import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit

@MainActor enum ApplicationAudioTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let own = "local.spy.mac"
        let allowed = ApplicationAudioPolicy.allowedBundleIDs(selected: ["COM.EXAMPLE.GAME", "com.example.private", own], excluded: ["com.example.private"], ownBundleID: own)
        try SelfTest.require(allowed == ["com.example.game"], "Application audio normalizes IDs and respects privacy/own-process exclusions")
        try SelfTest.require(ApplicationAudioPolicy.allowedBundleIDs(selected: [], excluded: []).isEmpty,
            "An empty application selection cannot broaden into all system audio")

        let suite = "Spy.ApplicationAudio.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ApplicationAudioSelection(defaults: defaults)
        try SelfTest.require(settings.mode == .all && settings.bundleIDs.isEmpty, "Existing installations retain all-system-audio behavior")
        settings.mode = .selected
        settings.setSelected(PrivacyApplication(bundleID: "COM.EXAMPLE.GAME", name: "Synthetic game"), true)
        settings.setSelected(PrivacyApplication(bundleID: own, name: "Spy"), true)
        let reloaded = ApplicationAudioSelection(defaults: defaults)
        try SelfTest.require(reloaded.mode == .selected && reloaded.bundleIDs == ["com.example.game"], "Selected application audio survives restart and never includes Spy")
        defaults.set(Data("bad-json".utf8), forKey: "applicationAudioApplications")
        let malformed = ApplicationAudioSelection(defaults: defaults)
        try SelfTest.require(malformed.mode == .selected && malformed.bundleIDs.isEmpty, "Damaged selection preferences retain silence instead of falling back to all apps")
        defaults.set("unknown-mode", forKey: "applicationAudioMode")
        let unknownMode = ApplicationAudioSelection(defaults: defaults)
        try SelfTest.require(unknownMode.mode == .selected && unknownMode.bundleIDs.isEmpty, "An unrecognized future/corrupt mode cannot broaden system audio")
        print("PASS: application audio defaults, persistence, normalization, privacy exclusion and fail-closed empty/corrupt selection")

        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache"))
        var failures: [String] = []
        engine.onFailure = { failures.append($0) }
        try engine.beginTest(seconds: 30, audio: true, microphone: true)
        let main = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let selected = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let obsolete = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        engine.testAdoptStream(main)
        engine.testAdoptApplicationAudioStream(selected)
        for frame in 0..<90 {
            let pts = CMTime(value: 12_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            let chosen = try SelfTest.audio(frame: frame, pts: pts, frequency: 440)
            let unwanted = try SelfTest.audio(frame: frame, pts: pts, frequency: 880)
            let old = try SelfTest.audio(frame: frame, pts: pts, frequency: 1400)
            let mic = try SelfTest.audio(frame: frame, pts: pts, rate: 44_100, channels: 1, frequency: 997)
            engine.queue.sync {
                engine.stream(main, didOutputSampleBuffer: unwanted, of: .audio)
                engine.stream(obsolete, didOutputSampleBuffer: old, of: .audio)
                engine.stream(selected, didOutputSampleBuffer: chosen, of: .audio)
                if #available(macOS 15.0, *) { engine.stream(main, didOutputSampleBuffer: mic, of: .microphone) }
            }
            if #available(macOS 15.0, *) {} else { engine.testAudio(mic, microphone: true) }
            try await Task.sleep(nanoseconds: 7_000_000)
        }
        engine.stream(obsolete, didStopWithError: SpyError.message("Late audio callback"))
        _ = engine.testStats() // Synchronize the delegate's queued error handler.
        try SelfTest.require(engine.captureProgress()?.isActive == true && engine.testApplicationAudioWarning() == nil && failures.isEmpty, "Obsolete audio stream errors cannot affect capture or current audio")
        let snapshot = try await engine.snapshot(seconds: 2.3)
        let target = directory.appendingPathComponent("selected-app-and-microphone.mov")
        try await SpyExporter.export(snapshot, to: target, separateAudio: true, editableMicrophone: true)
        let asset = AVURLAsset(url: target)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(tracks.count == 2, "The selected system audio and microphone remain independent AAC tracks")
        var hasGame = false, hasMic = false
        for track in tracks {
            let samples = try AudioTests.samples(asset, track: track)
            let game = AudioTests.magnitude(samples, frequency: 440)
            let microphone = AudioTests.magnitude(samples, frequency: 997)
            try SelfTest.require(AudioTests.magnitude(samples, frequency: 880) < 0.015 && AudioTests.magnitude(samples, frequency: 1400) < 0.015,
                "All-system and stale audio cannot leak into selected-app recording")
            hasGame = hasGame || game > 0.06; hasMic = hasMic || microphone > 0.06
        }
        try SelfTest.require(hasGame && hasMic, "The chosen source and main-stream microphone both survive full AAC decoding")

        engine.stream(selected, didStopWithError: SpyError.message("Synthetic selected audio failure"))
        _ = engine.testStats()
        try SelfTest.require(engine.captureProgress()?.isActive == true && engine.testApplicationAudioWarning() != nil && failures.isEmpty,
            "Selected audio failure reports silence without stopping video/mic or broadening capture")
        await engine.stop()
        try SelfTest.require(engine.testApplicationAudioWarning() == nil, "Stopping clears the old selected-audio warning")
        print("PASS: real separate AAC capture, exclusive stream routing, no duplicate/all-system leak, independent microphone, late-error rejection and nonfatal selected-audio failure")
        try await dormantStreamRegression(directory: directory.appendingPathComponent("dormant-lifecycle"))
    }

    private static func dormantStreamRegression(directory: URL) async throws {
        let engine = SpyEngine(cacheRoot: directory)
        let dormant = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let processes: Set<pid_t> = [42]
        let display: CGDirectDisplayID = 7
        var starts = 0
        engine.applicationAudioStartOverride = { capture in
            try SelfTest.require(capture === dormant, "A dormant selected stream is reused without broadening its filter")
            starts += 1
        }
        try engine.beginTest(seconds: 30, audio: true)
        engine.requestPrivacyBlock(true)
        engine.testAdoptApplicationAudioStream(dormant, processes: processes, display: display)
        let reusedWhileBlocked = await engine.testReconcileApplicationAudio(processes: processes, display: display)
        try SelfTest.require(reusedWhileBlocked && starts == 0 && !engine.testApplicationAudioStreamStarted(), "Reusing the same PID cannot start audio across a privacy block")
        engine.requestPrivacyBlock(false)
        let deadline = Date().addingTimeInterval(2)
        while !engine.testApplicationAudioStreamStarted() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try SelfTest.require(starts == 1 && engine.testApplicationAudioStreamStarted(), "Clearing a transient block starts its dormant selected stream without requiring a full pause/resume")
        _ = await engine.testReconcileApplicationAudio(processes: processes, display: display)
        try SelfTest.require(starts == 1, "A healthy same-PID refresh never starts an already running audio stream twice")
        await engine.stop()

        // Reproduce the original fast path separately, without an unblock task.
        try engine.beginTest(seconds: 30, audio: true)
        engine.testAdoptApplicationAudioStream(dormant, processes: processes, display: display)
        let reused = await engine.testReconcileApplicationAudio(processes: processes, display: display)
        try SelfTest.require(reused && starts == 2 && engine.testApplicationAudioStreamStarted(), "Same-PID/display reconciliation starts an installed but dormant audio stream")
        await engine.stop()

        // Resume and filter refresh can both reach start while its framework ACK
        // is pending. The encoder queue must claim the identity before awaiting.
        try engine.beginTest(seconds: 30, audio: true)
        engine.testAdoptApplicationAudioStream(dormant, processes: processes, display: display)
        var gate: CheckedContinuation<Void, Never>?
        engine.applicationAudioStartOverride = { _ in
            starts += 1
            await withCheckedContinuation { gate = $0 }
        }
        let first = Task { await engine.testReconcileApplicationAudio(processes: processes, display: display) }
        let claimDeadline = Date().addingTimeInterval(2)
        while gate == nil && Date() < claimDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try SelfTest.require(gate != nil && starts == 3, "The selected-audio start reached its pending framework ACK")
        _ = await engine.testReconcileApplicationAudio(processes: processes, display: display)
        try SelfTest.require(starts == 3 && !engine.testApplicationAudioStreamStarted(), "Concurrent reconciliation cannot issue a second start before the first ACK")
        gate?.resume(); gate = nil
        _ = await first.value
        try SelfTest.require(engine.testApplicationAudioStreamStarted(), "The first acknowledged start owns the running selected audio")
        await engine.stop()

        // Stop while startCapture is suspended: the late ACK cannot resurrect it.
        try engine.beginTest(seconds: 30, audio: true)
        engine.testAdoptApplicationAudioStream(dormant, processes: processes, display: display)
        let pending = Task { await engine.testReconcileApplicationAudio(processes: processes, display: display) }
        let stopDeadline = Date().addingTimeInterval(2)
        while gate == nil && Date() < stopDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try SelfTest.require(gate != nil && starts == 4, "A second test start is suspended before stop")
        await engine.stop()
        gate?.resume(); gate = nil
        _ = await pending.value
        try SelfTest.require(engine.captureProgress()?.isActive != true && !engine.testApplicationAudioStreamStarted(), "A late start ACK cannot resurrect stopped selected-app capture")
        print("PASS: dormant same-PID recovery, transient privacy unblock, single in-flight start claim and stale-ACK rejection after stop")
    }
}
