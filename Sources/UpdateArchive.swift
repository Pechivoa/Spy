import Foundation

/// Inspect ZIP central and local headers before any file is extracted. Spy's
/// release app has no symlinks; refusing them avoids extraction path escapes.
enum SpyUpdateArchive {
    static func inspect(_ data: Data) throws {
        func bad() -> SpyError { .message("Небезопасный или неподдерживаемый архив обновления.") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw bad() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int { try u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22, data.count <= 200_000_000 else { throw bad() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(offset) == 0x06054b50, offset + 22 + (try u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw bad() }
        let count = try u16(end + 10), centralSize = try u32(end + 12), central = try u32(end + 16)
        guard count > 0, count <= 4096, try u16(end + 8) == count,
              central >= 0, central + centralSize == end else { throw bad() }
        var position = central, total = 0
        var names = Set<String>()
        for _ in 0..<count {
            guard try u32(position) == 0x02014b50 else { throw bad() }
            let flags = try u16(position + 8), method = try u16(position + 10)
            let packed = try u32(position + 20), unpacked = try u32(position + 24)
            let length = try u16(position + 28), extra = try u16(position + 30), comment = try u16(position + 32)
            let attributes = try u32(position + 38), local = try u32(position + 42)
            let mode = attributes >> 16, kind = mode & 0o170000
            guard flags & 1 == 0, [0, 8].contains(method), [0, 0o100000, 0o040000].contains(kind), mode & 0o6000 == 0,
                  length > 0, position + 46 + length + extra + comment <= end,
                  local + 30 <= central, try u32(local) == 0x04034b50,
                  try u16(local + 6) == flags, try u16(local + 8) == method else { throw bad() }
            let rawName = data.subdata(in: position + 46..<position + 46 + length)
            let localLength = try u16(local + 26), localExtra = try u16(local + 28)
            guard localLength == length, local + 30 + localLength + localExtra + packed <= central,
                  data.subdata(in: local + 30..<local + 30 + localLength) == rawName,
                  let name = String(data: rawName, encoding: .utf8), !name.contains("\0"), !name.contains("\\"), !name.contains(":"),
                  !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."),
                  name == "Spy.app/" || name.hasPrefix("Spy.app/") || name.hasPrefix("__MACOSX/") else { throw bad() }
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw bad() }
            total += unpacked
            guard total <= 1_000_000_000 else { throw bad() }
            position += 46 + length + extra + comment
        }
        guard position == end, names.contains("spy.app/contents/info.plist"), names.contains("spy.app/contents/macos/spy") else { throw bad() }
    }
}

final class SpyUpdateDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        completionHandler(request.url?.scheme == "https" && (host == "github.com" || host.hasSuffix(".githubusercontent.com")) ? request : nil)
    }
}
