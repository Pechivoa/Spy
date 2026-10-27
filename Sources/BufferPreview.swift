import SwiftUI
import AVKit

struct PreviewRange: Hashable {
    private let firstTick: Int64
    private let lastTick: Int64
    var start: Double { Double(firstTick) / 60_000 }
    var end: Double { Double(lastTick) / 60_000 }
    var duration: Double { end - start }
    init(start: Double, end: Double, duration: Double) throws {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max / 60_000) - 1,
              start.isFinite, end.isFinite, start >= 0, end <= duration + 0.001,
              end > start, end - start >= 1.0 / 60_000 - 0.000000001 else {
            throw SpyError.message("Выберите фрагмент не короче одного кадра в пределах видео.")
        }
        firstTick = Int64((start * 60_000).rounded())
        lastTick = Int64((min(end, duration) * 60_000).rounded())
        guard lastTick > firstTick else { throw SpyError.message("Фрагмент слишком короткий.") }
    }
}

struct BufferPreview: Identifiable {
    let id = UUID()
    let directory: URL
    let clip: Clip
    let capturedAt: Date
    var playback: BufferPlayback? = nil
    var snapshot: SpySnapshot? = nil
    var separateAudio = false
    var initialMicrophoneEnabled = true
    var addedMarkers: [ClipMarker] = []
    var momentMarkers: [ClipMarker] {
        let captured: [ClipMarker]
        if let snapshot, let playback {
            captured = snapshot.markers.compactMap { marker in
                playback.sourcePosition(marker.sourceSeconds).map { ClipMarker(id: marker.id, seconds: $0, title: marker.title) }
            }
        } else if let snapshot { captured = MarkerTimeline.positions(in: snapshot) }
        else { captured = [] }
        return (captured + addedMarkers).sorted { $0.seconds < $1.seconds }
    }
    var savedURL: URL?
    var savedRanges: [PreviewRange: URL] = [:]
    var mutedSavedRanges: [PreviewRange: URL] = [:]
    var snapshotTimeLabel: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "ru_RU")
        format.timeZone = SpyDates.timeZone
        format.dateFormat = "HH:mm:ss"
        return format.string(from: capturedAt)
    }
    var asset: AVAsset {
        if let playback { return playback.asset }
        return AVURLAsset(url: clip.url)
    }
}

extension AppModel {
    /// A frozen composition directly references pinned encoder segments. No
    /// complete video or mixed audio is rendered before the user presses Save.
    func previewBuffer() async {
        guard canPreviewBuffer else { return }
        preparingBufferPreview = true; saving = true; message = nil
        defer {
            preparingBufferPreview = false; saving = false; refreshDisk()
            Task { await reconcilePendingChanges() }
        }
        do {
            let preview = try await prepareBufferPreview()
            bufferPreview = preview
            journal.record(.info, "Просмотр буфера", "Быстрый просмотр готов без экспорта: \(preciseClock(preview.clip.duration)) · \(fileSize(preview.clip.bytes)) в сегментах. Снимок на \(preview.snapshotTimeLabel); новые действия не входят. Видео ещё не добавлено в библиотеку.")
        } catch {
            showError(error.localizedDescription, topic: "Просмотр буфера", details: describeError(error))
        }
    }

    var canRefreshBufferPreview: Bool {
        bufferPreview != nil && recording && !busy && !saving && !shuttingDown &&
            !privacyPaused && !manualPrivacyPause && !privacy.isBlocked && minutes > 0 &&
            stats.frameCount > 0 && libraryAvailable
    }

    /// Publish the replacement only after new hardlinks and composition are ready.
    /// Failure keeps the old selection, completed saves and pinned media intact.
    @discardableResult func refreshBufferPreview(_ preview: BufferPreview, microphoneEnabled: Bool = true) async throws -> BufferPreview {
        guard let previous = bufferPreview, previous.id == preview.id else {
            throw SpyError.message("Этот просмотр уже закрыт. Откройте текущий буфер снова.")
        }
        guard canRefreshBufferPreview else {
            throw SpyError.message(!libraryAvailable
                ? "Папка видео недоступна. Прежний снимок остаётся открыт."
                : "Обновление доступно при работающем повторе вне паузы приватности. Прежний снимок сохранён.")
        }
        preparingBufferPreview = true; saving = true
        defer {
            preparingBufferPreview = false; saving = false; refreshDisk()
            Task { await reconcilePendingChanges() }
        }
        var candidate: BufferPreview?
        do {
            var replacement = try await prepareBufferPreview()
            candidate = replacement
            guard bufferPreview?.id == previous.id, recording, !shuttingDown,
                  !privacyPaused, !manualPrivacyPause, !privacy.isBlocked, libraryAvailable else {
                throw SpyError.message("Обновление прервано. Прежний снимок остаётся открыт.")
            }
            replacement.initialMicrophoneEnabled = microphoneEnabled
            if previous.snapshot?.captureSessionID == replacement.snapshot?.captureSessionID,
               let oldPlayback = previous.playback, let newPlayback = replacement.playback {
                replacement.addedMarkers = previous.addedMarkers.compactMap { marker in
                    guard let source = oldPlayback.sourceTime(marker.seconds), let position = newPlayback.sourcePosition(source) else { return nil }
                    return ClipMarker(id: marker.id, seconds: position, title: marker.title)
                }
            }
            bufferPreview = replacement
            candidate = nil
            do { try FileManager.default.removeItem(at: previous.directory) }
            catch { journal.record(.warning, "Очистка просмотра", "Новый снимок готов, но прежние временные сегменты не удалены.\n" + describeError(error)) }
            message = "Буфер обновлён · снимок на " + replacement.snapshotTimeLabel
            journal.record(.info, "Обновление просмотра", "Новый снимок на \(replacement.snapshotTimeLabel): \(preciseClock(replacement.clip.duration)). Прежний просмотр заменён после успешной подготовки.")
            return replacement
        } catch {
            if let candidate { try? FileManager.default.removeItem(at: candidate.directory) }
            journal.record(.error, "Обновление просмотра", "Прежний снимок сохранён.\n" + describeError(error))
            throw error
        }
    }

    private func prepareBufferPreview() async throws -> BufferPreview {
        let capturedAt = Date()
        let seconds = effectiveMinutes * 60
        let levels = AudioLevels(system: Float(systemVolume), microphone: Float(microphoneVolume))
        let separate = separateAudio
        let folder = cacheURL.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
        var pendingDirectory: URL?
        do {
            let snapshot = try await engine.snapshot(seconds: seconds)
            pendingDirectory = snapshot.directory
            try FileManager.default.moveItem(at: snapshot.directory, to: folder)
            pendingDirectory = folder
            let pinned = SpySnapshot(directory: folder, urls: snapshot.urls.map { folder.appendingPathComponent($0.lastPathComponent) }, requestedSeconds: snapshot.requestedSeconds, sourceIntervals: snapshot.sourceIntervals, markers: snapshot.markers, captureSessionID: snapshot.captureSessionID)
            let playback = try await BufferPlayback.prepare(pinned, levels: levels)
            let clip = Clip(url: folder.appendingPathComponent("Buffer.virtual"), date: capturedAt, bytes: playback.bytes, duration: playback.duration, managed: false)
            return BufferPreview(directory: folder, clip: clip, capturedAt: capturedAt, playback: playback, snapshot: pinned, separateAudio: separate)
        } catch {
            if let pendingDirectory { try? FileManager.default.removeItem(at: pendingDirectory) }
            throw error
        }
    }

    @discardableResult func saveBufferPreview(_ preview: BufferPreview, start: Double = 0, end: Double? = nil, microphoneEnabled: Bool = true) async throws -> URL {
        guard let current = bufferPreview, current.id == preview.id else { throw SpyError.message("Этот просмотр уже закрыт. Откройте текущий буфер снова.") }
        let range = try PreviewRange(start: start, end: end ?? preview.clip.duration, duration: preview.clip.duration)
        let fullRange = try PreviewRange(start: 0, end: preview.clip.duration, duration: preview.clip.duration)
        let entireBuffer = range == fullRange
        if let savedURL = (microphoneEnabled ? current.savedRanges : current.mutedSavedRanges)[range], FileManager.default.fileExists(atPath: savedURL.path) {
            storeMarkers(MarkerTimeline.selected(current.momentMarkers, start: range.start, end: range.end), for: savedURL)
            return savedURL
        }
        guard !saving, !shuttingDown else { throw SpyError.message("Дождитесь завершения текущей операции.") }
        saving = true
        defer { saving = false; refreshDisk(); Task { await reconcilePendingChanges() } }
        let stamp = DateFormatter(); stamp.timeZone = SpyDates.timeZone; stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = (entireBuffer ? "Spy_Preview_" : "Spy_Preview_Fragment_") + (microphoneEnabled ? "" : "NoMic_") + stamp.string(from: preview.capturedAt) + "_" + String(UUID().uuidString.prefix(4))
        let destination = libraryURL.appendingPathComponent(stem + ".mov").spyFileURL
        let partial = libraryURL.appendingPathComponent("." + stem + ".mov")
        do {
            guard libraryAvailable else { throw SpyError.message("Папка сохранения недоступна. Подключите диск или выберите другую папку; просмотр останется открыт.") }
            if let playback = preview.playback {
                try await playback.export(range: range, to: partial, separateAudio: preview.separateAudio, editableMicrophone: true, microphoneEnabled: microphoneEnabled)
            } else if !microphoneEnabled {
                let source = try await EditableVideoAudio.load(url: preview.clip.url)
                try await source.export(to: partial, start: range.start, end: range.end, microphoneEnabled: false)
            } else if entireBuffer {
                try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: preview.clip.url, to: partial) }.value
            } else {
                try await ClipTrimmer.export(source: preview.clip.url, start: range.start, end: range.end, to: partial)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            storeMarkers(MarkerTimeline.selected(current.momentMarkers, start: range.start, end: range.end), for: destination)
            if microphoneEnabled { bufferPreview?.savedRanges[range] = destination }
            else { bufferPreview?.mutedSavedRanges[range] = destination }
            if entireBuffer && microphoneEnabled { bufferPreview?.savedURL = destination }
            await reloadClips()
            message = (entireBuffer ? "Видео из просмотра сохранено · " : "Фрагмент сохранён · ") + preciseClock(range.duration)
            let savedBytes = clips.first(where: { $0.url == destination })?.bytes ?? 0
            journal.record(.info, "Сохранение из просмотра", "\(destination.lastPathComponent) · \(preciseClock(range.start))–\(preciseClock(range.end)) · \(fileSize(savedBytes))")
            if let saved = clips.first(where: { $0.url == destination }) { notifySaved(saved) }
            if autoCleanup { await cleanupLibrary(protecting: [destination]) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: partial)
            journal.record(.error, "Сохранение из просмотра", describeError(error))
            throw error
        }
    }

    func closeBufferPreview() {
        guard !saving, let preview = bufferPreview else { return }
        bufferPreview = nil
        do { try FileManager.default.removeItem(at: preview.directory) }
        catch { journal.record(.warning, "Очистка просмотра", describeError(error)) }
        refreshDisk()
    }
}

struct BufferPreviewSheet: View {
    let preview: BufferPreview
    @ObservedObject var model: AppModel
    @State private var player: AVPlayer?
    @StateObject private var editor = PlayerEditingState()
    @State private var audioControls: VideoAudioControls?
    @State private var microphoneEnabled = true
    @State private var observation: NSKeyValueObservation?
    @State private var playbackError: String?
    @State private var saveError: String?
    @State private var start: Double = 0
    @State private var end: Double
    private var currentTime: Double { editor.currentTime }
    private var frameStep: Double { max(1.0 / 60_000, editor.frameDuration) }
    private var momentMarkers: [ClipMarker] { model.bufferPreview?.id == preview.id ? model.bufferPreview!.momentMarkers : preview.momentMarkers }
    init(preview: BufferPreview, model: AppModel) {
        self.preview = preview
        self.model = model
        _end = State(initialValue: preview.clip.duration)
        _microphoneEnabled = State(initialValue: preview.initialMicrophoneEnabled)
    }
    private var duration: Double { max(0.001, preview.clip.duration) }
    private var range: PreviewRange? { try? PreviewRange(start: start, end: end, duration: duration) }
    private var entireBuffer: Bool { range == (try? PreviewRange(start: 0, end: duration, duration: duration)) }
    private var savedURL: URL? {
        guard let range, let url = (microphoneEnabled ? model.bufferPreview?.savedRanges : model.bufferPreview?.mutedSavedRanges)?[range],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SpyMark().fill(Theme.accent).frame(width: 18, height: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Просмотр буфера").font(.system(size: 17, weight: .semibold))
                    Text("\(preciseClock(preview.clip.duration)) · \(fileSize(preview.clip.bytes)) в буфере")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Text("Снимок на \(preview.snapshotTimeLabel). Новые действия не входят.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    player?.pause(); saveError = nil
                    let selectedMicrophone = microphoneEnabled
                    Task {
                        do { try await model.refreshBufferPreview(preview, microphoneEnabled: selectedMicrophone) }
                        catch { saveError = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.preparingBufferPreview { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(model.preparingBufferPreview ? "Обновляю…" : "Обновить буфер")
                    }
                }.buttonStyle(.bordered).controlSize(.small).disabled(!model.canRefreshBufferPreview)
                    .help("Получить новые кадры. Границы выбранного фрагмента будут сброшены.")
                Text(savedURL == nil ? "НЕ СОХРАНЕНО" : entireBuffer ? "В БИБЛИОТЕКЕ" : "ФРАГМЕНТ СОХРАНЁН")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(savedURL == nil ? Theme.muted : Theme.green)
            }.padding(20)
            HStack {
                Label("Предпросмотр видео", systemImage: "play.rectangle").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { editor.openFullScreen() } label: { Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderedProminent).disabled(!editor.canOpenFullScreen)
                    .accessibilityIdentifier("Spy.BufferPreview.FullScreen")
            }.padding(.horizontal, 20).padding(.bottom, 10)
            FullSizePlayer(player: player, title: "Просмотр буфера", editor: editor).frame(height: 290)
            FramePlaybackToolbar(editor: editor).padding(.horizontal, 20).padding(.top, 8)
            if let audioControls {
                VideoMicrophoneView(controls: audioControls, onChange: { microphoneEnabled = $0 })
                    .padding(.horizontal, 20).padding(.top, 10).disabled(model.saving)
            }
            TimelineThumbnailStrip(asset: preview.asset, assetID: preview.id.uuidString, duration: duration, selectionStart: start, selectionEnd: end, onSeek: seek)
                .padding(.horizontal, 20).padding(.top, 12)
            MomentMarkerStrip(markers: momentMarkers, onSeek: seek).padding(.horizontal, 20)
            selectionControls.padding(.horizontal, 20).padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 12) {
                if let playbackError { Text(playbackError).foregroundStyle(Theme.danger).font(.system(size: 12)) }
                if let saveError { Text(saveError).foregroundStyle(Theme.danger).font(.system(size: 12)).textSelection(.enabled) }
                Text(savedURL != nil ? "Выбранное видео добавлено в библиотеку." : "Сохранится выбранный момент. При закрытии временный просмотр удалится.")
                    .font(.system(size: 12)).foregroundStyle(savedURL == nil ? Theme.muted : Theme.green)
                HStack {
                    Label(model.privacyPaused ? "Запись на паузе" : model.recording ? "Новые кадры пишутся в фоне, вне снимка" : "Запись остановлена", systemImage: model.privacyPaused ? "pause.circle" : model.recording ? "record.circle" : "stop.circle")
                        .font(.system(size: 11)).foregroundStyle(model.privacyPaused ? Theme.accent : model.recording ? Theme.green : Theme.muted)
                    Spacer()
                    Button("Закрыть") { player?.pause(); model.closeBufferPreview() }
                        .keyboardShortcut(.cancelAction).disabled(model.saving)
                    Button {
                        saveError = nil
                        let selectedStart = start, selectedEnd = end
                        Task {
                            do { try await model.saveBufferPreview(preview, start: selectedStart, end: selectedEnd, microphoneEnabled: microphoneEnabled) }
                            catch { saveError = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if model.saving { ProgressView().controlSize(.small) }
                            Image(systemName: savedURL == nil ? "square.and.arrow.down" : "checkmark")
                            Text(savedURL != nil ? "Сохранено" : model.preparingBufferPreview ? "Обновляю…" : model.saving ? "Сохраняется…" : entireBuffer ? "Сохранить видео" : "Сохранить фрагмент")
                        }
                    }.buttonStyle(.borderedProminent).disabled(model.saving || !editor.canSave || savedURL != nil || range == nil)
                }.buttonStyle(.bordered)
            }.padding(20)
        }
        .frame(width: 760).foregroundStyle(.white).background(Theme.background)
        .preferredColorScheme(.dark).tint(Theme.accent).interactiveDismissDisabled(model.saving)
        .task(id: preview.id) {
            releasePlayer()
            start = 0; end = preview.clip.duration
            playbackError = nil; saveError = nil
            microphoneEnabled = preview.initialMicrophoneEnabled
            let previewID = preview.id
            do {
                let item: AVPlayerItem
                let sound: VideoAudioControls
                if let playback = preview.playback { sound = playback.videoAudioControls() }
                else { sound = try await VideoAudioControls.load(url: preview.clip.url) }
                try Task.checkCancellation()
                guard model.bufferPreview?.id == previewID else { return }
                sound.microphoneEnabled = microphoneEnabled
                audioControls = sound; item = sound.item
                player = AVPlayer(playerItem: item)
                if model.previewMode { player?.isMuted = true }
                editor.configure(player: player, duration: preview.clip.duration, audioControls: sound,
                    rangeStart: start, rangeEnd: end, markers: momentMarkers,
                    onRangeChanged: { first, last in start = first; end = last; saveError = nil },
                    onMicrophoneChanged: { microphoneEnabled = $0 },
                    onAddMarker: { time in
                        model.addBufferPreviewMarker(previewID, at: time)
                        editor.setMarkers(model.bufferPreview?.momentMarkers ?? [])
                    },
                    onSave: { first, last, microphone in
                        let url = try await model.saveBufferPreview(preview, start: first, end: last, microphoneEnabled: microphone)
                        return "Сохранено · " + url.lastPathComponent
                    })
                observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                    guard item.status == .failed, let error = item.error else { return }
                    Task { @MainActor in
                        guard model.bufferPreview?.id == previewID else { return }
                        playbackError = "Не удалось воспроизвести видео: " + error.localizedDescription
                        model.journal.record(.error, "Воспроизведение буфера", describeError(error))
                    }
                }
                player?.play()
            } catch {
                if !Task.isCancelled {
                    playbackError = error.localizedDescription
                    model.journal.record(.error, "Подготовка просмотра", describeError(error))
                }
            }
        }
        .onChange(of: start) { _, _ in saveError = nil; editor.setRange(start: start, end: end) }
        .onChange(of: end) { _, _ in saveError = nil; editor.setRange(start: start, end: end) }
        .onChange(of: momentMarkers) { _, value in editor.setMarkers(value) }
        .onDisappear { releasePlayer() }
    }

    private func releasePlayer() {
        editor.detach()
        player?.pause()
        observation?.invalidate(); observation = nil
        player = nil; audioControls = nil
    }

    private var selectionControls: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Выбрать момент", systemImage: "scissors").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(frameClock(max(0, end - start))).monospacedDigit().foregroundStyle(Theme.accent)
                Button("Весь буфер") { editor.selectAll(); seek(0) }.controlSize(.small)
            }
            HStack(spacing: 10) {
                Text("Начало").frame(width: 48, alignment: .leading)
                Slider(value: Binding(get: { start }, set: { editor.setStart($0) }), in: 0...duration, step: frameStep)
                    .accessibilityLabel("Начало фрагмента буфера")
                Text(frameClock(start)).monospacedDigit().frame(width: 85)
                Button("Из плеера") { editor.setStartAtPlayhead() }.controlSize(.small)
            }
            HStack(spacing: 10) {
                Text("Конец").frame(width: 48, alignment: .leading)
                Slider(value: Binding(get: { end }, set: { editor.setEnd($0) }), in: 0...duration, step: frameStep)
                    .accessibilityLabel("Конец фрагмента буфера")
                Text(frameClock(end)).monospacedDigit().frame(width: 85)
                Button("Из плеера") { editor.setEndAtPlayhead() }.controlSize(.small)
            }
            HStack {
                Text("В плеере: " + frameClock(currentTime)).foregroundStyle(Theme.muted).monospacedDigit()
                Spacer()
                Button("Просмотреть фрагмент") {
                    editor.seek(start, resume: true)
                }.controlSize(.small)
            }
        }.font(.system(size: 11)).buttonStyle(.bordered).disabled(model.saving || player == nil)
    }
    private func seek(_ seconds: Double) {
        editor.seek(seconds)
    }
}
