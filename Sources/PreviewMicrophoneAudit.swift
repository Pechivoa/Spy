import Foundation
import AVFoundation

/// Explicit local diagnostic: reads completed segments without stopping the
/// live ring, exercises the same preview composition/mix/export as the viewer.
/// Reports contain levels and packet counts only, never speech transcription.
@MainActor enum PreviewMicrophoneAudit {
    static func mixedSamples(_ item: AVPlayerItem) async throws -> [Float] {
        let reader = try AVAssetReader(asset: item.asset)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = item.audioMix
        guard reader.canAdd(output) else { throw SpyError.message("Не удалось проверить звук предпросмотра.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpyError.message("Не удалось прочитать звук предпросмотра.") }
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == noErr else { throw SpyError.message("Ошибка декодирования звука предпросмотра.") }
            for index in stride(from: 0, to: values.count, by: 2) { result.append(values[index]) }
        }
        guard reader.status == .completed else { throw reader.error ?? SpyError.message("Предпросмотр звука прочитан не полностью.") }
        return result
    }
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.spy.mac")
        let sessions = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("replay-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let session = sessions.first else { throw SpyError.message("Сначала включите повтор и накопите несколько сегментов.") }
        let files = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let completed = Array(files.dropLast().suffix(2))
        guard !completed.isEmpty else { throw SpyError.message("В буфере ещё нет завершённых сегментов.") }
        let pins = directory.appendingPathComponent("pinned", isDirectory: true)
        try FileManager.default.createDirectory(at: pins, withIntermediateDirectories: true)
        var urls: [URL] = []
        for file in completed {
            let dest = pins.appendingPathComponent(file.lastPathComponent)
            do { try FileManager.default.linkItem(at: file, to: dest) }
            catch { try FileManager.default.copyItem(at: file, to: dest) }
            urls.append(dest)
        }
        let playback = try await BufferPlayback.prepare(SpySnapshot(directory: pins, urls: urls, requestedSeconds: 3), levels: AudioLevels())
        let controls = playback.videoAudioControls()
        try SelfTest.require(controls.microphoneEnabled && controls.canMuteMicrophone, "Real buffer microphone is enabled in preview")
        let mixed = try await mixedSamples(controls.item)
        let destination = directory.appendingPathComponent("preview-with-microphone.mov")
        let range = try PreviewRange(start: 0, end: playback.duration, duration: playback.duration)
        try await playback.export(range: range, to: destination, separateAudio: false, editableMicrophone: true)
        let source = try await EditableVideoAudio.load(url: destination)
        guard let microphone = source.audio.first(where: { source.microphoneIDs.contains($0.trackID) }) else {
            throw SpyError.message("В сохранённом предпросмотре нет дорожки микрофона.")
        }
        let micPCM = try AudioTests.samples(source.asset, track: microphone)
        func rms(_ values: [Float]) -> Double { sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))) }
        let muted = directory.appendingPathComponent("preview-without-microphone.mov")
        try await playback.export(range: range, to: muted, separateAudio: false, editableMicrophone: true, microphoneEnabled: false)
        let mutedSource = try await EditableVideoAudio.load(url: muted)
        try SelfTest.require(mutedSource.microphoneIDs.isEmpty && source.audio.count >= 2 && !micPCM.isEmpty,
                             "Saving preserves system+microphone unless explicitly muted")
        let report: [String: Any] = ["microphoneEnabledByDefault": controls.microphoneEnabled,
            "previewFrames": mixed.count, "previewRMS": rms(mixed), "savedMicrophoneFrames": micPCM.count,
            "savedMicrophoneRMS": rms(micPCM), "savedAudioTracks": source.audio.count,
            "explicitlyMutedHasMicrophone": !mutedSource.microphoneIDs.isEmpty]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("microphone-audit.json"))
        print("PASS: real cached microphone in default preview mix and saved fragment; explicit mute removes only microphone")
    }
}
