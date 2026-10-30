import SwiftUI
import AppKit

struct CaptureTargetView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Область записи", selection: $model.captureMode) {
                ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(model.recording || model.diagnosticsBusy || model.busy)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    caption(model.captureMode == .display ? "ЭКРАН" : "ОКНО")
                    if model.captureMode == .display {
                        Picker("Экран", selection: Binding(get: { model.selectedDisplay?.id ?? CGDirectDisplayID.max }, set: { model.displayID = $0 })) {
                            ForEach(model.displays) { Text($0.name).tag($0.id) }
                            if model.selectedDisplay == nil { Text("Выбранный экран отключён").tag(CGDirectDisplayID.max) }
                        }.labelsHidden()
                    } else {
                        HStack {
                            Picker("Окно", selection: $model.windowID) {
                                Text("Выберите окно").tag(CGWindowID(0))
                                ForEach(model.windows) { Text($0.title).tag($0.id) }
                            }.labelsHidden()
                            Button { Task { await model.refreshWindows() } } label: {
                                if model.windowsLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                            }.help("Обновить список окон").disabled(model.windowsLoading)
                        }
                    }
                }.frame(maxWidth: .infinity).disabled(model.recording || model.diagnosticsBusy || model.busy)
                VStack(alignment: .leading, spacing: 7) {
                    caption("КАЧЕСТВО")
                    Picker("Качество", selection: $model.quality) { ForEach(Quality.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }.frame(width: 240).disabled(model.recording || model.diagnosticsBusy || model.busy)
            }
            if model.captureMode == .window && model.windows.isEmpty {
                Text("Откройте нужное окно и обновите список. macOS может запросить доступ к записи экрана.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }.onChange(of: model.captureMode) { _, value in
            if value == .window { Task { await model.refreshWindows(requestPermission: false) } }
        }.task { if model.captureMode == .window { await model.refreshWindows(requestPermission: false) } }
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted) }
}

struct AudioControlsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicrophonePickerView(model: model)
            HStack(spacing: 20) {
                level("Система", enabled: model.systemAudio, value: $model.systemVolume, meter: model.audioMeter.system)
                level("Микрофон", enabled: model.microphone, value: $model.microphoneVolume, meter: model.audioMeter.microphone)
            }
            Text("Громкость применяется при сохранении повтора. Индикаторы показывают уровень во время записи.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }
    private func level(_ title: String, enabled: Bool, value: Binding<Double>, meter: Float) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit() }.font(.system(size: 11)).foregroundStyle(enabled ? .white : Theme.muted)
            HStack(spacing: 10) {
                Slider(value: value, in: 0...1, step: 0.01).disabled(!enabled || model.saving).accessibilityLabel("Громкость: " + title)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(Theme.green).frame(width: geo.size.width * (enabled ? AudioMeter.normalized(meter * Float(value.wrappedValue)) : 0))
                    }
                }.frame(width: 60, height: 5).accessibilityLabel("Уровень: " + title)
            }
        }.frame(maxWidth: .infinity)
    }
}

struct QuickSaveView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("БЫСТРЫЙ ПОВТОР").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
                Spacer()
                ForEach(ShortcutAction.quick) { action in
                    Button { Task { await model.saveSpy(seconds: action.seconds) } } label: {
                        HStack(spacing: 7) {
                            Text(action.shortTitle).font(.system(size: 12, weight: .medium))
                            Text(model.shortcuts[action].label).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }.padding(.horizontal, 10).padding(.vertical, 9).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(!model.canSave).help(action.title)
                }
            }
            HStack {
                Text("Если в буфере меньше времени, сохранится весь накопленный момент.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                Button { model.addMomentMarker() } label: {
                    Label("Метка · " + model.shortcuts.marker.label, systemImage: "bookmark")
                }.buttonStyle(.bordered).controlSize(.small).disabled(!model.canAddMomentMarker)
            }
        }
    }
}

struct LibrarySettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Хранение", systemImage: "internaldrive").font(.system(size: 19, weight: .semibold))
            HStack {
                Text("\(fileSize(model.totalLibraryBytes)) в библиотеке").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Лимит: \(Int(model.libraryLimitGB)) ГБ").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            ProgressView(value: min(1, Double(model.totalLibraryBytes) / Double(model.cleanupPolicy.maximumBytes))).tint(Theme.accent)
            Toggle("Автоматически очищать библиотеку", isOn: $model.autoCleanup).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Максимальный размер").font(.system(size: 12))
                    Slider(value: $model.libraryLimitGB, in: 1...500, step: 1).accessibilityLabel("Лимит библиотеки в гигабайтах")
                    TextField("ГБ", value: $model.libraryLimitGB, format: .number.precision(.fractionLength(0))).frame(width: 55).textFieldStyle(.roundedBorder)
                        .onSubmit { model.libraryLimitGB = min(500, max(1, model.libraryLimitGB)) }
                    Text("ГБ").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                HStack {
                    Text("Удалять видео старше").font(.system(size: 12))
                    Picker("Возраст видео", selection: $model.maximumAgeDays) {
                        Text("Без ограничения").tag(0)
                        ForEach([1, 7, 14, 30, 90, 180, 365], id: \.self) { Text("\($0) дней").tag($0) }
                    }.labelsHidden().frame(width: 200)
                    Spacer()
                    Button(model.cleanupBusy ? "Очистка…" : "Очистить по правилам") { Task { await model.cleanupLibrary(manual: true) } }.buttonStyle(.bordered).disabled(model.cleanupBusy || model.saving)
                }
            }.disabled(!model.autoCleanup || model.cleanupBusy)
            Text("Самые старые видео перемещаются в Корзину до достижения лимита. Избранное, открытый ролик и файлы других приложений защищены. Автоочистка проверяет правила раз в минуту и после сохранения.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            if model.metadata.loadError != nil { Text("Автоочистка приостановлена: не удалось прочитать данные избранного. Подробности — в журнале ошибок.").font(.system(size: 12)).foregroundStyle(Theme.accent) }
            HStack {
                Text(model.libraryURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                Spacer()
                Button("Изменить…") { Task { await model.chooseLibrary() } }.buttonStyle(.bordered).controlSize(.small).disabled(model.recording || model.saving || model.cleanupBusy)
                Button("Открыть папку") { model.openFolder() }.buttonStyle(.bordered).controlSize(.small)
            }
            if !model.libraryAvailable { Text("Папка недоступна. Подключите диск или выберите другую папку.").font(.system(size: 12)).foregroundStyle(Theme.accent) }
            Text("При смене папки существующие ролики остаются на прежнем месте.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Divider().overlay(Theme.border)
            HStack {
                Toggle("Уведомлять о сохранении поверх игры", isOn: $model.notificationsEnabled).toggleStyle(.switch)
                Spacer()
                Button("Проверить") { model.testNotification() }.buttonStyle(.bordered).controlSize(.small).disabled(!model.notificationsEnabled)
            }
            Text("Короткое уведомление появляется в углу экрана и не переключает фокус на Spy.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

struct RenameClipSheet: View {
    let clip: Clip
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var issue: String?
    init(clip: Clip, model: AppModel) { self.clip = clip; self.model = model; _name = State(initialValue: clip.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Название видео", systemImage: "pencil").font(.system(size: 20, weight: .semibold))
            TextField("Например: Победа в последнем раунде", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            Text(issue ?? "До 120 символов. Пустое название возвращает дату записи.").font(.system(size: 12)).foregroundStyle(issue == nil ? Theme.muted : Theme.accent)
            HStack { Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить", action: save).buttonStyle(.borderedProminent).foregroundStyle(Theme.accentInk).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).count > 120) }
        }.padding(28).frame(width: 480).background(Theme.background).preferredColorScheme(.dark).tint(Theme.accent)
    }
    private func save() {
        do { try model.setClipName(clip, name: name); dismiss() }
        catch { issue = error.localizedDescription; model.journal.record(.error, "Название видео", describeError(error)) }
    }
}

struct CaptureDisplayRecoveryMenu: View {
    @ObservedObject var model: AppModel
    var compact = false
    var body: some View {
        Menu {
            ForEach(model.displays) { display in
                Button("Записывать «" + display.name + "»") {
                    model.displayID = display.id
                    Task { await model.toggleRecording() }
                }
            }
            if model.displays.isEmpty { Text("Подключите экран и повторите попытку") }
        } label: {
            if compact { Image(systemName: "display.trianglebadge.exclamationmark") }
            else { Label("Выбрать экран и включить", systemImage: "display") }
        }
        .accessibilityLabel("Выбрать экран и включить повтор")
        .help("Выбранный монитор отключён. Выберите экран для записи.")
        .disabled(model.recording || model.busy || model.saving || model.diagnosticsBusy || model.minutes == 0)
    }
}
