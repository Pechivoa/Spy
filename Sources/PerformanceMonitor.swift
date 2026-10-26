import Foundation
import SwiftUI
import Darwin

struct EncoderPerformanceSnapshot {
    var actualFPS: Double = 0
    var droppedFrames: Int = 0
}

/// Encoder-queue confined. Count only a scheduled frame the encoder could not
/// accept; a static screen, lock pause and absent source pixels are not drops.
struct EncoderPerformanceTracker {
    private var targetFPS = 30.0
    private var events: [(time: Double, accepted: Bool)] = []
    private var lastTime: Double?
    private var dropped = 0

    mutating func reset(fps: Int) {
        targetFPS = Double(max(1, fps)); events = []; lastTime = nil; dropped = 0
    }
    mutating func resumeWindow() {
        events = []; lastTime = nil
    }
    mutating func record(at seconds: Double, accepted: Bool) {
        guard seconds.isFinite, lastTime.map({ seconds > $0 }) ?? true else { return }
        lastTime = seconds
        if !accepted { dropped += 1 }
        events.append((seconds, accepted))
        events.removeAll { $0.time < seconds - 2 }
    }
    func snapshot(at seconds: Double? = nil) -> EncoderPerformanceSnapshot {
        guard let lastTime, let first = events.first else { return EncoderPerformanceSnapshot(droppedFrames: dropped) }
        let now = seconds.flatMap { $0.isFinite ? $0 : nil } ?? lastTime
        guard now - lastTime < 2 else { return EncoderPerformanceSnapshot(droppedFrames: dropped) }
        let span = max(1 / targetFPS, now - first.time + 1 / targetFPS)
        return EncoderPerformanceSnapshot(actualFPS: Double(events.filter(\.accepted).count) / span, droppedFrames: dropped)
    }
}

struct ProcessResourceReading {
    let uptime: Double
    let cpuSeconds: Double
    let residentBytes: Int64
}
struct ProcessPerformanceSample {
    var cpuPercent: Double?
    var memoryBytes: Int64?
}

enum ProcessResourceSampler {
    static func read() -> ProcessResourceReading? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        var basic = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return ProcessResourceReading(uptime: ProcessInfo.processInfo.systemUptime, cpuSeconds: cpu, residentBytes: Int64(clamping: basic.resident_size))
    }
}

@MainActor final class PerformanceMonitor: ObservableObject {
    @Published private(set) var sample = ProcessPerformanceSample()
    private var timer: Timer?
    private var previous: ProcessResourceReading?
    private var lastPoll: Double?
    private let sampler: () -> ProcessResourceReading?
    private let clock: () -> Double
    init(sampler: @escaping () -> ProcessResourceReading? = ProcessResourceSampler.read, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.sampler = sampler; self.clock = clock
    }
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; previous = nil; lastPoll = nil }
    func poll() {
        let now = clock()
        guard now.isFinite, lastPoll.map({ now - $0 >= 1 }) ?? true else { return }
        lastPoll = now
        guard let reading = sampler(), reading.uptime.isFinite, reading.cpuSeconds.isFinite, reading.residentBytes >= 0 else {
            sample = ProcessPerformanceSample(); previous = nil; return
        }
        var cpu: Double?
        if let previous {
            let elapsed = reading.uptime - previous.uptime
            let consumed = reading.cpuSeconds - previous.cpuSeconds
            if elapsed > 0, consumed >= 0 { cpu = consumed / elapsed * 100 }
        }
        sample = ProcessPerformanceSample(cpuPercent: cpu, memoryBytes: reading.residentBytes)
        previous = reading
    }
    deinit { timer?.invalidate() }
}

struct PerformancePanel: View {
    let actualFPS: Double
    let droppedFrames: Int
    let targetFPS: Int
    @ObservedObject var monitor: PerformanceMonitor
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 10 : 22) {
            value(String(format: "%.1f", max(0, actualFPS)), label: "FPS / \(targetFPS)")
            value("\(max(0, droppedFrames))", label: "Пропуски")
            value(monitor.sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—", label: "CPU Spy")
            value(monitor.sample.memoryBytes.map(fileSize) ?? "—", label: "Память")
        }
        .padding(compact ? 9 : 14)
        .frame(maxWidth: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .help("FPS — частота записанных кадров. Пропуски — кадры, которые кодировщик не принял. CPU: 100% соответствует одному ядру. Память — резидентная память Spy.")
    }
    private func value(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(size: compact ? 11 : 14, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: compact ? 8 : 10)).foregroundStyle(Theme.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
