import SwiftUI
import AVFoundation

struct ExportQueueItem: Identifiable {
    enum Phase { case preparing, waiting, running, cancelling, completed, cancelled, failed }
    let id: UUID
    let title: String
    let sourceKey: String
    let range: PreviewRange
    var microphoneEnabled = true
    var gains = AudioLevels()
    var phase: Phase = .preparing
    var progress: Double = 0
    var result: URL?
    var error: String?
    var retainedDirectory: URL?
    var pending: Bool { [.preparing, .waiting, .running, .cancelling].contains(phase) }
    var status: String {
        switch phase {
        case .preparing: return "Подготовка"
        case .waiting: return "Ожидает"
        case .running: return "Сохраняется · \(Int(progress * 100))%"
        case .cancelling: return "Отменяется…"
        case .completed: return "Сохранено"
        case .cancelled: return "Отменено"
        case .failed: return "Ошибка"
        }
    }
}

struct QueuedExportPlan {
    let directory: URL
    let export: (@escaping (Float) -> Void) async throws -> URL
}

/// Each job owns its pinned inputs and frozen selection/audio settings. Closing
/// a viewer, changing its selection or deleting an original cannot retarget it.
@MainActor final class ExportQueueController: ObservableObject {
    @Published private(set) var items: [ExportQueueItem] = []
    private var plans: [UUID: QueuedExportPlan] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var runner: Task<Void, Never>?
    private var runningID: UUID?
    private var outcomes: [UUID: Result<URL, Error>] = [:]
    private var waiters: [UUID: Int] = [:]
    private let pendingChanged: (Int) -> Void
    private let canStart: () -> Bool
    private let diagnostic: (String, Bool) -> Void
    var pendingCount: Int { items.filter(\.pending).count }

    init(pendingChanged: @escaping (Int) -> Void = { _ in }, canStart: @escaping () -> Bool = { true }, diagnostic: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.pendingChanged = pendingChanged; self.canStart = canStart; self.diagnostic = diagnostic
    }
    @discardableResult func enqueue(title: String, sourceKey: String, range: PreviewRange, directory: URL,
                                    microphone: Bool = true, gains: AudioLevels = AudioLevels(),
                                    prepare: @escaping () async throws -> QueuedExportPlan) -> UUID {
        let id = UUID()
        // Retain all live work, and bound completed history.
        if items.count >= 50 { clearFinished() }
        items.append(ExportQueueItem(id: id, title: title, sourceKey: sourceKey, range: range, microphoneEnabled: microphone, gains: gains))
        changed()
        preparations[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await prepare()
                try Task.checkCancellation()
                self.plans[id] = plan
                self.update(id) { $0.phase = .waiting }
                self.preparations[id] = nil
                self.pump()
            } catch {
                self.fail(id, directory: directory, error: error, cancelled: Task.isCancelled)
                self.preparations[id] = nil
                self.pump()
            }
        }
        return id
    }
    func item(_ id: UUID) -> ExportQueueItem? { items.first { $0.id == id } }
    func existing(sourceKey: String, range: PreviewRange, microphone: Bool, gains: AudioLevels, includeCompleted: Bool = false) -> UUID? {
        items.last { ($0.pending || includeCompleted && $0.phase == .completed && $0.result.map { FileManager.default.fileExists(atPath: $0.path) } == true) && $0.sourceKey == sourceKey && $0.range == range && $0.microphoneEnabled == microphone && $0.gains == gains }?.id
    }
    func pending(sourceKey: String, range: PreviewRange?, microphone: Bool, gains: AudioLevels) -> Bool {
        items.contains { $0.pending && $0.sourceKey == sourceKey && $0.range == range && $0.microphoneEnabled == microphone && $0.gains == gains }
    }
    func saved(sourceKey: String, range: PreviewRange?, microphone: Bool, gains: AudioLevels) -> URL? {
        items.reversed().first { $0.phase == .completed && $0.sourceKey == sourceKey && $0.range == range && $0.microphoneEnabled == microphone && $0.gains == gains && $0.result.map { FileManager.default.fileExists(atPath: $0.path) } == true }?.result
    }
    func cancel(_ id: UUID) {
        guard let item = item(id), item.pending else { return }
        if item.phase == .preparing || item.phase == .cancelling && preparations[id] != nil {
            update(id) { $0.phase = .cancelling }; preparations[id]?.cancel(); return
        }
        if runningID == id { update(id) { $0.phase = .cancelling }; runner?.cancel(); return }
        if let plan = plans.removeValue(forKey: id) { try? FileManager.default.removeItem(at: plan.directory) }
        outcomes[id] = .failure(CancellationError())
        update(id) { $0.phase = .cancelled }
        pump()
    }
    func clearFinished() {
        items.removeAll { !$0.pending }
        outcomes = outcomes.filter { item($0.key) != nil || waiters[$0.key] != nil }
        changed()
    }
    func result(_ id: UUID) async throws -> URL {
        waiters[id, default: 0] += 1
        defer {
            waiters[id, default: 1] -= 1
            if waiters[id] == 0 { waiters[id] = nil; if item(id) == nil { outcomes[id] = nil } }
        }
        if let outcome = outcomes[id] { return try outcome.get() }
        while let item = item(id) {
            if let result = item.result { return result }
            if item.phase == .cancelled { throw CancellationError() }
            if item.phase == .failed { throw SpyError.message(item.error ?? "Не удалось сохранить фрагмент.") }
            try await Task.sleep(nanoseconds: 50_000_000)
            if let outcome = outcomes[id] { return try outcome.get() }
        }
        throw SpyError.message("Задача сохранения уже удалена из очереди.")
    }
    private func update(_ id: UUID, _ body: (inout ExportQueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index]); changed()
    }
    private func changed() { pendingChanged(pendingCount) }
    private func fail(_ id: UUID, directory: URL, error: Error, cancelled: Bool) {
        if cancelled || error is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            outcomes[id] = .failure(CancellationError())
            update(id) { $0.phase = .cancelled; $0.error = nil }
        } else {
            let retained = directory.deletingLastPathComponent().appendingPathComponent("record-queue-" + id.uuidString)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var recovery: URL?
            if files.contains(where: { $0.pathExtension == "mov" }) {
                do { try FileManager.default.moveItem(at: directory, to: retained); recovery = retained }
                catch { recovery = directory }
            } else { try? FileManager.default.removeItem(at: directory) }
            outcomes[id] = .failure(error)
            update(id) { $0.phase = .failed; $0.error = error.localizedDescription; $0.retainedDirectory = recovery }
            diagnostic(describeError(error) + (recovery.map { "\nИсходник: " + $0.path } ?? ""), true)
        }
    }
    private func pump() {
        guard runner == nil, let item = items.first(where: \.pending), item.phase == .waiting, let plan = plans[item.id] else { return }
        let id = item.id
        runningID = id
        runner = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.item(id)?.phase == .completed || self.item(id)?.phase == .cancelled {
                    try? FileManager.default.removeItem(at: plan.directory)
                }
                self.plans[id] = nil; self.runningID = nil; self.runner = nil; self.pump()
            }
            do {
                while !self.canStart() { try await Task.sleep(nanoseconds: 100_000_000) }
                try Task.checkCancellation()
                self.update(id) { $0.phase = .running }
                let result = try await plan.export { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.item(id)?.phase == .running else { return }
                        self.update(id) { $0.progress = max($0.progress, min(0.99, Double(value))) }
                    }
                }
                // The export operation checks cancellation before publication.
                // Once a file is published, keep the truthful completed result.
                self.outcomes[id] = .success(result)
                self.update(id) { $0.result = result; $0.progress = 1; $0.phase = .completed }
            } catch {
                self.fail(id, directory: plan.directory, error: error, cancelled: Task.isCancelled)
            }
        }
    }
}

@MainActor extension AppModel {
    @discardableResult func enqueuePreview(_ preview: BufferPreview, start: Double, end: Double,
                                           microphone: Bool, gains: AudioLevels) throws -> UUID {
        guard bufferPreview?.id == preview.id, !shuttingDown else { throw SpyError.message("Этот просмотр уже закрыт.") }
        let range = try PreviewRange(start: start, end: end, duration: preview.clip.duration)
        if let id = exportQueue.existing(sourceKey: preview.id.uuidString, range: range, microphone: microphone, gains: gains, includeCompleted: true) { return id }
        guard exportQueue.pendingCount < 12 else { throw SpyError.message("В очереди уже 12 фрагментов. Дождитесь сохранения или отмените ненужные.") }
        let folder = cacheURL.appendingPathComponent("queue-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let snapshot: SpySnapshot?
            let file: URL?
            if let source = preview.snapshot {
                let urls = try source.urls.map { url -> URL in
                    let target = folder.appendingPathComponent(url.lastPathComponent)
                    do { try FileManager.default.linkItem(at: url, to: target) }
                    catch { try FileManager.default.copyItem(at: url, to: target) }
                    return target
                }
                snapshot = SpySnapshot(directory: folder, urls: urls, requestedSeconds: source.requestedSeconds,
                    sourceIntervals: source.sourceIntervals, markers: source.markers, captureSessionID: source.captureSessionID)
                file = nil
            } else {
                let target = folder.appendingPathComponent("source.mov")
                do { try FileManager.default.linkItem(at: preview.clip.url, to: target) }
                catch { try FileManager.default.copyItem(at: preview.clip.url, to: target) }
                file = target; snapshot = nil
            }
            let markers = MarkerTimeline.selected((bufferPreview ?? preview).momentMarkers, start: range.start, end: range.end)
            let capturedLevels = preview.playback?.sourceLevels ?? AudioLevels()
            return exportQueue.enqueue(title: "Буфер · " + frameClock(range.duration), sourceKey: preview.id.uuidString, range: range, directory: folder, microphone: microphone, gains: gains) { [weak self] in
                let playback = try await snapshot.mapAsync { try await BufferPlayback.prepare($0, levels: capturedLevels) }
                return QueuedExportPlan(directory: folder) { [weak self] progress in
                    guard let self else { throw CancellationError() }
                    return try await self.publishQueued(range: range, folder: folder, markers: markers,
                        source: nil, previewID: preview.id, microphone: microphone, gains: gains,
                        session: preview.snapshot?.captureSessionID, recovery: preview.recoveryOrigin != nil) { output in
                            if let playback { try await playback.export(range: range, to: output, separateAudio: preview.separateAudio, editableMicrophone: true, microphoneEnabled: microphone, gains: gains, progress: progress) }
                            else if let file { try await EditableVideoAudio.load(url: file).export(to: output, start: range.start, end: range.end, microphoneEnabled: microphone, levels: gains, progress: progress) }
                        }
                }
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    @discardableResult func enqueueClip(_ clip: Clip, start: Double, end: Double, microphone: Bool, gains: AudioLevels) throws -> UUID {
        guard !shuttingDown else { throw SpyError.message("Spy закрывается.") }
        let range = try PreviewRange(start: start, end: end, duration: clip.duration)
        if let id = exportQueue.existing(sourceKey: clip.url.path, range: range, microphone: microphone, gains: gains) { return id }
        guard exportQueue.pendingCount < 12 else { throw SpyError.message("В очереди уже 12 фрагментов. Дождитесь сохранения или отмените ненужные.") }
        let folder = cacheURL.appendingPathComponent("queue-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("source.mov")
        let linked: Bool
        do { try FileManager.default.linkItem(at: clip.url, to: target); linked = true }
        catch { linked = false }
        let markers = MarkerTimeline.selected(metadata.get(clip.url).markers, start: range.start, end: range.end)
        return exportQueue.enqueue(title: clip.title, sourceKey: clip.url.path, range: range, directory: folder, microphone: microphone, gains: gains) { [weak self] in
            if !linked {
                let copy = Task.detached(priority: .utility) { try FileManager.default.copyItem(at: clip.url, to: target) }
                try await withTaskCancellationHandler { try await copy.value; try Task.checkCancellation() } onCancel: { copy.cancel() }
            }
            let source = try await EditableVideoAudio.load(url: target)
            return QueuedExportPlan(directory: folder) { [weak self] progress in
                guard let self else { throw CancellationError() }
                return try await self.publishQueued(range: range, folder: folder, markers: markers,
                    source: clip, previewID: nil, microphone: microphone, gains: gains) { output in
                        try await source.export(to: output, start: range.start, end: range.end, microphoneEnabled: microphone, levels: gains, progress: progress)
                    }
            }
        }
    }
    private func publishQueued(range: PreviewRange, folder: URL, markers: [ClipMarker], source: Clip?,
                               previewID: UUID?, microphone: Bool, gains: AudioLevels,
                               session: UUID? = nil, recovery: Bool = false,
                               export: (URL) async throws -> Void) async throws -> URL {
        guard libraryAvailable else { throw SpyError.message("Папка видео недоступна. Проверьте диск и повторите сохранение.") }
        let stamp = DateFormatter(); stamp.timeZone = SpyDates.timeZone; stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "Spy_Fragment_" + stamp.string(from: Date()) + "_" + String(UUID().uuidString.prefix(8))
        let output = libraryURL.appendingPathComponent(stem + ".mov").spyFileURL
        let partial = libraryURL.appendingPathComponent("." + stem + ".mov")
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try Task.checkCancellation()
            try await export(partial)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: output)
            storeMarkers(markers, for: output)
            if let source {
                var value = metadata.get(output); value.name = String(("Фрагмент · " + source.title).prefix(120)); value.favorite = source.favorite
                try? metadata.set(value, for: output)
                sessions.copied(output, from: source.url)
            } else if !recovery || session != nil { sessions.saved(output, session: session) }
            if bufferPreview?.id == previewID, gains == AudioLevels() {
                if microphone { bufferPreview?.savedRanges[range] = output }
                else { bufferPreview?.mutedSavedRanges[range] = output }
            }
            await reloadClips(); refreshDisk()
            message = "Фрагмент сохранён · " + frameClock(range.duration)
            journal.record(.info, "Очередь сохранения", "Сохранено \(frameClock(range.duration)) · \(output.lastPathComponent)")
            if let clip = clips.first(where: { $0.url == output }) { notifySaved(clip, title: "Фрагмент сохранён") }
            return output
        } catch {
            throw error
        }
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}
