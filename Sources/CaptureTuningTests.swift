import Foundation
import AVFoundation
import CoreVideo
import AppKit

@MainActor enum CaptureTuningTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try testSettings()
        try testMasks()
        try testBudget(directory: directory)
        for codec in CaptureVideoCodec.allCases {
            if codec == .hevc && !CaptureEncodingOptions.hardwareHEVCAvailable(width: 320, height: 180) {
                print("SKIP: hardware HEVC unavailable; unsupported selection remains an explicit capture error")
                continue
            }
            try await testEncoder(codec, directory: directory)
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try condition() else { throw CaptureTuningError.invalid("TEST FAILED: " + description) }
    }

    private static func testSettings() throws {
        let suite = "Spy.CaptureTuningTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = CaptureTuningSettings(defaults: defaults)
        try require(original.codec == .h264 && original.bitrateMbps == 0 && original.cacheLimitGB == 0 && original.enabledMasks.isEmpty, "Defaults preserve the previous H264/quality bitrate/time-only ring")
        original.codec = .hevc; original.bitrateMbps = 4.5; original.cacheLimitGB = 2.25
        original.masksEnabled = true; original.addMask()
        let reloaded = CaptureTuningSettings(defaults: defaults)
        try require(reloaded.codec == .hevc && reloaded.bitrateMbps == 4.5 && reloaded.cacheLimitGB == 2.25 && reloaded.enabledMasks == original.masks, "Codec, custom bitrate, byte budget and regions persist together")
        try require(reloaded.encoding.cacheLimitBytes == 2_250_000_000, "GB budget converts to actual decimal bytes")
        try require(try reloaded.encoding.effectiveBitrate(defaultBitrate: 14_000_000) == 4_500_000, "Custom bitrate overrides the quality preset")
        let auto = CaptureEncodingOptions()
        try require(try auto.effectiveBitrate(defaultBitrate: 14_000_000) == 14_000_000, "Automatic bitrate stays unchanged")
        defaults.set(Data("broken settings".utf8), forKey: "CaptureTuning.v1")
        let damaged = CaptureTuningSettings(defaults: defaults)
        var blocked = false
        do { try damaged.encoding.validate() } catch { blocked = true }
        try require(blocked && damaged.configurationIssue != nil, "Corrupt privacy settings block capture rather than silently recording unmasked video")
        damaged.reset()
        try damaged.encoding.validate()
        try require(CaptureTuningSettings(defaults: defaults).enabledMasks.isEmpty && damaged.configurationIssue == nil, "Explicit reset recovers a damaged configuration")
        damaged.bitrateMbps = .nan
        try require(damaged.validationIssue != nil && damaged.persistenceIssue != nil, "Nonfinite settings cannot be encoded or used by capture")
        damaged.reset()
        print("PASS: tuning defaults, persisted codec/bitrate/budget/masks, finite-value validation and fail-closed corrupt configuration recovery")
    }

    private static func testMasks() throws {
        let pixel = try fixture(width: 37, height: 19, frame: 0)
        let before = try values(pixel)
        let masks = [RecordingMask(x: 0.25, y: 0.2, width: 0.3, height: 0.3),
                     RecordingMask(x: 0.8, y: 0.8, width: 0.2, height: 0.2)]
        let rectangles = try masks.map { try $0.pixelRect(frameWidth: 37, frameHeight: 19) }
        try require(rectangles[0] == CGRect(x: 9, y: 3, width: 12, height: 7), "Fractional privacy edges round outwards from a top-left origin")
        try RecordingMaskProcessor.apply(masks, to: pixel)
        let after = try values(pixel)
        for y in 0..<19 {
            for x in 0..<37 {
                let offset = (y * 37 + x) * 4
                let covered = rectangles.contains { $0.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) }
                if covered {
                    try require(Array(after[offset..<(offset + 4)]) == [0, 0, 0, 255], "Covered padded-row pixels are opaque black")
                } else {
                    try require(Array(after[offset..<(offset + 4)]) == Array(before[offset..<(offset + 4)]), "Pixels outside selected regions are unchanged")
                }
            }
        }
        let untouched = try fixture(width: 37, height: 19, frame: 1)
        let previous = try values(untouched)
        var invalidRejected = false
        do { try RecordingMaskProcessor.apply([masks[0], RecordingMask(x: .nan, y: 0, width: 0.5, height: 0.5)], to: untouched) }
        catch { invalidRejected = true }
        try require(invalidRejected && (try values(untouched)) == previous, "Every mask validates before any writes; invalid geometry never permits an unmasked fallback")
        let planar = try fixture(width: 32, height: 16, frame: 0, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        var formatRejected = false
        do { try RecordingMaskProcessor.apply(masks, to: planar) } catch { formatRejected = true }
        try require(formatRejected, "Unsupported input format must fail closed")
        let large = try fixture(width: 1920, height: 1080, frame: 0)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<60 { try RecordingMaskProcessor.apply([RecordingMask(x: 0, y: 0, width: 1, height: 1)], to: large) }
        let average = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 60
        print(String(format: "PASS: normalized/overlapping/edge privacy regions, opaque BGRA writes, unmasked pixels preserved, invalid inputs rejected; 1080p full-frame mask %.3f ms/frame", average))
    }

    private static func testBudget(directory: URL) throws {
        let folder = directory.appendingPathComponent("byte-budget", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (0..<3).map { folder.appendingPathComponent("segment-\($0).mov") }
        for (i, file) in files.enumerated() { try Data(repeating: UInt8(i + 1), count: (i + 1) * 100).write(to: file) }
        let reserved = folder.appendingPathComponent("writing.mov")
        try Data(repeating: 9, count: 100).write(to: reserved)
        let pinned = folder.appendingPathComponent("manual-pinned.mov")
        try FileManager.default.linkItem(at: files[0], to: pinned)
        let removals = CacheByteBudget.removalURLs(candidates: files, reservedURLs: [reserved, reserved], limitBytes: 450)
        try require(removals == Array(files.prefix(2)), "Ring byte budget counts live bytes including pending writers, evicts oldest and deduplicates paths")
        for file in removals { try FileManager.default.removeItem(at: file) }
        try require(CacheByteBudget.byteSize(pinned) == 100 && (try Data(contentsOf: pinned)).first == 1, "Removing ring links preserves pinned manual/preview video")
        try require(CacheByteBudget.removalURLs(candidates: [files[2]], reservedURLs: [reserved], limitBytes: 1).isEmpty, "A single segment remains usable while the soft budget waits for segment rollover")
        try require(CacheByteBudget.removalURLs(candidates: files, reservedURLs: [reserved], limitBytes: 0).isEmpty, "Zero byte limit preserves existing duration-only behavior")
        try require(CacheByteBudget.byteSize(folder.appendingPathComponent("missing.mov")) == 0, "Missing evicted files do not corrupt accounting")
        print("PASS: actual-byte ring eviction, writer reservation, duplicate-path accounting, zero-limit compatibility and preserved pinned hardlinks")
    }

    private static func testEncoder(_ codec: CaptureVideoCodec, directory: URL) async throws {
        let url = directory.appendingPathComponent("masked-\(codec.rawValue).mov")
        let options = CaptureEncodingOptions(codec: codec, bitrateMbps: 2)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let outputSettings = try options.videoSettings(width: 320, height: 180, fps: 30, defaultBitrate: 600_000)
        try require(writer.canApply(outputSettings: outputSettings, forMediaType: .video), "\(codec.rawValue) output settings are accepted")
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        try require(writer.startWriting(), "\(codec.rawValue) writer starts")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try require(input.isReadyForMoreMediaData, "\(codec.rawValue) hardware encoder accepts frames")
            let pixel = try fixture(width: 320, height: 180, frame: frame)
            try RecordingMaskProcessor.apply([RecordingMask(x: 0.2, y: 0.2, width: 0.3, height: 0.4)], to: pixel)
            try require(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "\(codec.rawValue) frame append")
        }
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "\(codec.rawValue) file completes: \(writer.error?.localizedDescription ?? "")")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw CaptureTuningError.invalid("TEST FAILED: encoded track") }
        let descriptions = try await track.load(.formatDescriptions)
        try require(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } == codec.mediaCodec, "\(codec.rawValue) is the actual file codec, with no silent fallback")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try require(reader.startReading(), "\(codec.rawValue) decode starts")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let protectedOffset = 60 * stride + 100 * 4, unmaskedOffset = 10 * stride + 10 * 4
            let black = max(base[protectedOffset], base[protectedOffset + 1], base[protectedOffset + 2]) <= 16
            let visible = max(base[unmaskedOffset], base[unmaskedOffset + 1], base[unmaskedOffset + 2]) > 32
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            try require(black && visible, "\(codec.rawValue) decoded video contains the privacy region and retains visible unmasked content")
            count += 1
        }
        try require(reader.status == .completed && count == 30, "All \(codec.rawValue) frames decode")
        print("PASS: real \(codec.rawValue.uppercased()) encode, codec subtype verified, 30 decoded frames with permanently black privacy region and visible surrounding pixels")
    }

    private static func fixture(width: Int, height: Int, frame: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &pixel)
        guard result == kCVReturnSuccess, let pixel else { throw CaptureTuningError.invalid("TEST FAILED: fixture allocation") }
        if format != kCVPixelFormatType_32BGRA { return pixel }
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                base[offset] = UInt8(50 + (frame + x) % 50)
                base[offset + 1] = UInt8(90 + (frame + y) % 50)
                base[offset + 2] = 180
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }

    private static func values(_ pixel: CVPixelBuffer) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { throw CaptureTuningError.invalid("TEST FAILED: pixel lock") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { throw CaptureTuningError.invalid("TEST FAILED: pixel data") }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRow(pixel)
        return (0..<height).flatMap { row in Array(UnsafeBufferPointer(start: base.advanced(by: row * stride), count: width * 4)) }
    }
}
