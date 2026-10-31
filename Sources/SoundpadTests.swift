import Foundation
import AVFoundation
import AppKit

enum SoundpadTests {
    static func tone(_ frequency: Double, seconds: Double = 0.1, amplitude: Float = 0.2, rate: Double = 48_000) -> SoundpadPCM {
        var samples = [Float](repeating: 0, count: Int(seconds * rate) * 2)
        for i in 0..<samples.count / 2 { let value = amplitude * Float(sin(Double(i) * frequency * 2 * .pi / rate)); samples[i * 2] = value; samples[i * 2 + 1] = value }
        return SoundpadPCM(samples: samples)
    }
    static func render(_ mixer: RoutingMixer, frames: Int) -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: SoundpadPCM.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames); mixer.render(frames: frames, into: buffer.mutableAudioBufferList)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frames))
    }
    static func magnitude(_ values: [Float], frequency: Double, rate: Double = 48_000) -> Double {
        var re = 0.0, im = 0.0
        for (i, value) in values.enumerated() { let phase = Double(i) * frequency * 2 * .pi / rate; re += Double(value) * cos(phase); im += Double(value) * sin(phase) }
        return sqrt(re * re + im * im) * 2 / Double(max(1, values.count))
    }
    @MainActor static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mixer = RoutingMixer(); mixer.levels(system: 0.5, microphone: 0.25, pads: 0.75)
        mixer.setEnabled(true)
        mixer.append(tone(440), microphone: false); mixer.append(tone(997), microphone: true)
        mixer.play(id: UUID(), pcm: tone(1500))
        let mixed = render(mixer, frames: 4800)
        try SelfTest.require(abs(magnitude(mixed, frequency: 440) - 0.1) < 0.003 && abs(magnitude(mixed, frequency: 997) - 0.05) < 0.003 && abs(magnitude(mixed, frequency: 1500) - 0.15) < 0.003, "System, microphone and pad retain independent levels")
        mixer.levels(system: 1, microphone: 0, pads: 0)
        mixer.append(tone(997), microphone: true)
        try SelfTest.require(render(mixer, frames: 4800).allSatisfy { $0 == 0 }, "Microphone gain zero removes voice")
        mixer.append(tone(440, seconds: 1), microphone: false)
        try SelfTest.require(mixer.metrics().dropped > 0 || render(mixer, frames: 12_001).suffix(1).first == 0, "Input is bounded to 250 ms")
        mixer.play(id: UUID(), pcm: tone(800)); mixer.setEnabled(false)
        try SelfTest.require(render(mixer, frames: 5000).allSatisfy { $0 == 0 }, "Emergency stop flushes voices and source buffers")
        mixer.setEnabled(true)
        try SelfTest.require(render(mixer, frames: 5000).allSatisfy { $0 == 0 }, "Restart never replays stale sound")
        mixer.levels(system: 1, microphone: 1, pads: 1)
        for _ in 0..<8 { mixer.play(id: UUID(), pcm: tone(440, amplitude: 0.9)) }
        let limited = render(mixer, frames: 4800)
        try SelfTest.require(limited.allSatisfy { $0.isFinite && abs($0) <= 1 } && mixer.metrics().clipped > 0 && mixer.metrics().voices == 0, "Four-voice limit and saturation prevent invalid PCM")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4410)!
        source.frameLength = 4410
        for i in 0..<4410 { source.floatChannelData![0][i] = 0.1 * Float(sin(Double(i) * 2 * .pi * 441 / 44100)) }
        let converted = try RoutingPCMConverter().convert(source)
        try SelfTest.require(abs(converted.frames - 4800) < 100 && zip(stride(from: 0, to: converted.samples.count, by: 2), stride(from: 1, to: converted.samples.count, by: 2)).allSatisfy { abs(converted.samples[$0] - converted.samples[$1]) < 0.001 }, "44.1 kHz mono converts to 48 kHz stereo: frames \(converted.frames), channels \(converted.samples.prefix(8))")
        let sample = try SelfTest.audio(frame: 0, pts: .zero, rate: 48_000, channels: 2, frequency: 900)
        let fromSample = try RoutingPCMConverter().convert(sample)
        try SelfTest.require(fromSample.frames > 1500 && magnitude(stride(from: 0, to: fromSample.samples.count, by: 2).map { fromSample.samples[$0] }, frequency: 900) > 0.1, "ScreenCaptureKit sample-buffer PCM conversion")
        try SelfTest.require(!AudioRoutingPolicy.permits("com.hnc.Discord", selected: nil, privateIDs: []) && !AudioRoutingPolicy.permits("com.hnc.discordcanary.helper", selected: nil, privateIDs: []) && !AudioRoutingPolicy.permits("local.spy.mac", selected: nil, privateIDs: []) && !AudioRoutingPolicy.permits("com.example.private", selected: nil, privateIDs: ["com.example.private"]) && !AudioRoutingPolicy.permits("com.example.other", selected: [], privateIDs: []) && AudioRoutingPolicy.permits("com.example.music", selected: ["com.example.music"], privateIDs: []), "Discord, Spy and privacy exclusions; empty selection stays silent")
        let suite = "Spy.SoundpadTests." + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let replay = ApplicationAudioSelection(defaults: defaults)
        let routing = ApplicationAudioSelection(defaults: defaults, prefix: "soundpadApps")
        routing.mode = .selected; routing.setSelected(.init(bundleID: "com.example.music", name: "Music"), true)
        try SelfTest.require(replay.mode == .all && replay.bundleIDs.isEmpty && ApplicationAudioSelection(defaults: defaults, prefix: "soundpadApps").bundleIDs == ["com.example.music"], "Replay and routing settings persist independently")
        var legacy = ShortcutBindings(); legacy.save = .broadcastDefault; legacy.toggle = Shortcut.padDefaults[0]
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        raw.removeValue(forKey: "broadcast"); raw.removeValue(forKey: "pads")
        let migrated = try JSONDecoder().decode(ShortcutBindings.self, from: JSONSerialization.data(withJSONObject: raw)); try migrated.validate()
        try SelfTest.require(migrated.save == legacy.save && migrated.toggle == legacy.toggle && !migrated.broadcast.sameCombination(as: legacy.save), "New soundpad defaults never overwrite old custom shortcuts")
        let importURL = directory.appendingPathComponent("tone.wav")
        var out: AVAudioFile? = try AVAudioFile(forWriting: importURL, settings: fmt.settings)
        try out?.write(from: source)
        out = nil
        let root = directory.appendingPathComponent("managed")
        let journal = EventJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let controller = SoundpadController(defaults: defaults, root: root, journal: journal, preview: true)
        await controller.importFiles([importURL])
        try SelfTest.require(controller.clips.count == 1, "Import validates and copies sound: \(controller.issue ?? "")")
        let clip = controller.clips[0]
        let restored = SoundpadController(defaults: defaults, root: root, journal: journal, preview: true)
        try SelfTest.require(restored.clips == [clip] && !restored.running, "Catalog restored, broadcast remains off")
        restored.remove(clip)
        try SelfTest.require(restored.clips.isEmpty && FileManager.default.fileExists(atPath: importURL.path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path), "Removing pad leaves original import intact")
        print("PASS: real PCM conversion, 3-source mixing and gains, mic mute, bounded FIFO, emergency stop, voice cap and limiter, privacy/call filters, independent settings, 18-shortcut migration, copied catalog and deletion")
        let inventory = RoutingDevices.all().map { ["uid": $0.uid, "name": $0.name, "in": String($0.inputChannels), "out": String($0.outputChannels)] }
        try JSONEncoder().encode(inventory).write(to: directory.appendingPathComponent("devices.json"))
    }
}

/// Reads only the virtual loopback, never the user's physical microphone.
final class SoundpadProbeReader: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.spy.soundpad.probe")
    private let lock = NSLock()
    private var samples: [Float] = []
    private let converter = RoutingPCMConverter()
    private let session = AVCaptureSession()
    func start(uid: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in queue.async {
            do {
                let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
                guard let device = devices.first(where: { $0.uniqueID == uid }) else { throw SpyError.message("BlackHole не появился в списке входов. Может потребоваться перезапуск Mac.") }
                let input = try AVCaptureDeviceInput(device: device); let output = AVCaptureAudioDataOutput()
                self.session.beginConfiguration()
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else { throw SpyError.message("Не удалось прочитать BlackHole.") }
                self.session.addInput(input); self.session.addOutput(output); output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.commitConfiguration(); self.session.startRunning(); continuation.resume()
            } catch { continuation.resume(throwing: error) }
        } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcm = try? converter.convert(sampleBuffer) else { return }
        lock.lock(); defer { lock.unlock() }
        if samples.count < 48_000 * 20 { samples += stride(from: 0, to: pcm.samples.count, by: 2).map { pcm.samples[$0] } }
    }
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; let value = samples; samples.removeAll(keepingCapacity: true); return value }
    func stop() async { await withCheckedContinuation { c in queue.async { self.session.stopRunning(); c.resume() } } }
}

extension SoundpadTests {
    /// Run with the two quiet fixture apps (440/880 Hz). No physical mic is used.
    @MainActor static func systemRoute(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Spy.SoundpadRoute." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SoundpadController(defaults: defaults, root: directory.appendingPathComponent("settings"), journal: EventJournal(fileURL: directory.appendingPathComponent("journal.json")))
        controller.microphoneEnabled = CommandLine.arguments.contains("--with-microphone")
        controller.monitorPads = CommandLine.arguments.contains("--monitor-pads")
        controller.systemVolume = 1
        controller.applications.mode = .selected
        guard let device = controller.targets.first else { throw SpyError.message("BlackHole не загружен.") }
        let reader = SoundpadProbeReader(); try await reader.start(uid: device.uid)
        var results: [[String: Any]] = []
        for (id, chosen, unwanted) in [("local.spy.audio-fixture-a", 440.0, 880.0), ("local.spy.audio-fixture-b", 880.0, 440.0)] {
            for app in controller.applications.selectedApplications { controller.applications.setSelected(app, false) }
            controller.applications.setSelected(.init(bundleID: id, name: id), true)
            await controller.start()
            guard controller.running else { await reader.stop(); throw SpyError.message(controller.issue ?? "Передача не включилась.") }
            try await Task.sleep(nanoseconds: 400_000_000); _ = reader.take()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let pcm = Array(reader.take().suffix(48_000))
            let wanted = magnitude(pcm, frequency: chosen), other = magnitude(pcm, frequency: unwanted)
            if chosen == 440, CommandLine.arguments.contains("--local-volume") {
                controller.refreshLocalVolume()
                guard controller.localVolumeAvailable else { await controller.stop(); await reader.stop(); throw SpyError.message("Устройство не поддерживает системную громкость для этого теста.") }
                let old = controller.localVolume; let physical = RoutingDevices.defaultOutput()
                defer { try? LocalListeningVolume.set(old, device: physical); controller.refreshLocalVolume() }
                controller.setLocalVolume(old * 0.2)
                try await Task.sleep(nanoseconds: 300_000_000); _ = reader.take()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let lowPCM = Array(reader.take().suffix(48_000))
                func rms(_ values: [Float]) -> Double { sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))) }
                // Bluetooth clock resampling can slightly shift the carrier.
                // Compare its energy, not a single narrow DFT bin.
                let before = rms(pcm), after = rms(lowPCM)
                let measurement: [String: Any] = ["localVolumeBefore": old, "localVolumeReduced": LocalListeningVolume.value(device: physical) ?? -1, "discordRMSBefore": before, "discordRMSAfter": after, "framesAfter": lowPCM.count]
                results.append(measurement)
                try JSONSerialization.data(withJSONObject: measurement, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("independent-volume.json"))
                try SelfTest.require(lowPCM.count >= 24_000 && abs(after - before) < max(0.001, before * 0.05), "Physical headphone volume does not lower the Discord feed: \(before)→\(after)")
            }
            await controller.stop()
            results.append(["selected": id, "frames": pcm.count, "wanted": wanted, "excluded": other])
            try SelfTest.require(pcm.count >= 24_000 && wanted > 0.01 && other < wanted * 0.03, "Selected app crosses virtual mic without other app: \(id), wanted \(wanted), excluded \(other)")
        }
        for app in controller.applications.selectedApplications { controller.applications.setSelected(app, false) }
        await controller.start()
        try SelfTest.require(!controller.running && controller.issue != nil, "Empty application selection cannot broadcast all audio")
        try await Task.sleep(nanoseconds: 400_000_000); _ = reader.take()
        try await Task.sleep(nanoseconds: 300_000_000)
        let silent = reader.take()
        await reader.stop()
        try SelfTest.require(!silent.isEmpty && (silent.map { abs($0) }.max() ?? 1) < 0.0001, "Controller stop and rejected restart leave virtual input silent")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("system-route.json"))
        print("PASS: real per-application ScreenCaptureKit→mixer→BlackHole→microphone route, 440/880 Hz isolation, controller start/stop and empty-selection silence")
    }
    @MainActor static func loopback(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw SpyError.message("Для проверки нужен уже разрешённый доступ Spy к микрофону.") }
        guard let device = RoutingDevices.all().first(where: \.isBlackHole) else { throw SpyError.message("Установите BlackHole 2ch для проверки реального маршрута.") }
        let reader = SoundpadProbeReader(); try await reader.start(uid: device.uid)
        let mixer = RoutingMixer(); let output = try RoutingOutput(device: device, mixer: mixer)
        try await Task.sleep(nanoseconds: 400_000_000); _ = reader.take()
        mixer.levels(system: 0.5, microphone: 0.25, pads: 0.75); mixer.setEnabled(true)
        mixer.play(id: UUID(), pcm: tone(1500, seconds: 1.5))
        for _ in 0..<12 {
            mixer.append(tone(440), microphone: false); mixer.append(tone(1000), microphone: true)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let active = reader.take()
        mixer.setEnabled(false)
        try await Task.sleep(nanoseconds: 350_000_000); _ = reader.take()
        try await Task.sleep(nanoseconds: 350_000_000)
        let silent = reader.take(); output.stop(); await reader.stop()
        let content = Array(active.dropFirst(min(active.count / 4, 8000)).suffix(24_000))
        let a = magnitude(content, frequency: 440), b = magnitude(content, frequency: 1000), c = magnitude(content, frequency: 1500)
        let peak = silent.map { abs($0) }.max() ?? 0
        try JSONSerialization.data(withJSONObject: ["frames": active.count, "system440Hz": a, "mic1000Hz": b, "pad1500Hz": c, "stoppedPeak": peak], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("loopback.json"))
        try SelfTest.require(content.count >= 12_000 && a > 0.06 && b > 0.025 && c > 0.1, "All three tones cross real virtual input: \(a), \(b), \(c), frames \(active.count)")
        try SelfTest.require(!silent.isEmpty && peak < 0.0001, "Stopped loopback emits silence")
        print("PASS: real BlackHole output→microphone loopback: \(active.count) frames, 3 separate tones, immediate stop verified silent")
    }
}
