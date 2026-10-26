import Foundation
import AVFoundation

@MainActor enum CrashRecoveryTests {
    /// Runs in an isolated subprocess, which exits without calling stop().
    static func writeCrashFixture(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory)
        try engine.beginTest(seconds: 2.25, audio: true, microphone: true)
        for frame in 0..<150 {
            let pts = CMTime(value: 90_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, rate: 44_100, channels: 1, frequency: 997), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        // Wait for all finalized files and durable index writes, then leave an
        // additional writer unfinished, exactly as during a sudden process loss.
        let pinned = try await engine.snapshot(seconds: 2.25)
        try FileManager.default.removeItem(at: pinned.directory)
        for frame in 150..<157 {
            let pts = CMTime(value: 90_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        // The CLI immediately calls exit(0). Keep the writer alive until that
        // process boundary instead of allowing ARC to perform orderly teardown.
        _ = Unmanaged.passRetained(engine)
        print("Crash fixture: finalized ring plus unfinished writer; no normal stop")
    }

    static func run(directory: URL) async throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = directory.appendingPathComponent("subprocess-cache", isDirectory: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let status = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--crash-recovery-fixture", fixture.path]
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }.value
        try SelfTest.require(status == 0, "Crash subprocess writes a real completed encoder ring")
        let ring = try files.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("replay-") }!
        let oldManifest = try Data(contentsOf: ring.appendingPathComponent(ReplayCrashRecovery.manifestName))
        let index = try JSONDecoder().decode(ReplayCrashManifest.self, from: oldManifest)
        try SelfTest.require(index.segments.count >= 2 && abs(index.limitSeconds - 2.25) < 0.001, "Durable index records current bounded ring")
        let segmentURLs = try files.contentsOfDirectory(at: ring, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mov" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let newest = segmentURLs.last!
        let handle = try FileHandle(forWritingTo: newest)
        try handle.truncate(atOffset: 16); try handle.close()

        let model = AppModel(preview: true)
        let modelRoot = model.libraryURL.deletingLastPathComponent()
        defer { try? files.removeItem(at: modelRoot) }
        let copied = model.cacheURL.appendingPathComponent(ring.lastPathComponent)
        try files.copyItem(at: ring, to: copied)
        let unknown = model.cacheURL.appendingPathComponent("unknown-data", isDirectory: true)
        try files.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("must survive startup".utf8).write(to: unknown.appendingPathComponent("keep.mov"))
        let transient = model.cacheURL.appendingPathComponent("preview-stale", isDirectory: true)
        try files.createDirectory(at: transient, withIntermediateDirectories: true)
        let promoted = ReplayCrashRecovery.prepareCache(model.cacheURL)
        model.refreshRecoveryFolders()
        try SelfTest.require(promoted.count == 1 && model.recoveryFolders.map(\.spyFileURL) == promoted.map(\.spyFileURL) && !files.fileExists(atPath: copied.path), "Startup promotes abandoned ring into visible recovery")
        try SelfTest.require(files.fileExists(atPath: unknown.appendingPathComponent("keep.mov").path) && !files.fileExists(atPath: transient.path), "Startup preserves unknown media and clears only stale temporary previews")
        let recovered = try await MediaSharing.recoverySnapshot(directory: promoted[0])
        let corruptBytes = try Data(contentsOf: promoted[0].appendingPathComponent(newest.lastPathComponent))
        let note = Data("unrecognized source data".utf8)
        try note.write(to: promoted[0].appendingPathComponent("extra-source.bin"))
        try SelfTest.require(recovered.urls.count >= 2 && recovered.skippedRecoveryFiles == [newest.lastPathComponent], "Unfinished newest segment is skipped while finalized media remains recoverable")
        try SelfTest.require(abs(recovered.requestedSeconds - 2.25) < 0.001, "Recovery retains requested replay duration")
        print("PASS: real subprocess exit, durable index, bounded chronological ring, corrupt-tail skip, safe startup cleanup")

        let offline = modelRoot.appendingPathComponent("OfflineLibrary")
        try files.moveItem(at: model.libraryURL, to: offline)
        await model.recoverRecording(promoted[0])
        try SelfTest.require(model.error != nil && model.recoveryFolders.count == 1 && files.fileExists(atPath: recovered.urls[0].path), "Failed recovery keeps original sources for another attempt")
        try files.moveItem(at: offline, to: model.libraryURL)
        model.error = nil
        model.separateAudio = true
        await model.recoverRecording(promoted[0])
        try SelfTest.require(model.error == nil && model.recoveryFolders.isEmpty && model.clips.count == 1, "Destination recovery succeeds after disk reconnect")
        let quarantine = try files.contentsOfDirectory(at: model.cacheURL, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("recovery-retained-") }!
        let retainedCorrupt = try Data(contentsOf: quarantine.appendingPathComponent(newest.lastPathComponent))
        let retainedNote = try Data(contentsOf: quarantine.appendingPathComponent("extra-source.bin"))
        try SelfTest.require(retainedCorrupt == corruptBytes && retainedNote == note, "Successful partial recovery preserves skipped media and unrecognized source bytes without another prompt")
        try SelfTest.require(ReplayCrashRecovery.prepareCache(model.cacheURL).isEmpty && files.fileExists(atPath: quarantine.path), "Later startups preserve quarantined media")
        let clip = model.clips[0]
        try SelfTest.require(clip.url.lastPathComponent.hasPrefix("Spy_Session_") && abs(clip.duration - 2.25) < 0.08, "Recovered replay has correct naming and exact duration")
        let asset = AVURLAsset(url: clip.url)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(audio.count == 2, "Recovery preserves both tagged audio sources")
        let system = try AudioTests.samples(asset, track: audio[0])
        let microphone = try AudioTests.samples(asset, track: audio[1])
        try SelfTest.require(AudioTests.magnitude(system, frequency: 440) > 0.01 && AudioTests.magnitude(microphone, frequency: 997) > 0.01, "Recovered system and microphone contain original sound")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Recovered video opens for decoding")
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        try SelfTest.require(reader.status == .completed && (66...70).contains(count), "Every recovered video frame decodes")
        try files.copyItem(at: clip.url, to: directory.appendingPathComponent("recovered-crash.mov"))
        print("PASS: failed destination retains sources, retry restores exact replay, both audible sources and all frames decode")

        let cleanRoot = directory.appendingPathComponent("clean-stop-cache")
        let clean = SpyEngine(cacheRoot: cleanRoot)
        try clean.beginTest(seconds: 2)
        for frame in 0..<35 {
            clean.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: 120_000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let activeRoot = try files.contentsOfDirectory(at: cleanRoot, includingPropertiesForKeys: nil).first!
        try SelfTest.require(ReplayCrashRecovery.prepareCache(cleanRoot).isEmpty && files.fileExists(atPath: activeRoot.path), "Startup never steals a live capture owned by another model/process")
        await clean.stop()
        try SelfTest.require(ReplayCrashRecovery.prepareCache(cleanRoot).isEmpty && !files.fileExists(atPath: activeRoot.path), "Ordinary explicit stop leaves no crash-recovery prompt")

        let reusedPIDFolder = cleanRoot.appendingPathComponent("replay-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: reusedPIDFolder, withIntermediateDirectories: true)
        try files.copyItem(at: clip.url, to: reusedPIDFolder.appendingPathComponent("00000000000000000001.mov"))
        let stale = ReplayCrashManifest(createdAt: .distantPast, ownerPID: ProcessInfo.processInfo.processIdentifier, limitSeconds: 2, segments: [])
        try JSONEncoder().encode(stale).write(to: reusedPIDFolder.appendingPathComponent(ReplayCrashRecovery.manifestName))
        try SelfTest.require(ReplayCrashRecovery.prepareCache(cleanRoot).count == 1, "A reused PID, including our own PID, cannot hide a crashed older session")

        // Old UUID ring directories have no manifest or timestamped filenames.
        // Preserve them too, and derive ordering from file creation dates.
        let legacy = model.cacheURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: legacy, withIntermediateDirectories: true)
        try files.copyItem(at: clip.url, to: legacy.appendingPathComponent(UUID().uuidString + ".mov"))
        let old = ReplayCrashRecovery.prepareCache(model.cacheURL, legacyLimit: 1.5)
        let legacySnapshot = try await MediaSharing.recoverySnapshot(directory: old[0])
        try SelfTest.require(old.count == 1 && abs(legacySnapshot.requestedSeconds - 1.5) < 0.001, "Legacy interrupted rings are preserved across the update")
        print("PASS: live capture protection, clean-stop cleanup and legacy interrupted-ring migration")
    }
}
