import SwiftUI
import AVFoundation

struct AudioWaveformLane: Identifiable {
    let id: CMPersistentTrackID
    let microphone: Bool
    let peaks: [Float]
    let sampleCount: Int
    let clippedCount: Int
    var silent: Bool { (peaks.max() ?? 0) < 0.001 }
    var clipping: Bool { sampleCount > 0 && Double(clippedCount) / Double(sampleCount) > 0.005 }
}

enum AudioWaveform {
    static func analyze(asset: AVAsset, microphoneIDs: Set<CMPersistentTrackID>, bins: Int = 800) async throws -> [AudioWaveformLane] {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }
        let count = max(8, min(1600, bins))
        var lanes: [AudioWaveformLane] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? SpyError.message("Не удалось прочитать звуковую дорожку.") }
            defer { reader.cancelReading() }
            var peaks = [Float](repeating: 0, count: count), samples = 0, clipped = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { continue }
                let bytes = CMBlockBufferGetDataLength(block)
                var data = Data(count: bytes)
                let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
                guard copied == noErr else { throw SpyError.message("Не удалось прочитать аудиоданные.") }
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard start.isFinite else { continue }
                let channels = Int(format.mChannelsPerFrame)
                data.withUnsafeBytes { raw in
                    let values = raw.bindMemory(to: Float.self)
                    for i in values.indices {
                        let amplitude = abs(values[i]); guard amplitude.isFinite else { continue }
                        let time = start + Double(i / channels) / format.mSampleRate
                        guard time >= 0, time <= duration else { continue }
                        let bin = min(count - 1, max(0, Int(time / duration * Double(count))))
                        peaks[bin] = max(peaks[bin], min(1, amplitude)); samples += 1
                        if amplitude >= 0.99 { clipped += 1 }
                    }
                }
            }
            guard reader.status == .completed else { throw reader.error ?? SpyError.message("Звуковая дорожка прочитана не полностью.") }
            lanes.append(AudioWaveformLane(id: track.trackID, microphone: microphoneIDs.contains(track.trackID), peaks: peaks, sampleCount: samples, clippedCount: clipped))
        }
        return lanes
    }
    static func load(asset: AVAsset, microphoneIDs: Set<CMPersistentTrackID>) async throws -> [AudioWaveformLane] {
        let task = Task.detached(priority: .utility) { try await analyze(asset: asset, microphoneIDs: microphoneIDs) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

struct WaveformMixerView: View {
    @ObservedObject var controls: VideoAudioControls
    @ObservedObject var editor: PlayerEditingState
    @State private var lanes: [AudioWaveformLane] = []
    @State private var issue: String?
    @State private var loading = false
    @State private var expanded = false
    init(controls: VideoAudioControls, editor: PlayerEditingState, initiallyExpanded: Bool = false) {
        self.controls = controls; self.editor = editor
        _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        if controls.hasAudio {
            DisclosureGroup("Звуковые дорожки и громкость", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if loading { HStack { ProgressView().controlSize(.small); Text("Строю звуковую волну…").font(.caption) } }
                    if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    ForEach(lanes) { lane in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(lane.microphone ? "Микрофон" : controls.hasUnidentifiedAudio ? "Общий звук" : "Система").font(.caption.bold()).frame(width: 90, alignment: .leading)
                                Slider(value: lane.microphone ? $controls.microphoneGain : $controls.systemGain, in: 0...1, step: 0.01)
                                    .accessibilityLabel(lane.microphone ? "Громкость микрофона в плеере" : "Громкость системы в плеере")
                                Text("\(Int((lane.microphone ? controls.microphoneGain : controls.systemGain) * 100))%").monospacedDigit().font(.caption).frame(width: 40)
                                if lane.clipping { Text("Перегрузка в исходнике").font(.caption2).foregroundStyle(.orange) }
                                else if lane.silent { Text("Очень тихо").font(.caption2).foregroundStyle(Theme.muted) }
                            }
                            GeometryReader { geo in
                                Canvas { context, size in
                                    let total = max(0.001, editor.duration)
                                    let selected = CGRect(x: CGFloat(editor.rangeStart / total) * size.width, y: 0,
                                                          width: CGFloat((editor.rangeEnd - editor.rangeStart) / total) * size.width, height: size.height)
                                    context.fill(Path(selected), with: .color(Theme.accent.opacity(0.12)))
                                    let gain = lane.microphone ? controls.microphoneGain : controls.systemGain
                                    let width = size.width / CGFloat(max(1, lane.peaks.count))
                                    var path = Path()
                                    for (i, peak) in lane.peaks.enumerated() {
                                        let height = max(1, CGFloat(sqrt(Double(peak)) * gain) * size.height)
                                        path.addRect(CGRect(x: CGFloat(i) * width, y: (size.height - height) / 2, width: max(0.5, width - 0.5), height: height))
                                    }
                                    context.fill(path, with: .color(lane.microphone ? Theme.green : Theme.accent))
                                    let x = CGFloat(editor.currentTime / total) * size.width
                                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white))
                                }
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                                    editor.seek(max(0, min(editor.duration, Double(event.location.x / max(1, geo.size.width)) * editor.duration)))
                                })
                                .accessibilityLabel(lane.microphone ? "Волна микрофона" : "Волна системного звука")
                            }.frame(height: 30).background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text("Нажмите на волну для перехода. Громкость применяется при просмотре и сохранении копии; исходный файл сохраняется.").font(.caption2).foregroundStyle(Theme.muted)
                }.padding(.top, 6)
            }.font(.system(size: 12)).task(id: expanded) {
                guard expanded, lanes.isEmpty, !loading else { return }
                loading = true; defer { loading = false }
                do {
                    let value = try await AudioWaveform.load(asset: controls.item.asset, microphoneIDs: controls.microphoneIDs)
                    try Task.checkCancellation(); lanes = value; issue = nil
                } catch is CancellationError {} catch { issue = error.localizedDescription }
            }
        }
    }
}
