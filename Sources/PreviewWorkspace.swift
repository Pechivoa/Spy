import SwiftUI
import AVKit

/// The canvas and primary actions remain visible at every supported size.
/// Audio details have their own popover instead of pushing the movie offscreen.
struct PreviewWorkspace<Header: View, Filmstrip: View, Footer: View>: View {
    let player: AVPlayer?
    let title: String
    let fullScreenID: String
    @ObservedObject var editor: PlayerEditingState
    var audioControls: VideoAudioControls?
    var busy: Bool
    var saveMutedCopy: (() -> Void)? = nil
    @ViewBuilder var header: () -> Header
    @ViewBuilder var filmstrip: () -> Filmstrip
    @ViewBuilder var footer: () -> Footer
    @State private var soundOpen = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    header().frame(maxWidth: .infinity, alignment: .leading)
                    Button { editor.openFullScreen() } label: {
                        Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(!editor.canOpenFullScreen).accessibilityIdentifier(fullScreenID)
                }.padding(.horizontal, 16).padding(.vertical, 12)
                Divider().overlay(Theme.border)
                FullSizePlayer(player: player, title: title, editor: editor, showsEntryButton: false, usesNativeControls: false)
                    .frame(minHeight: 160, maxHeight: .infinity).layoutPriority(1)
                    .accessibilityIdentifier("Spy.Preview.Canvas")
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { min(max(0, editor.currentTime), max(0.001, editor.duration)) },
                                              set: { editor.seek($0) }), in: 0...max(0.001, editor.duration))
                            .accessibilityLabel("Позиция видео")
                        Text(frameClock(editor.duration)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.muted).monospacedDigit()
                    }.disabled(editor.duration <= 0)
                    HStack(spacing: 12) {
                        FramePlaybackToolbar(editor: editor)
                        Button { soundOpen.toggle() } label: { Label("Звук", systemImage: "speaker.wave.2") }
                            .buttonStyle(.bordered).controlSize(.small).disabled(audioControls == nil || busy)
                            .popover(isPresented: $soundOpen, arrowEdge: .bottom) {
                                if let audioControls {
                                    VStack(alignment: .leading, spacing: 16) {
                                        VideoMicrophoneView(controls: audioControls, saveCopy: saveMutedCopy)
                                        WaveformMixerView(controls: audioControls, editor: editor, initiallyExpanded: true)
                                    }.padding(20).frame(width: 550).foregroundStyle(.white).background(Theme.panel)
                                        .preferredColorScheme(.dark).tint(Theme.accent)
                                        .disabled(busy)
                                }
                            }
                    }
                    if geometry.size.height >= 740 { filmstrip() }
                    PreviewSelectionControls(editor: editor)
                }.padding(.horizontal, 16).padding(.vertical, 12).disabled(busy)
                Divider().overlay(Theme.border)
                footer().padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .accessibilityIdentifier("Spy.Preview.Footer")
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white).background(Theme.background)
            .preferredColorScheme(.dark).tint(Theme.accent)
    }
}

private struct PreviewSelectionControls: View {
    @ObservedObject var editor: PlayerEditingState
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Label("Фрагмент · " + frameClock(max(0, editor.rangeEnd - editor.rangeStart)), systemImage: "scissors")
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Всё видео") { editor.selectAll() }
                Button("Смотреть фрагмент") { editor.seek(editor.rangeStart, resume: true) }
            }.font(.system(size: 11)).controlSize(.mini)
            boundary("Начало", value: editor.rangeStart, set: editor.setStart, current: editor.setStartAtPlayhead)
            boundary("Конец", value: editor.rangeEnd, set: editor.setEnd, current: editor.setEndAtPlayhead)
        }.buttonStyle(.bordered).disabled(editor.duration <= 0 || editor.isSaving)
    }
    private func boundary(_ title: String, value: Double, set: @escaping (Double) -> Void,
                          current: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 48, alignment: .leading).foregroundStyle(Theme.muted)
            Slider(value: Binding(get: { value }, set: set), in: 0...max(0.001, editor.duration))
                .accessibilityLabel(title + " фрагмента")
            Text(frameClock(value)).monospacedDigit().frame(width: 85)
            Button("Текущий кадр", action: current).controlSize(.mini)
        }.font(.system(size: 11))
    }
}
