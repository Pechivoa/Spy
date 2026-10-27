import SwiftUI
import AppKit

enum ApplicationAudioMode: String, CaseIterable, Codable, Identifiable {
    case all, selected
    var id: String { rawValue }
    var title: String { self == .all ? "Все приложения" : "Только выбранные" }
}

enum ApplicationAudioPolicy {
    static func allowedBundleIDs(selected: Set<String>, excluded: Set<String>, ownBundleID: String? = "local.spy.mac") -> Set<String> {
        CapturePrivacyPolicy.normalizedIDs(selected)
            .subtracting(CapturePrivacyPolicy.normalizedIDs(excluded))
            .subtracting(CapturePrivacyPolicy.normalizedIDs([ownBundleID ?? "local.spy.mac"]))
    }
}

/// The audio selection is global and independent of app quality/mic profiles.
/// Missing selected apps remain selected; they must never mean "all audio".
@MainActor final class ApplicationAudioSelection: ObservableObject {
    @Published var mode: ApplicationAudioMode {
        didSet { defaults.set(mode.rawValue, forKey: "applicationAudioMode") }
    }
    @Published private(set) var selectedApplications: [PrivacyApplication]
    @Published private(set) var runningApplications: [PrivacyApplication] = []
    var bundleIDs: Set<String> { CapturePrivacyPolicy.normalizedIDs(selectedApplications.map(\.bundleID)) }
    var onApplicationsChanged: (() -> Void)?
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let rawMode = defaults.string(forKey: "applicationAudioMode")
        let knownMode = rawMode.flatMap(ApplicationAudioMode.init(rawValue:))
        mode = knownMode ?? (rawMode == nil ? .all : .selected)
        let saved = (rawMode != nil && knownMode == nil ? nil : defaults.data(forKey: "applicationAudioApplications"))
            .flatMap { try? JSONDecoder().decode([PrivacyApplication].self, from: $0) } ?? []
        var seen = Set<String>()
        selectedApplications = saved.compactMap { app in
            guard let id = CapturePrivacyPolicy.normalizedIDs([app.bundleID]).first,
                  id != (Bundle.main.bundleIdentifier ?? "local.spy.mac").lowercased(), seen.insert(id).inserted else { return nil }
            return PrivacyApplication(bundleID: id, name: app.name)
        }
    }
    deinit {
        refreshTask?.cancel()
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
    func install() {
        guard observers.isEmpty else { return }
        refresh()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
    }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // Workspace notifications can arrive before ScreenCaptureKit has
            // replaced a terminated app's PID. Bounded retries reconnect the
            // same selected bundle after a restart without broadening capture.
            let delays: [UInt64] = [350_000_000, 1_000_000_000, 2_000_000_000]
            for delay in delays {
                do { try await Task.sleep(nanoseconds: delay); try Task.checkCancellation() }
                catch { return }
                self?.refresh(notifyCapture: true)
                if self?.mode != .selected { break }
            }
        }
    }
    func refresh(notifyCapture: Bool = false) {
        let own = (Bundle.main.bundleIdentifier ?? "local.spy.mac").lowercased()
        var seen = Set<String>()
        runningApplications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let raw = app.bundleIdentifier,
                  let id = CapturePrivacyPolicy.normalizedIDs([raw]).first, id != own,
                  seen.insert(id).inserted else { return nil }
            return PrivacyApplication(bundleID: id, name: app.localizedName ?? raw)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if notifyCapture { onApplicationsChanged?() }
    }
    func setSelected(_ app: PrivacyApplication, _ selected: Bool) {
        guard let id = CapturePrivacyPolicy.normalizedIDs([app.bundleID]).first,
              id != (Bundle.main.bundleIdentifier ?? "local.spy.mac").lowercased() else { return }
        selectedApplications.removeAll { $0.bundleID == id }
        if selected { selectedApplications.append(PrivacyApplication(bundleID: id, name: app.name)) }
        selectedApplications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(selectedApplications) { defaults.set(data, forKey: "applicationAudioApplications") }
    }
}

struct ApplicationAudioPickerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var selection: ApplicationAudioSelection
    init(model: AppModel) {
        self.model = model
        _selection = ObservedObject(wrappedValue: model.applicationAudio)
    }
    private var cannotChange: Bool { model.recording || model.busy || model.saving || model.diagnosticsBusy }
    private var choices: [PrivacyApplication] {
        var result = selection.runningApplications
        let running = Set(result.map(\.bundleID))
        result += selection.selectedApplications.filter { !running.contains($0.bundleID) }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2").foregroundStyle(Theme.muted)
                Picker("Системный звук", selection: $selection.mode) {
                    ForEach(ApplicationAudioMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().disabled(cannotChange || !model.systemAudio)
                Button { selection.refresh(notifyCapture: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).help("Обновить приложения и выбранный звук")
            }
            if selection.mode == .selected {
                Menu {
                    if choices.isEmpty { Text("Откройте нужное приложение и обновите список") }
                    ForEach(choices) { app in
                        Toggle(app.name + (selection.runningApplications.contains(where: { $0.bundleID == app.bundleID }) ? "" : " · не запущено"),
                            isOn: Binding(get: { selection.bundleIDs.contains(app.bundleID) }, set: { selection.setSelected(app, $0) }))
                    }
                } label: {
                    Label(selection.selectedApplications.isEmpty ? "Выбрать приложения…" : selection.selectedApplications.map(\.name).joined(separator: ", "), systemImage: "checklist")
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.menuStyle(.borderlessButton).disabled(cannotChange || !model.systemAudio)
                Text("Записывается только звук выбранных приложений. Микрофон задаётся отдельно. Приложения из списка приватности исключаются и из этого звука.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if selection.selectedApplications.isEmpty && !model.recording {
                    Text("Пока ничего не выбрано — системный звук не будет записан.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
            if let issue = model.applicationAudioIssue, model.systemAudio {
                Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                    .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            } else if cannotChange {
                Text("Чтобы изменить приложения со звуком, остановите повтор.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }.font(.system(size: 11)).onAppear { selection.refresh() }
    }
}
