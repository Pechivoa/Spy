import Foundation
import SwiftUI
import AVFoundation
import VideoToolbox
import CoreVideo

enum CaptureTuningError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum CaptureVideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264 · совместимость" : "HEVC · эффективное сжатие" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    var mediaCodec: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
}

struct CaptureEncodingOptions: Codable, Equatable, Sendable {
    var codec: CaptureVideoCodec = .h264
    /// Zero retains the existing quality preset's average bitrate.
    var bitrateMbps: Double = 0
    /// Zero leaves the rolling ring bounded by duration only.
    var cacheLimitGB: Double = 0
    var configurationIssue: String? = nil

    var cacheLimitBytes: Int64 { cacheLimitGB.isFinite && cacheLimitGB > 0 ? Int64(min(500, cacheLimitGB) * 1_000_000_000) : 0 }

    func validate() throws {
        if let configurationIssue { throw CaptureTuningError.invalid(configurationIssue) }
        guard bitrateMbps.isFinite, bitrateMbps == 0 || (1...80).contains(bitrateMbps) else {
            throw CaptureTuningError.invalid("Битрейт должен быть «Авто» или от 1 до 80 Мбит/с.")
        }
        guard cacheLimitGB.isFinite, cacheLimitGB == 0 || (0.25...500).contains(cacheLimitGB) else {
            throw CaptureTuningError.invalid("Лимит кэша должен быть выключен или составлять от 0,25 до 500 ГБ.")
        }
    }

    func effectiveBitrate(defaultBitrate: Int) throws -> Int {
        try validate()
        guard defaultBitrate > 0 else { throw CaptureTuningError.invalid("Некорректный битрейт выбранного качества.") }
        return bitrateMbps == 0 ? defaultBitrate : Int((bitrateMbps * 1_000_000).rounded())
    }

    static func hardwareHEVCAvailable(width: Int = 1920, height: Int = 1080) -> Bool {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else { return false }
        var supported: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            encoderIDOut: nil, supportedPropertiesOut: &supported)
        return status == noErr && supported != nil
    }

    func validateHardwareSupport(width: Int = 1920, height: Int = 1080) throws {
        try validate()
        if codec == .hevc && !Self.hardwareHEVCAvailable(width: width, height: height) {
            throw CaptureTuningError.invalid("Аппаратный HEVC недоступен для выбранного разрешения. Выберите H.264 или уменьшите качество; формат не меняется автоматически.")
        }
    }

    func videoSettings(width: Int, height: Int, fps: Int, defaultBitrate: Int) throws -> [String: Any] {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2), fps > 0 else {
            throw CaptureTuningError.invalid("Некорректные размеры или частота кадров для кодирования.")
        }
        try validateHardwareSupport(width: width, height: height)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: try effectiveBitrate(defaultBitrate: defaultBitrate),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        var result: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: compression
        ]
        if codec == .hevc {
            result[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        }
        return result
    }
}

/// Relative to the captured frame, with an origin at its top-left corner.
struct RecordingMask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = "Приватная область"
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.000000001, y + height <= 1.000000001 else {
            throw CaptureTuningError.invalid("Область «\(title)» выходит за пределы кадра. Исправьте её или удалите перед записью.")
        }
    }
    func pixelRect(frameWidth: Int, frameHeight: Int) throws -> CGRect {
        try validate()
        guard frameWidth > 0, frameHeight > 0 else { throw CaptureTuningError.invalid("Пустой кадр для приватной области.") }
        // Round outwards so partially covered edge pixels cannot reveal content.
        let left = max(0, min(frameWidth, Int(floor(x * Double(frameWidth)))))
        let top = max(0, min(frameHeight, Int(floor(y * Double(frameHeight)))))
        let right = max(left, min(frameWidth, Int(ceil((x + width) * Double(frameWidth)))))
        let bottom = max(top, min(frameHeight, Int(ceil((y + height) * Double(frameHeight)))))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

enum RecordingMaskProcessor {
    static func validate(_ masks: [RecordingMask]) throws {
        guard masks.count <= 16 else { throw CaptureTuningError.invalid("Можно закрыть не более 16 областей кадра.") }
        for mask in masks { try mask.validate() }
    }

    /// Call only on a newly owned frame, before publishing it to the encoder.
    /// Never mutate a provider buffer or an earlier frame retained by AVAssetWriter.
    static func apply(_ masks: [RecordingMask], to pixel: CVPixelBuffer) throws {
        try validate(masks)
        guard !masks.isEmpty else { return }
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(pixel) else {
            throw CaptureTuningError.invalid("Приватные области требуют кадр BGRA; запись остановлена, чтобы не сохранить открытое изображение.")
        }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let rects = try masks.map { try $0.pixelRect(frameWidth: width, frameHeight: height) }
        guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else {
            throw CaptureTuningError.invalid("Не удалось закрыть приватные области кадра. Запись остановлена.")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        guard width > 0, height > 0, stride > 0, stride >= width * 4, stride.isMultiple(of: 4), height <= Int.max / stride,
              let base = CVPixelBufferGetBaseAddress(pixel) else {
            throw CaptureTuningError.invalid("Некорректная память кадра: приватные области не применены.")
        }
        for rect in rects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let row = base.advanced(by: y * stride + Int(rect.minX) * 4).assumingMemoryBound(to: UInt32.self)
                row.update(repeating: 0xff000000, count: Int(rect.width))
            }
        }
    }
}

enum CacheByteBudget {
    static func byteSize(_ url: URL) -> Int64 {
        max(0, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// Oldest first. Only return rolling-ring URLs; hardlinked previews/manual
    /// recordings remain independently owned. Keep the newest completed segment
    /// so a single high-bitrate segment cannot make every snapshot empty.
    static func removalURLs(candidates: [URL], reservedURLs: [URL], limitBytes: Int64) -> [URL] {
        guard limitBytes > 0, candidates.count > 1 else { return [] }
        var seen = Set<URL>()
        let unique = candidates.filter { seen.insert($0).inserted }
        let sizes = unique.map(byteSize)
        let all = unique + reservedURLs.filter { seen.insert($0).inserted }
        var total = all.reduce(Int64(0)) { sum, url in
            let (value, overflow) = sum.addingReportingOverflow(byteSize(url))
            return overflow ? Int64.max : value
        }
        var removed: [URL] = []
        for (index, url) in unique.dropLast().enumerated() where total > limitBytes {
            removed.append(url); total = max(0, total - sizes[index])
        }
        return removed
    }
}

@MainActor final class CaptureTuningSettings: ObservableObject {
    @Published var codec: CaptureVideoCodec { didSet { persist() } }
    @Published var bitrateMbps: Double { didSet { persist() } }
    @Published var cacheLimitGB: Double { didSet { persist() } }
    @Published var masksEnabled: Bool { didSet { persist() } }
    @Published var masks: [RecordingMask] { didSet { persist() } }
    @Published private(set) var configurationIssue: String?
    @Published private(set) var persistenceIssue: String?
    private let defaults: UserDefaults
    private static let key = "CaptureTuning.v1"
    private struct Stored: Codable {
        var codec: CaptureVideoCodec = .h264
        var bitrateMbps: Double = 0
        var cacheLimitGB: Double = 0
        var masksEnabled = false
        var masks: [RecordingMask] = []
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        var value = Stored()
        var issue: String?
        if let data = defaults.data(forKey: Self.key) {
            do { value = try JSONDecoder().decode(Stored.self, from: data) }
            catch { issue = "Настройки формата и приватных областей повреждены. Сбросьте этот раздел перед записью." }
        }
        codec = value.codec; bitrateMbps = value.bitrateMbps; cacheLimitGB = value.cacheLimitGB
        masksEnabled = value.masksEnabled; masks = value.masks
        configurationIssue = issue
    }
    var validationIssue: String? {
        if let configurationIssue { return configurationIssue }
        do {
            try CaptureEncodingOptions(codec: codec, bitrateMbps: bitrateMbps, cacheLimitGB: cacheLimitGB).validate()
            if masksEnabled { try RecordingMaskProcessor.validate(masks) }
            return nil
        } catch { return error.localizedDescription }
    }
    var encoding: CaptureEncodingOptions {
        CaptureEncodingOptions(codec: codec, bitrateMbps: bitrateMbps, cacheLimitGB: cacheLimitGB, configurationIssue: validationIssue)
    }
    var enabledMasks: [RecordingMask] { masksEnabled ? masks : [] }
    func addMask() {
        guard masks.count < 16 else { return }
        masks.append(RecordingMask(title: "Область \(masks.count + 1)", x: 0.65, y: 0.05, width: 0.3, height: 0.25))
    }
    func reset() {
        configurationIssue = nil; codec = .h264; bitrateMbps = 0; cacheLimitGB = 0
        masksEnabled = false; masks = []; persist()
    }
    private func persist() {
        // A corrupt saved configuration stays blocked until an explicit reset.
        guard configurationIssue == nil else { return }
        do {
            let value = Stored(codec: codec, bitrateMbps: bitrateMbps, cacheLimitGB: cacheLimitGB, masksEnabled: masksEnabled, masks: masks)
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: Self.key); persistenceIssue = nil
        } catch { persistenceIssue = "Не удалось сохранить настройки формата и областей: " + error.localizedDescription }
    }
}
