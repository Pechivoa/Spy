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
    var recoveryOrigin: URL? = nil
    var audioGains = AudioLevels()
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
        bufferPreview != nil && bufferPreview?.recoveryOrigin == nil && recording && !busy && !saving && !shuttingDown &&
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
            replacement.audioGains = previous.audioGains
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
        if current.audioGains == AudioLevels(), let savedURL = (microphoneEnabled ? current.savedRanges : current.mutedSavedRanges)[range], FileManager.default.fileExists(atPath: savedURL.path) {
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
                try await playback.export(range: range, to: partial, separateAudio: preview.separateAudio, editableMicrophone: true, microphoneEnabled: microphoneEnabled, gains: current.audioGains)
            } else if !microphoneEnabled || current.audioGains != AudioLevels() {
                let source = try await EditableVideoAudio.load(url: preview.clip.url)
                try await source.export(to: partial, start: range.start, end: range.end, microphoneEnabled: microphoneEnabled, levels: current.audioGains)
            } else if entireBuffer {
                try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: preview.clip.url, to: partial) }.value
            } else {
                try await ClipTrimmer.export(source: preview.clip.url, start: range.start, end: range.end, to: partial)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            storeMarkers(MarkerTimeline.selected(current.momentMarkers, start: range.start, end: range.end), for: destination)
            if current.audioGains == AudioLevels(), microphoneEnabled { bufferPreview?.savedRanges[range] = destination }
            else if current.audioGains == AudioLevels() { bufferPreview?.mutedSavedRanges[range] = destination }
            if entireBuffer && microphoneEnabled && current.audioGains == AudioLevels() { bufferPreview?.savedURL = destination }
            if current.recoveryOrigin == nil || current.snapshot?.captureSessionID != nil { sessions.saved(destination, session: current.snapshot?.captureSessionID) }
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
        guard model.bufferPreview?.audioGains == AudioLevels(), let range, let url = (microphoneEnabled ? model.bufferPreview?.savedRanges : model.bufferPreview?.mutedSavedRanges)?[range],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var body: some View {
        PreviewWorkspace(player: player, title: "Просмотр буфера", fullScreenID: "Spy.BufferPreview.FullScreen",
                         editor: editor, audioControls: audioControls, busy: model.saving,
                         header: { previewHeader }, filmstrip: {
            TimelineThumbnailStrip(asset: preview.asset, assetID: preview.id.uuidString, duration: duration,
                                   selectionStart: start, selectionEnd: end, onSeek: seek)
            MomentMarkerStrip(markers: momentMarkers, onSeek: seek)
        }, footer: { previewFooter })
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
                sound.systemGain = Double(preview.audioGains.system); sound.microphoneGain = Double(preview.audioGains.microphone)
                sound.onGainsChanged = { [weak sound, weak model] in
                    guard let sound, let model, model.bufferPreview?.id == previewID else { return }
                    model.bufferPreview?.audioGains = sound.gains
                }
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
                if preview.recoveryOrigin == nil { player?.play() }
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

    private var previewHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.recoveryOrigin == nil ? "Предпросмотр буфера" : "Просмотр восстановления")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(preciseClock(preview.clip.duration)) · \(fileSize(preview.clip.bytes)) · снимок на \(preview.snapshotTimeLabel)")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if preview.recoveryOrigin == nil {
                Button {
                    player?.pause(); saveError = nil
                    let selectedMicrophone = microphoneEnabled
                    Task {
                        do { try await model.refreshBufferPreview(preview, microphoneEnabled: selectedMicrophone) }
                        catch { saveError = error.localizedDescription }
                    }
                } label: { Label(model.preparingBufferPreview ? "Обновляю…" : "Обновить", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!model.canRefreshBufferPreview)
                    .help("Получить новые кадры. Границы фрагмента будут сброшены.")
            }
        }
    }
    private var previewFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let playbackError { Text(playbackError).foregroundStyle(Theme.danger).font(.system(size: 11)).textSelection(.enabled) }
            if let saveError { Text(saveError).foregroundStyle(Theme.danger).font(.system(size: 11)).textSelection(.enabled) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(savedURL != nil ? "Сохранено в библиотеку" : "Ещё не сохранено")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(savedURL == nil ? Color.white : Theme.green)
                    Text(preview.recoveryOrigin != nil ? "Исходные сегменты восстановления сохраняются." :
                         model.recording ? "Повтор продолжает запись. Здесь — зафиксированный снимок." : "Запись остановлена. Сохраните нужный фрагмент.")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer(minLength: 8)
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
                    HStack(spacing: 6) {
                        if model.saving { ProgressView().controlSize(.small) }
                        Image(systemName: savedURL == nil ? "square.and.arrow.down" : "checkmark")
                        Text(savedURL != nil ? "Сохранено" : model.preparingBufferPreview ? "Обновляю…" : model.saving ? "Сохраняется…" : entireBuffer ? "Сохранить видео" : "Сохранить фрагмент")
                    }
                }.buttonStyle(.borderedProminent).disabled(model.saving || !editor.canSave || savedURL != nil || range == nil)
                    .accessibilityIdentifier("Spy.BufferPreview.Save")
            }.buttonStyle(.bordered)
        }
    }
    private func seek(_ seconds: Double) {
        editor.seek(seconds)
    }
}
