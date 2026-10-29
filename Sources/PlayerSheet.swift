import SwiftUI
import AVKit

struct PlayerSheet: View {
    let clip: Clip
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @StateObject private var editor = PlayerEditingState()
    @State private var audioControls: VideoAudioControls?
    @State private var microphoneEnabled = true
    @State private var deleteAlert = false
    @State private var rename = false
    @State private var playbackObservation: NSKeyValueObservation?
    @State private var playbackError: String?
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var result: URL?
    @State private var trimError: String?
    private var current: Clip { model.clips.first(where: { $0.id == clip.id }) ?? clip }
    private var audioLevels: AudioLevels { audioControls?.gains ?? AudioLevels() }
    private var duration: Double { max(0.001, clip.duration) }
    private var frameStep: Double { max(1.0 / 60_000, editor.frameDuration) }
    private var momentMarkers: [ClipMarker] { model.metadata.get(current.url).markers }
    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(current.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text("\(frameClock(clip.duration)) · \(fileSize(clip.bytes))").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { model.toggleFavorite(current) } label: { Image(systemName: current.favorite ? "star.fill" : "star").foregroundStyle(current.favorite ? Color.orange : Color.white) }.help("Избранное")
                Button { rename = true } label: { Image(systemName: "pencil") }.help("Назвать видео")
                Button { Task { await model.exportMP4(clip, microphoneEnabled: microphoneEnabled, levels: audioLevels) } } label: { Text("MP4") }.help("Экспортировать с выбранным звуком").disabled(model.saving)
                Button { model.reveal(clip) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                Button { deleteAlert = true } label: { Image(systemName: "trash") }.help("Удалить видео").disabled(model.saving || model.cleanupBusy)
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.saving)
            }.buttonStyle(.bordered).padding(20)
            if let playbackError { Text(playbackError).font(.system(size: 12)).foregroundStyle(Theme.accent).padding(.horizontal, 20).padding(.bottom, 14) }
            HStack {
                Label("Просмотр видео", systemImage: "play.rectangle").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { editor.openFullScreen() } label: { Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderedProminent).disabled(!editor.canOpenFullScreen)
                    .accessibilityIdentifier("Spy.SavedVideo.FullScreen")
            }.padding(.horizontal, 20).padding(.bottom, 10)
            FullSizePlayer(player: player, title: current.title, editor: editor).frame(height: 380)
            FramePlaybackToolbar(editor: editor).padding(.horizontal, 20).padding(.top, 8)
            if let audioControls {
                WaveformMixerView(controls: audioControls, editor: editor).padding(.horizontal, 20).disabled(model.saving)
                VideoMicrophoneView(controls: audioControls, onChange: { microphoneEnabled = $0 }, saveCopy: {
                    player?.pause(); result = nil; trimError = nil
                    Task {
                        do { result = try await model.trimClip(clip, start: 0, end: clip.duration, microphoneEnabled: false, levels: audioLevels) }
                        catch { trimError = error.localizedDescription }
                    }
                }).padding(.horizontal, 20).padding(.top, 10).disabled(model.saving)
            }
            MomentMarkerStrip(markers: momentMarkers, onSeek: seek).padding(.horizontal, 20)
            trimControls.padding(20)
        }
        }.frame(width: 900).frame(maxHeight: min(1100, (NSScreen.main?.visibleFrame.height ?? 1000) - 80)).background(Theme.background).preferredColorScheme(.dark).tint(Theme.accent)
            .task(id: clip.url) {
                end = clip.duration
                let item: AVPlayerItem
                do {
                    let sound = try await VideoAudioControls.load(url: clip.url)
                    try Task.checkCancellation(); audioControls = sound; item = sound.item
                }
                catch { if !Task.isCancelled { playbackError = error.localizedDescription; model.journal.record(.error, "Подготовка плеера", describeError(error)) }; return }
                player = AVPlayer(playerItem: item)
                if model.previewMode { player?.isMuted = true }
                playbackObservation = item.observe(\.status, options: [.new]) { item, _ in
                    guard item.status == .failed, let error = item.error else { return }
                    Task { @MainActor in
                        playbackError = "Не удалось воспроизвести видео. Подробности — в журнале ошибок."
                        model.journal.record(.error, "Воспроизведение видео", clip.url.lastPathComponent + "\n" + describeError(error))
                    }
                }
                editor.configure(player: player, duration: clip.duration, audioControls: audioControls,
                    rangeStart: start, rangeEnd: end, markers: momentMarkers,
                    onRangeChanged: { first, last in start = first; end = last; trimError = nil },
                    onMicrophoneChanged: { microphoneEnabled = $0 },
                    onAddMarker: { time in
                        model.addPlaybackMarker(current, at: time)
                        editor.setMarkers(model.metadata.get(current.url).markers)
                    },
                    onSave: { first, last, microphone in
                        let url = try await model.trimClip(clip, start: first, end: last, microphoneEnabled: microphone, levels: audioLevels)
                        result = url
                        return "Сохранено · " + url.lastPathComponent
                    })
                player?.play()
            }
            .onChange(of: start) { _, _ in editor.setRange(start: start, end: end) }
            .onChange(of: end) { _, _ in editor.setRange(start: start, end: end) }
            .onChange(of: momentMarkers) { _, value in editor.setMarkers(value) }
            .onDisappear {
                editor.detach()
                playbackObservation?.invalidate(); playbackObservation = nil; player?.pause(); player = nil; audioControls = nil }
            .sheet(isPresented: $rename) { RenameClipSheet(clip: current, model: model) }
            .alert("Переместить видео в Корзину?", isPresented: $deleteAlert) {
                Button("Удалить", role: .destructive) { player?.pause(); Task { await model.trash(clip); dismiss() } }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Вы сможете восстановить его из Корзины macOS.") }
    }
    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Обрезать момент", systemImage: "scissors").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Фрагмент: \(frameClock(max(0, end - start)))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 12) {
                Text("Начало").frame(width: 55, alignment: .leading)
                Slider(value: Binding(get: { start }, set: { editor.setStart($0) }), in: 0...duration, step: frameStep).accessibilityLabel("Начало фрагмента")
                Text(frameClock(start)).monospacedDigit().frame(width: 90)
                Button("Из плеера") { editor.setStartAtPlayhead() }.controlSize(.small)
            }.font(.system(size: 12))
            HStack(spacing: 12) {
                Text("Конец").frame(width: 55, alignment: .leading)
                Slider(value: Binding(get: { end }, set: { editor.setEnd($0) }), in: 0...duration, step: frameStep).accessibilityLabel("Конец фрагмента")
                Text(frameClock(end)).monospacedDigit().frame(width: 90)
                Button("Из плеера") { editor.setEndAtPlayhead() }.controlSize(.small)
            }.font(.system(size: 12))
            if let trimError { Text(trimError).font(.system(size: 11)).foregroundStyle(Theme.accent) }
            HStack {
                if let result {
                    Label("Копия добавлена в библиотеку", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 11))
                    Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([result]) }.buttonStyle(.plain).font(.system(size: 11))
                } else { Text("Сохранится отдельный ролик. Исходное видео останется в библиотеке.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                Spacer()
                Button("Просмотреть") { editor.seek(start, resume: true) }.buttonStyle(.bordered).controlSize(.small)
                Button(model.saving ? "Сохраняется…" : "Сохранить фрагмент") {
                    player?.pause(); result = nil; trimError = nil
                    Task {
                        do { result = try await model.trimClip(clip, start: start, end: end, microphoneEnabled: microphoneEnabled, levels: audioLevels) }
                        catch { trimError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!editor.canSave || player == nil)
            }
        }.disabled(model.saving)
    }
    private func seek(_ seconds: Double) { editor.seek(seconds) }
}
