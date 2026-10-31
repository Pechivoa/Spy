import SwiftUI

/// Fits in the mini-widget's existing footer; the 280×150 window never grows.
struct SoundpadWidgetControls: View {
    let model: AppModel
    @ObservedObject var soundpad: SoundpadController
    @State private var showing = false
    var body: some View {
        HStack(spacing: 3) {
            Button {
                if soundpad.targets.isEmpty { showing = true }
                else { Task { await soundpad.toggle(); if soundpad.issue != nil { showing = true } } }
            } label: {
                Image(systemName: soundpad.running ? "mic.fill" : "mic")
                    .foregroundStyle(soundpad.running ? Theme.green : Theme.muted).frame(width: 20, height: 20)
            }.buttonStyle(.plain).disabled(soundpad.busy)
                .accessibilityLabel(soundpad.running ? "Выключить передачу Soundpad" : "Включить передачу Soundpad")
                .help((soundpad.running ? "Передача включена" : "Передача выключена") + " · " + model.shortcuts.broadcast.label)
            Button { showing.toggle() } label: {
                Image(systemName: "waveform").foregroundStyle(showing ? Theme.accent : Theme.muted).frame(width: 20, height: 20)
            }.buttonStyle(.plain).accessibilityLabel("Звуки и громкость Soundpad")
                .help("Громкость у себя, передача в Discord и 8 звуков")
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    SoundpadQuickPanel(model: model, soundpad: soundpad, openFull: { showing = false; model.showSoundpad() })
                        .preferredColorScheme(.dark)
                }
        }
    }
}

private struct SoundpadQuickPanel: View {
    let model: AppModel
    @ObservedObject var soundpad: SoundpadController
    let openFull: () -> Void
    @State private var previousVoiceGain = 1.0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Soundpad").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button(action: openFull) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.plain).help("Открыть полный Soundpad").accessibilityLabel("Полное окно Soundpad")
                }
                HStack(spacing: 7) {
                    Circle().fill(soundpad.running ? Theme.green : Theme.muted).frame(width: 6, height: 6)
                    Text(soundpad.status).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Button { Task { await soundpad.toggle() } } label: {
                    Label(soundpad.running || soundpad.busy ? "Выключить передачу" : "Включить передачу", systemImage: soundpad.running ? "stop.fill" : "mic")
                        .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(Theme.accentInk).background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(soundpad.targets.isEmpty && !soundpad.running && !soundpad.busy)
                if let issue = soundpad.issue {
                    Text(issue).font(.system(size: 10)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                if soundpad.targets.isEmpty {
                    Text("Сначала установите BlackHole и выберите источники в полном окне.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Button("Настроить Soundpad…", action: openFull).buttonStyle(.bordered)
                } else {
                    Divider().overlay(Theme.border)
                    volume("У меня", value: Binding(get: { soundpad.localVolume }, set: { soundpad.setLocalVolume($0) }), enabled: soundpad.localVolumeAvailable)
                    volume("В Discord", value: $soundpad.systemVolume, enabled: true)
                    HStack {
                        Toggle("Голос", isOn: Binding(get: { soundpad.microphoneEnabled && soundpad.microphoneVolume > 0 }, set: { enabled in
                            if enabled { soundpad.microphoneVolume = previousVoiceGain > 0 ? previousVoiceGain : 1 }
                            else { previousVoiceGain = soundpad.microphoneVolume; soundpad.microphoneVolume = 0 }
                        })).toggleStyle(.switch).controlSize(.mini).disabled(!soundpad.microphoneEnabled)
                            .help("Выключить / вернуть голос в передаваемом звуке")
                        Spacer()
                        Button("Стоп звуки") { soundpad.stopClips() }.buttonStyle(.bordered).controlSize(.mini)
                    }.font(.system(size: 10))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(0..<8) { slot in
                            Button {
                                if soundpad.clips.indices.contains(slot) { Task { await soundpad.play(slot: slot) } }
                                else { openFull() }
                            } label: {
                                HStack(spacing: 7) {
                                    Text("\(slot + 1)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.accent)
                                    Text(soundpad.clips.indices.contains(slot) ? soundpad.clips[slot].title : "Добавить…").font(.system(size: 10)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 9).frame(height: 31).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Быстрый Soundpad \(slot + 1): " + (soundpad.clips.indices.contains(slot) ? soundpad.clips[slot].title : "добавить звук"))
                                .help(model.shortcuts[ShortcutAction.pads[slot]].label)
                        }
                    }
                    HStack {
                        ProgressView(value: Double(soundpad.meters.output)).tint(Theme.accent)
                        Text("\(Int(soundpad.meters.output * 100))%").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 28)
                    }
                    Button("Устройства и звуки…", action: openFull).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
                }
            }.padding(16)
        }.frame(width: 300, height: soundpad.targets.isEmpty ? 220 : 430)
            .background(Theme.background).foregroundStyle(.white).tint(Theme.accent)
            .onAppear { soundpad.refreshDevices() }
    }
    private func volume(_ title: String, value: Binding<Double>, enabled: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 54, alignment: .leading)
            Slider(value: value, in: 0...1).disabled(!enabled).accessibilityLabel("Быстрая громкость: " + title)
            Text(enabled ? "\(Int(value.wrappedValue * 100))%" : "—").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 27)
        }
    }
}
