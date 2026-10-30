import AppKit
import AVFoundation

extension URL {
    /// FileManager directory listings and appendingPathComponent may produce
    /// different URL bases for the same file. Use one absolute representation.
    var spyFileURL: URL { URL(fileURLWithPath: path).standardizedFileURL }
}

struct ClipMetadata: Codable, Equatable {
    var name = ""
    var favorite = false
    var markers: [ClipMarker] = []
    var playback: PlaybackBookmark? = nil
    enum CodingKeys: String, CodingKey { case name, favorite, markers, playback }
    init(name: String = "", favorite: Bool = false, markers: [ClipMarker] = []) {
        self.name = name; self.favorite = favorite; self.markers = markers
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        markers = try values.decodeIfPresent([ClipMarker].self, forKey: .markers) ?? []
        playback = try? values.decodeIfPresent(PlaybackBookmark.self, forKey: .playback)
    }
}

@MainActor final class LibraryMetadata {
    let url: URL
    private(set) var loadError: String?
    private var values: [String: ClipMetadata] = [:]
    init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do { values = try JSONDecoder().decode([String: ClipMetadata].self, from: Data(contentsOf: url)) }
            catch { loadError = error.localizedDescription }
        }
    }
    private func legacyValue(_ clip: URL) -> ClipMetadata? {
        let oldFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Spy", isDirectory: true)
        return clip.deletingLastPathComponent().spyFileURL.path == oldFolder.spyFileURL.path ? values[clip.lastPathComponent] : nil
    }
    func get(_ clip: URL) -> ClipMetadata { values[clip.spyFileURL.path] ?? legacyValue(clip) ?? ClipMetadata() }
    func contains(_ clip: URL) -> Bool { values[clip.spyFileURL.path] != nil || legacyValue(clip) != nil }
    func set(_ value: ClipMetadata, for clip: URL) throws {
        guard loadError == nil else { throw SpyError.message("Не удалось прочитать названия и избранное. Подробности — в журнале ошибок.") }
        var candidate = values; candidate[clip.spyFileURL.path] = value
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: url, options: .atomic)
        values = candidate
    }
}

struct CleanupPolicy {
    var enabled: Bool
    var maximumBytes: Int64
    var maximumAgeDays: Int
    func plan(_ clips: [Clip], protecting ids: Set<URL> = [], now: Date = Date()) -> [Clip] {
        guard enabled else { return [] }
        let protected = Set(ids.map(\.spyFileURL))
        let candidates = clips.filter { $0.managed && !$0.favorite && !protected.contains($0.id.spyFileURL) }.sorted { $0.date < $1.date }
        var selected: [Clip] = []
        var selectedIDs: Set<URL> = []
        var bytes = clips.reduce(Int64(0)) { $0 + $1.bytes }
        if maximumAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maximumAgeDays) * 86_400)
            for clip in candidates where clip.date < cutoff {
                selected.append(clip); selectedIDs.insert(clip.id); bytes -= clip.bytes
            }
        }
        if maximumBytes > 0 {
            for clip in candidates where !selectedIDs.contains(clip.id) && bytes > maximumBytes {
                selected.append(clip); selectedIDs.insert(clip.id); bytes -= clip.bytes
            }
        }
        return selected
    }
}

enum ClipTrimmer {
    static func export(source: URL, start: Double, end: Double, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let range = try PreviewRange(start: start, end: end, duration: duration)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw SpyError.message("Обрезка видео недоступна.") }
        exporter.outputURL = destination; exporter.outputFileType = .mov
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60_000), duration: CMTime(seconds: range.duration, preferredTimescale: 60_000))
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw exporter.error ?? SpyError.message("Не удалось сохранить фрагмент.")
        }
    }
}

func preciseClock(_ seconds: Double) -> String {
    let value = max(0, seconds)
    return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case display, window
    var id: String { rawValue }
    var title: String { self == .display ? "Весь экран" : "Отдельное окно" }
}
struct WindowChoice: Identifiable { var id: CGWindowID; var title: String }
struct MicrophoneChoice: Identifiable { var id: String; var name: String }

enum AudioSource: String, CaseIterable { case system = "Spy.System", microphone = "Spy.Microphone" }
struct AudioLevels: Equatable {
    var system: Float = 1
    var microphone: Float = 1
    subscript(_ source: AudioSource) -> Float { min(1, max(0, source == .system ? system : microphone)) }
}
struct AudioMeter {
    var system: Float = 0
    var microphone: Float = 0
    static func normalized(_ amplitude: Float) -> Double {
        min(1, max(0, (20 * log10(Double(max(0.000001, amplitude))) + 60) / 60))
    }
    static func rms(_ sample: CMSampleBuffer) -> Float {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return 0 }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { return 0 }
        let frames = CMSampleBufferGetNumSamples(sample)
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return 0 }
        let channels = Int(format.channelCount)
        let stride = format.isInterleaved ? channels : 1
        var sum = 0.0
        for channel in 0..<channels {
            for frame in 0..<frames {
                let index = frame * stride + (format.isInterleaved ? channel : 0)
                let plane = format.isInterleaved ? 0 : channel
                let value: Double
                if let data = buffer.floatChannelData { value = Double(data[plane][index]) }
                else if let data = buffer.int16ChannelData { value = Double(data[plane][index]) / 32768 }
                else if let data = buffer.int32ChannelData { value = Double(data[plane][index]) / 2147483648 }
                else { return 0 }
                sum += value * value
            }
        }
        return Float(sqrt(sum / Double(max(1, frames * channels))))
    }
}
