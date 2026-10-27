import SwiftUI

struct FramePlaybackToolbar: View {
    @ObservedObject var editor: PlayerEditingState
    var body: some View {
        HStack(spacing: 9) {
            Button { editor.stepFrames(-1) } label: { Image(systemName: "backward.end") }
                .accessibilityLabel("Назад на один кадр").help("Назад на один кадр")
            Button { editor.togglePlayback() } label: { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill") }
                .accessibilityLabel(editor.isPlaying ? "Пауза просмотра" : "Воспроизвести")
            Button { editor.stepFrames(1) } label: { Image(systemName: "forward.end") }
                .accessibilityLabel("Вперёд на один кадр").help("Вперёд на один кадр")
            Text(frameClock(editor.currentTime)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            Spacer()
            Button { editor.setLooping(!editor.isLooping) } label: {
                Label("Цикл A–B", systemImage: "repeat")
                    .foregroundStyle(editor.isLooping ? Theme.accent : Theme.muted)
            }.help("Повторять выбранный фрагмент")
            Button { editor.addMarker() } label: { Label("Метка", systemImage: "bookmark") }
                .disabled(!editor.canAddMarker)
        }.buttonStyle(.bordered).controlSize(.small)
            .disabled(editor.duration <= 0 || editor.isSaving)
    }
}
