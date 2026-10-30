import SwiftUI
import AVKit

struct PlayerSheet: View {
    let clip: Clip
    @ObservedObject var model: AppModel
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
    private var momentMarkers: [ClipMarker] { model.metadata.get(current.url).markers }
    var body: some View {
        PreviewWorkspace(player: player, title: current.title, fullScreenID: "Spy.SavedVideo.FullScreen",
                         editor: editor, audioControls: audioControls, busy: model.saving,
                         saveMutedCopy: {
            player?.pause(); result = nil; trimError = nil
            Task {
                do { result = try await model.trimClip(clip, start: 0, end: clip.duration, microphoneEnabled: false, levels: audioLevels) }
                catch { trimError = error.localizedDescription }
            }
        }, header: { playerHeader }, filmstrip: {
            MomentMarkerStrip(markers: momentMarkers, onSeek: seek)
        }, footer: { playerFooter })
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
                Button("Удалить", role: .destructive) { player?.pause(); Task { await model.trash(clip); model.selectedClip = nil } }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Вы сможете восстановить его из Корзины macOS.") }
    }
    private var playerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(current.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(frameClock(clip.duration)) · \(fileSize(clip.bytes))").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            Button { model.toggleFavorite(current) } label: { Image(systemName: current.favorite ? "star.fill" : "star") }
                .foregroundStyle(current.favorite ? Color.orange : Color.white).help("Избранное")
            Menu {
                Button("Назвать видео") { rename = true }
                Button("Экспортировать MP4") { Task { await model.exportMP4(clip, microphoneEnabled: microphoneEnabled, levels: audioLevels) } }
                Button("Показать в Finder") { model.reveal(clip) }
                Button("Удалить видео", role: .destructive) { deleteAlert = true }.disabled(model.cleanupBusy)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.saving)
        }.buttonStyle(.bordered).controlSize(.small)
    }
    private var playerFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let playbackError { Text(playbackError).font(.system(size: 11)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if let trimError { Text(trimError).font(.system(size: 11)).foregroundStyle(Theme.accent) }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                if let result {
                    Label("Копия добавлена в библиотеку", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 11))
                    Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([result]) }.buttonStyle(.plain).font(.system(size: 11))
                } else { Text("Сохранится отдельный ролик. Исходное видео останется в библиотеке.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }.lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                Button("Закрыть") { model.selectedClip = nil }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button(model.saving ? "Сохраняется…" : "Сохранить фрагмент") {
                    player?.pause(); result = nil; trimError = nil
                    Task {
                        do { result = try await model.trimClip(clip, start: start, end: end, microphoneEnabled: microphoneEnabled, levels: audioLevels) }
                        catch { trimError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(!editor.canSave || player == nil)
                    .accessibilityIdentifier("Spy.SavedVideo.Save")
            }
        }.disabled(model.saving)
    }
    private func seek(_ seconds: Double) { editor.seek(seconds) }
}
