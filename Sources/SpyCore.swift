import Foundation
import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox

enum Quality: String, CaseIterable, Identifiable, Codable {
    case compact, balanced, smooth, native
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "720p · 30 FPS"
        case .balanced: return "1080p · 30 FPS"
        case .smooth: return "1080p · 60 FPS"
        case .native: return "Нативное · 60 FPS"
        }
    }
    var fps: Int { self == .smooth || self == .native ? 60 : 30 }
    var bitrate: Int {
        switch self {
        case .compact: return 4_000_000
        case .balanced: return 8_000_000
        case .smooth: return 14_000_000
        case .native: return 28_000_000
        }
    }
    func dimensions(width: Int, height: Int) -> (Int, Int) {
        let maxHeight = self == .compact ? 720 : self == .native ? 2160 : 1080
        let scale = min(1, Double(maxHeight) / Double(max(1, height)), 3840.0 / Double(max(1, width)))
        return (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

struct RecordingConfig {
    var displayID: CGDirectDisplayID
    var quality: Quality
    var audio: Bool
    var microphone: Bool = false
    var seconds: Double
    var windowID: CGWindowID? = nil
    var microphoneID: String? = nil
    var excludedBundleIDs: Set<String> = []
    var microphoneCleanup: Bool = false
    var applicationAudioMode: ApplicationAudioMode = .all
    var applicationAudioBundleIDs: Set<String> = []
    var encoding: CaptureEncodingOptions = .init()
    var masks: [RecordingMask] = []
    var expectedWindowProcessID: pid_t? = nil
}

struct BufferStats {
    var seconds: Double = 0
    var bytes: Int64 = 0
    var frameCount: Int = 0
    var manualSeconds: Double = 0
    var manualBytes: Int64 = 0
    var actualFPS: Double = 0
    var droppedFrames: Int = 0
    var markerCount: Int = 0
    var sourceWarning: String? = nil
}

enum SpyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct Segment {
    let url: URL
    let start: CMTime
    let end: CMTime
    var seconds: Double { max(0, CMTimeGetSeconds(end - start)) }
}

struct SpySnapshot {
    let directory: URL
    let urls: [URL]
    let requestedSeconds: Double
    var skippedRecoveryFiles: [String] = []
    var sourceIntervals: [SpySourceInterval] = []
    var markers: [ReplayMarker] = []
    var captureSessionID: UUID? = nil
}

struct CaptureProgress {
    let sessionID: UUID
    let capturedSeconds: Double
    let sourceSeconds: Double?
    let isActive: Bool
    let isPaused: Bool
    var frameDuration: Double = 1.0 / 30
}

struct SpySourceInterval: Codable {
    let start: Double
    let end: Double
}

/// All encoder state lives on a single serial queue. Only compressed 5-second
/// files are retained; raw frames are never buffered for the replay duration.
final class SpyEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.spy.encoder", qos: .userInitiated)
    var onStats: ((BufferStats) -> Void)?
    var onTelemetry: ((CaptureTelemetry) -> Void)?
    private var healthTelemetry = CaptureTelemetry()
    var onFailure: ((String) -> Void)?
    var onDiagnostic: ((LogLevel, String, String) -> Void)?
    var onLevels: ((AudioMeter) -> Void)?
    var onApplicationAudioWarning: ((String?) -> Void)?
    /// Used by the isolated lifecycle regression; normal capture calls SCStream.
    var applicationAudioStartOverride: ((SCStream) async throws -> Void)?
    private var meter = AudioMeter()
    private var lastMeterTime: [AudioSource: Double] = [:]
    private var stream: SCStream?
    private var applicationAudioStream: SCStream?
    private var applicationAudioStreamStarted = false
    private var applicationAudioStreamStarting = false
    private var applicationAudioProcesses: Set<pid_t> = []
    private var applicationAudioDisplay: CGDirectDisplayID?
    private var applicationAudioWarning: String?
    private var usesApplicationAudio = false
    private var ticker: DispatchSourceTimer?
    private var latestPixel: CVPixelBuffer?
    private let ownedFrames = OwnedScreenFrames()
    private var sourceWarning: String?
    private var darkSince: Double?
    private var lastDarkCheck: Double = -.infinity
    private var lastCopyPressure: Double = -.infinity
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var currentURL: URL?
    private var segmentStart: CMTime = .invalid
    private var lastFrameTime: CMTime = .invalid
    private var lastStatsTime: Double = 0
    private var currentFrames = 0
    private var frameCount = 0
    private var markers: [ReplayMarker] = []
    private var markerCounter = 0
    private let microphoneFilter = MicrophoneCleanup()
    private var encoderPerformance = EncoderPerformanceTracker()
    private var lastAttemptTime = 0.0
    private var privacyPaused = false
    private var privacyFilterUpdating = false
    private var activeConfig: RecordingConfig?
    private var privacyBlockRequested = false
    private var privacyFilterRevision = 0
    private var requestedExclusions: Set<String>?
    private let privacyFilterQueue = PrivacyFilterQueue()
    private var segments: [Segment] = []
    private var finalizingSegments: [URL: (segment: Segment, manualFolder: URL?)] = [:]
    private var manualDirectory: URL?
    private var manualSegments: [Segment] = []
    private var manualMarkers: [ReplayMarker] = []
    private var manualStart: CMTime = .invalid
    private var manualPinnedBytes: Int64 = 0
    private var finishing = DispatchGroup()
    private var active = false
    private var startupError: Error?
    private var firstFrameWaiter: CheckedContinuation<Void, Error>?
    private var firstFrameCancellation: CaptureCancellationFlag?
    private var firstFrameTimeout: DispatchWorkItem?
    private var sessionID = UUID()
    private var closedContentSeconds: Double = 0
    private var sessionCreatedAt = Date()
    private var directory: URL?
    private var limitSeconds: Double = 300
    private var width = 1920
    private var height = 1080
    private var fps = 30
    private var bitrate = 8_000_000
    private var encoding = CaptureEncodingOptions()
    private var recordingMasks: [RecordingMask] = []
    private var includesAudio = true
    private var includesMicrophone = false
    private var segmentLength = 5.0
    private let cacheRoot: URL

    init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        super.init()
    }

    func start(_ config: RecordingConfig) async throws {
        try Task.checkCancellation()
        guard config.seconds > 0 else { throw SpyError.message("Выберите время повтора больше нуля.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let filter: SCContentFilter
        var windowProcessID: pid_t?
        let pixelsW: Int, pixelsH: Int
        if let windowID = config.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }), window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
                throw SpyError.message("Выбранное окно закрыто или недоступно. Обновите список окон.")
            }
            try WindowRecoveryIdentity.validate(expected: config.expectedWindowProcessID, actual: window.owningApplication?.processID)
            windowProcessID = window.owningApplication?.processID
            try CapturePrivacyPolicy.validateWindowOwner(window.owningApplication?.bundleIdentifier, selected: config.excludedBundleIDs, ownBundleID: Bundle.main.bundleIdentifier ?? "local.spy.mac")
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixelsW = Int(window.frame.width * CGFloat(filter.pointPixelScale))
            pixelsH = Int(window.frame.height * CGFloat(filter.pointPixelScale))
        } else {
            guard let display = content.displays.first(where: { $0.displayID == config.displayID }) else { throw SpyError.message("Выбранный экран отключён. Выберите другой экран.") }
            let excluded = content.applications.filter { CapturePrivacyPolicy.excludes($0.bundleIdentifier, selected: config.excludedBundleIDs, ownBundleID: Bundle.main.bundleIdentifier ?? "local.spy.mac") }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            // Core Graphics reports logical dimensions in some Retina modes.
            // Use the capture filter's scale to retain the real source pixels.
            pixelsW = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            pixelsH = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        }
        let (w, h) = config.quality.dimensions(width: pixelsW, height: pixelsH)
        let options = SCStreamConfiguration()
        options.width = w
        options.height = h
        options.minimumFrameInterval = CMTime(value: 1, timescale: Int32(config.quality.fps))
        options.pixelFormat = kCVPixelFormatType_32BGRA
        options.colorSpaceName = CGColorSpace.sRGB
        options.queueDepth = 5
        options.showsCursor = true
        options.scalesToFit = true
        options.capturesAudio = config.audio && config.applicationAudioMode == .all
        options.excludesCurrentProcessAudio = true
        options.sampleRate = 48_000
        options.channelCount = 2
        if #available(macOS 15.0, *) {
            options.captureMicrophone = config.microphone
            options.microphoneCaptureDeviceID = config.microphoneID
        } else if config.microphone { throw SpyError.message("Запись микрофона доступна на macOS 15 и новее.") }
        try queue.sync {
            try prepare(width: w, height: h, fps: config.quality.fps, bitrate: config.quality.bitrate, audio: config.audio, microphone: config.microphone, microphoneCleanup: config.microphoneCleanup, seconds: config.seconds, encoding: config.encoding, masks: config.masks)
            activeConfig = config
            activeConfig?.expectedWindowProcessID = windowProcessID
            usesApplicationAudio = config.audio && config.applicationAudioMode == .selected
        }
        do {
            let capture = SCStream(filter: filter, configuration: options, delegate: self)
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if config.audio && config.applicationAudioMode == .all { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if #available(macOS 15.0, *), config.microphone { try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            queue.sync { stream = capture }
            onDiagnostic?(.info, "ScreenCaptureKit", "Запуск потока: \(w)×\(h), \(config.quality.fps) FPS, система: \(config.audio), микрофон: \(config.microphone).")
            try await capture.startCapture()
            try Task.checkCancellation()
            if config.audio && config.applicationAudioMode == .selected {
                let id = queue.sync { sessionID }
                try await privacyFilterQueue.run { [self] in
                    await configureApplicationAudio(config, content: content, session: id)
                }
            }
            if queue.sync(execute: { privacyFilterUpdating }) {
                try await refreshPrivacyExclusions(queue.sync { requestedExclusions ?? config.excludedBundleIDs })
            }
            queue.async { [self] in
                guard active, !privacyBlockRequested, !privacyPaused, !privacyFilterUpdating else { return }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick(at: CMClockGetTime(CMClockGetHostTimeClock())) }
                ticker = timer
                timer.resume()
            }
            try await waitForFirstFrame()
        } catch {
            await stop(preserveForRecovery: true)
            throw error
        }
    }

    func requestPrivacyBlock(_ blocked: Bool) {
        let reconcile = queue.sync { () -> UUID? in
            privacyBlockRequested = blocked
            if blocked { latestPixel = nil; encoderPerformance.resumeWindow(); publishStats() }
            guard !blocked, active, usesApplicationAudio, !privacyPaused, !privacyFilterUpdating else { return nil }
            return sessionID
        }
        if let reconcile {
            Task { [weak self] in
                guard let self else { return }
                try? await self.privacyFilterQueue.run { [self] in
                    await self.startApplicationAudioStream(session: reconcile)
                }
            }
        }
    }

    func requestPrivacyFilter(_ ids: Set<String>) {
        queue.sync {
            requestedExclusions = ids; privacyFilterRevision += 1
            privacyFilterUpdating = true; latestPixel = nil
            encoderPerformance.resumeWindow(); publishStats()
        }
    }

    /// App audio owns a separate stream: narrowing it never narrows the video
    /// target or duplicates the microphone/system audio from the main stream.
    func refreshApplicationAudio() async throws {
        let id = queue.sync { sessionID }
        try await privacyFilterQueue.run { [self] in
            guard let config = queue.sync(execute: { () -> RecordingConfig? in
                guard active, sessionID == id, usesApplicationAudio, !privacyPaused,
                      !privacyBlockRequested, !privacyFilterUpdating else { return nil }
                return activeConfig
            }) else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard queue.sync(execute: { active && sessionID == id && !privacyFilterUpdating && !privacyBlockRequested && !privacyPaused }) else { throw CancellationError() }
            await configureApplicationAudio(config, content: content, session: id)
        }
    }

    private func configureApplicationAudio(_ config: RecordingConfig, content: SCShareableContent, session: UUID) async {
        guard queue.sync(execute: { active && sessionID == session }) else { return }
        let allowed = ApplicationAudioPolicy.allowedBundleIDs(selected: config.applicationAudioBundleIDs,
            excluded: config.excludedBundleIDs, ownBundleID: Bundle.main.bundleIdentifier)
        let apps = content.applications.filter { allowed.contains($0.bundleIdentifier.lowercased()) }
        let display = content.displays.first(where: { $0.displayID == config.displayID }) ?? content.displays.first
        let processes = Set(apps.map(\.processID))
        let requested = CapturePrivacyPolicy.normalizedIDs(config.applicationAudioBundleIDs)
        let missing = allowed.subtracting(Set(apps.map { $0.bundleIdentifier.lowercased() }))
        let blocked = requested.intersection(CapturePrivacyPolicy.normalizedIDs(config.excludedBundleIDs))
        let selectionWarning: String? = !blocked.isEmpty
            ? "Звук части выбранных приложений отключён настройками приватности. Остальные выбранные источники записываются."
            : !missing.isEmpty ? "Некоторые выбранные приложения пока недоступны. Записывается звук доступных; остальные приложения не подставляются." : nil
        if config.audio && config.applicationAudioMode == .selected && !apps.isEmpty,
           let display,
           await reuseApplicationAudioStream(processes: processes, display: display.displayID, warning: selectionWarning, session: session) {
            return
        }
        let previous = queue.sync { detachApplicationAudioStream() }
        if previous.started {
            do { try await previous.capture?.stopCapture() }
            catch { onDiagnostic?(.warning, "Остановка звука приложений", describeError(error)) }
        }
        guard queue.sync(execute: { active && sessionID == session }) else { return }
        guard config.audio && config.applicationAudioMode == .selected else {
            queue.sync { updateApplicationAudioWarning(nil) }; return
        }
        guard let display, !apps.isEmpty else {
            queue.sync {
                guard active, sessionID == session else { return }
                let detail = config.applicationAudioBundleIDs.isEmpty
                    ? "Приложения со звуком не выбраны. Системный звук сейчас не записывается."
                    : "Выбранные приложения не запущены или исключены приватностью. Их звук сейчас не записывается."
                updateApplicationAudioWarning(detail)
            }
            return
        }
        do {
            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            let options = SCStreamConfiguration()
            options.width = 2; options.height = 2
            options.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            options.queueDepth = 3
            options.capturesAudio = true; options.excludesCurrentProcessAudio = true
            options.sampleRate = 48_000; options.channelCount = 2
            let capture = SCStream(filter: filter, configuration: options, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            let accepted = queue.sync { () -> Bool in
                guard active, sessionID == session else { return false }
                applicationAudioStream = capture; applicationAudioProcesses = processes
                applicationAudioDisplay = display.displayID
                updateApplicationAudioWarning(selectionWarning)
                return true
            }
            guard accepted else { return }
            onDiagnostic?(.info, "Звук приложений", "Отдельный поток только выбранных приложений: " + apps.map(\.applicationName).sorted().joined(separator: ", ") + ". Источник изображения и микрофон не меняются.")
            if queue.sync(execute: { !privacyPaused && !privacyBlockRequested }) {
                await startApplicationAudioStream(session: session)
            }
        } catch {
            queue.sync {
                guard active, sessionID == session else { return }
                updateApplicationAudioWarning("Не удалось включить звук выбранных приложений. Видео и микрофон продолжаются. Обновите список или перезапустите повтор.")
            }
            onDiagnostic?(.warning, "Звук приложений", describeError(error))
        }
    }

    /// A matching process set only means its filter can be reused. The stream
    /// may still be dormant after configuration overlapped a transient privacy
    /// block, so reconciliation must also attempt the guarded start.
    private func reuseApplicationAudioStream(processes: Set<pid_t>, display: CGDirectDisplayID, warning: String?, session: UUID) async -> Bool {
        guard queue.sync(execute: {
            active && sessionID == session && applicationAudioStream != nil &&
                applicationAudioProcesses == processes && applicationAudioDisplay == display
        }) else { return false }
        queue.sync {
            guard active, sessionID == session else { return }
            updateApplicationAudioWarning(warning)
        }
        await startApplicationAudioStream(session: session)
        return true
    }

    private func startApplicationAudioStream(session: UUID, resuming: Bool = false) async {
        guard let capture = queue.sync(execute: { () -> SCStream? in
            guard active, sessionID == session, !privacyBlockRequested, !privacyFilterUpdating,
                  resuming || !privacyPaused, !applicationAudioStreamStarted,
                  !applicationAudioStreamStarting, let capture = applicationAudioStream else { return nil }
            applicationAudioStreamStarting = true
            return capture
        }) else { return }
        do {
            if let applicationAudioStartOverride { try await applicationAudioStartOverride(capture) }
            else { try await capture.startCapture() }
            let accepted = queue.sync { () -> Bool in
                guard sessionID == session, applicationAudioStream === capture else { return false }
                applicationAudioStreamStarting = false
                guard active, !privacyBlockRequested, !privacyFilterUpdating, resuming || !privacyPaused else { return false }
                applicationAudioStreamStarted = true
                return true
            }
            if !accepted {
                queue.sync { if sessionID == session && applicationAudioStream === capture { _ = detachApplicationAudioStream() } }
                try? await capture.stopCapture()
            }
        } catch {
            queue.sync {
                guard active, sessionID == session, applicationAudioStream === capture else { return }
                _ = detachApplicationAudioStream()
                updateApplicationAudioWarning("Звук выбранных приложений недоступен. Видео и микрофон продолжаются; звук остальных приложений не подставляется.")
            }
            try? await capture.stopCapture()
            onDiagnostic?(.warning, "Запуск звука приложений", describeError(error))
        }
    }

    /// Encoder queue only. Removing identity before stopping rejects late samples.
    private func detachApplicationAudioStream() -> (capture: SCStream?, started: Bool) {
        let result = (applicationAudioStream, applicationAudioStreamStarted)
        applicationAudioStream = nil; applicationAudioStreamStarted = false; applicationAudioStreamStarting = false
        applicationAudioProcesses = []; applicationAudioDisplay = nil
        meter.system = 0; onLevels?(meter)
        return result
    }

    private func updateApplicationAudioWarning(_ value: String?) {
        guard applicationAudioWarning != value else { return }
        applicationAudioWarning = value
        if let value { onDiagnostic?(.warning, "Звук приложений", value) }
        onApplicationAudioWarning?(value)
    }

    func refreshPrivacyExclusions(_ ids: Set<String>) async throws {
        let context = queue.sync { (stream, activeConfig, sessionID, privacyFilterRevision, requestedExclusions ?? ids) }
        guard let capture = context.0, let originalConfig = context.1 else { return }
        do { try await privacyFilterQueue.run { [self] in
        guard queue.sync(execute: { active && sessionID == context.2 && stream === capture && privacyFilterRevision == context.3 }) else { throw CancellationError() }
        var config = originalConfig
        config.excludedBundleIDs = context.4
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        if let windowID = config.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw SpyError.message("Выбранное окно больше недоступно.") }
            try WindowRecoveryIdentity.validate(expected: config.expectedWindowProcessID, actual: window.owningApplication?.processID)
            try CapturePrivacyPolicy.validateWindowOwner(window.owningApplication?.bundleIdentifier, selected: context.4, ownBundleID: Bundle.main.bundleIdentifier ?? "local.spy.mac")
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == config.displayID }) else { throw SpyError.message("Выбранный экран отключён.") }
            let excluded = content.applications.filter { CapturePrivacyPolicy.excludes($0.bundleIdentifier, selected: context.4, ownBundleID: Bundle.main.bundleIdentifier ?? "local.spy.mac") }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        }
        guard queue.sync(execute: { active && sessionID == context.2 && stream === capture }) else { throw CancellationError() }
        try await capture.updateContentFilter(filter)
        if config.audio && config.applicationAudioMode == .selected {
            await configureApplicationAudio(config, content: content, session: context.2)
        }
        let applied = queue.sync { () -> Bool in
            guard active, sessionID == context.2, stream === capture, privacyFilterRevision == context.3 else { return false }
            activeConfig = config; latestPixel = nil; privacyFilterUpdating = false
            return true
        }
        if applied { await startApplicationAudioStream(session: context.2) }
        } } catch {
            let current = queue.sync { active && sessionID == context.2 && stream === capture && privacyFilterRevision == context.3 }
            if !current { throw CancellationError() }
            throw error
        }
    }

    func pauseForPrivacy() async throws {
        let captures = queue.sync { () -> (SCStream?, SCStream?, Bool) in
            guard active else { return (nil, nil, false) }
            privacyPaused = true; latestPixel = nil
            ticker?.cancel(); ticker = nil; closeSegment()
            let started = applicationAudioStreamStarted
            applicationAudioStreamStarted = false
            meter.system = 0; meter.microphone = 0; onLevels?(meter)
            return (stream, applicationAudioStream, started)
        }
        var stopError: Error?
        do { try await captures.0?.stopCapture() } catch { stopError = error }
        if captures.2 {
            do { try await captures.1?.stopCapture() } catch { if stopError == nil { stopError = error } }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishing.notify(queue: queue) { [self] in publishStats(); continuation.resume() }
        }
        if let stopError { throw stopError }
    }

    func resumeAfterPrivacy(excluding ids: Set<String>) async throws {
        let context = queue.sync { (stream, sessionID, active && privacyPaused) }
        guard context.2 else { return }
        if let capture = context.0 {
            guard queue.sync(execute: { active && sessionID == context.1 && stream === capture && !privacyBlockRequested }) else { return }
            do {
                queue.sync { privacyFilterUpdating = true; latestPixel = nil }
                var ready = false
                for _ in 0..<5 {
                    do { try await refreshPrivacyExclusions(ids); ready = true; break }
                    catch is CancellationError {
                        guard queue.sync(execute: { active && sessionID == context.1 && stream === capture && !privacyBlockRequested }) else {
                            try? await capture.stopCapture(); return
                        }
                    }
                }
                guard ready else { throw SpyError.message("Исключения ещё обновляются. Повторите продолжение записи.") }
                guard queue.sync(execute: { active && sessionID == context.1 && stream === capture && !privacyBlockRequested }) else { return }
                try await capture.startCapture()
                await startApplicationAudioStream(session: context.1, resuming: true)
            } catch {
                try? await capture.stopCapture()
                throw error
            }
            let current = queue.sync { () -> Bool in
                guard active, sessionID == context.1, stream === capture, !privacyBlockRequested else { return false }
                privacyPaused = false; encoderPerformance.resumeWindow()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick(at: CMClockGetTime(CMClockGetHostTimeClock())) }
                ticker = timer; timer.resume(); return true
            }
            if !current {
                try? await capture.stopCapture()
                let audio = queue.sync { detachApplicationAudioStream() }
                if audio.started { try? await audio.capture?.stopCapture() }
            } else {
                // A filter update may replace the audio stream while the old
                // resume start is suspended. Reconcile the latest identity only
                // after it is safe to run outside the paused state.
                try await privacyFilterQueue.run { [self] in
                    await startApplicationAudioStream(session: context.1)
                }
            }
        } else {
            queue.sync {
                guard active, !privacyBlockRequested else { return }
                privacyPaused = false; privacyFilterUpdating = false
                latestPixel = nil; encoderPerformance.resumeWindow()
            }
        }
    }

    private func prepare(width: Int, height: Int, fps: Int, bitrate: Int, audio: Bool, microphone: Bool = false, microphoneCleanup: Bool = false, seconds: Double, encoding: CaptureEncodingOptions = .init(), masks: [RecordingMask] = []) throws {
        guard !active else { throw SpyError.message("Буфер уже запущен.") }
        guard manualDirectory == nil else { throw SpyError.message("Сначала завершите предыдущую ручную запись.") }
        try encoding.validateHardwareSupport(width: width, height: height)
        try RecordingMaskProcessor.validate(masks)
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
        self.encoding = encoding; recordingMasks = masks
        microphoneFilter.enabled = microphoneCleanup; microphoneFilter.reset()
        encoderPerformance.reset(fps: fps); lastAttemptTime = 0
        privacyPaused = false
        usesApplicationAudio = false
        updateApplicationAudioWarning(nil)
        includesAudio = audio
        includesMicrophone = microphone
        limitSeconds = min(1800, max(0, seconds))
        sessionID = UUID()
        closedContentSeconds = 0
        sessionCreatedAt = Date()
        healthTelemetry = CaptureTelemetry(session: sessionID)
        healthTelemetry.wantsSystem = includesAudio; healthTelemetry.wantsMicrophone = includesMicrophone
        directory = cacheRoot.appendingPathComponent("replay-" + sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
        segments = []; finalizingSegments = [:]; latestPixel = nil; ownedFrames.reset(); sourceWarning = nil; darkSince = nil; lastDarkCheck = -.infinity; lastCopyPressure = -.infinity; frameCount = 0; markers = []; markerCounter = 0; lastStatsTime = 0; startupError = nil
        meter = AudioMeter(); lastMeterTime = [:]
        segmentStart = .invalid; lastFrameTime = .invalid
        persistCrashManifest()
        active = true
    }

    func updateLimit(_ seconds: Double) {
        queue.async { [self] in
            limitSeconds = min(1800, max(0, seconds))
            prune()
            publishStats()
        }
    }

    func stop(preserveForRecovery: Bool = false) async {
        let captures = queue.sync { () -> (SCStream?, SCStream?, Bool) in
            let capture = stream; stream = nil
            let audio = detachApplicationAudioStream()
            active = false
            privacyPaused = false; privacyFilterUpdating = false; activeConfig = nil
            ticker?.cancel(); ticker = nil
            resolveFirstFrame(.failure(CancellationError()))
            usesApplicationAudio = false; updateApplicationAudioWarning(nil)
            return (capture, audio.capture, audio.started)
        }
        do { try await captures.0?.stopCapture() }
        catch { onDiagnostic?(.warning, "Остановка потока", describeError(error)) }
        if captures.2 {
            do { try await captures.1?.stopCapture() }
            catch { onDiagnostic?(.warning, "Остановка звука приложений", describeError(error)) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                closeSegment()
                latestPixel = nil
                let oldDirectory = directory
                finishing.notify(queue: queue) { [self] in
                    if preserveForRecovery, let oldDirectory, !segments.isEmpty {
                        let retained = cacheRoot.appendingPathComponent("record-replay-failure-" + UUID().uuidString, isDirectory: true)
                        do {
                            let snapshot = SpySnapshot(directory: oldDirectory, urls: segments.map(\.url), requestedSeconds: limitSeconds,
                                sourceIntervals: segments.map { SpySourceInterval(start: $0.start.seconds, end: $0.end.seconds) }, markers: markers, captureSessionID: sessionID)
                            try MarkerSnapshotMetadata.persist(snapshot)
                            try JSONEncoder().encode(limitSeconds).write(to: oldDirectory.appendingPathComponent("replay-seconds.json"), options: .atomic)
                            try FileManager.default.moveItem(at: oldDirectory, to: retained)
                            onDiagnostic?(.warning, "Восстановление после ошибки", "Готовые сегменты буфера сохранены: " + retained.path)
                        } catch { onDiagnostic?(.error, "Восстановление после ошибки", "Буфер оставлен в " + oldDirectory.path + "\n" + describeError(error)) }
                    } else if let oldDirectory { try? FileManager.default.removeItem(at: oldDirectory) }
                    segments = []
                    directory = nil
                    ownedFrames.reset(); sourceWarning = nil
                    onStats?(BufferStats())
                    onLevels?(AudioMeter())
                    continuation.resume()
                }
            }
        }
    }

    func snapshot(seconds: Double) async throws -> SpySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard active else {
                    continuation.resume(throwing: SpyError.message("Сначала включите мгновенный повтор.")); return
                }
                let cutoff = lastFrameTime.isValid ? lastFrameTime + CMTime(value: 1, timescale: Int32(fps)) : .zero
                closeSegment()
                finishing.notify(queue: queue) { [self] in
                    do {
                        let available = segments.sorted { $0.start < $1.start }.filter { $0.end <= cutoff }
                        guard !available.isEmpty else { throw SpyError.message("Буфер ещё пуст. Подождите пару секунд.") }
                        let folder = cacheRoot.appendingPathComponent("save-" + UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        var urls: [URL] = []
                        do {
                            for segment in available {
                                let target = folder.appendingPathComponent(segment.url.lastPathComponent)
                                try FileManager.default.linkItem(at: segment.url, to: target)
                                urls.append(target)
                            }
                        } catch {
                            try? FileManager.default.removeItem(at: folder)
                            throw error
                        }
                        let snapshot = SpySnapshot(directory: folder, urls: urls, requestedSeconds: min(1800, max(0, seconds)), sourceIntervals: available.map { SpySourceInterval(start: $0.start.seconds, end: $0.end.seconds) }, markers: markers.filter { $0.sourceSeconds < cutoff.seconds }, captureSessionID: sessionID)
                        do { try MarkerSnapshotMetadata.persist(snapshot) }
                        catch { try? FileManager.default.removeItem(at: folder); throw error }
                        continuation.resume(returning: snapshot)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func beginManual() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard active, manualDirectory == nil else { throw SpyError.message("Захват недоступен или ручная запись уже идёт.") }
                    closeSegment()
                    let folder = cacheRoot.appendingPathComponent("record-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    manualDirectory = folder; manualSegments = []; manualMarkers = []; manualStart = .invalid; manualPinnedBytes = 0
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func finishManual() async throws -> SpySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let folder = manualDirectory else { continuation.resume(throwing: SpyError.message("Ручная запись не запущена.")); return }
                closeSegment()
                finishing.notify(queue: queue) { [self] in
                    let selected = manualSegments.sorted { $0.start < $1.start }
                    let selectedMarkers = manualMarkers
                    manualDirectory = nil; manualSegments = []; manualMarkers = []; manualStart = .invalid; manualPinnedBytes = 0
                    publishStats()
                    guard !selected.isEmpty else {
                        try? FileManager.default.removeItem(at: folder)
                        continuation.resume(throwing: SpyError.message("В ручной записи пока нет кадров.")); return
                    }
                    let snapshot = SpySnapshot(directory: folder, urls: selected.map(\.url), requestedSeconds: selected.reduce(0) { $0 + $1.seconds }, sourceIntervals: selected.map { SpySourceInterval(start: $0.start.seconds, end: $0.end.seconds) }, markers: selectedMarkers)
                    do { try MarkerSnapshotMetadata.persist(snapshot); continuation.resume(returning: snapshot) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard active, !privacyBlockRequested, !privacyFilterUpdating, CMSampleBufferIsValid(sampleBuffer) else { return }
        if outputType == .audio {
            guard usesApplicationAudio ? applicationAudioStream === stream : self.stream === stream else { return }
            appendAudio(sampleBuffer)
            return
        }
        guard self.stream === stream else { return }
        if outputType == .screen {
            healthTelemetry.screen = ProcessInfo.processInfo.systemUptime
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw) else { return }
            healthTelemetry.idle = status == .idle
            if status == .blank || status == .suspended || status == .stopped {
                latestPixel = nil
                closeSegment()
                encoderPerformance.resumeWindow()
                if !privacyPaused {
                    let detail = status == .blank ? "Выбранный экран не выдаёт изображение." : status == .suspended ? "Обновления выбранного экрана приостановлены macOS." : "Источник экрана остановлен."
                    updateSourceWarning(detail)
                    publishStats()
                }
                return
            }
            guard status == .complete || status == .started,
                  let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            do {
                guard let owned = try ownedFrames.copy(pixel) else {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastCopyPressure > 5 { lastCopyPressure = now; onDiagnostic?(.warning, "Кадры источника", "Кодировщик удерживает пул кадров. Входящий кадр пропущен без удержания поверхности macOS.") }
                    return
                }
                inspectSourceBrightness(owned)
                try RecordingMaskProcessor.apply(recordingMasks, to: owned)
                latestPixel = owned
            } catch { onDiagnostic?(.error, "Кадр экрана", describeError(error)); fail(error.localizedDescription) }
        } else if #available(macOS 15.0, *), outputType == .microphone {
            appendAudio(sampleBuffer, microphone: true)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.active, !self.privacyPaused else { return }
            if self.applicationAudioStream === stream {
                _ = self.detachApplicationAudioStream()
                self.updateApplicationAudioWarning("Поток звука выбранных приложений остановился. Видео и микрофон продолжаются; обновите список для повторного подключения.")
                self.onDiagnostic?(.warning, "Звук приложений", describeError(error))
                return
            }
            guard self.stream === stream else { return }
            self.onDiagnostic?(.error, "ScreenCaptureKit", describeError(error))
            self.fail("Захват остановлен: " + error.localizedDescription)
        }
    }

    private func updateSourceWarning(_ value: String?) {
        guard sourceWarning != value else { return }
        let previous = sourceWarning
        sourceWarning = value
        if let value { onDiagnostic?(.warning, "Изображение источника", value) }
        else if previous != nil { onDiagnostic?(.info, "Изображение источника", "Изображение выбранного источника восстановлено.") }
    }

    private func inspectSourceBrightness(_ pixel: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDarkCheck >= 1 else { return }
        lastDarkCheck = now
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), stride = CVPixelBufferGetBytesPerRow(pixel)
        var bright = 0, count = 0
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 24)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 40)) {
                let offset = y * stride + x * 4
                if max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 10 { bright += 1 }
                count += 1
            }
        }
        if count > 0 && Double(bright) / Double(count) < 0.005 {
            if darkSince == nil { darkSince = now }
            if now - (darkSince ?? now) >= 3 {
                updateSourceWarning("Источник передаёт почти чёрный кадр. Проверьте выбранный экран и полноэкранное приложение. Тёмная сцена сама по себе может быть нормальной.")
            }
        } else { darkSince = nil; updateSourceWarning(nil) }
    }

    private func openSegment(at timestamp: CMTime) throws {
        guard let directory else { throw SpyError.message("Нет папки буфера.") }
        let url = directory.appendingPathComponent(String(format: "%020lld.mov", Int64(timestamp.seconds * 1_000_000)))
        let encoder = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings = try encoding.videoSettings(width: width, height: height, fps: fps, defaultBitrate: bitrate)
        guard encoder.canApply(outputSettings: settings, forMediaType: .video) else {
            throw SpyError.message("Кодировщик не поддерживает выбранный формат видео. Выберите другое качество или формат.")
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        encoder.add(video)
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        var audio: AVAssetWriterInput?
        var mic: AVAssetWriterInput?
        if includesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = [audioTag(.system)]
            encoder.add(input); audio = input
        }
        if includesMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = true
            input.metadata = [audioTag(.microphone)]
            encoder.add(input); mic = input
        }
        guard encoder.startWriting() else { throw encoder.error ?? SpyError.message("Не удалось запустить кодирование.") }
        encoder.startSession(atSourceTime: timestamp)
        writer = encoder; videoInput = video; audioInput = audio; microphoneInput = mic; adaptor = pixelAdaptor
        currentURL = url; segmentStart = timestamp; currentFrames = 0
        if manualDirectory != nil && !manualStart.isValid { manualStart = timestamp }
    }

    private func tick(at timestamp: CMTime) {
        guard active, !privacyBlockRequested, !privacyPaused, !privacyFilterUpdating else { return }
        lastAttemptTime = timestamp.seconds
        guard let pixel = latestPixel else {
            if timestamp.seconds - lastStatsTime >= 1 { lastStatsTime = timestamp.seconds; publishStats() }
            return
        }
        do {
            if writer != nil, CMTimeGetSeconds(timestamp - segmentStart) >= segmentLength { closeSegment() }
            if writer == nil { try openSegment(at: timestamp) }
            guard let videoInput, let adaptor, videoInput.isReadyForMoreMediaData else {
                if writer?.status == .failed { throw writer?.error ?? SpyError.message("Ошибка кодировщика.") }
                encoderPerformance.record(at: timestamp.seconds, accepted: false)
                if timestamp.seconds - lastStatsTime >= 1 { lastStatsTime = timestamp.seconds; publishStats() }
                return
            }
            guard adaptor.append(pixel, withPresentationTime: timestamp) else {
                throw writer?.error ?? SpyError.message("Не удалось записать кадр.")
            }
            currentFrames += 1; frameCount += 1; lastFrameTime = timestamp
            healthTelemetry.encoded = ProcessInfo.processInfo.systemUptime
            encoderPerformance.record(at: timestamp.seconds, accepted: true)
            if frameCount == 1 {
                onDiagnostic?(.info, "Первый кадр", "Кадр принят \(encoding.codec == .hevc ? "HEVC" : "H.264")-кодировщиком: \(width)×\(height).")
                resolveFirstFrame(.success(()))
            }
            let now = CMTimeGetSeconds(timestamp)
            if now - lastStatsTime >= 1 {
                lastStatsTime = now
                prune(); publishStats()
                if let directory, let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
                   let free = values.volumeAvailableCapacityForImportantUsage, free < 512 * 1024 * 1024 {
                    throw SpyError.message("На диске осталось меньше 512 МБ. Освободите место и включите повтор снова.")
                }
            }
        } catch { onDiagnostic?(.error, "Кодирование видео", describeError(error)); fail(error.localizedDescription) }
    }

    private func appendAudio(_ rawSample: CMSampleBuffer, microphone: Bool = false) {
        guard active, !privacyBlockRequested, !privacyPaused, !privacyFilterUpdating else { return }
        var sample = rawSample
        if microphone && includesMicrophone && microphoneFilter.enabled {
            do { sample = try microphoneFilter.process(rawSample) }
            catch {
                microphoneFilter.enabled = false
                onDiagnostic?(.warning, "Очистка микрофона", "Очистка отключена для неподдерживаемого формата; голос продолжает записываться.\n" + describeError(error))
            }
        }
        if microphone { healthTelemetry.microphone = ProcessInfo.processInfo.systemUptime }
        else { healthTelemetry.system = ProcessInfo.processInfo.systemUptime }
        let source: AudioSource = microphone ? .microphone : .system
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        if (microphone ? includesMicrophone : includesAudio), timestamp - (lastMeterTime[source] ?? 0) >= 0.1 {
            let value = AudioMeter.rms(sample)
            if microphone { meter.microphone = value } else { meter.system = value }
            lastMeterTime[source] = timestamp; onLevels?(meter)
        }
        let input = microphone ? microphoneInput : audioInput
        guard (microphone ? includesMicrophone : includesAudio), writer?.status == .writing, let input, input.isReadyForMoreMediaData,
              segmentStart.isValid, CMSampleBufferGetPresentationTimeStamp(sample) >= segmentStart else { return }
        if !input.append(sample), let error = writer?.error { onDiagnostic?(.error, microphone ? "Кодирование микрофона" : "Кодирование системного звука", describeError(error)); fail(error.localizedDescription) }
    }

    private func audioTag(_ source: AudioSource) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataTitle
        item.value = source.rawValue as NSString
        return item
    }

    private func closeSegment() {
        guard let encoder = writer, let url = currentURL else { return }
        let start = segmentStart
        let end = lastFrameTime.isValid ? lastFrameTime + CMTime(value: 1, timescale: Int32(fps)) : start
        let frames = currentFrames
        let id = sessionID
        let pinnedFolder = manualDirectory
        let group = finishing
        if encoder.status == .writing, frames > 0 {
            closedContentSeconds += max(0, (end - start).seconds)
            finalizingSegments[url] = (Segment(url: url, start: start, end: end), pinnedFolder)
            encoder.endSession(atSourceTime: end)
            videoInput?.markAsFinished(); audioInput?.markAsFinished(); microphoneInput?.markAsFinished()
            group.enter()
            encoder.finishWriting { [weak self] in
                guard let self else { group.leave(); return }
                self.queue.async {
                    self.finalizingSegments.removeValue(forKey: url)
                    if encoder.status == .completed, self.sessionID == id {
                        self.segments.append(Segment(url: url, start: start, end: end))
                        self.segments.sort { $0.start < $1.start }
                        if let pinnedFolder, self.manualDirectory == pinnedFolder {
                            do {
                                let target = pinnedFolder.appendingPathComponent(String(format: "%020lld.mov", Int64(start.seconds * 1_000_000)))
                                try FileManager.default.linkItem(at: url, to: target)
                                self.manualSegments.append(Segment(url: target, start: start, end: end))
                                self.manualPinnedBytes += (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
                                self.persistManualMarkers()
                            } catch { self.onDiagnostic?(.error, "Ручная запись", describeError(error)); self.fail(error.localizedDescription) }
                        }
                        self.prune()
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        if self.active, self.sessionID == id {
                            if let error = encoder.error { self.onDiagnostic?(.error, "Запись сегмента", describeError(error)) }
                            self.fail(encoder.error?.localizedDescription ?? "Ошибка записи буфера.")
                        }
                    }
                    group.leave()
                }
            }
        } else {
            encoder.cancelWriting(); try? FileManager.default.removeItem(at: url)
        }
        writer = nil; videoInput = nil; audioInput = nil; microphoneInput = nil; adaptor = nil; currentURL = nil
        segmentStart = .invalid; currentFrames = 0
    }

    private func prune() {
        guard lastFrameTime.isValid else { persistCrashManifest(); return }
        // Retain captured content, not elapsed wall time. Lock/display pauses
        // leave timestamp gaps which must not evict the pre-pause video.
        let current = segmentStart.isValid ? max(0, lastFrameTime.seconds - segmentStart.seconds + 1.0 / Double(fps)) : 0
        let finalizing = finalizingSegments.values.map(\.segment)
        var retained = segments.reduce(current + finalizing.reduce(0) { $0 + $1.seconds }) { $0 + $1.seconds }
        while let first = segments.first, retained - first.seconds >= limitSeconds {
            retained -= first.seconds
            try? FileManager.default.removeItem(at: first.url); segments.removeFirst()
        }
        let evicted = CacheByteBudget.removalURLs(candidates: segments.map(\.url),
            reservedURLs: Array(finalizingSegments.keys) + (currentURL.map { [$0] } ?? []), limitBytes: encoding.cacheLimitBytes)
        for url in evicted {
            do { try FileManager.default.removeItem(at: url); segments.removeAll { $0.url == url } }
            catch { onDiagnostic?(.warning, "Лимит кэша", "Не удалось удалить старый сегмент кольца. " + describeError(error)) }
        }
        markers.removeAll { marker in
            !(segments + finalizing).contains(where: { marker.sourceSeconds >= $0.start.seconds && marker.sourceSeconds < $0.end.seconds }) &&
            !(segmentStart.isValid && marker.sourceSeconds >= segmentStart.seconds && marker.sourceSeconds <= lastFrameTime.seconds)
        }
        persistCrashManifest()
    }

    private func persistCrashManifest() {
        guard let directory else { return }
        let value = ReplayCrashManifest(createdAt: sessionCreatedAt, ownerPID: ProcessInfo.processInfo.processIdentifier, limitSeconds: limitSeconds, segments: segments.map { ReplayCrashManifest.Entry(file: $0.url.lastPathComponent, start: $0.start.seconds, end: $0.end.seconds) }, ownerStartedAt: ReplayCrashRecovery.ownerStartedAt, markers: markers, sessionID: sessionID)
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(ReplayCrashRecovery.manifestName), options: .atomic) }
        catch { onDiagnostic?(.warning, "Защита буфера", "Не удалось обновить данные восстановления; готовые видео остаются в кэше. " + describeError(error)) }
    }

    private func publishStats() {
        onTelemetry?(healthTelemetry)
        let now = CMTimeGetSeconds(lastFrameTime)
        if now - (lastMeterTime[.system] ?? 0) > 0.4 { meter.system = 0 }
        if now - (lastMeterTime[.microphone] ?? 0) > 0.4 { meter.microphone = 0 }
        onLevels?(meter)
        let current = segmentStart.isValid && lastFrameTime.isValid ? max(0, (lastFrameTime - segmentStart).seconds + 1.0 / Double(fps)) : 0
        let pending = finalizingSegments.values.reduce(0) { $0 + $1.segment.seconds }
        let seconds = segments.reduce(current + pending) { $0 + $1.seconds }
        var bytes: Int64 = 0
        for url in segments.map(\.url) + Array(finalizingSegments.keys) + (currentURL.map { [$0] } ?? []) {
            // URL resource values cache the first size (often zero while the
            // writer is active). File attributes always read the live size.
            if let values = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = values[.size] as? NSNumber { bytes += size.int64Value }
        }
        let manualPending = finalizingSegments.values.filter { $0.manualFolder == manualDirectory }.reduce(0) { $0 + $1.segment.seconds }
        let manualDuration = manualDirectory == nil ? 0 : manualSegments.reduce(current + manualPending) { $0 + $1.seconds }
        let manualFiles = manualDirectory != nil ? currentURL.map { [$0] } ?? [] : []
        let manualBytes = manualFiles.reduce(manualPinnedBytes) { sum, url in sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) }
        let performance = encoderPerformance.snapshot(at: lastAttemptTime > 0 ? lastAttemptTime : nil)
        onStats?(BufferStats(seconds: min(limitSeconds, seconds), bytes: bytes, frameCount: frameCount, manualSeconds: manualDuration, manualBytes: manualBytes, actualFPS: performance.actualFPS, droppedFrames: performance.droppedFrames, markerCount: manualDirectory == nil ? markers.count : manualMarkers.count, sourceWarning: sourceWarning))
    }

    func addMomentMarker() -> ReplayMarker? {
        queue.sync {
            guard active, !privacyBlockRequested, !privacyPaused, !privacyFilterUpdating, limitSeconds > 0 || manualDirectory != nil, lastFrameTime.isNumeric else { return nil }
            if let last = manualDirectory == nil ? markers.last : manualMarkers.last, lastFrameTime.seconds - last.sourceSeconds < 0.25 { return last }
            markerCounter += 1
            let current = segmentStart.isValid ? max(0, (lastFrameTime - segmentStart).seconds + 1.0 / Double(fps)) : 0
            let marker = ReplayMarker(sourceSeconds: lastFrameTime.seconds, date: Date(), title: "Момент \(markerCounter)", contentSeconds: max(0, closedContentSeconds + current - 1.0 / Double(fps)))
            markers.append(marker)
            if manualDirectory != nil { manualMarkers.append(marker); persistManualMarkers() }
            persistCrashManifest(); publishStats()
            return marker
        }
    }

    func captureProgress() -> CaptureProgress? {
        queue.sync {
            let current = segmentStart.isValid && lastFrameTime.isValid ? max(0, (lastFrameTime - segmentStart).seconds + 1.0 / Double(fps)) : 0
            return CaptureProgress(sessionID: sessionID, capturedSeconds: closedContentSeconds + current, sourceSeconds: lastFrameTime.isNumeric ? lastFrameTime.seconds : nil, isActive: active, isPaused: privacyPaused || privacyBlockRequested || privacyFilterUpdating, frameDuration: 1.0 / Double(fps))
        }
    }

    private func persistManualMarkers() {
        guard let folder = manualDirectory, !manualMarkers.isEmpty else { return }
        var sources = manualSegments.sorted { $0.start < $1.start }
        if segmentStart.isValid, lastFrameTime.isValid {
            let url = folder.appendingPathComponent(String(format: "%020lld.mov", Int64(segmentStart.seconds * 1_000_000)))
            sources.append(Segment(url: url, start: segmentStart, end: lastFrameTime + CMTime(value: 1, timescale: Int32(fps))))
        }
        let snapshot = SpySnapshot(directory: folder, urls: sources.map(\.url), requestedSeconds: sources.reduce(0) { $0 + $1.seconds }, sourceIntervals: sources.map { SpySourceInterval(start: $0.start.seconds, end: $0.end.seconds) }, markers: manualMarkers)
        do { try MarkerSnapshotMetadata.persist(snapshot) }
        catch { onDiagnostic?(.warning, "Метки ручной записи", describeError(error)) }
    }

    private func fail(_ message: String) {
        guard active else { return }
        active = false; ticker?.cancel(); ticker = nil
        startupError = SpyError.message(message)
        resolveFirstFrame(.failure(startupError!))
        onFailure?(message)
    }

    func windowOwnerProcessID() -> pid_t? { queue.sync { activeConfig?.expectedWindowProcessID } }

    func waitForFirstFrame(timeout: Double = 12) async throws {
        let cancelled = CaptureCancellationFlag()
        try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if cancelled.value { continuation.resume(throwing: CancellationError()); return }
                if let startupError { continuation.resume(throwing: startupError); return }
                guard active else { continuation.resume(throwing: CancellationError()); return }
                if frameCount > 0 { continuation.resume(); return }
                guard firstFrameWaiter == nil else { continuation.resume(throwing: SpyError.message("Проверка первого кадра уже выполняется.")); return }
                firstFrameWaiter = continuation
                firstFrameCancellation = cancelled
                let task = DispatchWorkItem { [weak self] in
                    self?.fail("Поток запущен, но кадры не поступают. Проверьте доступ к экрану и выбранный экран или окно, затем повторите запуск.")
                }
                firstFrameTimeout = task
                queue.asyncAfter(deadline: .now() + timeout, execute: task)
            }
        }
        }, onCancel: { [self] in
            cancelled.cancel()
            queue.async { [self] in
                if firstFrameCancellation === cancelled { resolveFirstFrame(.failure(CancellationError())) }
            }
        })
    }

    private func resolveFirstFrame(_ result: Result<Void, Error>) {
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        let waiter = firstFrameWaiter; firstFrameWaiter = nil
        firstFrameCancellation = nil
        waiter?.resume(with: result)
    }

    // Runs the real encoder and ring without requiring screen permissions.
    func beginTest(seconds: Double, audio: Bool = false, microphone: Bool = false, microphoneCleanup: Bool = false, encoding: CaptureEncodingOptions = .init(), masks: [RecordingMask] = []) throws {
        try queue.sync {
            segmentLength = 1
            try prepare(width: 320, height: 180, fps: 30, bitrate: 600_000, audio: audio, microphone: microphone, microphoneCleanup: microphoneCleanup, seconds: seconds, encoding: encoding, masks: masks)
        }
    }
    func testFrame(_ pixel: CVPixelBuffer, at time: CMTime) {
        queue.sync {
            do {
                if recordingMasks.isEmpty { latestPixel = pixel }
                else {
                    guard let owned = try ownedFrames.copy(pixel) else { return }
                    try RecordingMaskProcessor.apply(recordingMasks, to: owned)
                    latestPixel = owned
                }
                tick(at: time)
            } catch { onDiagnostic?(.error, "Приватные области", describeError(error)); fail(error.localizedDescription) }
        }
    }
    func testAudio(_ sample: CMSampleBuffer, microphone: Bool = false) { queue.sync { appendAudio(sample, microphone: microphone) } }
    func testStats() -> BufferStats {
        queue.sync {
            var value = BufferStats()
            let callback = onStats
            onStats = { value = $0 }; publishStats(); onStats = callback
            return value
        }
    }
    func testAdoptStream(_ capture: SCStream) { queue.sync { stream = capture } }
    func testAdoptApplicationAudioStream(_ capture: SCStream?, processes: Set<pid_t> = [], display: CGDirectDisplayID? = nil) {
        queue.sync {
            usesApplicationAudio = true; applicationAudioStream = capture; applicationAudioStreamStarted = false; applicationAudioStreamStarting = false
            applicationAudioProcesses = processes; applicationAudioDisplay = display
        }
    }
    func testReconcileApplicationAudio(processes: Set<pid_t>, display: CGDirectDisplayID) async -> Bool {
        let id = queue.sync { sessionID }
        return await reuseApplicationAudioStream(processes: processes, display: display, warning: nil, session: id)
    }
    func testApplicationAudioStreamStarted() -> Bool { queue.sync { applicationAudioStreamStarted } }
    func testApplicationAudioWarning() -> String? { queue.sync { applicationAudioWarning } }
    func testTick(at time: CMTime) { queue.sync { tick(at: time) } }
}

enum SpyExporter {
    /// Pinning uses hard links, so saving neither copies nor freezes the ring.
    static func export(_ snapshot: SpySnapshot, to destination: URL, levels: AudioLevels = AudioLevels(), separateAudio: Bool = false, editableMicrophone: Bool = false, removeSnapshot: Bool = true, progress: @escaping (Float) -> Void = { _ in }) async throws {
        defer { if removeSnapshot { try? FileManager.default.removeItem(at: snapshot.directory) } }
        guard snapshot.requestedSeconds > 0 else { throw SpyError.message("Выберите время больше нуля.") }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SpyError.message("Не удалось создать видео.")
        }
        var sources: [(AVURLAsset, AVAssetTrack, CMTimeRange, [(AVAssetTrack, AudioSource)])] = []
        var audioTracks: [AudioSource: AVMutableCompositionTrack] = [:]
        var total = CMTime.zero
        for url in snapshot.urls {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await track.load(.timeRange)
            guard range.duration > .zero else { continue }
            let assetAudio = try await asset.loadTracks(withMediaType: .audio)
            var tagged: [(AVAssetTrack, AudioSource)] = []
            for (index, source) in assetAudio.enumerated() {
                let metadata = try await source.load(.metadata)
                var kind: AudioSource = index == 0 ? .system : .microphone
                for item in metadata where item.identifier == .quickTimeMetadataTitle {
                    if let text = try await item.load(.stringValue), let parsed = AudioSource(rawValue: text) { kind = parsed }
                }
                tagged.append((source, kind))
                if audioTracks[kind] == nil {
                    guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("Не удалось создать звуковую дорожку.") }
                    audioTracks[kind] = target
                }
            }
            sources.append((asset, track, range, tagged)); total = total + range.duration
        }
        guard total > .zero else { throw SpyError.message("В буфере пока нет кадров.") }
        let requested = CMTime(seconds: snapshot.requestedSeconds, preferredTimescale: 60_000)
        var skip = CMTimeMaximum(.zero, total - requested)
        var cursor = CMTime.zero
        for (_, track, range, assetAudio) in sources {
            if skip >= range.duration { skip = skip - range.duration; continue }
            let start = range.start + skip
            let length = range.duration - skip
            let selectedRange = CMTimeRange(start: start, duration: length)
            try video.insertTimeRange(selectedRange, of: track, at: cursor)
            for (audioTrack, kind) in assetAudio {
                let audioRange = try await audioTrack.load(.timeRange)
                let intersection = CMTimeRangeGetIntersection(selectedRange, otherRange: audioRange)
                if intersection.duration > .zero {
                    try audioTracks[kind]?.insertTimeRange(intersection, of: audioTrack, at: cursor + intersection.start - selectedRange.start)
                }
            }
            cursor = cursor + length; skip = .zero
        }
        if let source = sources.first { video.preferredTransform = try await source.1.load(.preferredTransform) }
        let audible = audioTracks.filter { !$0.value.segments.isEmpty }
        let volumes = Dictionary(uniqueKeysWithValues: audible.map { ($0.value.trackID, levels[$0.key]) })
        let keepSeparate = separateAudio || (editableMicrophone && audible[.microphone] != nil)
        if (keepSeparate && !audible.isEmpty) || audible.count > 1 || audible.contains(where: { levels[$0.key] != 1 }) {
            // Mix system + microphone into ONE AAC track. Copy the compressed
            // H.264 packets so even long replays don't re-encode their video.
            try await Task.detached(priority: .userInitiated) {
                try await MixedAudioExporter.export(composition, video: video, audio: AudioSource.allCases.compactMap { audible[$0] }, to: destination, volumes: volumes, separate: keepSeparate, names: Dictionary(uniqueKeysWithValues: audible.map { ($0.value.trackID, $0.key.rawValue) }), progress: progress)
            }.value
            return
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw SpyError.message("Экспорт видео недоступен.")
        }
        exporter.outputURL = destination; exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        progress(0.2)
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw exporter.error ?? SpyError.message("Не удалось сохранить повтор.")
        }
        progress(1)
    }
}

func fileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: bytes).replacingOccurrences(of: "MB", with: "МБ").replacingOccurrences(of: "GB", with: "ГБ").replacingOccurrences(of: "Zero KB", with: "0 МБ").replacingOccurrences(of: "KB", with: "КБ")
}

func clockText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

private final class CaptureCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
