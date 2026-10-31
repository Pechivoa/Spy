import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SoundpadClip: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let file: String
    let duration: Double
}

@MainActor final class SoundpadController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var importing = false
    @Published private(set) var devices: [RoutingDevice] = []
    @Published private(set) var clips: [SoundpadClip] = []
    @Published private(set) var meters = RoutingMixer.Metrics(system: 0, microphone: 0, output: 0, clipped: 0, dropped: 0, voices: 0)
    @Published var issue: String?
    @Published var status = "Передача выключена"
    @Published private(set) var localVolume = 0.0
    @Published private(set) var localVolumeAvailable = false
    @Published private(set) var localOutputName = "Наушники"
    @Published var targetUID: String { didSet { defaults.set(targetUID, forKey: "soundpad.target") } }
    @Published var systemEnabled: Bool { didSet { defaults.set(systemEnabled, forKey: "soundpad.system") } }
    @Published var microphoneEnabled: Bool { didSet { defaults.set(microphoneEnabled, forKey: "soundpad.mic") } }
    @Published var microphoneID: String { didSet { defaults.set(microphoneID, forKey: "soundpad.micID") } }
    @Published var monitorPads: Bool { didSet { defaults.set(monitorPads, forKey: "soundpad.monitor") } }
    @Published var systemVolume: Double { didSet { saveLevels() } }
    @Published var microphoneVolume: Double { didSet { saveLevels() } }
    @Published var padVolume: Double { didSet { saveLevels() } }
    let applications: ApplicationAudioSelection
    let mixer = RoutingMixer()
    let root: URL
    private let defaults: UserDefaults
    private let journal: EventJournal
    private var output: RoutingOutput?
    private var monitorDevice: RoutingDevice?
    private var monitorPlayers: [UUID: AVAudioPlayer] = [:]
    private var capture: SoundpadCapture?
    private var generation = UUID()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var cachedPCM: [UUID: SoundpadPCM] = [:]
    private var cacheOrder: [UUID] = []
    private var loading = Set<UUID>()
    private var lastProcesses: Set<String> = []
    private var refreshing = false
    private var lastPrivacyIDs = Set<String>()
    private var activeMicID: String?
    var excludedPrivateIDs: () -> Set<String> = { [] }
    var transmissionBlocked: () -> Bool = { false }
    var isPreview = false
    var targets: [RoutingDevice] { devices.filter(\.isBlackHole) }
    var target: RoutingDevice? { targets.first { $0.uid == targetUID } }
    var selectedIDs: Set<String>? { applications.mode == .selected ? applications.bundleIDs : nil }

    init(defaults: UserDefaults, root: URL, journal: EventJournal, preview: Bool = false) {
        self.defaults = defaults; self.root = root; self.journal = journal; isPreview = preview
        targetUID = defaults.string(forKey: "soundpad.target") ?? ""
        systemEnabled = defaults.object(forKey: "soundpad.system") == nil ? true : defaults.bool(forKey: "soundpad.system")
        microphoneEnabled = defaults.object(forKey: "soundpad.mic") == nil ? true : defaults.bool(forKey: "soundpad.mic")
        microphoneID = defaults.string(forKey: "soundpad.micID") ?? ""
        monitorPads = defaults.object(forKey: "soundpad.monitor") == nil ? true : defaults.bool(forKey: "soundpad.monitor")
        func gain(_ key: String, _ fallback: Double) -> Double { let v = defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key); return v.isFinite ? min(1, max(0, v)) : fallback }
        systemVolume = gain("soundpad.systemVolume", 0.65); microphoneVolume = gain("soundpad.micVolume", 1); padVolume = gain("soundpad.padVolume", 0.7)
        applications = ApplicationAudioSelection(defaults: defaults, prefix: "soundpadApps")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: root.appendingPathComponent("clips.json")), data.count < 128_000,
           let saved = try? JSONDecoder().decode([SoundpadClip].self, from: data) {
            var seen = Set<UUID>()
            clips = saved.filter { value in
                value.file.hasPrefix(value.id.uuidString + ".") && URL(fileURLWithPath: value.file).lastPathComponent == value.file &&
                value.duration.isFinite && value.duration > 0 && value.duration <= 121 && seen.insert(value.id).inserted
            }.prefix(8).map { $0 }
        }
        saveLevels()
        guard !preview else { return }
        refreshDevices(); applications.install()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.blockNow("Сон или смена сессии Mac. Передача выключена.") }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.blockNow("Экран заблокирован. Передача выключена.") }
        }
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }
    func refreshDevices() {
        devices = RoutingDevices.all()
        if targetUID.isEmpty, let first = targets.first { targetUID = first.uid }
        refreshLocalVolume()
    }
    func refreshLocalVolume() {
        let id = RoutingDevices.defaultOutput()
        guard let physical = devices.first(where: { $0.id == id }), !physical.isBlackHole else { localVolumeAvailable = false; return }
        localOutputName = physical.name
        if let value = LocalListeningVolume.value(device: id) { localVolume = min(1, max(0, value)); localVolumeAvailable = true }
        else { localVolumeAvailable = false }
    }
    func setLocalVolume(_ value: Double) {
        let id = RoutingDevices.defaultOutput()
        guard let device = RoutingDevices.all().first(where: { $0.id == id }), !device.isBlackHole else { issue = "Выберите наушники выходом macOS; BlackHole используется только для Discord."; return }
        do { try LocalListeningVolume.set(value, device: id); localVolume = min(1, max(0, value)) }
        catch { issue = error.localizedDescription }
    }
    private func saveLevels() {
        defaults.set(systemVolume, forKey: "soundpad.systemVolume"); defaults.set(microphoneVolume, forKey: "soundpad.micVolume"); defaults.set(padVolume, forKey: "soundpad.padVolume")
        mixer.levels(system: systemVolume, microphone: microphoneEnabled ? microphoneVolume : 0, pads: padVolume)
        for player in monitorPlayers.values { player.volume = Float(padVolume) }
    }
    func toggle() async { if running || busy { await stop() } else { await start() } }
    func start() async {
        guard !running, !busy, !isPreview else { return }
        busy = true; issue = nil; generation = UUID(); let token = generation
        status = "Подключение звука…"
        defer { if generation == token { busy = false } }
        do {
            refreshDevices()
            guard !transmissionBlocked(), !PrivacyController.currentScreenLockHint() else { throw SpyError.message("Передача недоступна во время паузы приватности или блокировки экрана.") }
            guard let target else { throw SpyError.message("Установите BlackHole 2ch, затем нажмите «Обновить устройства».") }
            guard RoutingDevices.defaultOutput() != target.id else { throw SpyError.message("Выберите наушники или динамики выходом macOS. BlackHole нужен только как вход в Discord.") }
            if systemEnabled, applications.mode == .selected, applications.bundleIDs.isEmpty { throw SpyError.message("Выберите приложения для передачи звука или выключите «Звук приложений».") }
            if microphoneEnabled {
                let permission = AVCaptureDevice.authorizationStatus(for: .audio)
                let allowed = permission == .authorized ? true : permission == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : false
                guard allowed else { throw SpyError.message("Разрешите Spy доступ к микрофону в настройках macOS или выключите передачу голоса.") }
                activeMicID = microphoneID.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : microphoneID
            }
            guard generation == token else { return }
            let capture = SoundpadCapture(mixer: mixer); self.capture = capture
            capture.onFailure = { [weak self] text in Task { @MainActor in
                guard let self, self.generation == token else { return }; await self.interrupt(text)
            } }
            if systemEnabled { try await capture.startSystem(selected: selectedIDs, privateIDs: excludedPrivateIDs()) }
            guard generation == token else { return }
            if microphoneEnabled {
                try await capture.startMicrophone(id: microphoneID)
                // Bluetooth input can change the output format/profile. Wait
                // for actual input before creating the virtual output graph.
                for _ in 0..<60 {
                    guard generation == token else { return }
                    if capture.hasMicrophoneAudio { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard capture.hasMicrophoneAudio else { throw SpyError.message("От микрофона не поступает звук. Выберите другое устройство.") }
            }
            guard generation == token else { return }
            refreshDevices()
            // One continuously running AVAudioEngine. Local pad monitoring uses
            // device-pinned AVAudioPlayer instances only while a pad is playing.
            output = try RoutingOutput(device: target, mixer: mixer)
            if monitorPads {
                guard let physical = devices.first(where: { $0.id == RoutingDevices.defaultOutput() }), !physical.isBlackHole, physical.outputChannels > 0 else { throw SpyError.message("Выберите наушники для прослушивания кнопок.") }
                monitorDevice = physical
            }
            saveLevels(); mixer.setEnabled(true)
            running = true; status = "Передача включена · " + target.name
            lastProcesses = processes()
            lastPrivacyIDs = excludedPrivateIDs()
            journal.record(.info, "Soundpad", "Передача включена. Звук приложений: \(systemEnabled), голос: \(microphoneEnabled), выход: \(target.name). Discord исключён.")
        } catch {
            guard generation == token else { return }
            await interrupt(error.localizedDescription)
        }
    }
    func stop() async {
        generation = UUID(); let token = generation
        mixer.setEnabled(false); stopClips()
        output?.stop(); output = nil; monitorDevice = nil
        let capture = self.capture; self.capture = nil
        let wasActive = running || busy
        running = false; busy = true; status = "Передача выключена"
        await capture?.stop()
        if generation == token { busy = false }
        if wasActive { journal.record(.info, "Soundpad", "Передача выключена; виртуальный выход заглушён.") }
    }
    func interrupt(_ message: String) async {
        // Gate the callback immediately, before awaiting capture shutdown.
        mixer.setEnabled(false); stopClips()
        await stop(); issue = message
        journal.record(.warning, "Soundpad", message)
    }
    func blockNow(_ message: String) {
        guard running || busy else { return }
        mixer.setEnabled(false); stopClips()
        Task { await interrupt(message) }
    }
    func privacyUpdated() {
        if running, lastPrivacyIDs != excludedPrivateIDs() { blockNow("Исключения приватности изменились. Включите передачу снова с новым списком.") }
    }
    private var ticks = 0
    private func processes() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { $0.lowercased() + ":" + String(app.processIdentifier) } })
    }
    private func tick() {
        meters = mixer.metrics(); ticks += 1
        if ticks % 5 == 0 { refreshLocalVolume() }
        guard running else { if ticks % 25 == 0 { refreshDevices() }; return }
        if transmissionBlocked() { mixer.setEnabled(false); Task { await interrupt("Пауза приватности. Передача выключена.") }; return }
        guard ticks % 10 == 0 else { return }
        privacyUpdated()
        if let activeMicID, microphoneEnabled {
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            if !discovery.devices.contains(where: { $0.uniqueID == activeMicID }) {
                blockNow("Микрофон отключён. Выберите устройство и включите передачу снова."); return
            }
        }
        refreshDevices()
        guard let output, output.running, devices.contains(output.device),
              monitorDevice == nil || devices.contains(where: { $0.uid == monitorDevice?.uid && $0.outputChannels > 0 }) else {
            mixer.setEnabled(false); Task { await interrupt("Аудиоустройство изменилось или отключено. Выберите устройства и включите передачу снова.") }; return
        }
        if let target, RoutingDevices.defaultOutput() == target.id {
            mixer.setEnabled(false); Task { await interrupt("BlackHole выбран выходом macOS. Верните вывод в наушники и включите передачу снова.") }; return
        }
        let current = processes()
        if systemEnabled, current != lastProcesses, !refreshing {
            refreshing = true; let token = generation
            Task {
                defer { refreshing = false }
                do { try await capture?.updateApplications(selected: selectedIDs, privateIDs: excludedPrivateIDs()); if generation == token { lastProcesses = current } }
                catch { if generation == token { await interrupt(error.localizedDescription) } }
            }
        }
    }
    func stopClips() { mixer.stopPads(); for player in monitorPlayers.values { player.stop() }; monitorPlayers.removeAll() }
    func play(slot: Int) async {
        guard running, !busy, clips.indices.contains(slot) else { if !running { issue = "Сначала включите передачу звука." }; return }
        let clip = clips[slot]; let token = generation
        guard loading.insert(clip.id).inserted else { return }
        defer { loading.remove(clip.id) }
        do {
            let path = root.appendingPathComponent(clip.file)
            guard FileManager.default.fileExists(atPath: path.path) else { throw SpyError.message("Файл «\(clip.title)» удалён. Уберите кнопку и добавьте звук снова.") }
            let pcm: SoundpadPCM
            if let cached = cachedPCM[clip.id] { pcm = cached }
            else {
                pcm = try await Task.detached(priority: .userInitiated) { try RoutingPCMConverter.loadFile(path) }.value
                while cachedPCM.values.reduce(0, { $0 + $1.samples.count * 4 }) + pcm.samples.count * 4 > 96 * 1024 * 1024, let old = cacheOrder.first {
                    cachedPCM.removeValue(forKey: old); cacheOrder.removeFirst()
                }
                cachedPCM[clip.id] = pcm; cacheOrder.append(clip.id)
            }
            guard running, generation == token, clips.contains(where: { $0.id == clip.id }) else { return }
            issue = nil; mixer.play(id: clip.id, pcm: pcm)
            if monitorPads, let monitorDevice {
                monitorPlayers = monitorPlayers.filter { $0.value.isPlaying }
                monitorPlayers.removeValue(forKey: clip.id)?.stop()
                if monitorPlayers.count >= 4, let first = monitorPlayers.keys.first { monitorPlayers.removeValue(forKey: first)?.stop() }
                let player = try AVAudioPlayer(contentsOf: path)
                player.currentDevice = monitorDevice.uid; player.volume = Float(padVolume)
                guard player.prepareToPlay(), player.play() else { throw SpyError.message("Звук передаётся в микрофон, но прослушивание в наушниках недоступно.") }
                monitorPlayers[clip.id] = player
            }
        } catch { issue = error.localizedDescription; journal.record(.error, "Soundpad", describeError(error)) }
    }
    func chooseFiles() {
        guard clips.count < 8, !importing else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]; panel.message = "До 8 звуков, каждый до двух минут. Файлы будут скопированы в Spy."
        guard panel.runModal() == .OK else { return }
        let urls = Array(panel.urls.prefix(8 - clips.count))
        Task { await importFiles(urls) }
    }
    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }; importing = true; defer { importing = false }
        for url in urls.prefix(max(0, 8 - clips.count)) {
            do {
                let value = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard value.isRegularFile == true, (value.fileSize ?? 0) <= 64 * 1024 * 1024 else { throw SpyError.message("Добавьте аудиофайл размером до 64 МБ.") }
                let duration = try await Task.detached(priority: .userInitiated) { try RoutingPCMConverter.loadFile(url).duration }.value
                let id = UUID(); let ext = url.pathExtension.lowercased().filter { $0.isASCII && $0.isLetter || $0.isNumber }
                guard !ext.isEmpty, ext.count < 12 else { throw SpyError.message("Неизвестное расширение звука.") }
                let file = id.uuidString + "." + ext
                try FileManager.default.copyItem(at: url, to: root.appendingPathComponent(file))
                let old = clips
                clips.append(SoundpadClip(id: id, title: String(url.deletingPathExtension().lastPathComponent.prefix(80)), file: file, duration: duration))
                do { try saveCatalog() } catch { clips = old; try? FileManager.default.removeItem(at: root.appendingPathComponent(file)); throw error }
                issue = nil
            } catch { issue = error.localizedDescription; journal.record(.error, "Импорт звука", describeError(error)) }
        }
    }
    func remove(_ clip: SoundpadClip) {
        stopClips(); let old = clips; clips.removeAll { $0.id == clip.id }
        do { try saveCatalog(); cachedPCM.removeValue(forKey: clip.id); cacheOrder.removeAll { $0 == clip.id }
            // Only the managed copy is removed. The original import is untouched.
            try? FileManager.default.removeItem(at: root.appendingPathComponent(clip.file))
        } catch { clips = old; issue = error.localizedDescription }
    }
    private func saveCatalog() throws { try JSONEncoder().encode(clips).write(to: root.appendingPathComponent("clips.json"), options: .atomic) }
    func openDriverSetup() { NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!) }
}

@MainActor extension AppModel {
    func showSoundpad() {
        soundpad.refreshDevices(); soundpad.applications.refresh()
        soundpadWindow.present(title: "Spy — Soundpad", frameName: "Spy.Soundpad", preferredSize: NSSize(width: 820, height: 760), minimumSize: NSSize(width: 700, height: 540), onClose: {}) {
            SoundpadView(model: self, soundpad: self.soundpad).preferredColorScheme(.dark)
        }
    }
}
