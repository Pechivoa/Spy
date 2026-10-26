import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct GameAutoCaptureApplication: Codable, Identifiable, Equatable {
    let bundleID: String
    var name: String
    var id: String { bundleID.lowercased() }

    static func normalizedID(_ value: String) -> String? {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, id.count <= 255, !id.contains(where: \.isWhitespace), id != "local.spy.mac" else { return nil }
        return id
    }
}

/// A PID, rather than just a bundle ID, distinguishes two instances of one game.
struct GameAutoCaptureProcess: Equatable {
    let processID: Int32
    let bundleID: String
    let name: String
    var selectable = true
}

struct GameAutoCaptureRuntime: Equatable {
    var recording: Bool
    var canStart: Bool
    var canStop: Bool
    var manualRecording: Bool = false
}

enum GameAutoCaptureStartResult {
    case started
    case deferred
    case failed(String)
}

/// Pure ownership policy. No permission requests, capture calls, or user defaults.
struct GameAutoCapturePolicy {
    enum Action: Equatable { case start, stop }
    struct StartTicket { let cycle: UInt64; let manualRevision: UInt64 }

    private(set) var enabled = false
    private(set) var activeGames: Set<String> = []
    private(set) var ownsReplay = false
    private(set) var userOwnsReplay = false
    private(set) var isSuppressed = false
    private(set) var failedCycle: UInt64?
    private(set) var cycle: UInt64 = 0
    private var manualRevision: UInt64 = 0

    var shouldStop: Bool { ownsReplay && (!enabled || activeGames.isEmpty || isSuppressed) }

    mutating func update(enabled: Bool, activeGames: Set<String>) {
        if self.activeGames.isEmpty && !activeGames.isEmpty { cycle &+= 1; failedCycle = nil }
        if activeGames.isEmpty { isSuppressed = false; failedCycle = nil }
        if enabled != self.enabled { failedCycle = nil }
        self.enabled = enabled
        self.activeGames = activeGames
    }

    mutating func userRequestedStart() {
        manualRevision &+= 1
        userOwnsReplay = true
        ownsReplay = false
        isSuppressed = false
    }

    mutating func userRequestedStop() {
        manualRevision &+= 1
        userOwnsReplay = false
        isSuppressed = !activeGames.isEmpty
    }

    mutating func decision(_ runtime: GameAutoCaptureRuntime) -> Action? {
        // Existing replay belongs to the user, including a restored session.
        // Manual recording is a separate temporary operation, so only defer it.
        if runtime.recording && !runtime.manualRecording && runtime.canStop && !ownsReplay { userOwnsReplay = true }
        if shouldStop && !runtime.recording { ownsReplay = false }
        guard !runtime.manualRecording else { return nil }
        if shouldStop { return runtime.canStop ? .stop : nil }
        guard enabled, !activeGames.isEmpty, !isSuppressed, !userOwnsReplay,
              failedCycle != cycle, !runtime.recording, runtime.canStart else { return nil }
        return .start
    }

    func beginStart() -> StartTicket { StartTicket(cycle: cycle, manualRevision: manualRevision) }

    mutating func completedStart(_ result: GameAutoCaptureStartResult, ticket: StartTicket) {
        switch result {
        case .started:
            // A manual Start during the await adopts this capture. A manual
            // Stop during the await keeps ownership so the late start is stopped.
            ownsReplay = !(ticket.manualRevision != manualRevision && userOwnsReplay)
        case .failed: failedCycle = ticket.cycle
        case .deferred: break
        }
    }

    mutating func completedStop() { ownsReplay = false }
    mutating func retry() { failedCycle = nil }
}

@MainActor final class GameAutoCaptureController: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            startDeferredAt = nil; stopDeferredAt = nil
            synchronizePolicy(); enqueueReconciliation()
        }
    }
    @Published private(set) var selectedApplications: [GameAutoCaptureApplication]
    @Published private(set) var runningApplications: [GameAutoCaptureApplication] = []
    @Published private(set) var activeApplications: [GameAutoCaptureApplication] = []
    @Published private(set) var ownsReplay = false
    @Published private(set) var isSuppressed = false
    @Published private(set) var status = "Автозапуск выключен"
    @Published private(set) var error: String?
    @Published private(set) var configurationReadable = true
    var onDiagnostic: ((String) -> Void)?

    static let enabledKey = "gameAutoCaptureEnabled"
    static let applicationsKey = "gameAutoCaptureApplications"
    var selectedBundleIDs: Set<String> { Set(selectedApplications.map(\.id)) }
    /// Recheck this after saving a buffer and before stopping the capture: the
    /// game may have relaunched, or the user may have adopted the replay.
    var shouldStopAutomatically: Bool { policy.shouldStop }

    private let defaults: UserDefaults
    private let workspaceCenter: NotificationCenter
    private let runningProvider: @MainActor () -> [GameAutoCaptureProcess]
    private let terminationDelayNanoseconds: UInt64
    private var tokens: [NSObjectProtocol] = []
    private var terminationTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var stateProvider: (() -> GameAutoCaptureRuntime)?
    private var startCallback: (() async -> GameAutoCaptureStartResult)?
    private var stopCallback: (() async -> Bool)?
    private var processes: [GameAutoCaptureProcess] = []
    private var effectiveActiveIDs: Set<String> = []
    private var policy = GameAutoCapturePolicy()
    private var reconciliationPending = false
    private var installed = false
    private var installation: UInt64 = 0
    private var startDeferredAt: GameAutoCaptureRuntime?
    private var stopDeferredAt: GameAutoCaptureRuntime?
    private var operation: GameAutoCapturePolicy.Action?

    init(defaults: UserDefaults,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         runningApplications: @escaping @MainActor () -> [GameAutoCaptureProcess] = GameAutoCaptureController.liveProcesses,
         terminationDelayNanoseconds: UInt64 = 1_500_000_000) {
        self.defaults = defaults
        self.workspaceCenter = workspaceCenter
        self.runningProvider = runningApplications
        self.terminationDelayNanoseconds = terminationDelayNanoseconds
        enabled = defaults.bool(forKey: Self.enabledKey)
        var saved: [GameAutoCaptureApplication] = []
        if let data = defaults.data(forKey: Self.applicationsKey) {
            do { saved = try JSONDecoder().decode([GameAutoCaptureApplication].self, from: data) }
            catch {
                configurationReadable = false
                self.error = "Не удалось прочитать список игр. Восстановите список или сбросьте его вручную. Автозапуск приостановлен."
            }
        } else if defaults.object(forKey: Self.applicationsKey) != nil {
            configurationReadable = false
            self.error = "Неверный формат списка игр. Автозапуск приостановлен; сохранённые данные не изменены."
        }
        var seen: Set<String> = []
        selectedApplications = saved.compactMap { app in
            guard let id = GameAutoCaptureApplication.normalizedID(app.bundleID), seen.insert(id).inserted else { return nil }
            return GameAutoCaptureApplication(bundleID: id, name: app.name.isEmpty ? id : app.name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshRunningApplications()
    }

    deinit {
        terminationTask?.cancel(); reconcileTask?.cancel()
        for token in tokens { workspaceCenter.removeObserver(token) }
    }

    /// Callbacks are serialized. `start` must not request system permission;
    /// return .failed once if unavailable. `stop` must save the owned buffer,
    /// recheck shouldStopAutomatically, and return true only after capture stops.
    func install(state: @escaping () -> GameAutoCaptureRuntime,
                 start: @escaping () async -> GameAutoCaptureStartResult,
                 stop: @escaping () async -> Bool) {
        stateProvider = state; startCallback = start; stopCallback = stop
        installed = true
        if tokens.isEmpty {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                tokens.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshRunningApplications() }
                })
            }
        }
        refreshRunningApplications()
        enqueueReconciliation()
    }

    /// Does not stop capture or alter the saved enable/selection preferences.
    func uninstall() {
        installed = false; installation &+= 1
        terminationTask?.cancel(); terminationTask = nil
        reconcileTask?.cancel(); reconcileTask = nil
        for token in tokens { workspaceCenter.removeObserver(token) }
        tokens = []; stateProvider = nil; startCallback = nil; stopCallback = nil
        reconciliationPending = false
    }

    func runtimeChanged() {
        if let runtime = stateProvider?() {
            if startDeferredAt != runtime { startDeferredAt = nil }
            if stopDeferredAt != runtime { stopDeferredAt = nil }
        }
        enqueueReconciliation()
    }

    /// Invoke only for an explicit user request (including a restored user
    /// replay intent), never for this controller's or privacy-resume callbacks.
    func userRequestedStart() {
        policy.userRequestedStart(); startDeferredAt = nil; stopDeferredAt = nil
        publishState(); enqueueReconciliation()
    }

    /// Invoke before stopping from UI/hotkey/menu. Suppression survives focus
    /// changes and transient game relaunches, until the selected games close.
    func userRequestedStop() {
        policy.userRequestedStop(); startDeferredAt = nil; stopDeferredAt = nil
        publishState(); enqueueReconciliation()
    }

    func retry() {
        guard configurationReadable else { return }
        error = nil; policy.retry(); startDeferredAt = nil; stopDeferredAt = nil
        enqueueReconciliation()
    }

    func add(_ application: GameAutoCaptureApplication) {
        guard configurationReadable,
              let id = GameAutoCaptureApplication.normalizedID(application.bundleID),
              !selectedBundleIDs.contains(id) else { return }
        selectedApplications.append(GameAutoCaptureApplication(bundleID: id, name: application.name.isEmpty ? id : application.name))
        selectedApplications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistApplications(); refreshRunningApplications(selectionChanged: true)
    }

    func remove(_ application: GameAutoCaptureApplication) {
        guard configurationReadable, selectedBundleIDs.contains(application.id) else { return }
        selectedApplications.removeAll { $0.id == application.id }
        persistApplications(); refreshRunningApplications(selectionChanged: true)
    }

    func resetUnreadableApplications() {
        guard !configurationReadable else { return }
        selectedApplications = []; configurationReadable = true; error = nil
        persistApplications(); refreshRunningApplications(selectionChanged: true)
    }

    func chooseApplications() {
        guard configurationReadable else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите игры для автозапуска повтора"
        panel.prompt = "Добавить"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            add(GameAutoCaptureApplication(bundleID: id, name: name))
        }
    }

    /// Launch/termination notifications, not activation/focus, drive recording.
    func refreshRunningApplications(selectionChanged: Bool = false) {
        processes = runningProvider()
        var seen: Set<String> = []
        runningApplications = processes.compactMap { process in
            guard process.selectable, let id = GameAutoCaptureApplication.normalizedID(process.bundleID), seen.insert(id).inserted else { return nil }
            return GameAutoCaptureApplication(bundleID: id, name: process.name.isEmpty ? id : process.name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let current = matchingIDs()
        activeApplications = selectedApplications.filter { current.contains($0.id) }
        if !current.isEmpty || effectiveActiveIDs.isEmpty || selectionChanged || terminationDelayNanoseconds == 0 {
            terminationTask?.cancel(); terminationTask = nil
            effectiveActiveIDs = current
            synchronizePolicy(); enqueueReconciliation()
        } else if terminationTask == nil {
            // A short grace period avoids stopping and clearing the ring during
            // a game's quick helper-process handoff or relaunch.
            let generation = installation
            terminationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: self.terminationDelayNanoseconds) } catch { return }
                guard !Task.isCancelled, self.installation == generation else { return }
                self.terminationTask = nil
                self.processes = self.runningProvider()
                self.effectiveActiveIDs = self.matchingIDs()
                self.activeApplications = self.selectedApplications.filter { self.effectiveActiveIDs.contains($0.id) }
                self.synchronizePolicy(); self.enqueueReconciliation()
            }
        }
    }

    static func liveProcesses() -> [GameAutoCaptureProcess] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let id = app.bundleIdentifier,
                  GameAutoCaptureApplication.normalizedID(id) != nil else { return nil }
            return GameAutoCaptureProcess(processID: app.processIdentifier, bundleID: id,
                name: app.localizedName ?? id, selectable: app.activationPolicy == .regular)
        }
    }

    private func matchingIDs() -> Set<String> {
        Set(processes.compactMap { GameAutoCaptureApplication.normalizedID($0.bundleID) }).intersection(selectedBundleIDs)
    }

    private func persistApplications() {
        do { defaults.set(try JSONEncoder().encode(selectedApplications), forKey: Self.applicationsKey) }
        catch { self.error = "Не удалось сохранить список игр: " + error.localizedDescription }
    }

    private func synchronizePolicy() {
        let previousCycle = policy.cycle
        let previouslyStopping = policy.shouldStop
        policy.update(enabled: enabled && configurationReadable, activeGames: effectiveActiveIDs)
        if previousCycle != policy.cycle {
            startDeferredAt = nil; stopDeferredAt = nil
            if configurationReadable { error = nil }
        } else if !previouslyStopping && policy.shouldStop {
            stopDeferredAt = nil
        }
        publishState()
    }

    private func enqueueReconciliation() {
        reconciliationPending = true
        guard installed, reconcileTask == nil else { return }
        let generation = installation
        reconcileTask = Task { @MainActor [weak self] in await self?.reconcile(generation: generation) }
    }

    private func reconcile(generation: UInt64) async {
        while reconciliationPending && installed && installation == generation && !Task.isCancelled {
            reconciliationPending = false
            guard let runtime = stateProvider?() else { break }
            let action = policy.decision(runtime)
            publishState()
            switch action {
            case .start:
                guard startDeferredAt == nil, let startCallback else { continue }
                operation = .start; publishState()
                let ticket = policy.beginStart()
                let result = await startCallback()
                guard installed, installation == generation, !Task.isCancelled else { break }
                policy.completedStart(result, ticket: ticket)
                operation = nil
                switch result {
                case .started:
                    error = nil
                    onDiagnostic?("Автозапуск: повтор включён для выбранной игры.")
                    reconciliationPending = true
                case .deferred:
                    startDeferredAt = stateProvider?()
                case .failed(let message):
                    error = message
                    onDiagnostic?("Автозапуск повтора: " + message)
                }
            case .stop:
                guard stopDeferredAt == nil, let stopCallback else { continue }
                operation = .stop; publishState()
                let stopped = await stopCallback()
                guard installed, installation == generation, !Task.isCancelled else { break }
                operation = nil
                if stopped {
                    policy.completedStop()
                    onDiagnostic?("Автозапуск: буфер сохранён, автоматический повтор остановлен.")
                    reconciliationPending = true
                } else {
                    stopDeferredAt = stateProvider?()
                    if policy.shouldStop, stopDeferredAt?.canStop == true {
                        error = "Автоматическая остановка отложена. Проверьте сохранение буфера и повторите попытку."
                    }
                }
            case nil: break
            }
            publishState()
        }
        if installation == generation { reconcileTask = nil; operation = nil; publishState() }
    }

    private func publishState() {
        ownsReplay = policy.ownsReplay; isSuppressed = policy.isSuppressed
        if !configurationReadable { status = "Автозапуск приостановлен: список игр недоступен" }
        else if operation == .start { status = "Запускаем мгновенный повтор…" }
        else if operation == .stop { status = "Сохраняем буфер и останавливаем повтор…" }
        else if policy.shouldStop { status = "Ожидаем сохранения и остановки автоматического повтора" }
        else if !enabled { status = "Автозапуск выключен" }
        else if selectedApplications.isEmpty { status = "Добавьте игру или приложение" }
        else if policy.isSuppressed { status = "Остановлено вручную до следующего запуска игры" }
        else if policy.userOwnsReplay { status = "Повтор включён вручную: закрытие игры его не остановит" }
        else if policy.ownsReplay { status = "Автоматический повтор включён" }
        else if policy.failedCycle == policy.cycle { status = "Автозапуск не удался; повторите вручную или перезапустите игру" }
        else if !policy.activeGames.isEmpty { status = "Игра запущена. Ожидаем окончания записи, проверки или паузы" }
        else { status = "Ожидаем запуск выбранной игры" }
    }
}
