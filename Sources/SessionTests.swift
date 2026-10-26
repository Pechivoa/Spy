import AppKit
import AVFoundation

@MainActor enum SessionTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Spy.SessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var roots: [URL] = []
        defer {
            defaults.removePersistentDomain(forName: suite)
            for root in roots { try? FileManager.default.removeItem(at: root) }
        }
        func model(screen: Bool = true) -> AppModel {
            let value = AppModel(preview: true, defaults: defaults, captureAccess: CaptureAccess(screenAllowed: { screen }, microphoneStatus: { .authorized }, requestMicrophone: { false }))
            roots.append(value.libraryURL.deletingLastPathComponent())
            value.captureStartOverride = { [weak value] config in
                guard let value else { throw CancellationError() }
                try value.engine.beginTest(seconds: config.seconds, audio: config.audio)
                for frame in 0..<60 {
                    let pts = CMTime(value: 60_000 + Int64(frame), timescale: 30)
                    value.engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                    if config.audio { value.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts)) }
                    try await Task.sleep(nanoseconds: 8_000_000)
                }
                try await value.engine.waitForFirstFrame(timeout: 0.5)
            }
            return value
        }

        let first = model()
        first.minutes = 0.5; first.quality = .smooth; first.systemVolume = 0.65
        await first.start()
        try SelfTest.require(first.lastReplayEnabled && defaults.bool(forKey: "lastReplayEnabled"), "Successful replay persists its enabled state immediately")
        let quit = await first.shutdown()
        try SelfTest.require(quit && !first.recording && first.lastReplayEnabled && first.clips.count == 1, "Quit saves replay before stopping and retains restart intent")
        let saved = first.clips[0]
        try SelfTest.require(saved.url.lastPathComponent.hasPrefix("Spy_Session_") && abs(saved.duration - 2) < 0.06, "Autosaved session includes all buffered frames at the exact duration")
        let asset = AVURLAsset(url: saved.url)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try SelfTest.require(reader.startReading(), "Autosaved movie opens for decoding")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        try SelfTest.require(reader.status == .completed && frames == 60, "Autosaved movie decodes every original frame")
        try FileManager.default.copyItem(at: saved.url, to: directory.appendingPathComponent("autosaved-session.mov"))
        print("PASS: enabled state persistence, quit snapshot, exact duration and complete video decode")

        let resumed = model()
        try SelfTest.require(resumed.minutes == 0.5 && resumed.quality == .smooth && resumed.systemVolume == 0.65, "Last capture settings survive a new app model")
        await resumed.restoreLastSession()
        try SelfTest.require(resumed.recording && resumed.lastReplayEnabled, "Reopening resumes enabled replay without a manual button press")
        await resumed.stop()
        try SelfTest.require(!defaults.bool(forKey: "lastReplayEnabled"), "Explicit stop clears restart intent")
        await resumed.shutdown()
        let stopped = model()
        await stopped.restoreLastSession()
        try SelfTest.require(!stopped.recording && stopped.clips.isEmpty, "Explicitly disabled replay stays disabled on reopening")
        await stopped.start(forManual: true)
        try SelfTest.require(stopped.recording && !stopped.lastReplayEnabled, "Manual-only capture never enables replay restore")
        await stopped.shutdown()
        try SelfTest.require(stopped.clips.isEmpty, "Manual-only engine is not accidentally autosaved as replay")
        print("PASS: restored settings and replay, explicit off remains off, manual-only capture stays separate")

        let broken = model()
        await broken.start()
        await broken.handleCaptureFailure("Synthetic stream interruption")
        try SelfTest.require(!broken.recording && broken.lastReplayEnabled, "Unexpected stream failure retains user replay intent")
        let denied = model(screen: false)
        await denied.restoreLastSession()
        try SelfTest.require(!denied.recording && denied.lastReplayEnabled && denied.needsPermission, "Unavailable permission blocks restore visibly without discarding intent")
        let optedOut = model(); optedOut.rememberReplay = false
        await optedOut.restoreLastSession()
        try SelfTest.require(!optedOut.recording, "Restore can be disabled independently of autosave")
        optedOut.rememberReplay = true
        print("PASS: interrupted capture preserves intent, denied restore is honest, restore opt-out")

        let disconnected = model()
        await disconnected.start()
        try FileManager.default.removeItem(at: disconnected.libraryURL)
        let disconnectedQuit = await disconnected.shutdown()
        disconnected.refreshRecoveryFolders()
        try SelfTest.require(disconnectedQuit && disconnected.recoveryFolders.count == 1 && disconnected.lastReplayEnabled, "Unavailable library retains replay segments for recovery after quit")
        let folder = disconnected.recoveryFolders[0]
        let snapshot = try await MediaSharing.recoverySnapshot(directory: folder)
        try SelfTest.require(abs(snapshot.requestedSeconds - 2) < 0.06, "Recovery restores session snapshot duration")
        try FileManager.default.createDirectory(at: disconnected.libraryURL, withIntermediateDirectories: true)
        await disconnected.recoverRecording(folder)
        try SelfTest.require(disconnected.clips.count == 1 && disconnected.recoveryFolders.isEmpty, "Connecting the library allows lossless recovery and clears retained segments")
        try disconnected.journal.export(to: directory.appendingPathComponent("session-journal.txt"))
        print("PASS: autosave failure retains segments, restored disk recovers video, journal export")

        let noVideo = model(); noVideo.saveBufferOnExit = false
        await noVideo.start(); await noVideo.shutdown()
        try SelfTest.require(noVideo.clips.isEmpty && noVideo.lastReplayEnabled, "Autosave opt-out still remembers enabled replay")
        print("PASS: autosave opt-out retains independent replay restoration")
    }
}
