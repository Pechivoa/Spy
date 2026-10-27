import SwiftUI
import AVKit
import Combine

/// One editing session drives the inline sheet and its same-Space full-size view.
/// The source player/item are never replaced when the presentation changes.
@MainActor final class PlayerEditingState: ObservableObject {
    @Published private(set) var duration: Double = 0
    @Published private(set) var frameDuration: Double = 1.0 / 60
    @Published private(set) var rangeStart: Double = 0
    @Published private(set) var rangeEnd: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isLooping = false
    @Published private(set) var isPlaying = false
    @Published private(set) var microphoneEnabled = true
    @Published private(set) var canOpenFullScreen = false
    @Published private(set) var isSaving = false
    @Published private(set) var isSeeking = false
    @Published private(set) var isStepping = false
    @Published private(set) var message: String?
    @Published private(set) var saveError: String?
    @Published private(set) var markers: [ClipMarker] = []
    @Published private(set) var audioControls: VideoAudioControls?

    private var player: AVPlayer?
    private weak var host: FullSizePlayerHost?
    private var periodicObservation: Any?
    private var boundaryObservation: Any?
    private var endObservation: NSObjectProtocol?
    private var rateObservation: NSKeyValueObservation?
    private var microphoneObservation: AnyCancellable?
    private var frameTask: Task<Void, Never>?
    private var stepTask: Task<Void, Never>?
    private var stepOrigin: Double?
    private var pendingStepCount = 0
    private var stepID = UUID()
    private enum PlayheadAction { case start, end, marker }
    private var pendingPlayheadActions: [PlayheadAction] = []
    private var sessionID = UUID()
    private var seekID = UUID()
    private var boundaryID = UUID()
    private var onRangeChanged: ((Double, Double) -> Void)?
    private var onMicrophoneChanged: ((Bool) -> Void)?
    private var onAddMarker: ((Double) -> Void)?
    private var onSave: (@MainActor (Double, Double, Bool) async throws -> String)?

    var canMuteMicrophone: Bool { audioControls?.canMuteMicrophone == true }
    var canAddMarker: Bool { onAddMarker != nil && player != nil && !isSaving }
    // minFrameDuration can describe the shortest jittery sample, not the frame
    // under the playhead. Selection validity uses the export timeline's tick.
    var minimumRange: Double { min(1.0 / 60_000, duration) }
    var canSave: Bool {
        onSave != nil && player != nil && !isSaving && !isSeeking && !isStepping && duration > 0 &&
        rangeEnd > rangeStart && rangeEnd - rangeStart >= minimumRange - 0.000001
    }

    func configure(player: AVPlayer?, duration: Double, frameRate: Double = 60,
                   audioControls: VideoAudioControls? = nil, rangeStart: Double = 0,
                   rangeEnd: Double? = nil, markers: [ClipMarker] = [],
                   onRangeChanged: ((Double, Double) -> Void)? = nil,
                   onMicrophoneChanged: ((Bool) -> Void)? = nil,
                   onAddMarker: ((Double) -> Void)? = nil,
                   onSave: (@MainActor (Double, Double, Bool) async throws -> String)? = nil) {
        detach()
        guard let player, duration.isFinite, duration > 0 else { return }
        self.player = player
        self.duration = duration
        self.frameDuration = 1 / (frameRate.isFinite && frameRate > 0 ? frameRate : 60)
        self.audioControls = audioControls
        self.microphoneEnabled = audioControls?.microphoneEnabled ?? true
        self.onRangeChanged = onRangeChanged; self.onMicrophoneChanged = onMicrophoneChanged
        self.onAddMarker = onAddMarker; self.onSave = onSave
        setRange(start: rangeStart, end: rangeEnd ?? duration)
        setMarkers(markers)
        currentTime = playhead()
        isPlaying = player.rate > 0
        let session = sessionID
        periodicObservation = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 60_000), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.sessionID == session, time.isNumeric, !self.isSeeking, !self.isStepping else { return }
                self.currentTime = self.playhead()
            }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.sessionID == session else { return }
                self.isPlaying = self.player?.rate ?? 0 > 0
            }
        }
        if let audioControls {
            microphoneObservation = audioControls.$microphoneEnabled.sink { [weak self] enabled in
                Task { @MainActor in
                    guard let self, self.sessionID == session, self.microphoneEnabled != enabled else { return }
                    self.microphoneEnabled = enabled; self.onMicrophoneChanged?(enabled)
                }
            }
        }
        if let item = player.currentItem {
            endObservation = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sessionID == session else { return }
                    self.reachedRangeEnd()
                }
            }
            frameTask = Task { [weak self] in
                guard let track = try? await item.asset.loadTracks(withMediaType: .video).first else { return }
                let minimum = try? await track.load(.minFrameDuration)
                let rate = try? await track.load(.nominalFrameRate)
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                let sourceFrame = minimum?.seconds ?? 0
                if sourceFrame.isFinite, sourceFrame > 0, sourceFrame <= 1 {
                    self.frameDuration = sourceFrame
                } else if let rate, rate.isFinite, rate > 0 {
                    self.frameDuration = 1 / Double(rate)
                }
                let previous = (self.rangeStart, self.rangeEnd)
                self.setRange(start: previous.0, end: previous.1)
                if self.rangeStart != previous.0 || self.rangeEnd != previous.1 { self.publishRange() }
            }
        }
        installBoundary()
        refreshFullScreenAvailability()
    }

    func detach() {
        host?.presentation.close(returnFocus: false)
        sessionID = UUID(); seekID = UUID(); boundaryID = UUID()
        frameTask?.cancel(); frameTask = nil; stepTask?.cancel(); stepTask = nil
        if let periodicObservation { player?.removeTimeObserver(periodicObservation); self.periodicObservation = nil }
        if let boundaryObservation { player?.removeTimeObserver(boundaryObservation); self.boundaryObservation = nil }
        if let endObservation { NotificationCenter.default.removeObserver(endObservation); self.endObservation = nil }
        rateObservation?.invalidate(); rateObservation = nil; microphoneObservation = nil
        player = nil; audioControls = nil
        onRangeChanged = nil; onMicrophoneChanged = nil; onAddMarker = nil; onSave = nil
        duration = 0; rangeStart = 0; rangeEnd = 0; currentTime = 0
        isLooping = false; isPlaying = false; isSaving = false
        isSeeking = false; isStepping = false; stepOrigin = nil; pendingStepCount = 0; pendingPlayheadActions = []
        canOpenFullScreen = false; message = nil; saveError = nil; markers = []
    }

    func attachHost(_ value: FullSizePlayerHost) {
        let alreadyAttached = host === value
        host = value
        if alreadyAttached, canOpenFullScreen == (player != nil && value.playerView.player === player) { return }
        // NSViewRepresentable calls this during SwiftUI updates. Publish on the
        // next main-actor turn rather than mutating view state while rendering.
        Task { @MainActor [weak self, weak value] in
            guard let self, let value, self.host === value else { return }
            self.refreshFullScreenAvailability()
        }
    }
    func detachHost(_ value: FullSizePlayerHost) {
        guard host === value else { return }
        host = nil
        Task { @MainActor [weak self] in self?.refreshFullScreenAvailability() }
    }
    @discardableResult func openFullScreen() -> Bool {
        guard let host, player != nil, host.playerView.player === player else { return false }
        return host.presentation.present(host)
    }
    private func refreshFullScreenAvailability() {
        let available = player != nil && host?.playerView.player === player
        if canOpenFullScreen != available { canOpenFullScreen = available }
    }

    /// Synchronize external sliders without echoing their changes back to SwiftUI.
    func setRange(start: Double, end: Double) {
        guard duration > 0 else { return }
        let first = start.isFinite ? max(0, min(start, duration - minimumRange)) : 0
        let last = end.isFinite ? max(first + minimumRange, min(end, duration)) : duration
        if rangeStart == first && rangeEnd == last { return }
        rangeStart = first; rangeEnd = last; saveError = nil; message = nil
        installBoundary()
    }
    func setStart(_ seconds: Double) {
        guard !isSaving else { return }
        setRange(start: min(snapped(seconds), max(0, rangeEnd - minimumRange)), end: rangeEnd)
        publishRange()
        seek(rangeStart)
    }
    func setEnd(_ seconds: Double) {
        guard !isSaving else { return }
        setRange(start: rangeStart, end: max(snapped(seconds), rangeStart + minimumRange))
        publishRange()
        seek(max(rangeStart, rangeEnd - frameDuration))
    }
    func setStartAtPlayhead() {
        guard !isSaving else { return }
        if isSeeking || isStepping { pendingPlayheadActions.append(.start); return }
        resolveFrameBoundary(.start)
    }
    func setEndAtPlayhead() {
        guard !isSaving else { return }
        if isSeeking || isStepping { pendingPlayheadActions.append(.end); return }
        resolveFrameBoundary(.end)
    }
    func selectAll() { setRange(start: 0, end: duration); publishRange() }
    func setMarkers(_ value: [ClipMarker]) {
        markers = value.filter { $0.seconds.isFinite && $0.seconds >= 0 && $0.seconds <= duration }.sorted { $0.seconds < $1.seconds }
    }
    func addMarker() {
        guard canAddMarker else { return }
        if isSeeking || isStepping { pendingPlayheadActions.append(.marker); return }
        onAddMarker?(playhead())
    }
    func setMicrophoneEnabled(_ value: Bool) {
        guard canMuteMicrophone, !isSaving else { return }
        audioControls?.microphoneEnabled = value
        if microphoneEnabled != value { microphoneEnabled = value; onMicrophoneChanged?(value) }
    }
    func togglePlayback() {
        guard let player, !isSaving else { return }
        if player.rate > 0 { player.pause(); isPlaying = false }
        else if playhead() >= rangeEnd - 0.000001 || (isLooping && playhead() < rangeStart) { seek(rangeStart, resume: true) }
        else { player.play(); isPlaying = true }
    }
    func setLooping(_ value: Bool) {
        guard !isSaving else { return }
        isLooping = value
        installBoundary()
        if value, playhead() < rangeStart || playhead() >= rangeEnd {
            seek(rangeStart, resume: player?.rate ?? 0 > 0)
        }
    }
    func seek(_ seconds: Double, resume: Bool = false) {
        performSeek(seconds, resume: resume, keepPlayheadActions: false)
    }
    private func performSeek(_ seconds: Double, resume: Bool, keepPlayheadActions: Bool) {
        guard let player, seconds.isFinite else { return }
        if !keepPlayheadActions { pendingPlayheadActions = [] }
        stepTask?.cancel(); stepTask = nil; stepOrigin = nil; pendingStepCount = 0; isStepping = false
        player.pause(); isPlaying = false
        let target = clampTime(seconds), request = UUID(), session = sessionID
        seekID = request; currentTime = target; isSeeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] done in
            Task { @MainActor in
                guard let self, let player, self.sessionID == session, self.seekID == request, self.player === player else { return }
                self.isSeeking = false
                self.currentTime = self.clampTime(player.currentTime().seconds)
                if done {
                    if resume { player.play(); self.isPlaying = true }
                    self.performPendingPlayheadActions()
                } else { self.pendingPlayheadActions = [] }
            }
        }
    }
    func stepFrames(_ count: Int) {
        guard let player, let item = player.currentItem, count != 0, !isSaving else { return }
        let origin = stepOrigin ?? playhead()
        stepOrigin = origin
        pendingStepCount = max(-120, min(120, pendingStepCount + max(-120, min(120, count))))
        let offset = pendingStepCount, session = sessionID, request = UUID()
        player.pause(); player.currentItem?.cancelPendingSeeks()
        isPlaying = false; seekID = UUID(); isSeeking = false; stepID = request; isStepping = true
        stepTask?.cancel()
        let movie = item.asset, totalDuration = duration, sourceFrame = frameDuration
        stepTask = Task { [weak self, weak player] in
            do {
                let target = try await SourceFrameStepper.targetTime(asset: movie, current: origin, offset: offset,
                    duration: totalDuration, frameDuration: sourceFrame)
                guard !Task.isCancelled, let self, let player, self.sessionID == session, self.stepID == request, self.player === player else { return }
                self.performSeek(target, resume: false, keepPlayheadActions: true)
            } catch {
                guard !Task.isCancelled, let self, self.sessionID == session, self.stepID == request else { return }
                self.isStepping = false; self.stepOrigin = nil; self.pendingStepCount = 0; self.pendingPlayheadActions = []
                self.saveError = "Не удалось перейти к соседнему кадру: " + error.localizedDescription
            }
        }
    }

    func saveSelection() async {
        guard canSave, let onSave else { return }
        let selectedStart = rangeStart, selectedEnd = rangeEnd, microphone = microphoneEnabled, session = sessionID
        isSaving = true; message = nil; saveError = nil; player?.pause(); isPlaying = false
        defer { if sessionID == session { isSaving = false } }
        do {
            let result = try await onSave(selectedStart, selectedEnd, microphone)
            if sessionID == session { message = result }
        } catch {
            if sessionID == session { saveError = error.localizedDescription }
        }
    }

    private func playhead() -> Double {
        if isSeeking { return currentTime }
        guard let player else { return currentTime }
        let time = player.currentTime()
        return time.isNumeric ? clampTime(time.seconds) : currentTime
    }
    private func clampTime(_ seconds: Double) -> Double { seconds.isFinite ? max(0, min(duration, seconds)) : 0 }
    private func snapped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        if abs(seconds - duration) < 0.000001 { return duration }
        return clampTime((seconds / frameDuration).rounded() * frameDuration)
    }
    private func publishRange() { onRangeChanged?(rangeStart, rangeEnd) }
    private func performPendingPlayheadActions() {
        let actions = pendingPlayheadActions; pendingPlayheadActions = []
        for action in actions {
            switch action {
            case .start: setStartAtPlayhead()
            case .end: setEndAtPlayhead()
            case .marker: addMarker()
            }
        }
    }
    private func resolveFrameBoundary(_ action: PlayheadAction) {
        guard let player, let item = player.currentItem else { return }
        player.pause(); isPlaying = false
        let position = playhead(), session = sessionID, request = UUID()
        let movie = item.asset, total = duration, frameHint = frameDuration
        stepTask?.cancel(); stepOrigin = nil; pendingStepCount = 0
        stepID = request; isStepping = true
        stepTask = Task { [weak self, weak player] in
            do {
                let bounds = try await SourceFrameStepper.frameBounds(asset: movie, current: position,
                    duration: total, frameDuration: frameHint)
                guard !Task.isCancelled, let self, let player, self.sessionID == session,
                      self.stepID == request, self.player === player else { return }
                self.stepTask = nil; self.isStepping = false
                switch action {
                case .start:
                    self.setRange(start: bounds.start, end: self.rangeEnd > bounds.start ? self.rangeEnd : bounds.end)
                case .end:
                    self.setRange(start: self.rangeStart < bounds.end ? self.rangeStart : bounds.start, end: bounds.end)
                case .marker: break
                }
                self.publishRange()
                self.performPendingPlayheadActions()
            } catch {
                guard !Task.isCancelled, let self, self.sessionID == session, self.stepID == request else { return }
                self.isStepping = false; self.pendingPlayheadActions = []
                self.saveError = "Не удалось определить границу кадра: " + error.localizedDescription
            }
        }
    }
    private func installBoundary() {
        if let boundaryObservation { player?.removeTimeObserver(boundaryObservation); self.boundaryObservation = nil }
        guard let player, rangeEnd > rangeStart else { return }
        let boundary = UUID(), session = sessionID
        boundaryID = boundary
        boundaryObservation = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: rangeEnd, preferredTimescale: 60_000))], queue: .main) { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionID == session, self.boundaryID == boundary else { return }
                self.reachedRangeEnd()
            }
        }
    }
    private func reachedRangeEnd() {
        guard !isSaving, player != nil else { return }
        if isLooping { seek(rangeStart, resume: true) }
        else { player?.pause(); isPlaying = false; currentTime = rangeEnd }
    }
}

/// Read only a small compressed-packet window around the playhead. This works
/// for local AVComposition segments without needing a visible AVPlayerLayer.
enum SourceFrameStepper {
    struct Bounds {
        let start: Double
        let end: Double
    }
    private struct Window {
        let frames: [Int64]
        let first: Double
        let last: Double
    }
    static func targetTime(asset: AVAsset, current: Double, offset: Int, duration: Double, frameDuration: Double) async throws -> Double {
        guard (-120...120).contains(offset) else { throw SpyError.message("Недопустимый шаг по кадрам.") }
        let radius = min(10, max(0.5, Double(abs(offset) + 4) * frameDuration))
        let window = try await readWindow(asset: asset, current: current, duration: duration, frameDuration: frameDuration, radius: radius)
        let index = frameIndex(window.frames, current: current)
        let requested = index + offset
        if requested < 0 && window.first > 0 || requested >= window.frames.count && window.last < duration {
            throw SpyError.message("Между соседними кадрами слишком большой разрыв. Переместите ползунок ближе к нужному моменту.")
        }
        return Double(window.frames[max(0, min(window.frames.count - 1, requested))]) / 60_000
    }

    /// Return the interval of the actual sample under the playhead. A sample's
    /// exclusive end is its next output PTS, not a nominal/minimum frame hint.
    static func frameBounds(asset: AVAsset, current: Double, duration: Double, frameDuration: Double) async throws -> Bounds {
        var radius = min(10, max(0.5, 5 * frameDuration))
        while true {
            try Task.checkCancellation()
            let window = try await readWindow(asset: asset, current: current, duration: duration, frameDuration: frameDuration, radius: radius)
            let index = frameIndex(window.frames, current: current)
            let start = Double(window.frames[index]) / 60_000
            if index + 1 < window.frames.count {
                return Bounds(start: start, end: Double(window.frames[index + 1]) / 60_000)
            }
            if window.last >= duration { return Bounds(start: start, end: duration) }
            guard radius < 10 else { throw SpyError.message("Следующий кадр слишком далеко. Переместите ползунок ближе к нужному моменту.") }
            radius = min(10, radius * 2)
        }
    }
    private static func frameIndex(_ frames: [Int64], current: Double) -> Int {
        let playhead = Int64((current * 60_000).rounded())
        return frames.lastIndex(where: { $0 <= playhead }) ?? 0
    }
    private static func readWindow(asset: AVAsset, current: Double, duration: Double, frameDuration: Double, radius: Double) async throws -> Window {
        guard current.isFinite, duration.isFinite, duration > 0, frameDuration.isFinite, frameDuration > 0,
              current >= 0, current <= duration, duration < Double(Int64.max / 60_000) else { throw SpyError.message("Недопустимое время кадра.") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("В ролике нет видеодорожки.") }
        let first = max(0, current - radius), last = min(duration, current + radius)
        let task = Task.detached(priority: .userInitiated) { () throws -> Window in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw SpyError.message("Видеодорожка недоступна для покадрового просмотра.") }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: first, preferredTimescale: 60_000),
                duration: CMTime(seconds: max(frameDuration, last - first), preferredTimescale: 60_000))
            guard reader.startReading() else { throw reader.error ?? SpyError.message("Не удалось прочитать кадры.") }
            var ticks: Set<Int64> = []
            var samples = 0
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                samples += 1
                if samples > 4096 { reader.cancelReading(); throw SpyError.message("Превышен безопасный размер покадрового запроса.") }
                // Compressed AVComposition buffers retain source PTS and carry
                // the edit's mapped timeline in outputPTS. Reader edit-boundary
                // markers have no media samples and must not become fake frames.
                guard sample.numSamples > 0 else { continue }
                let time = sample.outputPresentationTimeStamp
                guard time.isNumeric else { continue }
                let seconds = time.seconds
                guard seconds >= 0, seconds < duration else { continue }
                ticks.insert(Int64((seconds * 60_000).rounded()))
            }
            guard reader.status == .completed else { throw reader.error ?? SpyError.message("Не удалось дочитать соседние кадры.") }
            let frames = ticks.sorted()
            guard !frames.isEmpty else { throw SpyError.message("Возле выбранного времени нет кадров.") }
            return Window(frames: frames, first: first, last: last)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

struct FullscreenEditingToolbar: View {
    @ObservedObject var editor: PlayerEditingState
    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Button { editor.togglePlayback() } label: { Label(editor.isPlaying ? "Пауза" : "Смотреть", systemImage: editor.isPlaying ? "pause.fill" : "play.fill") }
                Button { editor.stepFrames(-1) } label: { Label("Кадр назад", systemImage: "backward.frame") }
                    .accessibilityLabel("Предыдущий кадр")
                Button { editor.stepFrames(1) } label: { Label("Кадр вперёд", systemImage: "forward.frame") }
                    .accessibilityLabel("Следующий кадр")
                Text(frameClock(editor.currentTime) + " / " + frameClock(editor.duration)).monospacedDigit().foregroundStyle(Theme.muted)
                Spacer()
                Button("Весь ролик") { editor.selectAll() }
                Text("Фрагмент: " + frameClock(max(0, editor.rangeEnd - editor.rangeStart))).monospacedDigit()
            }
            rangeRow("Начало", value: editor.rangeStart, onChange: editor.setStart, usePlayhead: editor.setStartAtPlayhead)
            rangeRow("Конец", value: editor.rangeEnd, onChange: editor.setEnd, usePlayhead: editor.setEndAtPlayhead)
            HStack(spacing: 15) {
                Toggle("Повтор A–B", isOn: Binding(get: { editor.isLooping }, set: editor.setLooping)).toggleStyle(.checkbox)
                if editor.canMuteMicrophone {
                    Toggle("Микрофон в видео", isOn: Binding(get: { editor.microphoneEnabled }, set: editor.setMicrophoneEnabled)).toggleStyle(.switch)
                }
                if editor.canAddMarker { Button { editor.addMarker() } label: { Label("Метка", systemImage: "bookmark") } }
                Spacer()
                Button { Task { await editor.saveSelection() } } label: {
                    HStack(spacing: 7) {
                        if editor.isSaving { ProgressView().controlSize(.small) }
                        Text(editor.isSaving ? "Сохраняется…" : "Сохранить фрагмент")
                    }
                }.buttonStyle(.borderedProminent).disabled(!editor.canSave)
            }
            if !editor.markers.isEmpty {
                MomentMarkerStrip(markers: editor.markers, onSeek: { editor.seek($0) })
            }
            if let error = editor.saveError {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            } else if let message = editor.message {
                Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.green).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12)).buttonStyle(.bordered).controlSize(.small)
        .padding(15).background(Theme.panel.opacity(0.97)).clipShape(RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white).preferredColorScheme(.dark).tint(Theme.accent)
        .disabled(editor.isSaving)
    }
    private func rangeRow(_ title: String, value: Double, onChange: @escaping (Double) -> Void, usePlayhead: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...max(0.000001, editor.duration), step: editor.frameDuration)
                .accessibilityLabel(title + " фрагмента в полноэкранном режиме")
            Text(frameClock(value)).monospacedDigit().frame(width: 85)
            Button("Текущий кадр", action: usePlayhead)
        }
    }
}
