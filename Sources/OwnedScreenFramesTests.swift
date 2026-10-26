import CoreVideo
import Foundation
import Darwin

enum OwnedScreenFramesTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try pixel(width: 37, height: 19)
        try fill(source, seed: 11)
        let original = try bytes(source)
        try SelfTest.require(CVPixelBufferGetBytesPerRow(source) > 37 * 4, "Fixture exercises actual padded BGRA rows")
        let copier = OwnedScreenFrames(maximumBuffers: 2)
        var first = try copier.copy(source)
        guard let identity = first.map({ Unmanaged.passUnretained($0).toOpaque() }) else {
            throw SpyError.message("TEST FAILED: First owned frame is absent")
        }
        try SelfTest.require(identity != Unmanaged.passUnretained(source).toOpaque(), "Owned output is not the provider CVPixelBuffer")
        try SelfTest.require(CVPixelBufferGetIOSurface(first!) != nil, "Independent frame is IOSurface-backed for hardware encoding")
        if let from = CVPixelBufferGetIOSurface(source), let to = CVPixelBufferGetIOSurface(first!) {
            try SelfTest.require(Unmanaged.passUnretained(from.takeUnretainedValue()).toOpaque() != Unmanaged.passUnretained(to.takeUnretainedValue()).toOpaque(), "Owned frame never aliases the provider IOSurface")
        }
        try fill(source, seed: 177)
        let heldFirstBytes = try bytes(first!), changedSourceBytes = try bytes(source)
        try SelfTest.require(heldFirstBytes == original && changedSourceBytes != original, "Mutating the provider after callback cannot change an already copied frame")
        var second = try copier.copy(source)
        try SelfTest.require(second != nil && Unmanaged.passUnretained(second!).toOpaque() != identity, "Two retained frames remain distinct")
        let exhausted = try withExtendedLifetime((first, second)) { try copier.copy(source) }
        try SelfTest.require(exhausted == nil, "Pool allocation threshold drops a new frame rather than growing beyond its bound")
        second = nil
        var recycled: CVPixelBuffer? = try copier.copy(source)
        let stillHeldFirstBytes = try bytes(first!), recycledBytes = try recycled.map { try bytes($0) }
        try SelfTest.require(recycled != nil && stillHeldFirstBytes == original && recycledBytes == changedSourceBytes, "Released slots become reusable without mutating an encoder-held frame")
        recycled = nil; first = nil
        print("PASS: padded-row BGRA copy, independent pixels/IOSurface, immutable retained frames and bounded pool pressure/recovery")

        // Return a borrowed source to its own threshold-one pool. A helper that
        // accidentally retains that source would prevent the second allocation.
        var providerPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
             kCVPixelBufferWidthKey: 64, kCVPixelBufferHeightKey: 32,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &providerPool)
        guard poolStatus == kCVReturnSuccess, let providerPool else { throw SpyError.message("TEST FAILED: Provider pool allocation failed") }
        let providerLimit = [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary
        var borrowed: CVPixelBuffer?
        try SelfTest.require(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, providerPool, providerLimit, &borrowed) == kCVReturnSuccess, "Provider starts with one borrowed surface")
        let owned = try copier.copy(borrowed!)
        borrowed = nil
        var nextBorrowed: CVPixelBuffer?
        let returned = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, providerPool, providerLimit, &nextBorrowed)
        try SelfTest.require(returned == kCVReturnSuccess && nextBorrowed != nil && owned != nil, "Copy releases all ownership of the provider frame while the independent copy remains alive")

        let changed = try pixel(width: 97, height: 43)
        try fill(changed, seed: 24)
        let changedCopy = try copier.copy(changed)
        let newDimensionBytes = try changedCopy.map { try bytes($0) }, changedBytes = try bytes(changed)
        try SelfTest.require(changedCopy != nil && CVPixelBufferGetWidth(changedCopy!) == 97 && CVPixelBufferGetHeight(changedCopy!) == 43 && newDimensionBytes == changedBytes, "A changed source dimension receives a compatible new pool")
        copier.reset()
        let afterReset = try copier.copy(source)
        let heldDimensionBytes = try changedCopy.map { try bytes($0) }
        try SelfTest.require(afterReset != nil && CVPixelBufferGetWidth(afterReset!) == 37 && heldDimensionBytes == changedBytes, "Reset starts a new pool without corrupting previously retained dimensions")
        print("PASS: provider surface returned immediately, independent dimensions and reset without invalidating queued frames")

        let colors = OwnedScreenFrames(maximumBuffers: 1)
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        var colored = try colors.copy(source)
        let tag = CVBufferCopyAttachment(colored!, kCVImageBufferColorPrimariesKey, nil) as? String
        try SelfTest.require(tag == kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "Standard color information reaches the owned frame")
        colored = nil
        CVBufferRemoveAllAttachments(source)
        let plain = try colors.copy(source)
        try SelfTest.require(plain != nil && CVBufferCopyAttachment(plain!, kCVImageBufferColorPrimariesKey, nil) == nil, "Recycled frames cannot inherit stale color metadata")
        let unsupported = try pixel(width: 64, height: 32, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        var rejected = false
        do { _ = try colors.copy(unsupported) } catch { rejected = true }
        try SelfTest.require(rejected, "Unexpected planar format throws even when the destination pool is under pressure")
        print("PASS: propagated color metadata, clean recycled attachments and explicit invalid-format rejection")
    }

    private static func pixel(width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &value)
        guard status == kCVReturnSuccess, let value else { throw SpyError.message("TEST FAILED: Pixel fixture allocation failed: \(status)") }
        return value
    }
    private static func fill(_ buffer: CVPixelBuffer, seed: Int) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw SpyError.message("TEST FAILED: Fixture write lock") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let address = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw SpyError.message("TEST FAILED: Fixture address") }
        memset(address, 0x99, stride * height)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * stride + column * 4
                address[offset] = UInt8((seed + row * 3) % 256)
                address[offset + 1] = UInt8((seed + column * 5) % 256)
                address[offset + 2] = UInt8((seed + row + column) % 256)
                address[offset + 3] = 255
            }
        }
    }
    private static func bytes(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw SpyError.message("TEST FAILED: Fixture read lock") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let address = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw SpyError.message("TEST FAILED: Fixture address") }
        return (0..<height).flatMap { row in Array(UnsafeBufferPointer(start: address.advanced(by: row * stride), count: width * 4)) }
    }
}
