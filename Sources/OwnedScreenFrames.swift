import CoreVideo
import CoreGraphics
import Foundation
import Darwin

/// Encoder-queue confined. Copy SCK's borrowed display surface into a small
/// independent pool so asynchronous compression never holds the provider pool.
final class OwnedScreenFrames {
    private let maximumBuffers: Int
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    init(maximumBuffers: Int = 8) {
        self.maximumBuffers = min(8, max(1, maximumBuffers))
    }

    /// Nil means bounded pool pressure only. Invalid media, allocation failures
    /// and failed pixel locks throw rather than silently pretending to succeed.
    func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(source), sourceWidth > 0, sourceHeight > 0,
              sourceWidth <= Int.max / 4, sourceHeight <= Int.max / (sourceWidth * 4) else {
            throw SpyError.message("Поток экрана передал неподдерживаемый формат или размер кадра.")
        }
        if pool == nil || width != sourceWidth || height != sourceHeight {
            try makePool(width: sourceWidth, height: sourceHeight)
        }
        guard let pool else { throw SpyError.message("Не удалось подготовить буфер кадра.") }
        var destination: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: maximumBuffers] as CFDictionary, &destination)
        if result == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard result == kCVReturnSuccess, let destination else {
            throw SpyError.message("Не удалось выделить собственный буфер кадра: \(result).")
        }

        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else {
            throw SpyError.message("Не удалось прочитать кадр экрана: \(sourceLock).")
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else {
            throw SpyError.message("Не удалось записать собственный кадр: \(destinationLock).")
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let rowBytes = sourceWidth * 4
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        guard sourceStride >= rowBytes, destinationStride >= rowBytes,
              sourceHeight <= Int.max / sourceStride, sourceHeight <= Int.max / destinationStride,
              let sourceAddress = CVPixelBufferGetBaseAddress(source),
              let destinationAddress = CVPixelBufferGetBaseAddress(destination) else {
            throw SpyError.message("Некорректная память кадра экрана.")
        }
        for row in 0..<sourceHeight {
            let from = sourceAddress.advanced(by: row * sourceStride)
            let to = destinationAddress.advanced(by: row * destinationStride)
            memcpy(to, from, rowBytes)
            if destinationStride > rowBytes { memset(to.advanced(by: rowBytes), 0, destinationStride - rowBytes) }
        }
        // A recycled target must not inherit a prior frame's color description.
        // Only standard color metadata is needed by VideoToolbox; arbitrary
        // provider attachments could themselves retain a borrowed source frame.
        CVBufferRemoveAllAttachments(destination)
        for key in Self.colorKeys {
            var mode: CVAttachmentMode = .shouldNotPropagate
            if let value = CVBufferCopyAttachment(source, key, &mode), mode == .shouldPropagate,
               Self.isColorValue(value) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            }
        }
        return destination
    }

    func reset() {
        if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) }
        pool = nil; width = 0; height = 0
    }

    private func makePool(width: Int, height: Int) throws {
        var value: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 0, kCVPixelBufferPoolMaximumBufferAgeKey: 1] as CFDictionary,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
             kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
             kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &value)
        guard status == kCVReturnSuccess, let value else {
            throw SpyError.message("Не удалось создать очередь собственных кадров: \(status).")
        }
        // Existing encoded frames may outlive a resize/reset; never mutate them.
        reset(); pool = value; self.width = width; self.height = height
    }

    private static let colorKeys: [CFString] = [
        kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey, kCVImageBufferCGColorSpaceKey,
        kCVImageBufferICCProfileKey, kCVImageBufferGammaLevelKey,
        kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey
    ]
    private static func isColorValue(_ value: CFTypeRef) -> Bool {
        let type = CFGetTypeID(value)
        return type == CFStringGetTypeID() || type == CFNumberGetTypeID() ||
            type == CFDataGetTypeID() || type == CGColorSpace.typeID
    }
}
