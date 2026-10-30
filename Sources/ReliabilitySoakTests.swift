import Foundation
import AVFoundation
import Darwin

/// A bounded disk footprint and real-time encoder exercise. The duration may
/// be extended to eight hours; generated media never reads the user's screen.
@MainActor enum ReliabilitySoakTests {
    struct Report: Codable {
        let elapsed: Double
        let cycles: Int
        let decodedFrames: Int
        let peakResidentBytes: Int64
        let passed: Bool
    }
    static func run(directory: URL, seconds: Double) async throws {
        guard seconds.isFinite, (10...28_800).contains(seconds) else { throw SpyError.message("Длительность прогона: от 10 секунд до 8 часов.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = ProcessInfo.processInfo.systemUptime
        var cycles = 0, decoded = 0
        repeat {
            let root = directory.appendingPathComponent("cycle-" + String(cycles), isDirectory: true)
            let engine = SpyEngine(cacheRoot: root)
            let codec: CaptureVideoCodec = cycles.isMultiple(of: 2) || !CaptureEncodingOptions.hardwareHEVCAvailable(width: 320, height: 180) ? .h264 : .hevc
            try engine.beginTest(seconds: 3, audio: true, microphone: true, encoding: CaptureEncodingOptions(codec: codec),
                masks: [RecordingMask(x: 0.2, y: 0.2, width: 0.3, height: 0.4)])
            var manualStarted = false
            do {
                for frame in 0..<300 {
                    let pts = CMTime(value: Int64(90_000 + frame), timescale: 30)
                    if frame == 30 { try await engine.beginManual(); manualStarted = true }
                    if frame == 90 {
                        engine.requestPrivacyBlock(true)
                        let blocked = await engine.overviewThumbnail()
                        try SelfTest.require(blocked == nil, "Privacy blocks overview during an active long capture")
                    }
                    if frame == 96 { engine.requestPrivacyBlock(false) }
                    engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                    engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                    engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997), microphone: true)
                    if frame == 180, manualStarted {
                        let manual = try await engine.finishManual(); manualStarted = false
                        let movie = root.appendingPathComponent("manual-check.mov")
                        try await SpyExporter.export(manual, to: movie, separateAudio: true, editableMicrophone: true)
                        decoded += try await verify(movie)
                    }
                    if frame == 240 {
                        let snapshot = try await engine.snapshot(seconds: 2)
                        let movie = root.appendingPathComponent("ring-check.mov")
                        try await SpyExporter.export(snapshot, to: movie, separateAudio: true, editableMicrophone: true)
                        decoded += try await verify(movie)
                    }
                    try await Task.sleep(nanoseconds: 33_333_333)
                }
                await engine.stop(preserveForRecovery: true)
                let recovered = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("record-replay-") }
                try SelfTest.require(!recovered.isEmpty, "Finalized ring remains recoverable after stop")
                for folder in recovered {
                    let snapshot = try await MediaSharing.recoverySnapshot(directory: folder)
                    let movie = root.appendingPathComponent("recovery-check.mov")
                    try await SpyExporter.export(snapshot, to: movie)
                    decoded += try await verify(movie)
                    try FileManager.default.removeItem(at: movie)
                }
                cycles += 1
                try FileManager.default.removeItem(at: root)
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                let report = Report(elapsed: ProcessInfo.processInfo.systemUptime - started, cycles: cycles,
                    decodedFrames: decoded, peakResidentBytes: Int64(usage.ru_maxrss), passed: true)
                try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("soak-report.json"), options: .atomic)
                print("PASS: soak cycle \(cycles), \(codec.rawValue), manual/ring/recovery decode, privacy interruption; \(Int(report.elapsed)) seconds")
            } catch { await engine.stop(preserveForRecovery: true); throw error }
        } while ProcessInfo.processInfo.systemUptime - started < seconds
    }
    private static func verify(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("TEST FAILED: no video") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try SelfTest.require(reader.startReading(), "Soak output decodes")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let hidden = 60 * stride + 100 * 4, visible = 10 * stride + 10 * 4
            let maskBlack = max(base[hidden], base[hidden + 1], base[hidden + 2]) < 20
            let pictureVisible = max(base[visible], base[visible + 1], base[visible + 2]) > 35
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            try SelfTest.require(maskBlack && pictureVisible, "Soak frames retain the mask and visible surrounding picture")
            count += 1
        }
        try SelfTest.require(reader.status == .completed && count > 15, "Every output is fully readable")
        return count
    }
}
