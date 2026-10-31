import Foundation
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Explicit developer audit. Discord's local microphone test must already be
/// enabled by the user/UI. This never joins a call or changes Discord settings.
final class SoundpadDiscordProbe: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.spy.discord-audit")
    private let converter = RoutingPCMConverter()
    private let lock = NSLock()
    private var samples: [Float] = []
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = try? converter.convert(sampleBuffer) else { return }
        lock.lock(); defer { lock.unlock() }
        if samples.count < 48_000 * 20 { samples += stride(from: 0, to: pcm.samples.count, by: 2).map { pcm.samples[$0] } }
    }
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; let value = samples; samples.removeAll(keepingCapacity: true); return value }
    @MainActor static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard CGPreflightScreenCaptureAccess() else { throw SpyError.message("Для проверки нужно разрешение Spy на системный звук.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let apps = content.applications.filter { $0.bundleIdentifier.lowercased() == "com.hnc.discord" }
        guard let display = content.displays.first, !apps.isEmpty,
              let device = RoutingDevices.all().first(where: \.isBlackHole) else { throw SpyError.message("Для аудита нужны запущенный Discord и BlackHole.") }
        let receiver = SoundpadDiscordProbe()
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true; config.sampleRate = 48_000; config.channelCount = 2
        let stream = SCStream(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.queue)
        try await stream.startCapture()
        let mixer = RoutingMixer(); let output = try RoutingOutput(device: device, mixer: mixer)
        try await Task.sleep(nanoseconds: 500_000_000); _ = receiver.take()
        mixer.levels(system: 0, microphone: 0, pads: 0.3); mixer.setEnabled(true)
        mixer.play(id: UUID(), pcm: SoundpadTests.tone(1000, seconds: 2, amplitude: 0.2))
        try await Task.sleep(nanoseconds: 2_800_000_000)
        let active = receiver.take()
        mixer.setEnabled(false); output.stop()
        try await Task.sleep(nanoseconds: 600_000_000); _ = receiver.take()
        try await Task.sleep(nanoseconds: 500_000_000)
        let silence = receiver.take()
        try? await stream.stopCapture()
        // Search a short interior window so Discord's test latency/silence
        // around playback cannot dilute a valid returned tone.
        var peakTone = 0.0
        if active.count >= 4800 {
            for offset in stride(from: 0, through: active.count - 4800, by: 2400) {
                peakTone = max(peakTone, SoundpadTests.magnitude(Array(active[offset..<(offset + 4800)]), frequency: 1000))
            }
        }
        let after = SoundpadTests.magnitude(silence, frequency: 1000)
        try JSONSerialization.data(withJSONObject: ["discordFrames": active.count, "returned1000Hz": peakTone, "afterStop1000Hz": after, "scope": "Discord local microphone test only"], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("discord-audit.json"))
        try SelfTest.require(peakTone > 0.005, "Discord local test returned the virtual microphone tone: \(peakTone), \(active.count) frames")
        try SelfTest.require(after < 0.001, "Stopped transmission no longer returns a tone through Discord")
        print("PASS: Spy→BlackHole→Discord local microphone test→headphone playback captured only from Discord; stop verified")
    }
}
