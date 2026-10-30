import SwiftUI
import AppKit

struct ManualControlsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: model.manualRecording ? "record.circle.fill" : "video").foregroundStyle(model.manualRecording ? Theme.accent : Theme.muted).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.manualRecording ? "Ручная запись · " + clockText(model.stats.manualSeconds) : "Записать весь сеанс").font(.system(size: 13, weight: .semibold))
                    Text(model.manualRecording ? fileSize(model.stats.manualBytes) + (model.minutes > 0 ? " · повтор продолжает работать" : " · полный сеанс") : "От начала до остановки, без лимита в 30 минут").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { Task { await model.toggleManual() } } label: {
                    Label(model.manualRecording ? "Завершить и сохранить" : "Начать запись", systemImage: model.manualRecording ? "stop.fill" : "record.circle")
                }.buttonStyle(.bordered).disabled(model.busy || model.saving)
                Text(model.shortcuts.manual.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }.padding(14).background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct ProSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Запуск и запись", systemImage: "power").font(.system(size: 19, weight: .semibold))
            Toggle("Открывать Spy при входе в macOS", isOn: Binding(get: { model.loginEnabled }, set: { value in Task { await model.setLoginEnabled(value) } })).toggleStyle(.switch).disabled(model.loginBusy)
            if model.loginNeedsApproval {
                HStack { Text("macOS ожидает разрешения на автозапуск.").font(.system(size: 12)).foregroundStyle(Theme.muted); Button("Объекты входа") { LoginService.openSettings() }.buttonStyle(.bordered) }
            }
            Toggle("Восстанавливать включённый повтор", isOn: $model.rememberReplay).toggleStyle(.switch)
            Text("Spy запоминает состояние и настройки. Если повтор был включён, он включится при следующем запуске и после сна Mac.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            Toggle("Сохранять последние минуты при выходе", isOn: $model.saveBufferOnExit).toggleStyle(.switch)
            Text("При завершении Spy видео из буфера появится в библиотеке. Закрытие окна оставляет Spy работать в фоне. Если диск недоступен, запись можно восстановить после подключения.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            Toggle("Всегда включать повтор при открытии Spy", isOn: $model.startBufferOnLaunch).toggleStyle(.switch)
            Text("Для автоматической записи нужен разрешённый доступ к экрану и выбранному микрофону. Если выбранное окно закрыто, выберите источник заново.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            Divider().overlay(Theme.border)
            Label("Индикатор поверх игры", systemImage: "rectangle.topthird.inset.filled").font(.system(size: 19, weight: .semibold))
            HStack {
                Toggle("Показывать состояние записи", isOn: $model.hudEnabled).toggleStyle(.switch)
                Spacer()
                Picker("Расположение", selection: $model.hudCorner) { ForEach(HUDCorner.allCases) { Text($0.title).tag($0) } }.frame(width: 250).disabled(!model.hudEnabled)
            }
            HStack {
                Button("Минимальный размер") { model.hud.setSize(HUDOverlay.minimumSize) }.buttonStyle(.bordered)
                Button("Маленький размер") { model.hud.setSize(HUDOverlay.defaultSize) }.buttonStyle(.bordered)
            }
            Text("Перетаскивайте индикатор в удобное место. Потяните его правый край, чтобы изменить размер; правый клик позволяет скрыть его. Положение и размер сохраняются. Индикатор не попадает в запись Spy.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            Divider().overlay(Theme.border)
            Label("Звук для монтажа", systemImage: "waveform.path").font(.system(size: 19, weight: .semibold))
            Label("Микрофон сохраняется отдельно", systemImage: "mic").font(.system(size: 13, weight: .medium))
            Text("В плеере можно выключить микрофон, оставив звук системы. Сохранение копии, фрагмента и экспорт MP4 учитывают выбранный звук.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            Divider().overlay(Theme.border)
            HStack {
                Label("Режим для батареи", systemImage: "battery.75percent").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text(model.onBattery ? "От аккумулятора" : "От сети").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Toggle("Использовать отдельные настройки без зарядки", isOn: $model.batterySaving).toggleStyle(.switch)
            HStack(spacing: 18) {
                Picker("Качество", selection: $model.batteryQuality) { ForEach(Quality.allCases) { Text($0.title).tag($0) } }
                Text("Буфер до \(model.batteryMinutes.formatted()) мин").font(.system(size: 12)).frame(width: 150)
                Slider(value: $model.batteryMinutes, in: 0.5...30, step: 0.5).accessibilityLabel("Максимальный буфер при работе от батареи")
            }.disabled(!model.batterySaving)
            Text("При смене питания буфер начинается заново с выбранным качеством. Ручная запись завершается с прежними настройками; изменения применяются после сохранения. Основные настройки возвращаются при подключении зарядки.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
    }
}

struct ProfilesView: View {
    @ObservedObject var model: AppModel
    @State private var choices: [AppChoice] = []
    @State private var selected = ""
    @State private var editing: AppProfile?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Профили приложений", systemImage: "square.stack.3d.up").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("Выбрать приложение…") { model.addProfileFromApp() }.buttonStyle(.bordered)
            }
            Toggle("Применять профиль при переходе в приложение", isOn: $model.profileAutomatic).toggleStyle(.switch)
            HStack {
                Picker("Открытое приложение", selection: $selected) {
                    Text("Выберите приложение").tag("")
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 350)
                Button { choices = model.runningAppChoices() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить приложения")
                Spacer()
                Button("Сохранить текущие настройки") { if let app = choices.first(where: { $0.id == selected }) { model.saveProfile(bundleID: app.id, name: app.name) } }.buttonStyle(.borderedProminent).foregroundStyle(Theme.accentInk).disabled(selected.isEmpty)
            }
            Text("Профиль хранит качество, время, источники звука, выбранный микрофон и громкость. Смена профиля начинает буфер заново. Во время ручной записи изменения откладываются.").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(4)
            if let active = model.activeProfileName { Label("Текущий профиль: " + active, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.green) }
            if let pending = model.pendingProfile { Text("Ожидает применения: " + pending.name).font(.system(size: 12)).foregroundStyle(.orange) }
            Divider().overlay(Theme.border)
            if model.profiles.isEmpty {
                Text("Выберите игру или приложение и сохраните настройки. Можно изменить профиль кнопкой с карандашом.").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.vertical, 30)
            }
            ForEach(model.profiles) { profile in
                HStack(spacing: 12) {
                    Image(systemName: "app.dashed").font(.system(size: 24)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(profile.name).font(.system(size: 14, weight: .semibold))
                        Text("\(profile.settings.quality.title) · \(profile.settings.minutes.formatted()) мин · система \(Int(profile.settings.systemVolume * 100))% · микрофон \(profile.settings.microphone ? "\(Int(profile.settings.microphoneVolume * 100))%" : "выкл.")").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Применить") { Task { await model.applyProfile(profile) } }.buttonStyle(.bordered).disabled(model.saving || model.busy)
                    Button { editing = profile } label: { Image(systemName: "pencil") }.buttonStyle(.bordered).help("Изменить профиль")
                    Button { model.removeProfile(profile) } label: { Image(systemName: "trash") }.buttonStyle(.bordered).help("Удалить профиль")
                }.padding(16).background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
            .onAppear { choices = model.runningAppChoices() }
            .sheet(item: $editing) { profile in ProfileEditorSheet(profile: profile, model: model) }
    }
}

struct ProfileEditorSheet: View {
    @ObservedObject var model: AppModel
    @State var profile: AppProfile
    @Environment(\.dismiss) private var dismiss
    init(profile: AppProfile, model: AppModel) { self.model = model; _profile = State(initialValue: profile) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(profile.name).font(.system(size: 22, weight: .semibold))
            Picker("Качество", selection: $profile.settings.quality) { ForEach(Quality.allCases) { Text($0.title).tag($0) } }
            HStack { Text("\(profile.settings.minutes.formatted()) мин").frame(width: 70); Slider(value: $profile.settings.minutes, in: 0...30, step: 0.5) }
            Toggle("Звук системы", isOn: $profile.settings.systemAudio)
            HStack { Text("Громкость: \(Int(profile.settings.systemVolume * 100))%").frame(width: 140); Slider(value: $profile.settings.systemVolume, in: 0...1, step: 0.01) }.disabled(!profile.settings.systemAudio)
            Toggle("Микрофон", isOn: $profile.settings.microphone)
            Picker("Устройство микрофона", selection: $profile.settings.microphoneID) { ForEach(model.microphones) { Text($0.name).tag($0.id) }; if !model.microphones.contains(where: { $0.id == profile.settings.microphoneID }) { Text("Отключённое устройство").tag(profile.settings.microphoneID) } }
            HStack { Text("Громкость: \(Int(profile.settings.microphoneVolume * 100))%").frame(width: 140); Slider(value: $profile.settings.microphoneVolume, in: 0...1, step: 0.01) }.disabled(!profile.settings.microphone)
            Text("Микрофон сохраняется отдельной дорожкой для отключения в плеере.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack { Spacer(); Button("Отмена") { dismiss() }; Button("Сохранить") { if let index = model.profiles.firstIndex(where: { $0.id == profile.id }) { model.profiles[index] = profile }; dismiss() }.buttonStyle(.borderedProminent).foregroundStyle(Theme.accentInk) }
        }.padding(28).frame(width: 540).background(Theme.background).preferredColorScheme(.dark).tint(Theme.accent)
    }
}
