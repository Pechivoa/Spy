import Foundation
import AVFoundation

/// Runs the actual ring/export stack with both codecs and permanent privacy
/// regions. Generated frames/audio only; no ScreenCaptureKit or real devices.
@MainActor enum CaptureTuningIntegrationTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for codec in CaptureVideoCodec.allCases {
            if codec == .hevc && !CaptureEncodingOptions.hardwareHEVCAvailable(width: 320, height: 180) { continue }
            try await run(codec, directory: directory.appendingPathComponent(codec.rawValue, isDirectory: true))
        }
    }

    private static func run(_ codec: CaptureVideoCodec, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("cache")
        let engine = SpyEngine(cacheRoot: cache)
        var failures: [String] = []
        engine.onFailure = { failures.append($0) }
        let mask = RecordingMask(x: 0.2, y: 0.2, width: 0.3, height: 0.4)
        try engine.beginTest(seconds: 3, audio: true, microphone: true,
            encoding: CaptureEncodingOptions(codec: codec, bitrateMbps: 2), masks: [mask])
        do {
            try await engine.beginManual()
            let source = try SelfTest.pixel(frame: 10)
            let before = try samplePixel(source, x: 100, y: 60)
            engine.testFrame(source, at: CMTime(value: 90_000, timescale: 30))
            let after = try samplePixel(source, x: 100, y: 60)
            try SelfTest.require(after == before, "Mask application never mutates the caller/provider pixel buffer")
            for frame in 1..<120 {
                let pts = CMTime(value: 90_000 + Int64(frame), timescale: 30)
                engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, rate: 44_100, channels: 1, frequency: 997), microphone: true)
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            try SelfTest.require(failures.isEmpty, "\(codec.rawValue) ring capture has no mask/encoder failures: " + failures.joined(separator: "; "))
            let snapshot = try await engine.snapshot(seconds: 2)
            let playback = try await BufferPlayback.prepare(snapshot, levels: AudioLevels())
            let expectedPackets = try await packets(playback.asset, expectedCodec: codec)
            let movie = directory.appendingPathComponent("editable-microphone.mov")
            try await SpyExporter.export(snapshot, to: movie, levels: AudioLevels(system: 0.7, microphone: 0.3),
                separateAudio: true, editableMicrophone: true, removeSnapshot: false)
            let exportedPackets = try await packets(AVURLAsset(url: movie), expectedCodec: codec)
            try SelfTest.require(!expectedPackets.isEmpty && exportedPackets == expectedPackets,
                "\(codec.rawValue) ring export preserves compressed video packets while mixing separate source gains")
            let named = try await trackNames(movie)
            try SelfTest.require(Set(named) == Set([AudioSource.system.rawValue, AudioSource.microphone.rawValue]), "\(codec.rawValue) MOV retains separately tagged system/microphone AAC")
            try await verifyPixels(movie)

            let muted = directory.appendingPathComponent("without-microphone.mov")
            let editable = try await EditableVideoAudio.load(url: movie)
            try await editable.export(to: muted, start: 0.25, end: 1.75, microphoneEnabled: false)
            let mutedNames = try await trackNames(muted)
            try SelfTest.require(mutedNames == [AudioSource.system.rawValue], "\(codec.rawValue) microphone removal retains only system audio")
            try await verifyPixels(muted)

            let mp4 = directory.appendingPathComponent("sharing.mp4")
            try await MediaSharing.exportMP4(source: movie, to: mp4, microphoneEnabled: false)
            let mp4Packets = try await packets(AVURLAsset(url: mp4), expectedCodec: codec)
            try SelfTest.require(mp4Packets == exportedPackets, "\(codec.rawValue) MP4 export keeps the original compressed frames")
            let mp4Audio = try await AVURLAsset(url: mp4).loadTracks(withMediaType: .audio)
            try SelfTest.require(mp4Audio.count == 1, "\(codec.rawValue) MP4 has one selected mixed audio track")
            try await verifyPixels(mp4)

            let manual = try await engine.finishManual()
            let manualPlayback = try await BufferPlayback.prepare(manual, levels: AudioLevels())
            try SelfTest.require(manualPlayback.duration >= 3.9, "\(codec.rawValue) manual recording remains pinned while the short ring rotates")
            await engine.stop(preserveForRecovery: true)
            let recoveryFolders = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("record-replay-failure-") }
            try SelfTest.require(recoveryFolders.count == 1, "\(codec.rawValue) recovery retains the completed ring")
            let recovery = try await MediaSharing.recoverySnapshot(directory: recoveryFolders[0])
            let recovered = directory.appendingPathComponent("recovered.mov")
            try await SpyExporter.export(recovery, to: recovered)
            try await verifyPixels(recovered)
            _ = try await packets(AVURLAsset(url: recovered), expectedCodec: codec)
            try FileManager.default.removeItem(at: snapshot.directory)
            try FileManager.default.removeItem(at: manual.directory)
            print("PASS: \(codec.rawValue.uppercased()) actual masked ring, immutable provider pixels, separate AAC gains, packet-exact MOV/MP4, microphone removal, manual pins and crash recovery")
        } catch {
            await engine.stop()
            throw error
        }
    }

    private static func samplePixel(_ pixel: CVPixelBuffer, x: Int, y: Int) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { throw SpyError.message("TEST FAILED: pixel read lock") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { throw SpyError.message("TEST FAILED: no pixels") }
        let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
        return Array(UnsafeBufferPointer(start: base.advanced(by: offset), count: 4))
    }
    private static func verifyPixels(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("TEST FAILED: video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Exported video decodes")
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0, let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            let hidden = try samplePixel(pixel, x: 100, y: 60), visible = try samplePixel(pixel, x: 10, y: 10)
            try SelfTest.require(hidden.prefix(3).max()! <= 18 && visible.prefix(3).max()! > 35, "Permanent private region survives every export while surrounding content stays visible")
            frames += 1
        }
        try SelfTest.require(reader.status == .completed && frames > 10, "All exported frames are readable")
    }
    private static func packets(_ asset: AVAsset, expectedCodec: CaptureVideoCodec) async throws -> [Data] {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("TEST FAILED: no video") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Compressed video reader starts")
        var result: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  CMFormatDescriptionGetMediaSubType(format) == expectedCodec.mediaCodec,
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw SpyError.message("TEST FAILED: unexpected codec or missing packet") }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            try SelfTest.require(status == noErr, "Compressed packet is readable")
            result.append(data)
        }
        try SelfTest.require(reader.status == .completed, "Compressed video reader finishes")
        return result
    }
    private static func trackNames(_ url: URL) async throws -> [String] {
        var names: [String] = []
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) {
            for entry in try await track.load(.metadata) where entry.identifier == .quickTimeMetadataTitle {
                if let name = try await entry.load(.stringValue) { names.append(name) }
            }
        }
        return names
    }
}
