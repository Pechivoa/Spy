import SwiftUI
import AppKit

@MainActor final class SpyWindowController: ObservableObject {
    weak var window: NSWindow?
    var recording = false { didSet { updateCaptureProtection() } }
    static let minimum = NSSize(width: 280, height: 150)
    static let compact = NSSize(width: 340, height: 380)
    static let expanded = NSSize(width: 1160, height: 820)

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = Self.minimum
        window.styleMask.insert(.resizable)
        window.setFrameAutosaveName("Spy.MainWindow")
        updateCaptureProtection()
        let preferences = UserDefaults.standard
        if !preferences.bool(forKey: "compactWindowInstalled") {
            resize(to: Self.compact)
            preferences.set(true, forKey: "compactWindowInstalled")
        } else if !window.setFrameUsingName("Spy.MainWindow") {
            resize(to: Self.compact)
        }
    }
    func showCompact() { resize(to: Self.compact) }
    func showMini() { resize(to: Self.minimum) }
    func showExpanded() { resize(to: Self.expanded) }
    func updateCaptureProtection() {
        guard let window else { return }
        if recording {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
        } else {
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
    private func resize(to contentSize: NSSize) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        let current = window.frame
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var target = NSRect(x: current.minX, y: current.maxY - frameSize.height, width: frameSize.width, height: frameSize.height)
        if let visible = screen?.visibleFrame {
            target.size.width = min(target.width, visible.width)
            target.size.height = min(target.height, visible.height)
            target.origin.x = max(visible.minX, min(target.minX, visible.maxX - target.width))
            target.origin.y = max(visible.minY, min(target.minY, visible.maxY - target.height))
        }
        window.setFrame(target, display: true)
        window.saveFrame(usingName: "Spy.MainWindow")
    }
}

private struct WindowAttachment: NSViewRepresentable {
    let controller: SpyWindowController
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) { view.controller = controller }
    final class AttachmentView: NSView {
        weak var controller: SpyWindowController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DispatchQueue.main.async { [weak self, weak window] in
                    if let window { self?.controller?.attach(window) }
                }
            }
        }
    }
}

/// A dedicated native drag area leaves sliders and buttons fully interactive.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct SpyWindowView: View {
    @ObservedObject var model: AppModel
    @StateObject private var window = SpyWindowController()
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1060 || geometry.size.height < 800
            VStack(spacing: 0) {
                toolbar(compact: compact, tiny: geometry.size.height < 240)
                if compact { CompactSpyView(model: model, window: window, tiny: geometry.size.height < 240) }
                else { ContentView(model: model) }
            }
            .background(Theme.background)
            .background {
                if !model.previewMode { WindowAttachment(controller: window).frame(width: 0, height: 0) }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: SpyWindowController.minimum.width, minHeight: SpyWindowController.minimum.height)
        .preferredColorScheme(.dark)
        .onAppear {
            window.recording = model.recording
            if !model.previewMode { model.showMainWindow = { openWindow(id: "main") } }
        }
        .onChange(of: model.recording) { _, value in window.recording = value }
        .onChange(of: model.section) { _, value in if [6, 7, 8].contains(value) { window.showExpanded() } }
        .sheet(item: Binding(get: { model.bufferPreview }, set: { value in
            if value == nil { model.closeBufferPreview() }
        })) { preview in
            BufferPreviewSheet(preview: preview, model: model)
        }
    }
    private func toolbar(compact: Bool, tiny: Bool) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 70, height: 28)
            WindowDragArea()
                .overlay(alignment: .leading) {
                    HStack(spacing: 7) {
                        SpyMark().fill(Theme.brand).frame(width: 18, height: 22)
                        Text(model.previewMode ? "Spy · Пример" : "Spy").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }.allowsHitTesting(false)
                }.frame(maxWidth: .infinity).frame(height: 30)
                .help("Перетащите окно за эту область")
            CaptureHealthBadge(health: model.captureHealth) { model.section = 3; window.showExpanded() }
            Menu {
                navigation("Мгновенный повтор", section: 0)
                navigation("Библиотека", section: 1)
                navigation("Настройки", section: 2)
                navigation("Профили", section: 4)
                navigation("Дополнительно", section: 5)
                navigation("Восстановление", section: 6)
                navigation("Хранилище", section: 7)
                navigation("История сессий", section: 8)
                navigation("Журнал ошибок", section: 3)
                Divider()
                Button("Добавить метку · " + model.shortcuts.marker.label) { model.addMomentMarker() }
                    .disabled(!model.canAddMomentMarker)
                if !model.recoveryFolders.isEmpty {
                    Button("Восстановить последнюю запись") {
                        if let folder = model.recoveryFolders.last { Task { await model.recoverRecording(folder) } }
                    }.disabled(model.saving || model.busy || model.manualRecording)
                }
                Button("Открыть папку видео") { model.openFolder() }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Разделы Spy").help("Все разделы приложения")
            Button { if tiny { window.showCompact() } else { window.showMini() } } label: {
                Image(systemName: tiny ? "plus.square" : "minus.square").frame(width: 25, height: 24)
            }.buttonStyle(.plain).accessibilityLabel(tiny ? "Увеличить панель" : "Мини-панель")
                .help(tiny ? "Увеличить панель" : "Уменьшить до мини-панели 280×150")
            Button { if compact { window.showExpanded() } else { window.showCompact() } } label: {
                Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .frame(width: 25, height: 24)
            }.buttonStyle(.plain).accessibilityLabel(compact ? "Развернуть интерфейс" : "Компактное окно")
                .help(compact ? "Развернуть интерфейс" : "Компактное окно")
        }.padding(.horizontal, 8).frame(height: 36).foregroundStyle(.white)
            .background(Theme.panel)
    }
    private func navigation(_ title: String, section: Int) -> some View {
        Button(title) { model.section = section; window.showExpanded() }
    }
}

struct CompactSpyView: View {
    @ObservedObject var model: AppModel
    let window: SpyWindowController
    let tiny: Bool
    private var status: String {
        model.startupStatus ?? (model.privacyPaused ? "Запись на паузе" : model.manualRecording ? "Ручная запись" : model.recording ? "Повтор активен" : model.needsPermission ? "Нужен доступ к экрану" : model.captureIssue != nil ? "Ошибка запуска" : "Повтор выключен")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: tiny ? 7 : 13) {
            HStack(spacing: 8) {
                Circle().fill(model.privacyPaused ? Theme.accent : model.recording ? Theme.green : model.captureIssue != nil ? Theme.accent : Theme.muted).frame(width: 6, height: 6)
                Text(status).font(.system(size: tiny ? 10 : 12, weight: .medium)).lineLimit(1)
                if !model.recording && model.captureMode == .display && model.selectedDisplay == nil {
                    CaptureDisplayRecoveryMenu(model: model, compact: true).menuStyle(.borderlessButton).fixedSize()
                }
                Spacer(minLength: 0)
                Text(clockText(model.manualRecording ? model.stats.manualSeconds : model.stats.seconds))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button { Task { await model.toggleRecording() } } label: {
                    HStack(spacing: 6) {
                        if model.busy { ProgressView().controlSize(.mini) }
                        else { Image(systemName: model.recording ? "stop.fill" : "record.circle") }
                        Text(model.recording ? "Стоп" : "Включить").fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).frame(height: tiny ? 32 : 38)
                        .background(model.recording ? Color.white.opacity(0.08) : Theme.accent, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(model.diagnosticsBusy || model.busy || model.saving || (!model.recording && model.minutes == 0))
                Button { Task { await model.openBufferPreview() } } label: {
                    Group {
                        if model.preparingBufferPreview { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "play.rectangle") }
                    }.frame(width: 28, height: tiny ? 32 : 38)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!model.canPreviewBuffer && model.bufferPreview == nil)
                    .accessibilityLabel("Просмотреть буфер").help("Посмотреть видео перед сохранением")
                Button { Task { await model.saveSpy() } } label: {
                    Label(model.saving ? "Сохранение…" : "Сохранить", systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).frame(height: tiny ? 32 : 38)
                        .foregroundStyle(model.canSave ? .white : Theme.muted)
                        .background(model.canSave ? Theme.accent : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!model.canSave).help(model.shortcuts.save.label)
            }.font(.system(size: 12))
            HStack {
                Label(fileSize(model.manualRecording ? model.stats.manualBytes : model.stats.bytes), systemImage: "internaldrive")
                if let warning = model.stats.sourceWarning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent).help(warning)
                }
                Button { model.addMomentMarker() } label: { Image(systemName: "bookmark").frame(width: 20) }
                    .buttonStyle(.plain).disabled(!model.canAddMomentMarker)
                    .accessibilityLabel("Добавить метку момента").help(model.shortcuts.marker.label)
                Spacer()
                if tiny && !model.recoveryFolders.isEmpty {
                    Button("Восстановить") {
                        model.section = 6; window.showExpanded()
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .disabled(model.saving || model.busy || model.manualRecording)
                } else { Text("из " + model.effectiveDurationLabel) }
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
            if !tiny {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        PerformancePanel(actualFPS: model.recording && !model.privacyPaused ? model.stats.actualFPS : 0, droppedFrames: model.stats.droppedFrames, targetFPS: (model.recordingQuality ?? model.effectiveQuality).fps, monitor: model.performance, compact: true)
                        Button(model.privacyPaused ? "Продолжить запись" : "Пауза записи") { model.togglePrivacyPause() }
                            .buttonStyle(.bordered).disabled(!model.recording || model.busy)
                        if !model.recoveryFolders.isEmpty { RecoveryNotice(model: model, compact: true) }
                        if let issue = model.captureIssue {
                            Text(issue).font(.system(size: 11)).foregroundStyle(Theme.accent)
                            HStack {
                                if model.needsPermission { Button("Доступ к экрану") { model.openPermissions() } }
                                if model.needsMicrophonePermission { Button("Микрофон") { model.openMicrophonePermissions() } }
                                if model.needsPermission { Button("Перезапустить") { model.restartSpy() }.disabled(model.diagnosticsBusy || model.busy || model.saving || model.recording) }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Время повтора").foregroundStyle(Theme.muted)
                                Spacer()
                                Text(model.effectiveDurationLabel).fontWeight(.semibold)
                            }.font(.system(size: 11))
                            Slider(value: $model.minutes, in: 0...30, step: 0.5)
                                .accessibilityLabel("Время повтора в минутах")
                                .disabled(model.diagnosticsBusy || model.busy || model.saving || model.manualRecording)
                            HStack { Text("0"); Spacer(); Text("30 мин") }.font(.system(size: 9)).foregroundStyle(Theme.muted)
                            Text("≈ " + fileSize(model.estimatedBytes)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                        }
                        HStack(spacing: 8) {
                            ForEach(ShortcutAction.quick) { action in
                                Button { Task { await model.saveSpy(seconds: action.seconds) } } label: {
                                    Text(action.seconds == 30 ? "30 с" : "\(Int((action.seconds ?? 60) / 60)) м")
                                        .font(.system(size: 10)).frame(maxWidth: .infinity)
                                }.buttonStyle(.bordered).disabled(!model.canSave).help(action.title + " · " + model.shortcuts[action].label)
                            }
                        }
                        Divider().overlay(Theme.border)
                        Toggle("Звук системы", isOn: $model.systemAudio).disabled(model.recording || model.diagnosticsBusy || model.busy || model.saving)
                        Text(model.captureTargetSummary).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        if let warning = model.stats.sourceWarning {
                            Text(warning).font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                        Toggle("Микрофон", isOn: $model.microphone).disabled(!model.microphoneAvailable || model.recording || model.diagnosticsBusy || model.busy || model.saving)
                        MicrophonePickerView(model: model)
                        ApplicationAudioPickerView(model: model)
                        Button("Формат, кэш и приватные области") { model.section = 2; window.showExpanded() }
                            .buttonStyle(.bordered)
                        Button(model.manualRecording ? "Завершить ручную запись" : "Ручная запись") { Task { await model.toggleManual() } }
                            .buttonStyle(.bordered).disabled(model.diagnosticsBusy || model.busy || model.saving)
                            .help(model.shortcuts.manual.label)
                        Button { model.section = 1; window.showExpanded() } label: {
                            HStack { Label("Библиотека", systemImage: "play.rectangle"); Spacer(); Text("\(model.clips.count) видео").foregroundStyle(Theme.muted); Image(systemName: "chevron.right") }
                        }.buttonStyle(.plain)
                        if let message = model.message { Text(message).font(.system(size: 10)).foregroundStyle(Theme.green) }
                    }.font(.system(size: 12)).toggleStyle(.switch)
                }.scrollIndicators(.hidden)
                .disabled(model.busy)
            } else { Spacer(minLength: 0) }
        }.padding(.horizontal, 12).padding(.vertical, tiny ? 7 : 12)
            .foregroundStyle(.white).background(Theme.background).tint(Theme.accent)
            .alert("Spy", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("Хорошо", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}
