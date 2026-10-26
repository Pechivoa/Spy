import AppKit
import AVKit
import ScreenCaptureKit

@MainActor enum CaptureReliabilityTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = SpyEngine(cacheRoot: directory.appendingPathComponent("cache"))
        try engine.beginTest(seconds: 3)
        let old = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let current = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        engine.testAdoptStream(current)
        let pixel = try SelfTest.pixel(frame: 90)
        for frame in 0..<18 {
            engine.testFrame(pixel, at: CMTime(value: 3000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let before = engine.testStats().frameCount
        let stopped = try sample(pixel, status: .stopped)
        engine.queue.sync { engine.stream(old, didOutputSampleBuffer: stopped, of: .screen) }
        engine.testTick(at: CMTime(value: 3018, timescale: 30))
        try SelfTest.require(engine.testStats().frameCount == before + 1, "A delayed stopped sample from the previous stream cannot clear the current source")
        var failure: String?
        engine.onFailure = { failure = $0 }
        engine.stream(old, didStopWithError: SpyError.message("Old stream callback"))
        try SelfTest.require(engine.captureProgress()?.isActive == true && failure == nil, "A late error from a different stream cannot stop the active session")
        let blank = try sample(pixel, status: .blank)
        engine.queue.sync { engine.stream(current, didOutputSampleBuffer: blank, of: .screen) }
        let blockedStats = engine.testStats()
        try SelfTest.require(blockedStats.actualFPS == 0 && blockedStats.sourceWarning != nil, "An unavailable screen immediately reports zero FPS and an honest warning")
        engine.testTick(at: CMTime(value: 3019, timescale: 30))
        try SelfTest.require(engine.testStats().frameCount == before + 1, "An unavailable source never fabricates new frames")
        let complete = try sample(pixel, status: .complete)
        engine.queue.sync { engine.stream(current, didOutputSampleBuffer: complete, of: .screen) }
        engine.testTick(at: CMTime(value: 3020, timescale: 30))
        try SelfTest.require(engine.testStats().sourceWarning == nil && engine.testStats().frameCount == before + 2, "A real frame restores the source and recording")
        engine.stream(current, didStopWithError: SpyError.message("Synthetic source failure"))
        try SelfTest.require(engine.captureProgress()?.isActive == false && failure != nil, "A real error from the current source still stops capture")
        await engine.stop(preserveForRecovery: true)
        let folders = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("cache"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("record-replay-failure-") }
        try SelfTest.require(folders.count == 1, "Fatal source failure retains a durable recovery folder")
        let recovered = try await MediaSharing.recoverySnapshot(directory: folders[0])
        let output = directory.appendingPathComponent("recovered-after-failure.mov")
        try await SpyExporter.export(recovered, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        try SelfTest.require(duration > 0.5, "Recovery preserves already encoded frames rather than deleting the ring")
        print("PASS: late-stream callbacks ignored, source availability reflected in FPS, real source resume and fatal-error ring recovery")

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = SpyWindowController(); controller.window = window
        controller.recording = true
        try SelfTest.require(window.collectionBehavior.contains(.fullScreenNone) && !window.collectionBehavior.contains(.fullScreenPrimary), "Recording prevents the excluded Spy window from creating a blank fullscreen Space")
        controller.recording = false
        try SelfTest.require(!window.collectionBehavior.contains(.fullScreenNone) && window.collectionBehavior.contains(.fullScreenPrimary), "Window fullscreen behavior is restored after recording")
        let activePlayer = NativePlayer(player: nil, allowsFullScreen: false).makePlayerView()
        let stoppedPlayer = NativePlayer(player: nil, allowsFullScreen: true).makePlayerView()
        try SelfTest.require(!activePlayer.showsFullScreenToggleButton && stoppedPlayer.showsFullScreenToggleButton, "The actual AVPlayerView hides fullscreen only while its screen is being captured")
        print("PASS: native window fullscreen protection and native player fullscreen policy")

        let item = AVPlayerItem(asset: asset)
        let playback = AVPlayer(playerItem: item)
        playback.volume = 0.37; playback.isMuted = true
        let host = FullSizePlayerHost(player: playback, title: "Synthetic playback")
        window.contentView = host
        let sourceFrame = window.frame
        let presentationOptions = NSApp.presentationOptions
        try SelfTest.require(host.presentation.present(host, show: false), "Full-size playback is available while native fullscreen remains protected")
        guard let fullSizeWindow = host.presentation.panel else { throw SpyError.message("TEST FAILED: full-size player window") }
        try SelfTest.require(fullSizeWindow.collectionBehavior.contains(.fullScreenNone) && !fullSizeWindow.styleMask.contains(.fullScreen), "Full-size playback never requests an excluded native fullscreen Space")
        try SelfTest.require(fullSizeWindow.frame == (window.screen ?? NSScreen.main)?.frame, "Full-size playback covers the originating display")
        try SelfTest.require(host.playerView.superview === fullSizeWindow.contentView && host.playerView.player === playback && playback.currentItem === item && !host.playerView.showsFullScreenToggleButton, "The actual player view and audio item are moved without creating another renderer")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Task.sleep(nanoseconds: 30_000_000)
        try SelfTest.require(host.presentation.panel === fullSizeWindow, "Dock and menu-bar presentation notifications cannot immediately close fullscreen playback")
        fullSizeWindow.cancelOperation(nil)
        try SelfTest.require(host.presentation.panel == nil && host.playerView.superview === host && window.frame == sourceFrame, "Escape restores the original player and leaves the source window unchanged")
        try SelfTest.require(playback.volume == 0.37 && playback.isMuted && playback.currentItem === item && NSApp.presentationOptions == presentationOptions, "Fullscreen exit preserves selected audio and presentation settings")
        try SelfTest.require(host.presentation.present(host, show: false), "Full-size playback can reopen")
        host.update(player: nil, title: "Closed snapshot")
        try SelfTest.require(host.presentation.panel == nil && host.playerView.superview === host && host.playerView.player == nil && !host.expandButton.isEnabled, "Replacing or closing a preview releases its fullscreen panel and disables stale media")
        print("PASS: full-size same-view playback, no native Space, Escape return, audio preservation and snapshot replacement cleanup")

        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        try model.engine.beginTest(seconds: 30)
        for frame in 0..<18 {
            model.engine.testFrame(pixel, at: CMTime(value: 6000 + Int64(frame), timescale: 30))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        model.recording = true; model.stats = model.engine.testStats()
        model.displayID = UInt32.max
        model.refreshDisplays()
        let deadline = Date().addingTimeInterval(3)
        while model.recording && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try SelfTest.require(!model.recording && model.displayID == UInt32.max && !model.recoveryFolders.isEmpty,
            "Disconnecting the selected display preserves encoded video and never silently records a different monitor")
        print("PASS: missing-display target remains explicit and model error-stop preserves the replay")
    }

    private static func sample(_ pixel: CVPixelBuffer, status: SCFrameStatus) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        try SelfTest.require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, "Screen sample format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 3020, timescale: 30), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let code = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &result)
        guard code == noErr, let result, let entries = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) else { throw SpyError.message("TEST FAILED: screen sample") }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(entries, 0), to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.status.rawValue as NSString, value = NSNumber(value: status.rawValue)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
        return result
    }
}
