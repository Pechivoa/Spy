import SwiftUI

struct CaptureTelemetry {
    var session: UUID? = nil
    var began = ProcessInfo.processInfo.systemUptime
    var screen: Double?
    var encoded: Double?
    var system: Double?
    var microphone: Double?
    var idle = false
    var wantsSystem = false
    var wantsMicrophone = false
}

@MainActor final class CaptureHealth: ObservableObject {
    @Published private(set) var warnings: [String] = []
    var sample = CaptureTelemetry()
    private var expectedSession: UUID?
    private var graceUntil: Double = 0
    var onChange: (([String]) -> Void)?
    func reset(session: UUID? = nil) { expectedSession = session; sample = CaptureTelemetry(session: session); warnings = []; graceUntil = 0 }
    func receive(_ value: CaptureTelemetry) {
        guard expectedSession == nil || expectedSession == value.session else { return }
        sample = value
    }
    func snooze(now: Double = ProcessInfo.processInfo.systemUptime) { graceUntil = now + 8; warnings = [] }
    static func evaluate(_ sample: CaptureTelemetry, now: Double, active: Bool, paused: Bool) -> [String] {
        guard active, !paused, now - sample.began > 8 else { return [] }
        var result: [String] = []
        if now - (sample.encoded ?? sample.began) > 4 {
            result.append("Кадры не записываются больше 4 секунд. Проверьте источник и журнал.")
        } else if !sample.idle && now - (sample.screen ?? sample.began) > 8 {
            result.append("Экран давно не присылал обновлений. В видео может повторяться последний кадр.")
        }
        if sample.wantsSystem && now - (sample.system ?? sample.began) > 8 {
            result.append("Нет новых данных системного звука. Возможна тишина или остановка аудиопотока.")
        }
        if sample.wantsMicrophone && now - (sample.microphone ?? sample.began) > 8 {
            result.append("Нет новых данных микрофона. Проверьте подключение выбранного устройства.")
        }
        return result
    }
    func check(active: Bool, paused: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        let next = Self.evaluate(sample, now: now, active: active, paused: paused || now < graceUntil)
        if next != warnings { warnings = next; onChange?(next) }
    }
}

struct CaptureHealthBadge: View {
    @ObservedObject var health: CaptureHealth
    let open: () -> Void
    var body: some View {
        if !health.warnings.isEmpty {
            Button(action: open) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .buttonStyle(.plain).help(health.warnings.joined(separator: "\n"))
                .accessibilityLabel("Проблема записи: открыть журнал")
        }
    }
}

struct CaptureHealthView: View {
    @ObservedObject var health: CaptureHealth
    var showJournal: () -> Void
    var body: some View {
        if !health.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Проверьте запись", systemImage: "exclamationmark.triangle.fill").font(.headline)
                ForEach(health.warnings, id: \.self) { Text($0).font(.system(size: 12)) }
                Button("Открыть журнал", action: showJournal).buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
