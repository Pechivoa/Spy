import AVFoundation

/// Copies compressed H.264/HEVC video, applying gains to mixed or separate AAC audio.
enum MixedAudioExporter {
    static func export(_ composition: AVMutableComposition, video: AVAssetTrack, audio: [AVAssetTrack], to destination: URL, volumes: [CMPersistentTrackID: Float] = [:], separate: Bool = false, names: [CMPersistentTrackID: String] = [:], fileType: AVFileType = .mov, progress: @escaping (Float) -> Void) async throws {
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false; reader.add(videoOutput)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        guard let format = try await video.load(.formatDescriptions).first else { throw SpyError.message("Не удалось прочитать формат видео.") }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.transform = try await video.load(.preferredTransform); writer.add(videoInput)
        let groups: [[AVAssetTrack]] = separate ? audio.map { [$0] } : [audio]
        var outputs: [AVAssetReaderAudioMixOutput] = []
        var inputs: [AVAssetWriterInput] = []
        for group in groups where !group.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: group, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = group.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(volumes[track.trackID] ?? 1, at: .zero); return parameters
            }
            output.audioMix = mix; reader.add(output); outputs.append(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            let tag = AVMutableMetadataItem(); tag.identifier = .quickTimeMetadataTitle
            tag.value = (separate ? names[group[0].trackID] ?? "Spy.Audio" : "Spy.Mixed") as NSString
            input.metadata = [tag]; writer.add(input); inputs.append(input)
        }
        let duration = try await composition.load(.duration)
        do {
            guard writer.startWriting() else { throw writer.error ?? SpyError.message("Не удалось подготовить сохранение видео.") }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else { throw reader.error ?? SpyError.message("Не удалось прочитать звуковые дорожки.") }
            var videoDone = false, audioDone = Array(repeating: false, count: inputs.count)
            var lastProgress: Float = -1
            while !videoDone || audioDone.contains(false) {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? SpyError.message("Ошибка сохранения звука.") }
                if reader.status == .failed { throw reader.error ?? SpyError.message("Ошибка чтения звука.") }
                var advanced = false
                for _ in 0..<8 where !videoDone && videoInput.isReadyForMoreMediaData {
                    try autoreleasepool {
                        if let sample = videoOutput.copyNextSampleBuffer() {
                            guard videoInput.append(sample) else { throw writer.error ?? SpyError.message("Ошибка копирования видеокадра.") }
                        } else { videoInput.markAsFinished(); videoDone = true }
                    }; advanced = true
                }
                for index in inputs.indices {
                    for _ in 0..<16 where !audioDone[index] && inputs[index].isReadyForMoreMediaData {
                        try autoreleasepool {
                            if let sample = outputs[index].copyNextSampleBuffer() {
                                guard inputs[index].append(sample) else { throw writer.error ?? SpyError.message("Ошибка сохранения аудиодорожки.") }
                                let fraction = Float(sample.presentationTimeStamp.seconds / max(0.01, duration.seconds))
                                if fraction - lastProgress > 0.03 { lastProgress = fraction; progress(min(0.95, fraction)) }
                            } else { inputs[index].markAsFinished(); audioDone[index] = true }
                        }; advanced = true
                    }
                }
                if !advanced { try await Task.sleep(nanoseconds: 1_000_000) }
            }
            if reader.status == .failed { throw reader.error ?? SpyError.message("Не удалось полностью прочитать запись.") }
            writer.endSession(atSourceTime: duration); await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? SpyError.message("Сохранение видео не завершено.") }
            progress(1)
        } catch {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: destination); throw error
        }
    }
}
