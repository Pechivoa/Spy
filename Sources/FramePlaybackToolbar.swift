import SwiftUI

struct FramePlaybackToolbar: View {
    @ObservedObject var editor: PlayerEditingState
    var compact = false
    var body: some View {
        HStack(spacing: 9) {
            Button { editor.stepFrames(-1) } label: { Image(systemName: "backward.end") }
                .accessibilityLabel("Назад на один кадр").help("Назад на один кадр")
            Button { editor.togglePlayback() } label: { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill") }
                .accessibilityLabel(editor.isPlaying ? "Пауза просмотра" : "Воспроизвести")
                .keyboardShortcut(.space, modifiers: [])
            Button { editor.stepFrames(1) } label: { Image(systemName: "forward.end") }
                .accessibilityLabel("Вперёд на один кадр").help("Вперёд на один кадр")
            Text(frameClock(editor.currentTime)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            PlaybackSpeedPicker(editor: editor)
            Spacer()
            Button { editor.setLooping(!editor.isLooping) } label: {
                if compact { Image(systemName: "repeat").foregroundStyle(editor.isLooping ? Theme.accent : Theme.muted) }
                else { Label("Цикл A–B", systemImage: "repeat").foregroundStyle(editor.isLooping ? Theme.accent : Theme.muted) }
            }.help("Повторять выбранный фрагмент").accessibilityLabel("Цикл A–B")
            Button { editor.addMarker() } label: {
                if compact { Image(systemName: "bookmark") } else { Label("Метка", systemImage: "bookmark") }
            }.disabled(!editor.canAddMarker).help("Добавить метку").accessibilityLabel("Добавить метку")
        }.buttonStyle(.bordered).controlSize(.small)
            .disabled(editor.duration <= 0 || editor.isSaving)
    }
}

struct PlaybackSpeedPicker: View {
    @ObservedObject var editor: PlayerEditingState
    var body: some View {
        Picker("Скорость воспроизведения", selection: Binding(get: { editor.playbackRate }, set: editor.setPlaybackRate)) {
            ForEach(PlayerEditingState.supportedRates, id: \.self) { rate in
                Text(String(format: "%g×", rate).replacingOccurrences(of: ".", with: ",")).tag(rate)
            }
        }.labelsHidden().pickerStyle(.menu).frame(width: 63).controlSize(.small).disabled(editor.duration <= 0)
    }
}
