import SwiftUI
import AVKit

struct PreviewWorkspace<Header: View, Footer: View>: View {
    let player: AVPlayer?
    let title: String
    let fullScreenID: String
    let sourceID: String
    @ObservedObject var editor: PlayerEditingState
    @ObservedObject var queue: ExportQueueController
    var audioControls: VideoAudioControls?
    var busy: Bool
    var saveMutedCopy: (() -> Void)? = nil
    @ViewBuilder var header: () -> Header
    @ViewBuilder var footer: () -> Footer
    @State private var soundOpen = false
    @State private var editingOpen = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    header().frame(maxWidth: .infinity, alignment: .leading)
                    Button { editor.openFullScreen() } label: { Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.bordered).controlSize(.small).disabled(!editor.canOpenFullScreen).accessibilityIdentifier(fullScreenID)
                }.padding(.horizontal, 20).padding(.vertical, 14).background(Theme.sidebar)
                Divider().overlay(Theme.border)
                FullSizePlayer(player: player, title: title, editor: editor, showsEntryButton: false, usesNativeControls: false)
                    .frame(minHeight: 160, maxHeight: .infinity).layoutPriority(1).accessibilityIdentifier("Spy.Preview.Canvas")
                VStack(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            FramePlaybackToolbar(editor: editor, compact: true).disabled(busy)
                            workspaceTools
                        }
                        VStack(spacing: 8) {
                            FramePlaybackToolbar(editor: editor, compact: true).disabled(busy)
                            HStack { Spacer(); workspaceTools }
                        }
                    }
                    EditingTimeline(editor: editor, sourceID: sourceID).id(sourceID).disabled(busy)
                    HStack {
                        if audioControls?.canMuteMicrophone == true {
                            Toggle("Микрофон в видео", isOn: Binding(get: { editor.microphoneEnabled }, set: editor.setMicrophoneEnabled))
                                .toggleStyle(.switch).controlSize(.mini).fixedSize().disabled(busy)
                        }
                        Spacer()
                        Text("I / O — границы · ← / → — кадр").foregroundStyle(Theme.muted)
                    }.font(.system(size: 10))
                }.padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 10).background(Theme.panel)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                footer().padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel).accessibilityIdentifier("Spy.Preview.Footer")
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white).background(Theme.background)
            .preferredColorScheme(.dark).tint(Theme.accent)
    }
    private var workspaceTools: some View {
        HStack(spacing: 6) {
            Button { soundOpen.toggle() } label: { Label("Звук", systemImage: "speaker.wave.2") }
                .disabled(audioControls == nil || busy).popover(isPresented: $soundOpen, arrowEdge: .bottom) { soundPanel }
            Button { editingOpen.toggle() } label: { Label("Монтаж", systemImage: "slider.horizontal.3") }
                .disabled(editor.duration <= 0 || busy).popover(isPresented: $editingOpen, arrowEdge: .bottom) {
                    PreciseEditingPanel(editor: editor).disabled(busy)
                }
            ExportQueueButton(queue: queue)
        }.font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
    }
    @ViewBuilder private var soundPanel: some View {
        if let audioControls {
            VStack(alignment: .leading, spacing: 16) {
                VideoMicrophoneView(controls: audioControls, saveCopy: saveMutedCopy)
                WaveformMixerView(controls: audioControls, editor: editor, initiallyExpanded: true)
            }.padding(20).frame(width: 550).foregroundStyle(.white).background(Theme.panel)
                .preferredColorScheme(.dark).tint(Theme.accent).disabled(busy)
        }
    }
}
