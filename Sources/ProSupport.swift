import AppKit
import AVFoundation
import IOKit.ps
import ServiceManagement

struct CaptureSettings: Codable, Equatable {
    var quality: Quality
    var minutes: Double
    var systemAudio: Bool
    var microphone: Bool
    var microphoneID: String
    var systemVolume: Double
    var microphoneVolume: Double
    var separateAudio: Bool
    func validate() throws {
        guard minutes.isFinite, (0...30).contains(minutes), systemVolume.isFinite, microphoneVolume.isFinite,
              (0...1).contains(systemVolume), (0...1).contains(microphoneVolume) else { throw SpyError.message("В профиле некорректные значения времени или громкости.") }
    }
}
struct AppProfile: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var settings: CaptureSettings
}
struct AppChoice: Identifiable { var id: String; var name: String }

enum PowerPolicy {
    static func quality(base: Quality, battery: Quality, enabled: Bool, onBattery: Bool) -> Quality { enabled && onBattery ? battery : base }
    static func minutes(base: Double, cap: Double, enabled: Bool, onBattery: Bool) -> Double { enabled && onBattery ? min(base, cap) : base }
}

final class PowerMonitor {
    private var source: CFRunLoopSource?
    private let changed: (Bool) -> Void
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.changed(PowerMonitor.onBattery())
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    deinit { if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) } }
}

@MainActor enum LoginService {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum MediaSharing {
    static func composition(url: URL) async throws -> (AVMutableComposition, AVMutableCompositionTrack, [AVMutableCompositionTrack]) {
        let asset = AVURLAsset(url: url)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("В файле нет видеодорожки.") }
        let videoRange = try await sourceVideo.load(.timeRange)
        let result = AVMutableComposition()
        guard let video = result.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось подготовить видео.") }
        try video.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var audio: [AVMutableCompositionTrack] = []
        for source in try await asset.loadTracks(withMediaType: .audio) {
            guard let track = result.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось подготовить звук.") }
            let range = CMTimeRangeGetIntersection(videoRange, otherRange: try await source.load(.timeRange))
            if range.duration > .zero { try track.insertTimeRange(range, of: source, at: range.start - videoRange.start) }
            audio.append(track)
        }
        return (result, video, audio)
    }
    static func exportMP4(source: URL, to destination: URL, microphoneEnabled: Bool = true, levels: AudioLevels = AudioLevels()) async throws {
        let video = try await EditableVideoAudio.load(url: source)
        try await video.export(to: destination, microphoneEnabled: microphoneEnabled, levels: levels, fileType: .mp4)
    }
    @MainActor static func playerItem(url: URL) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).count > 1 else { return AVPlayerItem(asset: asset) }
        let (composition, _, audio) = try await self.composition(url: url)
        let item = AVPlayerItem(asset: composition)
        let mix = AVMutableAudioMix()
        mix.inputParameters = audio.map { track in let value = AVMutableAudioMixInputParameters(track: track); value.setVolume(1, at: .zero); return value }
        item.audioMix = mix
        return item
    }
    static func recoverySnapshot(directory: URL) async throws -> SpySnapshot {
        try await ReplayCrashRecovery.snapshot(in: directory)
    }
}
