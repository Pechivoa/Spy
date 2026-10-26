import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor extension AppModel {
    var effectiveDurationLabel: String { effectiveMinutes == minutes ? durationLabel : effectiveMinutes == 0 ? "Выключено" : effectiveMinutes.formatted() + " мин" }
    var effectiveQuality: Quality { PowerPolicy.quality(base: quality, battery: batteryQuality, enabled: batterySaving, onBattery: onBattery) }
    var effectiveMinutes: Double { PowerPolicy.minutes(base: minutes, cap: batteryMinutes, enabled: batterySaving, onBattery: onBattery) }
    var libraryAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    var captureSettings: CaptureSettings { CaptureSettings(quality: quality, minutes: minutes, systemAudio: systemAudio, microphone: microphone, microphoneID: microphoneID, systemVolume: systemVolume, microphoneVolume: microphoneVolume, separateAudio: separateAudio) }
    func updateHUD() {
        guard !previewMode else { return }
        hud.update(HUDState(recording: recording && !privacyPaused, manual: manualRecording, seconds: manualRecording ? stats.manualSeconds : stats.seconds, bytes: manualRecording ? stats.manualBytes : stats.bytes, battery: batterySaving && onBattery), enabled: hudEnabled, displayID: displayID, corner: hudCorner)
    }
    func setupProFeatures() {
        setupPrivacy()
        proObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.journal.record(.info, "Рабочий стол macOS", "Переключение полноэкранного Space. " + self.captureTargetSummary)
            }
        })
        hud.onHide = { [weak self] in self?.hudEnabled = false }
        onBattery = PowerMonitor.onBattery(); refreshLoginStatus(); refreshRecoveryFolders()
        powerMonitor = PowerMonitor { [weak self] value in Task { @MainActor in self?.powerChanged(value) } }
        proObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] event in
            let bundleID = (event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, self.profileAutomatic, let bundleID, bundleID != Bundle.main.bundleIdentifier, let profile = self.profiles.first(where: { $0.bundleID == bundleID }) else { return }
                await self.applyProfile(profile)
            }
        })
        proObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshLoginStatus(); self?.refreshCaptureAccess(); await self?.reloadClips(ifChanged: true) } })
        if !libraryAvailable { journal.record(.warning, "Папка видео", libraryURL.path + " недоступна. Подключите диск или выберите другую папку.") }
        setupAutomation()
        Task { await restoreLastSession(); sessionRestorationFinished = true; automationRuntimeChanged() }
    }
    func refreshLoginStatus() { if !previewMode { loginEnabled = LoginService.enabled; loginNeedsApproval = LoginService.needsApproval } }
    func setLoginEnabled(_ enabled: Bool) async {
        guard !loginBusy else { return }; loginBusy = true
        defer { loginBusy = false; refreshLoginStatus() }
        do {
            if !previewMode { try await LoginService.setEnabled(enabled) } else { loginEnabled = enabled }
            journal.record(.info, "Автозапуск", enabled ? "Запуск при входе включён." : "Запуск при входе выключен.")
        } catch { showError("Не удалось изменить автозапуск: " + error.localizedDescription, topic: "Автозапуск", details: describeError(error)) }
    }
    func powerChanged(_ value: Bool) {
        guard onBattery != value else { return }; onBattery = value; updateHUD()
        if batterySaving { requestPowerUpdate() }
    }
    func requestPowerUpdate() {
        guard !previewMode else { return }
        guard !recording || recordingQuality != effectiveQuality || recordingMinutes != effectiveMinutes else { return }
        pendingPowerUpdate = true
        Task { await reconcilePendingChanges() }
    }
    func applyProfile(_ profile: AppProfile) async {
        do { try profile.settings.validate() } catch { showError(error.localizedDescription, topic: "Профиль"); return }
        guard captureSettings != profile.settings else { activeProfileName = profile.name; return }
        pendingProfile = profile
        if manualRecording { message = "Профиль «\(profile.name)» применится после ручной записи" }
        await reconcilePendingChanges()
    }
    func reconcilePendingChanges() async {
        guard !shuttingDown, !busy, !saving, !diagnosticsBusy, !manualRecording, !switchingConfiguration, pendingProfile != nil || pendingPowerUpdate else { return }
        switchingConfiguration = true
        defer { switchingConfiguration = false; if pendingProfile != nil || pendingPowerUpdate { Task { await reconcilePendingChanges() } } }
        let profile = pendingProfile; pendingProfile = nil; pendingPowerUpdate = false
        let resume = recording
        if resume { await stop(processPending: false, preserveReplayIntent: true) }
        if let profile {
            let value = profile.settings
            quality = value.quality; minutes = min(30, max(0, value.minutes)); systemAudio = value.systemAudio
            microphone = value.microphone; microphoneID = value.microphoneID
            systemVolume = min(1, max(0, value.systemVolume)); microphoneVolume = min(1, max(0, value.microphoneVolume))
            separateAudio = value.separateAudio; activeProfileName = profile.name
            journal.record(.info, "Профиль", "Применён профиль «\(profile.name)» для \(profile.bundleID).")
        }
        engine.updateLimit(effectiveMinutes * 60)
        if resume && minutes > 0 { await start(requestPermission: false) }
        updateHUD()
    }
    func saveProfile(bundleID: String, name: String) {
        let profile = AppProfile(bundleID: bundleID, name: name, settings: captureSettings)
        if let index = profiles.firstIndex(where: { $0.bundleID == bundleID }) { profiles[index] = profile } else { profiles.append(profile) }
        message = "Профиль «\(name)» сохранён"
        journal.record(.info, "Профиль", "Сохранены настройки для \(bundleID).")
    }
    func addProfileFromApp() {
        let panel = NSOpenPanel(); panel.title = "Приложение для профиля"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        saveProfile(bundleID: id, name: name)
    }
    func removeProfile(_ profile: AppProfile) {
        profiles.removeAll { $0.id == profile.id }
        if pendingProfile?.id == profile.id { pendingProfile = nil }
        if activeProfileName == profile.name { activeProfileName = nil }
    }
    func runningAppChoices() -> [AppChoice] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }; return AppChoice(id: id, name: app.localizedName ?? id)
        }.sorted { $0.name < $1.name }
    }
    func chooseLibrary() async {
        guard !recording, !saving, !cleanupBusy else { return }
        let panel = NSOpenPanel(); panel.title = "Папка для сохранённых видео Spy"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = libraryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try await setLibraryFolder(url) }
        catch { showError("Не удалось выбрать папку: " + error.localizedDescription, topic: "Папка видео", details: describeError(error)) }
    }
    func setLibraryFolder(_ url: URL) async throws {
        guard !recording, !saving, !cleanupBusy else { throw SpyError.message("Остановите запись перед сменой папки.") }
        let normalized = url.spyFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SpyError.message("Папка недоступна.") }
        let probe = normalized.appendingPathComponent(".Spy-write-" + UUID().uuidString)
        try Data().write(to: probe, options: .withoutOverwriting); try FileManager.default.removeItem(at: probe)
        autoCleanup = false; libraryURL = normalized; selectedClip = nil
        if !previewMode { preferences.set(normalized.path, forKey: "libraryPath") }
        await reloadClips()
        message = "Папка изменена. Правила автоочистки можно включить для новой библиотеки."
        journal.record(.info, "Папка видео", normalized.path)
    }
    func toggleManual() async {
        guard !busy, !saving, !shuttingDown, !diagnosticsBusy else { return }
        if manualRecording { await finishManual(); return }
        let wasCapturing = recording
        if !recording { await start(forManual: true) }
        guard recording else { return }
        busy = true
        defer { busy = false }
        do {
            try await engine.beginManual(); manualStartedCapture = !wasCapturing; manualRecording = true
            message = "Ручная запись началась · " + shortcuts.manual.label + " — завершить"
            journal.record(.info, "Ручная запись", "Начат полный сеанс без ограничения длительностью буфера.")
        } catch { showError(error.localizedDescription, topic: "Ручная запись", details: describeError(error)) }
    }
    func finishManual(stopCapture: Bool = false) async {
        guard manualRecording, !saving, !busy else { return }
        busy = true; saving = true
        let shouldStop = stopCapture || manualStartedCapture || minutes == 0
        defer { busy = false; saving = false; manualStartedCapture = false; refreshDisk(); refreshRecoveryFolders(); Task { await reconcilePendingChanges() } }
        do {
            if shouldStop { await flushAutoMoments() }
            let snapshot = try await engine.finishManual(); manualRecording = false
            if shouldStop { await engine.stop(preserveForRecovery: captureFailure != nil); recording = false; privacyPaused = false; manualPrivacyPause = false; endCaptureActivity() }
            try await saveManualSnapshot(snapshot)
        } catch {
            manualRecording = false
            if shouldStop { await engine.stop(preserveForRecovery: captureFailure != nil); recording = false; privacyPaused = false; manualPrivacyPause = false; endCaptureActivity() }
            showError(error.localizedDescription, topic: "Сохранение ручной записи", details: describeError(error))
        }
    }
    func endCaptureActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil } }
    func saveManualSnapshot(_ snapshot: SpySnapshot, replaySession: Bool = false) async throws {
        guard libraryAvailable else { throw SpyError.message("Папка видео недоступна. Подключите диск; запись сохранена во временных файлах и доступна для восстановления.") }
        let stem = (replaySession ? "Spy_Session_" : "Spy_Recording_") + String(Int(Date().timeIntervalSince1970)) + "_" + String(UUID().uuidString.prefix(4))
        let destination = libraryURL.appendingPathComponent(stem + ".mov").spyFileURL
        let partial = libraryURL.appendingPathComponent("." + stem + ".mov")
        do {
            try await SpyExporter.export(snapshot, to: partial, levels: AudioLevels(system: Float(systemVolume), microphone: Float(microphoneVolume)), separateAudio: separateAudio, editableMicrophone: true, removeSnapshot: false)
            try FileManager.default.moveItem(at: partial, to: destination)
            storeMarkers(MarkerTimeline.positions(in: snapshot), for: destination)
            do {
                let retained = try ReplayCrashRecovery.retainUnexported(from: snapshot)
                if let retained { journal.record(.warning, "Восстановление записи", "Неэкспортированные сегменты и дополнительные файлы сохранены отдельно:\n" + retained.path) }
                else { try FileManager.default.removeItem(at: snapshot.directory) }
            } catch { journal.record(.warning, "Очистка восстановления", "Видео сохранено, но исходная папка оставлена для защиты неэкспортированных файлов.\n" + snapshot.directory.path + "\n" + describeError(error)) }
            await reloadClips()
            if let clip = clips.first(where: { $0.url == destination }) { if !shuttingDown { notifySaved(clip, title: "Запись сохранена") }; message = (replaySession ? "Последняя сессия сохранена · " : "Ручная запись сохранена · ") + clockText(clip.duration) }
            journal.record(.info, replaySession ? "Автосохранение" : "Ручная запись", "Сохранено " + destination.lastPathComponent)
            if autoCleanup { await cleanupLibrary(protecting: [destination]) }
        } catch { try? FileManager.default.removeItem(at: partial); throw error }
    }
    func refreshRecoveryFolders() {
        recoveryFolders = ((try? FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])) ?? []).filter {
            guard !autoMomentClips.isProcessing(directory: $0) else { return false }
            guard $0.lastPathComponent.hasPrefix("record-"), let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }
    }
    func recoverRecording(_ folder: URL) async {
        guard !busy, !saving, !manualRecording else { return }; busy = true; saving = true
        defer { busy = false; saving = false; refreshRecoveryFolders() }
        do {
            if AutoMomentClipController.isRecoverable(directory: folder) { _ = try await autoMomentClips.recover(directory: folder); await reloadClips(); return }
            let snapshot = try await MediaSharing.recoverySnapshot(directory: folder)
            if !snapshot.skippedRecoveryFiles.isEmpty { journal.record(.warning, "Восстановление записи", "Пропущены незавершённые или повреждённые сегменты: " + snapshot.skippedRecoveryFiles.joined(separator: ", ")) }
            try await saveManualSnapshot(snapshot, replaySession: folder.lastPathComponent.hasPrefix("record-replay-"))
        }
        catch { showError(error.localizedDescription, topic: "Восстановление записи", details: describeError(error)) }
    }
    func exportMP4(_ clip: Clip, microphoneEnabled: Bool = true) async {
        guard !saving, !cleanupBusy else { return }
        let panel = NSSavePanel(); panel.title = "Экспортировать MP4"
        panel.allowedContentTypes = [.mpeg4Movie]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = clip.url.deletingPathExtension().lastPathComponent + ".mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try await exportMP4(clip, destination: destination, microphoneEnabled: microphoneEnabled) }
        catch { showError(error.localizedDescription, topic: "Экспорт MP4", details: describeError(error)) }
    }
    func exportMP4(_ clip: Clip, destination: URL, microphoneEnabled: Bool = true) async throws {
        guard !saving else { throw SpyError.message("Дождитесь текущего сохранения.") }
        guard clip.url.spyFileURL != destination.spyFileURL else { throw SpyError.message("Выберите другой файл, чтобы сохранить оригинал.") }
        saving = true
        defer { saving = false; Task { await reconcilePendingChanges() } }
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".Spy-export-" + UUID().uuidString + ".mp4")
        do {
            try await MediaSharing.exportMP4(source: clip.url, to: partial, microphoneEnabled: microphoneEnabled)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial) }
            else { try FileManager.default.moveItem(at: partial, to: destination) }
            message = "MP4 экспортирован · " + destination.lastPathComponent
            journal.record(.info, "Экспорт MP4", destination.path)
            if destination.deletingLastPathComponent().path == libraryURL.path { await reloadClips() }
        } catch { try? FileManager.default.removeItem(at: partial); throw error }
    }
}
