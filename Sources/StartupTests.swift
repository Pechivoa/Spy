import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor enum StartupTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var roots: [URL] = []
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        func model(screen: Bool, mic: AVAuthorizationStatus = .authorized) -> AppModel {
            let value = AppModel(preview: true, captureAccess: CaptureAccess(screenAllowed: { screen }, microphoneStatus: { mic }, requestMicrophone: { false }))
            roots.append(value.libraryURL.deletingLastPathComponent())
            return value
        }
        func simulatedStart(_ value: AppModel) {
            value.captureStartOverride = { [weak value] config in
                guard let value else { throw CancellationError() }
                try value.engine.beginTest(seconds: config.seconds)
                value.engine.testFrame(try SelfTest.pixel(frame: 1), at: CMTime(value: 3000, timescale: 30))
                try await value.engine.waitForFirstFrame(timeout: 0.3)
            }
        }
        let stale = model(screen: false)
        simulatedStart(stale)
        await stale.toggleRecording()
        try SelfTest.require(stale.recording && !stale.busy && !stale.needsPermission && stale.startupStatus == nil && stale.engine.testStats().frameCount == 1, "Manual startup reaches actual encoder even when legacy preflight is false")
        await stale.stop()
        try SelfTest.require(!stale.recording && stale.stats.frameCount == 0, "Stop clears recording and live statistics")
        await stale.toggleRecording()
        try SelfTest.require(stale.recording, "Start works again after stop")
        stale.saving = true
        await stale.toggleRecording()
        try SelfTest.require(stale.recording, "Toggle cannot remove live files while replay export is starting")
        stale.saving = false
        await stale.stop()
        print("PASS: stale preflight, first encoded frame, normal toggle, stop and restart")

        let denied = model(screen: false)
        var starts = 0
        denied.captureStartOverride = { _ in starts += 1; throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue) }
        await denied.start(requestPermission: false)
        try SelfTest.require(starts == 0 && denied.needsPermission && !denied.busy && !denied.recording, "Automatic startup never prompts when access is missing")
        await denied.start()
        try SelfTest.require(starts == 1 && denied.needsPermission && denied.captureIssue?.contains("снова включите") == true && !denied.recording && !denied.busy, "ScreenCaptureKit denial explains enabled-but-stale grants and does not claim recording")
        simulatedStart(denied)
        await denied.start()
        try SelfTest.require(denied.recording && !denied.needsPermission && denied.captureIssue == nil, "Retry clears previous denial on actual success")
        await denied.stop()
        try denied.journal.export(to: directory.appendingPathComponent("startup-journal.txt"))
        print("PASS: automatic startup without prompts, OS denial, visible actionable error and successful retry")

        let mic = model(screen: true, mic: .denied)
        mic.microphone = true
        var micStarts = 0
        mic.captureStartOverride = { _ in micStarts += 1 }
        await mic.start()
        try SelfTest.require(micStarts == 0 && mic.needsMicrophonePermission && mic.captureIssue != nil && !mic.busy && !mic.recording, "Denied microphone stops startup with a visible explanation")
        mic.microphone = false
        simulatedStart(mic)
        await mic.start()
        try SelfTest.require(mic.recording && mic.captureIssue == nil && !mic.needsMicrophonePermission, "Disabling microphone permits screen capture and clears the stale microphone warning")
        await mic.stop()
        let zero = model(screen: true)
        zero.minutes = 0
        simulatedStart(zero)
        await zero.start()
        try SelfTest.require(!zero.recording && zero.error != nil, "Replay duration zero prevents replay startup")
        zero.error = nil
        await zero.start(forManual: true)
        try SelfTest.require(zero.recording && !zero.canSave, "Manual capture still starts when replay is disabled")
        await zero.stop()
        print("PASS: microphone denial and retry without microphone, zero-duration replay and manual capture")

        let concurrent = model(screen: true)
        var concurrentStarts = 0
        concurrent.captureStartOverride = { _ in
            concurrentStarts += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            try concurrent.engine.beginTest(seconds: 30)
            concurrent.engine.testFrame(try SelfTest.pixel(frame: 1), at: CMTime(value: 6000, timescale: 30))
        }
        let first = Task { await concurrent.start() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await concurrent.toggleRecording()
        try SelfTest.require(concurrent.busy && !concurrent.recording && concurrent.startupStatus != nil, "Startup status remains distinct from recording")
        await first.value
        try SelfTest.require(concurrentStarts == 1 && concurrent.recording, "Repeated click during startup starts only one capture")
        await concurrent.stop()
        let cancelled = Task { await concurrent.start() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await concurrent.stop()
        await cancelled.value
        try SelfTest.require(!concurrent.recording && !concurrent.busy && !concurrent.pendingCaptureStop, "Sleep/stop requested during startup is not dropped")
        print("PASS: duplicate-click protection, honest startup status and stop requested during startup")

        let empty = SpyEngine(cacheRoot: directory.appendingPathComponent("empty"))
        try empty.beginTest(seconds: 30)
        do {
            try await empty.waitForFirstFrame(timeout: 0.12)
            throw SpyError.message("TEST FAILED: empty stream announced success")
        } catch { try SelfTest.require(error.localizedDescription.contains("кадры не поступают"), "No-frame timeout explains failure") }
        await empty.stop()
        try empty.beginTest(seconds: 30)
        let pending = Task { try await empty.waitForFirstFrame(timeout: 0.3) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await empty.stop()
        do { try await pending.value; throw SpyError.message("TEST FAILED: stopped startup announced success") }
        catch { try SelfTest.require(error is CancellationError, "Stop resolves pending startup exactly once") }
        let failing = model(screen: true)
        failing.captureStartOverride = { _ in
            try failing.engine.beginTest(seconds: 30)
            try await failing.engine.waitForFirstFrame(timeout: 0.12)
        }
        await failing.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        try SelfTest.require(!failing.recording && !failing.busy && failing.captureIssue != nil && failing.startupStatus == nil, "Encoder failure during busy startup cannot leave recording active")
        await failing.stop()
        print("PASS: first-frame timeout, pending startup cancellation, encoder failure while app is busy")
    }
}
