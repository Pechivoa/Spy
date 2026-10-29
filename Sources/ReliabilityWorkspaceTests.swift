import AppKit
import AVFoundation
import CryptoKit

@MainActor enum ReliabilityWorkspaceTests {
    private static func require(_ value: Bool, _ message: String) throws { try SelfTest.require(value, message) }
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sample = CaptureTelemetry(began: 0, screen: 1, encoded: 20, system: 20, microphone: 20, idle: true, wantsSystem: true, wantsMicrophone: true)
        try require(CaptureHealth.evaluate(sample, now: 20, active: true, paused: false).isEmpty, "Static desktop reported as idle must stay healthy while encoded frames and audio packets arrive")
        sample.idle = false
        try require(CaptureHealth.evaluate(sample, now: 20, active: true, paused: false).count == 1, "A source heartbeat gap is distinguished from encoder progress")
        sample.encoded = 1; sample.system = nil; sample.microphone = nil
        try require(CaptureHealth.evaluate(sample, now: 20, active: true, paused: false).count == 3, "Stalled encoding and missing audio packets are visible independently")
        try require(CaptureHealth.evaluate(sample, now: 20, active: true, paused: true).isEmpty, "Privacy pause cannot become a false recording alarm")
        let health = CaptureHealth(); var changes = 0; health.onChange = { _ in changes += 1 }; health.sample = sample
        health.check(active: true, paused: false, now: 20); health.check(active: true, paused: false, now: 21)
        try require(changes == 1, "A persistent fault must not spam the journal")
        health.sample = CaptureTelemetry(began: 22); health.check(active: true, paused: false, now: 22)
        try require(changes == 2 && health.warnings.isEmpty, "Recovered recording clears its health warning")
        let newSession = UUID(); health.reset(session: newSession)
        health.receive(CaptureTelemetry(session: UUID(), began: 0))
        try require(health.sample.session == newSession, "Late telemetry from an older capture cannot overwrite the current session")
        health.sample = sample; health.snooze(now: 30); health.check(active: true, paused: false, now: 31)
        try require(health.warnings.isEmpty, "Resuming privacy pause gives streams a fresh grace interval")
        print("PASS: static/idle screen, encoder stall, independent audio packet loss, privacy grace, stale-session rejection and warning deduplication")

        let historyURL = directory.appendingPathComponent("Sessions.json"), id = UUID()
        let history = SessionHistory(url: historyURL)
        let began = Date(timeIntervalSince1970: 1_000_000)
        history.begin(id: id, source: "Fixture", at: began)
        history.event("pause", "Privacy", at: began.addingTimeInterval(10))
        history.event("resume", "Resume", at: began.addingTimeInterval(15))
        history.touch(at: began.addingTimeInterval(60))
        let missingMovie = directory.appendingPathComponent("later-moved.mov")
        history.saved(missingMovie, session: id)
        history.saved(directory.appendingPathComponent("unrelated.mov"), session: UUID())
        let restarted = SessionHistory(url: historyURL)
        try require(restarted.sessions.count == 1 && restarted.sessions[0].ended == began.addingTimeInterval(60), "Interrupted history closes at its last heartbeat after process recreation")
        try require(restarted.sessions[0].videos.map { $0.spyFileURL.path } == [missingMovie.spyFileURL.path] && restarted.sessions[0].events.last?.kind == "failure", "Unknown session IDs cannot attach videos to a different session")
        let broken = directory.appendingPathComponent("BrokenSessions.json"), brokenBytes = Data("broken history".utf8)
        try brokenBytes.write(to: broken)
        let corrupt = SessionHistory(url: broken); corrupt.begin(id: UUID(), source: "No overwrite")
        try require(try Data(contentsOf: broken) == brokenBytes && corrupt.persistenceIssue != nil, "Damaged history is reported and retained intact")
        print("PASS: durable session timeline, pause/resume, crash heartbeat, missing-video references and corrupt-history preservation")

        let model = AppModel(preview: true)
        let recovery = model.cacheURL.appendingPathComponent("record-replay-test-" + UUID().uuidString)
        let encoder = SpyEngine(cacheRoot: directory.appendingPathComponent("encoder"))
        try encoder.beginTest(seconds: 6, audio: true, microphone: true)
        for i in 0..<96 {
            let pts = CMTime(value: 9000 + Int64(i), timescale: 30)
            encoder.testFrame(try SelfTest.pixel(frame: i), at: pts)
            encoder.testAudio(try SelfTest.audio(frame: i, pts: pts, frequency: 440))
            encoder.testAudio(try SelfTest.audio(frame: i, pts: pts, channels: 1, frequency: 880), microphone: true)
            try await Task.sleep(nanoseconds: 4_000_000)
        }
        let snapshot = try await encoder.snapshot(seconds: 3)
        let baseline = directory.appendingPathComponent("baseline.mov")
        try await SpyExporter.export(snapshot, to: baseline, editableMicrophone: true, removeSnapshot: false)
        await encoder.stop()
        try FileManager.default.moveItem(at: snapshot.directory, to: recovery)
        let before = try hashes(in: recovery)
        model.refreshRecoveryFolders()
        let summary = await RecoverySummary.load(recovery)
        try require(summary.count > 0 && summary.seconds > 2 && summary.image != nil && summary.bytes > 0, "Recovery inventory reads real segment duration, size and thumbnail")
        await model.previewRecovery(recovery)
        guard let preview = model.bufferPreview, let playback = preview.playback else { throw SpyError.message("TEST FAILED: recovery preview was not prepared: " + (model.error ?? "unknown")) }
        try require(preview.recoveryOrigin == recovery && playback.duration > 2, "Recovery preview uses an independent immutable pin")
        let sound = playback.videoAudioControls()
        let lanes = try await AudioWaveform.load(asset: sound.item.asset, microphoneIDs: sound.microphoneIDs)
        try require(lanes.count == 2 && lanes.contains(where: { $0.microphone }) && lanes.allSatisfy { !$0.silent && $0.sampleCount > 40_000 }, "Real separate AAC system/mic tracks decode into bounded waveform bins")
        sound.systemGain = 0; sound.microphoneGain = 0.3
        model.bufferPreview?.audioGains = sound.gains
        let lowered = try await model.saveBufferPreview(preview, start: 0.5, end: 1.5)
        let loaded = try await VideoAudioControls.load(url: lowered)
        let resultLanes = try await AudioWaveform.load(asset: loaded.item.asset, microphoneIDs: loaded.microphoneIDs)
        let systemPeak = resultLanes.first(where: { !$0.microphone })?.peaks.max() ?? 99
        let micPeak = resultLanes.first(where: { $0.microphone })?.peaks.max() ?? 99
        try require(systemPeak < 0.005 && micPeak > 0.015 && micPeak < 0.09, "Gain changes reach the exported AAC tracks without leaking muted system audio")
        let mp4 = directory.appendingPathComponent("mixed-gains.mp4")
        try await MediaSharing.exportMP4(source: baseline, to: mp4, levels: AudioLevels(system: 0, microphone: 0.3))
        let mixed = try await AudioWaveform.load(asset: AVURLAsset(url: mp4), microphoneIDs: [])
        try require(mixed.count == 1 && (mixed[0].peaks.max() ?? 99) > 0.015 && (mixed[0].peaks.max() ?? 99) < 0.09,
            "The MP4 export mixes only the chosen gains into its single AAC track")
        model.bufferPreview?.audioGains = AudioLevels()
        let normal = try await model.saveBufferPreview(preview, start: 0.5, end: 1.5)
        try require(normal != lowered, "Changing mixer gains cannot reuse a previously saved export with different sound")
        let cancelled = Task { try await AudioWaveform.load(asset: loaded.item.asset, microphoneIDs: loaded.microphoneIDs) }; cancelled.cancel()
        do { _ = try await cancelled.value; throw SpyError.message("TEST FAILED: waveform cancellation ignored") } catch is CancellationError {}
        model.closeBufferPreview()
        try require(try hashes(in: recovery) == before && !FileManager.default.fileExists(atPath: preview.directory.path), "Closing or exporting a recovery preview never changes original segment bytes")
        print("PASS: real recovery thumbnails/pinned playback, separate waveforms, microphone/system gains in actual exports, cancellation and immutable originals")

        let previewCache = model.cacheURL.appendingPathComponent("preview-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: previewCache, withIntermediateDirectories: false)
        try Data(repeating: 3, count: 1024).write(to: previewCache.appendingPathComponent("owned.bin"))
        let outside = directory.appendingPathComponent("outside.bin"); try Data("do not touch".utf8).write(to: outside)
        let link = model.cacheURL.appendingPathComponent("record-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let entries = SpyCacheInventory.scan(cache: model.cacheURL, updates: model.updateStorageURL)
        try require(entries.contains { $0.url.resolvingSymlinksInPath().path == recovery.resolvingSymlinksInPath().path && $0.kind == .recovery && $0.removable } && !entries.contains { $0.url == link }, "Inventory accounts recovery data and never follows a symlink")
        try require(try SpyCacheInventory.validateRemoval(previewCache, cache: model.cacheURL, updates: model.updateStorageURL).bytes == 1024, "Only recognized direct child data can enter cleanup")
        var denied = false
        do { _ = try SpyCacheInventory.validateRemoval(directory, cache: model.cacheURL, updates: model.updateStorageURL) } catch { denied = true }
        try require(denied && FileManager.default.fileExists(atPath: outside.path), "Outside folders cannot be deleted through cache cleanup")
        try model.engine.beginTest(seconds: 10)
        var liveDenied = false
        do { _ = try SpyCacheInventory.validateRemoval(previewCache, cache: model.cacheURL, updates: model.updateStorageURL) } catch { liveDenied = true }
        try require(liveDenied, "A live capture manifest prevents cleanup, including another process's pins")
        await model.engine.stop()
        print("PASS: cache categories/weights, symlink and traversal protection, active-capture lock and untouched external files")
    }
    private static func hashes(in directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            result[file.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}
