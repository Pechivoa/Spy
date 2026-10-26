import Foundation
import AVFoundation

/// Queue-confined microphone DSP. This is a rumble filter and a soft noise gate,
/// not speech separation. System audio must never be passed through this filter.
final class MicrophoneCleanup {
    var enabled = false { didSet { if enabled != oldValue { reset() } } }

    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0
        init(rate: Double, q: Double) {
            let omega = 2 * Double.pi * min(100, rate * 0.1) / rate
            let cosine = cos(omega), alpha = sin(omega) / (2 * q), divisor = 1 + alpha
            b0 = (1 + cosine) / (2 * divisor)
            b1 = -(1 + cosine) / divisor
            b2 = b0
            a1 = -2 * cosine / divisor
            a2 = (1 - alpha) / divisor
        }
        mutating func process(_ input: Double) -> Double {
            let output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }
    }
    private var stages: [[Biquad]] = []
    private var sampleRate = 0.0
    private var channelCount = 0
    private var envelope = 0.0
    private var gain = 0.04
    private var holdFrames = 0
    private var previousEnd: CMTime = .invalid

    func reset() {
        stages = []; sampleRate = 0; channelCount = 0
        envelope = 0; gain = 0.04; holdFrames = 0; previousEnd = .invalid
    }

    func process(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard enabled else { return sample }
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else {
            throw SpyError.message("Микрофон передал некорректный звуковой буфер.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        let rate = format.sampleRate, channels = Int(format.channelCount)
        guard frames > 0, frames <= 1_000_000, rate.isFinite, (8000...384000).contains(rate), (1...32).contains(channels),
              format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16 || format.commonFormat == .pcmFormatInt32,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw SpyError.message("Формат микрофона не поддерживает очистку звука.")
        }
        input.frameLength = AVAudioFrameCount(frames)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw SpyError.message("Не удалось прочитать микрофон для очистки: \(copied).") }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        let discontinuity = previousEnd.isNumeric && timestamp.isNumeric && abs((timestamp - previousEnd).seconds) > 0.25
        if sampleRate != rate || channelCount != channels || discontinuity {
            reset()
            sampleRate = rate; channelCount = channels
            stages = (0..<channels).map { _ in [Biquad(rate: rate, q: 0.5411961001), Biquad(rate: rate, q: 1.306562965)] }
        }
        let interleaved = format.isInterleaved
        let attack = exp(-1 / (rate * 0.002))
        let release = exp(-1 / (rate * 0.080))
        let gainAttack = exp(-1 / (rate * 0.003))
        let gainRelease = exp(-1 / (rate * 0.120))
        let openLevel = 0.004, closeLevel = 0.0012
        let holdLength = Int(rate * 0.10)
        var output = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            var peak = 0.0
            for channel in 0..<channels {
                let plane = interleaved ? 0 : channel
                let offset = interleaved ? frame * channels + channel : frame
                let value: Double
                if let floats = input.floatChannelData { value = Double(floats[plane][offset]) }
                else if let integers = input.int16ChannelData { value = Double(integers[plane][offset]) / 32768 }
                else if let integers = input.int32ChannelData { value = Double(integers[plane][offset]) / 2147483648 }
                else { throw SpyError.message("Не удалось прочитать каналы микрофона.") }
                // Bad device samples must not poison persistent filter state.
                var filtered = value.isFinite ? value : 0
                filtered = stages[channel][0].process(filtered)
                filtered = stages[channel][1].process(filtered)
                peak = max(peak, abs(filtered))
                output[frame * channels + channel] = Float(filtered)
            }
            let coefficient = peak > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * peak
            if envelope >= openLevel { holdFrames = holdLength }
            else if holdFrames > 0 { holdFrames -= 1 }
            let amount = min(1, max(0, (envelope - closeLevel) / (openLevel - closeLevel)))
            let soft = amount * amount * (3 - 2 * amount)
            let target = holdFrames > 0 ? 1 : 0.04 + soft * 0.96
            let gainCoefficient = target > gain ? gainAttack : gainRelease
            gain = gainCoefficient * gain + (1 - gainCoefficient) * target
            for channel in 0..<channels {
                let offset = frame * channels + channel
                output[offset] = Float(max(-1, min(1, Double(output[offset]) * gain)))
            }
        }
        let sourceDuration = CMSampleBufferGetDuration(sample)
        previousEnd = timestamp + (sourceDuration.isNumeric ? sourceDuration : CMTime(seconds: Double(frames) / rate, preferredTimescale: 1_000_000_000))
        return try makeSample(output, frames: frames, rate: rate, channels: channels, source: sample)
    }

    private func makeSample(_ values: [Float], frames: Int, rate: Double, channels: Int, source: CMSampleBuffer) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        let byteCount = values.count * MemoryLayout<Float>.size
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw SpyError.message("Не удалось создать очищенный звук: \(status).") }
        status = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        guard status == noErr else { throw SpyError.message("Не удалось скопировать очищенный звук: \(status).") }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw SpyError.message("Не удалось описать очищенный звук: \(status).") }
        var timing = CMSampleTimingInfo()
        status = CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing)
        guard status == noErr else { throw SpyError.message("Не удалось сохранить время очищенного звука: \(status).") }
        var size = channels * 4
        var result: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result)
        guard status == noErr, let result else { throw SpyError.message("Не удалось передать очищенный звук: \(status).") }
        return result
    }
}
