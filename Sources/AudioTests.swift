import AVFoundation
import CryptoKit

enum AudioTests {
    static func packetHashes(_ urls: [URL]) async throws -> Set<String> {
        var result: Set<String> = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            try SelfTest.require(reader.startReading(), "Read compressed video packets")
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var data = Data(count: CMBlockBufferGetDataLength(block))
                let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                try SelfTest.require(status == noErr, "Copy compressed video data")
                result.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
        }
        return result
    }
    static func samples(_ asset: AVURLAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        try SelfTest.require(reader.canAdd(output), "Audio track belongs to the asset being decoded")
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Decode saved sound")
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            try SelfTest.require(status == noErr, "Read audio samples")
            data.withUnsafeBytes { buffer in
                let floats = buffer.bindMemory(to: Float.self)
                for index in stride(from: 0, to: floats.count, by: 2) { result.append(floats[index]) }
            }
        }
        try SelfTest.require(reader.status == .completed, "Entire sound track decodes")
        return result
    }
    static func magnitude(_ samples: [Float], frequency: Double) -> Double {
        let start = min(9600, samples.count / 8), end = max(start, samples.count - 9600)
        var real = 0.0, imaginary = 0.0
        for index in start..<end {
            let angle = Double(index) / 48_000 * .pi * 2 * frequency
            real += Double(samples[index]) * cos(angle)
            imaginary += Double(samples[index]) * sin(angle)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(max(1, end - start))
    }
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (system, microphone) in [(false, false), (true, false), (false, true), (true, true)] {
            let name = "system-\(system)-mic-\(microphone)"
            let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache-" + name))
            var failures: [String] = []
            engine.onFailure = { failures.append($0) }
            try engine.beginTest(seconds: 30, audio: system, microphone: microphone)
            for frame in 0..<120 {
                let pts = CMTime(value: 12_000 + Int64(frame), timescale: 30)
                engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                // Feed both sources even when disabled to prove ignored inputs
                // cannot accidentally appear in the final soundtrack.
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, rate: 44_100, channels: 1, frequency: 997), microphone: true)
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            try SelfTest.require(failures.isEmpty, "Audio writer: " + failures.joined(separator: "; "))
            let snapshot = try await engine.snapshot(seconds: 2.37)
            let originals = try await packetHashes(snapshot.urls)
            let url = directory.appendingPathComponent(name + ".mov")
            try await SpyExporter.export(snapshot, to: url)
            await engine.stop()
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            try SelfTest.require(abs(duration - 2.37) < 0.04, "Trim stays exact after audio mixing: \(duration)")
            try SelfTest.require(tracks.count == (system || microphone ? 1 : 0), "Final clip has one mixed audio track, or none when both sources disabled")
            let copied = try await packetHashes([url])
            try SelfTest.require(!copied.isEmpty && copied.isSubset(of: originals), "H.264 packets are copied byte-for-byte, not re-encoded")
            if system && microphone {
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                try SelfTest.require(reader.startReading(), "Mixed clip video decodes")
                var frames = 0, firstRed = 0, lastRed = 0
                while let sample = output.copyNextSampleBuffer() {
                    guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let red = Int(CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)[2])
                    if frames == 0 { firstRed = red }; lastRed = red; frames += 1
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                }
                try SelfTest.require(reader.status == .completed && frames >= 70 && frames <= 74 && abs(firstRed - 99) < 25 && abs(lastRed - 169) < 25, "Mixed clip preserves frames, order and exact trim")
            }
            if let audio = tracks.first {
                let decoded = try samples(asset, track: audio)
                try SelfTest.require(decoded.count > 105_000, "Audio covers the full trimmed replay")
                let systemLevel = magnitude(decoded, frequency: 440)
                let micLevel = magnitude(decoded, frequency: 997)
                try SelfTest.require(system ? systemLevel > 0.06 : systemLevel < 0.015, "System toggle is respected: \(systemLevel)")
                try SelfTest.require(microphone ? micLevel > 0.06 : micLevel < 0.015, "Microphone toggle is respected: \(micLevel)")
                print("PASS: \(name), duration=\(duration), 440Hz=\(systemLevel), 997Hz=\(micLevel), copied H.264")
            } else { print("PASS: both sources off, no audio track, copied H.264") }
        }
        // A selected microphone that is temporarily silent doesn't prevent
        // saving the other source or the video.
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache-silent-mic"))
        try engine.beginTest(seconds: 30, audio: true, microphone: true)
        for frame in 0..<36 {
            let pts = CMTime(value: 18_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let snapshot = try await engine.snapshot(seconds: 30)
        let url = directory.appendingPathComponent("silent-microphone.mov")
        try await SpyExporter.export(snapshot, to: url)
        await engine.stop()
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
        try SelfTest.require(duration > 1, "Silent microphone doesn't block video")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(tracks.count == 1, "Silent microphone does not create a second selectable soundtrack")
        let decoded = try samples(asset, track: tracks[0])
        try SelfTest.require(magnitude(decoded, frequency: 440) > 0.06, "System stays audible when microphone is silent")
        print("PASS: silent microphone with system sound")
    }
}
