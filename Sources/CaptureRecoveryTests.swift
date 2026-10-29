import AppKit
import AVFoundation

@MainActor enum CaptureRecoveryTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WindowRecoveryIdentity.validate(expected: 100, actual: 100)
        var rejectedWindow = false
        do { try WindowRecoveryIdentity.validate(expected: 100, actual: 101) } catch { rejectedWindow = true }
        try SelfTest.require(rejectedWindow, "Window recovery cannot reuse an ID from a different process")
        let model = AppModel(preview: true, captureAccess: CaptureAccess(screenAllowed: { true }, microphoneStatus: { .authorized }, requestMicrophone: { false }))
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        model.saveBufferOnExit = false
        var starts = 0
        model.captureStartOverride = { config in
            starts += 1
            try model.engine.beginTest(seconds: config.seconds)
            for frame in 0..<20 {
                model.engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: Int64(starts * 3000 + frame), timescale: 30))
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try await model.engine.waitForFirstFrame(timeout: 1)
        }
        await model.start()
        model.installCaptureRecovery(delays: [0.04, 0.04, 0.04], maximumWait: 1)
        let original = try await model.engine.snapshot(seconds: 30)
        let originalBytes = try original.urls.map { try Data(contentsOf: $0) }
        await model.handleCaptureFailure("Synthetic stream interruption")
        try SelfTest.require(!model.recording && model.captureRecovery.isPending, "Failure stops and schedules bounded recovery")
        try await wait { model.recording && !model.captureRecovery.isPending }
        let retainedBytes = try original.urls.map { try Data(contentsOf: $0) }
        try SelfTest.require(starts == 2 && retainedBytes == originalBytes && !model.recoveryFolders.isEmpty && model.captureRecovery.lastInterruption?.resumed != nil,
            "Fresh capture starts once, original pinned packets and recovery folder survive, interruption is reported")
        print("PASS: real engine restart, preserved original encoded packets and durable interruption interval")
        await model.handleCaptureFailure("Second interruption")
        model.cancelCaptureRecovery()
        try await Task.sleep(nanoseconds: 200_000_000)
        try SelfTest.require(!model.recording && !model.lastReplayEnabled && starts == 2, "Manual cancellation prevents a delayed automatic restart")
        model.setReplayIntent(true)
        model.privacy.setBlocked(true, reason: .screenLocked)
        model.captureRecovery.schedule(target: model.recoveryTarget, reason: "Private")
        try await Task.sleep(nanoseconds: 150_000_000)
        try SelfTest.require(starts == 2 && model.captureRecovery.isPending, "Privacy waits without consuming attempts or creating capture")
        model.privacy.setBlocked(false, reason: .screenLocked)
        try await wait { model.recording && !model.captureRecovery.isPending }
        try SelfTest.require(starts == 3, "Unlock recovers only after privacy unblocks")
        await model.stop()
        let suite = "Spy.Recovery.Test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CaptureRecovery(defaults: defaults)
        var attempts = 0
        controller.install(delays: [0.01, 0.01, 0.01], maximumWait: 0.2, readiness: { _ in .ready }, attempt: { attempts += 1; return false }, report: { _ in })
        controller.schedule(target: "source", reason: "Unavailable")
        try await wait { !controller.isPending }
        try SelfTest.require(attempts == 3 && controller.lastInterruption?.resumed == nil && controller.status?.contains("Не удалось") == true,
            "Three failed attempts end visibly instead of looping forever")
        let restored = CaptureRecovery(defaults: defaults)
        try SelfTest.require(restored.lastInterruption?.attempts == 3, "Interruption diagnostics survive app restart")
        controller.enabled = false; controller.schedule(target: "source", reason: "Off")
        try SelfTest.require(!controller.isPending && attempts == 3, "Opt-out never starts capture")
        print("PASS: cancel/stop intent, privacy wait/unlock, bounded retries, persisted failure and opt-out")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try SelfTest.require(condition(), "Recovery operation completed")
    }
}
