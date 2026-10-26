import AppKit
import AVFoundation
import Combine

/// Exercises AppModel's actual automation hooks with a real video encoder,
/// isolated preferences, temporary libraries and injected application processes.
@MainActor enum AutomationIntegrationTests {
    @MainActor private final class Harness {
        let suite: String
        let defaults: UserDefaults
        let model: AppModel
        var processes: [GameAutoCaptureProcess] = []
        var startAttempts = 0
        let game = GameAutoCaptureApplication(bundleID: "test.spy.integration.game", name: "Integration Game")

        init(persistedGameReplay: Bool = false, startOnLaunch: Bool = false) {
            suite = "Spy.AutomationIntegrationTests." + UUID().uuidString
            let isolatedDefaults = UserDefaults(suiteName: suite)!
            defaults = isolatedDefaults
            if persistedGameReplay {
                isolatedDefaults.set(true, forKey: "lastReplayEnabled")
                isolatedDefaults.set(true, forKey: "gameOwnedReplay")
            }
            isolatedDefaults.set(startOnLaunch, forKey: "startBufferOnLaunch")
            model = AppModel(preview: true, defaults: isolatedDefaults,
                captureAccess: CaptureAccess(screenAllowed: { true }, microphoneStatus: { .authorized }, requestMicrophone: { false }))
            model.minutes = 0.5
            model.systemAudio = false; model.microphone = false
            model.notificationsEnabled = false; model.autoCleanup = false; model.saveBufferOnExit = false
            model.gameAutoCapture = GameAutoCaptureController(defaults: defaults, workspaceCenter: NotificationCenter(),
                runningApplications: { [weak self] in self?.processes ?? [] }, terminationDelayNanoseconds: 0)
            model.captureStartOverride = { [weak self] config in
                guard let self else { throw CancellationError() }
                self.startAttempts += 1
                try self.model.engine.beginTest(seconds: config.seconds)
                try await self.feed(0..<60)
                try await self.model.engine.waitForFirstFrame(timeout: 0.5)
            }
        }

        func installGames(restorationFinished: Bool = true) {
            model.gameAutoCapture.add(game)
            model.gameAutoCapture.enabled = true
            model.sessionRestorationFinished = restorationFinished
            model.setupAutomation()
        }

        func launchGame() {
            processes = [GameAutoCaptureProcess(processID: 123, bundleID: game.bundleID, name: game.name)]
            model.gameAutoCapture.refreshRunningApplications()
        }

        func closeGame() {
            processes = []
            model.gameAutoCapture.refreshRunningApplications()
        }

        func feed(_ frames: Range<Int>) async throws {
            for frame in frames {
                let pts = CMTime(value: 90_000 + Int64(frame), timescale: 30)
                model.engine.testFrame(try SelfTest.pixel(frame: frame), at: pts)
                try await Task.sleep(nanoseconds: 8_000_000)
            }
        }

        func cleanup() async {
            model.gameAutoCapture.uninstall(); model.automationInstalled = false
            model.manualSaving = false
            await model.flushAutoMoments()
            await model.engine.stop()
            model.recording = false; model.endCaptureActivity()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent())
        }
    }

    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await immediateMarkerAndStop(directory: directory)
        try await failedGameSaveRetainsCapture(directory: directory)
        try await restoredUserIntentStaysManual()
        try await automaticOriginAndPrivacyStop()
    }

    private static func waitFor(_ message: String, timeout: TimeInterval = 15,
                                _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try SelfTest.require(predicate(), message)
    }

    private static func decodedFrameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw SpyError.message("TEST FAILED: Automation movie has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try SelfTest.require(reader.startReading(), "Automation movie opens for complete decode")
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        try SelfTest.require(reader.status == .completed, "Automation movie decodes without a truncated final frame")
        return frames
    }

    private static func immediateMarkerAndStop(directory: URL) async throws {
        let h = Harness()
        do {
            let model = h.model
            model.autoMomentClips.enabled = true
            model.autoMomentClips.beforeSeconds = 2; model.autoMomentClips.afterSeconds = 10
            await model.start(requestPermission: false)
            try SelfTest.require(model.recording && model.engine.testStats().frameCount == 60, "Real encoder is running before AppModel queues an automatic marker")

            // Synchronously overlap a manual save with the actual automatic
            // export's counter transition; finishing that export must leave the
            // independent manual-saving state set.
            var sawAutomaticExport = false
            let subscription = model.$autoClipExports.sink { count in
                if count > 0 { sawAutomaticExport = true; model.saving = true }
            }
            model.addMomentMarker()
            try SelfTest.require(model.markerCaptureTasks.count == 1, "Marker hook queues its pinning task before returning to UI")
            // No yield between marking and Stop: this catches dropping a queued
            // pre-roll snapshot before the engine clears its temporary ring.
            await model.stop()
            subscription.cancel()
            try SelfTest.require(!model.recording && model.markerCaptureTasks.isEmpty && model.autoMomentClips.pendingCount == 0,
                "Immediate Stop awaits queued marker pinning and finalizes the available automatic movie")
            try SelfTest.require(sawAutomaticExport && model.autoClipExports == 0 && model.manualSaving && model.saving,
                "Automatic export completion releases only its own counter and preserves an overlapping manual save")
            model.saving = false
            try SelfTest.require(!model.saving && !model.manualSaving, "Saving becomes idle only after the independent manual operation finishes")
            guard let clip = model.clips.first(where: { $0.url.lastPathComponent.hasPrefix("Spy_Auto_") }) else {
                throw SpyError.message("TEST FAILED: Immediate-stop automatic movie missing: " + (model.autoMomentClips.lastError ?? "unknown"))
            }
            let frames = try await decodedFrameCount(clip.url)
            try SelfTest.require(frames >= 57 && frames <= 60 && clip.duration > 1.8 && clip.duration < 2.1,
                "Immediate-stop automatic clip preserves real pre-marker frames and shortens unavailable future content")
            try SelfTest.require(model.metadata.get(clip.url).markers.count == 1, "AppModel publishes the automatic movie together with its marker metadata")
            try FileManager.default.copyItem(at: clip.url, to: directory.appendingPathComponent("immediate-marker-stop.mov"))
            await h.cleanup()
            print("PASS: AppModel marker task followed by immediate Stop pins real pre-roll, decodes final video, stores its marker and preserves overlapping manualSaving accounting")
        } catch { await h.cleanup(); throw error }
    }

    private static func failedGameSaveRetainsCapture(directory: URL) async throws {
        let h = Harness()
        do {
            let model = h.model
            h.installGames(); h.launchGame()
            try await waitFor("Injected game launch starts the real engine and retains controller ownership through recording/busy didSet callbacks") {
                model.recording && !model.busy && model.gameAutoCapture.ownsReplay
            }
            try SelfTest.require(h.startAttempts == 1, "Runtime callbacks during automatic start do not steal ownership or start a second encoder")
            let original = try await model.engine.snapshot(seconds: 30)
            let originalPackets = try await AudioTests.packetHashes(original.urls)
            try FileManager.default.removeItem(at: original.directory)
            let originalSession = model.engine.captureProgress()?.sessionID
            let offline = model.libraryURL.deletingLastPathComponent().appendingPathComponent("OfflineLibrary")
            try FileManager.default.moveItem(at: model.libraryURL, to: offline)
            h.closeGame()
            try await waitFor("Failed game autosave returns without clearing the live capture or hanging its busy gate") {
                model.gameAutoCapture.error != nil && !model.busy
            }
            try SelfTest.require(model.recording && model.gameAutoCapture.ownsReplay && model.lastReplayEnabled
                && model.engine.captureProgress()?.sessionID == originalSession && model.engine.captureProgress()?.isActive == true,
                "Unavailable game-save destination preserves the active capture session, ownership and replay intent")
            model.refreshRecoveryFolders()
            guard let retained = model.recoveryFolders.first(where: { $0.lastPathComponent.hasPrefix("record-replay-game-") }) else {
                throw SpyError.message("TEST FAILED: Failed game autosave did not retain its recovery snapshot")
            }
            let recovery = try await MediaSharing.recoverySnapshot(directory: retained)
            let retainedPackets = try await AudioTests.packetHashes(recovery.urls)
            try SelfTest.require(!originalPackets.isEmpty && originalPackets.isSubset(of: retainedPackets),
                "Failed game autosave retains every original compressed frame in its durable recovery folder")
            try await h.feed(60..<75)
            let stillLive = try await model.engine.snapshot(seconds: 30)
            let livePackets = try await AudioTests.packetHashes(stillLive.urls)
            try FileManager.default.removeItem(at: stillLive.directory)
            try SelfTest.require(originalPackets.isSubset(of: livePackets) && livePackets.count > originalPackets.count,
                "Original ring frames survive the failed save and the real encoder continues accepting new frames")
            try FileManager.default.moveItem(at: offline, to: model.libraryURL)
            model.gameAutoCapture.retry()
            try await waitFor("Retry saves the owned game buffer and stops capture after the library returns") {
                !model.recording && !model.busy && !model.gameAutoCapture.ownsReplay
            }
            try SelfTest.require(!model.lastReplayEnabled && !model.saving && model.autoClipExports == 0 && !model.manualSaving,
                "Successful automatic stop clears only its replay intent and releases every save gate")
            guard let clip = model.clips.first(where: { $0.url.lastPathComponent.hasPrefix("Spy_Session_") }) else {
                throw SpyError.message("TEST FAILED: Game buffer was not saved on retry")
            }
            let decoded = try await decodedFrameCount(clip.url)
            try SelfTest.require(decoded == 75, "Game autosave retry exports every original and newly recorded frame")
            try FileManager.default.copyItem(at: clip.url, to: directory.appendingPathComponent("game-autosave-retry.mov"))
            await h.cleanup()
            print("PASS: actual game launch owns replay through didSet callbacks; offline auto-stop retains original packets and a live ring; retry saves all 75 frames before stopping")
        } catch { await h.cleanup(); throw error }
    }

    private static func restoredUserIntentStaysManual() async throws {
        let h = Harness()
        do {
            let model = h.model
            model.setReplayIntent(true)
            model.manualPrivacyPause = true
            h.installGames(restorationFinished: false); h.launchGame()
            await model.restoreLastSession()
            try SelfTest.require(!model.recording && h.startAttempts == 0 && model.lastReplayEnabled,
                "A privacy-blocked session restore preserves user intent without starting capture")
            model.sessionRestorationFinished = true; model.manualPrivacyPause = false
            model.automationRuntimeChanged()
            for _ in 0..<30 { await Task.yield() }
            try SelfTest.require(h.startAttempts == 0 && !model.gameAutoCapture.ownsReplay,
                "Game automation cannot appropriate restored user intent while waiting for privacy resume")
            await model.restoreLastSession()
            try SelfTest.require(model.recording && !model.gameAutoCapture.ownsReplay, "Resumed session remains user-owned")
            h.closeGame()
            for _ in 0..<30 { await Task.yield() }
            try SelfTest.require(model.recording && model.lastReplayEnabled && !model.gameAutoCapture.ownsReplay,
                "Closing a selected game never stops a restored user replay")
            await h.cleanup()
            print("PASS: deferred session restoration protects manual replay ownership before privacy unlock and after selected-game exit")
        } catch { await h.cleanup(); throw error }
    }

    private static func automaticOriginAndPrivacyStop() async throws {
        let h = Harness(persistedGameReplay: true)
        do {
            let model = h.model
            try SelfTest.require(model.lastReplayEnabled && h.defaults.bool(forKey: "gameOwnedReplay"),
                "A new model loads the prior automatic replay origin from isolated persisted preferences")
            h.installGames(restorationFinished: false)
            await model.restoreLastSession()
            model.sessionRestorationFinished = true; model.automationRuntimeChanged()
            for _ in 0..<30 { await Task.yield() }
            try SelfTest.require(!model.recording && h.startAttempts == 0 && !model.lastReplayEnabled,
                "Restoring a prior automatic session with no selected game does not create a user-owned replay")
            h.launchGame()
            try await waitFor("A selected game's actual launch restarts the prior automatic replay with automatic ownership") {
                model.recording && !model.busy && model.gameAutoCapture.ownsReplay
            }
            try SelfTest.require(h.defaults.bool(forKey: "gameOwnedReplay"), "Automatic launch records its persisted automatic-session origin")
            model.manualPrivacyPause = true
            await model.reconcilePrivacyState()
            try SelfTest.require(model.recording && model.privacyPaused && model.manualPrivacyPause,
                "A user privacy pause retains the automatic game's buffered session")
            h.closeGame()
            try await waitFor("Closing a privacy-paused game's last process saves its ring and finishes automatic stop") {
                !model.recording && !model.busy && !model.gameAutoCapture.ownsReplay
            }
            try SelfTest.require(!model.privacyPaused && !model.manualPrivacyPause && !model.lastReplayEnabled
                && !h.defaults.bool(forKey: "gameOwnedReplay"),
                "Successful automatic stop clears both transient privacy flags and the persisted automatic-session origin")
            h.launchGame()
            try await waitFor("The next selected-game launch starts after a privacy-paused automatic stop") {
                h.startAttempts == 2 && model.recording && !model.busy && model.gameAutoCapture.ownsReplay
            }
            h.closeGame()
            try await waitFor("The second automatic game session also saves and stops normally") {
                !model.recording && !model.busy && !model.gameAutoCapture.ownsReplay
            }
            await h.cleanup()
        } catch { await h.cleanup(); throw error }

        let explicitLaunch = Harness(persistedGameReplay: true, startOnLaunch: true)
        do {
            let model = explicitLaunch.model
            explicitLaunch.installGames(restorationFinished: false)
            await model.restoreLastSession()
            model.sessionRestorationFinished = true; model.automationRuntimeChanged()
            try SelfTest.require(model.recording && model.lastReplayEnabled && !explicitLaunch.defaults.bool(forKey: "gameOwnedReplay")
                && !model.gameAutoCapture.ownsReplay,
                "Explicit start-on-launch preference deliberately restores a user-owned replay instead of automatic game ownership")
            explicitLaunch.launchGame(); explicitLaunch.closeGame()
            for _ in 0..<30 { await Task.yield() }
            try SelfTest.require(model.recording && model.lastReplayEnabled,
                "A game closing never stops the explicit start-on-launch replay")
            await explicitLaunch.cleanup()
            print("PASS: automatic origin survives model recreation without false manual restore; paused game exit clears privacy gates; next game restarts; explicit start-on-launch remains user-owned")
        } catch { await explicitLaunch.cleanup(); throw error }
    }
}
