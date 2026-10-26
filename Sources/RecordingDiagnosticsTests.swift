import Foundation
import AVFoundation

private actor DiagnosticsStartSignal {
    private var ready = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() { ready = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if ready { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Uses the real H.264/AAC encoder with generated frames and tones. No test
/// starts ScreenCaptureKit, accesses a microphone or changes user preferences.
@MainActor enum RecordingDiagnosticsTests {
    private static var access: CaptureAccess {
        CaptureAccess(screenAllowed: { true }, microphoneStatus: { .authorized },
                      requestMicrophone: { throwUnexpectedPermissionRequest() })
    }
    private static func throwUnexpectedPermissionRequest() -> Bool {
        preconditionFailure("Diagnostics must never ask macOS for a permission")
    }
    private static let dimensions = CGSize(width: 320, height: 180)

    private static func feed(_ engine: SpyEngine, frames: Range<Int> = 0..<60,
                             system: Bool, microphone: Bool, amplitude: Float = 0.15) async throws {
        for frame in frames {
            try Task.checkCancellation()
            let pts = CMTime(value: 30_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            if system { engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440, amplitude: amplitude)) }
            if microphone {
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, rate: 44_100, channels: 1, frequency: 997, amplitude: amplitude), microphone: true)
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    private static func require(_ check: RecordingDiagnostics, _ component: RecordingDiagnosticResult.Component,
                                _ status: RecordingDiagnosticStatus, _ message: String) throws {
        try SelfTest.require(check.results.first(where: { $0.component == component })?.status == status,
                             message + "\n" + check.reportText)
    }

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateRoot = directory.appendingPathComponent("private-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        func requirePrivateCleanup() throws {
            let files = try FileManager.default.contentsOfDirectory(at: privateRoot, includingPropertiesForKeys: nil)
            try SelfTest.require(files.isEmpty, "Diagnostic temporary capture and snapshots are removed")
        }

        // Every independent capture uses the real selected source layout. A
        // zero replay limit must not prevent a short private diagnostic capture.
        for (system, microphone) in [(false, false), (true, false), (false, true), (true, true)] {
            let config = RecordingConfig(displayID: 0, quality: .balanced, audio: system, microphone: microphone, seconds: 0)
            let check = RecordingDiagnostics(access: access, captureStartOverride: { engine, selected in
                try SelfTest.require(selected.seconds == 10, "Private diagnostic has its own nonzero ring limit")
                try SelfTest.require(selected.audio == system && selected.microphone == microphone, "Private diagnostic uses exactly the selected sources")
                try engine.beginTest(seconds: selected.seconds, audio: selected.audio, microphone: selected.microphone)
                try await feed(engine, system: system, microphone: microphone)
            }, testDuration: 0, tempRoot: privateRoot)
            await check.run(config: config, expectedDimensions: dimensions)
            try require(check, .video, .passed, "Real H.264 frames decode at the expected size")
            try require(check, .system, system ? .passed : .notSelected, "System AAC is checked only when selected")
            try require(check, .microphone, microphone ? .passed : .notSelected, "Microphone AAC is checked only when selected")
            try SelfTest.require(!check.running && check.checkedAt != nil && !check.reportText.isEmpty, "Completed diagnostic exposes an exportable report")
            try requirePrivateCleanup()
        }
        print("PASS: diagnostic H.264 decode, source-specific AAC/PCM, disabled sources and private capture cleanup")

        let fullConfig = RecordingConfig(displayID: 0, quality: .balanced, audio: true, microphone: true, seconds: 30)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("existing-ring"))
        try engine.beginTest(seconds: 30, audio: true, microphone: true)
        try await engine.beginManual()
        try await feed(engine, frames: 0..<90, system: true, microphone: true)
        let pinnedBefore = try await engine.snapshot(seconds: 2)
        let bytesBefore = try pinnedBefore.urls.map { try Data(contentsOf: $0) }
        let beforeSeconds = engine.testStats().seconds
        let advisoryDenied = CaptureAccess(screenAllowed: { false }, microphoneStatus: { .denied }, requestMicrophone: { throwUnexpectedPermissionRequest() })
        let existingCheck = RecordingDiagnostics(access: advisoryDenied, captureStartOverride: { _, _ in
            throw SpyError.message("Existing capture must never start a second engine")
        }, testDuration: 0, tempRoot: privateRoot)
        await existingCheck.run(config: fullConfig, existingEngine: engine, expectedDimensions: dimensions)
        try require(existingCheck, .screen, .passed, "An existing stream is authoritative despite stale preflight")
        try require(existingCheck, .video, .passed, "A pinned existing ring is readable")
        try require(existingCheck, .system, .passed, "Existing system audio is checked without capturing again")
        try require(existingCheck, .microphone, .passed, "Existing microphone audio is checked without granting access")
        let bytesAfter = try pinnedBefore.urls.map { try Data(contentsOf: $0) }
        try SelfTest.require(bytesBefore == bytesAfter, "Diagnostics leaves previously pinned segment bytes unchanged")
        try SelfTest.require(engine.testStats().seconds >= beforeSeconds - 0.05, "Diagnostics preserves the live ring")
        try await feed(engine, frames: 90..<120, system: true, microphone: true)
        let manual = try await engine.finishManual()
        let manualPlayback = try await BufferPlayback.prepare(manual, levels: AudioLevels())
        try SelfTest.require(manualPlayback.duration >= 3.8, "Manual recording continues across the diagnostic snapshot")
        let continued = try await engine.snapshot(seconds: 1)
        let continuedPlayback = try await BufferPlayback.prepare(continued, levels: AudioLevels())
        try SelfTest.require(continuedPlayback.duration > 0.9, "Existing engine continues encoding after the diagnostic")
        await engine.stop()
        for snapshot in [pinnedBefore, manual, continued] { try? FileManager.default.removeItem(at: snapshot.directory) }
        try requirePrivateCleanup()
        print("PASS: diagnostic preserves active ring, pinned files and an active manual recording")

        let silent = RecordingDiagnostics(access: access, captureStartOverride: { engine, config in
            try engine.beginTest(seconds: 10, audio: config.audio, microphone: config.microphone)
            try await feed(engine, system: true, microphone: true, amplitude: 0)
        }, testDuration: 0, tempRoot: privateRoot)
        await silent.run(config: fullConfig, expectedDimensions: dimensions)
        try require(silent, .video, .passed, "Silence does not invalidate video")
        try require(silent, .system, .warning, "Valid silent system AAC gives an actionable warning")
        try require(silent, .microphone, .warning, "Valid silent microphone AAC gives an actionable warning")
        try requirePrivateCleanup()

        let missingAudio = RecordingDiagnostics(access: access, captureStartOverride: { engine, _ in
            try engine.beginTest(seconds: 10)
            try await feed(engine, system: false, microphone: false)
        }, testDuration: 0, tempRoot: privateRoot)
        await missingAudio.run(config: fullConfig, expectedDimensions: dimensions)
        try require(missingAudio, .system, .warning, "Selected system input with no packets can be silent")
        try require(missingAudio, .microphone, .warning, "Selected microphone with no packets requests a spoken test")
        try requirePrivateCleanup()
        print("PASS: silent AAC and absent selected audio produce warnings instead of false successes or failures")

        let wrongSize = RecordingDiagnostics(access: access, captureStartOverride: { engine, _ in
            try engine.beginTest(seconds: 10, audio: true, microphone: true)
            try await feed(engine, system: true, microphone: true)
        }, testDuration: 0, tempRoot: privateRoot)
        await wrongSize.run(config: fullConfig, expectedDimensions: CGSize(width: 640, height: 360))
        try require(wrongSize, .video, .failed, "A wrong frame size fails even if H.264 metadata is otherwise valid")
        try require(wrongSize, .system, .passed, "A video failure does not hide a working audio source")
        try requirePrivateCleanup()

        let empty = RecordingDiagnostics(access: access, captureStartOverride: { engine, _ in
            try engine.beginTest(seconds: 10)
        }, testDuration: 0, tempRoot: privateRoot)
        await empty.run(config: fullConfig, expectedDimensions: dimensions)
        try require(empty, .video, .failed, "An encoder with no frames cannot pass the diagnostic")
        try requirePrivateCleanup()
        print("PASS: expected resolution and missing real frames are validated")

        var deniedStartCalled = false
        let noScreen = RecordingDiagnostics(access: advisoryDenied, captureStartOverride: { _, _ in deniedStartCalled = true },
                                            testDuration: 0, tempRoot: privateRoot)
        await noScreen.run(config: fullConfig, expectedDimensions: dimensions)
        try require(noScreen, .screen, .failed, "Missing screen permission has an actionable failure")
        try SelfTest.require(!deniedStartCalled, "Permission check never starts capture or prompts for access")
        let noMicrophone = RecordingDiagnostics(access: CaptureAccess(screenAllowed: { true }, microphoneStatus: { .notDetermined },
                                                                       requestMicrophone: { throwUnexpectedPermissionRequest() }),
                                                captureStartOverride: { engine, config in
            try SelfTest.require(!config.microphone, "Unauthorized microphone is never captured implicitly")
            try engine.beginTest(seconds: 10, audio: config.audio)
            try await feed(engine, system: true, microphone: false)
        }, testDuration: 0, tempRoot: privateRoot)
        await noMicrophone.run(config: fullConfig, expectedDimensions: dimensions)
        try require(noMicrophone, .microphone, .failed, "Microphone permission remains explicit and actionable")
        try require(noMicrophone, .video, .passed, "A missing microphone grant does not prevent checking screen/video")
        try requirePrivateCleanup()
        print("PASS: diagnostics reports missing permission without requesting or changing any grants")

        let signal = DiagnosticsStartSignal()
        let cancelled = RecordingDiagnostics(access: access, captureStartOverride: { engine, _ in
            try engine.beginTest(seconds: 10)
            await signal.signal()
            try await engine.waitForFirstFrame(timeout: 5)
        }, testDuration: 0, tempRoot: privateRoot)
        let task = Task { await cancelled.run(config: fullConfig, expectedDimensions: dimensions) }
        await signal.wait()
        cancelled.cancel()
        await task.value
        try SelfTest.require(!cancelled.running, "Cancellation awaits shutdown before reporting idle")
        try require(cancelled, .operation, .warning, "Cancellation is reported explicitly")
        try requirePrivateCleanup()
        // The same controller can run again after its previous job was cancelled.
        let cancelledAgain = Task { await cancelled.run(config: fullConfig, expectedDimensions: dimensions) }
        await Task.yield()
        cancelledAgain.cancel()
        await cancelledAgain.value
        try SelfTest.require(!cancelled.running, "Caller cancellation propagates to the owned diagnostic job")
        try requirePrivateCleanup()
        print("PASS: button and caller cancellation stop private capture and remove its files")
    }
}
