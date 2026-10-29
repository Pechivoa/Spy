import SwiftUI
import AVFoundation

/// Keep the source asset alive while compositions reference its compressed media.
final class EditableVideoAudio {
    let source: AVURLAsset
    let asset: AVMutableComposition
    let video: AVMutableCompositionTrack
    let audio: [AVMutableCompositionTrack]
    let names: [CMPersistentTrackID: String]
    var microphoneIDs: Set<CMPersistentTrackID> {
        Set(names.filter { $0.value == AudioSource.microphone.rawValue }.map(\.key))
    }

    private init(source: AVURLAsset, asset: AVMutableComposition, video: AVMutableCompositionTrack,
                 audio: [AVMutableCompositionTrack], names: [CMPersistentTrackID: String]) {
        self.source = source; self.asset = asset; self.video = video; self.audio = audio; self.names = names
    }

    static func load(url: URL) async throws -> EditableVideoAudio {
        let source = AVURLAsset(url: url)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else {
            throw SpyError.message("В файле нет видеодорожки.")
        }
        let videoRange = try await sourceVideo.load(.timeRange)
        let asset = AVMutableComposition()
        guard let video = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SpyError.message("Не удалось подготовить видео.")
        }
        try video.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var audio: [AVMutableCompositionTrack] = [], names: [CMPersistentTrackID: String] = [:]
        for track in try await source.loadTracks(withMediaType: .audio) {
            let range = CMTimeRangeGetIntersection(videoRange, otherRange: try await track.load(.timeRange))
            guard range.duration > .zero else { continue }
            guard let target = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw SpyError.message("Не удалось подготовить звук.")
            }
            try target.insertTimeRange(range, of: track, at: range.start - videoRange.start)
            var name = "Spy.Mixed"
            for entry in try await track.load(.metadata) where entry.identifier == .quickTimeMetadataTitle {
                if let value = try await entry.load(.stringValue), AudioSource(rawValue: value) != nil { name = value }
            }
            names[target.trackID] = name; audio.append(target)
        }
        return EditableVideoAudio(source: source, asset: asset, video: video, audio: audio, names: names)
    }

    func export(to destination: URL, start: Double = 0, end: Double? = nil,
                microphoneEnabled: Bool = true, levels: AudioLevels = AudioLevels(), fileType: AVFileType = .mov) async throws {
        let duration = try await asset.load(.duration).seconds
        let range = try PreviewRange(start: start, end: end ?? duration, duration: duration)
        let selected = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60_000),
                                   duration: CMTime(seconds: range.duration, preferredTimescale: 60_000))
        let composition = AVMutableComposition()
        guard let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось подготовить видео.") }
        try targetVideo.insertTimeRange(selected, of: video, at: .zero)
        targetVideo.preferredTransform = video.preferredTransform
        var selectedAudio: [AVMutableCompositionTrack] = [], selectedNames: [CMPersistentTrackID: String] = [:]
        var selectedVolumes: [CMPersistentTrackID: Float] = [:]
        for track in audio where microphoneEnabled || !microphoneIDs.contains(track.trackID) {
            let intersection = CMTimeRangeGetIntersection(selected, otherRange: track.timeRange)
            guard intersection.duration > .zero else { continue }
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось подготовить звук.") }
            try target.insertTimeRange(intersection, of: track, at: intersection.start - selected.start)
            selectedAudio.append(target); selectedNames[target.trackID] = names[track.trackID]
            selectedVolumes[target.trackID] = levels[microphoneIDs.contains(track.trackID) ? .microphone : .system]
        }
        if !selectedAudio.isEmpty {
            try await MixedAudioExporter.export(composition, video: targetVideo, audio: selectedAudio, to: destination,
                volumes: selectedVolumes, separate: fileType == .mov, names: selectedNames, fileType: fileType, progress: { _ in })
        } else {
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw SpyError.message("Экспорт видео недоступен.") }
            exporter.outputURL = destination; exporter.outputFileType = fileType
            await exporter.export()
            guard exporter.status == .completed else { try? FileManager.default.removeItem(at: destination); throw exporter.error ?? SpyError.message("Не удалось сохранить видео.") }
        }
    }
}

@MainActor final class VideoAudioControls: ObservableObject {
    let item: AVPlayerItem
    let microphoneIDs: Set<CMPersistentTrackID>
    let hasAudio: Bool
    let hasUnidentifiedAudio: Bool
    private let retainedSource: EditableVideoAudio?
    private let volumes: [CMPersistentTrackID: Float]
    @Published var microphoneEnabled = true { didSet { apply() } }
    @Published var systemGain: Double = 1 { didSet { apply(); onGainsChanged?() } }
    @Published var microphoneGain: Double = 1 { didSet { apply(); onGainsChanged?() } }
    var onGainsChanged: (() -> Void)?
    var gains: AudioLevels { AudioLevels(system: Float(systemGain), microphone: Float(microphoneGain)) }
    var canMuteMicrophone: Bool { !microphoneIDs.isEmpty }

    init(item: AVPlayerItem, microphoneIDs: Set<CMPersistentTrackID>, volumes: [CMPersistentTrackID: Float],
         hasUnidentifiedAudio: Bool = false, retainedSource: EditableVideoAudio? = nil) {
        self.item = item; self.microphoneIDs = microphoneIDs; self.volumes = volumes
        self.hasAudio = !volumes.isEmpty; self.hasUnidentifiedAudio = hasUnidentifiedAudio
        self.retainedSource = retainedSource
        apply()
    }
    static func load(url: URL) async throws -> VideoAudioControls {
        let source = try await EditableVideoAudio.load(url: url)
        return VideoAudioControls(item: AVPlayerItem(asset: source.asset), microphoneIDs: source.microphoneIDs,
            volumes: Dictionary(uniqueKeysWithValues: source.audio.map { ($0.trackID, Float(1)) }),
            hasUnidentifiedAudio: source.names.values.contains("Spy.Mixed"), retainedSource: source)
    }
    private func apply() {
        let mix = AVMutableAudioMix()
        mix.inputParameters = volumes.map { id, volume in
            let value = AVMutableAudioMixInputParameters()
            value.trackID = id
            value.setVolume(!microphoneEnabled && microphoneIDs.contains(id) ? 0 : volume * gains[microphoneIDs.contains(id) ? .microphone : .system], at: .zero)
            return value
        }
        item.audioMix = mix
    }
}

struct VideoMicrophoneView: View {
    @ObservedObject var controls: VideoAudioControls
    var onChange: ((Bool) -> Void)? = nil
    var saveCopy: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if controls.canMuteMicrophone {
                Toggle("Микрофон в видео", isOn: $controls.microphoneEnabled).toggleStyle(.switch)
                    .accessibilityLabel("Микрофон при просмотре видео")
                Text("Выбор учитывается при сохранении фрагмента и экспорте MP4.")
                if !controls.microphoneEnabled, let saveCopy {
                    Button("Сохранить копию без микрофона", action: saveCopy).buttonStyle(.bordered)
                }
            } else if controls.hasUnidentifiedAudio {
                Text("В этом ролике звук уже смешан. Отдельно выключить микрофон нельзя. Новые записи Spy сохраняют его отдельной дорожкой.")
            } else {
                Text(controls.hasAudio ? "В этом ролике нет отдельной дорожки микрофона." : "Видео без звука.")
            }
        }.font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            .onChange(of: controls.microphoneEnabled) { _, value in onChange?(value) }
    }
}

struct MicrophonePickerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "mic").foregroundStyle(Theme.muted)
                Picker("Устройство микрофона", selection: $model.microphoneID) {
                    ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    if !model.microphones.contains(where: { $0.id == model.microphoneID }) {
                        Text("Выбранный микрофон отключён").tag(model.microphoneID)
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
                    .disabled(!model.microphoneAvailable || model.recording || model.busy || model.saving || model.diagnosticsBusy)
                Button { model.refreshMicrophones() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).help("Обновить список микрофонов")
            }
            Text(model.recording ? "Чтобы сменить микрофон, остановите повтор." : "Выберите устройство и включите «Микрофон» для записи голоса.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).onAppear { model.refreshMicrophones() }
    }
}
