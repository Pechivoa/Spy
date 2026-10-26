import AVFoundation

@MainActor enum AutoMomentClipTests {
    private struct Saved {
        let url: URL
        let marker: ReplayMarker
        let duration: Double
        let firstRed: UInt8
        let decodedFrames: Int
        let sourceIntervals: [SpySourceInterval]
        let markers: [ClipMarker]
        let systemGain: Float
        let microphoneGain: Float
        let separate: Bool
    }
    @MainActor private final class Harness {
        let directory: URL
        let cache: URL
        let library: URL
        let defaults: UserDefaults
        let suite: String
        let engine: SpyEngine
        var saved: [Saved] = []
        var diagnostics: [String] = []
        lazy var controller = AutoMomentClipController(defaults: defaults, engine: engine,
            onReady: { [unowned self] job in try await self.publish(job) },
            onDiagnostic: { [unowned self] message, _ in self.diagnostics.append(message) })

        init(_ directory: URL) throws {
            self.directory = directory
            self.cache = directory.appendingPathComponent("cache")
            self.library = directory.appendingPathComponent("library")
            self.suite = "local.spy.auto-moment-test." + UUID().uuidString
            self.defaults = UserDefaults(suiteName: suite)!
            self.engine = SpyEngine(cacheRoot: cache)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
        func feed(_ frames: Range<Int>, sourceStart: Double = 100, audio: Bool = false, jitter: Double = 0) async throws {
            for frame in frames {
                let offset = frame.isMultiple(of: 2) ? -jitter : jitter
                let pts = CMTime(seconds: sourceStart + Double(frame) / 30 + offset, preferredTimescale: 60_000)
                engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                if audio {
                    engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                    engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 880), microphone: true)
                }
                try await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        func mark() throws -> ReplayMarker {
            guard let marker = engine.addMomentMarker() else { throw SpyError.message("TEST FAILED: Missing real encoder marker") }
            return marker
        }
        func publish(_ job: AutoMomentClipJob) async throws -> URL {
            guard FileManager.default.fileExists(atPath: library.path) else { throw SpyError.message("TEST: Library disk is offline") }
            let intervals = job.snapshot.sourceIntervals
            try SelfTest.require(intervals.count == job.snapshot.urls.count, "Every auto-clip source has encoder-clock metadata")
            for index in intervals.indices.dropFirst() {
                try SelfTest.require(intervals[index].start > intervals[index - 1].start && !AutoMomentClipController.invalidOverlap(intervals[index - 1], intervals[index], frameDuration: job.frameDuration), "Repeated snapshots never duplicate sources; real segment-boundary jitter is bounded to one frame")
            }
            let sourceHashes = try await AudioTests.packetHashes(job.snapshot.urls)
            let url = library.appendingPathComponent("Auto-" + job.id.uuidString + ".mov")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            try await job.playback.export(range: job.range, to: url, separateAudio: job.separateAudio)
            let exportedHashes = try await AudioTests.packetHashes([url])
            try SelfTest.require(!exportedHashes.isEmpty && exportedHashes.isSubset(of: sourceHashes), "Auto-clip export passes through original compressed frames")
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw SpyError.message("TEST FAILED: Auto-clip video missing") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            try SelfTest.require(reader.startReading(), "Real automatic movie opens for decoding")
            var count = 0
            var firstRed: UInt8 = 0
            while let sample = output.copyNextSampleBuffer() {
                if count == 0, let pixel = CMSampleBufferGetImageBuffer(sample) {
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    firstRed = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)[2]
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                }
                count += 1
            }
            try SelfTest.require(reader.status == .completed && count > 0, "All frames in the automatic movie decode")
            try SelfTest.require(abs(duration - job.range.duration) < 0.06, "Automatic movie has the selected content duration")
            saved.append(Saved(url: url, marker: job.marker, duration: duration, firstRed: firstRed,
                decodedFrames: count, sourceIntervals: intervals, markers: job.markers,
                systemGain: job.levels.system, microphoneGain: job.levels.microphone, separate: job.separateAudio))
            return url
        }
        func waitForIdle() async throws {
            let deadline = Date().addingTimeInterval(15)
            while controller.pendingCount > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            try SelfTest.require(controller.pendingCount == 0, "Automatic clips finish after the requested recorded content arrives")
        }
    }

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await shortRingAndLongPostRoll(directory.appendingPathComponent("short-ring"))
        try await jitteredSegmentBoundaries(directory.appendingPathComponent("jitter"))
        try await privacyPause(directory.appendingPathComponent("privacy-gap"))
        try await overlappingAndBounded(directory.appendingPathComponent("overlap"))
        try await earlyStopAndRecovery(directory.appendingPathComponent("offline"))
        try await immediateZeroPreRollStop(directory.appendingPathComponent("zero-pre-roll"))
        try await sessionRestart(directory.appendingPathComponent("session-restart"))
    }

    private static func shortRingAndLongPostRoll(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        try SelfTest.require(!h.controller.enabled && h.controller.beforeSeconds == 30 && h.controller.afterSeconds == 10, "Automatic clips are opt-in with 30/10 defaults")
        h.controller.beforeSeconds = .nan; h.controller.afterSeconds = 1000
        try SelfTest.require(h.controller.beforeSeconds == 30 && h.controller.afterSeconds == 60, "Invalid and out-of-range settings are normalized")
        h.controller.enabled = true; h.controller.beforeSeconds = 3; h.controller.afterSeconds = 4
        try h.engine.beginTest(seconds: 3, audio: true, microphone: true)
        try await h.feed(0..<90, audio: true)
        let marker = try h.mark()
        await h.controller.capture(marker: marker, levels: AudioLevels(system: 0.6, microphone: 0.2), separateAudio: true)
        try SelfTest.require(h.controller.pendingCount == 1 && h.saved.isEmpty, "Pre-marker footage is pinned before waiting for new content")
        let pinned = try FileManager.default.contentsOfDirectory(at: h.cache, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("record-auto-") }
        try SelfTest.require(pinned.count == 1 && AutoMomentClipController.isRecoverable(directory: pinned[0]), "Pending source links and recovery recipe are already durable")
        await h.controller.capture(marker: marker, levels: AudioLevels(), separateAudio: false)
        try SelfTest.require(h.controller.pendingCount == 1, "The same marker cannot create duplicate automatic clips")
        h.controller.beforeSeconds = 0; h.controller.afterSeconds = 1
        try await h.feed(90..<220, audio: true)
        try await h.waitForIdle()
        guard let saved = h.saved.first else { throw SpyError.message("TEST FAILED: Long post-roll auto clip missing: " + (h.controller.lastError ?? "unknown")) }
        try SelfTest.require(h.saved.count == 1 && abs(saved.duration - (3 - 1.0 / 30 + 4)) < 0.07, "Four future seconds survive a three-second ring; settings are frozen at the mark")
        try SelfTest.require(abs(Int(saved.firstRed) - 50) < 4 && saved.decodedFrames >= 207, "The oldest pre-marker frames survive ring pruning and decode in the final clip")
        try SelfTest.require(saved.markers.contains(where: { $0.id == marker.id && abs($0.seconds - (3 - 1.0 / 30)) < 0.04 }), "Auto-clip marker position uses the selected source timeline")
        let audioAsset = AVURLAsset(url: saved.url)
        let tracks = try await audioAsset.loadTracks(withMediaType: .audio)
        try SelfTest.require(saved.separate && tracks.count == 2 && saved.systemGain == 0.6 && saved.microphoneGain == 0.2, "Both source gains and separate-audio policy are frozen per marker")
        let system = try AudioTests.samples(audioAsset, track: tracks[0])
        let microphone = try AudioTests.samples(audioAsset, track: tracks[1])
        try SelfTest.require(abs(AudioTests.magnitude(system, frequency: 440) - 0.09) < 0.025 && abs(AudioTests.magnitude(microphone, frequency: 880) - 0.03) < 0.02, "Real automatic AAC export applies frozen microphone and system gains")
        await h.engine.stop()
        print("PASS: opt-in defaults, clamped settings, immediate pre-roll pin, long post-roll in a shorter ring, duplicate-mark guard, original H.264 frames and frozen AAC gains")
    }

    private static func privacyPause(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        h.controller.enabled = true; h.controller.beforeSeconds = 2; h.controller.afterSeconds = 2
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<60)
        let marker = try h.mark()
        await h.controller.capture(marker: marker, levels: AudioLevels(), separateAudio: false)
        try await h.engine.pauseForPrivacy()
        let before = h.engine.captureProgress()?.capturedSeconds
        try await h.feed(60..<75, sourceStart: 200)
        try await Task.sleep(nanoseconds: 150_000_000)
        try SelfTest.require(h.engine.captureProgress()?.capturedSeconds == before && h.saved.isEmpty && h.controller.pendingCount == 1, "Blocked frames and a wall-clock pause do not consume future clip content")
        try await h.engine.resumeAfterPrivacy(excluding: [])
        try await h.feed(60..<125, sourceStart: 200)
        try await h.waitForIdle()
        guard let saved = h.saved.first else { throw SpyError.message("TEST FAILED: Paused automatic clip missing") }
        try SelfTest.require(abs(saved.duration - (4 - 1.0 / 30)) < 0.08, "Privacy gap is excluded from the exported automatic movie")
        let hasGap = saved.sourceIntervals.indices.dropFirst().contains { saved.sourceIntervals[$0].start - saved.sourceIntervals[$0 - 1].end > 90 }
        try SelfTest.require(hasGap && saved.markers.contains(where: { $0.id == marker.id && abs($0.seconds - (2 - 1.0 / 30)) < 0.04 }), "Marker and post-roll map correctly across a 100-second encoder-clock gap")
        await h.engine.stop()
        print("PASS: privacy pause freezes post-roll countdown; gap-free movie and exact marker position across a source-clock gap")
    }

    private static func jitteredSegmentBoundaries(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        h.controller.enabled = true; h.controller.beforeSeconds = 3; h.controller.afterSeconds = 2
        try h.engine.beginTest(seconds: 3)
        try await h.feed(0..<90, jitter: 0.001)
        let marker = try h.mark()
        await h.controller.capture(marker: marker, levels: AudioLevels(), separateAudio: false)
        try await h.feed(90..<160, jitter: 0.001)
        try await h.waitForIdle()
        guard let saved = h.saved.first else { throw SpyError.message("TEST FAILED: Jittered automatic clip missing: " + (h.controller.lastError ?? "unknown")) }
        let negativeGap = saved.sourceIntervals.indices.dropFirst().contains { saved.sourceIntervals[$0].start < saved.sourceIntervals[$0 - 1].end - 0.00001 }
        try SelfTest.require(h.saved.count == 1 && negativeGap && saved.decodedFrames >= 147 && abs(saved.duration - 5) < 0.10, "Real encoded adjacent segments with sub-frame source overlap retain the complete marked clip")
        try SelfTest.require(abs(Int(saved.firstRed) - 50) < 4 && saved.markers.contains(where: { $0.id == marker.id && abs($0.seconds - 3) < 0.06 }), "Jittered source mapping retains the oldest frame and a frame-accurate marker")
        try SelfTest.require(AutoMomentClipController.invalidOverlap(SpySourceInterval(start: 0, end: 1), SpySourceInterval(start: 0.5, end: 1.5), frameDuration: 1.0 / 30), "A substantial overlapping source remains rejected")
        try SelfTest.require(AutoMomentClipController.invalidOverlap(SpySourceInterval(start: 0, end: 1), SpySourceInterval(start: 0.99, end: 0.995), frameDuration: 1.0 / 30), "A contained duplicate interval is not mistaken for adjacent timer jitter")
        await h.engine.stop()
        print("PASS: real encoder timer jitter across initial and future snapshots, preserved source frames, exact marker mapping and rejection of non-adjacent overlap")
    }

    private static func overlappingAndBounded(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        h.controller.enabled = true; h.controller.beforeSeconds = 1; h.controller.afterSeconds = 5
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<60)
        var markers: [ReplayMarker] = []
        for index in 0..<6 {
            if index > 0 { try await h.feed((60 + (index - 1) * 10)..<(60 + index * 10)) }
            let marker = try h.mark(); markers.append(marker)
            await h.controller.capture(marker: marker, levels: AudioLevels(), separateAudio: false)
        }
        try SelfTest.require(h.controller.pendingCount == AutoMomentClipController.maximumPending && h.saved.isEmpty, "Overlapping markers are bounded to five pending clips")
        try SelfTest.require(h.controller.lastError?.contains("Очередь") == true, "Rejected overflow reports a readable queue status")
        await h.controller.flushPending()
        await h.engine.stop()
        try SelfTest.require(h.saved.count == 5 && Set(h.saved.map { $0.marker.id }).count == 5 && !h.saved.contains(where: { $0.marker.id == markers[5].id }), "Early stop publishes each accepted marker once, with no sixth job")
        try SelfTest.require(h.saved.allSatisfy { $0.duration >= 1 && $0.duration < 3 }, "Stop finalizes available content instead of waiting five future seconds")
        print("PASS: five overlapping markers, bounded queue, interval deduplication and shortened finalization before engine stop")
    }

    private static func earlyStopAndRecovery(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        h.controller.enabled = true; h.controller.beforeSeconds = 2; h.controller.afterSeconds = 10
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<60)
        let marker = try h.mark()
        await h.controller.capture(marker: marker, levels: AudioLevels(system: 0.45, microphone: 0.25), separateAudio: true)
        try await h.feed(60..<75)
        let offline = h.directory.appendingPathComponent("disconnected-library")
        try FileManager.default.moveItem(at: h.library, to: offline)
        await h.controller.flushPending()
        await h.engine.stop()
        let retained = try FileManager.default.contentsOfDirectory(at: h.cache, includingPropertiesForKeys: nil).filter { AutoMomentClipController.isRecoverable(directory: $0) }
        try SelfTest.require(h.saved.isEmpty && h.controller.pendingCount == 0 && retained.count == 1, "Offline destination retains a completed job instead of losing its sources or hanging shutdown")
        let manifest = try AutoMomentClipManifest.load(in: retained[0])
        let originalFiles = try manifest.files.map { try Data(contentsOf: retained[0].appendingPathComponent($0.name)) }
        let retry = AutoMomentClipController(defaults: h.defaults, engine: nil, onReady: { job in try await h.publish(job) })
        retry.enabled = false; retry.beforeSeconds = 0; retry.afterSeconds = 0
        var failed = false
        do { _ = try await retry.recover(directory: retained[0]) } catch { failed = true }
        let afterFailure = try manifest.files.map { try Data(contentsOf: retained[0].appendingPathComponent($0.name)) }
        try SelfTest.require(failed && afterFailure == originalFiles, "Failed offline recovery leaves the original compressed sources unchanged")
        try FileManager.default.moveItem(at: offline, to: h.library)
        let recovered = try await retry.recover(directory: retained[0])
        guard let saved = h.saved.first else { throw SpyError.message("TEST FAILED: Recovered automatic clip missing") }
        try SelfTest.require(recovered == saved.url && !FileManager.default.fileExists(atPath: retained[0].path), "Successful retry publishes the movie before removing retained sources")
        try SelfTest.require(abs(saved.duration - (2.5 - 1.0 / 30)) < 0.08 && saved.systemGain == 0.45 && saved.microphoneGain == 0.25 && saved.separate, "Recovery preserves the shortened selection and frozen settings with replay disabled")
        print("PASS: early-stop pinning, unavailable destination, durable sources, failed offline retry and exact recovered selection independent of current settings")
    }

    private static func sessionRestart(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        h.controller.enabled = true; h.controller.beforeSeconds = 1; h.controller.afterSeconds = 10
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<60)
        let marker = try h.mark()
        await h.controller.capture(marker: marker, levels: AudioLevels(), separateAudio: false)
        let oldSession = h.engine.captureProgress()?.sessionID
        // Even a caller missing the preferred flush hook must retain/publish
        // its pre-roll rather than combining two independent capture sessions.
        await h.engine.stop()
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<10, sourceStart: 1000)
        try SelfTest.require(h.engine.captureProgress()?.sessionID != oldSession, "Encoder restart changes the capture session identity")
        try await h.waitForIdle()
        try SelfTest.require(h.saved.count == 1 && h.saved[0].sourceIntervals.allSatisfy { $0.end < 110 } && h.saved[0].duration < 1.1, "Session restart finalizes only pinned old-session frames")
        await h.engine.stop()
        print("PASS: session replacement cannot merge unrelated capture footage or lose previously pinned source files")
    }

    private static func immediateZeroPreRollStop(_ directory: URL) async throws {
        let h = try Harness(directory); defer { h.cleanup() }
        h.controller.enabled = true; h.controller.beforeSeconds = 0; h.controller.afterSeconds = 10
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<60)
        await h.controller.capture(marker: try h.mark(), levels: AudioLevels(), separateAudio: false)
        await h.controller.flushPending()
        await h.engine.stop()
        try SelfTest.require(h.saved.count == 1 && abs(h.saved[0].duration - 0.05) < 0.015 && (1...3).contains(h.saved[0].decodedFrames), "Immediate stop with zero pre-roll saves the nearest available 50ms instead of stranding an unexportable single frame")
        try h.engine.beginTest(seconds: 2)
        try await h.feed(0..<1, sourceStart: 300)
        await h.controller.capture(marker: try h.mark(), levels: AudioLevels(), separateAudio: false)
        await h.controller.flushPending()
        await h.engine.stop()
        try SelfTest.require(h.saved.count == 2 && h.saved[1].decodedFrames == 1 && h.saved[1].duration < 0.05, "A complete single-frame source can still be finalized on stop")
        print("PASS: zero pre-roll with immediate stop finalizes a valid 50ms selection, including a complete single-frame capture")
    }
}
