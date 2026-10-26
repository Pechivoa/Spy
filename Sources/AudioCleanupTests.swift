import Foundation
import AVFoundation

enum AudioCleanupTests {
    static func pcm(_ values: [Float], rate: Int, channels: Int, pts: CMTime, sampleDuration: CMTime? = nil) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: values.count * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw SpyError.message("Test PCM allocation failed") }
        status = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard status == noErr else { throw SpyError.message("Test PCM copy failed") }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw SpyError.message("Test PCM description failed") }
        var timing = CMSampleTimingInfo(duration: sampleDuration ?? CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = channels * 4
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: values.count / channels, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw SpyError.message("Test PCM sample failed") }
        return sample
    }
    static func floats(_ sample: CMSampleBuffer) throws -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw SpyError.message("Missing PCM block") }
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        try SelfTest.require(status == noErr, "Read cleaned PCM")
        return values
    }
    static func magnitude(_ values: [Float], rate: Int, channels: Int, frequency: Double) -> Double {
        let first = min(rate / 3, values.count / channels / 4)
        let end = values.count / channels
        var real = 0.0, imaginary = 0.0
        for frame in first..<end {
            let angle = Double(frame) / Double(rate) * .pi * 2 * frequency
            real += Double(values[frame * channels]) * cos(angle)
            imaginary += Double(values[frame * channels]) * sin(angle)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(max(1, end - first))
    }
    static func rms(_ values: [Float]) -> Double {
        sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count)))
    }
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (rate, channels) in [(44_100, 1), (48_000, 2)] {
            var input = [Float]()
            input.reserveCapacity(rate * 2 * channels)
            for frame in 0..<(rate * 2) {
                let time = Double(frame) / Double(rate)
                let tone = Float(0.15 * sin(2 * .pi * 50 * time) + 0.15 * sin(2 * .pi * 440 * time))
                input.append(contentsOf: [Float](repeating: tone, count: channels))
            }
            let sample = try pcm(input, rate: rate, channels: channels, pts: CMTime(value: 9000, timescale: 30))
            let cleanup = MicrophoneCleanup()
            let bypass = try cleanup.process(sample)
            try SelfTest.require(Unmanaged.passUnretained(bypass).toOpaque() == Unmanaged.passUnretained(sample).toOpaque(), "Disabled cleanup returns the exact original audio sample")
            cleanup.enabled = true
            let cleaned = try cleanup.process(sample)
            let output = try floats(cleaned)
            let hum = magnitude(output, rate: rate, channels: channels, frequency: 50)
            let voice = magnitude(output, rate: rate, channels: channels, frequency: 440)
            try SelfTest.require(hum < 0.02 && voice > 0.12 && voice < 0.17, "Low hum is reduced while voiced-band audio remains audible")
            let description = CMSampleBufferGetFormatDescription(cleaned)!
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            try SelfTest.require(format.sampleRate == Double(rate) && format.channelCount == channels, "Cleanup preserves microphone sample rate and channel count")
            try SelfTest.require(CMSampleBufferGetPresentationTimeStamp(cleaned) == CMSampleBufferGetPresentationTimeStamp(sample) && abs((CMSampleBufferGetDuration(cleaned) - CMSampleBufferGetDuration(sample)).seconds) < 0.000001, "Cleanup preserves timestamps and audio duration")
            try SelfTest.require(output.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Cleaned audio is finite and bounded")

            let streaming = MicrophoneCleanup(); streaming.enabled = true
            var chunked: [Float] = []
            let total = input.count / channels
            for start in stride(from: 0, to: total, by: 1024) {
                let end = min(total, start + 1024)
                let piece = Array(input[(start * channels)..<(end * channels)])
                let pts = CMSampleBufferGetPresentationTimeStamp(sample) + CMTime(value: Int64(start), timescale: Int32(rate))
                chunked.append(contentsOf: try floats(streaming.process(pcm(piece, rate: rate, channels: channels, pts: pts))))
            }
            let maximumDifference = zip(output, chunked).map { abs($0.0 - $0.1) }.max() ?? 1
            try SelfTest.require(output.count == chunked.count && maximumDifference < 0.000001, "Audio chunks preserve continuous filter and gate state without boundary clicks")
            print("PASS: \(rate) Hz / \(channels) channels, exact bypass, hum attenuation, voice preservation, timestamps and chunk continuity")
        }
        let cleanup = MicrophoneCleanup(); cleanup.enabled = true
        var noise = [Float]()
        var random: UInt64 = 12345
        for _ in 0..<96_000 {
            random = random &* 6364136223846793005 &+ 1
            noise.append(Float(Double((random >> 32) & 0xffff) / 65535 * 2 - 1) * 0.0004)
        }
        let gated = try floats(cleanup.process(pcm(noise, rate: 48_000, channels: 1, pts: .zero)))
        try SelfTest.require(rms(gated) < rms(noise) * 0.08, "Quiet ambient noise is reduced by the smooth gate")
        cleanup.enabled = false
        let sample = try pcm(noise, rate: 48_000, channels: 1, pts: .zero)
        let bypass = try floats(cleanup.process(sample))
        try SelfTest.require(bypass == noise, "Disabling cleanup preserves every PCM value")
        cleanup.enabled = true
        let preciseTiming = CMTime(value: 1000, timescale: 48_000_001)
        let precise = try pcm(Array(noise.prefix(1024)), rate: 48_000, channels: 1, pts: CMTime(value: 1234567, timescale: 60000), sampleDuration: preciseTiming)
        let preciseOutput = try cleanup.process(precise)
        var originalTiming = CMSampleTimingInfo(), cleanedTiming = CMSampleTimingInfo()
        let inputStatus = CMSampleBufferGetSampleTimingInfo(precise, at: 0, timingInfoOut: &originalTiming)
        let outputStatus = CMSampleBufferGetSampleTimingInfo(preciseOutput, at: 0, timingInfoOut: &cleanedTiming)
        try SelfTest.require(inputStatus == noErr && outputStatus == noErr && originalTiming.duration == cleanedTiming.duration && originalTiming.presentationTimeStamp == cleanedTiming.presentationTimeStamp && originalTiming.decodeTimeStamp == cleanedTiming.decodeTimeStamp, "Cleanup retains exact input sample timing without integer-rate rounding")
        print("PASS: quiet-noise attenuation and exact PCM bypass after toggling cleanup")
        try await encodedMicrophone(directory: directory)
    }

    private static func encodedMicrophone(directory: URL) async throws {
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cleanup-encoder-cache"))
        var failures: [String] = []
        engine.onFailure = { failures.append($0) }
        try engine.beginTest(seconds: 2, audio: true, microphone: true, microphoneCleanup: true)
        for frame in 0..<120 {
            let pts = CMTime(value: 12_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            // The system intentionally contains 50 Hz: it must remain untouched.
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 50))
            var microphone = [Float]()
            microphone.reserveCapacity(1470)
            for offset in 0..<1470 {
                let time = Double(frame * 1470 + offset) / 44_100
                microphone.append(Float(0.15 * sin(2 * .pi * 50 * time) + 0.15 * sin(2 * .pi * 440 * time)))
            }
            engine.testAudio(try pcm(microphone, rate: 44_100, channels: 1, pts: pts), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        try SelfTest.require(failures.isEmpty, "Microphone cleanup works inside the actual encoder: " + failures.joined(separator: "; "))
        let snapshot = try await engine.snapshot(seconds: 2)
        let destination = directory.appendingPathComponent("cleaned-recording.mov")
        try await SpyExporter.export(snapshot, to: destination, separateAudio: true)
        await engine.stop()
        let asset = AVURLAsset(url: destination)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(audio.count == 2, "Encoder retains independently selected system and microphone tracks")
        let system = try AudioTests.samples(asset, track: audio[0])
        let microphone = try AudioTests.samples(asset, track: audio[1])
        try SelfTest.require(AudioTests.magnitude(system, frequency: 50) > 0.08, "System audio is never passed through microphone cleanup")
        try SelfTest.require(AudioTests.magnitude(microphone, frequency: 50) < 0.025 && AudioTests.magnitude(microphone, frequency: 440) > 0.10, "Actual AAC microphone recording attenuates hum and retains voiced-band sound")
        print("PASS: real encoder/AAC output cleans microphone only and preserves system audio")
    }
}
