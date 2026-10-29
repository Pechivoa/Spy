import SwiftUI

enum WindowRecoveryIdentity {
    static func validate(expected: pid_t?, actual: pid_t?) throws {
        if let expected, expected != actual { throw SpyError.message("Приложение выбранного окна изменилось. Выберите окно заново.") }
    }
}

@MainActor final class CaptureRecovery: ObservableObject {
    enum Readiness { case ready, wait, cancel, running, needsUser }
    struct Interruption: Codable {
        var began: Date
        var resumed: Date?
        var reason: String
        var attempts: Int
    }
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "autoRecoverCapture"); if !enabled { cancel() } }
    }
    @Published private(set) var status: String?
    @Published private(set) var isPending = false
    @Published private(set) var lastInterruption: Interruption?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var readiness: ((String) -> Readiness)?
    private var attempt: (() async -> Bool)?
    private var report: ((String) -> Void)?
    private var delays: [Double] = [2, 5, 15]
    private var maximumWait: Double = 120
    var installed: Bool { readiness != nil }
    var interruptionText: String? {
        guard let gap = lastInterruption else { return nil }
        let f = DateFormatter(); f.timeZone = SpyDates.timeZone; f.dateFormat = "HH:mm:ss"
        if let end = gap.resumed {
            return "Перерыв после сбоя: \(f.string(from: gap.began))–\(f.string(from: end)) · \(Int(ceil(end.timeIntervalSince(gap.began)))) с. Готовое видео до сбоя доступно через «Восстановить»."
        }
        return "Сбой в \(f.string(from: gap.began)). Готовые сегменты сохранены для восстановления."
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "autoRecoverCapture") == nil || defaults.bool(forKey: "autoRecoverCapture")
        lastInterruption = defaults.data(forKey: "captureInterruption").flatMap { try? JSONDecoder().decode(Interruption.self, from: $0) }
    }
    func install(delays: [Double] = [2, 5, 15], maximumWait: Double = 120,
                 readiness: @escaping (String) -> Readiness, attempt: @escaping () async -> Bool,
                 report: @escaping (String) -> Void) {
        self.delays = delays; self.maximumWait = maximumWait
        self.readiness = readiness; self.attempt = attempt; self.report = report
    }
    func schedule(target: String, reason: String) {
        guard installed, enabled, !isPending else { return }
        let id = UUID(); generation = id
        lastInterruption = Interruption(began: Date(), reason: reason, attempts: 0)
        persist(); isPending = true; status = "Восстанавливаю запись…"
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.maximumWait)
            for delay in self.delays {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
                guard self.generation == id, !Task.isCancelled else { return }
                while self.readiness?(target) == .wait && Date() < deadline {
                    self.status = "Ожидаю источник или завершение паузы…"
                    do { try await Task.sleep(nanoseconds: UInt64(min(2, max(0.01, delay)) * 1_000_000_000)) } catch { return }
                    guard self.generation == id else { return }
                }
                switch self.readiness?(target) {
                case .running: self.finish(id); return
                case .ready: break
                case .cancel, .none: self.cancel(); return
                case .needsUser: self.exhausted("Проверьте источник и разрешения записи."); return
                case .wait: self.exhausted("Источник пока недоступен. Выберите экран и включите повтор вручную."); return
                }
                self.lastInterruption?.attempts += 1; self.persist()
                self.status = "Повторный запуск · попытка \(self.lastInterruption?.attempts ?? 1) из \(self.delays.count)…"
                let recovered = await self.attempt?() ?? false
                guard self.generation == id, !Task.isCancelled else { return }
                if recovered { self.finish(id); return }
            }
            self.exhausted("Не удалось восстановить запись. Проверьте источник и нажмите «Включить повтор».")
        }
    }
    func captureDidStart() {
        guard lastInterruption != nil, lastInterruption?.resumed == nil else { return }
        lastInterruption?.resumed = Date(); persist()
        if !isPending { status = "Запись продолжена"; report?(interruptionText ?? "Запись продолжена") }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isPending = false; status = nil
    }
    private func finish(_ id: UUID) {
        guard generation == id else { return }
        if lastInterruption?.resumed == nil { lastInterruption?.resumed = Date() }; persist()
        status = "Запись восстановлена"; isPending = false; task = nil
        report?(interruptionText ?? "Запись восстановлена")
    }
    private func exhausted(_ message: String) {
        status = message; isPending = false; task = nil; persist(); report?(message)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(lastInterruption) { defaults.set(data, forKey: "captureInterruption") }
    }
}

@MainActor extension AppModel {
    var recoveryTarget: String {
        captureMode == .window ? "window:\(windowID):\(recordingWindowProcessID ?? 0)" : "display:" + (preferences.string(forKey: "displayUUID") ?? "id:\(displayID)")
    }
    func installCaptureRecovery(delays: [Double] = [2, 5, 15], maximumWait: Double = 120) {
        captureRecovery.install(delays: delays, maximumWait: maximumWait, readiness: { [weak self] target in
            guard let self, !self.shuttingDown, self.lastReplayEnabled, self.minutes > 0, !self.manualRecording,
                  self.recoveryTarget == target else { return .cancel }
            if self.needsPermission || self.needsMicrophonePermission { return .needsUser }
            if self.privacy.isBlocked || self.manualPrivacyPause || self.busy || self.saving || self.diagnosticsBusy || self.switchingConfiguration { return .wait }
            if self.recording { return .running }
            if self.captureMode == .window && self.recordingWindowProcessID == nil { return .needsUser }
            if self.captureMode == .display {
                self.refreshDisplays()
                if self.selectedDisplay == nil { return .wait }
            }
            return .ready
        }, attempt: { [weak self] in
            guard let self else { return false }
            await self.start(requestPermission: false)
            return self.recording
        }, report: { [weak self] message in
            self?.journal.record(.warning, "Самовосстановление", message)
        })
    }
    func cancelCaptureRecovery() {
        captureRecovery.cancel(); setReplayIntent(false)
        if busy { pendingCaptureStop = true }
    }
}

struct CaptureRecoveryView: View {
    @ObservedObject var recovery: CaptureRecovery
    var onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Восстанавливать повтор после сбоя", isOn: $recovery.enabled)
            Text("До трёх попыток. Готовые сегменты сохраняются; другой экран сам не выбирается. Ручная запись не перезапускается.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            if let status = recovery.status { Text(status).font(.system(size: 12, weight: .medium)) }
            if let text = recovery.interruptionText { Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            if recovery.isPending { Button("Отменить восстановление", action: onCancel) }
        }
    }
}

struct CaptureRecoveryNotice: View {
    @ObservedObject var recovery: CaptureRecovery
    var onCancel: () -> Void
    var body: some View {
        if let status = recovery.status {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(status, systemImage: recovery.isPending ? "arrow.triangle.2.circlepath" : "info.circle")
                    Spacer()
                    if recovery.isPending { Button("Отменить", action: onCancel) }
                }
                if let text = recovery.interruptionText { Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }.font(.system(size: 12)).padding(14).background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
