import AppKit
import AVFoundation

@MainActor enum FullscreenEditorTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache"))
        try engine.beginTest(seconds: 10, audio: true, microphone: true)
        for frame in 0..<120 {
            let pts = CMTime(value: 9000 + Int64(frame), timescale: 30)
            engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 440))
            engine.testAudio(try SelfTest.audio(frame: frame, pts: pts, frequency: 997), microphone: true)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let snapshot = try await engine.snapshot(seconds: 4)
        let movie = directory.appendingPathComponent("editor-source.mov")
        try await SpyExporter.export(snapshot, to: movie, separateAudio: true, editableMicrophone: true)
        await engine.stop()
        let controls = try await VideoAudioControls.load(url: movie)
        let player = AVPlayer(playerItem: controls.item)
        player.isMuted = true
        defer { player.pause() }
        try await wait("A real movie item becomes ready") { controls.item.status == .readyToPlay }
        let duration = try await controls.item.asset.load(.duration).seconds
        let editor = PlayerEditingState()
        var publishedRange: (Double, Double)?
        var addedMarker: Double?
        var exported: (Double, Double, Bool)?
        var microphoneChanges: [Bool] = []
        var shouldFailSave = true
        editor.configure(player: player, duration: duration, frameRate: 60, audioControls: controls,
            onRangeChanged: { publishedRange = ($0, $1) },
            onMicrophoneChanged: { microphoneChanges.append($0) },
            onAddMarker: { addedMarker = $0 },
            onSave: { start, end, microphone in
                if shouldFailSave { throw SpyError.message("Synthetic destination unavailable") }
                exported = (start, end, microphone)
                return "Synthetic fragment saved"
            })
        defer { editor.detach() }
        try await wait("The source frame duration is read instead of keeping a 60 FPS fallback") { abs(editor.frameDuration - 1.0 / 30) < 0.001 }
        editor.seek(1)
        try await wait("Exact seek reaches the chosen source frame") { abs(player.currentTime().seconds - 1) < 0.001 }
        editor.stepFrames(1)
        do { try await wait("Frame forward advances one real 30 FPS frame") { abs(player.currentTime().seconds - 31.0 / 30) < 0.002 } }
        catch { throw SpyError.message("TEST FAILED: Frame forward: current=\(player.currentTime().seconds), frame=\(editor.frameDuration), canStep=\(controls.item.canStepForward), status=\(controls.item.status.rawValue)") }
        editor.stepFrames(-1)
        try await wait("Frame backward returns to the same real frame") { abs(player.currentTime().seconds - 1) < 0.002 }
        editor.setStartAtPlayhead()
        editor.setEndAtPlayhead()
        try await wait("Current-frame bounds resolve before saving") {
            !editor.isSeeking && !editor.isStepping && abs(editor.rangeStart - 1) < 0.002 && abs(editor.rangeEnd - 31.0 / 30) < 0.002
        }
        try SelfTest.require(abs(editor.rangeStart - 1) < 0.002 && abs(editor.rangeEnd - 31.0 / 30) < 0.002 && editor.canSave,
            "Selecting the current frame creates a valid one-frame exclusive range")
        try SelfTest.require(publishedRange != nil && abs(publishedRange!.0 - editor.rangeStart) < 0.000001 && abs(publishedRange!.1 - editor.rangeEnd) < 0.000001,
            "Fullscreen range changes reach the inline sheet")
        let originalItem = player.currentItem
        editor.setMicrophoneEnabled(false)
        try SelfTest.require(!controls.microphoneEnabled && !editor.microphoneEnabled && player.currentItem === originalItem,
            "Fullscreen microphone switch keeps the same item and system soundtrack")
        try SelfTest.require(microphoneChanges.last == false, "Microphone selection reaches the sheet save/export state")
        for parameter in controls.item.audioMix?.inputParameters ?? [] {
            var first: Float = -1, last: Float = -1
            var ramp = CMTimeRange.zero
            try SelfTest.require(parameter.getVolumeRamp(for: .zero, startVolume: &first, endVolume: &last, timeRange: &ramp), "Actual audio mix exposes source volume")
            try SelfTest.require(controls.microphoneIDs.contains(parameter.trackID) ? first == 0 : first > 0,
                "Only the actual microphone track is muted in the player mix")
        }
        editor.addMarker()
        try SelfTest.require(addedMarker != nil && abs(addedMarker! - player.currentTime().seconds) < 0.002,
            "A fullscreen marker uses the frozen movie playhead rather than live recording time")
        await editor.saveSelection()
        try SelfTest.require(editor.saveError?.contains("unavailable") == true && !editor.isSaving && editor.canSave,
            "A failed fullscreen save retains the selection for retry")
        shouldFailSave = false
        await editor.saveSelection()
        try SelfTest.require(editor.message == "Synthetic fragment saved" && editor.saveError == nil && exported != nil && exported!.2 == false,
            "Retry delivers selected range and microphone choice to the real sheet save callback")
        editor.selectAll()
        editor.seek(1)
        try await wait("Rapid-step fixture seek completes") { !editor.isSeeking && abs(player.currentTime().seconds - 1) < 0.002 }
        editor.stepFrames(1); editor.stepFrames(1); editor.stepFrames(1)
        editor.setStartAtPlayhead(); editor.addMarker()
        try SelfTest.require(!editor.canSave, "An unresolved frame request cannot save an old selection")
        try await wait("Rapid frame clicks accumulate, and queued playhead actions use the resolved target") {
            !editor.isSeeking && !editor.isStepping && abs(player.currentTime().seconds - 1.1) < 0.002 && abs(editor.rangeStart - 1.1) < 0.002
        }
        try SelfTest.require(addedMarker != nil && abs(addedMarker! - 1.1) < 0.002,
            "A marker queued after rapid frame steps does not use the previous frame")
        print("PASS: source frame duration, exact forward/backward frame stepping, one-frame selection, real microphone mix, playhead marker and save retry bridge")

        try await checkVariableFrameComposition(directory: directory)

        editor.setRange(start: 0.4, end: 0.8)
        editor.setLooping(true)
        editor.seek(0.65, resume: true)
        try await wait("Range playback starts") { player.rate > 0 }
        var previous = player.currentTime().seconds
        var wrapped = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 35_000_000)
            let next = player.currentTime().seconds
            if next + 0.15 < previous { wrapped = true }
            previous = next
            if wrapped && next > 0.6 { break }
        }
        try SelfTest.require(wrapped && player.rate > 0 && player.currentTime().seconds >= 0.39 && player.currentTime().seconds < 0.85,
            "A–B playback repeatedly seeks to A while staying inside the selected source range")
        editor.setLooping(false)
        try await wait("Disabling A–B pauses at B instead of continuing into unselected content") { player.rate == 0 && editor.currentTime >= 0.79 }
        print("PASS: real AVPlayer A–B wrap and normal end-of-range pause")

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = FullSizePlayerHost(player: player, title: "Synthetic editor", editor: editor)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        try await wait("An external sheet header can discover the attached player") { editor.canOpenFullScreen }
        try SelfTest.require(!host.expandButton.title.isEmpty && host.expandButton.imagePosition == .imageLeading,
            "The inline expand action has a visible text label rather than only a small overlay glyph")
        try SelfTest.require(host.playerView.frame.minY >= host.expandButton.frame.maxY + 1,
            "The expand action is laid out outside the native player rendering surface")
        try SelfTest.require(host.presentation.present(host, show: false), "The editor's fullscreen presentation is available")
        guard let panel = host.presentation.panel else { throw SpyError.message("TEST FAILED: fullscreen editor panel") }
        try SelfTest.require(panel.collectionBehavior.contains(.fullScreenNone) && !panel.styleMask.contains(.fullScreen) && host.playerView.superview === panel.contentView,
            "The same player view enters an editing presentation without a native excluded Space")
        let displayFrame = (window.screen ?? NSScreen.main)!.frame
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        panel.contentView?.layoutSubtreeIfNeeded()
        try SelfTest.require(panel.frame == displayFrame && panel.contentView?.bounds.size == displayFrame.size,
            "The editing toolbar cannot shrink fullscreen after SwiftUI layout: panel=\(panel.frame), content=\(String(describing: panel.contentView?.bounds)), display=\(displayFrame)")
        guard let controlsContainer = panel.contentView?.subviews.compactMap({ $0 as? FullSizeEditingControlsContainer }).first else {
            throw SpyError.message("TEST FAILED: fullscreen editing controls container")
        }
        for size in [NSSize(width: 1440, height: 900), displayFrame.size] {
            panel.setFrame(NSRect(origin: displayFrame.origin, size: size), display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 40_000_000)
            panel.contentView?.layoutSubtreeIfNeeded()
            try SelfTest.require(panel.frame.size == size && panel.contentView?.bounds.size == size &&
                abs(controlsContainer.controls.frame.width - min(1200, size.width - 40)) < 1 &&
                controlsContainer.bounds.contains(controlsContainer.controls.frame),
                "Display resize preserves the fullscreen canvas while centering a bounded editing toolbar")
        }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Task.sleep(nanoseconds: 40_000_000)
        panel.contentView?.layoutSubtreeIfNeeded()
        try SelfTest.require(host.presentation.panel === panel && panel.frame == displayFrame,
            "Dock/menu-bar geometry notifications keep the editing player on the entire original display")

        host.presentation.chromeIdleInterval = 0.1
        editor.selectAll(); editor.seek(1, resume: true)
        try await wait("Clean view fixture begins playing") { player.rate > 0 }
        host.presentation.noteInteraction(at: NSPoint(x: displayFrame.width / 2, y: displayFrame.height / 2))
        try await wait("Playback hides editing chrome after inactivity") { host.presentation.chromeHidden }
        panel.contentView?.layoutSubtreeIfNeeded()
        try SelfTest.require(host.playerView.frame.size == panel.contentView?.bounds.size && host.playerView.player === player && host.playerView.controlsStyle == .none,
            "Hidden chrome gives the same player the entire display without changing item or timeline")
        host.presentation.noteInteraction(at: NSPoint(x: 500, y: 500))
        try SelfTest.require(!host.presentation.chromeHidden && host.playerView.controlsStyle == .floating, "Pointer activity restores editing and native transport")
        host.presentation.setControlsPinned(true)
        try await Task.sleep(nanoseconds: 160_000_000)
        try SelfTest.require(!host.presentation.chromeHidden, "Pinned editing controls never auto-hide")
        host.presentation.setControlsPinned(false)
        player.pause()
        try await Task.sleep(nanoseconds: 160_000_000)
        try SelfTest.require(!host.presentation.chromeHidden, "Paused video keeps editing controls visible")
        let returnTime = player.currentTime().seconds
        panel.cancelOperation(nil)
        try SelfTest.require(host.playerView.superview === host && player.currentItem === originalItem && player.rate == 0 && abs(player.currentTime().seconds - returnTime) < 0.002,
            "Fullscreen return preserves the selected player's paused frame and item")
        editor.detach()
        try SelfTest.require(!editor.isLooping && !editor.canSave && editor.duration == 0 && host.presentation.panel == nil,
            "Closing the parent session cleans the fullscreen editor and stale callbacks")
        print("PASS: fullscreen retains full display width after SwiftUI layout and resizing, centered toolbar, geometry notifications, same-view Escape return and observer cleanup")
    }

    private static func wait(_ message: String, timeout: Double = 5, condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try SelfTest.require(condition(), message)
    }

    private static func checkVariableFrameComposition(directory: URL) async throws {
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("vfr-cache"))
        try engine.beginTest(seconds: 5)
        for (index, seconds) in [0.0, 0.1, 0.11, 0.4, 0.9].enumerated() {
            engine.testFrame(try SelfTest.pixel(frame: index * 20), at: CMTime(seconds: 400 + seconds, preferredTimescale: 60_000))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let snapshot = try await engine.snapshot(seconds: 5)
        let file = directory.appendingPathComponent("variable-frame-source.mov")
        try await SpyExporter.export(snapshot, to: file)
        await engine.stop()
        let source = AVURLAsset(url: file)
        guard let track = try await source.loadTracks(withMediaType: .video).first else { throw SpyError.message("TEST FAILED: variable-frame source track") }
        let length = try await source.load(.duration)
        let composition = AVMutableComposition()
        guard let shifted = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SpyError.message("TEST FAILED: shifted composition track") }
        try shifted.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: CMTime(seconds: 2, preferredTimescale: 60_000))
        let duration = try await composition.load(.duration).seconds
        let forward = try await SourceFrameStepper.targetTime(asset: composition, current: 2.1, offset: 1, duration: duration, frameDuration: 1.0 / 30)
        let backward = try await SourceFrameStepper.targetTime(asset: composition, current: 2.4, offset: -1, duration: duration, frameDuration: 1.0 / 30)
        try SelfTest.require(abs(forward - 2.11) < 0.001 && abs(backward - 2.11) < 0.001,
            "Compressed PTS lookup follows actual variable-rate frames and AVComposition insertion offsets rather than a nominal FPS grid: forward=\(forward), backward=\(backward)")
        let bounds = try await SourceFrameStepper.frameBounds(asset: composition, current: 2.105, duration: duration, frameDuration: 1.0 / 30)
        try SelfTest.require(abs(bounds.start - 2.1) < 0.000001 && abs(bounds.end - 2.11) < 0.000001,
            "A real 10ms frame ends at next output PTS, irrespective of a 33ms frame-duration hint")
        let final = try await SourceFrameStepper.frameBounds(asset: composition, current: duration - 0.001, duration: duration, frameDuration: 1.0 / 30)
        try SelfTest.require(abs(final.start - 2.9) < 0.000001 && abs(final.end - duration) < 0.000001,
            "The last frame ends at the clip duration rather than adding a nominal duration")

        let item = AVPlayerItem(asset: composition), player = AVPlayer()
        player.replaceCurrentItem(with: item); player.isMuted = true
        let editor = PlayerEditingState()
        var selected: (Double, Double)?
        editor.configure(player: player, duration: duration, frameRate: 30,
            onRangeChanged: { selected = ($0, $1) }, onSave: { _, _, _ in "saved" })
        defer { editor.detach(); player.pause() }
        try await wait("Variable-frame composition becomes ready") { item.status == .readyToPlay }
        editor.seek(2.105)
        try await wait("Subframe playhead seek resolves") { !editor.isSeeking && abs(player.currentTime().seconds - 2.105) < 0.001 }
        editor.setStartAtPlayhead(); editor.setEndAtPlayhead()
        try SelfTest.require(!editor.canSave, "Saving is gated while actual frame boundaries resolve")
        try await wait("Selecting a jitter frame uses exact source start and next PTS") {
            !editor.isStepping && abs(editor.rangeStart - 2.1) < 0.000001 && abs(editor.rangeEnd - 2.11) < 0.000001
        }
        try SelfTest.require(editor.canSave && selected != nil && abs(selected!.1 - selected!.0 - 0.01) < 0.000001,
            "A genuine 10ms frame survives editor validation and reaches the sheet unchanged")
        editor.seek(duration - 0.001)
        try await wait("Final-frame seek resolves") { !editor.isSeeking }
        editor.setStartAtPlayhead(); editor.setEndAtPlayhead()
        try await wait("Final-frame selection includes only the final source frame") {
            !editor.isStepping && abs(editor.rangeStart - 2.9) < 0.000001 && abs(editor.rangeEnd - duration) < 0.000001
        }
        try SelfTest.require(editor.canSave && frameClock(2.105) == "00:02.105", "Frame selection remains savable and milliseconds stay visible")
        print("PASS: VFR/shifted composition output PTS, actual next-frame exclusive bounds, true10ms selection/save gating and final-frame end")
    }
}
