import SwiftUI

struct SoundpadMenu: View {
    let model: AppModel
    @ObservedObject var soundpad: SoundpadController
    var body: some View {
        Button("Soundpad — звук в микрофон…") { model.showSoundpad() }
        if soundpad.running || soundpad.busy {
            Button("Выключить передачу звука · " + model.shortcuts.broadcast.label) { Task { await soundpad.stop() } }
        }
    }
}

struct SoundpadView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var soundpad: SoundpadController
    @State private var editing: ShortcutAction?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let issue = soundpad.issue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.danger)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if soundpad.targets.isEmpty { setup }
                routing
                pads
                Text("Передача запускается вручную. При закрытии этого окна она продолжается; при выходе из Spy, блокировке экрана, сне или сбое устройства — выключается.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(26)
        }.background(Theme.background).foregroundStyle(.white).tint(Theme.accent)
            .sheet(item: $editing) { action in ShortcutCaptureSheet(action: action, model: model) }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SpyMark().fill(Theme.accent).frame(width: 30, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text("Soundpad").font(.system(size: 25, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(soundpad.running ? Theme.green : Theme.muted).frame(width: 6, height: 6)
                    Text(soundpad.status).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Button { Task { await soundpad.toggle() } } label: {
                Label(soundpad.running || soundpad.busy ? "Выключить передачу" : "Включить передачу", systemImage: soundpad.running ? "stop.fill" : "mic.badge.plus")
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9)
                    .foregroundStyle(soundpad.running ? Color.white : Theme.accentInk)
                    .background(soundpad.running ? Theme.danger.opacity(0.8) : Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(soundpad.targets.isEmpty && !soundpad.running && !soundpad.busy)
                .accessibilityIdentifier("Spy.Soundpad.Toggle")
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Нужен виртуальный микрофон BlackHole", systemImage: "cable.connector").font(.system(size: 14, weight: .semibold))
            Text("Установите бесплатный BlackHole 2ch. После установки выберите его в Discord → Голос и видео → Устройство ввода. Вывод macOS оставьте в наушниках.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Установить BlackHole…") { soundpad.openDriverSetup() }
                Button("Обновить устройства") { soundpad.refreshDevices(); model.refreshMicrophones() }
            }.buttonStyle(.bordered)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private var routing: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Источники и громкость").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { soundpad.refreshDevices(); model.refreshMicrophones(); soundpad.applications.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Обновить устройства и приложения")
            }
            HStack {
                Text("Вход для Discord").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Picker("Виртуальный вход", selection: $soundpad.targetUID) {
                    if soundpad.targets.isEmpty || soundpad.target == nil { Text("Не подключён").tag(soundpad.targetUID) }
                    ForEach(soundpad.targets) { Text($0.name).tag($0.uid) }
                }.labelsHidden().frame(width: 225).disabled(soundpad.running || soundpad.busy)
            }
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("У меня").font(.system(size: 12, weight: .medium)).frame(width: 56, alignment: .leading)
                    Slider(value: Binding(get: { soundpad.localVolume }, set: { soundpad.setLocalVolume($0) }), in: 0...1)
                        .disabled(!soundpad.localVolumeAvailable).accessibilityLabel("Громкость у меня в наушниках")
                    Text(soundpad.localVolumeAvailable ? "\(Int(soundpad.localVolume * 100))%" : "—").font(.system(size: 10, design: .monospaced)).frame(width: 35)
                }
                Text(soundpad.localVolumeAvailable ? "\(soundpad.localOutputName). Меняет звук только у вас. Громкость в Discord задаётся ниже." : "\(soundpad.localOutputName) не поддерживает регулировку macOS. Используйте регулятор устройства; передача в Discord от него не зависит.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Theme.border)
            HStack {
                Toggle("Звук приложений", isOn: $soundpad.systemEnabled).toggleStyle(.switch).font(.system(size: 12))
                    .disabled(soundpad.running || soundpad.busy)
                Spacer()
                SoundpadAppPicker(selection: soundpad.applications, disabled: soundpad.running || soundpad.busy || !soundpad.systemEnabled)
            }
            volume("В Discord", value: $soundpad.systemVolume, peak: soundpad.meters.system)
            HStack {
                Toggle("Мой голос", isOn: $soundpad.microphoneEnabled).toggleStyle(.switch).font(.system(size: 12)).disabled(soundpad.running || soundpad.busy)
                Spacer()
                Picker("Микрофон для передачи", selection: $soundpad.microphoneID) {
                    ForEach(model.microphones.filter { !$0.id.lowercased().contains("blackhole") }) { Text($0.name).tag($0.id) }
                    if !model.microphones.contains(where: { $0.id == soundpad.microphoneID }) { Text("Микрофон отключён").tag(soundpad.microphoneID) }
                }.labelsHidden().frame(width: 260).disabled(soundpad.running || soundpad.busy || !soundpad.microphoneEnabled)
            }
            volume("Голос", value: $soundpad.microphoneVolume, peak: soundpad.meters.microphone)
            volume("Кнопки", value: $soundpad.padVolume, peak: nil)
            HStack(spacing: 10) {
                Text("В эфире").font(.system(size: 11, weight: .medium)).frame(width: 56, alignment: .leading)
                ProgressView(value: Double(soundpad.meters.output)).tint(soundpad.meters.output > 0.95 ? Theme.danger : Theme.accent)
                Text("\(Int(soundpad.meters.output * 100))%").font(.system(size: 10, design: .monospaced)).frame(width: 35)
            }
            Text("Discord исключён из передаваемого звука. Для музыки в Discord отключите шумоподавление и автоматическую регулировку усиления, если они обрезают звук. Голос в наушники повторно не выводится.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Включить / выключить").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                keyButton(.broadcast)
            }
        }.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func volume(_ title: String, value: Binding<Double>, peak: Float?) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 56, alignment: .leading)
            Slider(value: value, in: 0...1).accessibilityLabel("Громкость: " + title)
            Text("\(Int(value.wrappedValue * 100))%").font(.system(size: 10, design: .monospaced)).frame(width: 35)
            if let peak { Capsule().fill(peak > 0.02 ? Theme.green : Theme.border).frame(width: 5, height: 14).accessibilityLabel(title + ": уровень \(Int(peak * 100))%") }
        }
    }
    private var pads: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Звуки").font(.system(size: 15, weight: .semibold))
                Text("\(soundpad.clips.count)/8").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Остановить звуки") { soundpad.stopClips() }.buttonStyle(.bordered).disabled(!soundpad.running)
                Button(soundpad.importing ? "Добавление…" : "Добавить звук…") { soundpad.chooseFiles() }.buttonStyle(.bordered)
                    .disabled(soundpad.importing || soundpad.clips.count >= 8)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<8) { slot in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if soundpad.clips.indices.contains(slot) { Task { await soundpad.play(slot: slot) } } else { soundpad.chooseFiles() }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: soundpad.clips.indices.contains(slot) ? "waveform" : "plus").font(.system(size: 20)).foregroundStyle(Theme.accent)
                                Text(soundpad.clips.indices.contains(slot) ? soundpad.clips[slot].title : "Звук \(slot + 1)").font(.system(size: 12, weight: .medium)).lineLimit(2).frame(height: 32, alignment: .top)
                                Text(soundpad.clips.indices.contains(slot) ? String(format: "%.1f с", soundpad.clips[slot].duration) : "Добавить файл").font(.system(size: 10)).foregroundStyle(Theme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(soundpad.importing)
                            .accessibilityLabel("Soundpad \(slot + 1): " + (soundpad.clips.indices.contains(slot) ? soundpad.clips[slot].title : "добавить звук"))
                        HStack(spacing: 2) {
                            keyButton(ShortcutAction.pads[slot])
                            Spacer(minLength: 0)
                            if soundpad.clips.indices.contains(slot) {
                                Button { soundpad.remove(soundpad.clips[slot]) } label: { Image(systemName: "trash").foregroundStyle(Theme.muted) }.buttonStyle(.plain).help("Удалить кнопку звука")
                            }
                        }
                    }.padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                }
            }
            Toggle("Слышать кнопки Soundpad в моих наушниках", isOn: $soundpad.monitorPads).toggleStyle(.switch).font(.system(size: 11)).disabled(soundpad.running || soundpad.busy)
            Text("Повторное нажатие начинает звук сначала. До четырёх звуков одновременно. Ползунок «Голос» в ноль выключает ваш микрофон в передаче.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func keyButton(_ action: ShortcutAction) -> some View {
        Button { model.beginShortcutEdit(action, external: true); editing = action } label: {
            Text(model.shortcuts[action].label).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.accent)
        }.buttonStyle(.plain).help("Назначить: " + action.title)
    }
}

private struct SoundpadAppPicker: View {
    @ObservedObject var selection: ApplicationAudioSelection
    let disabled: Bool
    var body: some View {
        HStack {
            Picker("Передаваемый звук", selection: $selection.mode) {
                ForEach(ApplicationAudioMode.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 175)
            if selection.mode == .selected {
                Menu {
                    let choices = selection.runningApplications + selection.selectedApplications.filter { app in !selection.runningApplications.contains { $0.bundleID == app.bundleID } }
                    ForEach(choices.filter { !AudioRoutingPolicy.isCallApp($0.bundleID) }) { app in
                        Toggle(app.name, isOn: Binding(get: { selection.bundleIDs.contains(app.bundleID) }, set: { selection.setSelected(app, $0) }))
                    }
                } label: { Text(selection.selectedApplications.isEmpty ? "Выбрать…" : "Выбрано: \(selection.selectedApplications.count)") }
                .menuStyle(.borderlessButton).frame(width: 115)
            }
        }.disabled(disabled)
    }
}
