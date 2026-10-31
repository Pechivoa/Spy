import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct RoutingDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    var isBlackHole: Bool { uid.lowercased().hasPrefix("blackhole") && inputChannels >= 2 && outputChannels >= 2 }
}

enum RoutingDevices {
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func all() -> [RoutingDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty, AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in RoutingDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
            inputChannels: channels(id, scope: kAudioDevicePropertyScopeInput), outputChannels: channels(id, scope: kAudioDevicePropertyScopeOutput)) }
    }
    static func defaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }
}

struct SoundpadPCM {
    static let rate: Double = 48_000
    static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let samples: [Float] // stereo, interleaved; immutable and shared by the two renderers
    var frames: Int { samples.count / 2 }
    var duration: Double { Double(frames) / Self.rate }
}

/// Conversion stays on the serial capture/import queue, away from the audio render callback.
final class RoutingPCMConverter {
    private var converter: AVAudioConverter?
    func convert(_ input: AVAudioPCMBuffer) throws -> SoundpadPCM {
        if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: SoundpadPCM.format) }
        guard let converter else { throw SpyError.message("Формат звука не поддерживается.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * SoundpadPCM.rate / input.format.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: SoundpadPCM.format, frameCapacity: capacity) else { throw SpyError.message("Недостаточно памяти для звука.") }
        var offset: AVAudioFrameCount = 0
        var chunks: [AVAudioPCMBuffer] = []
        var samples: [Float] = []
        for _ in 0..<64 {
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { requested, status in
                guard offset < input.frameLength else { status.pointee = .noDataNow; return nil }
                let count = min(requested, input.frameLength - offset)
                guard let chunk = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else { status.pointee = .noDataNow; return nil }
                chunk.frameLength = count
                let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
                let stride = Int(input.format.streamDescription.pointee.mBytesPerFrame)
                for i in source.indices {
                    if let from = source[i].mData, let to = target[i].mData { memcpy(to, from.advanced(by: Int(offset) * stride), Int(count) * stride) }
                }
                offset += count; chunks.append(chunk); status.pointee = .haveData; return chunk
            }
            if let error { throw error }
            guard result != .error, let channels = output.floatChannelData else { throw SpyError.message("Не удалось преобразовать звук.") }
            for i in 0..<Int(output.frameLength) { samples.append(channels[0][i]); samples.append(channels[1][i]) }
            if result != .haveData { break }
        }
        return SoundpadPCM(samples: samples)
    }
    func convert(_ sample: CMSampleBuffer) throws -> SoundpadPCM {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { throw SpyError.message("Нет формата входящего звука.") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
            throw SpyError.message("Не удалось прочитать входящий звук.")
        }
        input.frameLength = input.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength), into: input.mutableAudioBufferList)
        guard status == noErr else { throw SpyError.message("Ошибка чтения звука: \(status).") }
        return try convert(input)
    }
    static func loadFile(_ url: URL) throws -> SoundpadPCM {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= 120 else { throw SpyError.message("Добавьте звук длительностью до двух минут.") }
        let converter = RoutingPCMConverter()
        var samples: [Float] = []
        let chunk = AVAudioFrameCount(8192)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw SpyError.message("Не удалось открыть звук.") }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            samples += try converter.convert(buffer).samples
            guard samples.count <= 11_520_512 else { throw SpyError.message("Звуковой файл слишком большой.") }
        }
        guard !samples.isEmpty else { throw SpyError.message("В файле нет звука.") }
        return SoundpadPCM(samples: samples)
    }
}

/// Bounded FIFO. All access is under the mixer's lock; no allocations or file work in render.
private struct RoutingRing {
    private var data = [Float](repeating: 0, count: 24_000)
    private var read = 0
    private var count = 0
    var dropped = 0
    mutating func clear() { read = 0; count = 0 }
    mutating func append(_ samples: [Float]) {
        let values = samples.count - samples.count % 2
        let skip = max(0, values - data.count)
        dropped += skip / 2
        let incoming = values - skip
        let overflow = max(0, count + incoming - data.count)
        if overflow > 0 { read = (read + overflow) % data.count; count -= overflow; dropped += overflow / 2 }
        for i in skip..<values { data[(read + count) % data.count] = samples[i].isFinite ? samples[i] : 0; count += 1 }
    }
    mutating func next() -> (Float, Float) {
        guard count >= 2 else { return (0, 0) }
        let left = data[read]; let right = data[(read + 1) % data.count]
        read = (read + 2) % data.count; count -= 2
        return (left, right)
    }
}

final class RoutingMixer {
    struct Metrics { var system: Float; var microphone: Float; var output: Float; var clipped: Int; var dropped: Int; var voices: Int }
    private struct Voice { let id: UUID; let pcm: SoundpadPCM; var frame: Int = 0 }
    private let lock = NSLock()
    private var system = RoutingRing(), microphone = RoutingRing()
    private var voices: [Voice] = []
    private var enabled = false
    private var systemGain: Float = 0.65, microphoneGain: Float = 1, padGain: Float = 0.7
    private var systemPeak: Float = 0, micPeak: Float = 0, outputPeak: Float = 0
    private var clipped = 0
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value; system.clear(); microphone.clear(); voices.removeAll(keepingCapacity: true)
        systemPeak = 0; micPeak = 0; outputPeak = 0
    }
    func levels(system: Double, microphone: Double, pads: Double) {
        lock.lock(); defer { lock.unlock() }
        func safe(_ value: Double) -> Float { value.isFinite ? Float(min(1, max(0, value))) : 0 }
        systemGain = safe(system); microphoneGain = safe(microphone); padGain = safe(pads)
    }
    func append(_ pcm: SoundpadPCM, microphone isMic: Bool) {
        lock.lock(); defer { lock.unlock() }; guard enabled else { return }
        if isMic { microphone.append(pcm.samples) } else { system.append(pcm.samples) }
    }
    func play(id: UUID, pcm: SoundpadPCM) {
        lock.lock(); defer { lock.unlock() }; guard enabled else { return }
        voices.removeAll { $0.id == id }
        if voices.count >= 4 { voices.removeFirst() }
        voices.append(Voice(id: id, pcm: pcm))
    }
    func stopPads() { lock.lock(); voices.removeAll(keepingCapacity: true); lock.unlock() }
    func metrics() -> Metrics {
        lock.lock(); defer { lock.unlock() }
        let value = Metrics(system: systemPeak, microphone: micPeak, output: outputPeak, clipped: clipped, dropped: system.dropped + microphone.dropped, voices: voices.count)
        systemPeak = 0; micPeak = 0; outputPeak = 0
        return value
    }
    func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        // AVAudioSourceNode is connected with planar stereo Float32.
        guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in buffers { if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) } }; return
        }
        for i in 0..<frames {
            var l: Float = 0, r: Float = 0
            if enabled {
                let s = system.next(); let m = microphone.next()
                systemPeak = max(systemPeak, abs(s.0), abs(s.1)); micPeak = max(micPeak, abs(m.0), abs(m.1))
                l = s.0 * systemGain + m.0 * microphoneGain; r = s.1 * systemGain + m.1 * microphoneGain
                for v in voices.indices where voices[v].frame < voices[v].pcm.frames {
                    let offset = voices[v].frame * 2
                    l += voices[v].pcm.samples[offset] * padGain; r += voices[v].pcm.samples[offset + 1] * padGain
                    voices[v].frame += 1
                }
                if abs(l) > 1 || abs(r) > 1 { clipped += 1 }
            }
            left[i] = min(1, max(-1, l)); right[i] = min(1, max(-1, r))
            outputPeak = max(outputPeak, abs(left[i]), abs(right[i]))
        }
        voices.removeAll { $0.frame >= $0.pcm.frames }
    }
}

final class RoutingOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    let device: RoutingDevice
    init(device: RoutingDevice, mixer: RoutingMixer) throws {
        self.device = device
        guard let unit = engine.outputNode.audioUnit else { throw SpyError.message("Аудиовыход недоступен.") }
        var id = device.id
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw SpyError.message("Не удалось выбрать \(device.name): \(result).") }
        let node = AVAudioSourceNode(format: SoundpadPCM.format) { _, _, count, list in mixer.render(frames: Int(count), into: list); return noErr }
        source = node; engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: SoundpadPCM.format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare(); try engine.start()
        var actual: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
        guard status == noErr, actual == device.id else { engine.stop(); throw SpyError.message("Маршрут аудиовыхода изменился. Передача остановлена.") }
    }
    func stop() { engine.stop() }
    var running: Bool { engine.isRunning }
    deinit { engine.stop() }
}
