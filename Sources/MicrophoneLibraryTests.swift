import AVFoundation
import Foundation

@MainActor enum MicrophoneLibraryTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("source-cache"))
        try engine.beginTest(seconds: 20, audio: true, microphone: true)
        for frame in 0..<90 {
            let pts = CMTime(value: 120_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440, amplitude: 0.06))
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997, amplitude: 0.06), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let snapshot = try await engine.snapshot(seconds: 20)
        let fixture = directory.appendingPathComponent("editable-microphone.mov")
        try await SpyExporter.export(snapshot, to: fixture, separateAudio: false, editableMicrophone: true, removeSnapshot: false)
        let source = AVURLAsset(url: fixture)
        let sourceTracks = try await source.loadTracks(withMediaType: .audio)
        try SelfTest.require(sourceTracks.count == 2, "Application save preserves microphone independently even when the old separate-audio setting is off")
        let controls = try await VideoAudioControls.load(url: fixture)
        try SelfTest.require(controls.canMuteMicrophone && !controls.hasUnidentifiedAudio, "Player identifies the named microphone rather than guessing from track order")
        let originalItem = controls.item
        controls.microphoneEnabled = false
        for parameter in controls.item.audioMix?.inputParameters ?? [] {
            var first: Float = -1, last: Float = -1, range = CMTimeRange.invalid
            try SelfTest.require(parameter.getVolumeRamp(for: .zero, startVolume: &first, endVolume: &last, timeRange: &range), "Player exposes an explicit source gain")
            try SelfTest.require(first == (controls.microphoneIDs.contains(parameter.trackID) ? 0 : 1), "Muting microphone keeps system sound at its original volume")
        }
        controls.microphoneEnabled = true
        try SelfTest.require(controls.item === originalItem, "Switching microphone neither replaces nor restarts the player item")
        let editable = try await EditableVideoAudio.load(url: fixture)
        let muted = directory.appendingPathComponent("muted-copy.mov")
        try await editable.export(to: muted, microphoneEnabled: false)
        try await requireSystemOnly(muted)
        let shared = directory.appendingPathComponent("muted-share.mp4")
        try await MediaSharing.exportMP4(source: fixture, to: shared, microphoneEnabled: false)
        try await requireSystemOnly(shared)
        let beforeHashes = try await AudioTests.packetHashes([fixture])
        let afterHashes = try await AudioTests.packetHashes([muted])
        try SelfTest.require(beforeHashes == afterHashes, "Muting a copy preserves every original compressed H.264 packet")
        let legacy = directory.appendingPathComponent("legacy-mixed.mov")
        try await SpyExporter.export(snapshot, to: legacy, separateAudio: false)
        let legacyControls = try await VideoAudioControls.load(url: legacy)
        try SelfTest.require(!legacyControls.canMuteMicrophone && legacyControls.hasUnidentifiedAudio, "An already mixed legacy file never claims independently removable voice")
        await engine.stop()
        try engine.beginTest(seconds: 5, audio: false, microphone: true)
        for frame in 0..<30 {
            let pts = CMTime(value: 180_000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997, amplitude: 0.06), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let micOnly = directory.appendingPathComponent("microphone-only.mov")
        let micSnapshot = try await engine.snapshot(seconds: 5)
        try await SpyExporter.export(micSnapshot, to: micOnly, editableMicrophone: true)
        let micControls = try await VideoAudioControls.load(url: micOnly)
        try SelfTest.require(micControls.canMuteMicrophone, "A microphone-only recording keeps its source tag")
        let silent = directory.appendingPathComponent("microphone-only-muted.mov")
        let micSource = try await EditableVideoAudio.load(url: micOnly)
        try await micSource.export(to: silent, microphoneEnabled: false)
        let silentAsset = AVURLAsset(url: silent)
        let silentAudio = try await silentAsset.loadTracks(withMediaType: .audio)
        let silentVideo = try await silentAsset.loadTracks(withMediaType: .video)
        try SelfTest.require(silentAudio.isEmpty && silentVideo.count == 1, "Muting the only microphone source exports a valid silent video")
        await engine.stop()
        print("PASS: editable microphone tags, independent player mute/unmute, system-only MOV/MP4, original H.264 and honest legacy mixed-audio state")

        let model = AppModel(preview: true)
        let root = model.libraryURL.deletingLastPathComponent()
        defer { model.libraryMonitor?.stop(); try? FileManager.default.removeItem(at: root) }
        model.microphone = true; model.systemAudio = true; model.separateAudio = false
        model.refreshMicrophones(); model.microphoneID = "preview-mic"
        let persisted = model.preferences.string(forKey: "microphoneID")
        model.refreshMicrophones()
        try SelfTest.require(persisted == "preview-mic" && model.microphones.contains(where: { $0.id == model.microphoneID }), "Device choice persists and refreshing the list preserves selection")
        try model.engine.beginTest(seconds: 20, audio: true, microphone: true)
        for frame in 0..<60 {
            let pts = CMTime(value: 150_000 + Int64(frame), timescale: 30)
            model.engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            model.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440, amplitude: 0.06))
            model.engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997, amplitude: 0.06), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        model.recording = true; model.stats = model.engine.testStats()
        await model.saveSpy()
        guard let saved = model.clips.first else { throw SpyError.message("TEST FAILED: App save missing") }
        let savedControls = try await VideoAudioControls.load(url: saved.url)
        try SelfTest.require(savedControls.canMuteMicrophone, "Normal replay button produces editable microphone audio")
        await model.previewBuffer()
        guard let preview = model.bufferPreview, let playback = preview.playback else { throw SpyError.message("TEST FAILED: Buffer preview missing") }
        let liveControls = playback.videoAudioControls()
        try SelfTest.require(liveControls.canMuteMicrophone, "Unsaved buffer exposes microphone independently")
        liveControls.microphoneEnabled = false
        let noMic = try await model.saveBufferPreview(preview, microphoneEnabled: false)
        try await requireSystemOnly(noMic)
        let withMic = try await model.saveBufferPreview(preview, microphoneEnabled: true)
        let withMicControls = try await VideoAudioControls.load(url: withMic)
        try SelfTest.require(withMic != noMic && withMicControls.canMuteMicrophone, "Preview save identity distinguishes muted and original audio")
        let retry = try await model.saveBufferPreview(preview, microphoneEnabled: false)
        try SelfTest.require(retry == noMic, "Repeated muted save reuses its own completed result")
        model.closeBufferPreview()
        let copy = try await model.trimClip(saved, start: 0, end: saved.duration, microphoneEnabled: false)
        try await requireSystemOnly(copy)
        await model.stop()
        print("PASS: persisted device selection, application replay/preview/copy paths, retained microphone sources and separate idempotent saves for muted audio")

        let libraryModel = AppModel(preview: true)
        let library = libraryModel.libraryURL
        let libraryRoot = library.deletingLastPathComponent()
        defer { libraryModel.libraryMonitor?.stop(); try? FileManager.default.removeItem(at: libraryRoot) }
        let clipURL = library.appendingPathComponent("Spy_Finder_Test.mov")
        try FileManager.default.copyItem(at: fixture, to: clipURL)
        try libraryModel.metadata.set(ClipMetadata(name: "Finder test", favorite: true), for: clipURL)
        await libraryModel.reloadClips()
        guard let stale = libraryModel.clips.first else { throw SpyError.message("TEST FAILED: Library fixture absent") }
        libraryModel.selectedClip = stale
        libraryModel.setupLibraryMonitoring()
        let moved = libraryRoot.appendingPathComponent("moved.mov")
        try FileManager.default.moveItem(at: clipURL, to: moved)
        try await wait("External deletion/move removes stale cards and dismisses an absent selected video") {
            libraryModel.clips.isEmpty && libraryModel.selectedClip == nil
        }
        await libraryModel.trash(stale)
        try SelfTest.require(libraryModel.error == nil && libraryModel.clips.isEmpty, "Deleting an already missing file is idempotent, not an alert")
        try FileManager.default.moveItem(at: moved, to: clipURL)
        try await wait("Restored external file reappears automatically with its favorite metadata") {
            libraryModel.clips.count == 1 && libraryModel.clips[0].favorite
        }
        let renamed = library.appendingPathComponent("Spy_Renamed_Outside.mov")
        try FileManager.default.moveItem(at: clipURL, to: renamed)
        try await wait("Finder rename replaces the old URL without duplicate ghosts") {
            libraryModel.clips.count == 1 && libraryModel.clips[0].url == renamed.spyFileURL
        }
        let detached = libraryRoot.appendingPathComponent("detached-library")
        try FileManager.default.moveItem(at: library, to: detached)
        try await wait("Missing library clears stale rows") { libraryModel.clips.isEmpty }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: clipURL)
        try await wait("Recreated folder is detected without an app restart", timeout: 7) {
            libraryModel.clips.count == 1 && libraryModel.clips[0].url == clipURL.spyFileURL
        }
        print("PASS: real directory notifications, external move/rename/delete, missing-file delete, selected-player dismissal, favorites retained and recreated directory detection")
    }

    private static func requireSystemOnly(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try SelfTest.require(tracks.count == 1, "Muted copy retains exactly the system audio track")
        let samples = try AudioTests.samples(asset, track: tracks[0])
        try SelfTest.require(AudioTests.magnitude(samples, frequency: 440) > 0.015 && AudioTests.magnitude(samples, frequency: 997) < 0.003,
            "Saved output contains audible system tone with microphone removed")
    }
    private static func wait(_ message: String, timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        try SelfTest.require(condition(), message)
    }
}
