import AppKit
import AVFoundation

@MainActor enum ProTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("manual-cache"))
        try engine.beginTest(seconds: 0.5, audio: true, microphone: true)
        func feed(_ start: Int, _ end: Int) async throws {
            for frame in start..<end {
                let pts = CMTime(value: 42_000 + Int64(frame), timescale: 30)
                engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
                engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, rate: 44100, channels: 1, frequency: 997), microphone: true)
                try await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        try await feed(0, 30)
        try await engine.beginManual()
        try await feed(30, 105)
        let concurrent = try await engine.snapshot(seconds: 0.5)
        let replay = directory.appendingPathComponent("concurrent-replay.mov")
        try await SpyExporter.export(concurrent, to: replay)
        try await feed(105, 180)
        let stats = engine.testStats()
        try SelfTest.require(stats.manualSeconds > 4.9 && stats.seconds <= 0.51 && stats.manualBytes > stats.bytes, "Manual retains full session while replay ring remains bounded")
        let manual = try await engine.finishManual()
        try SelfTest.require(abs(manual.requestedSeconds - 5) < 0.04 && manual.urls.count >= 5, "Manual snapshot starts exactly at record boundary")
        let separate = directory.appendingPathComponent("manual-separate.mov")
        try await SpyExporter.export(manual, to: separate, levels: AudioLevels(system: 0.3, microphone: 0.6), separateAudio: true, removeSnapshot: false)
        let resumedReplay = try await engine.snapshot(seconds: 0.5)
        try await SpyExporter.export(resumedReplay, to: directory.appendingPathComponent("after-manual-replay.mov"))
        await engine.stop()
        try SelfTest.require(FileManager.default.fileExists(atPath: manual.urls[0].path), "Manual sources survive ring stop and export for recovery")
        let asset = AVURLAsset(url: separate)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(abs(duration - 5) < 0.04 && tracks.count == 2, "Manual records all 5 seconds with two audio tracks")
        var tags: [String: Double] = [:]
        for track in tracks {
            let metadata = try await track.load(.metadata)
            var tag = ""
            for item in metadata where item.identifier == .quickTimeMetadataTitle { tag = try await item.load(.stringValue) ?? "" }
            let samples = try AudioTests.samples(asset, track: track)
            let system = AudioTests.magnitude(samples, frequency: 440), mic = AudioTests.magnitude(samples, frequency: 997)
            if tag == AudioSource.system.rawValue { try SelfTest.require(abs(system - 0.045) < 0.01 && mic < 0.005, "System track contains only system at 30% gain"); tags[tag] = system }
            if tag == AudioSource.microphone.rawValue { try SelfTest.require(abs(mic - 0.09) < 0.012 && system < 0.005, "Microphone track contains only voice at 60% gain"); tags[tag] = mic }
        }
        try SelfTest.require(tags.count == 2, "Both source tags are preserved")
        let mp4 = directory.appendingPathComponent("share.mp4")
        try await MediaSharing.exportMP4(source: separate, to: mp4)
        let share = AVURLAsset(url: mp4)
        let shareAudio = try await share.loadTracks(withMediaType: .audio)
        let sharedSamples = try AudioTests.samples(share, track: shareAudio[0])
        try SelfTest.require(shareAudio.count == 1 && abs(AudioTests.magnitude(sharedSamples, frequency: 440) - 0.045) < 0.012 && abs(AudioTests.magnitude(sharedSamples, frequency: 997) - 0.09) < 0.015, "MP4 mixes both sources for sharing")
        let hashes = try await AudioTests.packetHashes([separate])
        let sharedHashes = try await AudioTests.packetHashes([mp4])
        try SelfTest.require(hashes == sharedHashes, "MP4 copies all original video packets")
        let item = try await MediaSharing.playerItem(url: separate)
        try SelfTest.require(item.audioMix?.inputParameters.count == 2, "Player explicitly mixes both separate tracks")
        let trim = directory.appendingPathComponent("separate-trim.mov")
        try await ClipTrimmer.export(source: separate, start: 0.4, end: 2.8, to: trim)
        let trimmedAudio = try await AVURLAsset(url: trim).loadTracks(withMediaType: .audio)
        try SelfTest.require(trimmedAudio.count == 2, "Trim retains separate audio tracks")
        let recovery = try await MediaSharing.recoverySnapshot(directory: manual.directory)
        try SelfTest.require(abs(recovery.requestedSeconds - 5) < 0.04, "Recovery finds and orders all pinned segments")
        try? FileManager.default.removeItem(at: manual.directory)
        print("PASS: manual/replay simultaneous recording, bounded ring, exact start/stop, separate source gains/tags, two-track player/trim, MP4 sound mix and unchanged H.264, recoverable source files")

        let model = AppModel(preview: true)
        let originalRoot = model.libraryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: originalRoot) }
        model.quality = .smooth; model.minutes = 10; model.microphone = true; model.systemVolume = 0.7; model.microphoneVolume = 0.4
        model.saveProfile(bundleID: "example.game", name: "Тестовая игра")
        let profile = model.profiles[0]
        let encoded = try JSONEncoder().encode(model.profiles)
        let decodedProfiles = try JSONDecoder().decode([AppProfile].self, from: encoded)
        try SelfTest.require(decodedProfiles == model.profiles, "Profiles retain complete settings across encoding")
        model.quality = .compact; model.minutes = 1; model.manualRecording = true
        await model.applyProfile(profile)
        try SelfTest.require(model.quality == .compact && model.pendingProfile == profile, "Profile switch is deferred during manual recording")
        model.manualRecording = false; await model.reconcilePendingChanges()
        try SelfTest.require(model.quality == .smooth && model.minutes == 10 && model.systemVolume == 0.7 && model.microphoneVolume == 0.4 && model.microphone, "Pending profile applies all capture and audio settings")
        model.batterySaving = true; model.batteryQuality = .compact; model.batteryMinutes = 2; model.onBattery = true
        try SelfTest.require(model.effectiveQuality == .compact && model.effectiveMinutes == 2 && model.quality == .smooth && model.minutes == 10, "Battery overrides preserve base settings")
        model.onBattery = false
        try SelfTest.require(model.effectiveQuality == .smooth && model.effectiveMinutes == 10, "AC restores base capture settings")
        var invalid = profile; invalid.settings.systemVolume = .nan
        do { try invalid.settings.validate(); throw SpyError.message("TEST FAILED: invalid profile accepted") } catch { try SelfTest.require(invalid.settings.systemVolume.isNaN, "Corrupt profile rejected") }
        await model.setLoginEnabled(true); try SelfTest.require(model.loginEnabled, "Login UI enables through isolated preview adapter")
        await model.setLoginEnabled(false); try SelfTest.require(!model.loginEnabled && !model.startBufferOnLaunch, "Login UI disables; automatic capture stays opt-in")
        for corner in HUDCorner.allCases {
            let rect = HUDOverlay.frame(visible: CGRect(x: 1920, y: -200, width: 1512, height: 982), corner: corner)
            try SelfTest.require(rect.minX >= 1940 && rect.maxX <= 3412 && rect.minY >= -180 && rect.maxY <= 762, "HUD fits selected monitor in every corner")
        }
        let visible = CGRect(x: 1920, y: -200, width: 1512, height: 982)
        let tiny = HUDOverlay.constrained(CGRect(x: 0, y: 0, width: 1, height: 1), visible: visible)
        let large = HUDOverlay.constrained(CGRect(x: 9000, y: 9000, width: 900, height: 900), visible: visible)
        try SelfTest.require(tiny.size == CGSize(width: 56, height: 18) && visible.contains(tiny) && large.size == CGSize(width: 220, height: 36) && visible.contains(large), "HUD resizes down to 56×18 and stays within its monitor")
        print("PASS: profiles persisted and deferred safely, source/device/gain settings, battery override and AC restore, corrupt profile validation, login preference flow without altering system startup, multi-monitor HUD placement")

        let oldClip = model.libraryURL.appendingPathComponent("Spy_old.mov")
        try FileManager.default.copyItem(at: separate, to: oldClip)
        await model.reloadClips(); try model.setClipName(model.clips[0], name: "Старое видео")
        let newFolder = directory.appendingPathComponent("ExternalSSD", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let unrelated = newFolder.appendingPathComponent("personal.mov")
        try FileManager.default.copyItem(at: separate, to: unrelated)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: unrelated.path)
        model.autoCleanup = true
        try await model.setLibraryFolder(newFolder)
        try SelfTest.require(!model.autoCleanup && model.libraryURL.path == newFolder.path && FileManager.default.fileExists(atPath: oldClip.path), "Folder selection leaves existing clips and disables cleanup for new location")
        model.autoCleanup = true; model.maximumAgeDays = 1
        await model.cleanupLibrary()
        try SelfTest.require(FileManager.default.fileExists(atPath: unrelated.path) && !model.clips[0].managed, "Auto cleanup protects unrelated videos in selected folder")
        let one = newFolder.appendingPathComponent("Spy_old.mov")
        try FileManager.default.copyItem(at: separate, to: one)
        await model.reloadClips()
        try SelfTest.require(model.clips.first(where: { $0.url.lastPathComponent == "Spy_old.mov" })?.name == "", "Identical filenames in different folders have independent metadata")
        let selected = model.clips.first(where: { $0.url.lastPathComponent == "Spy_old.mov" })!
        let exported = newFolder.appendingPathComponent("Spy_share.mp4")
        try await model.exportMP4(selected, destination: exported)
        try SelfTest.require(FileManager.default.fileExists(atPath: exported.path) && FileManager.default.fileExists(atPath: selected.url.path), "App MP4 export preserves original")
        model.selectedClip = selected
        do { try await model.setLibraryFolder(directory.appendingPathComponent("missing")); throw SpyError.message("TEST FAILED: missing directory accepted") }
        catch { try SelfTest.require(model.libraryURL.path == newFolder.path, "Missing SSD/folder does not reset library or write elsewhere") }
        let manualModel = AppModel(preview: true)
        let manualRoot = manualModel.libraryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: manualRoot) }
        try manualModel.engine.beginTest(seconds: 1, audio: false)
        manualModel.recording = true
        await manualModel.toggleManual()
        for frame in 0..<90 {
            manualModel.engine.testFrame(try SelfTest.pixel(frame: frame), at: CMTime(value: 48_000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let availableFolder = manualModel.libraryURL
        manualModel.libraryURL = manualRoot.appendingPathComponent("DisconnectedSSD")
        await manualModel.finishManual()
        try SelfTest.require(!manualModel.manualRecording && manualModel.recording && manualModel.recoveryFolders.count == 1 && manualModel.error != nil, "Disconnected SSD keeps completed manual sources available for retry while replay continues")
        await manualModel.engine.stop(); manualModel.recording = false
        try await manualModel.setLibraryFolder(availableFolder)
        manualModel.error = nil
        await manualModel.recoverRecording(manualModel.recoveryFolders[0])
        try SelfTest.require(manualModel.error == nil && manualModel.clips.count == 1 && abs(manualModel.clips[0].duration - 3) < 0.04 && manualModel.recoveryFolders.isEmpty, "App recovery saves complete manual recording after disk reconnect")
        print("PASS: app manual start/finish flow, disconnected disk preserves sources, replay keeps running, recovery saves full recording")
        print("PASS: alternate folder and SSD path, old clips retained, cleanup ownership protection, path-scoped metadata, app MP4 export, missing-folder handling")
    }
}
