import Foundation
import SwiftUI

/// The library publisher must use `id` in its destination name. Retrying a
/// retained job can then acknowledge a movie published just before a crash.
struct AutoMomentClipJob {
    let id: UUID
    let marker: ReplayMarker
    let snapshot: SpySnapshot
    let playback: BufferPlayback
    let range: PreviewRange
    let levels: AudioLevels
    let separateAudio: Bool
    let frameDuration: Double
    var markers: [ClipMarker] {
        let mapped = snapshot.markers.compactMap { marker in
            playback.sourcePosition(marker.sourceSeconds).map { ClipMarker(id: marker.id, seconds: $0, title: marker.title) }
        }
        return MarkerTimeline.selected(mapped, start: range.start, end: range.end)
            .sorted { $0.seconds < $1.seconds }
    }
}

/// This manifest is durable before any source snapshot is released. Recovery
/// rebuilds the same edit list and gains, even when the library was unavailable.
struct AutoMomentClipManifest: Codable {
    static let fileName = "auto-moment-clip.json"
    struct File: Codable {
        let name: String
        let interval: SpySourceInterval
    }
    let id: UUID
    let sessionID: UUID
    let marker: ReplayMarker
    let beforeSeconds: Double
    let afterSeconds: Double
    let systemVolume: Float
    let microphoneVolume: Float
    let separateAudio: Bool
    var nominalFrameDuration: Double? = nil
    var files: [File] = []
    var markers: [ReplayMarker] = []
    var completedDestination: URL?
    var frameDuration: Double {
        guard let value = nominalFrameDuration, value.isFinite, value > 0 else { return 1.0 / 30 }
        return min(1.0 / 15, max(1.0 / 240, value))
    }

    func persist(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
    static func load(in directory: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
        guard value.beforeSeconds.isFinite, value.afterSeconds.isFinite,
              (0...120).contains(value.beforeSeconds), (0...60).contains(value.afterSeconds),
              value.systemVolume.isFinite, value.microphoneVolume.isFinite,
              value.marker.sourceSeconds.isFinite,
              value.files.allSatisfy({ file in
                  file.name == URL(fileURLWithPath: file.name).lastPathComponent && file.name.hasSuffix(".mov") &&
                  file.interval.start.isFinite && file.interval.end.isFinite && file.interval.end > file.interval.start
              }) else { throw SpyError.message("Повреждены параметры автоклипа. Исходные сегменты сохранены.") }
        guard Set(value.files.map(\.name)).count == value.files.count else {
            throw SpyError.message("Повторяются имена исходников автоклипа. Исходные сегменты сохранены.")
        }
        let ordered = value.files.sorted { $0.interval.start < $1.interval.start }
        for index in ordered.indices.dropFirst() where AutoMomentClipController.invalidOverlap(ordered[index - 1].interval, ordered[index].interval, frameDuration: value.frameDuration) {
            throw SpyError.message("Перекрываются интервалы исходников автоклипа. Исходные сегменты сохранены.")
        }
        return value
    }
    func snapshot(in directory: URL) throws -> SpySnapshot {
        guard !files.isEmpty else { throw SpyError.message("В автоклипе ещё нет видеокадров.") }
        let urls = files.map { directory.appendingPathComponent($0.name) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SpyError.message("Один из сегментов автоклипа недоступен. Остальные исходники сохранены.")
        }
        // Do not tail-trim: the marker is mapped against the entire pinned list.
        let seconds = files.reduce(0) { $0 + $1.interval.end - $1.interval.start }
        return SpySnapshot(directory: directory, urls: urls, requestedSeconds: seconds + 1,
                           sourceIntervals: files.map(\.interval), markers: markers, captureSessionID: sessionID)
    }
}

@MainActor final class AutoMomentClipController: ObservableObject {
    static let maximumPending = 5
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "autoMomentClips.enabled"); updateStatus() }
    }
    @Published var beforeSeconds: Double {
        didSet {
            let valid = Self.bounded(beforeSeconds, maximum: 120, fallback: 30)
            if beforeSeconds != valid { beforeSeconds = valid }
            defaults.set(valid, forKey: "autoMomentClips.beforeSeconds")
        }
    }
    @Published var afterSeconds: Double {
        didSet {
            let valid = Self.bounded(afterSeconds, maximum: 60, fallback: 10)
            if afterSeconds != valid { afterSeconds = valid }
            defaults.set(valid, forKey: "autoMomentClips.afterSeconds")
        }
    }
    @Published private(set) var pendingCount = 0
    @Published private(set) var savedCount = 0
    @Published private(set) var status = "Автоклипы выключены"
    @Published private(set) var lastError: String?
    @Published private(set) var lastSavedURL: URL?

    private final class Pending {
        enum Phase { case pinning, waiting, finalizing }
        var manifest: AutoMomentClipManifest
        var directory: URL?
        var phase: Phase = .pinning
        let markerContentSeconds: Double
        var lastPinnedContent: Double
        var collecting = false
        var task: Task<Void, Never>?
        init(manifest: AutoMomentClipManifest, contentSeconds: Double) {
            self.manifest = manifest; self.markerContentSeconds = contentSeconds; self.lastPinnedContent = contentSeconds
        }
    }
    private let defaults: UserDefaults
    private let engine: SpyEngine?
    private let onReady: (AutoMomentClipJob) async throws -> URL
    private let onDiagnostic: (String, Bool) -> Void
    private var pending: [UUID: Pending] = [:]
    private var seenMarkerIDs: Set<UUID> = []
    private var seenOrder: [UUID] = []
    private var recovering: Set<String> = []
    private var flushing = false

    init(defaults: UserDefaults, engine: SpyEngine?,
         onReady: @escaping (AutoMomentClipJob) async throws -> URL,
         onDiagnostic: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.defaults = defaults; self.engine = engine; self.onReady = onReady; self.onDiagnostic = onDiagnostic
        self.enabled = defaults.bool(forKey: "autoMomentClips.enabled")
        self.beforeSeconds = Self.bounded(defaults.object(forKey: "autoMomentClips.beforeSeconds") as? Double ?? 30, maximum: 120, fallback: 30)
        self.afterSeconds = Self.bounded(defaults.object(forKey: "autoMomentClips.afterSeconds") as? Double ?? 10, maximum: 60, fallback: 10)
        updateStatus()
    }

    /// Await this method when adding a mark: the pre-roll is pinned before this
    /// returns, rather than ten seconds later after a short ring has evicted it.
    func capture(marker: ReplayMarker, levels: AudioLevels, separateAudio: Bool) async {
        guard enabled, !flushing, !seenMarkerIDs.contains(marker.id), let engine,
              let progress = engine.captureProgress(), progress.isActive else { return }
        guard pending.count < Self.maximumPending else {
            report("Очередь автоклипов заполнена (5). Метка сохранена; новый автоклип не запущен.")
            return
        }
        guard beforeSeconds + afterSeconds > 0 else {
            report("Для автоклипа задайте время до или после метки больше нуля.")
            return
        }
        seenMarkerIDs.insert(marker.id); seenOrder.append(marker.id)
        if seenOrder.count > 512 { seenMarkerIDs.remove(seenOrder.removeFirst()) }
        let content = marker.contentSeconds ?? progress.capturedSeconds
        let manifest = AutoMomentClipManifest(id: UUID(), sessionID: progress.sessionID, marker: marker,
            beforeSeconds: beforeSeconds, afterSeconds: afterSeconds,
            systemVolume: levels[.system], microphoneVolume: levels[.microphone], separateAudio: separateAudio,
            nominalFrameDuration: progress.frameDuration,
            markers: [marker])
        let item = Pending(manifest: manifest, contentSeconds: content)
        pending[manifest.id] = item; lastError = nil; updateStatus()
        do {
            let snapshot = try await engine.snapshot(seconds: 1800)
            guard snapshot.captureSessionID == nil || snapshot.captureSessionID == manifest.sessionID else {
                retainSnapshot(snapshot)
                throw SpyError.message("Запись сменилась до закрепления метки. Доступные исходники сохранены для восстановления.")
            }
            do {
                let folder = snapshot.directory.deletingLastPathComponent().appendingPathComponent("record-auto-" + manifest.id.uuidString, isDirectory: true)
                // Promote the whole hardlink snapshot first. A crash while the
                // manifest is being written must not leave its only copies in
                // save-*, which startup considers disposable.
                try FileManager.default.moveItem(at: snapshot.directory, to: folder)
                item.directory = folder
                let durable = SpySnapshot(directory: folder,
                    urls: snapshot.urls.map { folder.appendingPathComponent($0.lastPathComponent) },
                    requestedSeconds: snapshot.requestedSeconds, sourceIntervals: snapshot.sourceIntervals,
                    markers: snapshot.markers, captureSessionID: snapshot.captureSessionID)
                // Preserve the complete recipe before selecting/validating the
                // edit list. A malformed source still retains its original mark,
                // audio policy and timing settings for a later recovery attempt.
                var recovery = item.manifest
                recovery.files = zip(durable.urls, durable.sourceIntervals).map {
                    .init(name: $0.0.lastPathComponent, interval: $0.1)
                }
                recovery.markers = durable.markers
                if !recovery.markers.contains(where: { $0.id == marker.id }) { recovery.markers.append(marker) }
                try recovery.persist(in: folder)
                try merge(durable, into: item, initial: true, removeSnapshot: false)
            } catch {
                if FileManager.default.fileExists(atPath: snapshot.directory.path) { retainSnapshot(snapshot) }
                throw error
            }
            item.phase = .waiting
            item.task = Task { [weak self, weak item] in
                guard let self, let item else { return }
                await self.monitor(item)
            }
            updateStatus()
        } catch {
            failed(item, error: error)
        }
    }

    /// Hook before stopping/reconfiguring the engine. Capture the final available
    /// frames while it is still active, then publish shortened clips if necessary.
    func flushPending() async {
        if flushing { await waitUntilIdle(); return }
        flushing = true
        defer { flushing = false; updateStatus() }
        while pending.values.contains(where: { $0.phase == .pinning || $0.collecting }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = pending.values.filter { $0.phase == .waiting }
        for item in waiting { item.phase = .finalizing }
        // Every item is made non-pollable before the shared final snapshot awaits.
        if !waiting.isEmpty, let engine, let progress = engine.captureProgress(), progress.isActive {
            do {
                let snapshot = try await engine.snapshot(seconds: 1800)
                var allMerged = true
                for item in waiting where item.manifest.sessionID == progress.sessionID {
                    do { try merge(snapshot, into: item, initial: false, removeSnapshot: false) }
                    catch { allMerged = false; report("Не удалось закрепить остаток автоклипа: " + describeError(error)) }
                }
                if allMerged { try? FileManager.default.removeItem(at: snapshot.directory) }
                else { retainSnapshot(snapshot) }
            } catch { report("Автоклипы завершены по уже закреплённым кадрам: " + describeError(error)) }
        }
        for item in waiting { await finish(item) }
        await waitUntilIdle()
    }

    func waitUntilIdle() async {
        while !pending.isEmpty || !recovering.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    static func isRecoverable(directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(AutoMomentClipManifest.fileName).path)
    }
    func isProcessing(directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        return recovering.contains(path) || pending.values.contains { $0.directory?.standardizedFileURL.path == path }
    }

    /// Recovery is independent of enabled replay, the current ring and current
    /// preferences. Failure retains every original source and exact edit recipe.
    @discardableResult func recover(directory: URL) async throws -> URL {
        let key = directory.standardizedFileURL.path
        guard !recovering.contains(key), !pending.values.contains(where: { $0.directory?.standardizedFileURL.path == key }) else {
            throw SpyError.message("Этот автоклип уже сохраняется.")
        }
        recovering.insert(key); updateStatus()
        defer { recovering.remove(key); updateStatus() }
        do {
            var manifest = try AutoMomentClipManifest.load(in: directory)
            if let existing = manifest.completedDestination, FileManager.default.fileExists(atPath: existing.path) {
                try? FileManager.default.removeItem(at: directory)
                return existing
            }
            let job = try await prepare(manifest, directory: directory)
            let destination = try await onReady(job)
            manifest.completedDestination = destination
            try manifest.persist(in: directory)
            try? FileManager.default.removeItem(at: directory)
            savedCount += 1; lastSavedURL = destination; lastError = nil
            onDiagnostic("Автоклип восстановлен: " + destination.lastPathComponent, false)
            return destination
        } catch {
            report("Автоклип не восстановлен; исходники оставлены в кэше. " + describeError(error))
            throw error
        }
    }

    private func monitor(_ item: Pending) async {
        while pending[item.manifest.id] === item, item.phase == .waiting {
            if flushing { return }
            guard let engine, let progress = engine.captureProgress(), progress.isActive,
                  progress.sessionID == item.manifest.sessionID else {
                item.phase = .finalizing; await finish(item); return
            }
            let target = item.markerContentSeconds + item.manifest.afterSeconds
            let ready = progress.capturedSeconds >= target - 0.00001
            // Periodic pinning also protects a 60-second post-roll in a 30-second ring.
            if ready || progress.capturedSeconds - item.lastPinnedContent >= 0.75 {
                item.collecting = true
                do {
                    let snapshot = try await engine.snapshot(seconds: 1800)
                    if snapshot.captureSessionID == nil || snapshot.captureSessionID == item.manifest.sessionID {
                        do { try merge(snapshot, into: item, initial: false) }
                        catch { retainSnapshot(snapshot); throw error }
                        item.lastPinnedContent = progress.capturedSeconds
                    } else { retainSnapshot(snapshot) }
                } catch {
                    item.collecting = false
                    failed(item, error: error); return
                }
                item.collecting = false
                if ready { item.phase = .finalizing; await finish(item); return }
            }
            updateStatus()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func merge(_ snapshot: SpySnapshot, into item: Pending, initial: Bool, removeSnapshot: Bool = true) throws {
        guard let directory = item.directory,
              snapshot.sourceIntervals.count == snapshot.urls.count else {
            throw SpyError.message("Не удалось прочитать временную шкалу автоклипа.")
        }
        var value = item.manifest
        let total = snapshot.sourceIntervals.reduce(0) { $0 + max(0, $1.end - $1.start) }
        var markerPosition: Double?
        var cursor = 0.0
        for interval in snapshot.sourceIntervals {
            if value.marker.sourceSeconds >= interval.start - 0.00001 && value.marker.sourceSeconds <= interval.end + 0.00001 {
                markerPosition = cursor + value.marker.sourceSeconds - interval.start
            }
            cursor += interval.end - interval.start
        }
        let earliest = markerPosition.map { max(0, $0 - value.beforeSeconds) } ?? (initial ? total : 0)
        cursor = 0
        for (url, interval) in zip(snapshot.urls, snapshot.sourceIntervals) {
            defer { cursor += interval.end - interval.start }
            if initial && cursor + interval.end - interval.start <= earliest - 0.00001 { continue }
            // Later snapshots need only the post-marker portion. Older pinned
            // files remain intact and are never replaced by the pruned ring.
            if !initial && interval.end < value.marker.sourceSeconds - 0.00001 { continue }
            if let duplicate = value.files.first(where: { abs($0.interval.start - interval.start) < 0.00001 && abs($0.interval.end - interval.end) < 0.00001 }) {
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(duplicate.name).path) else {
                    throw SpyError.message("Закреплённый сегмент автоклипа пропал.")
                }
                continue
            }
            // A different name pointing to the same hardlink is one source,
            // just as an identical encoder interval is one source.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let inode = attributes[.systemFileNumber] as? NSNumber,
               let device = attributes[.systemNumber] as? NSNumber,
               value.files.contains(where: { entry in
                   let existing = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(entry.name).path)
                   return (existing?[.systemFileNumber] as? NSNumber) == inode && (existing?[.systemNumber] as? NSNumber) == device
               }) { continue }
            if value.files.contains(where: { Self.invalidOverlap(interval, $0.interval, frameDuration: value.frameDuration) }) {
                throw SpyError.message("Перекрываются интервалы исходников автоклипа. Исходники сохранены без дублирования кадров.")
            }
            let name = url.lastPathComponent
            guard !value.files.contains(where: { $0.name == name }) else {
                throw SpyError.message("Совпали имена разных сегментов автоклипа.")
            }
            let destination = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.linkItem(at: url, to: destination)
            }
            value.files.append(.init(name: name, interval: interval))
        }
        value.files.sort { $0.interval.start < $1.interval.start }
        for marker in snapshot.markers where !value.markers.contains(where: { $0.id == marker.id }) { value.markers.append(marker) }
        guard !value.files.isEmpty else { throw SpyError.message("Для метки пока нет видеокадров.") }
        try value.persist(in: directory)
        item.manifest = value
        if removeSnapshot { try? FileManager.default.removeItem(at: snapshot.directory) }
    }

    private func prepare(_ manifest: AutoMomentClipManifest, directory: URL) async throws -> AutoMomentClipJob {
        let snapshot = try manifest.snapshot(in: directory)
        let levels = AudioLevels(system: manifest.systemVolume, microphone: manifest.microphoneVolume)
        let playback = try await BufferPlayback.prepare(snapshot, levels: levels)
        guard let position = playback.sourcePosition(manifest.marker.sourceSeconds) else {
            throw SpyError.message("Кадр метки не найден; исходники автоклипа сохранены для восстановления.")
        }
        var start = max(0, position - manifest.beforeSeconds)
        // Include the marked frame when the requested post-roll is zero.
        var end = min(playback.duration, position + max(manifest.afterSeconds, 1.0 / 30))
        // A stop immediately after a zero-pre-roll mark may leave only one
        // available frame. Include its nearest frames up to the editor's 50ms
        // minimum, or the complete source when the source itself is shorter.
        if end - start < 0.05 {
            if playback.duration <= 0.05 { start = 0; end = playback.duration }
            else { start = max(0, end - 0.05); end = min(playback.duration, max(end, start + 0.05)) }
        }
        let range = try PreviewRange(start: start, end: end, duration: playback.duration)
        return AutoMomentClipJob(id: manifest.id, marker: manifest.marker, snapshot: snapshot, playback: playback,
                                 range: range, levels: levels, separateAudio: manifest.separateAudio, frameDuration: manifest.frameDuration)
    }

    private func finish(_ item: Pending) async {
        guard pending[item.manifest.id] === item, let directory = item.directory else { return }
        do {
            let job = try await prepare(item.manifest, directory: directory)
            let destination = try await onReady(job)
            item.manifest.completedDestination = destination
            try item.manifest.persist(in: directory)
            try? FileManager.default.removeItem(at: directory)
            pending.removeValue(forKey: item.manifest.id)
            savedCount += 1; lastSavedURL = destination; lastError = nil
            onDiagnostic("Автоклип сохранён: " + destination.lastPathComponent, false)
            updateStatus()
        } catch { failed(item, error: error) }
    }

    private func failed(_ item: Pending, error: Error) {
        pending.removeValue(forKey: item.manifest.id)
        report("Автоклип не сохранён; закреплённые исходники оставлены для восстановления. " + describeError(error))
        updateStatus()
    }
    private func retainSnapshot(_ snapshot: SpySnapshot) {
        let target = snapshot.directory.deletingLastPathComponent().appendingPathComponent("record-auto-unmerged-" + UUID().uuidString)
        do { try FileManager.default.moveItem(at: snapshot.directory, to: target) }
        catch { onDiagnostic("Не удалось перенести исходники в папку восстановления: " + snapshot.directory.path + " · " + describeError(error), true) }
    }
    private func report(_ message: String) { lastError = message; onDiagnostic(message, true); updateStatus() }
    private func updateStatus() {
        pendingCount = pending.count + recovering.count
        if pendingCount > 0 {
            let waiting = pending.values.filter { $0.phase == .waiting }
            if let item = waiting.first, let progress = engine?.captureProgress(), progress.sessionID == item.manifest.sessionID {
                let target = item.markerContentSeconds + item.manifest.afterSeconds
                let remaining = max(0, Int(ceil(target - progress.capturedSeconds)))
                status = progress.isPaused ? "Автоклипов: \(pendingCount) · ожидание на паузе" : "Автоклипов: \(pendingCount) · ещё \(remaining) с записи"
            } else { status = "Автоклипов: \(pendingCount) · сохранение…" }
        } else if lastError != nil { status = "Не удалось сохранить автоклип · исходники доступны для восстановления" }
        else if savedCount > 0 { status = "Сохранено автоклипов: \(savedCount)" }
        else { status = enabled ? "Добавьте метку, чтобы сохранить автоклип" : "Автоклипы выключены" }
    }
    private static func bounded(_ value: Double, maximum: Double, fallback: Double) -> Double {
        value.isFinite ? min(maximum, max(0, value.rounded())) : fallback
    }
    /// Each encoded segment ends at its last accepted PTS plus one nominal
    /// frame. A real display timer may put the next segment a fraction of a
    /// frame earlier. These are different frames and both must be preserved.
    /// Equal intervals/hardlinks are deduplicated before reaching this check.
    nonisolated static func invalidOverlap(_ first: SpySourceInterval, _ second: SpySourceInterval, frameDuration: Double) -> Bool {
        let overlap = min(first.end, second.end) - max(first.start, second.start)
        guard overlap > 0.00001 else { return false }
        let earlier = first.start < second.start ? first : second
        let later = first.start < second.start ? second : first
        let adjacent = earlier.start < later.start && earlier.end < later.end
        return !adjacent || overlap > frameDuration + 0.00001
    }
}

struct AutoMomentClipSettingsView: View {
    @ObservedObject var controller: AutoMomentClipController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $controller.enabled) {
                Label("Автоклип по метке", systemImage: "bookmark.square.fill").font(.system(size: 14, weight: .semibold))
            }.toggleStyle(.switch)
            Text("Добавьте метку во время повтора: Spy сохранит видео до неё и дождётся нужного количества новых кадров после. Пауза приватности не сокращает этот интервал.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                secondsControl("До метки", value: $controller.beforeSeconds, maximum: 120)
                secondsControl("После метки", value: $controller.afterSeconds, maximum: 60)
            }.disabled(!controller.enabled)
            HStack(spacing: 7) {
                Image(systemName: controller.lastError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                Text(controller.status).textSelection(.enabled)
            }.font(.system(size: 11)).foregroundStyle(controller.lastError == nil ? Theme.muted : Theme.accent)
            if let error = controller.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
            Text("До 5 автоклипов одновременно. При остановке сохраняется доступная часть. Громкость и раздельные дорожки фиксируются при добавлении метки.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
    private func secondsControl(_ title: String, value: Binding<Double>, maximum: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) с").monospacedDigit().foregroundStyle(.white)
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            Slider(value: value, in: 0...maximum, step: 1).tint(Theme.accent)
                .accessibilityLabel(title)
        }
    }
}
