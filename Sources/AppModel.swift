import SwiftUI
import AppKit
import AVFoundation
import Carbon
import UniformTypeIdentifiers
import ScreenCaptureKit

struct Clip: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let date: Date
    let bytes: Int64
    var duration: Double = 0
    var name: String = ""
    var favorite: Bool = false
    var managed: Bool = true
    init(url: URL, date: Date, bytes: Int64, duration: Double = 0, name: String = "", favorite: Bool = false, managed: Bool = true) {
        self.url = url.spyFileURL; self.date = date; self.bytes = bytes
        self.duration = duration; self.name = name; self.favorite = favorite; self.managed = managed
    }
    var title: String { name.isEmpty ? dateTitle : name }
    var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = SpyDates.timeZone
        formatter.dateFormat = "d MMMM · HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct DisplayChoice: Identifiable {
    var id: CGDirectDisplayID
    var name: String
    var uuid: String? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var minutes: Double {
        didSet {
            preferences.set(minutes, forKey: "minutes")
            engine.updateLimit(effectiveMinutes * 60)
            automationRuntimeChanged()
            if minutes == 0 { setReplayIntent(false) }
            if minutes == 0 && recording && !manualRecording { Task { await stop() } }
        }
    }
    @Published var quality: Quality { didSet { preferences.set(quality.rawValue, forKey: "quality") } }
    @Published var systemAudio: Bool { didSet { preferences.set(systemAudio, forKey: "audio") } }
    let applicationAudio: ApplicationAudioSelection
    let captureTuning: CaptureTuningSettings
    lazy var captureRecovery = CaptureRecovery(defaults: preferences)
    lazy var captureHealth = CaptureHealth()
    lazy var sessions = SessionHistory(url: journal.fileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sessions.json"))
    var healthTimer: Timer?
    lazy var updates = AppUpdates(loadReceipt: !previewMode)
    @Published var applicationAudioIssue: String?
    @Published var microphone: Bool { didSet { preferences.set(microphone, forKey: "microphone") } }
    @Published var captureMode: CaptureMode { didSet { preferences.set(captureMode.rawValue, forKey: "captureMode") } }
    @Published var windowID: CGWindowID = 0 { didSet { preferences.set(Int(windowID), forKey: "windowID") } }
    @Published var windows: [WindowChoice] = []
    @Published var windowsLoading = false
    @Published var microphones: [MicrophoneChoice] = []
    @Published var microphoneID: String { didSet { preferences.set(microphoneID, forKey: "microphoneID") } }
    @Published var systemVolume: Double { didSet { preferences.set(systemVolume, forKey: "systemVolume") } }
    @Published var microphoneVolume: Double { didSet { preferences.set(microphoneVolume, forKey: "microphoneVolume") } }
    @Published var audioMeter = AudioMeter()
    @Published var autoCleanup: Bool { didSet { preferences.set(autoCleanup, forKey: "autoCleanup") } }
    @Published var libraryLimitGB: Double {
        didSet {
            libraryLimitGB = libraryLimitGB.isFinite ? min(500, max(1, libraryLimitGB)) : 10
            preferences.set(libraryLimitGB, forKey: "libraryLimitGB")
        }
    }
    @Published var maximumAgeDays: Int { didSet { preferences.set(maximumAgeDays, forKey: "maximumAgeDays") } }
    @Published var notificationsEnabled: Bool { didSet { preferences.set(notificationsEnabled, forKey: "notifications") } }
    @Published var cleanupBusy = false
    let metadata: LibraryMetadata
    let preferences: UserDefaults
    let privacy: PrivacyController
    let performance = PerformanceMonitor()
    var showMainWindow: (() -> Void)?
    let toast = SaveToast()
    var cleanupTimer: Timer?
    var lastOverLimitBytes: Int64?
    @Published var displays: [DisplayChoice] = []
    @Published var displayID: CGDirectDisplayID = CGMainDisplayID() {
        didSet { preferences.set(Int(displayID), forKey: "displayID"); rememberDisplayIdentity() }
    }
    @Published var recording = false { didSet {
        updateHUD(); automationRuntimeChanged()
        guard oldValue != recording else { return }
        if recording {
            let id = engine.captureProgress()?.sessionID ?? UUID()
            captureHealth.reset(session: id)
            captureHealth.sample.wantsSystem = systemAudio; captureHealth.sample.wantsMicrophone = microphone
            sessions.begin(id: id, source: (captureMode == .display ? (selectedDisplay?.name ?? "Экран") : "Окно") + " · " + effectiveQuality.title)
        } else {
            sessions.end(reason: captureFailure ?? "Запись остановлена")
            captureHealth.check(active: false, paused: false)
        }
    } }
    @Published var busy = false { didSet { automationRuntimeChanged(); if !busy { flushCaptureFailure(); if pendingPrivacyUpdate { Task { await reconcilePrivacyState() } } } } }
    @Published var manualSaving = false { didSet { automationRuntimeChanged() } }
    @Published var autoClipExports = 0 { didSet { automationRuntimeChanged() } }
    @Published var queuedExports = 0 { didSet { automationRuntimeChanged() } }
    var previewBusy: Bool { manualSaving || autoClipExports > 0 }
    var saving: Bool { get { previewBusy || queuedExports > 0 } set { manualSaving = newValue } }
    lazy var exportQueue = ExportQueueController(pendingChanged: { [weak self] count in
        guard let self else { return }; self.queuedExports = count
        if count == 0 {
            self.refreshRecoveryFolders()
            Task { await self.reconcilePendingChanges() }
        }
    }, canStart: { [weak self] in self?.previewBusy == false }, diagnostic: { [weak self] text, failed in
        guard let self else { return }
        self.journal.record(failed ? .error : .info, "Очередь сохранения", text)
        if failed {
            self.message = "Не удалось сохранить фрагмент. Подробности — в очереди и журнале."
            if self.notificationsEnabled && !self.previewMode { self.toast.show(title: "Ошибка сохранения", detail: "Подробности — в очереди и журнале.", displayID: self.displayID) }
        }
    })
    @Published var diagnosticsBusy = false { didSet { automationRuntimeChanged() } }
    var automationInstalled = false
    var sessionRestorationFinished = false
    var markerCaptureTasks: [UUID: Task<Void, Never>] = [:]
    var protectedAutoClipURLs: Set<URL> = []
    lazy var gameAutoCapture = GameAutoCaptureController(defaults: preferences)
    lazy var recordingDiagnostics = RecordingDiagnostics(access: captureAccess)
    lazy var autoMomentClips = AutoMomentClipController(defaults: preferences, engine: engine, onReady: { [weak self] job in
        guard let self else { throw CancellationError() }
        return try await self.publishAutoMoment(job)
    }, onDiagnostic: { [weak self] text, failed in
        self?.journal.record(failed ? .error : .info, "Автоклип", text)
        self?.refreshRecoveryFolders()
    })
    @Published var preparingBufferPreview = false
    @Published var privacyPaused = false { didSet {
        updateHUD(); automationRuntimeChanged()
        if oldValue != privacyPaused && recording { if !privacyPaused { captureHealth.snooze() }; sessions.event(privacyPaused ? "pause" : "resume", privacyPaused ? "Пауза приватности" : "Запись продолжена") }
    } }
    @Published var manualPrivacyPause = false
    var privacyTransitionRunning = false
    var pendingPrivacyUpdate = false
    @Published var microphoneCleanup = false { didSet { preferences.set(microphoneCleanup, forKey: "microphoneCleanup") } }
    let bufferViewer = VideoViewerWindow()
    let savedViewer = VideoViewerWindow()
    let queueViewer = VideoViewerWindow()
    @Published var bufferPreview: BufferPreview? { didSet {
        if oldValue?.id != bufferPreview?.id { presentBufferViewer() }
    } }
    @Published var stats = BufferStats() { didSet { updateHUD() } }
    @Published var clips: [Clip] = []
    @Published var selectedClip: Clip? { didSet {
        if oldValue?.id != selectedClip?.id { presentSavedViewer() }
    } }
    @Published var message: String?
    @Published var error: String?
    @Published var needsPermission = false
    @Published var needsMicrophonePermission = false
    @Published var captureIssue: String?
    @Published var startupStatus: String?
    var captureFailure: String?
    var recordingWindowProcessID: pid_t?
    var pendingCaptureStop = false
    let captureAccess: CaptureAccess
    // Test seam runs the normal app startup state machine without OS prompts.
    var captureStartOverride: ((RecordingConfig) async throws -> Void)?
    @Published var section = 0
    @Published var freeSpace: Int64 = 0
    @Published var hotkeyAvailable = true
    @Published private(set) var shortcuts: ShortcutBindings
    @Published var editingShortcut: ShortcutAction?
    let journal: EventJournal
    let engine: SpyEngine
    @Published var libraryURL: URL { didSet { libraryMonitor?.watch(libraryURL); librarySignature = nil } }
    var libraryMonitor: LibraryMonitor?
    var librarySignature: [URL: String]?
    var clipFileSignatures: [URL: String] = [:]
    var activeLibraryLoads = 0
    let cacheURL: URL
    @Published var manualRecording = false { didSet { updateHUD(); automationRuntimeChanged() } }
    @Published var recoveryFolders: [URL] = []
    @Published var separateAudio: Bool = false { didSet { preferences.set(separateAudio, forKey: "separateAudio") } }
    @Published var profiles: [AppProfile] = [] { didSet { if let data = try? JSONEncoder().encode(profiles) { preferences.set(data, forKey: "profiles") } } }
    @Published var profileAutomatic = true { didSet { preferences.set(profileAutomatic, forKey: "profileAutomatic") } }
    @Published var activeProfileName: String?
    @Published var pendingProfile: AppProfile?
    @Published var hudEnabled = true { didSet { preferences.set(hudEnabled, forKey: "hudEnabled"); updateHUD() } }
    @Published var hudCorner: HUDCorner = .bottomRight { didSet { preferences.set(hudCorner.rawValue, forKey: "hudCorner"); updateHUD() } }
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var loginBusy = false
    @Published var startBufferOnLaunch = false { didSet { preferences.set(startBufferOnLaunch, forKey: "startBufferOnLaunch") } }
    @Published var rememberReplay = true { didSet { preferences.set(rememberReplay, forKey: "rememberReplay") } }
    @Published var saveBufferOnExit = true { didSet { preferences.set(saveBufferOnExit, forKey: "saveBufferOnExit") } }
    private(set) var lastReplayEnabled = false
    var shuttingDown = false
    @Published var batterySaving = false { didSet { preferences.set(batterySaving, forKey: "batterySaving"); requestPowerUpdate() } }
    @Published var batteryQuality: Quality = .compact { didSet { preferences.set(batteryQuality.rawValue, forKey: "batteryQuality"); requestPowerUpdate() } }
    @Published var batteryMinutes: Double = 2 { didSet { preferences.set(batteryMinutes, forKey: "batteryMinutes"); requestPowerUpdate() } }
    @Published var onBattery = false
    let hud = HUDOverlay()
    var powerMonitor: PowerMonitor?
    var proObservers: [NSObjectProtocol] = []
    var pendingPowerUpdate = false
    var switchingConfiguration = false { didSet { automationRuntimeChanged() } }
    var manualStartedCapture = false
    var recordingQuality: Quality?
    var recordingMinutes: Double?
    private var loadID = UUID()
    private var hotkeys: HotKeys?
    var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    let previewMode: Bool

    init(preview: Bool = false, defaults suppliedDefaults: UserDefaults? = nil, captureAccess: CaptureAccess? = nil) {
        self.captureAccess = captureAccess ?? .live
        let defaults = suppliedDefaults ?? (preview ? UserDefaults(suiteName: "Spy.Preview." + UUID().uuidString)! : UserDefaults.standard)
        preferences = defaults
        captureTuning = CaptureTuningSettings(defaults: defaults)
        privacy = PrivacyController(defaults: defaults, initialScreenLocked: !preview && PrivacyController.currentScreenLockHint())
        shortcuts = preview ? ShortcutBindings() : ShortcutBindings.load(from: defaults)
        minutes = defaults.object(forKey: "minutes") == nil ? 5 : min(30, max(0, defaults.double(forKey: "minutes")))
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced
        systemAudio = defaults.object(forKey: "audio") == nil ? true : defaults.bool(forKey: "audio")
        applicationAudio = ApplicationAudioSelection(defaults: defaults)
        microphone = preview ? false : defaults.bool(forKey: "microphone")
        microphoneCleanup = defaults.bool(forKey: "microphoneCleanup")
        captureMode = CaptureMode(rawValue: defaults.string(forKey: "captureMode") ?? "") ?? .display
        windowID = CGWindowID(clamping: defaults.integer(forKey: "windowID"))
        displayID = defaults.object(forKey: "displayID") == nil ? CGMainDisplayID() : CGDirectDisplayID(clamping: defaults.integer(forKey: "displayID"))
        microphoneID = defaults.string(forKey: "microphoneID") ?? ""
        systemVolume = defaults.object(forKey: "systemVolume") == nil ? 1 : min(1, max(0, defaults.double(forKey: "systemVolume")))
        microphoneVolume = defaults.object(forKey: "microphoneVolume") == nil ? 1 : min(1, max(0, defaults.double(forKey: "microphoneVolume")))
        autoCleanup = defaults.bool(forKey: "autoCleanup")
        libraryLimitGB = defaults.object(forKey: "libraryLimitGB") == nil ? 10 : min(500, max(1, defaults.double(forKey: "libraryLimitGB")))
        maximumAgeDays = min(365, max(0, defaults.integer(forKey: "maximumAgeDays")))
        notificationsEnabled = defaults.object(forKey: "notifications") == nil ? true : defaults.bool(forKey: "notifications")
        let previewRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SpyPreview-" + UUID().uuidString, isDirectory: true)
        let defaultLibrary = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Spy", isDirectory: true)
        libraryURL = preview ? previewRoot.appendingPathComponent("Library") : defaults.string(forKey: "libraryPath").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultLibrary
        separateAudio = defaults.bool(forKey: "separateAudio")
        if let data = defaults.data(forKey: "profiles"), let saved = try? JSONDecoder().decode([AppProfile].self, from: data) { profiles = saved.filter { (try? $0.settings.validate()) != nil } }
        profileAutomatic = defaults.object(forKey: "profileAutomatic") == nil ? true : defaults.bool(forKey: "profileAutomatic")
        hudEnabled = defaults.object(forKey: "hudEnabled") == nil ? true : defaults.bool(forKey: "hudEnabled")
        hudCorner = HUDCorner(rawValue: defaults.string(forKey: "hudCorner") ?? "") ?? .bottomRight
        startBufferOnLaunch = defaults.bool(forKey: "startBufferOnLaunch")
        rememberReplay = defaults.object(forKey: "rememberReplay") == nil ? true : defaults.bool(forKey: "rememberReplay")
        saveBufferOnExit = defaults.object(forKey: "saveBufferOnExit") == nil ? true : defaults.bool(forKey: "saveBufferOnExit")
        lastReplayEnabled = defaults.bool(forKey: "lastReplayEnabled")
        batterySaving = defaults.bool(forKey: "batterySaving")
        batteryQuality = Quality(rawValue: defaults.string(forKey: "batteryQuality") ?? "") ?? .compact
        batteryMinutes = defaults.object(forKey: "batteryMinutes") == nil ? 2 : min(30, max(0.5, defaults.double(forKey: "batteryMinutes")))
        cacheURL = preview ? previewRoot.appendingPathComponent("Cache") : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.spy.mac", isDirectory: true)
        let support = preview ? previewRoot : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spy", isDirectory: true)
        journal = EventJournal(fileURL: support.appendingPathComponent("Journal/events.json"))
        metadata = LibraryMetadata(url: support.appendingPathComponent("LibraryMetadata.json"))
        previewMode = preview
        engine = SpyEngine(cacheRoot: cacheURL)
        // Finished segments from an interrupted capture are promoted for manual
        // recovery before a new ring starts. Unknown files are never discarded.
        ReplayCrashRecovery.prepareCache(cacheURL, legacyLimit: minutes * 60) { [journal] level, detail in
            journal.record(level, "Восстановление буфера", detail)
        }
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        if preview || defaults.string(forKey: "libraryPath") == nil { try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true) }
        engine.onStats = { [weak self] value in Task { @MainActor in self?.stats = value } }
        engine.onTelemetry = { [weak self] value in Task { @MainActor in self?.captureHealth.receive(value) } }
        engine.onFailure = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                await self.handleCaptureFailure(value)
            }
        }
        engine.onDiagnostic = { [weak self] level, topic, detail in
            Task { @MainActor in self?.journal.record(level, topic, detail) }
        }
        engine.onLevels = { [weak self] value in Task { @MainActor in self?.audioMeter = value } }
        engine.onApplicationAudioWarning = { [weak self] value in Task { @MainActor in self?.applicationAudioIssue = value } }
        applicationAudio.onApplicationsChanged = { [weak self] in
            guard let self, self.recording, self.systemAudio, self.applicationAudio.mode == .selected else { return }
            Task {
                do { try await self.engine.refreshApplicationAudio() }
                catch is CancellationError {}
                catch { self.journal.record(.warning, "Звук приложений", describeError(error)) }
            }
        }
        if !preview { applicationAudio.install() }
        refreshDisplays()
        refreshMicrophones()
        if preview { return }
        journal.record(.info, "Запуск", "Spy 1.14.0 запущен. " + ProcessInfo.processInfo.operatingSystemVersionString)
        if let issue = metadata.loadError { journal.record(.error, "Данные библиотеки", "Автоочистка приостановлена для защиты избранного.\n" + metadata.url.path + "\n" + issue) }
        hotkeys = HotKeys(bindings: shortcuts) { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                if let action = ShortcutAction(rawValue: id) { self.journal.record(.info, "Горячая клавиша", action.title + " · " + self.shortcuts[action].label) }
                if let action = ShortcutAction(rawValue: id) {
                    if action == .manual { await self.toggleManual() }
                    else if action == .toggle { await self.toggleRecording() }
                    else if action == .preview { await self.openBufferPreview() }
                    else if action == .marker { self.addMomentMarker() }
                    else { await self.saveSpy(seconds: action.seconds) }
                }
            }
        }
        hotkeyAvailable = hotkeys?.registered == true
        if let issue = hotkeys?.registrationError { journal.record(.warning, "Горячие клавиши", issue) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordingDiagnostics.cancel()
                guard self.recording || self.startupStatus != nil else { return }
                if self.privacy.pauseOnLock {
                    self.privacy.setBlocked(true, reason: .displayAsleep)
                    self.requestPrivacyState()
                    return
                }
                await self.stop(preserveReplayIntent: true); self.message = "Повтор приостановлен на время сна Mac."
                self.journal.record(.info, "Сон Mac", "Буфер остановлен перед переходом в сон.")
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.privacy.pauseOnLock {
                    if PrivacyController.currentScreenLockHint() { self.privacy.setBlocked(true, reason: .screenLocked) }
                    self.privacy.setBlocked(false, reason: .displayAsleep)
                    self.requestPrivacyState()
                    if self.privacyPaused { return }
                }
                guard self.rememberReplay, self.lastReplayEnabled else { return }
                await self.restoreLastSession()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshMicrophones() } })
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCleanup, !self.saving, self.section != 2 else { return }
                await self.cleanupLibrary()
            }
        }
        setupProFeatures()
        setupLibraryMonitoring()
        Task { await reloadClips(); if autoCleanup { await cleanupLibrary() } }
    }

    var estimatedBytes: Int64 {
        let encoding = captureTuning.encoding
        let bitrate = (try? encoding.effectiveBitrate(defaultBitrate: effectiveQuality.bitrate)) ?? effectiveQuality.bitrate
        let expected = Int64(effectiveMinutes * 60 * Double(bitrate + (systemAudio ? 192_000 : 0) + (microphone ? 96_000 : 0)) / 8)
        return encoding.cacheLimitBytes > 0 ? min(expected, encoding.cacheLimitBytes) : expected
    }
    var microphoneAvailable: Bool { if #available(macOS 15.0, *) { return true }; return false }
    var audioSummary: String {
        if systemAudio && microphone { return "Система + микрофон" }
        if systemAudio { return "Только системный звук" }
        if microphone { return "Только микрофон" }
        return "Без звука"
    }
    var captureTargetSummary: String {
        if captureMode == .window { return "Записывается только выбранное окно." }
        let name = selectedDisplay?.name ?? "отключённый экран"
        return "Записывается экран «\(name)»." + (displays.count > 1 ? " Другие мониторы в видео не входят." : "")
    }
    var totalLibraryBytes: Int64 { clips.reduce(0) { $0 + $1.bytes } }
    var durationLabel: String {
        if minutes == 0 { return "Выключено" }
        if minutes < 1 { return "30 сек" }
        return minutes.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(minutes)) мин" : "\(Int(minutes)) мин 30 сек"
    }
    var canSave: Bool { recording && !saving && !busy && !shuttingDown && stats.frameCount > 0 && minutes > 0 }
    var canPreviewBuffer: Bool { recording && !previewBusy && !busy && !shuttingDown && stats.frameCount > 0 && minutes > 0 && bufferPreview == nil }

    var selectedDisplay: DisplayChoice? {
        guard let match = DisplaySelection.resolve(id: displayID, uuid: preferences.string(forKey: "displayUUID"), choices: displays),
              match.id == displayID else { return nil }
        return match
    }
    var missingDisplayHelp: String { "Выбранный экран отключён. Выберите экран перед продолжением повтора." }
    func rememberDisplayIdentity() {
        if let selected = displays.first(where: { $0.id == displayID }) {
            preferences.set(selected.uuid, forKey: "displayUUID")
        } else {
            preferences.removeObject(forKey: "displayUUID")
        }
    }
    func refreshDisplays(available: [DisplayChoice]? = nil) {
        let uuid = preferences.string(forKey: "displayUUID")
        displays = available ?? DisplaySelection.connected()
        let match = DisplaySelection.resolve(id: displayID, uuid: uuid, choices: displays)
        // Never change the target under a running stream. A reconnect can
        // change display IDs; stop safely, then resolve the same UUID on start.
        if recording || startupStatus != nil {
            if match?.id != displayID && captureMode == .display && captureFailure != missingDisplayHelp {
                engine.requestPrivacyBlock(true)
                Task { await handleCaptureFailure(missingDisplayHelp) }
            }
        } else if !busy, let match {
            if displayID != match.id {
                displayID = match.id
                journal.record(.info, "Выбор экрана", "Восстановлен монитор «\(match.name)» после изменения системного номера.")
            } else { rememberDisplayIdentity() }
            if captureIssue == missingDisplayHelp { captureIssue = nil }
        } else if captureMode == .display, match == nil {
            captureIssue = missingDisplayHelp
        }
        refreshDisk()
    }
    func refreshDisk() {
        if let values = try? libraryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) { freeSpace = values.volumeAvailableCapacityForImportantUsage ?? 0 }
    }
    func toggleRecording() async {
        guard !busy, !saving, !shuttingDown, !diagnosticsBusy else { return }
        if recording { await stop() } else { captureRecovery.cancel(); preferences.set(false, forKey: "gameOwnedReplay"); gameAutoCapture.userRequestedStart(); await start() }
    }
    func start(forManual: Bool = false, requestPermission: Bool = true) async {
        guard !recording, !busy, !saving, !shuttingDown, !diagnosticsBusy else { return }
        if requestPermission { captureRecovery.cancel() }
        refreshDisplays()
        if captureMode == .display && selectedDisplay == nil {
            captureIssue = missingDisplayHelp
            journal.record(.warning, "Выбор экрана", missingDisplayHelp)
            return
        }
        do { try privacy.validateConfiguration() }
        catch { showError(error.localizedDescription, topic: "Приватность", details: describeError(error)); return }
        guard !privacy.isBlocked && !manualPrivacyPause else { message = "Запись приостановлена для приватности."; return }
        engine.requestPrivacyBlock(false)
        guard minutes > 0 || forManual else { showError("Перед запуском выберите время от 30 секунд до 30 минут.", topic: "Запуск буфера"); return }
        if captureMode == .window && windowID == 0 { showError("Выберите окно для записи.", topic: "Захват окна"); return }
        if microphone && !microphoneID.isEmpty && !microphones.contains(where: { $0.id == microphoneID }) { showError("Выбранный микрофон отключён. Выберите другой микрофон.", topic: "Микрофон"); return }
        busy = true; message = nil; captureIssue = nil; captureFailure = nil
        startupStatus = "Проверяю доступ…"
        journal.record(.info, "Запуск буфера", "Длительность: \(durationLabel); качество: \(effectiveQuality.title); фактический буфер: \(effectiveMinutes.formatted()) мин; звук: \(audioSummary); захват: \(captureMode.title); окно: \(windowID); микрофон: \(microphoneID.isEmpty ? "по умолчанию" : microphoneID).")
        defer { startupStatus = nil; busy = false }
        let preflight = captureAccess.screenAllowed()
        journal.record(.info, "Диагностика запуска", "Core Graphics preflight: \(preflight); ручной запрос: \(requestPermission); приложение: \(Bundle.main.bundleURL.path).")
        if !preflight && !requestPermission {
            blockScreenCapture()
            return
        }
        if microphone {
            guard microphoneAvailable else { showError("Для записи микрофона нужна macOS 15 или новее.", topic: "Микрофон"); return }
            let status = captureAccess.microphoneStatus()
            var granted = status == .authorized
            if status == .notDetermined && requestPermission { granted = await captureAccess.requestMicrophone() }
            guard granted else {
                needsMicrophonePermission = true
                captureIssue = "Микрофон недоступен. Разрешите Spy доступ в настройках macOS или выключите «Микрофон» и включите повтор снова."
                journal.record(.warning, "Доступ к микрофону", captureIssue!)
                return
            }
            needsMicrophonePermission = false
        } else { needsMicrophonePermission = false }
        do {
            startupStatus = "Запускаю захват…"
            let config = RecordingConfig(displayID: displayID, quality: effectiveQuality, audio: systemAudio, microphone: microphone, seconds: max(30, effectiveMinutes * 60), windowID: captureMode == .window ? windowID : nil, microphoneID: microphoneID.isEmpty ? nil : microphoneID, excludedBundleIDs: privacy.excludedBundleIDs, microphoneCleanup: microphoneCleanup, applicationAudioMode: applicationAudio.mode, applicationAudioBundleIDs: applicationAudio.bundleIDs, encoding: captureTuning.encoding, masks: captureTuning.enabledMasks)
            var protectedConfig = config
            if captureRecovery.isPending { protectedConfig.expectedWindowProcessID = recordingWindowProcessID }
            if let captureStartOverride { try await captureStartOverride(protectedConfig) }
            else { try await engine.start(protectedConfig) }
            if let captureFailure { throw SpyError.message(captureFailure) }
            if pendingCaptureStop || shuttingDown || Task.isCancelled {
                pendingCaptureStop = false
                await engine.stop()
                journal.record(.info, "Запуск буфера", "Запуск отменён запросом остановки.")
                return
            }
            recordingQuality = effectiveQuality; recordingMinutes = effectiveMinutes
            recordingWindowProcessID = engine.windowOwnerProcessID()
            recording = true; needsPermission = false; captureIssue = nil
            privacyPaused = false
            if !forManual { setReplayIntent(true) }
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .suddenTerminationDisabled], reason: "Instant replay recording")
            journal.record(.info, "Буфер", "Захват экрана запущен; первый кадр записан кодировщиком.")
            captureRecovery.captureDidStart()
        } catch {
            await engine.stop()
            recording = false; stats = BufferStats(); audioMeter = AudioMeter()
            journal.record(.error, "Запуск буфера", describeError(error))
            if CaptureAccess.isScreenDenial(error) { blockScreenCapture() }
            else { captureIssue = "Не удалось включить повтор. " + error.localizedDescription }
        }
    }
    func stop(processPending: Bool = true, preserveReplayIntent: Bool = false, userInitiated: Bool = true) async {
        if userInitiated && !preserveReplayIntent { gameAutoCapture.userRequestedStop() }
        if !preserveReplayIntent { captureRecovery.cancel(); manualPrivacyPause = false }
        if !preserveReplayIntent { setReplayIntent(false) }
        guard !busy else { pendingCaptureStop = true; return }
        if manualRecording { await finishManual(stopCapture: true); return }
        busy = true
        await flushAutoMoments()
        let retain = preserveReplayIntent && captureFailure != nil
        let previousRecovery = Set(recoveryFolders.map { $0.path })
        await engine.stop(preserveForRecovery: retain)
        privacyPaused = false
        recording = false; stats = BufferStats(); audioMeter = AudioMeter(); busy = false
        journal.record(.info, "Буфер", retain ? "Запись остановлена после ошибки; готовые сегменты оставлены для восстановления." : "Запись остановлена, временный буфер очищен.")
        if retain { refreshRecoveryFolders(); sessions.retain(recoveryFolders.filter { !previousRecovery.contains($0.path) }, session: sessions.sessions.last?.id) }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        refreshDisk()
        if processPending { Task { await reconcilePendingChanges() } }
    }
    func setReplayIntent(_ enabled: Bool) {
        lastReplayEnabled = enabled
        preferences.set(enabled, forKey: "lastReplayEnabled")
        if !enabled { captureRecovery.cancel(); preferences.set(false, forKey: "gameOwnedReplay") }
    }

    func restoreLastSession() async {
        guard !shuttingDown, !captureRecovery.isPending, startBufferOnLaunch || (rememberReplay && lastReplayEnabled) else { return }
        // Automatic replay follows selected processes across app launches;
        // restoring it as manual replay would leave it running after game exit.
        if preferences.bool(forKey: "gameOwnedReplay") && !startBufferOnLaunch {
            setReplayIntent(false)
            return
        }
        preferences.set(false, forKey: "gameOwnedReplay")
        gameAutoCapture.userRequestedStart()
        if captureMode == .window { await refreshWindows(requestPermission: false) }
        journal.record(.info, "Восстановление сессии", "Включаю повтор с сохранёнными настройками.")
        await start(requestPermission: false)
    }

    /// Snapshot before stopping the stream: the original ring is still available
    /// if pinning fails. Retained record-* segments survive failed exports.
    @discardableResult func shutdown() async -> Bool {
        guard !shuttingDown else { return false }
        shuttingDown = true
        captureRecovery.cancel()
        if busy && startupStatus != nil { pendingCaptureStop = true }
        recordingDiagnostics.cancel()
        while diagnosticsBusy { try? await Task.sleep(nanoseconds: 50_000_000) }
        while busy || saving { try? await Task.sleep(nanoseconds: 50_000_000) }
        await flushAutoMoments()
        closeBufferPreview()
        selectedClip = nil
        queueViewer.dismiss()
        var replay: SpySnapshot?
        if (saveBufferOnExit || updates.pendingInstall) && lastReplayEnabled && recording && minutes > 0 && engine.testStats().frameCount > 0 {
            do {
                let snapshot = try await engine.snapshot(seconds: effectiveMinutes * 60)
                let retained = cacheURL.appendingPathComponent("record-replay-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.moveItem(at: snapshot.directory, to: retained)
                replay = SpySnapshot(directory: retained, urls: snapshot.urls.map { retained.appendingPathComponent($0.lastPathComponent) }, requestedSeconds: snapshot.requestedSeconds, sourceIntervals: snapshot.sourceIntervals, markers: snapshot.markers, captureSessionID: snapshot.captureSessionID)
                try JSONEncoder().encode(snapshot.requestedSeconds).write(to: retained.appendingPathComponent("replay-seconds.json"), options: .atomic)
            } catch {
                shuttingDown = false
                showError("Не удалось подготовить автосохранение. Spy остаётся открыт: " + error.localizedDescription, topic: "Автосохранение", details: describeError(error))
                return false
            }
        }
        if manualRecording { await finishManual(stopCapture: true) }
        healthTimer?.invalidate(); healthTimer = nil
        hud.hide(); cleanupTimer?.invalidate(); libraryMonitor?.stop(); privacy.uninstall(); performance.stop()
        await engine.stop(); recording = false; endCaptureActivity()
        if let replay {
            saving = true
            do { try await saveManualSnapshot(replay, replaySession: true) }
            catch { journal.record(.error, "Автосохранение", "Видео оставлено для восстановления при следующем запуске.\n" + describeError(error)); refreshRecoveryFolders() }
            saving = false
        }
        journal.record(.info, "Завершение", "Состояние повтора сохранено: \(lastReplayEnabled). Spy закрывается.")
        preferences.synchronize()
        return true
    }

    func saveSpy(seconds requested: Double? = nil) async {
        guard canSave else { return }
        guard libraryAvailable else { showError("Папка сохранения недоступна. Подключите диск или выберите другую папку.", topic: "Сохранение"); return }
        saving = true; message = nil
        journal.record(.info, "Сохранение", "Запрошено \(clockText(requested ?? effectiveMinutes * 60)). В буфере: \(clockText(stats.seconds)).")
        defer { saving = false; refreshDisk(); Task { await reconcilePendingChanges() } }
        let seconds = min(1800, max(0.1, requested ?? effectiveMinutes * 60))
        let levels = AudioLevels(system: Float(systemVolume), microphone: Float(microphoneVolume))
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        stamp.timeZone = SpyDates.timeZone
        let baseName = "Spy_" + stamp.string(from: Date()) + "_" + String(UUID().uuidString.prefix(4))
        let destination = libraryURL.appendingPathComponent(baseName + ".mov").spyFileURL
        // Only completed exports receive a library-visible filename.
        let partial = libraryURL.appendingPathComponent("." + baseName + ".mov")
        do {
            let snapshot = try await engine.snapshot(seconds: seconds)
            try await SpyExporter.export(snapshot, to: partial, levels: levels, separateAudio: separateAudio, editableMicrophone: true)
            try FileManager.default.moveItem(at: partial, to: destination)
            storeMarkers(MarkerTimeline.positions(in: snapshot), for: destination)
            sessions.saved(destination, session: snapshot.captureSessionID)
            await reloadClips()
            let saved = clips.first(where: { $0.url == destination })
            message = "Повтор сохранён · \(clockText(saved?.duration ?? seconds))"
            journal.record(.info, "Видео сохранено", "\(destination.lastPathComponent) · \(clockText(saved?.duration ?? seconds)) · \(fileSize(saved?.bytes ?? 0))")
            if let saved { notifySaved(saved) }
            if autoCleanup { await cleanupLibrary(protecting: [destination]) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            showError(error.localizedDescription, topic: "Сохранение видео", details: describeError(error))
        }
    }

    func setupLibraryMonitoring() {
        libraryMonitor = LibraryMonitor { [weak self] in await self?.reloadClips(ifChanged: true) }
        libraryMonitor?.watch(libraryURL)
    }

    func reloadClips(ifChanged: Bool = false) async {
        if ifChanged && activeLibraryLoads > 0 { return }
        let id = UUID()
        let folder = libraryURL.spyFileURL
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) }
        catch {
            if !FileManager.default.fileExists(atPath: folder.path) {
                loadID = id
                clips = []; selectedClip = nil; librarySignature = nil; clipFileSignatures = [:]
                refreshDisk()
            } else if !ifChanged { journal.record(.error, "Чтение библиотеки", describeError(error)) }
            return
        }
        var signature: [URL: String] = [:]
        var entries: [(URL, URLResourceValues)] = []
        for url in urls where ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let normalized = url.spyFileURL
            signature[normalized] = "\(values.fileSize ?? 0)/\(values.creationDate?.timeIntervalSince1970 ?? 0)/\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            entries.append((normalized, values))
        }
        if ifChanged && librarySignature == signature { return }
        loadID = id
        activeLibraryLoads += 1
        defer { activeLibraryLoads -= 1 }
        let previous = Dictionary(uniqueKeysWithValues: clips.map { ($0.url, $0) })
        var result: [Clip] = []
        for (url, values) in entries {
            guard loadID == id, libraryURL.spyFileURL == folder else { return }
            var clip = Clip(url: url, date: values.creationDate ?? Date(), bytes: Int64(values.fileSize ?? 0), managed: url.lastPathComponent.hasPrefix("Spy_") || metadata.contains(url))
            let extra = metadata.get(url); clip.name = extra.name; clip.favorite = extra.favorite
            if clipFileSignatures[url] == signature[url], let old = previous[url] { clip.duration = old.duration }
            else { do {
                let time = try await AVURLAsset(url: url).load(.duration)
                if time.isNumeric { clip.duration = CMTimeGetSeconds(time) }
            } catch { if FileManager.default.fileExists(atPath: url.path) { journal.record(.warning, "Чтение видео", url.lastPathComponent + "\n" + describeError(error)) } } }
            guard FileManager.default.fileExists(atPath: url.path) else { signature.removeValue(forKey: url); continue }
            result.append(clip)
        }
        guard id == loadID, libraryURL.spyFileURL == folder else { return }
        librarySignature = signature; clipFileSignatures = signature
        clips = result.sorted { $0.date > $1.date }
        if let selected = selectedClip { selectedClip = clips.first { $0.id == selected.id } }
        refreshDisk()
    }
    func trash(_ clip: Clip) async {
        if !FileManager.default.fileExists(atPath: clip.url.path) { await forgetMissingClip(clip); return }
        do {
            try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
            if selectedClip?.id == clip.id { selectedClip = nil }
            await reloadClips()
            message = "Видео перемещено в Корзину"
            journal.record(.info, "Удаление видео", clip.url.lastPathComponent + " перемещено в Корзину.")
        } catch {
            if !FileManager.default.fileExists(atPath: clip.url.path) { await forgetMissingClip(clip) }
            else { showError("Не удалось удалить видео: " + error.localizedDescription, topic: "Удаление видео", details: describeError(error)) }
        }
    }
    private func forgetMissingClip(_ clip: Clip) async {
        clips.removeAll { $0.id == clip.id }
        if selectedClip?.id == clip.id { selectedClip = nil }
        await reloadClips()
        message = "Файл уже удалён или перемещён. Библиотека обновлена."
    }
    func openFolder() { NSWorkspace.shared.open(libraryURL) }
    func reveal(_ clip: Clip) { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
    func openPermissions() {
        journal.record(.info, "Разрешения", "Открыты настройки доступа к экрану macOS.")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func openMicrophonePermissions() {
        journal.record(.info, "Разрешения", "Открыты настройки доступа к микрофону macOS.")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }

    func showError(_ text: String, topic: String, details: String? = nil) {
        error = text
        journal.record(.error, topic, details ?? text)
    }
    func beginShortcutEdit(_ action: ShortcutAction) {
        hotkeys?.suspend()
        editingShortcut = action
    }
    func assignShortcut(_ value: Shortcut, to action: ShortcutAction) throws {
        var candidate = shortcuts
        candidate[action] = value
        do {
            try candidate.validate()
            try hotkeys?.configure(candidate)
            shortcuts = candidate
            if !previewMode { candidate.persist(to: preferences) }
            hotkeyAvailable = previewMode || hotkeys?.registered == true
            journal.record(.info, "Настройка клавиш", action.title + " → " + value.label)
        } catch {
            if editingShortcut != nil { hotkeys?.suspend() }
            journal.record(.warning, "Настройка клавиш", describeError(error))
            throw error
        }
    }
    func finishShortcutEdit() {
        editingShortcut = nil
        do { try hotkeys?.resume(); hotkeyAvailable = previewMode || hotkeys?.registered == true }
        catch { hotkeyAvailable = false; journal.record(.warning, "Горячие клавиши", describeError(error)) }
    }
    func restoreDefaultShortcuts() {
        do {
            let defaults = ShortcutBindings()
            try hotkeys?.configure(defaults)
            shortcuts = defaults
            if !previewMode { defaults.persist(to: preferences) }
            hotkeyAvailable = previewMode || hotkeys?.registered == true
            message = "Горячие клавиши сброшены: \(defaults.save.label), \(defaults.toggle.label)"
            journal.record(.info, "Настройка клавиш", "Восстановлены стандартные сочетания.")
        } catch { showError(error.localizedDescription, topic: "Сброс горячих клавиш", details: describeError(error)) }
    }
    func copyJournal(entries: [LogEntry]) {
        let text = journal.text(entries: entries)
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { message = "Текст журнала скопирован" }
        else { showError("Не удалось скопировать текст журнала.", topic: "Копирование журнала") }
    }
    func saveJournal(entries: [LogEntry]) {
        let panel = NSSavePanel()
        panel.title = "Сохранить журнал Spy"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"; formatter.timeZone = SpyDates.timeZone
        panel.nameFieldStringValue = "Spy-Журнал-" + formatter.string(from: Date()) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try journal.export(to: url, entries: entries)
            message = "Журнал сохранён в " + url.lastPathComponent
        } catch { showError("Не удалось сохранить журнал: " + error.localizedDescription, topic: "Экспорт журнала", details: describeError(error)) }
    }
}

