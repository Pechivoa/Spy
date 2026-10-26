import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecordingDiagnosticStatus: String {
    case passed, warning, failed, notSelected
    var title: String {
        switch self {
        case .passed: return "Работает"
        case .warning: return "Нужна проверка"
        case .failed: return "Ошибка"
        case .notSelected: return "Не выбран"
        }
    }
}

struct RecordingDiagnosticResult: Identifiable {
    enum Component: String { case screen, video, system, microphone, operation }
    let component: Component
    let status: RecordingDiagnosticStatus
    let detail: String
    var id: String { component.rawValue }
    var title: String {
        switch component {
        case .screen: return "Доступ к экрану"
        case .video: return "Видео"
        case .system: return "Системный звук"
        case .microphone: return "Микрофон"
        case .operation: return "Проверка"
        }
    }
}

/// A check owns only its temporary capture and pinned snapshot. It never stops
/// the supplied live engine or changes the user's replay intent/preferences.
@MainActor final class RecordingDiagnostics: ObservableObject {
    typealias CaptureStart = (SpyEngine, RecordingConfig) async throws -> Void
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var results: [RecordingDiagnosticResult] = []
    @Published private(set) var checkedAt: Date?
    private let access: CaptureAccess
    private let captureStartOverride: CaptureStart?
    private let testDuration: Double
    private let tempRoot: URL
    private var job: Task<Void, Never>?
    private var privateEngine: SpyEngine?

    init(access: CaptureAccess? = nil, captureStartOverride: CaptureStart? = nil,
         testDuration: Double = 5, tempRoot: URL = FileManager.default.temporaryDirectory) {
        self.access = access ?? .live
        self.captureStartOverride = captureStartOverride
        self.testDuration = min(5, max(0, testDuration.isFinite ? testDuration : 5))
        self.tempRoot = tempRoot
    }

    var reportText: String {
        var lines = ["Spy — проверка записи"]
        if let checkedAt { lines.append(checkedAt.formatted(date: .numeric, time: .standard)) }
        lines.append(contentsOf: results.map { "\($0.title): \($0.status.title)\n\($0.detail)" })
        return lines.joined(separator: "\n\n")
    }

    func cancel() {
        guard running else { return }
        progress = "Отменяю проверку и удаляю временный фрагмент…"
        // Stop accepting samples immediately, including while startCapture or
        // the first-frame wait is suspended. The live engine is never blocked.
        privateEngine?.requestPrivacyBlock(true)
        job?.cancel()
    }

    func cancelAndWait() async {
        guard let current = job else { return }
        cancel()
        await current.value
    }

    func run(config: RecordingConfig, existingEngine: SpyEngine? = nil, expectedDimensions: CGSize? = nil) async {
        guard !running else { return }
        running = true; results = []; checkedAt = nil
        progress = existingEngine == nil ? "Готовлю проверку записи…" : "Проверяю последние секунды буфера…"
        let worker = Task { [self] in
            results = await perform(config: config, existingEngine: existingEngine, expectedDimensions: expectedDimensions)
        }
        job = worker
        await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        job = nil; running = false; checkedAt = Date(); progress = ""
    }

    private func perform(config: RecordingConfig, existingEngine: SpyEngine?, expectedDimensions: CGSize?) async -> [RecordingDiagnosticResult] {
        var report: [RecordingDiagnosticResult] = []
        var ownedEngine: SpyEngine?
        var ownedDirectory: URL?
        var pinnedDirectory: URL?
        var selectedConfig = config
        var blockedMicrophone: RecordingDiagnosticResult?
        do {
            try Task.checkCancellation()
            // A running capture is stronger evidence than the advisory preflight,
            // which can lag behind an already approved ScreenCaptureKit stream.
            let screenAllowed = access.screenAllowed()
            report.append(.init(component: .screen, status: screenAllowed || existingEngine != nil ? .passed : .failed,
                                detail: existingEngine != nil ? "Проверяется уже работающий поток; доступ macOS не меняется."
                                : screenAllowed ? "macOS разрешила Spy запись экрана."
                                : "Разрешите Spy запись экрана в Системных настройках → Конфиденциальность и безопасность → Запись экрана и системного звука, затем перезапустите Spy и повторите проверку."))
            guard screenAllowed || existingEngine != nil else {
                report.append(.init(component: .video, status: .warning, detail: "Видео не проверено: сначала нужен доступ к экрану."))
                report += Self.uncheckedAudio(config: config)
                return report
            }
            if config.microphone && existingEngine == nil && access.microphoneStatus() != .authorized {
                selectedConfig.microphone = false
                blockedMicrophone = .init(component: .microphone, status: .failed,
                                          detail: "Нет разрешения на микрофон. Разрешите Spy доступ в Системных настройках → Конфиденциальность и безопасность → Микрофон. Проверка сама не запрашивает и не меняет доступ.")
            }
            let dimensions: CGSize?
            if let expectedDimensions { dimensions = expectedDimensions }
            else if captureStartOverride == nil && screenAllowed {
                dimensions = try await Self.captureDimensions(config: config)
            } else { dimensions = nil }
            try Task.checkCancellation()
            let engine: SpyEngine
            if let existingEngine { engine = existingEngine }
            else {
                let directory = tempRoot.appendingPathComponent("Spy-recording-check-" + UUID().uuidString, isDirectory: true)
                ownedDirectory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                engine = SpyEngine(cacheRoot: directory)
                ownedEngine = engine
                privateEngine = engine
                // Keep the check independent of a disabled/zero replay setting.
                selectedConfig.seconds = 10
                progress = "Записываю тестовый фрагмент — до 5 секунд…"
                if let captureStartOverride { try await captureStartOverride(engine, selectedConfig) }
                else { try await engine.start(selectedConfig) }
                try Task.checkCancellation()
                if testDuration > 0 { try await Task.sleep(nanoseconds: UInt64(testDuration * 1_000_000_000)) }
            }
            try Task.checkCancellation()
            let snapshot = try await engine.snapshot(seconds: 5)
            pinnedDirectory = snapshot.directory
            try Task.checkCancellation()
            progress = "Читаю кадры H.264 и дорожки AAC…"
            let playback = try await BufferPlayback.prepare(snapshot, levels: AudioLevels())
            let checks = try await RecordingDiagnosticAnalyzer.inspect(playback: playback, config: config, expectedDimensions: dimensions)
            report += checks.map { $0.component == .microphone ? blockedMicrophone ?? $0 : $0 }
            try Task.checkCancellation()
        } catch is CancellationError {
            report = [.init(component: .operation, status: .warning, detail: "Проверка отменена. Временный фрагмент удалён; текущая запись продолжается.")]
        } catch {
            report.append(.init(component: .video, status: .failed,
                                detail: "Не удалось проверить фрагмент. " + describeError(error) + " Проверьте выбранный экран или окно и повторите проверку."))
            if !report.contains(where: { $0.component == .system }) { report += Self.uncheckedAudio(config: config) }
            if let blockedMicrophone { report = report.map { $0.component == .microphone ? blockedMicrophone : $0 } }
        }
        // Await stop even after cancellation; cleanup has no cancellation gate.
        // The caller cannot report idle while its private stream is still open.
        if let ownedEngine { await ownedEngine.stop() }
        privateEngine = nil
        if let pinnedDirectory { try? FileManager.default.removeItem(at: pinnedDirectory) }
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        return report
    }

    private static func uncheckedAudio(config: RecordingConfig) -> [RecordingDiagnosticResult] {
        [RecordingDiagnosticResult(component: .system, status: config.audio ? .warning : .notSelected,
                                   detail: config.audio ? "Не проверен: тестовая запись не получена." : "Системный звук отключён в настройках записи."),
         RecordingDiagnosticResult(component: .microphone, status: config.microphone ? .warning : .notSelected,
                                   detail: config.microphone ? "Не проверен: тестовая запись не получена." : "Микрофон отключён в настройках записи.")]
    }

    private static func captureDimensions(config: RecordingConfig) async throws -> CGSize {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let source: CGSize
        if let windowID = config.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw SpyError.message("Выбранное окно закрыто.") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            source = window.frame.size
        } else {
            guard let display = content.displays.first(where: { $0.displayID == config.displayID }) else { throw SpyError.message("Выбранный экран отключён.") }
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            source = filter.contentRect.size
        }
        let (width, height) = config.quality.dimensions(width: Int(source.width * CGFloat(filter.pointPixelScale)), height: Int(source.height * CGFloat(filter.pointPixelScale)))
        return CGSize(width: width, height: height)
    }
}

/// Reads actual compressed packets and then decodes them. Track metadata alone
/// cannot prove that a valid movie or audible signal was captured.
enum RecordingDiagnosticAnalyzer {
    static func inspect(playback: BufferPlayback, config: RecordingConfig, expectedDimensions: CGSize?) async throws -> [RecordingDiagnosticResult] {
        var result: [RecordingDiagnosticResult] = []
        do {
            let detail = try await inspectVideo(asset: playback.asset, expectedDimensions: expectedDimensions, quality: config.quality)
            result.append(.init(component: .video, status: .passed, detail: detail))
        } catch is CancellationError { throw CancellationError() }
        catch { result.append(.init(component: .video, status: .failed, detail: describeError(error))) }
        for source in AudioSource.allCases {
            try Task.checkCancellation()
            let component: RecordingDiagnosticResult.Component = source == .system ? .system : .microphone
            let selected = source == .system ? config.audio : config.microphone
            guard selected else {
                result.append(.init(component: component, status: .notSelected,
                                    detail: source == .system ? "Системный звук отключён в настройках записи." : "Микрофон отключён в настройках записи."))
                continue
            }
            guard let id = playback.audioTrackID(for: source), let track = playback.asset.track(withTrackID: id) else {
                result.append(.init(component: component, status: .warning,
                                    detail: source == .system ? "Звук не поступил. Включите звук в другом приложении и повторите проверку." : "Звук не поступил. Произнесите несколько слов, проверьте выбранный микрофон и повторите проверку."))
                continue
            }
            do {
                let packets = try readCompressed(asset: playback.asset, track: track, codec: kAudioFormatMPEG4AAC)
                let signal = try readAudio(asset: playback.asset, track: track)
                let audible = signal.peak > 0.0001 && signal.rms > 0.00001
                let db = signal.rms > 0 ? String(format: "%.1f dBFS", 20 * log10(signal.rms)) : "−∞ dBFS"
                let detail = audible ? "AAC читается: \(packets) пакетов, уровень \(db). Сигнал обнаружен."
                : "AAC читается, но в фрагменте тишина (\(db)). " + (source == .system ? "Включите звук в другом приложении и повторите проверку." : "Произнесите несколько слов и повторите проверку; проверьте вход и усиление микрофона.")
                result.append(.init(component: component, status: audible ? .passed : .warning, detail: detail))
            } catch is CancellationError { throw CancellationError() }
            catch { result.append(.init(component: component, status: .failed, detail: "Не удалось прочитать звук. " + describeError(error))) }
        }
        return result
    }

    private static func inspectVideo(asset: AVAsset, expectedDimensions: CGSize?, quality: Quality) async throws -> String {
        try Task.checkCancellation()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("В фрагменте нет видеодорожки.") }
        let packets = try readCompressed(asset: asset, track: track, codec: kCMVideoCodecType_H264)
        let size = try await track.load(.naturalSize)
        let width = Int(abs(size.width)), height = Int(abs(size.height))
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { throw SpyError.message("Неверный размер видеокадра: \(width)×\(height).") }
        if let expectedDimensions {
            guard width == Int(expectedDimensions.width), height == Int(expectedDimensions.height) else {
                throw SpyError.message("Размер кадра \(width)×\(height), ожидался \(Int(expectedDimensions.width))×\(Int(expectedDimensions.height)). Проверьте экран, окно и профиль качества.")
            }
        } else {
            let limit = quality.dimensions(width: width, height: height)
            guard limit.0 == width, limit.1 == height else { throw SpyError.message("Кадр \(width)×\(height) превышает выбранный профиль качества.") }
        }
        let reader = try makeReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        try start(reader, output: output)
        defer { reader.cancelReading() }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // AVComposition readers emit zero-sample timing/empty-edit markers.
            // They carry no frame and must not be mistaken for corrupt media.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height else {
                throw SpyError.message("Декодированный кадр повреждён или имеет неверный размер.")
            }
            frames += 1
        }
        try completed(reader)
        guard frames > 0 else { throw SpyError.message("H.264-дорожка не содержит читаемых кадров.") }
        let duration = min(5, (try await asset.load(.duration)).seconds)
        guard duration.isFinite, duration > 0 else { throw SpyError.message("Некорректная длительность видео.") }
        return "H.264: \(width)×\(height), \(frames) кадров за \(String(format: "%.2f", duration)) с; \(packets) пакетов прочитано и декодировано."
    }

    private static func makeReader(asset: AVAsset) throws -> AVAssetReader {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 60_000))
        return reader
    }

    private static func start(_ reader: AVAssetReader, output: AVAssetReaderTrackOutput) throws {
        guard reader.canAdd(output) else { throw SpyError.message("Не удалось открыть дорожку для чтения.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpyError.message("Не удалось прочитать тестовый фрагмент.") }
    }

    private static func completed(_ reader: AVAssetReader) throws {
        guard reader.status == .completed else { throw reader.error ?? SpyError.message("Чтение дорожки не завершено.") }
    }

    private static func readCompressed(asset: AVAsset, track: AVAssetTrack, codec: FourCharCode) throws -> Int {
        let reader = try makeReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        try start(reader, output: output)
        defer { reader.cancelReading() }
        var packets = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let format = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionGetMediaSubType(format) == codec,
                  CMSampleBufferDataIsReady(sample), CMSampleBufferGetTotalSampleSize(sample) > 0 else {
                throw SpyError.message(codec == kCMVideoCodecType_H264 ? "Дорожка не содержит корректных пакетов H.264." : "Дорожка не содержит корректных пакетов AAC.")
            }
            packets += CMSampleBufferGetNumSamples(sample)
        }
        try completed(reader)
        guard packets > 0 else { throw SpyError.message("Дорожка пуста: сжатые данные не получены.") }
        return packets
    }

    private static func readAudio(asset: AVAsset, track: AVAssetTrack) throws -> (peak: Double, rms: Double) {
        let reader = try makeReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        try start(reader, output: output)
        defer { reader.cancelReading() }
        var peak = 0.0, squares = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw SpyError.message("Не удалось декодировать звуковой пакет.") }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length % MemoryLayout<Float>.size == 0 else { throw SpyError.message("Некорректный размер звукового пакета.") }
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw SpyError.message("Не удалось прочитать звуковые отсчёты (\(status)).") }
            for value in samples {
                guard value.isFinite else { throw SpyError.message("Звуковая дорожка содержит повреждённые отсчёты.") }
                let sample = Double(value)
                peak = max(peak, abs(sample)); squares += sample * sample; count += 1
            }
        }
        try completed(reader)
        guard count > 0 else { throw SpyError.message("В звуковой дорожке нет читаемых отсчётов.") }
        return (peak, sqrt(squares / Double(count)))
    }
}
