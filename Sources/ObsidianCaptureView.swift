import SwiftUI
import AVKit

struct ObsidianCaptureView: View {
    @ObservedObject var model: AppModel
    @State private var audioOpen = false
    @State private var detailsOpen = false
    private var locked: Bool { model.recording || model.diagnosticsBusy || model.busy || model.saving }
    private var seconds: Double { model.manualRecording ? model.stats.manualSeconds : model.stats.seconds }
    private var bytes: Int64 { model.manualRecording ? model.stats.manualBytes : model.stats.bytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let warning = model.stats.sourceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            HStack(alignment: .top, spacing: 42) {
                recordingHub.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 10) {
                    CaptureOverviewTile(model: model)
                    audioToggle("Звук системы", icon: "speaker.wave.2", value: $model.systemAudio)
                    audioToggle("Микрофон", icon: "mic", value: $model.microphone)
                        .disabled(!model.microphoneAvailable)
                    Button { audioOpen = true } label: {
                        Label("Устройства и приложения", systemImage: "arrow.up.right")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }.buttonStyle(.plain).padding(.top, 2)
                        .popover(isPresented: $audioOpen) { soundPanel }
                }.frame(maxWidth: .infinity)
            }
            DisclosureGroup(isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 20) {
                    CaptureTargetView(model: model)
                    QuickSaveView(model: model)
                    ManualControlsView(model: model).disabled(model.diagnosticsBusy)
                    PerformancePanel(actualFPS: model.recording && !model.privacyPaused ? model.stats.actualFPS : 0,
                        droppedFrames: model.stats.droppedFrames,
                        targetFPS: (model.recordingQuality ?? model.effectiveQuality).fps, monitor: model.performance)
                    if let active = model.activeProfileName {
                        Label("Профиль: " + active, systemImage: "square.stack.3d.up").foregroundStyle(Theme.muted)
                    }
                    if model.batterySaving && model.onBattery {
                        Label("От батареи: \(model.effectiveQuality.title) · до \(model.effectiveMinutes.formatted()) мин", systemImage: "leaf.fill")
                            .foregroundStyle(Theme.green)
                    }
                }.font(.system(size: 12)).padding(.top, 18)
            } label: {
                HStack(spacing: 8) {
                    Label("Запись и источники", systemImage: "slider.horizontal.3")
                    Spacer()
                    if model.manualRecording { Text("Ручная запись · " + clockText(model.stats.manualSeconds)).foregroundStyle(Theme.accent) }
                    else { Text(model.captureTargetSummary).lineLimit(1).foregroundStyle(Theme.muted) }
                }.font(.system(size: 12))
            }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var recordingHub: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.manualRecording ? "Ручная запись" : "Мгновенный повтор")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text(clockText(seconds)).font(.system(size: 64, weight: .regular, design: .monospaced))
                .tracking(-3).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier("Spy.Capture.Duration")
            HStack(spacing: 18) {
                Text(fileSize(bytes)).accessibilityIdentifier("Spy.Capture.Bytes")
                Text((model.recordingQuality ?? model.effectiveQuality).title)
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            VStack(spacing: 8) {
                HStack {
                    Text("Хранить последние").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(model.effectiveDurationLabel).fontWeight(.medium)
                }.font(.system(size: 12))
                Slider(value: $model.minutes, in: 0...30, step: 0.5)
                    .accessibilityLabel("Время повтора в минутах")
                    .disabled(model.diagnosticsBusy || model.busy || model.saving || model.manualRecording)
                HStack { Text("Выкл."); Spacer(); Text("≈ " + fileSize(model.estimatedBytes)); Spacer(); Text("30 мин") }
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }.padding(.top, 12)
            Button {
                Task { if model.recording { await model.saveSpy() } else { await model.toggleRecording() } }
            } label: {
                HStack(spacing: 8) {
                    if model.busy || model.saving { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.recording ? "square.and.arrow.down" : "record.circle") }
                    Text(model.startupStatus ?? (model.saving ? "Сохраняется…" : model.busy ? "Подождите…" : model.recording ? "Сохранить повтор" : "Включить повтор"))
                        .fontWeight(.medium)
                    Spacer(minLength: 0)
                    Text(model.recording ? model.shortcuts.save.label : model.shortcuts.toggle.label)
                        .font(.system(size: 11)).opacity(0.75)
                }.padding(.horizontal, 14).frame(height: 43)
                    .foregroundStyle(Theme.accentInk).background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .disabled(model.recording ? !model.canSave : model.diagnosticsBusy || model.busy || model.saving || model.minutes == 0)
                .accessibilityIdentifier("Spy.Capture.Primary")
            HStack {
                if model.recording {
                    Button("Остановить повтор") { Task { await model.toggleRecording() } }
                        .disabled(model.diagnosticsBusy || model.busy || model.saving)
                }
                Spacer()
                if model.recording {
                    Button(model.privacyPaused ? "Продолжить" : "Пауза") { model.togglePrivacyPause() }
                        .disabled(model.busy)
                }
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.muted).frame(minHeight: 22)
        }
    }
    private func audioToggle(_ title: String, icon: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Label(title, systemImage: icon).font(.system(size: 12)) }
            .toggleStyle(.switch).controlSize(.small).disabled(locked)
            .padding(.vertical, 3).help(locked ? "Остановите запись, чтобы изменить источники звука" : title)
    }
    private var soundPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Звук и устройства", systemImage: "audio.waveform").font(.system(size: 17, weight: .medium))
            AudioControlsView(model: model)
            Divider().overlay(Theme.border)
            ApplicationAudioPickerView(model: model)
            if !model.microphoneAvailable { Text("Запись микрофона доступна на macOS 15 и новее.").foregroundStyle(Theme.muted) }
        }.padding(22).frame(width: 560).font(.system(size: 12))
            .background(Theme.panel).preferredColorScheme(.dark).tint(Theme.accent)
    }
}

/// A small in-memory sample from the same masked pixels as the encoder.
/// It never opens a second capture session or exports the replay buffer.
struct CaptureOverviewTile: View {
    @ObservedObject var model: AppModel
    @State private var image: NSImage?
    private var active: Bool { model.recording && !model.privacyPaused }
    var body: some View {
        Button { Task { await model.openBufferPreview() } } label: {
            ZStack {
                Theme.panel
                if active, let image {
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    Color.black.opacity(0.2)
                } else if model.previewMode, let clip = model.clips.first {
                    ThumbnailView(url: clip.url)
                } else {
                    SpyMark().fill(Theme.accent.opacity(0.12)).frame(width: 75, height: 95)
                }
                VStack(spacing: 9) {
                    if model.preparingBufferPreview { ProgressView().controlSize(.small) }
                    else { Image(systemName: "play.fill").font(.system(size: 16)).frame(width: 42, height: 42).background(.black.opacity(0.65), in: Circle()) }
                    Text(model.preparingBufferPreview ? "Подготовка просмотра…" : "Посмотреть буфер")
                        .font(.system(size: 12, weight: .medium))
                    if !model.recording { Text("Включите мгновенный повтор").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                }.padding(12).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomLeading) {
                    Text(active && image != nil ? "Последний кадр буфера" : model.captureTargetSummary)
                        .font(.system(size: 10)).lineLimit(1).padding(6).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(9)
                }
        }.buttonStyle(.plain).disabled(!model.canPreviewBuffer && model.bufferPreview == nil)
            .accessibilityLabel("Просмотреть буфер").accessibilityIdentifier("Spy.Capture.Preview")
            .task(id: active) {
                image = nil
                guard active, !model.previewMode else { return }
                while !Task.isCancelled {
                    let frame = await model.engine.overviewThumbnail()
                    guard !Task.isCancelled else { return }
                    image = frame.map { NSImage(cgImage: $0, size: .zero) }
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                }
            }
    }
}

struct RecentMomentRow: View {
    let clip: Clip
    let play: () -> Void
    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ThumbnailView(url: clip.url).frame(width: 78, height: 53).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 6) {
                    Text(clip.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(clockText(clip.duration) + " · " + fileSize(clip.bytes)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
        }.buttonStyle(.plain).accessibilityLabel("Смотреть видео " + clip.title)
    }
}
