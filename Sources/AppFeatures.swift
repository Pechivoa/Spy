import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor extension AppModel {
    var cleanupPolicy: CleanupPolicy { CleanupPolicy(enabled: autoCleanup, maximumBytes: Int64(libraryLimitGB * 1_000_000_000), maximumAgeDays: maximumAgeDays) }
    func refreshMicrophones() {
        if previewMode { microphones = [MicrophoneChoice(id: "", name: "По умолчанию в macOS"), MicrophoneChoice(id: "preview-mic", name: "Микрофон MacBook")]; return }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        var devices = discovery.devices
        if let current = AVCaptureDevice.default(for: .audio), !devices.contains(where: { $0.uniqueID == current.uniqueID }) { devices.append(current) }
        microphones = [MicrophoneChoice(id: "", name: "По умолчанию в macOS")] + devices.filter { $0.hasMediaType(.audio) }.map { MicrophoneChoice(id: $0.uniqueID, name: $0.localizedName) }.sorted { $0.name < $1.name }
    }
    func refreshWindows(requestPermission: Bool = true) async {
        guard !recording, !busy, !windowsLoading else { return }
        if !captureAccess.screenAllowed() && !requestPermission { blockScreenCapture(); return }
        windowsLoading = true
        defer { windowsLoading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }.map {
                let app = $0.owningApplication?.applicationName ?? "Приложение"
                let title = ($0.title?.isEmpty == false) ? $0.title! : "Без названия"
                return WindowChoice(id: $0.windowID, title: app + " — " + title)
            }.sorted { $0.title < $1.title }
            if !windows.contains(where: { $0.id == windowID }) { windowID = 0 }
            needsPermission = false; captureIssue = nil
            journal.record(.info, "Окна", "Список обновлён: \(windows.count) окон.")
        } catch {
            journal.record(.error, "Список окон", describeError(error))
            if CaptureAccess.isScreenDenial(error) { blockScreenCapture() }
            else { captureIssue = "Не удалось получить список окон. " + error.localizedDescription }
        }
    }
    func setClipName(_ clip: Clip, name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count <= 120 else { throw SpyError.message("Название должно быть не длиннее 120 символов.") }
        var value = metadata.get(clip.url); value.name = cleaned
        try metadata.set(value, for: clip.url)
        applyMetadata(clip.url)
        journal.record(.info, "Название видео", clip.url.lastPathComponent + " → " + (cleaned.isEmpty ? "дата записи" : cleaned))
    }
    func toggleFavorite(_ clip: Clip) {
        var value = metadata.get(clip.url); value.favorite.toggle()
        do { try metadata.set(value, for: clip.url); applyMetadata(clip.url) }
        catch { showError("Не удалось сохранить избранное: " + error.localizedDescription, topic: "Избранное", details: describeError(error)) }
    }
    func applyMetadata(_ source: URL) {
        let url = source.spyFileURL
        let value = metadata.get(url)
        if let index = clips.firstIndex(where: { $0.url == url }) { clips[index].name = value.name; clips[index].favorite = value.favorite }
        if selectedClip?.url == url { selectedClip?.name = value.name; selectedClip?.favorite = value.favorite }
    }
    func notifySaved(_ clip: Clip, title: String = "Повтор сохранён") {
        if notificationsEnabled && !previewMode { toast.show(title: title, detail: "\(preciseClock(clip.duration)) · \(fileSize(clip.bytes))", displayID: displayID) }
    }
    func testNotification() { toast.show(title: "Spy готов сохранять моменты", detail: "Уведомления исчезают через 3 секунды", displayID: displayID) }
    func cleanupLibrary(protecting ids: Set<URL> = [], manual: Bool = false) async {
        guard autoCleanup, !cleanupBusy, metadata.loadError == nil else { return }
        cleanupBusy = true
        defer { cleanupBusy = false }
        var protected = ids.union(protectedAutoClipURLs)
        if let selectedClip { protected.insert(selectedClip.id) }
        let planned = cleanupPolicy.plan(clips, protecting: protected)
        var removed = 0
        for clip in planned {
            guard !metadata.get(clip.url).favorite, selectedClip?.id != clip.id else { continue }
            do { try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil); removed += 1 }
            catch { journal.record(.error, "Автоочистка", clip.url.lastPathComponent + "\n" + describeError(error)) }
            await Task.yield()
        }
        if removed > 0 {
            await reloadClips()
            journal.record(.info, "Автоочистка", "В Корзину перемещено \(removed) видео. Избранное сохранено.")
        }
        if manual { message = removed > 0 ? "Очистка завершена: \(removed) видео в Корзине" : "Видео для очистки по этим правилам нет" }
        let overLimit = totalLibraryBytes > cleanupPolicy.maximumBytes
        if autoCleanup && overLimit && lastOverLimitBytes != totalLibraryBytes {
            lastOverLimitBytes = totalLibraryBytes
            journal.record(.warning, "Лимит библиотеки", "Лимит превышен. Избранное и открытые видео защищены от автоочистки.")
        } else if !overLimit { lastOverLimitBytes = nil }
    }
    func trimClip(_ clip: Clip, start: Double, end: Double, microphoneEnabled: Bool = true, levels: AudioLevels = AudioLevels()) async throws -> URL {
        guard !saving else { throw SpyError.message("Дождитесь завершения текущего сохранения.") }
        saving = true
        defer { saving = false; refreshDisk() }
        let formatter = DateFormatter(); formatter.timeZone = SpyDates.timeZone; formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "Spy_Trim_" + formatter.string(from: Date()) + "_" + String(UUID().uuidString.prefix(4))
        let output = libraryURL.appendingPathComponent(stem + ".mov").spyFileURL
        let partial = libraryURL.appendingPathComponent("." + stem + ".mov")
        do {
            let source = try await EditableVideoAudio.load(url: clip.url)
            try await source.export(to: partial, start: start, end: end, microphoneEnabled: microphoneEnabled, levels: levels)
            try FileManager.default.moveItem(at: partial, to: output)
            do { try metadata.set(ClipMetadata(name: String(((microphoneEnabled ? "Фрагмент · " : "Без микрофона · ") + clip.title).prefix(120)), favorite: clip.favorite, markers: MarkerTimeline.selected(metadata.get(clip.url).markers, start: start, end: end)), for: output) }
            catch { journal.record(.warning, "Данные фрагмента", "Видео сохранено, но название и избранное не записаны.\n" + describeError(error)) }
            await reloadClips()
            sessions.copied(output, from: clip.url)
            journal.record(.info, "Обрезка", "\(clip.url.lastPathComponent) · \(preciseClock(start))–\(preciseClock(end)) → \(output.lastPathComponent)")
            if let saved = clips.first(where: { $0.url == output }) { notifySaved(saved, title: "Фрагмент сохранён") }
            if autoCleanup { await cleanupLibrary(protecting: [clip.url, output]) }
            return output
        } catch {
            try? FileManager.default.removeItem(at: partial)
            journal.record(.error, "Обрезка", describeError(error))
            throw error
        }
    }
}
