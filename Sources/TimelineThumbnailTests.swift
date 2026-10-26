import Foundation
import AVFoundation

@MainActor enum TimelineThumbnailTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("thumbnail-cache")
        let movie = directory.appendingPathComponent("thumbnail-source.mov")
        try? FileManager.default.removeItem(at: movie)
        let engine = SpyEngine(cacheRoot: cache)
        try engine.beginTest(seconds: 5)
        for frame in 0..<90 {
            engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: 9000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let snapshot = try await engine.snapshot(seconds: 3)
        try await SpyExporter.export(snapshot, to: movie)
        await engine.stop()
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        let frames = try await TimelineThumbnailGenerator.generate(url: movie, duration: duration)
        try SelfTest.require(frames.count == 8 && frames.allSatisfy { $0.image != nil }, "Eight real video thumbnails decode")
        let times = frames.map(\.seconds)
        try SelfTest.require(times.first! > 0 && times.last! < duration && zip(times, times.dropFirst()).allSatisfy { $0.0 < $0.1 }, "Sample times cover the movie in strict chronological order without the empty endpoint")
        try SelfTest.require(frames.allSatisfy { frame in
            guard let image = frame.image else { return false }
            return image.width > 0 && image.height > 0 && image.width <= 200 && image.height <= 112
        }, "Thumbnail dimensions stay bounded independent of source resolution")
        func averageRed(_ image: CGImage) -> Int {
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return Int(pixel[0])
        }
        try SelfTest.require(averageRed(frames.last!.image!) - averageRed(frames.first!.image!) > 30, "Thumbnails show changing movie content rather than repeating the first frame")
        print("PASS: eight real bounded thumbnails, chronological sampled frames, changing video content")

        let corrupt = directory.appendingPathComponent("invalid-video.mov")
        try Data("invalid movie".utf8).write(to: corrupt)
        let missing = try await TimelineThumbnailGenerator.generate(url: corrupt, duration: 2)
        try SelfTest.require(missing.count == 8 && missing.allSatisfy { $0.image == nil }, "Invalid video produces recoverable placeholders")
        let invalid = try await TimelineThumbnailGenerator.generate(url: movie, duration: .nan)
        try SelfTest.require(invalid.isEmpty && TimelineThumbnailGenerator.sampleTimes(duration: 0).isEmpty, "Invalid durations never request decoder frames")
        try SelfTest.require(TimelineThumbnailGenerator.sampleTimes(duration: 1800, count: 10_000).count == 16, "Decoder request count remains bounded")
        let cancellation = Task { try await TimelineThumbnailGenerator.generate(url: movie, duration: duration) }
        cancellation.cancel()
        var cancelled = false
        do { _ = try await cancellation.value } catch is CancellationError { cancelled = true }
        try SelfTest.require(cancelled, "Cancelled thumbnail work exits without publishing stale frames")
        print("PASS: invalid media placeholders, invalid-duration guard, bounded requests and cancellation")
    }
}
