import Foundation
import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit

enum AudioRoutingPolicy {
    static func isCallApp(_ id: String) -> Bool {
        let id = id.lowercased()
        return ["com.hnc.discord", "com.hnc.discordcanary", "com.hnc.discordptb"].contains { id == $0 || id.hasPrefix($0 + ".") }
    }
    static func permits(_ id: String, selected: Set<String>?, privateIDs: Set<String>) -> Bool {
        let id = id.lowercased()
        guard !id.isEmpty, id != (Bundle.main.bundleIdentifier ?? "local.spy.mac").lowercased(), !isCallApp(id), !privateIDs.contains(id) else { return false }
        return selected?.contains(id) ?? true
    }
}

/// Dedicated audio-only stream. It never writes to or changes the replay engine.
final class SoundpadCapture: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.spy.soundpad.input", qos: .userInitiated)
    private let mixer: RoutingMixer
    private let systemConverter = RoutingPCMConverter(), micConverter = RoutingPCMConverter()
    private var stream: SCStream?
    private var microphone: AVCaptureSession?
    private var failed = false
    private var microphoneReady = false
    var hasMicrophoneAudio: Bool { queue.sync { microphoneReady } }
    var onFailure: ((String) -> Void)?
    init(mixer: RoutingMixer) { self.mixer = mixer }
    @MainActor func startSystem(selected: Set<String>?, privateIDs: Set<String>) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw SpyError.message("Для передачи звука приложений разрешите Spy запись экрана в настройках macOS.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SpyError.message("Нет доступного экрана для системного звука.") }
        let apps = content.applications.filter { AudioRoutingPolicy.permits($0.bundleIdentifier, selected: selected, privateIDs: privateIDs) }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2; config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
        guard self.stream === stream else { try? await stream.stopCapture(); throw CancellationError() }
    }
    @MainActor func updateApplications(selected: Set<String>?, privateIDs: Set<String>) async throws {
        guard let stream else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SpyError.message("Источник системного звука отключён.") }
        let apps = content.applications.filter { AudioRoutingPolicy.permits($0.bundleIdentifier, selected: selected, privateIDs: privateIDs) }
        try await stream.updateContentFilter(SCContentFilter(display: display, including: apps, exceptingWindows: []))
    }
    func startMicrophone(id: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
                    let device = id.isEmpty ? AVCaptureDevice.default(for: .audio) : discovery.devices.first { $0.uniqueID == id }
                    guard let device else { throw SpyError.message("Выбранный микрофон отключён. Выберите другой.") }
                    guard !device.uniqueID.lowercased().contains("blackhole") else { throw SpyError.message("Выберите настоящий микрофон вместо BlackHole, чтобы избежать петли звука.") }
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw SpyError.message("Не удалось подключить микрофон.") }
                    session.addInput(input); session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    session.commitConfiguration(); session.startRunning()
                    guard session.isRunning else { throw SpyError.message("Микрофон не запустился.") }
                    self.microphone = session
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @MainActor func stop() async {
        let stream = self.stream; self.stream = nil
        try? await stream?.stopCapture()
        await withCheckedContinuation { continuation in queue.async { self.microphone?.stopRunning(); self.microphone = nil; continuation.resume() } }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { report(describeError(error)) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        do { mixer.append(try systemConverter.convert(sampleBuffer), microphone: false) }
        catch { report(describeError(error)) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        do { let pcm = try micConverter.convert(sampleBuffer); microphoneReady = pcm.frames > 0; mixer.append(pcm, microphone: true) }
        catch { report(describeError(error)) }
    }
    private func report(_ text: String) {
        queue.async {
            guard !self.failed else { return }; self.failed = true
            self.mixer.setEnabled(false); self.onFailure?(text)
        }
    }
}
