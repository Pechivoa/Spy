import AppKit
import AVFoundation

@MainActor enum PreviewEditingTests {
    static func run(directory: URL) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("engine"))
        try engine.beginTest(seconds: 10, audio: true, microphone: true)
        for frame in 0..<120 {
            let pts = CMTime(value: 9000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let movie = directory.appendingPathComponent("source.mov")
        try await SpyExporter.export(try await engine.snapshot(seconds: 4), to: movie, separateAudio: true, editableMicrophone: true)
        let snapshot = try await engine.snapshot(seconds: 4)
        await engine.stop()
        let playback = try await BufferPlayback.prepare(snapshot, levels: AudioLevels(system: 0.8, microphone: 0.5))
        let bytes = Int64(try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        try await memory(model: model, movie: movie, bytes: bytes, duration: duration)
        try await timeline(movie: movie, duration: duration)
        try await ordering(directory: directory)
        let clip = Clip(url: snapshot.directory.appendingPathComponent("Buffer.virtual"), date: Date(), bytes: playback.bytes, duration: playback.duration, managed: false)
        let preview = BufferPreview(directory: snapshot.directory, clip: clip, capturedAt: Date(), playback: playback, snapshot: snapshot, separateAudio: true)
        model.bufferPreview = preview
        model.manualSaving = true
        let first = try model.enqueuePreview(preview, start: 0.25, end: 1.75, microphone: false, gains: AudioLevels(system: 0.6, microphone: 0.1))
        let cancelled = try model.enqueuePreview(preview, start: 0, end: 3, microphone: true, gains: AudioLevels())
        let last = try model.enqueuePreview(preview, start: 2, end: 3.5, microphone: true, gains: AudioLevels())
        try await wait("Queue prepares all frozen inputs") { model.exportQueue.items.allSatisfy { $0.phase == .waiting } }
        let deferred = AppProfile(bundleID: "example.queue-profile", name: "Профиль после очереди", settings: CaptureSettings(quality: .compact, minutes: 2, systemAudio: true, microphone: false, microphoneID: "", systemVolume: 0.5, microphoneVolume: 1, separateAudio: true))
        await model.applyProfile(deferred)
        try SelfTest.require(model.pendingProfile != nil, "Automatic profile changes wait for active exports")
        model.exportQueue.cancel(cancelled)
        model.bufferPreview?.audioGains = AudioLevels(system: 0, microphone: 0)
        model.manualSaving = false
        model.closeBufferPreview()
        try SelfTest.require(model.bufferPreview == nil && !FileManager.default.fileExists(atPath: snapshot.directory.path), "Closing viewer removes original pins while queued jobs own separate pins")
        let firstURL = try await model.exportQueue.result(first)
        let lastURL = try await model.exportQueue.result(last)
        try await wait("Deferred capture profile applies after queue drains") { model.pendingProfile == nil && model.minutes == 2 }
        try SelfTest.require(model.exportQueue.item(cancelled)?.phase == .cancelled && model.queuedExports == 0,
                             "Waiting cancellation does not prevent the following export; pending count returns to zero")
        try await decode(firstURL, seconds: 1.5, audioTracks: 1)
        try await decode(lastURL, seconds: 1.5, audioTracks: 2)
        let rms = try await systemRMS(firstURL)
        try SelfTest.require(rms > 0.035 && rms < 0.065, "Queued export freezes system gain before later UI changes: RMS \(rms)")
        print("PASS: two queued frozen-buffer fragments decode after viewer close/ring stop, cancelled middle job, frozen microphone/gains and no pending pins")
        print("PASS: deferred capture profile resumes after queue completion")
        await model.reloadClips()
        guard let saved = model.clips.first(where: { $0.url == lastURL }) else { throw SpyError.message("TEST FAILED: Published queue output is in the library") }
        model.manualSaving = true
        let failed = try model.enqueueClip(saved, start: 0, end: 1, microphone: true, gains: AudioLevels())
        try await wait("Library job pinned") { model.exportQueue.item(failed)?.phase == .waiting }
        let offline = directory.appendingPathComponent("OfflineLibrary")
        try FileManager.default.moveItem(at: model.libraryURL, to: offline)
        defer { if FileManager.default.fileExists(atPath: offline.path) { try? FileManager.default.moveItem(at: offline, to: model.libraryURL) } }
        model.manualSaving = false
        try await wait("Unavailable destination reports failure") { model.exportQueue.item(failed)?.phase == .failed }
        guard let retained = model.exportQueue.item(failed)?.retainedDirectory else { throw SpyError.message("TEST FAILED: Failed job retains its source") }
        try SelfTest.require(retained.lastPathComponent.hasPrefix("record-queue-") && FileManager.default.fileExists(atPath: retained.appendingPathComponent("source.mov").path), "Failed export keeps a recoverable source")
        try FileManager.default.moveItem(at: offline, to: model.libraryURL)
        let unfinished = try FileManager.default.contentsOfDirectory(at: model.libraryURL, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".Spy_Fragment_") }
        try SelfTest.require(unfinished.isEmpty, "No orphaned partial exports remain")
        print("PASS: destination failure retains a recovery source and does not publish partial files")
        let silent = directory.appendingPathComponent("cancelled-real.mov")
        let source = try await EditableVideoAudio.load(url: movie)
        let task = Task { try await source.export(to: silent, start: 0, end: 3, microphoneEnabled: false, levels: AudioLevels()) }
        task.cancel()
        do { try await task.value; throw SpyError.message("TEST FAILED: Cancelled media export must not finish") }
        catch is CancellationError { }
        try SelfTest.require(!FileManager.default.fileExists(atPath: silent.path), "Cancellation cleans the actual AVAssetWriter output")
        print("PASS: real media export cancellation removes its partial file")
        let final = try model.enqueueClip(saved, start: 0, end: 1, microphone: true, gains: AudioLevels())
        let closed = await model.shutdown()
        try SelfTest.require(closed && model.exportQueue.item(final)?.phase == .completed && model.queuedExports == 0,
                             "Model shutdown waits for queued work before closing its services")
        print("PASS: orderly shutdown drains the queue")
    }

    private static func memory(model: AppModel, movie: URL, bytes: Int64, duration: Double) async throws {
        let old = try JSONDecoder().decode(ClipMetadata.self, from: Data("{\"name\":\"Старое имя\",\"favorite\":true,\"markers\":[]}".utf8))
        try SelfTest.require(old.name == "Старое имя" && old.favorite && old.playback == nil, "Existing metadata remains compatible")
        try model.metadata.set(ClipMetadata(name: "Имя сохранено", favorite: true), for: movie)
        let controls = try await VideoAudioControls.load(url: movie)
        let player = AVPlayer(playerItem: controls.item); player.isMuted = true
        let editor = PlayerEditingState()
        editor.configure(player: player, duration: duration, audioControls: controls,
            onCheckpoint: { model.rememberPlayback($0, for: movie, bytes: bytes, duration: duration) })
        editor.setRange(start: 0.5, end: 2.5); editor.seek(1.25)
        try await wait("Remembered seek resolves") { !editor.isSeeking }
        editor.setPlaybackRate(1.5); editor.setMicrophoneEnabled(false); controls.systemGain = 0.35; controls.microphoneGain = 0.65
        editor.checkpoint(); editor.detach()
        let reloaded = LibraryMetadata(url: model.metadata.url).get(movie)
        guard let memory = reloaded.playback?.validated(bytes: bytes, duration: duration) else { throw SpyError.message("TEST FAILED: Bookmark survives a new metadata instance") }
        try SelfTest.require(reloaded.name == "Имя сохранено" && reloaded.favorite && abs(memory.position - 1.25) < 0.04 && memory.start == 0.5 && memory.end == 2.5 && memory.rate == 1.5 && !memory.microphone && memory.systemGain == 0.35,
                             "Position, range, rate and soundtrack persist without replacing name/favorite")
        try SelfTest.require(memory.validated(bytes: bytes + 1, duration: duration) == nil && memory.validated(bytes: bytes, duration: duration + 1) == nil,
                             "Replaced source files reject stale bookmarks")
        let nextSound = try await VideoAudioControls.load(url: movie)
        let nextPlayer = AVPlayer(playerItem: nextSound.item); nextPlayer.isMuted = true
        editor.configure(player: nextPlayer, duration: duration, audioControls: nextSound, bookmark: memory)
        try await wait("Reopened player restores source position") { !editor.isSeeking }
        try SelfTest.require(abs(editor.currentTime - 1.25) < 0.04 && editor.rangeStart == 0.5 && editor.rangeEnd == 2.5 && editor.playbackRate == 1.5 && !nextSound.microphoneEnabled && nextSound.systemGain == 0.35,
                             "Reopening applies the saved selection, rate and actual audio mix")
        editor.togglePlayback()
        try await wait("Selected speed reaches the actual player") { abs(nextPlayer.rate - 1.5) < 0.01 }
        nextPlayer.pause(); nextPlayer.play()
        try await wait("Native AVPlayer controls retain the chosen playback rate") { abs(nextPlayer.rate - 1.5) < 0.01 }
        editor.togglePlayback(); editor.detach(); player.pause(); nextPlayer.pause()
        print("PASS: backwards-compatible persistent playback, source validation, real seek/rate/audio restore")
    }
    private static func timeline(movie: URL, duration: Double) async throws {
        let view = TimelineViewport(duration: 1800, zoom: 16, center: 1799)
        try SelfTest.require(view.end == 1800 && view.start >= 0 && view.time(fraction: -1) == view.start && view.time(fraction: 2) == view.end,
                             "Zoomed timeline clamps at both source boundaries")
        let asset = AVURLAsset(url: movie)
        let thumbs = try await TimelineThumbnailGenerator.generate(asset: asset, duration: duration, count: 8, start: 1, end: 2)
        try SelfTest.require(thumbs.count == 8 && thumbs.allSatisfy { $0.seconds >= 1 && $0.seconds < 2 && $0.image != nil }, "Zoomed filmstrip decodes the visible interval")
        let hover = TimelineHoverLoader()
        hover.request(asset: asset, time: 0.5); hover.request(asset: asset, time: 2)
        try await wait("Hover resolves latest frame") { hover.image != nil }
        try SelfTest.require(abs(hover.actualTime - 2) < 0.1, "Rapid hover never publishes a stale frame")
        hover.cancel(); try await Task.sleep(nanoseconds: 150_000_000)
        try SelfTest.require(hover.image == nil, "Leaving timeline cancels the thumbnail decoder")
        print("PASS: zoom bounds, real visible-interval thumbnails, cancellable and non-stale hover frame")
    }
    private static func ordering(directory: URL) async throws {
        let queue = ExportQueueController()
        let range = try PreviewRange(start: 0, end: 1, duration: 1)
        var order: [Int] = []
        let firstDir = directory.appendingPathComponent("first")
        let secondDir = directory.appendingPathComponent("second")
        for folder in [firstDir, secondDir] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let first = queue.enqueue(title: "first", sourceKey: "first", range: range, directory: firstDir) {
            try await Task.sleep(nanoseconds: 80_000_000)
            return QueuedExportPlan(directory: firstDir) { progress in order.append(1); progress(1); return directory.appendingPathComponent("first.mov") }
        }
        let second = queue.enqueue(title: "second", sourceKey: "second", range: range, directory: secondDir) {
            QueuedExportPlan(directory: secondDir) { progress in order.append(2); progress(1); return directory.appendingPathComponent("second.mov") }
        }
        _ = try await queue.result(first); _ = try await queue.result(second)
        try SelfTest.require(order == [1, 2], "Preparation speed does not reorder exports")
        let activeDir = directory.appendingPathComponent("cancel-active")
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        let active = queue.enqueue(title: "active", sourceKey: "active", range: range, directory: activeDir) {
            QueuedExportPlan(directory: activeDir) { progress in progress(0.2); try await Task.sleep(nanoseconds: 3_000_000_000); return directory.appendingPathComponent("unexpected.mov") }
        }
        try await wait("Active export reports progress") { (queue.item(active)?.progress ?? 0) > 0 }
        queue.cancel(active)
        do { _ = try await queue.result(active); throw SpyError.message("TEST FAILED: Active cancellation must throw") } catch is CancellationError { }
        try SelfTest.require(!FileManager.default.fileExists(atPath: activeDir.path), "Active cancellation releases its own pinned files")
        print("PASS: FIFO queue despite asynchronous preparation, real progress state, active cancellation and pin cleanup")
    }
    private static func decode(_ url: URL, seconds: Double, audioTracks: Int) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("TEST FAILED: Export has no video") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]); reader.add(output)
        try SelfTest.require(reader.startReading(), "Queued movie starts decoding")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        try SelfTest.require(reader.status == .completed && frames >= 43 && abs(duration - seconds) < 0.05 && audio.count == audioTracks,
                             "Queued movie completely decodes with exact selection and frozen soundtrack")
    }
    private static func systemRMS(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url); let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]); reader.add(output)
        guard reader.startReading() else { return 0 }
        var sum = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() { sum += Double(AudioMeter.rms(sample)); count += 1 }
        return sum / Double(max(1, count))
    }
    private static func wait(_ title: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw SpyError.message("TEST FAILED: " + title)
    }
}
