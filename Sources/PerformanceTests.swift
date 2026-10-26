import Foundation

@MainActor enum PerformanceTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tracker = EncoderPerformanceTracker()
        tracker.reset(fps: 60)
        for frame in 0..<120 { tracker.record(at: Double(frame) / 60, accepted: true) }
        try SelfTest.require(abs(tracker.snapshot().actualFPS - 60) < 0.01 && tracker.snapshot().droppedFrames == 0, "Accepted encoded frames report actual 60 FPS with no drops")
        tracker.reset(fps: 60)
        for frame in 0..<120 { tracker.record(at: Double(frame) / 60, accepted: frame % 10 != 0) }
        let reduced = tracker.snapshot()
        try SelfTest.require(abs(reduced.actualFPS - 54) < 0.01 && reduced.droppedFrames == 12, "Only frames rejected by encoder count as dropped")
        tracker.record(at: .nan, accepted: false)
        tracker.record(at: 0.1, accepted: false)
        try SelfTest.require(tracker.snapshot().droppedFrames == 12, "Invalid and stale timestamps do not invent frame drops")
        try SelfTest.require(tracker.snapshot(at: 10).actualFPS == 0, "Idle encoder does not report stale active FPS")
        tracker.resumeWindow()
        try SelfTest.require(tracker.snapshot().actualFPS == 0 && tracker.snapshot().droppedFrames == 12, "Privacy pause clears stale FPS while retaining cumulative encoder drops")
        tracker.record(at: 100, accepted: true)
        try SelfTest.require(tracker.snapshot().actualFPS == 60 && tracker.snapshot().droppedFrames == 12, "Resume starts a fresh FPS window without counting paused wall time as dropped frames")
        tracker.reset(fps: 30)
        try SelfTest.require(tracker.snapshot().droppedFrames == 0 && tracker.snapshot().actualFPS == 0, "New capture clears historical performance counters")
        print("PASS: actual encoded FPS, rejected-frame counts, timestamp guards and idle/reset behavior")

        var time = 100.0, cpu = 2.0, memory: Int64 = 100_000_000, calls = 0, available = true
        let monitor = PerformanceMonitor(sampler: {
            calls += 1
            return available ? ProcessResourceReading(uptime: time, cpuSeconds: cpu, residentBytes: memory) : nil
        }, clock: { time })
        monitor.poll()
        try SelfTest.require(monitor.sample.cpuPercent == nil && monitor.sample.memoryBytes == memory, "CPU starts unavailable until a second real interval; memory is current")
        time = 100.5; cpu = 2.1; monitor.poll()
        try SelfTest.require(calls == 1, "Resource sampling is limited to at most once per second")
        time = 101; cpu = 2.25; memory = 110_000_000; monitor.poll()
        try SelfTest.require(abs((monitor.sample.cpuPercent ?? -1) - 25) < 0.0001 && monitor.sample.memoryBytes == memory, "CPU uses process CPU time and memory reflects the current reading")
        time = 102; cpu = 3.75; monitor.poll()
        try SelfTest.require(abs((monitor.sample.cpuPercent ?? -1) - 150) < 0.0001, "CPU permits multiple active cores instead of falsely capping at 100 percent")
        time = 103; available = false; monitor.poll()
        try SelfTest.require(monitor.sample.cpuPercent == nil && monitor.sample.memoryBytes == nil, "Unavailable process metrics remain unavailable rather than becoming false zeros")
        monitor.start(); monitor.stop()
        let stoppedCalls = calls
        time = 105
        try await Task.sleep(nanoseconds: 1_050_000_000)
        try SelfTest.require(calls == stoppedCalls, "Stopping the performance monitor removes its repeating sampler")
        guard let real = ProcessResourceSampler.read() else { throw SpyError.message("TEST FAILED: Cannot read this process metrics") }
        try SelfTest.require(real.uptime > 0 && real.cpuSeconds >= 0 && real.residentBytes > 0, "Actual macOS process CPU and resident memory are readable without extra permissions")
        print("PASS: one-second resource sampling, CPU calculation, current RAM, unavailable-state handling and timer cleanup")
    }
}
