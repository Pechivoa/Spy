import Foundation
import AVFoundation
import AppKit

enum SelfTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpyError.message("TEST FAILED: " + message) }
    }
    static func pixel(frame: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        guard result == kCVReturnSuccess, let value else { throw SpyError.message("Pixel allocation failed") }
        CVPixelBufferLockBaseAddress(value, [])
        let address = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(value)
        for y in 0..<180 {
            for x in 0..<320 {
                let offset = y * stride + x * 4
                address[offset] = 45
                address[offset + 1] = UInt8(80 + x / 4)
                address[offset + 2] = UInt8(min(250, frame + 50))
                address[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
    static func audio(frame: Int, pts: CMTime, rate: Int = 48_000, channels: Int = 2, frequency: Double = 440, amplitude: Float = 0.15) throws -> CMSampleBuffer {
        let count = rate / 30
        var floats: [Float] = Array(repeating: 0, count: count * channels)
        for i in 0..<count {
            let sample = Float(sin(Double(frame * count + i) / Double(rate) * .pi * 2 * frequency)) * amplitude
            for channel in 0..<channels { floats[i * channels + channel] = sample }
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: floats.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: floats.count * 4, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw SpyError.message("Audio allocation failed") }
        status = floats.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard status == noErr else { throw SpyError.message("Audio copy failed") }
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw SpyError.message("Audio format failed") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = channels * 4
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SpyError.message("Audio sample failed") }
        return sample
    }

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache"))
        var failures: [String] = []
        engine.onFailure = { failures.append($0) }
        try engine.beginTest(seconds: 3, audio: true)
        for i in 0..<180 {
            let pts = CMTime(value: 3000 + Int64(i), timescale: 30)
            engine.testFrame(try pixel(frame: i), at: pts)
            engine.testAudio(try audio(frame: i, pts: pts))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let stats = engine.testStats()
        try require(failures.isEmpty, failures.joined(separator: "; "))
        try require(stats.seconds <= 3.01 && stats.seconds >= 2.9, "Ring must retain 3 seconds")
        try require(stats.bytes > 0, "Buffer reports actual bytes")
        let snapshot = try await engine.snapshot(seconds: 2.25)
        let export = directory.appendingPathComponent("trimmed-with-audio.mov")
        try await SpyExporter.export(snapshot, to: export)
        let asset = AVURLAsset(url: export)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(abs(duration - 2.25) < 0.08, "Exact trimming: got \(duration)")
        try require(video.count == 1 && audio.count == 1, "Both video and AAC audio survive concatenation")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try require(reader.startReading(), "Video can be decoded")
        var count = 0
        var firstRed = 0
        var lastRed = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let red = Int(CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)[2])
            if count == 0 { firstRed = red }
            lastRed = red
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            count += 1
        }
        try require(reader.status == .completed, "Entire exported clip decodes")
        try require(count >= 63 && count <= 72, "Expected 30 fps across segment joins: \(count) frames")
        // H.264 is lossy; BGRA/YUV conversion can change absolute channel values.
        // The first decoded frame must still identify the trimmed tail, and the
        // last frame must identify the final input, with a substantial rise.
        try require(abs(firstRed - 163) < 24 && abs(lastRed - 229) < 24 && lastRed - firstRed >= 50, "Export contains latest frames in correct order: first=\(firstRed), last=\(lastRed), frames=\(count)")
        let audioReader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        audioReader.add(audioOutput)
        try require(audioReader.startReading(), "AAC can be decoded")
        var audioSamples = 0
        while let sample = audioOutput.copyNextSampleBuffer() { audioSamples += CMSampleBufferGetNumSamples(sample) }
        try require(audioReader.status == .completed && audioSamples > 90_000, "Audio is present throughout replay")
        // A pinned snapshot remains usable after the live ring is cleared.
        let second = try await engine.snapshot(seconds: 0.5)
        await engine.stop()
        try require(engine.testStats().bytes == 0, "Stopping clears temporary buffer")
        let short = directory.appendingPathComponent("after-stop.mov")
        try await SpyExporter.export(second, to: short)
        let shortDuration = CMTimeGetSeconds(try await AVURLAsset(url: short).load(.duration))
        try require(abs(shortDuration - 0.5) < 0.08, "Snapshot survives stop")
        try require(Quality.balanced.dimensions(width: 3024, height: 1964).1 == 1080, "Retina screen dimensions preserve aspect")
        try require(Quality.native.dimensions(width: 7680, height: 4320).0 == 3840, "Encoding dimensions are bounded")
        print("PASS: ring pruning, actual file sizes, 2.25-second trim, \(count) decoded frames, AAC \(audioSamples) samples, saving after stop, Retina scaling")
        // Test the real encoder with no system audio, including a silent track.
        try engine.beginTest(seconds: 1800, audio: false)
        for i in 0..<36 {
            engine.testFrame(try pixel(frame: i), at: CMTime(value: 6000 + Int64(i), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let noAudioSnapshot = try await engine.snapshot(seconds: 1800)
        let silent = directory.appendingPathComponent("no-audio.mov")
        try await SpyExporter.export(noAudioSnapshot, to: silent)
        let silentAsset = AVURLAsset(url: silent)
        let silentAudio = try await silentAsset.loadTracks(withMediaType: .audio)
        let silentDuration = CMTimeGetSeconds(try await silentAsset.load(.duration))
        try require(silentAudio.isEmpty && silentDuration > 1, "No-audio mode and underfilled buffer")
        await engine.stop()
        print("PASS: silent capture and underfilled 30-minute buffer")
        // Enabling system audio while no app is producing sound must still
        // yield a playable video, not an unfinished audio encoder.
        try engine.beginTest(seconds: 30, audio: true)
        do {
            _ = try await engine.snapshot(seconds: 30)
            throw SpyError.message("TEST FAILED: empty buffer must refuse export")
        } catch let error as SpyError {
            try require(error.localizedDescription.contains("пуст"), "Empty buffer error is actionable")
        }
        for i in 0..<36 {
            engine.testFrame(try pixel(frame: i), at: CMTime(value: 9000 + Int64(i), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let idleAudioSnapshot = try await engine.snapshot(seconds: 30)
        let idleAudio = directory.appendingPathComponent("system-audio-silent.mov")
        try await SpyExporter.export(idleAudioSnapshot, to: idleAudio)
        let idleDuration = CMTimeGetSeconds(try await AVURLAsset(url: idleAudio).load(.duration))
        try require(idleDuration > 1, "Silent system audio does not block video")
        await engine.stop()
        let model = await AppModel(preview: true)
        let library = await model.libraryURL
        let copied = library.appendingPathComponent("test-library.mov")
        try FileManager.default.copyItem(at: export, to: copied)
        await model.reloadClips()
        let clips = await model.clips
        try require(clips.count == 1 && abs(clips[0].duration - 2.25) < 0.08 && clips[0].bytes > 0, "Library loads duration and actual file weight")
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: copied, resultingItemURL: &trashedURL)
        await model.reloadClips()
        let countAfterTrash = await model.clips.count
        try require(countAfterTrash == 0 && trashedURL != nil, "Recoverable deletion removes clip from library")
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
        print("PASS: empty buffer, silent system audio, library metadata, recoverable deletion")
    }
}

@main struct SpyBootstrap {
    @MainActor static func main() async {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--spy-install-update" {
            exit(SpyUpdateInstaller.helper(planURL: URL(fileURLWithPath: CommandLine.arguments[2])))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview-editing-test"), CommandLine.arguments.count > index + 1 {
            do { try await PreviewEditingTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--preview-window-test"), CommandLine.arguments.count > index + 1 {
            do { try await PreviewWindowTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--workspace-test"), CommandLine.arguments.count > index + 1 {
            do { try await ReliabilityWorkspaceTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--updater-test"), CommandLine.arguments.count > index + 1 {
            do { try await AppUpdatesTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-recovery-test"), CommandLine.arguments.count > index + 1 {
            do { try await CaptureRecoveryTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-tuning-test"), CommandLine.arguments.count > index + 1 {
            do {
                let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                try await CaptureTuningTests.run(directory: directory)
                try await CaptureTuningIntegrationTests.run(directory: directory.appendingPathComponent("integration"))
                exit(0)
            }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--editor-test"), CommandLine.arguments.count > index + 1 {
            do { try await FullscreenEditorTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--application-audio-test"), CommandLine.arguments.count > index + 1 {
            do { try await ApplicationAudioTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture-reliability-test"), CommandLine.arguments.count > index + 1 {
            do { try await CaptureReliabilityTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--owned-frames-test"), CommandLine.arguments.count > index + 1 {
            do { try await OwnedScreenFramesTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--microphone-library-test"), CommandLine.arguments.count > index + 1 {
            do { try await MicrophoneLibraryTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--automation-integration-test"), CommandLine.arguments.count > index + 1 {
            do { try await AutomationIntegrationTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--game-auto-test"), CommandLine.arguments.count > index + 1 {
            do { try await GameAutoCaptureTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--diagnostics-test"), CommandLine.arguments.count > index + 1 {
            do { try await RecordingDiagnosticsTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--auto-moment-test"), CommandLine.arguments.count > index + 1 {
            do { try await AutoMomentClipTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--runtime-test"), CommandLine.arguments.count > index + 1 {
            do { try await RuntimeIntegrationTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--moment-marker-test"), CommandLine.arguments.count > index + 1 {
            do { try await MomentMarkerTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--privacy-test"), CommandLine.arguments.count > index + 1 {
            do { try await PrivacyTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-cleanup-test"), CommandLine.arguments.count > index + 1 {
            do { try await AudioCleanupTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--performance-test"), CommandLine.arguments.count > index + 1 {
            do { try await PerformanceTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--crash-recovery-test"), CommandLine.arguments.count > index + 1 {
            do { try await CrashRecoveryTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--crash-recovery-fixture"), CommandLine.arguments.count > index + 1 {
            do { try await CrashRecoveryTests.writeCrashFixture(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--thumbnail-test"), CommandLine.arguments.count > index + 1 {
            do { try await TimelineThumbnailTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--buffer-preview-test"), CommandLine.arguments.count > index + 1 {
            do { try await BufferPreviewTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--session-test"), CommandLine.arguments.count > index + 1 {
            do { try await SessionTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--startup-test"), CommandLine.arguments.count > index + 1 {
            do { try await StartupTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            do {
                let section = CommandLine.arguments.count > index + 2 ? Int(CommandLine.arguments[index + 2]) ?? 0 : 0
                let source = CommandLine.arguments.count > index + 3 ? URL(fileURLWithPath: CommandLine.arguments[index + 3]) : nil
                try await PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), section: section, sourceURL: source)
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--settings-test"), CommandLine.arguments.count > index + 1 {
            do { try SettingsTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-test"), CommandLine.arguments.count > index + 1 {
            do { try await AudioTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--feature-test"), CommandLine.arguments.count > index + 1 {
            do { try await FeatureTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--pro-test"), CommandLine.arguments.count > index + 1 {
            do { try await ProTests.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--self-test") {
            let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory() + "SpySelfTest"
            do {
                try await SelfTest.run(directory: URL(fileURLWithPath: path, isDirectory: true))
                exit(0)
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                exit(1)
            }
        }
        SpyApp.main()
    }
}
