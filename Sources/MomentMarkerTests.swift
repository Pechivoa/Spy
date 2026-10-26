import Foundation
import AVFoundation

@MainActor enum MomentMarkerTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exact = ClipMarker(id: UUID(), seconds: 1.000009, title: "Граница")
        let range = try PreviewRange(start: exact.seconds, end: 2, duration: 3)
        let selected = MarkerTimeline.selected([exact, ClipMarker(id: UUID(), seconds: 2, title: "Конец")], start: range.start, end: range.end)
        try SelfTest.require(selected.count == 1 && selected[0].id == exact.id && selected[0].seconds == 0, "CMTime rounding retains a marker at the selected start, with half-open end")
        try await replayAndMetadata(directory: directory)
        try await privacyGap(directory: directory)
        try await manualAndRecovery(directory: directory)
        try await failedExitRecovery(directory: directory)
    }

    private static func feed(_ engine: SpyEngine, frames: Range<Int>, base: Int64) async throws {
        for frame in frames {
            engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: base + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    private static func replayAndMetadata(directory: URL) async throws {
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        model.saveBufferOnExit = false; model.minutes = 0.5
        try model.engine.beginTest(seconds: 2)
        model.recording = true
        try await feed(model.engine, frames: 0..<45, base: 3000)
        guard let first = model.engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: First moment marker") }
        let duplicate = model.engine.addMomentMarker()
        try SelfTest.require(duplicate?.id == first.id, "Repeated marking within one frame does not create duplicates")
        try await feed(model.engine, frames: 45..<90, base: 3000)
        guard let second = model.engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Second moment marker") }
        model.stats = model.engine.testStats()
        try SelfTest.require(model.stats.markerCount == 2 && first.id != second.id && first.sourceSeconds < second.sourceSeconds, "Real encoder marks retain source-clock order")
        await model.previewBuffer()
        guard let preview = model.bufferPreview else { throw SpyError.message("TEST FAILED: Marked preview not available") }
        let positions = preview.momentMarkers
        try SelfTest.require(positions.map(\.id) == [first.id, second.id] && positions.allSatisfy { $0.seconds >= 0 && $0.seconds < preview.clip.duration }, "Preview exposes only retained markers in relative video time")
        let selectedStart = max(0, positions[0].seconds - 0.1)
        let selectedEnd = min(preview.clip.duration, positions[1].seconds + 0.05)
        let saved = try await model.saveBufferPreview(preview, start: selectedStart, end: selectedEnd)
        let stored = model.metadata.get(saved).markers
        try SelfTest.require(stored.map(\.id) == [first.id, second.id] && abs(stored[0].seconds - (positions[0].seconds - selectedStart)) < 0.001, "Saving a selected fragment stores shifted marker positions")
        let reloaded = LibraryMetadata(url: model.metadata.url)
        try SelfTest.require(reloaded.get(saved).markers == stored, "Saved marker metadata survives a new library reader")
        let old = try JSONDecoder().decode(ClipMetadata.self, from: Data(#"{"name":"Old clip","favorite":true}"#.utf8))
        try SelfTest.require(old.name == "Old clip" && old.favorite && old.markers.isEmpty, "Metadata written before markers remains readable")
        model.closeBufferPreview()
        try await feed(model.engine, frames: 90..<180, base: 3000)
        let rotated = try await model.engine.snapshot(seconds: 2)
        try SelfTest.require(!rotated.markers.contains(where: { $0.id == first.id || $0.id == second.id }), "Replay markers leave the ring when their corresponding frames are pruned")
        try FileManager.default.removeItem(at: rotated.directory)
        await model.stop()
        print("PASS: real encoder marks, debounce, source order, relative preview timing, selected-save metadata, old metadata and replay pruning")
    }

    private static func privacyGap(directory: URL) async throws {
        let cache = directory.appendingPathComponent("marker-gap-cache")
        let engine = SpyEngine(cacheRoot: cache)
        try engine.beginTest(seconds: 2)
        try await feed(engine, frames: 0..<30, base: 9000)
        guard let before = engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Marker before pause") }
        engine.requestPrivacyBlock(true)
        try await engine.pauseForPrivacy()
        try SelfTest.require(engine.addMomentMarker() == nil, "Privacy pause blocks new markers")
        engine.testFrame(try SelfTest.pixel(frame: 120), at: CMTime(value: 36_000, timescale: 30))
        engine.requestPrivacyBlock(false)
        try await engine.resumeAfterPrivacy(excluding: [])
        try await feed(engine, frames: 30..<60, base: 39_000)
        guard let after = engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Marker after pause") }
        let snapshot = try await engine.snapshot(seconds: 2)
        let mapped = MarkerTimeline.positions(in: snapshot)
        let playback = try await BufferPlayback.prepare(snapshot, levels: AudioLevels())
        try SelfTest.require(engine.testStats().frameCount == 60 && abs(playback.duration - 2) < 0.04, "Privacy gap contributes no video frames or elapsed wall-clock duration")
        try SelfTest.require(mapped.map(\.id) == [before.id, after.id] && mapped[0].seconds < 1 && mapped[1].seconds > 1 && mapped[1].seconds < 2, "Markers on both sides of a long privacy pause map to captured time")
        try SelfTest.require(abs((playback.sourcePosition(before.sourceSeconds) ?? -1) - mapped[0].seconds) < 0.001 && abs((playback.sourcePosition(after.sourceSeconds) ?? -1) - mapped[1].seconds) < 0.001, "Export and fast-preview marker timelines agree across a clock gap")
        try FileManager.default.removeItem(at: snapshot.directory)
        await engine.stop()
        print("PASS: privacy-pause marker suppression, captured-duration retention and consistent gap mapping")
    }

    private static func manualAndRecovery(directory: URL) async throws {
        let model = AppModel(preview: true)
        let modelRoot = model.libraryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: modelRoot) }
        model.minutes = 0; model.saveBufferOnExit = false
        try model.engine.beginTest(seconds: 1)
        model.recording = true
        try await model.engine.beginManual()
        model.manualRecording = true
        try SelfTest.require(model.canAddMomentMarker, "Manual-only capture permits marking while replay is disabled")
        try await feed(model.engine, frames: 0..<30, base: 60_000)
        guard let early = model.engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Early manual marker") }
        try await feed(model.engine, frames: 30..<180, base: 60_000)
        guard let late = model.engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Late manual marker") }
        let snapshot = try await model.engine.finishManual()
        model.manualRecording = false
        await model.engine.stop(); model.recording = false
        let manualPositions = MarkerTimeline.positions(in: snapshot)
        try SelfTest.require(abs(snapshot.requestedSeconds - 6) < 0.04 && manualPositions.map(\.id) == [early.id, late.id] && manualPositions[0].seconds < 1, "Full-session markers survive beyond the one-second replay limit")
        try SelfTest.require(MarkerSnapshotMetadata.load(snapshot.directory)?.markers.map(\.id) == [early.id, late.id], "Manual source folder durably stores marker metadata")
        let availableLibrary = model.libraryURL
        model.libraryURL = modelRoot.appendingPathComponent("DisconnectedOutput")
        var failed = false
        do { try await model.saveManualSnapshot(snapshot) } catch { failed = true }
        let recovered = try await MediaSharing.recoverySnapshot(directory: snapshot.directory)
        try SelfTest.require(failed && recovered.markers.map(\.id) == [early.id, late.id] && !recovered.sourceIntervals.isEmpty, "Offline output retains durable manual markers for recovery")
        model.libraryURL = availableLibrary
        model.refreshRecoveryFolders()
        await model.recoverRecording(snapshot.directory)
        guard let clip = model.clips.first else { throw SpyError.message("TEST FAILED: Recovered marked manual video") }
        try SelfTest.require(model.metadata.get(clip.url).markers.map(\.id) == [early.id, late.id] && model.recoveryFolders.isEmpty, "Retry restores the full manual video and both saved marker identities")
        let leftovers = try FileManager.default.contentsOfDirectory(at: model.cacheURL, includingPropertiesForKeys: nil)
        try SelfTest.require(!leftovers.contains(where: { $0.lastPathComponent.hasPrefix("recovery-retained-") }), "Known marker sidecar does not cause a false partial-recovery quarantine")
        try FileManager.default.copyItem(at: clip.url, to: directory.appendingPathComponent("manual-with-markers.mov"))
        print("PASS: manual-only marks, long-session retention, durable sidecar, offline retry and correct sidecar cleanup")
    }

    private static func failedExitRecovery(directory: URL) async throws {
        let model = AppModel(preview: true, captureAccess: CaptureAccess(screenAllowed: { true }, microphoneStatus: { .authorized }, requestMicrophone: { false }))
        let modelRoot = model.libraryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: modelRoot) }
        model.minutes = 0.5; model.saveBufferOnExit = true
        model.captureStartOverride = { [weak model] config in
            guard let model else { throw CancellationError() }
            try model.engine.beginTest(seconds: config.seconds)
            try await feed(model.engine, frames: 0..<60, base: 90_000)
            try await model.engine.waitForFirstFrame(timeout: 0.5)
        }
        await model.start()
        guard let mark = model.engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Marker before failed exit") }
        let offline = modelRoot.appendingPathComponent("OfflineLibrary")
        try FileManager.default.moveItem(at: model.libraryURL, to: offline)
        let quit = await model.shutdown()
        model.refreshRecoveryFolders()
        guard let folder = model.recoveryFolders.first else { throw SpyError.message("TEST FAILED: Exit recovery folder") }
        let recovered = try await MediaSharing.recoverySnapshot(directory: folder)
        try SelfTest.require(quit && recovered.markers.map(\.id) == [mark.id] && MarkerTimeline.positions(in: recovered).count == 1, "Failed exit autosave preserves marker identity and source intervals on disk")
        try FileManager.default.moveItem(at: offline, to: model.libraryURL)
        await model.recoverRecording(folder)
        guard let clip = model.clips.first else { throw SpyError.message("TEST FAILED: Recovered exit video") }
        try SelfTest.require(model.metadata.get(clip.url).markers.map(\.id) == [mark.id] && model.recoveryFolders.isEmpty, "Exit recovery publishes the original moment marker in library metadata")
        try FileManager.default.copyItem(at: clip.url, to: directory.appendingPathComponent("exit-recovered-marker.mov"))
        print("PASS: failed exit autosave retains durable marker timeline and recovery restores it to the library")
    }
}
