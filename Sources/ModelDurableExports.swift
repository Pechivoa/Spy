import Foundation
import AVFoundation

@MainActor extension AppModel {
    func configureExportQueue() throws {
        try exportQueue.configureDurability(root: cacheURL) { [weak self] record, directory in
            guard let self else { throw CancellationError() }
            return try await self.prepareDurableExport(record, directory: directory)
        }
    }
    @discardableResult func enqueuePreview(_ preview: BufferPreview, start: Double, end: Double,
                                           microphone: Bool, gains: AudioLevels) throws -> UUID {
        guard bufferPreview?.id == preview.id, !shuttingDown else { throw SpyError.message("Этот просмотр уже закрыт.") }
        try configureExportQueue()
        let range = try PreviewRange(start: start, end: end, duration: preview.clip.duration)
        if let id = exportQueue.existing(sourceKey: preview.id.uuidString, range: range, microphone: microphone, gains: gains, includeCompleted: true) { return id }
        guard exportQueue.pendingCount < 12 else { throw SpyError.message("В очереди уже 12 фрагментов. Возобновите сохранение или отмените ненужные.") }
        var record = makeExportJob(title: "Буфер · " + frameClock(range.duration), sourceKey: preview.id.uuidString,
            range: range, duration: preview.clip.duration, microphone: microphone, gains: gains)
        record.previewID = preview.id; record.session = preview.snapshot?.captureSessionID
        record.recovery = preview.recoveryOrigin != nil; record.separateAudio = preview.separateAudio
        record.markers = MarkerTimeline.selected((bufferPreview ?? preview).momentMarkers, start: range.start, end: range.end)
        let captured = preview.playback?.sourceLevels ?? AudioLevels()
        record.capturedSystemGain = captured.system; record.capturedMicrophoneGain = captured.microphone
        let folder = cacheURL.appendingPathComponent("queue-" + record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            if let snapshot = preview.snapshot {
                record.files = snapshot.urls.map(\.lastPathComponent)
                record.requestedSeconds = snapshot.requestedSeconds
                record.intervals = snapshot.sourceIntervals; record.replayMarkers = snapshot.markers
                for url in snapshot.urls {
                    let target = folder.appendingPathComponent(url.lastPathComponent)
                    do { try FileManager.default.linkItem(at: url, to: target) }
                    catch { try FileManager.default.copyItem(at: url, to: target) }
                }
            } else { try pinFile(preview.clip.url, into: folder, record: &record) }
            return try exportQueue.enqueueDurable(record, directory: folder)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    @discardableResult func enqueueClip(_ clip: Clip, start: Double, end: Double, microphone: Bool, gains: AudioLevels) throws -> UUID {
        guard !shuttingDown else { throw SpyError.message("Spy закрывается.") }
        try configureExportQueue()
        let range = try PreviewRange(start: start, end: end, duration: clip.duration)
        if let id = exportQueue.existing(sourceKey: clip.url.path, range: range, microphone: microphone, gains: gains) { return id }
        guard exportQueue.pendingCount < 12 else { throw SpyError.message("В очереди уже 12 фрагментов. Возобновите сохранение или отмените ненужные.") }
        var record = makeExportJob(title: clip.title, sourceKey: clip.url.path, range: range,
            duration: clip.duration, microphone: microphone, gains: gains)
        record.originalTitle = clip.title; record.originalFavorite = clip.favorite
        record.markers = MarkerTimeline.selected(metadata.get(clip.url).markers, start: range.start, end: range.end)
        let folder = cacheURL.appendingPathComponent("queue-" + record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try pinFile(clip.url, into: folder, record: &record)
            return try exportQueue.enqueueDurable(record, directory: folder)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    private func makeExportJob(title: String, sourceKey: String, range: PreviewRange, duration: Double,
                               microphone: Bool, gains: AudioLevels) -> DurableExportJob {
        var record = DurableExportJob(title: title, sourceKey: sourceKey, start: range.start, end: range.end,
            duration: duration, microphone: microphone, systemGain: gains.system, microphoneGain: gains.microphone,
            files: ["source.mov"], destination: libraryURL, outputName: "")
        let stamp = DateFormatter(); stamp.timeZone = SpyDates.timeZone; stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        record.outputName = "Spy_Fragment_" + stamp.string(from: record.createdAt) + "_" + record.id.uuidString + ".mov"
        return record
    }
    private func pinFile(_ url: URL, into directory: URL, record: inout DurableExportJob) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SpyError.message("Исходное видео недоступно или заменено ссылкой.") }
        record.originalURL = url; record.originalBytes = Int64(values.fileSize ?? 0); record.originalModified = values.contentModificationDate
        do { try FileManager.default.linkItem(at: url, to: directory.appendingPathComponent("source.mov")) }
        catch { /* Cross-volume copies are atomic and cancellable in prepare. */ }
    }
    private func prepareDurableExport(_ record: DurableExportJob, directory: URL) async throws -> QueuedExportPlan {
        try record.validate(directory: directory)
        // A receipt is durable before the atomic rename. After a process crash,
        // validate and reuse that exact output rather than generating a duplicate.
        if FileManager.default.fileExists(atPath: record.output.path) {
            guard let receipt = record.receipt, try await receipt.matches(record.output) else {
                throw SpyError.message("Файл назначения уже существует, но не подтверждён этой задачей. Он не будет перезаписан: " + record.output.path)
            }
            return QueuedExportPlan(directory: directory) { [weak self] _ in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                await self.finishDurablePublication(record)
                return record.output
            }
        }
        if record.requestedSeconds == nil {
            let source = directory.appendingPathComponent("source.mov")
            if !FileManager.default.fileExists(atPath: source.path) {
                guard let original = record.originalURL else { throw SpyError.message("Нет закреплённого исходника. Данные задачи сохранены.") }
                let values = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == record.originalBytes,
                      values.contentModificationDate == record.originalModified else { throw SpyError.message("Исходное видео изменилось или недоступно. Прежняя задача сохранена.") }
                let partial = directory.appendingPathComponent(".source-copy.partial")
                let task = Task.detached(priority: .utility) {
                    if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
                    do { try FileManager.default.copyItem(at: original, to: partial); try Task.checkCancellation(); try FileManager.default.moveItem(at: partial, to: source) }
                    catch { try? FileManager.default.removeItem(at: partial); throw error }
                }
                try await withTaskCancellationHandler { try await task.value; try Task.checkCancellation() } onCancel: { task.cancel() }
            }
        }
        for name in record.files {
            let file = directory.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw SpyError.message("Закреплённый исходник недоступен: " + name)
            }
        }
        let playback: BufferPlayback?
        let source: EditableVideoAudio?
        if let snapshot = record.snapshot(in: directory) {
            playback = try await BufferPlayback.prepare(snapshot, levels: AudioLevels(system: record.capturedSystemGain, microphone: record.capturedMicrophoneGain))
            source = nil
            _ = try PreviewRange(start: record.start, end: record.end, duration: playback!.duration)
        } else {
            playback = nil; source = try await EditableVideoAudio.load(url: directory.appendingPathComponent("source.mov"))
            let duration = try await source!.asset.load(.duration).seconds
            _ = try PreviewRange(start: record.start, end: record.end, duration: duration)
        }
        return QueuedExportPlan(directory: directory) { [weak self] progress in
            guard let self else { throw CancellationError() }
            guard self.libraryAvailable, self.libraryURL.spyFileURL == record.destination.spyFileURL else {
                throw SpyError.message("Папка назначения недоступна или изменилась. Восстановите её в настройках и повторите задачу.")
            }
            guard !FileManager.default.fileExists(atPath: record.output.path) else { throw SpyError.message("Файл назначения уже существует и не будет перезаписан.") }
            if FileManager.default.fileExists(atPath: record.partial.path) {
                guard (try record.partial.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw SpyError.message("Временный файл заменён ссылкой.") }
                try FileManager.default.removeItem(at: record.partial)
            }
            defer { try? FileManager.default.removeItem(at: record.partial) }
            if let playback {
                try await playback.export(range: try record.range, to: record.partial, separateAudio: record.separateAudio,
                    editableMicrophone: true, microphoneEnabled: record.microphone, gains: record.gains, progress: progress)
            } else if let source {
                try await source.export(to: record.partial, start: record.start, end: record.end,
                    microphoneEnabled: record.microphone, levels: record.gains, progress: progress)
            }
            try Task.checkCancellation()
            let receipt = try await ExportPublicationReceipt.measure(record.partial)
            let handle = try FileHandle(forWritingTo: record.partial)
            do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
            try self.exportQueue.checkpointPublication(record.id, receipt: receipt)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: record.partial, to: record.output)
            await self.finishDurablePublication(record)
            return record.output
        }
    }
    private func finishDurablePublication(_ record: DurableExportJob) async {
        storeMarkers(record.markers, for: record.output)
        if let title = record.originalTitle {
            var value = metadata.get(record.output); value.name = String(("Фрагмент · " + title).prefix(120)); value.favorite = record.originalFavorite
            try? metadata.set(value, for: record.output)
            if let url = record.originalURL {
                sessions.copied(record.output, from: url)
            }
        } else if !record.recovery || record.session != nil { sessions.saved(record.output, session: record.session) }
        if bufferPreview?.id == record.previewID, record.gains == AudioLevels(), let range = try? record.range {
            if record.microphone { bufferPreview?.savedRanges[range] = record.output }
            else { bufferPreview?.mutedSavedRanges[range] = record.output }
        }
        await reloadClips(); refreshDisk()
        message = "Фрагмент сохранён · " + frameClock(record.end - record.start)
        journal.record(.info, "Очередь сохранения", "Сохранено " + record.output.lastPathComponent)
        if let clip = clips.first(where: { $0.url == record.output }) { notifySaved(clip, title: "Фрагмент сохранён") }
    }
}
