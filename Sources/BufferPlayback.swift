import AVFoundation

/// An immutable edit list over pinned compressed segments. Preparing a preview
/// reads only track metadata; it never renders a movie or mixes an AAC stream.
final class BufferPlayback {
    struct SourceSpan {
        let sourceStart: Double
        let sourceEnd: Double
        let previewStart: Double
        let previewEnd: Double
    }
    let asset: AVComposition
    let duration: Double
    let bytes: Int64
    let sourceURLs: [URL]
    let sourceSpans: [SourceSpan]
    // AVAssetTrack does not guarantee the lifetime of its originating asset.
    // Keep every referenced source alive through playback and confirmed export.
    private let sourceAssets: [AVURLAsset]
    private let levels: AudioLevels
    private let videoID: CMPersistentTrackID
    private let audioIDs: [AudioSource: CMPersistentTrackID]

    func audioTrackID(for source: AudioSource) -> CMPersistentTrackID? { audioIDs[source] }

    private init(asset: AVComposition, duration: Double, bytes: Int64, sourceURLs: [URL], sourceSpans: [SourceSpan], sourceAssets: [AVURLAsset], levels: AudioLevels, videoID: CMPersistentTrackID, audioIDs: [AudioSource: CMPersistentTrackID]) {
        self.asset = asset; self.duration = duration; self.bytes = bytes
        self.sourceURLs = sourceURLs; self.sourceSpans = sourceSpans
        self.sourceAssets = sourceAssets
        self.levels = levels; self.videoID = videoID; self.audioIDs = audioIDs
    }

    static func prepare(_ snapshot: SpySnapshot, levels: AudioLevels) async throws -> BufferPlayback {
        guard snapshot.requestedSeconds.isFinite, snapshot.requestedSeconds > 0 else { throw SpyError.message("Выберите время больше нуля.") }
        struct Source {
            let url: URL
            let asset: AVURLAsset
            let video: AVAssetTrack
            let range: CMTimeRange
            let audio: [(AVAssetTrack, AudioSource)]
            let interval: SpySourceInterval
        }
        var sources: [Source] = []
        var total = CMTime.zero
        for (index, url) in snapshot.urls.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await video.load(.timeRange)
            guard range.duration.isNumeric, range.duration > .zero else { continue }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var tagged: [(AVAssetTrack, AudioSource)] = []
            for (audioIndex, track) in audio.enumerated() {
                var kind: AudioSource = audioIndex == 0 ? .system : .microphone
                for entry in try await track.load(.metadata) where entry.identifier == .quickTimeMetadataTitle {
                    if let text = try await entry.load(.stringValue), let source = AudioSource(rawValue: text) { kind = source }
                }
                tagged.append((track, kind))
            }
            let interval = index < snapshot.sourceIntervals.count ? snapshot.sourceIntervals[index] : SpySourceInterval(start: range.start.seconds, end: (range.start + range.duration).seconds)
            sources.append(Source(url: url, asset: asset, video: video, range: range, audio: tagged, interval: interval))
            total = total + range.duration
        }
        guard total > .zero else { throw SpyError.message("В буфере пока нет кадров.") }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось подготовить видео.") }
        var audioTracks: [AudioSource: AVMutableCompositionTrack] = [:]
        var skip = CMTimeMaximum(.zero, total - CMTime(seconds: snapshot.requestedSeconds, preferredTimescale: 60_000))
        var cursor = CMTime.zero
        var used: [URL] = []
        var retainedAssets: [AVURLAsset] = []
        var spans: [SourceSpan] = []
        var bytes: Int64 = 0
        for source in sources {
            try Task.checkCancellation()
            if skip >= source.range.duration { skip = skip - source.range.duration; continue }
            let start = source.range.start + skip
            let length = source.range.duration - skip
            let selected = CMTimeRange(start: start, duration: length)
            do { try video.insertTimeRange(selected, of: source.video, at: cursor) }
            catch { throw SpyError.message("Не удалось подготовить сегмент видео \(source.url.lastPathComponent).\n" + describeError(error)) }
            for (track, kind) in source.audio {
                if audioTracks[kind] == nil {
                    guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось подготовить звуковую дорожку.") }
                    audioTracks[kind] = target
                }
                let audioRange = try await track.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(selected, otherRange: audioRange)
                if intersection.duration > .zero {
                    do { try audioTracks[kind]?.insertTimeRange(intersection, of: track, at: cursor + intersection.start - selected.start) }
                    catch { throw SpyError.message("Не удалось подготовить звук \(kind.rawValue) в \(source.url.lastPathComponent).\n" + describeError(error)) }
                }
            }
            let sourceStart = source.interval.start + skip.seconds
            spans.append(SourceSpan(sourceStart: sourceStart, sourceEnd: min(source.interval.end, sourceStart + length.seconds), previewStart: cursor.seconds, previewEnd: (cursor + length).seconds))
            used.append(source.url)
            retainedAssets.append(source.asset)
            bytes += Int64((try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            cursor = cursor + length; skip = .zero
        }
        if let first = sources.first { video.preferredTransform = try await first.video.load(.preferredTransform) }
        let audible = audioTracks.filter { !$0.value.segments.isEmpty }
        return BufferPlayback(asset: composition.copy() as! AVComposition, duration: cursor.seconds, bytes: bytes, sourceURLs: used, sourceSpans: spans, sourceAssets: retainedAssets, levels: levels, videoID: video.trackID, audioIDs: audible.mapValues(\.trackID))
    }

    /// Source times use the encoder clock, not wall time, so marks remain exact
    /// through ring pruning, sleep gaps and a selection clipped at the front.
    func sourcePosition(_ sourceSeconds: Double) -> Double? {
        guard sourceSeconds.isFinite else { return nil }
        for span in sourceSpans where sourceSeconds >= span.sourceStart - 0.00001 && sourceSeconds <= span.sourceEnd + 0.00001 {
            return min(span.previewEnd, max(span.previewStart, span.previewStart + sourceSeconds - span.sourceStart))
        }
        return nil
    }

    func sourceTime(_ previewSeconds: Double) -> Double? {
        guard previewSeconds.isFinite, previewSeconds >= 0, previewSeconds < duration else { return nil }
        guard let span = sourceSpans.first(where: { previewSeconds >= $0.previewStart && previewSeconds < $0.previewEnd }) else { return nil }
        return min(span.sourceEnd, span.sourceStart + previewSeconds - span.previewStart)
    }

    @MainActor func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioIDs.compactMap { kind, id in
            guard let track = asset.track(withTrackID: id) else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(levels[kind], at: .zero)
            return parameters
        }
        if !mix.inputParameters.isEmpty { item.audioMix = mix }
        return item
    }

    @MainActor func videoAudioControls() -> VideoAudioControls {
        VideoAudioControls(item: playerItem(), microphoneIDs: Set(audioIDs[.microphone].map { [$0] } ?? []),
            volumes: Dictionary(uniqueKeysWithValues: audioIDs.map { ($0.value, levels[$0.key]) }))
    }

    /// Export only after confirmation, from the same immutable edit list and
    /// frozen source gains used for playback. H.264 packets pass through intact.
    func export(range: PreviewRange, to destination: URL, separateAudio: Bool, editableMicrophone: Bool = false, microphoneEnabled: Bool = true) async throws {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("Нет видеодорожки.") }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось сохранить видео.") }
        let selected = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60_000), duration: CMTime(seconds: range.duration, preferredTimescale: 60_000))
        try video.insertTimeRange(selected, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var audio: [AVMutableCompositionTrack] = []
        var volumes: [CMPersistentTrackID: Float] = [:]
        var names: [CMPersistentTrackID: String] = [:]
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        for kind in AudioSource.allCases where kind != .microphone || microphoneEnabled {
            guard let id = audioIDs[kind], let source = sourceAudio.first(where: { $0.trackID == id }),
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let intersection = CMTimeRangeGetIntersection(selected, otherRange: try await source.load(.timeRange))
            guard intersection.duration > .zero else { composition.removeTrack(target); continue }
            try target.insertTimeRange(intersection, of: source, at: intersection.start - selected.start)
            audio.append(target); volumes[target.trackID] = levels[kind]; names[target.trackID] = kind.rawValue
        }
        if !audio.isEmpty {
            try await MixedAudioExporter.export(composition, video: video, audio: audio, to: destination, volumes: volumes, separate: separateAudio || (editableMicrophone && names.values.contains(AudioSource.microphone.rawValue)), names: names, progress: { _ in })
        } else {
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw SpyError.message("Экспорт видео недоступен.") }
            exporter.outputURL = destination; exporter.outputFileType = .mov; exporter.shouldOptimizeForNetworkUse = true
            await exporter.export()
            guard exporter.status == .completed else { try? FileManager.default.removeItem(at: destination); throw exporter.error ?? SpyError.message("Не удалось сохранить видео.") }
        }
    }
}
