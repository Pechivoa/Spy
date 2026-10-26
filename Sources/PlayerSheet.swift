import SwiftUI
import AVKit

struct PlayerSheet: View {
    let clip: Clip
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var audioControls: VideoAudioControls?
    @State private var microphoneEnabled = true
    @State private var boundaryObservation: Any?
    @State private var deleteAlert = false
    @State private var rename = false
    @State private var playbackObservation: NSKeyValueObservation?
    @State private var playbackError: String?
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var result: URL?
    @State private var trimError: String?
    private var current: Clip { model.clips.first(where: { $0.id == clip.id }) ?? clip }
    private var duration: Double { max(0.05, clip.duration) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(current.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text("\(preciseClock(clip.duration)) · \(fileSize(clip.bytes))").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { model.toggleFavorite(current) } label: { Image(systemName: current.favorite ? "star.fill" : "star").foregroundStyle(current.favorite ? Color.orange : Color.white) }.help("Избранное")
                Button { rename = true } label: { Image(systemName: "pencil") }.help("Назвать видео")
                Button { Task { await model.exportMP4(clip, microphoneEnabled: microphoneEnabled) } } label: { Text("MP4") }.help("Экспортировать с выбранным звуком").disabled(model.saving)
                Button { model.reveal(clip) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                Button { deleteAlert = true } label: { Image(systemName: "trash") }.help("Удалить видео").disabled(model.saving || model.cleanupBusy)
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.saving)
            }.buttonStyle(.bordered).padding(20)
            if let playbackError { Text(playbackError).font(.system(size: 12)).foregroundStyle(Theme.accent).padding(.horizontal, 20).padding(.bottom, 14) }
            NativePlayer(player: player, allowsFullScreen: !model.recording).frame(height: 380)
            if model.recording {
                Text("Во время записи просмотр Spy работает в окне: полноэкранный плеер исключён из захвата.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.horizontal, 20).padding(.top, 8)
            }
            if let audioControls {
                VideoMicrophoneView(controls: audioControls, onChange: { microphoneEnabled = $0 }, saveCopy: {
                    player?.pause(); result = nil; trimError = nil
                    Task {
                        do { result = try await model.trimClip(clip, start: 0, end: clip.duration, microphoneEnabled: false) }
                        catch { trimError = error.localizedDescription }
                    }
                }).padding(.horizontal, 20).padding(.top, 10).disabled(model.saving)
            }
            MomentMarkerStrip(markers: model.metadata.get(current.url).markers, onSeek: seek).padding(.horizontal, 20)
            trimControls.padding(20)
        }.frame(width: 900).background(Theme.background).preferredColorScheme(.dark).tint(Theme.accent)
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
                setBoundary(); player?.play()
            }
            .onChange(of: end) { _, _ in setBoundary() }
            .onDisappear {
                if let boundaryObservation { player?.removeTimeObserver(boundaryObservation); self.boundaryObservation = nil }
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
                Text("Фрагмент: \(preciseClock(max(0, end - start)))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 12) {
                Text("Начало").frame(width: 55, alignment: .leading)
                Slider(value: Binding(get: { start }, set: { start = min($0, max(0, end - 0.05)); seek(start) }), in: 0...duration, step: 0.1).accessibilityLabel("Начало фрагмента")
                Text(preciseClock(start)).monospacedDigit().frame(width: 70)
                Button("Из плеера") { start = min(max(0, player?.currentTime().seconds ?? 0), max(0, end - 0.05)) }.controlSize(.small)
            }.font(.system(size: 12))
            HStack(spacing: 12) {
                Text("Конец").frame(width: 55, alignment: .leading)
                Slider(value: Binding(get: { end }, set: { end = max($0, min(duration, start + 0.05)); seek(end) }), in: 0...duration, step: 0.1).accessibilityLabel("Конец фрагмента")
                Text(preciseClock(end)).monospacedDigit().frame(width: 70)
                Button("Из плеера") { end = max(min(duration, player?.currentTime().seconds ?? duration), start + 0.05) }.controlSize(.small)
            }.font(.system(size: 12))
            if let trimError { Text(trimError).font(.system(size: 11)).foregroundStyle(Theme.accent) }
            HStack {
                if let result {
                    Label("Копия добавлена в библиотеку", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 11))
                    Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([result]) }.buttonStyle(.plain).font(.system(size: 11))
                } else { Text("Сохранится отдельный ролик. Исходное видео останется в библиотеке.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                Spacer()
                Button("Просмотреть") { seek(start); player?.play() }.buttonStyle(.bordered).controlSize(.small)
                Button(model.saving ? "Сохраняется…" : "Сохранить фрагмент") {
                    player?.pause(); result = nil; trimError = nil
                    Task {
                        do { result = try await model.trimClip(clip, start: start, end: end, microphoneEnabled: microphoneEnabled) }
                        catch { trimError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(end - start < 0.05 || clip.duration < 0.05)
            }
        }.disabled(model.saving)
    }
    private func setBoundary() {
        if let boundaryObservation { player?.removeTimeObserver(boundaryObservation) }
        boundaryObservation = player?.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))], queue: .main) { [weak player] in player?.pause() }
    }
    private func seek(_ seconds: Double) { player?.pause(); player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
}
