import Foundation
import AppKit
import AVFoundation
import Darwin

/// A durable index is replaced atomically after segment finalization/pruning.
/// Media files themselves are already finalized MOVs; no raw frames are kept.
struct ReplayCrashManifest: Codable {
    struct Entry: Codable {
        let file: String
        let start: Double
        let end: Double
    }
    var version = 1
    let createdAt: Date
    let ownerPID: Int32
    let limitSeconds: Double
    let segments: [Entry]
    var ownerStartedAt: Date? = nil
    var markers: [ReplayMarker]? = nil
}

enum ReplayCrashRecovery {
    static let manifestName = "replay-manifest.json"
    private static let currentProcessStart = queryProcessStart(ProcessInfo.processInfo.processIdentifier)

    static func manifest(in directory: URL) -> ReplayCrashManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let value = try? JSONDecoder().decode(ReplayCrashManifest.self, from: data),
              value.version == 1, value.limitSeconds.isFinite else { return nil }
        return value
    }

    /// Promote only our abandoned ring folders. Unknown folders, manual recovery
    /// folders and live captures in another Spy process are left untouched.
    @discardableResult static func prepareCache(_ root: URL, legacyLimit: Double = 1800, diagnostic: (LogLevel, String) -> Void = { _, _ in }) -> [URL] {
        var promoted: [URL] = []
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        let liveCaptureExists = entries.contains { directory in manifest(in: directory).map(ownerIsRunning) ?? false }
        for directory in entries {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let name = directory.lastPathComponent
            if name.hasPrefix("record-") { continue }
            if name.hasPrefix("save-") || name.hasPrefix("preview-") {
                if liveCaptureExists { continue }
                // These are disposable copies/pins; an unfinished export's ring
                // is handled below and retained independently.
                do { try files.removeItem(at: directory) }
                catch { diagnostic(.warning, "Не удалось очистить временный просмотр: " + describeError(error)) }
                continue
            }
            let owned = UUID(uuidString: name) != nil || (name.hasPrefix("replay-") && UUID(uuidString: String(name.dropFirst(7))) != nil)
            guard owned else { continue }
            let index = manifest(in: directory)
            if let index, ownerIsRunning(index) { continue }
            let contents = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            guard contents.contains(where: { $0.pathExtension.lowercased() == "mov" }) else {
                // Do not remove an unrecognized file, even from an owned folder.
                if contents.allSatisfy({ $0.lastPathComponent == manifestName }) { try? files.removeItem(at: directory) }
                continue
            }
            let destination = root.appendingPathComponent("record-replay-crash-" + UUID().uuidString, isDirectory: true)
            do {
                try files.moveItem(at: directory, to: destination)
                promoted.append(destination)
                let limit = min(1800, max(0.1, index?.limitSeconds ?? (legacyLimit.isFinite && legacyLimit > 0 ? legacyLimit : 1800)))
                // The marker is optional: even if writing it fails, the MOVs
                // and manifest remain and recovery can calculate their length.
                do { try JSONEncoder().encode(limit).write(to: destination.appendingPathComponent("replay-seconds.json"), options: .atomic) }
                catch { diagnostic(.warning, "Запись сохранена для восстановления, но длительность не записана: " + describeError(error)) }
                diagnostic(.warning, "Найден буфер после незавершённого выхода Spy. Доступно восстановление последних минут.")
            } catch { diagnostic(.error, "Не удалось подготовить буфер к восстановлению; исходные файлы оставлены. " + describeError(error)) }
        }
        return promoted
    }

    private static func ownerIsRunning(_ index: ReplayCrashManifest) -> Bool {
        guard index.ownerPID > 0, Darwin.kill(index.ownerPID, 0) == 0 || errno == EPERM else { return false }
        if index.ownerPID == ProcessInfo.processInfo.processIdentifier {
            return launchMatches(index, actual: currentProcessStart ?? NSRunningApplication.current.launchDate)
        }
        guard let app = NSRunningApplication(processIdentifier: index.ownerPID), app.bundleIdentifier == "local.spy.mac" else { return false }
        // A reused PID from a newer Spy launch does not own an older folder.
        return launchMatches(index, actual: app.launchDate ?? queryProcessStart(index.ownerPID))
    }

    private static func launchMatches(_ index: ReplayCrashManifest, actual: Date?) -> Bool {
        guard let actual else { return false }
        if let recorded = index.ownerStartedAt { return abs(actual.timeIntervalSince(recorded)) < 1 }
        return actual <= index.createdAt.addingTimeInterval(2)
    }

    static var ownerStartedAt: Date? { currentProcessStart ?? NSRunningApplication.current.launchDate }

    private static func queryProcessStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let seconds = Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Atomically move the entire original folder out of the recovery queue if
    /// anything was not exported. No file is deleted from partial recoveries.
    static func retainUnexported(from snapshot: SpySnapshot) throws -> URL? {
        let files = FileManager.default
        let exported = Set(snapshot.urls.map(\.spyFileURL))
        let metadata = Set([manifestName, "replay-seconds.json", MarkerSnapshotMetadata.fileName])
        let leftovers = try files.contentsOfDirectory(at: snapshot.directory, includingPropertiesForKeys: nil).filter {
            !exported.contains($0.spyFileURL) && !metadata.contains($0.lastPathComponent)
        }
        guard !leftovers.isEmpty else { return nil }
        let retained = snapshot.directory.deletingLastPathComponent().appendingPathComponent("recovery-retained-" + UUID().uuidString, isDirectory: true)
        try files.moveItem(at: snapshot.directory, to: retained)
        return retained
    }

    static func snapshot(in directory: URL) async throws -> SpySnapshot {
        let files = FileManager.default
        let candidates = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey])
            .filter { $0.pathExtension.lowercased() == "mov" }
        let index = manifest(in: directory)
        let markerMetadata = MarkerSnapshotMetadata.load(directory)
        let savedPositions = markerMetadata.map { Array(zip($0.files, $0.intervals)).map { ($0.0, $0.1.start) } } ?? []
        let positions = Dictionary(index?.segments.map { ($0.file, $0.start) } ?? savedPositions, uniquingKeysWith: { first, _ in first })
        var valid: [(url: URL, order: Double, duration: Double)] = []
        var skipped: [String] = []
        for url in candidates {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SpyError.message("Необычный файл сегмента.") }
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("Нет видеодорожки.") }
                let range = try await track.load(.timeRange)
                let duration = range.duration.seconds
                guard duration.isFinite, duration > 0 else { throw SpyError.message("Пустой сегмент.") }
                // A truncated mdat can have readable metadata. Read all original
                // compressed packets to avoid poisoning an otherwise good replay.
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? SpyError.message("Сегмент не читается.") }
                var packets = 0
                while output.copyNextSampleBuffer() != nil { packets += 1 }
                guard reader.status == .completed, packets > 0 else { throw reader.error ?? SpyError.message("Сегмент записан не полностью.") }
                // New names preserve source order even if a crash occurs between
                // finishWriting and the manifest update. Old UUID names use dates.
                let numeric = Double(url.deletingPathExtension().lastPathComponent).flatMap { $0.isFinite ? $0 / 1_000_000 : nil }
                let order = positions[url.lastPathComponent] ?? numeric ?? (values.creationDate ?? .distantPast).timeIntervalSince1970
                valid.append((url, order, duration))
            } catch { skipped.append(url.lastPathComponent) }
        }
        valid.sort { $0.order == $1.order ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.order < $1.order }
        guard !valid.isEmpty else { throw SpyError.message("В незавершённой записи нет готовых кадров. Файлы оставлены в кэше для восстановления.") }
        let duration = valid.reduce(0) { $0 + $1.duration }
        let marker = (try? Data(contentsOf: directory.appendingPathComponent("replay-seconds.json"))).flatMap { try? JSONDecoder().decode(Double.self, from: $0) }
        let configured = marker ?? index?.limitSeconds
        let requested = configured.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? duration
        let intervals = valid.map { item in SpySourceInterval(start: item.order, end: item.order + item.duration) }
        return SpySnapshot(directory: directory, urls: valid.map(\.url), requestedSeconds: min(duration, requested), skippedRecoveryFiles: skipped, sourceIntervals: intervals, markers: index?.markers ?? markerMetadata?.markers ?? [])
    }
}
