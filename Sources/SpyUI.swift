import SwiftUI
import AVKit
import AppKit

enum Theme {
    static let background = Color(red: 5 / 255, green: 5 / 255, blue: 5 / 255)
    static let panel = Color(red: 17 / 255, green: 17 / 255, blue: 19 / 255)
    static let sidebar = Color(red: 9 / 255, green: 9 / 255, blue: 11 / 255)
    static let border = Color(red: 43 / 255, green: 43 / 255, blue: 49 / 255)
    static let muted = Color(red: 160 / 255, green: 157 / 255, blue: 169 / 255)
    static let accentInk = Color(red: 27 / 255, green: 20 / 255, blue: 46 / 255)
    static let accent = Color(red: Double(SpiderGlyph.accentRed), green: Double(SpiderGlyph.accentGreen), blue: Double(SpiderGlyph.accentBlue))
    static let brand = accent
    static let danger = Color(red: 1, green: 0.40, blue: 0.44)
    static let green = Color(red: 0.40, green: 0.83, blue: 0.66)
}

struct SpyMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(SpiderGlyph.path(in: rect))
    }
}

@MainActor enum SpyBrandImages {
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 22), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(SpiderGlyph.path(in: rect.insetBy(dx: 0.7, dy: 0.7)))
            context.setFillColor(SpiderGlyph.accentCGColor)
            context.fillPath()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Spy — паук"
        return image
    }()
}

struct SpyApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Spy", id: "main") {
            SpyWindowView(model: model)
                .onAppear { delegate.model = model }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 340, height: 380)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Повтор") {
                Button(model.recording ? "Остановить буфер" : "Включить буфер") { Task { await model.toggleRecording() } }.disabled(model.diagnosticsBusy || model.busy || model.saving)
                Button(model.manualRecording ? "Завершить ручную запись" : "Начать ручную запись") { Task { await model.toggleManual() } }.disabled(model.diagnosticsBusy || model.busy || model.saving)
                Button("Сохранить повтор") { Task { await model.saveSpy() } }.disabled(!model.canSave)
                Button("Просмотреть буфер · " + model.shortcuts.preview.label) { Task { await model.openBufferPreview() } }.disabled(!model.canPreviewBuffer && model.bufferPreview == nil)
                Button("Добавить метку · " + model.shortcuts.marker.label) { model.addMomentMarker() }.disabled(!model.canAddMomentMarker)
                ForEach(ShortcutAction.quick) { action in
                    Button(action.title) { Task { await model.saveSpy(seconds: action.seconds) } }.disabled(!model.canSave)
                }
                Divider()
                Button("Проверить обновления Spy…") { model.section = 2; Task { await model.updates.check() } }
                Button("Открыть папку видео") { model.openFolder() }
                Button("Очередь сохранения…") { model.showExportQueue() }
            }
        }
        MenuBarExtra {
            SpyMenu(model: model)
        } label: {
            Image(nsImage: SpyBrandImages.menuBar)
                .renderingMode(.original)
                .accessibilityLabel(model.recording ? "Spy — повтор активен" : "Spy — повтор выключен")
                .help(model.recording ? "Spy — повтор активен" : "Spy — повтор выключен")
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Spy", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if terminating { return .terminateLater }
        if model.saving {
            model.updates.cancelInstall()
            let alert = NSAlert()
            alert.messageText = "Видео ещё сохраняется"
            alert.informativeText = "Дождитесь завершения сохранения, затем закройте Spy."
            alert.addButton(withTitle: "Хорошо"); alert.runModal()
            return .terminateCancel
        }
        terminating = true
        Task { let saved = await model.shutdown(); if !saved { model.updates.cancelInstall() }; terminating = false; sender.reply(toApplicationShouldTerminate: saved) }
        return .terminateLater
    }
}

struct SpyMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.recording ? "Буфер · \(clockText(model.stats.seconds))" : "Мгновенный повтор выключен")
        Button("Открыть Spy") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button((model.recording ? "Остановить · " : "Включить · ") + model.shortcuts.toggle.label) { Task { await model.toggleRecording() } }.disabled(model.diagnosticsBusy || model.busy || model.saving)
        Button(model.saving ? "Сохраняется…" : "Сохранить повтор · " + model.shortcuts.save.label) { Task { await model.saveSpy() } }.disabled(!model.canSave)
        Button(model.preparingBufferPreview ? "Подготовка просмотра…" : "Просмотреть буфер") {
            openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
            Task { await model.openBufferPreview() }
        }.disabled(!model.canPreviewBuffer && model.bufferPreview == nil)
        Button("Добавить метку · " + model.shortcuts.marker.label) { model.addMomentMarker() }.disabled(!model.canAddMomentMarker)
        ForEach(ShortcutAction.quick) { action in
            Button(action.title + " · " + model.shortcuts[action].label) { Task { await model.saveSpy(seconds: action.seconds) } }.disabled(!model.canSave)
        }
        Divider()
        Button((model.manualRecording ? "Завершить запись · " : "Начать запись · ") + model.shortcuts.manual.label) { Task { await model.toggleManual() } }.disabled(model.diagnosticsBusy || model.busy || model.saving)
        Button(model.privacyPaused ? "Продолжить запись" : "Пауза записи") { model.togglePrivacyPause() }.disabled(!model.recording || model.busy)
        Toggle("Индикатор поверх игры", isOn: $model.hudEnabled)
        Button("Папка с видео") { model.openFolder() }
        Button("Очередь сохранения · \(model.queuedExports)") { model.showExportQueue() }
        Divider()
        Button("Завершить Spy") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var journal: EventJournal
    @State private var deleteCandidate: Clip?
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var renameCandidate: Clip?
    init(model: AppModel) { self.model = model; self.journal = model.journal }
    private var visibleClips: [Clip] {
        model.clips.filter { clip in
            (!favoritesOnly || clip.favorite) && (search.isEmpty || clip.title.localizedCaseInsensitiveContains(search) || clip.dateTitle.localizedCaseInsensitiveContains(search) || clip.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header.id("capture-top")
                    CaptureHealthView(health: model.captureHealth, showJournal: { model.section = 3 })
                    CaptureRecoveryNotice(recovery: model.captureRecovery, onCancel: model.cancelCaptureRecovery)
                    if !model.recoveryFolders.isEmpty && model.section != 6 { RecoveryNotice(model: model) }
                    if let issue = model.captureIssue { captureProblem(issue) }
                    if let message = model.message {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                            Text(message).font(.system(size: 13))
                            Spacer()
                            Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                        }.padding(14).background(Theme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.section == 0 {
                        ObsidianCaptureView(model: model)
                    } else if model.section == 2 {
                        settingsPanel
                    } else if model.section == 4 {
                        ProfilesView(model: model)
                    } else if model.section == 5 {
                        ProSettingsView(model: model)
                    } else if model.section == 6 {
                        RecoveryCenterView(model: model)
                    } else if model.section == 7 {
                        StorageCenterView(model: model)
                    } else if model.section == 8 {
                        SessionHistoryView(history: model.sessions, model: model)
                    } else if model.section == 3 {
                        JournalView(model: model, journal: journal)
                    }
                    if model.section == 0 || model.section == 1 { library }
                }.padding(30)
            }.background(Theme.background)
                .onChange(of: model.captureIssue) { _, value in
                    if value != nil { withAnimation { proxy.scrollTo("capture-top", anchor: .top) } }
                }
            }
            footer.padding(.horizontal, 24).padding(.vertical, 10).background(Theme.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .foregroundStyle(.white)
        .font(.system(size: 14))
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.background)
        .tint(Theme.accent)
        .alert("Spy", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Хорошо", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Переместить видео в Корзину?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
            if let clip = deleteCandidate {
                Button("Удалить видео", role: .destructive) { Task { await model.trash(clip) }; deleteCandidate = nil }
            }
            Button("Отмена", role: .cancel) { deleteCandidate = nil }
        } message: { Text("Видео можно восстановить из Корзины macOS.") }
        .sheet(item: $renameCandidate) { clip in RenameClipSheet(clip: clip, model: model) }
        .sheet(item: $model.editingShortcut) { action in ShortcutCaptureSheet(action: action, model: model) }
    }

    private var navigationBar: some View {
        HStack(spacing: 22) {
            HStack(spacing: 9) {
                SpyMark().fill(Theme.accent).frame(width: 23, height: 30)
                Text("Spy").font(.system(size: 21, weight: .medium))
            }.frame(width: 140, alignment: .leading)
            Spacer(minLength: 0)
            topLink("Повтор", section: 0)
            topLink("Библиотека", section: 1)
            Button { model.showExportQueue() } label: {
                HStack(spacing: 6) {
                    Text("Очередь")
                    if model.queuedExports > 0 { Text("\(model.queuedExports)").foregroundStyle(Theme.accent).monospacedDigit() }
                }
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                .accessibilityIdentifier("Spy.Navigation.Queue")
            Spacer(minLength: 0)
            Menu {
                Button("Профили приложений") { model.section = 4 }
                Button("Сессия и автосохранение") { model.section = 5 }
                Button("Восстановление") { model.section = 6 }
                Button("Хранилище") { model.section = 7 }
                Button("История сессий") { model.section = 8 }
                Button(journal.errorCount > 0 ? "Журнал ошибок · \(journal.errorCount)" : "Журнал ошибок") { model.section = 3 }
                Divider()
                Button("Настройки записи") { model.section = 2 }
                Button("Открыть папку видео") { model.openFolder() }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Все разделы Spy")
            Button { model.section = 2 } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                .buttonStyle(.plain).accessibilityLabel("Настройки записи")
        }.padding(.horizontal, 28).padding(.vertical, 15).background(Theme.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
    private func topLink(_ title: String, section: Int) -> some View {
        Button { model.section = section } label: {
            Text(title).font(.system(size: 12, weight: model.section == section ? .medium : .regular))
                .foregroundStyle(model.section == section ? .white : Theme.muted)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(model.section == section ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.section == 0 ? "Мгновенный повтор" : model.section == 1 ? "Библиотека видео" : model.section == 3 ? "Журнал ошибок" : model.section == 4 ? "Профили приложений" : model.section == 5 ? "Сессия и автосохранение" : model.section == 6 ? "Центр восстановления" : model.section == 7 ? "Хранилище Spy" : model.section == 8 ? "История сессий" : "Настройки записи")
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                Text(model.section == 0 ? "Последние минуты экрана — перед сохранением можно посмотреть." : model.section == 1 ? "Предпросмотр, монтаж и сохранённые моменты." : model.section == 3 ? "События, диагностика и экспорт в TXT." : model.section == 4 ? "Свои настройки для каждого приложения." : model.section == 5 ? "Восстановление, индикатор и работа в фоне." : model.section == 6 ? "Предпросмотр и сохранение незавершённых записей." : model.section == 7 ? "Размеры данных и выбранная очистка через Корзину." : model.section == 8 ? "Запись, паузы и сохранённые моменты." : "Источники, качество, звук и горячие клавиши.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.privacyPaused ? Theme.accent : model.recording ? Theme.green : Theme.muted).frame(width: 6, height: 6)
                Text(model.privacyPaused ? "ПАУЗА" : model.manualRecording ? "РУЧНАЯ ЗАПИСЬ" : model.recording ? "ЗАПИСЬ" : "ОЖИДАНИЕ").font(.system(size: 9, weight: .bold)).tracking(1)
            }.foregroundStyle(model.recording ? Theme.green : Theme.muted).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.white.opacity(0.04), in: Capsule()).overlay(Capsule().stroke(Theme.border))
        }.padding(.top, 10)
    }

    private func captureProblem(_ issue: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.needsPermission ? "Повтор не запущен: доступ к экрану" : "Повтор не запущен", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger)
            Text(issue).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if model.needsPermission { Button("Настройки доступа") { model.openPermissions() } }
                if model.needsMicrophonePermission { Button("Доступ к микрофону") { model.openMicrophonePermissions() } }
                if model.captureMode == .display && model.selectedDisplay == nil {
                    CaptureDisplayRecoveryMenu(model: model)
                } else {
                    Button("Повторить запуск") { Task { await model.toggleRecording() } }.disabled(model.diagnosticsBusy || model.busy || model.saving || model.recording || model.minutes == 0)
                }
                if model.needsPermission { Button("Перезапустить Spy") { model.restartSpy() }.disabled(model.diagnosticsBusy || model.busy || model.saving || model.recording) }
                Button("Открыть журнал") { model.section = 3 }
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.18)))
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text(model.section == 1 ? "Сохранённые видео" : "Последние повторы").font(.system(size: 19, weight: .semibold))
                Text("\(model.clips.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.panel, in: Capsule())
                Spacer()
                Button { Task { await model.reloadClips() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Обновить библиотеку")
                Button { model.openFolder() } label: { Label("Открыть папку", systemImage: "folder") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if model.section == 1 && !model.clips.isEmpty {
                HStack(spacing: 12) {
                    TextField("Найти по названию, дате или файлу", text: $search).textFieldStyle(.roundedBorder)
                    Toggle(isOn: $favoritesOnly) { Label("Избранное", systemImage: "star.fill") }.toggleStyle(.button).tint(Theme.accent)
                    Text(fileSize(model.totalLibraryBytes)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            if model.clips.isEmpty {
                HStack(spacing: 20) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 31, weight: .light)).foregroundStyle(Theme.muted.opacity(0.6))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Здесь появятся ваши моменты").font(.system(size: 13, weight: .medium))
                        Text("Включите повтор и нажмите \(model.shortcuts.save.label), когда захотите сохранить последние минуты.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }.padding(26).frame(maxWidth: .infinity).background(Theme.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            } else if model.section == 0 {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(model.clips.prefix(3))) { clip in
                        RecentMomentRow(clip: clip) { model.selectedClip = clip }
                    }
                }
                Button("Вся библиотека →") { model.section = 1 }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(Array(visibleClips.prefix(model.section == 0 ? 6 : Int.max))) { clip in
                        ClipCard(clip: clip, play: { model.selectedClip = clip }, reveal: { model.reveal(clip) }, delete: { deleteCandidate = clip }, favorite: { model.toggleFavorite(clip) }, rename: { renameCandidate = clip }, deletingDisabled: model.saving || model.cleanupBusy, onError: { error in journal.record(.warning, "Миниатюра видео", clip.url.lastPathComponent + "\n" + describeError(error)) })
                    }
                }
                if visibleClips.isEmpty { Text("Видео не найдены").foregroundStyle(Theme.muted).padding() }
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppUpdatesView(updates: model.updates, installAllowed: !model.manualRecording && !model.busy && !model.saving && !model.diagnosticsBusy)
            Divider().overlay(Theme.border)
            CaptureRecoveryView(recovery: model.captureRecovery, onCancel: model.cancelCaptureRecovery)
            Divider().overlay(Theme.border)
            CaptureTuningSettingsView(settings: model.captureTuning,
                locked: model.recording || model.busy || model.saving || model.diagnosticsBusy,
                previewLoader: { try await model.captureMaskPreview() })
            Divider().overlay(Theme.border)
            ApplicationAudioPickerView(model: model)
            Divider().overlay(Theme.border)
            DiagnosticsView(controller: model.recordingDiagnostics, onRun: { Task { await model.runRecordingCheck() } })
                .disabled(model.busy || model.saving || model.shuttingDown)
            AutoMomentClipSettingsView(controller: model.autoMomentClips)
            GameAutoCaptureSettingsView(controller: model.gameAutoCapture)
            Label("Быстрые клавиши", systemImage: "keyboard").font(.system(size: 19, weight: .semibold))
            shortcutRow(.save, detail: "Работает и когда окно Spy закрыто")
            shortcutRow(.manual, detail: "Полный сеанс от начала до остановки")
            shortcutRow(.toggle, detail: "Время задаётся ползунком на главном экране")
            shortcutRow(.preview, detail: "Открыть буфер из игры или другого приложения")
            shortcutRow(.marker, detail: "Отметить событие и найти его в просмотре")
            ForEach(ShortcutAction.quick) { shortcutRow($0, detail: "Последний фрагмент из текущего буфера") }
            HStack {
                Text("Нажмите сочетание, чтобы назначить своё. Можно использовать ⌘, ⌥, ⌃ и F-клавиши.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("По умолчанию") { model.restoreDefaultShortcuts() }.buttonStyle(.bordered).controlSize(.small)
            }
            if !model.hotkeyAvailable { Text("Одна из горячих клавиш занята другим приложением. Используйте кнопку или меню Spy в строке меню.").foregroundStyle(Theme.accent).font(.system(size: 12)) }
            Divider().overlay(Theme.border)
            LibrarySettingsView(model: model)
            Divider().overlay(Theme.border)
            Label("Звук микрофона", systemImage: "waveform").font(.system(size: 19, weight: .semibold))
            Toggle("Очистка микрофона", isOn: $model.microphoneCleanup).toggleStyle(.switch).disabled(model.recording || model.diagnosticsBusy || model.busy)
            Text("Уменьшает низкий гул и приглушает тихий фоновый шум. Применяется только к микрофону; включите перед записью.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Divider().overlay(Theme.border)
            PrivacySettingsView(controller: model.privacy).disabled(model.busy)
            Button(model.privacyPaused ? "Продолжить запись" : "Приостановить запись сейчас") { model.togglePrivacyPause() }
                .buttonStyle(.bordered).disabled(!model.recording || model.busy)
            Divider().overlay(Theme.border)
            Label("Доступ к экрану", systemImage: "display").font(.system(size: 19, weight: .semibold))
            Text("Повтор записывает выбранный экран или окно и выбранные источники звука: систему, микрофон или оба сразу. Окно Spy и системный звук его плеера исключены из записи. Запись включается вручную, при восстановлении сессии или по выбранной игре.").font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(5)
            Button("Настройки разрешений macOS") { model.openPermissions() }.buttonStyle(.bordered)
            Button("Доступ к микрофону") { model.openMicrophonePermissions() }.buttonStyle(.bordered)
            Text("Для смены области, качества, микрофона или источников остановите буфер. Громкость можно менять во время записи. Автоматическое включение настраивается во вкладке «Дополнительно».").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
    }
    private func shortcutRow(_ action: ShortcutAction, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(action.title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { model.beginShortcutEdit(action) } label: {
                HStack(spacing: 10) {
                    Text(model.shortcuts[action].label).font(.system(size: 15, weight: .medium, design: .monospaced))
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 15).padding(.vertical, 10).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }.buttonStyle(.plain).help("Назначить клавиши для действия «\(action.title)»")
        }
    }
    private var footer: some View {
        HStack {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("Видео хранятся только на этом Mac").font(.system(size: 10))
            Spacer()
            CaptureFormatSummary(settings: model.captureTuning)
        }.foregroundStyle(Theme.muted.opacity(0.7)).padding(.bottom, 4)
    }
}

struct ClipCard: View {
    let clip: Clip
    let play: () -> Void
    let reveal: () -> Void
    let delete: () -> Void
    let favorite: () -> Void
    let rename: () -> Void
    var deletingDisabled = false
    let onError: (Error) -> Void
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: play) {
                ZStack {
                    ThumbnailView(url: clip.url, onFailure: onError).frame(height: 135).clipped()
                    Color.black.opacity(hovered ? 0.15 : 0.32)
                    Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 43, height: 43).background(.black.opacity(0.45), in: Circle())
                }.frame(height: 135).overlay(alignment: .bottomTrailing) {
                    Text(clip.duration < 1 ? frameClock(clip.duration) : clockText(clip.duration)).font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5)).padding(9)
                }
            }.buttonStyle(.plain).accessibilityLabel("Смотреть видео \(clip.title)")
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(clip.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(fileSize(clip.bytes)).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                Button(action: favorite) { Image(systemName: clip.favorite ? "star.fill" : "star").font(.system(size: 12)).foregroundStyle(clip.favorite ? Theme.accent : Theme.muted) }.buttonStyle(.plain).help(clip.favorite ? "Убрать из избранного" : "Добавить в избранное")
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(hovered ? Theme.accent : Theme.muted) }.buttonStyle(.plain).help("Удалить видео").disabled(deletingDisabled)
            }.padding(13)
        }.background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.border))
            .onHover { hovered = $0 }
            .contextMenu {
                Button("Смотреть", action: play)
                Button("Назвать видео", action: rename)
                Button(clip.favorite ? "Убрать из избранного" : "Добавить в избранное", action: favorite)
                Button("Показать в Finder", action: reveal)
                Divider()
                Button("Удалить", role: .destructive, action: delete).disabled(deletingDisabled)
            }
    }
}

struct ThumbnailView: View {
    let url: URL
    var onFailure: ((Error) -> Void)? = nil
    @State private var thumbnail: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5)
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { Image(systemName: "film").foregroundStyle(Theme.muted).font(.system(size: 26)) }
            }
        }.task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 700, height: 400)
            do {
                let result = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
                thumbnail = NSImage(cgImage: result.image, size: .zero)
            } catch { if !Task.isCancelled { onFailure?(error) } }
        }
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer?
    var allowsFullScreen = true
    func makeNSView(context: Context) -> AVPlayerView {
        makePlayerView()
    }
    func makePlayerView() -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = allowsFullScreen
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
        view.showsFullScreenToggleButton = allowsFullScreen
    }
}
