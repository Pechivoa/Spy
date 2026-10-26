import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

struct PrivacyApplication: Codable, Identifiable, Equatable {
    let bundleID: String
    var name: String
    var id: String { bundleID.lowercased() }
}

enum CapturePrivacyPolicy {
    static func normalizedIDs(_ ids: some Sequence<String>) -> Set<String> {
        Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 255 && !$0.contains(where: \.isWhitespace) })
    }
    static func excludes(_ bundleID: String?, selected: Set<String>, ownBundleID: String? = "local.spy.mac") -> Bool {
        guard let bundleID else { return false }
        let normalized = bundleID.lowercased()
        return normalized == ownBundleID?.lowercased() || selected.contains(normalized)
    }
    static func validateWindowOwner(_ bundleID: String?, selected: Set<String>, ownBundleID: String? = "local.spy.mac") throws {
        guard !excludes(bundleID, selected: selected, ownBundleID: ownBundleID) else {
            throw SpyError.message("Окно этого приложения исключено из записи. Выберите другое окно или уберите приложение из списка приватности.")
        }
    }
}

/// AppKit documents session switching separately from screen locking:
/// https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification
/// Distributed screen-lock names supplement that public API; they are not a
/// public AppKit contract. Display sleep and session notifications are fallbacks.
@MainActor final class PrivacyController: ObservableObject {
    enum BlockReason: Hashable { case screenLocked, sessionInactive, displayAsleep }
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    @Published var pauseOnLock: Bool {
        didSet {
            defaults.set(pauseOnLock, forKey: "privacyPauseOnLock")
            reportBlockingChange()
        }
    }
    @Published private(set) var excludedApplications: [PrivacyApplication]
    @Published private(set) var runningApplications: [PrivacyApplication] = []
    @Published private(set) var blockReasons: Set<BlockReason> = []
    @Published private(set) var error: String?
    @Published private(set) var exclusionsReadable = true
    var excludedBundleIDs: Set<String> { CapturePrivacyPolicy.normalizedIDs(excludedApplications.map(\.bundleID)) }
    var isBlocked: Bool { pauseOnLock && !blockReasons.isEmpty }
    var onDiagnostic: ((String) -> Void)?

    private let defaults: UserDefaults
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let runningProvider: @MainActor () -> [PrivacyApplication]
    private let lockHintProvider: @MainActor () -> Bool
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var blockingCallback: ((Bool) -> Void)?
    private var filterCallback: (() -> Void)?
    private var lastReportedBlock = false

    init(defaults: UserDefaults,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
         runningApplications: @escaping @MainActor () -> [PrivacyApplication] = PrivacyController.liveApplications,
         initialScreenLocked: Bool = false,
         screenLockHint: @escaping @MainActor () -> Bool = PrivacyController.currentScreenLockHint) {
        self.defaults = defaults
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        runningProvider = runningApplications
        lockHintProvider = screenLockHint
        pauseOnLock = defaults.object(forKey: "privacyPauseOnLock") == nil ? true : defaults.bool(forKey: "privacyPauseOnLock")
        let saved: [PrivacyApplication]
        var readFailure: String?
        if let data = defaults.data(forKey: "privacyExcludedApplications") {
            do { saved = try JSONDecoder().decode([PrivacyApplication].self, from: data) }
            catch {
                saved = []
                readFailure = "Не удалось прочитать исключения приложений. Запись заблокирована, пока вы не восстановите или не сбросите список."
            }
        } else { saved = [] }
        var seen: Set<String> = []
        excludedApplications = saved.compactMap { app in
            guard let id = CapturePrivacyPolicy.normalizedIDs([app.bundleID]).first,
                  id != "local.spy.mac", seen.insert(id).inserted else { return nil }
            return PrivacyApplication(bundleID: id, name: app.name.isEmpty ? id : app.name)
        }
        if let readFailure { exclusionsReadable = false; error = readFailure }
        if initialScreenLocked { blockReasons.insert(.screenLocked) }
        refreshRunningApplications()
    }

    deinit {
        for token in workspaceTokens { workspaceCenter.removeObserver(token) }
        for token in distributedTokens { distributedCenter.removeObserver(token) }
    }

    func install(onBlockingChanged: @escaping (Bool) -> Void, onFilterRefresh: @escaping () -> Void) {
        blockingCallback = onBlockingChanged
        filterCallback = onFilterRefresh
        if workspaceTokens.isEmpty && distributedTokens.isEmpty {
            observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, reason: .sessionInactive, blocked: true)
            observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, reason: .sessionInactive, blocked: false)
            observe(workspaceCenter, NSWorkspace.screensDidSleepNotification, reason: .displayAsleep, blocked: true)
            observe(workspaceCenter, NSWorkspace.screensDidWakeNotification, reason: .displayAsleep, blocked: false)
            observe(distributedCenter, Self.screenLocked, reason: .screenLocked, blocked: true)
            observe(distributedCenter, Self.screenUnlocked, reason: .screenLocked, blocked: false)
            for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let identifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    Task { @MainActor in self?.applicationChanged(bundleID: identifier) }
                }
                workspaceTokens.append(token)
            }
        }
        // Report the current state too, including a lock hint supplied by the
        // app at launch, rather than waiting for the next lock transition.
        lastReportedBlock = !isBlocked
        reportBlockingChange()
    }

    func uninstall() {
        for token in workspaceTokens { workspaceCenter.removeObserver(token) }
        for token in distributedTokens { distributedCenter.removeObserver(token) }
        workspaceTokens = []; distributedTokens = []
        blockingCallback = nil; filterCallback = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: BlockReason, blocked: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !blocked, reason != .screenLocked, self.lockHintProvider() {
                    // The distributed lock event may have arrived while the
                    // process slept. Establish the lock before releasing the
                    // display/session reason, with no intermediate unblocked state.
                    self.setBlocked(true, reason: .screenLocked)
                }
                self.setBlocked(blocked, reason: reason)
            }
        }
        if center === workspaceCenter { workspaceTokens.append(token) }
        else { distributedTokens.append(token) }
    }

    func setBlocked(_ blocked: Bool, reason: BlockReason) {
        if blocked { blockReasons.insert(reason) } else { blockReasons.remove(reason) }
        reportBlockingChange()
    }

    private func reportBlockingChange() {
        let blocked = isBlocked
        guard blocked != lastReportedBlock else { return }
        lastReportedBlock = blocked
        blockingCallback?(blocked)
    }

    /// The app must gate frame ingestion before asynchronously updating its
    /// SCContentFilter. A newly launching excluded process gets a fresh PID.
    func applicationChanged(bundleID: String?) {
        refreshRunningApplications()
        if let bundleID, excludedBundleIDs.contains(bundleID.lowercased()) { filterCallback?() }
    }

    func add(_ application: PrivacyApplication) {
        guard exclusionsReadable else { return }
        guard let id = CapturePrivacyPolicy.normalizedIDs([application.bundleID]).first, id != "local.spy.mac" else { return }
        guard !excludedApplications.contains(where: { $0.id == id }) else { return }
        excludedApplications.append(PrivacyApplication(bundleID: id, name: application.name.isEmpty ? id : application.name))
        excludedApplications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistExclusions()
        filterCallback?()
    }
    func remove(_ application: PrivacyApplication) {
        guard exclusionsReadable else { return }
        guard excludedApplications.contains(where: { $0.id == application.id }) else { return }
        excludedApplications.removeAll { $0.id == application.id }
        persistExclusions()
        filterCallback?()
    }
    func validateConfiguration() throws {
        guard exclusionsReadable else { throw SpyError.message(error ?? "Список исключений недоступен.") }
    }
    func resetUnreadableExclusions() {
        guard !exclusionsReadable else { return }
        excludedApplications = []; exclusionsReadable = true
        persistExclusions(); filterCallback?()
    }
    private func persistExclusions() {
        do {
            defaults.set(try JSONEncoder().encode(excludedApplications), forKey: "privacyExcludedApplications")
            error = nil
        } catch {
            self.error = "Не удалось сохранить исключения: " + error.localizedDescription
            onDiagnostic?(self.error!)
        }
    }
    func refreshRunningApplications() {
        var seen: Set<String> = []
        runningApplications = runningProvider().filter {
            $0.id != "local.spy.mac" && seen.insert($0.id).inserted
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func liveApplications() -> [PrivacyApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return PrivacyApplication(bundleID: id, name: app.localizedName ?? id)
        }
    }

    /// Only an initial hint: the dictionary key is not a public lock API.
    /// Ongoing state comes from lock/session/display notifications above.
    static func currentScreenLockHint() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "Исключить приложения из видео"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            add(PrivacyApplication(bundleID: id, name: name))
        }
    }
}

struct PrivacySettingsView: View {
    @ObservedObject var controller: PrivacyController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Приватность", systemImage: "eye.slash").font(.system(size: 18, weight: .semibold))
            Toggle("Пауза при блокировке Mac", isOn: $controller.pauseOnLock).toggleStyle(.switch)
            Text("При блокировке, смене пользователя или выключении экрана захват приостанавливается. Накопленный буфер остаётся доступен после возвращения.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
            Divider().overlay(Theme.border)
            HStack {
                Text("Исключённые приложения").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu("Добавить") {
                    ForEach(controller.runningApplications.filter { app in !controller.excludedBundleIDs.contains(app.id) }) { app in
                        Button(app.name) { controller.add(app) }
                    }
                    Divider()
                    Button("Выбрать приложение…") { controller.chooseApplications() }
                    Button("Обновить список") { controller.refreshRunningApplications() }
                }.menuStyle(.borderlessButton).fixedSize().disabled(!controller.exclusionsReadable)
            }
            Text("Окна этих приложений скрыты в записи всего экрана. Для отдельного окна Spy проверит исключение перед запуском. Системный звук задаётся общим переключателем записи звука.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
            if controller.excludedApplications.isEmpty {
                Text("Исключений пока нет").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                ForEach(controller.excludedApplications) { app in
                    HStack {
                        Image(systemName: "app.dashed").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.system(size: 12))
                            Text(app.bundleID).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Button { controller.remove(app) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Убрать из исключений").accessibilityLabel("Убрать " + app.name + " из исключений")
                    }.padding(10).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger)
                if !controller.exclusionsReadable {
                    Button("Сбросить повреждённый список") { controller.resetUnreadableExclusions() }.buttonStyle(.bordered)
                }
            }
        }
    }
}
