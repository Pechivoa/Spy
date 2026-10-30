import AppKit
import AVFoundation
import Darwin

@MainActor enum DurableQueueTests {
    struct Ready: Codable { let id: UUID; let output: URL }

    static func fixture(root: URL, source: URL, stage: String) async throws {
        _ = NSApplication.shared
        let model = AppModel(preview: true, previewRoot: root)
        let input = model.libraryURL.appendingPathComponent("input.mov")
        try FileManager.default.copyItem(at: source, to: input)
        if stage == "receipt" || stage == "published" {
            try model.exportQueue.configureDurability(root: model.cacheURL) { [weak model] record, directory in
                let media = try await EditableVideoAudio.load(url: directory.appendingPathComponent("source.mov"))
                return QueuedExportPlan(directory: directory) { _ in
                    guard let model else { throw CancellationError() }
                    try await media.export(to: record.partial, start: record.start, end: record.end,
                        microphoneEnabled: record.microphone, levels: record.gains)
                    try model.exportQueue.checkpointPublication(record.id, receipt: try await ExportPublicationReceipt.measure(record.partial))
                    if stage == "published" { try FileManager.default.moveItem(at: record.partial, to: record.output) }
                    try JSONEncoder().encode(Ready(id: record.id, output: record.output)).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
                    for _ in 0..<90 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    throw CancellationError()
                }
            }
        } else { model.manualSaving = true }
        let id = try model.enqueueClip(Clip(url: input, date: Date(), bytes: Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize!), duration: 4),
            start: 0.25, end: 1.75, microphone: false, gains: AudioLevels(system: 0.6, microphone: 0.1))
        if stage == "waiting" || stage == "copy-missing" || stage == "paused-exit" {
            try await wait("prepared child job") { model.exportQueue.item(id)?.phase == .waiting }
            if stage == "paused-exit" {
                await model.exportQueue.pauseAll(); model.manualSaving = false
                let closed = await model.shutdown()
                try SelfTest.require(closed, "Paused durable queue permits orderly shutdown")
            }
            let data = try Data(contentsOf: model.cacheURL.appendingPathComponent("queue-" + id.uuidString).appendingPathComponent(DurableExportJob.fileName))
            let record = try JSONDecoder().decode(DurableExportJob.self, from: data)
            try JSONEncoder().encode(Ready(id: id, output: record.output)).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
            if stage == "paused-exit" { return }
        }
        for _ in 0..<90 { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }

    static func run(directory: URL) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("template-cache"))
        try engine.beginTest(seconds: 10, audio: true, microphone: true)
        for frame in 0..<120 {
            let pts = CMTime(value: Int64(9000 + frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let template = directory.appendingPathComponent("template.mov")
        try await SpyExporter.export(try await engine.snapshot(seconds: 4), to: template, separateAudio: true, editableMicrophone: true)
        await engine.stop()
        for stage in ["waiting", "copy-missing", "receipt", "published", "paused-exit"] {
            let root = directory.appendingPathComponent(stage, isDirectory: true)
            let process = Process()
            process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--queue-fixture", root.path, template.path, stage]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
            let readyURL = root.appendingPathComponent("ready.json")
            try await wait("child durable checkpoint: " + stage, seconds: 25) {
                FileManager.default.fileExists(atPath: readyURL.path) || !process.isRunning
            }
            guard let bytes = try? Data(contentsOf: readyURL) else { throw SpyError.message("TEST FAILED: child failed before checkpoint: " + stage) }
            let ready = try JSONDecoder().decode(Ready.self, from: bytes)
            if stage != "paused-exit" { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if stage == "paused-exit" { try SelfTest.require(process.terminationStatus == 0, "Clean exit succeeds with paused work") }
            let publishedBefore = try? await ExportPublicationReceipt.measure(ready.output)
            let original = root.appendingPathComponent("Library/input.mov")
            let offlineSource = root.appendingPathComponent("offline-source.mov")
            if stage == "copy-missing" {
                try FileManager.default.moveItem(at: original, to: offlineSource)
                try FileManager.default.removeItem(at: root.appendingPathComponent("Cache/queue-" + ready.id.uuidString + "/source.mov"))
            } else { try FileManager.default.removeItem(at: original) }
            var corrupt: URL?
            if stage == "waiting" {
                let bad = root.appendingPathComponent("Cache/queue-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
                try Data("broken manifest".utf8).write(to: bad.appendingPathComponent(DurableExportJob.fileName))
                try FileManager.default.copyItem(at: template, to: bad.appendingPathComponent("source.mov"))
                corrupt = bad
            }
            let model = AppModel(preview: true, previewRoot: root)
            try model.configureExportQueue()
            try SelfTest.require(model.exportQueue.restoredCount == 1 && model.queuedExports == 0 && !model.saving,
                "Restored work waits for explicit resume and does not block replay startup")
            try SelfTest.require(model.storageLocked, "Paused source pins are protected from storage cleanup")
            var secondBlocked = false
            do { _ = try DurableExportStore(root: model.cacheURL) } catch { secondBlocked = true }
            try SelfTest.require(secondBlocked, "A second process/controller cannot adopt a live queue lease")
            let restored = model.exportQueue.item(ready.id)!
            try SelfTest.require(restored.range.start == 0.25 && restored.range.end == 1.75 && !restored.microphoneEnabled && restored.gains.system == 0.6,
                "Boundaries, microphone selection and gain survive the killed process")
            model.systemVolume = 0; model.microphoneVolume = 1
            if stage == "copy-missing" {
                model.exportQueue.resume(ready.id)
                try await wait("missing source retains recipe") { model.exportQueue.item(ready.id)?.phase == .failed }
                let retained = model.exportQueue.item(ready.id)!.retainedDirectory!
                try SelfTest.require(FileManager.default.fileExists(atPath: retained.appendingPathComponent(DurableExportJob.fileName).path),
                    "An interrupted pin/copy keeps its durable request even before any media is pinned")
                try FileManager.default.moveItem(at: offlineSource, to: original)
            }
            if stage == "waiting" {
                let offline = root.appendingPathComponent("Offline")
                try FileManager.default.moveItem(at: model.libraryURL, to: offline)
                model.exportQueue.resume(ready.id)
                try await wait("offline destination failure") { model.exportQueue.item(ready.id)?.phase == .failed }
                try SelfTest.require(model.exportQueue.item(ready.id)?.retainedDirectory != nil, "Offline destination preserves resumable media")
                try FileManager.default.moveItem(at: offline, to: model.libraryURL)
            }
            model.exportQueue.resume(ready.id)
            let output = try await model.exportQueue.result(ready.id)
            try SelfTest.require(output == ready.output, "Restored job keeps the original unique output path")
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            try SelfTest.require(abs(duration - 1.5) < 0.08 && audio.count == 1, "Recovered fragment has the exact range and selected audio")
            let samples = try AudioTests.samples(asset, track: audio[0])
            try SelfTest.require(AudioTests.magnitude(samples, frequency: 440) > 0.02 && AudioTests.magnitude(samples, frequency: 997) < 0.005,
                "Restored export retains system audio and removes the microphone")
            if let publishedBefore {
                let identical = try await publishedBefore.matches(output)
                try SelfTest.require(identical, "Crash after publication reuses the identical file without encoding again")
            }
            let outputs = try FileManager.default.contentsOfDirectory(at: model.libraryURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Spy_Fragment_") }
            try SelfTest.require(outputs.count == 1, "No duplicate is produced around either publication checkpoint")
            try SelfTest.require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Cache/queue-" + ready.id.uuidString).path), "Completed job releases its own pins")
            if let corrupt { try SelfTest.require(FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("source.mov").path), "A corrupt neighbouring manifest never deletes its media") }
            print("PASS: real-process " + stage + ", durable source pins, frozen range/audio, explicit resume, unique publication and queue lease")
        }
    }
    private static func wait(_ description: String, seconds: Double = 15, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        try SelfTest.require(condition(), description)
    }
}
