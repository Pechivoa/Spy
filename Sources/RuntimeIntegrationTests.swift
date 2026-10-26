import Foundation
import AVFoundation

private actor RuntimeEventLog {
    var events: [String] = []
    func append(_ value: String) { events.append(value) }
    func values() -> [String] { events }
}
private actor RuntimeStartSignal {
    private var ready = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { ready = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor enum RuntimeIntegrationTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let serial = PrivacyFilterQueue(), log = RuntimeEventLog(), signal = RuntimeStartSignal()
        let first = Task {
            try await serial.run {
                await log.append("first-start"); await signal.signal()
                try await Task.sleep(nanoseconds: 30_000_000)
                await log.append("first-finish")
            }
        }
        await signal.wait()
        let second = Task {
            try await serial.run {
                await log.append("second-start"); await log.append("second-finish")
            }
        }
        try await first.value; try await second.value
        let order = await log.values()
        try SelfTest.require(order == ["first-start", "first-finish", "second-start", "second-finish"], "Awaited privacy filter updates are serialized through their completion")
        do { try await serial.run { throw SpyError.message("Synthetic old-filter failure") } } catch {}
        try await serial.run { await log.append("after-error") }
        let afterError = await log.values()
        try SelfTest.require(afterError.last == "after-error", "A failed filter cannot poison subsequent updates")
        print("PASS: filter update FIFO across awaits and error recovery")

        let model = AppModel(preview: true, captureAccess: CaptureAccess(screenAllowed: { true }, microphoneStatus: { .authorized }, requestMicrophone: { true }))
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        model.saveBufferOnExit = false; model.minutes = 0
        model.captureStartOverride = { [weak model] config in
            guard let model else { throw CancellationError() }
            try model.engine.beginTest(seconds: config.seconds)
            for frame in 0..<30 {
                model.engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: 90_000 + Int64(frame), timescale: 30))
                try await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        await model.toggleManual()
        for frame in 30..<60 {
            model.engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: 90_000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        model.manualPrivacyPause = true
        model.engine.requestPrivacyBlock(true)
        await model.reconcilePrivacyState()
        try SelfTest.require(model.recording && model.manualRecording && model.privacyPaused, "Manual-only capture can pause without clearing its session")
        await model.stop()
        try SelfTest.require(!model.recording && !model.manualRecording && !model.privacyPaused && !model.manualPrivacyPause, "Stopping a paused manual session clears every pause flag")
        await model.toggleManual()
        try SelfTest.require(model.recording && model.manualRecording && !model.privacyPaused, "A subsequent manual session starts after a paused stop")
        await model.finishManual(stopCapture: true)
        print("PASS: paused manual stop preserves video, clears pause state and permits a fresh recording")
    }
}
