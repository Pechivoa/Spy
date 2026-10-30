import Foundation
import CryptoKit
import Darwin

struct ExportPublicationReceipt: Codable {
    let bytes: Int64
    let sha256: String
    static func measure(_ url: URL) async throws -> Self {
        let task = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256(), bytes: Int64 = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); bytes += Int64(data.count); hash.update(data: data)
            }
            return Self(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func matches(_ url: URL) async throws -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == bytes else { return false }
        return try await Self.measure(url).sha256 == sha256
    }
}

/// Only values are persisted; executable closures and absolute source-segment
/// paths never cross a restart. All media remains pinned in this job's folder.
struct DurableExportJob: Codable {
    static let fileName = "export-job.json"
    var version = 1
    var id = UUID()
    var createdAt = Date()
    var phase = "preparing"
    var issue: String?
    var title: String
    var sourceKey: String
    var start: Double
    var end: Double
    var duration: Double
    var microphone: Bool
    var systemGain: Float
    var microphoneGain: Float
    var files: [String]
    var requestedSeconds: Double? = nil
    var intervals: [SpySourceInterval] = []
    var replayMarkers: [ReplayMarker] = []
    var markers: [ClipMarker] = []
    var capturedSystemGain: Float = 1
    var capturedMicrophoneGain: Float = 1
    var separateAudio = true
    var session: UUID? = nil
    var previewID: UUID? = nil
    var recovery = false
    var originalURL: URL? = nil
    var originalBytes: Int64? = nil
    var originalModified: Date? = nil
    var originalTitle: String? = nil
    var originalFavorite = false
    var destination: URL
    var outputName: String
    var receipt: ExportPublicationReceipt? = nil

    var range: PreviewRange { get throws { try PreviewRange(start: start, end: end, duration: duration) } }
    var gains: AudioLevels { AudioLevels(system: systemGain, microphone: microphoneGain) }
    var output: URL { destination.appendingPathComponent(outputName) }
    var partial: URL { destination.appendingPathComponent("." + outputName) }
    func validate(directory: URL) throws {
        let names = ["queue-" + id.uuidString, "record-queue-" + id.uuidString]
        guard version == 1, names.contains(directory.lastPathComponent),
              !files.isEmpty, files.count <= 2048, Set(files).count == files.count,
              title.count <= 512, sourceKey.count <= 8192,
              destination.isFileURL, destination.path.hasPrefix("/"),
              outputName == URL(fileURLWithPath: outputName).lastPathComponent,
              outputName.hasPrefix("Spy_Fragment_"), outputName.hasSuffix("_" + id.uuidString + ".mov"),
              systemGain.isFinite, microphoneGain.isFinite,
              capturedSystemGain.isFinite, capturedMicrophoneGain.isFinite,
              [systemGain, microphoneGain, capturedSystemGain, capturedMicrophoneGain].allSatisfy({ (0...1).contains($0) }),
              files.allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent && $0.hasSuffix(".mov") && !$0.hasPrefix(".") }),
              intervals.isEmpty || intervals.count == files.count,
              intervals.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }),
              replayMarkers.allSatisfy({ $0.sourceSeconds.isFinite }),
              markers.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 }),
              requestedSeconds.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw SpyError.message("Повреждены параметры задачи. Исходники оставлены в хранилище.")
        }
        _ = try range
        if let receipt {
            guard receipt.bytes > 0, receipt.sha256.count == 64,
                  receipt.sha256.allSatisfy({ $0.isHexDigit }) else { throw SpyError.message("Повреждена контрольная сумма результата.") }
        }
    }
    func snapshot(in directory: URL) -> SpySnapshot? {
        requestedSeconds.map { SpySnapshot(directory: directory, urls: files.map { directory.appendingPathComponent($0) },
            requestedSeconds: $0, sourceIntervals: intervals, markers: replayMarkers, captureSessionID: session) }
    }
}

/// The OS releases the exclusive lease even after SIGKILL. A second Spy may
/// not restore, rewrite or delete the first process's export jobs.
final class DurableExportStore {
    let root: URL
    private var lease: Int32 = -1
    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = root.appendingPathComponent(".export-queue.lock")
        lease = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { close(lease); lease = -1 }
            throw SpyError.message("Очередь уже открыта другой Spy или кэш недоступен. Закройте другую копию приложения.")
        }
    }
    deinit { if lease >= 0 { flock(lease, LOCK_UN); close(lease) } }
    func validateDirectory(_ directory: URL) throws {
        guard directory.standardizedFileURL.deletingLastPathComponent().path == root.path,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path,
              (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else {
            throw SpyError.message("Каталог задачи недоступен или заменён. Данные не изменены.")
        }
    }
    func write(_ record: DurableExportJob, in directory: URL) throws {
        try validateDirectory(directory); try record.validate(directory: directory)
        let url = directory.appendingPathComponent(DurableExportJob.fileName)
        guard !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true) else {
            throw SpyError.message("Файл задачи заменён ссылкой. Данные не изменены.")
        }
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    func load(_ directory: URL) throws -> DurableExportJob {
        try validateDirectory(directory)
        let url = directory.appendingPathComponent(DurableExportJob.fileName)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_097_152 else {
            throw SpyError.message("Файл очереди повреждён или слишком большой. Исходники сохранены.")
        }
        let record = try JSONDecoder().decode(DurableExportJob.self, from: Data(contentsOf: url))
        try record.validate(directory: directory)
        return record
    }
    func scan(report: (String) -> Void) -> [(DurableExportJob, URL)] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var jobs: [(DurableExportJob, URL)] = []
        for directory in entries where directory.lastPathComponent.hasPrefix("queue-") || directory.lastPathComponent.hasPrefix("record-queue-") {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(DurableExportJob.fileName).path) else { continue }
            do { jobs.append((try load(directory), directory)) }
            catch { report(directory.lastPathComponent + ": " + error.localizedDescription) }
        }
        return jobs.sorted { $0.0.createdAt < $1.0.createdAt }
    }
}
