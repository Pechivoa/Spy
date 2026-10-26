import AppKit
import AVFoundation

@MainActor enum FeatureTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        func clip(_ name: String, days: Int, bytes: Int64, favorite: Bool = false) -> Clip {
            Clip(url: directory.appendingPathComponent(name + ".mov"), date: now.addingTimeInterval(-Double(days) * 86400), bytes: bytes, favorite: favorite)
        }
        let oldest = clip("oldest", days: 100, bytes: 100)
        let favorite = clip("favorite", days: 99, bytes: 800, favorite: true)
        let opened = clip("opened", days: 98, bytes: 100)
        let recent = clip("recent", days: 1, bytes: 100)
        let clips = [recent, opened, favorite, oldest]
        let quota = CleanupPolicy(enabled: true, maximumBytes: 950, maximumAgeDays: 0)
        try SelfTest.require(quota.plan(clips, protecting: [opened.id], now: now).map(\.id) == [oldest.id, recent.id], "Quota removes oldest first, protects favorite and open clip")
        let age = CleanupPolicy(enabled: true, maximumBytes: 5000, maximumAgeDays: 30)
        try SelfTest.require(age.plan(clips, protecting: [opened.id], now: now).map(\.id) == [oldest.id], "Age cleanup excludes protected clips")
        try SelfTest.require(CleanupPolicy(enabled: false, maximumBytes: 1, maximumAgeDays: 1).plan(clips).isEmpty, "Disabled cleanup never deletes")
        try SelfTest.require(quota.plan([favorite, opened], protecting: [opened.id]).isEmpty, "Favorites are retained even over quota")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let metadata = LibraryMetadata(url: metadataURL)
        let named = ClipMetadata(name: "Победа · русский текст", favorite: true)
        try metadata.set(named, for: favorite.url)
        try SelfTest.require(LibraryMetadata(url: metadataURL).get(favorite.url) == named && metadata.get(recent.url) == ClipMetadata(), "Names and favorites persist, old clips have defaults")
        let corrupt = directory.appendingPathComponent("broken-metadata.json")
        try Data("broken".utf8).write(to: corrupt)
        let broken = LibraryMetadata(url: corrupt)
        do { try broken.set(named, for: recent.url); throw SpyError.message("TEST FAILED: corrupt favorites overwritten") }
        catch { try SelfTest.require(broken.loadError != nil && (try? Data(contentsOf: corrupt)) == Data("broken".utf8), "Corrupt metadata remains recoverable and blocks writes") }
        let frame = SaveToast.frame(in: CGRect(x: 1920, y: -50, width: 1512, height: 940))
        try SelfTest.require(frame.maxX == 3412 && frame.maxY == 870, "Toast stays within selected display with 20px margins")
        print("PASS: disk quota, oldest-first and age rules, disabled cleanup, favorites/open-clip protection, persistent Unicode metadata, corrupt-file protection, notification geometry")

        for (rate, channels) in [(48000, 2), (44100, 1)] {
            let rms = AudioMeter.rms(try SelfTest.audio(frame: 0, pts: .zero, rate: rate, channels: channels, frequency: 900, amplitude: 0.4))
            try SelfTest.require(abs(rms - Float(0.4 / sqrt(2))) < 0.005, "Audio meters decode \(rate)Hz / \(channels) channels: \(rms)")
        }
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache"))
        try engine.beginTest(seconds: 600, audio: true, microphone: true)
        var measured = AudioMeter()
        engine.onLevels = { measured = $0 }
        for index in 0..<150 {
            let pts = CMTime(value: 24_000 + Int64(index), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: index), at: pts)
            engine.testAudio(try SelfTest.audio(frame: index, pts: pts, frequency: 440))
            engine.testAudio(try SelfTest.audio(frame: index, pts: pts, rate: 44100, channels: 1, frequency: 997), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let snapshot = try await engine.snapshot(seconds: 600)
        let output = directory.appendingPathComponent("volume-mix.mov")
        try await SpyExporter.export(snapshot, to: output, levels: AudioLevels(system: 0.25, microphone: 0.5))
        try SelfTest.require(measured.system > 0.1 && measured.microphone > 0.1, "Engine publishes both live meters")
        await engine.stop()
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        try SelfTest.require(abs(duration - 5) < 0.05, "Underfilled 10-minute quick save keeps all available 5 seconds")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let decoded = try AudioTests.samples(asset, track: audio[0])
        let systemGain = AudioTests.magnitude(decoded, frequency: 440)
        let micGain = AudioTests.magnitude(decoded, frequency: 997)
        try SelfTest.require(abs(systemGain - 0.0375) < 0.008 && abs(micGain - 0.075) < 0.012, "Separate gains reach saved soundtrack: \(systemGain), \(micGain)")
        let trimmed = directory.appendingPathComponent("user-trim.mov")
        try await ClipTrimmer.export(source: output, start: 0.33, end: 3.77, to: trimmed)
        let trimAsset = AVURLAsset(url: trimmed)
        let trimDuration = try await trimAsset.load(.duration).seconds
        let originalPackets = try await AudioTests.packetHashes([output])
        let trimPackets = try await AudioTests.packetHashes([trimmed])
        try SelfTest.require(abs(trimDuration - 3.44) < 0.04 && !trimPackets.isEmpty && trimPackets.isSubset(of: originalPackets), "User trim has exact duration and copies video packets")
        let trimAudio = try await trimAsset.loadTracks(withMediaType: .audio)
        let trimSamples = try AudioTests.samples(trimAsset, track: trimAudio[0])
        try SelfTest.require(AudioTests.magnitude(trimSamples, frequency: 440) > 0.02 && AudioTests.magnitude(trimSamples, frequency: 997) > 0.04, "Trim keeps both audible sources")
        let invalid = directory.appendingPathComponent("invalid.mov")
        do { try await ClipTrimmer.export(source: output, start: 4, end: 2, to: invalid); throw SpyError.message("TEST FAILED: reversed trim accepted") }
        catch { try SelfTest.require(!FileManager.default.fileExists(atPath: invalid.path) && FileManager.default.fileExists(atPath: output.path), "Invalid trim leaves original unchanged") }
        print("PASS: live RMS meters, separate 25%/50% gains, underfilled quick save, exact user trim, preserved compressed video and both audio sources")

        // Only microphone packets are produced while both sources are enabled.
        // Track tags must stop the system volume from muting that microphone.
        try engine.beginTest(seconds: 30, audio: true, microphone: true)
        for index in 0..<90 {
            let pts = CMTime(value: 30_000 + Int64(index), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: index), at: pts)
            engine.testAudio(try SelfTest.audio(frame: index, pts: pts, rate: 44100, channels: 1, frequency: 997), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let micSnapshot = try await engine.snapshot(seconds: 30)
        let micOutput = directory.appendingPathComponent("mic-only-volume.mov")
        try await SpyExporter.export(micSnapshot, to: micOutput, levels: AudioLevels(system: 0, microphone: 0.5))
        await engine.stop()
        let micAsset = AVURLAsset(url: micOutput)
        let micAudio = try await micAsset.loadTracks(withMediaType: .audio)
        let micSamples = try AudioTests.samples(micAsset, track: micAudio[0])
        try SelfTest.require(abs(AudioTests.magnitude(micSamples, frequency: 997) - 0.075) < 0.012, "Mic identity and gain survive silent system source")
        print("PASS: microphone source identity when system has no packets")

        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        let libraryClip = model.libraryURL.appendingPathComponent("original.mov")
        try FileManager.default.copyItem(at: output, to: libraryClip)
        await model.reloadClips()
        let original = model.clips[0]
        try model.setClipName(original, name: "  Победа  ")
        model.toggleFavorite(original)
        let fragment = try await model.trimClip(model.clips[0], start: 1, end: 2.5)
        await model.reloadClips()
        try SelfTest.require(model.clips.count == 2 && model.clips.allSatisfy(\.favorite) && model.clips.contains(where: { $0.url == fragment && $0.name == "Фрагмент · Победа" }), "App trim preserves original, creates named fragment and inherits favorite")
        await model.cleanupLibrary(manual: true)
        try SelfTest.require(model.clips.count == 2, "App defaults to no automatic cleanup")
        // Test recoverable cleanup only with generated media in the isolated library.
        let discard = model.libraryURL.appendingPathComponent("Spy_discard.mov")
        try FileManager.default.copyItem(at: output, to: discard)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: discard.path)
        await model.reloadClips()
        model.autoCleanup = true; model.maximumAgeDays = 1
        await model.cleanupLibrary(manual: true)
        try SelfTest.require(!FileManager.default.fileExists(atPath: discard.path) && model.clips.count == 2 && FileManager.default.fileExists(atPath: libraryClip.path), "Configured app cleanup trashes eligible generated clip, keeps favorites")
        print("PASS: app name/favorite edits, fragment creation, default cleanup off, actual recoverable cleanup on generated video")
        let quickModel = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: quickModel.libraryURL.deletingLastPathComponent()) }
        try quickModel.engine.beginTest(seconds: 600, audio: false)
        for index in 0..<60 {
            quickModel.engine.testFrame(try SelfTest.pixel(frame: index), at: CMTime(value: 36_000 + Int64(index), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        quickModel.recording = true; quickModel.stats = quickModel.engine.testStats()
        await quickModel.saveSpy(seconds: 30)
        await quickModel.engine.stop(); quickModel.recording = false
        try SelfTest.require(quickModel.error == nil && quickModel.clips.count == 1 && abs(quickModel.clips[0].duration - 2) < 0.05 && quickModel.message == "Повтор сохранён · 00:02", "App quick-save finds its exported clip and reports actual duration")
        print("PASS: full app quick-save flow and exported-clip lookup")
    }
}
