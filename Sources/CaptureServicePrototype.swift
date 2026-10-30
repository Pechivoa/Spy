import Foundation
import AppKit
import AVFoundation
import Darwin
import Security

enum CaptureServicePhase: String, Codable { case idle, starting, recording, paused, stopping, failed }
struct CaptureServiceRequest: Codable {
    enum Action: String, Codable { case start, status, snapshot, limit, privacyBlock, pause, resume, stop, shutdown }
    var version = 1
    var id = UUID()
    let action: Action
    var config: RecordingConfig? = nil
    var seconds: Double? = nil
    var blocked: Bool? = nil
}
struct CaptureServiceReply: Codable {
    let id: UUID
    let phase: CaptureServicePhase
    let stats: BufferStats
    var snapshot: SpySnapshot? = nil
    var error: String? = nil
}
struct CaptureServiceReport: Codable {
    let workerPID: Int32
    let phase: CaptureServicePhase
    let frames: Int
    var framesAtDisconnect: Int? = nil
    var framesAfterDisconnect: Int? = nil
    var finished = false
    var error: String? = nil
}

/// An internal, opt-in IPC prototype. Normal Spy still uses its validated
/// in-process engine until privacy observers and reconnection are migrated.
/// The only channel is a pair of inherited anonymous pipes, never a TCP port.
@MainActor final class CaptureServicePrototype {
    private let engine: SpyEngine
    private let root: URL
    private var phase: CaptureServicePhase = .idle
    private var issue: String?
    private var exclusions: Set<String> = []
    private var lifetime: Task<Void, Never>?
    init(root: URL) throws {
        var parent: SecCode?, current: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: getppid()] as CFDictionary, [], &parent) == errSecSuccess,
              SecCodeCopySelf([], &current) == errSecSuccess, let current, let parent,
              SecCodeCopyStaticCode(current, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(parent, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw SpyError.message("Внутренняя служба принимает запуск только от подписанного процесса Spy.")
        }
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        engine = SpyEngine(cacheRoot: root)
        engine.onFailure = { [weak self] text in Task { @MainActor in self?.issue = text; self?.phase = .failed } }
    }
    func run() async {
        signal(SIGPIPE, SIG_IGN)
        _ = NSApplication.shared
        let commands = AsyncStream<CaptureServiceRequest> { continuation in
            lifetime = Task { try? await Task.sleep(nanoseconds: 90_000_000_000); if !Task.isCancelled { continuation.finish() } }
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                while true {
                    let next = FileHandle.standardInput.availableData
                    if next.isEmpty { break }
                    buffer.append(next)
                    guard buffer.count <= 65_536 else { break }
                    while let index = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                        guard let request = try? JSONDecoder().decode(CaptureServiceRequest.self, from: line), request.version == 1 else { continuation.finish(); return }
                        continuation.yield(request)
                    }
                }
                continuation.finish()
            }
        }
        let reporter = Task { [weak self] in
            while !Task.isCancelled {
                self?.report()
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
        var explicitShutdown = false
        for await request in commands {
            var snapshot: SpySnapshot?
            var errorText: String?
            do {
                switch request.action {
                case .start:
                    guard phase == .idle, let config = request.config else { throw SpyError.message("Некорректный запуск службы.") }
                    guard CGPreflightScreenCaptureAccess() else { throw SpyError.message("У фонового процесса нет подтверждённого доступа к экрану. Разрешения не изменялись.") }
                    phase = .starting
                    exclusions = config.excludedBundleIDs
                    try await engine.start(config); try await engine.waitForFirstFrame()
                    phase = .recording
                case .status: break
                case .snapshot:
                    guard let seconds = request.seconds, seconds.isFinite, seconds > 0, seconds <= 1800 else { throw SpyError.message("Некорректная длительность снимка.") }
                    snapshot = try await engine.snapshot(seconds: seconds)
                case .limit:
                    guard let seconds = request.seconds, seconds.isFinite, (0...1800).contains(seconds) else { throw SpyError.message("Некорректный лимит буфера.") }
                    engine.updateLimit(seconds)
                case .privacyBlock: engine.requestPrivacyBlock(request.blocked ?? true)
                case .pause: try await engine.pauseForPrivacy(); phase = .paused
                case .resume: try await engine.resumeAfterPrivacy(excluding: exclusions); phase = .recording
                case .stop, .shutdown:
                    phase = .stopping; await engine.stop(preserveForRecovery: true); phase = .idle
                }
            } catch { errorText = error.localizedDescription; issue = errorText; phase = .failed }
            let reply = CaptureServiceReply(id: request.id, phase: phase, stats: engine.testStats(), snapshot: snapshot, error: errorText)
            if let data = try? JSONEncoder().encode(reply) { try? FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
            if request.action == .shutdown { explicitShutdown = true; break }
        }
        let before = engine.testStats().frameCount
        // Bounded orphan grace is deliberate for the prototype. It proves that
        // UI lifetime and encoding lifetime are independent, then retains media.
        if !explicitShutdown, phase == .recording { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        let after = engine.testStats().frameCount
        reporter.cancel()
        lifetime?.cancel(); lifetime = nil
        await engine.stop(preserveForRecovery: true)
        let result = CaptureServiceReport(workerPID: ProcessInfo.processInfo.processIdentifier, phase: phase,
            frames: after, framesAtDisconnect: before, framesAfterDisconnect: after, finished: true, error: issue)
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: root.appendingPathComponent("service-report.json"), options: .atomic) }
    }
    private func report() {
        let value = CaptureServiceReport(workerPID: ProcessInfo.processInfo.processIdentifier, phase: phase,
            frames: engine.testStats().frameCount, error: issue)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: root.appendingPathComponent("service-report.json"), options: .atomic) }
    }
}

@MainActor enum CaptureServiceProbe {
    struct Ready: Codable { let workerPID: Int32; let frames: Int }
    static func driver(root: URL) async throws {
        _ = NSApplication.shared
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--capture-service", root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let config = RecordingConfig(displayID: CGMainDisplayID(), quality: .compact, audio: false, microphone: false,
            seconds: 5, excludedBundleIDs: ["local.spy.mac"])
        let request = CaptureServiceRequest(action: .start, config: config)
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request) + Data([10]))
        let data = await Task.detached(priority: .utility) { () -> Data in
            var buffer = Data()
            while true {
                let next = output.fileHandleForReading.availableData
                if next.isEmpty { break }
                buffer.append(next); if let end = buffer.firstIndex(of: 10) { return Data(buffer[..<end]) }
                if buffer.count > 65_536 { break }
            }
            return buffer
        }.value
        let reply = try JSONDecoder().decode(CaptureServiceReply.self, from: data)
        if let error = reply.error { try? input.fileHandleForWriting.close(); throw SpyError.message(error) }
        guard reply.phase == .recording, reply.stats.frameCount > 0 else { throw SpyError.message("Служба не подтвердила первый кадр.") }
        try JSONEncoder().encode(Ready(workerPID: process.processIdentifier, frames: reply.stats.frameCount))
            .write(to: root.appendingPathComponent("driver-ready.json"), options: .atomic)
        for _ in 0..<60 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        try? input.fileHandleForWriting.close()
    }
    static func run(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let driver = Process()
        driver.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        driver.arguments = ["--capture-service-driver", root.path]
        driver.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); driver.standardError = errors
        try driver.run()
        defer { if driver.isRunning { Darwin.kill(driver.processIdentifier, SIGKILL) } }
        let readyURL = root.appendingPathComponent("driver-ready.json")
        let deadline = Date().addingTimeInterval(22)
        while driver.isRunning, !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let data = try? Data(contentsOf: readyURL) else {
            if driver.isRunning { Darwin.kill(driver.processIdentifier, SIGKILL) }
            driver.waitUntilExit()
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Неизвестная ошибка службы"
            throw SpyError.message("Прототип фоновой записи не запущен: " + text)
        }
        let ready = try JSONDecoder().decode(Ready.self, from: data)
        try SelfTest.require(ready.workerPID != driver.processIdentifier && ready.workerPID != ProcessInfo.processInfo.processIdentifier,
            "Capture is owned by an independent worker process")
        Darwin.kill(driver.processIdentifier, SIGKILL); driver.waitUntilExit()
        let reportURL = root.appendingPathComponent("service-report.json")
        var report: CaptureServiceReport?
        let limit = Date().addingTimeInterval(18)
        while Date() < limit {
            report = (try? Data(contentsOf: reportURL)).flatMap { try? JSONDecoder().decode(CaptureServiceReport.self, from: $0) }
            if report?.finished == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let report, report.finished else { throw SpyError.message("Служба не завершила ограниченный прототип после разрыва связи.") }
        try SelfTest.require((report.framesAfterDisconnect ?? 0) > (report.framesAtDisconnect ?? Int.max) + 15,
            "Real encoded frames continue after abrupt UI-process death")
        let recoveries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("record-replay-") }
        try SelfTest.require(!recoveries.isEmpty && recoveries.contains { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "mov" }
        }, "Worker retains finalized media after the controller disappears")
        var decodedFrames = 0
        for directory in recoveries {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "mov" {
                let asset = AVURLAsset(url: file)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output); try SelfTest.require(reader.startReading(), "Service movie starts decoding")
                while let sample = output.copyNextSampleBuffer() { if CMSampleBufferGetImageBuffer(sample) != nil { decodedFrames += 1 } }
                try SelfTest.require(reader.status == .completed, "Service movie fully decodes after controller death")
            }
        }
        try SelfTest.require(decodedFrames >= 30, "At least one second of real service output decodes")
        print("PASS: independent ScreenCaptureKit worker, existing permission, encoded frames after controller SIGKILL, bounded orphan shutdown and \(decodedFrames) decoded frames")
    }
}
