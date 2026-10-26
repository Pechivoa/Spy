import AppKit
import Foundation

@MainActor enum GameAutoCaptureTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try testPolicy()
        try await testController()
        try await testFailuresAndOverrides()
        try await testRacesAndDebounce()
    }

    private static func settle() async { for _ in 0..<30 { await Task.yield() } }

    private static func testPolicy() throws {
        let idle = GameAutoCaptureRuntime(recording: false, canStart: true, canStop: true)
        let recording = GameAutoCaptureRuntime(recording: true, canStart: false, canStop: true)
        var policy = GameAutoCapturePolicy()
        policy.update(enabled: false, activeGames: ["game.one"])
        try SelfTest.require(policy.decision(idle) == nil, "Game autostart is opt-in even with a running game")
        policy.update(enabled: true, activeGames: ["game.one"])
        try SelfTest.require(policy.decision(idle) == .start, "Enabling starts an already-running selected game")
        policy.completedStart(.started, ticket: policy.beginStart())
        policy.update(enabled: true, activeGames: ["game.one", "game.two"])
        try SelfTest.require(policy.decision(recording) == nil && policy.ownsReplay, "A second game shares the existing automatic replay")
        policy.update(enabled: true, activeGames: ["game.two"])
        try SelfTest.require(policy.decision(recording) == nil, "Closing one selected game does not stop another game's replay")
        policy.update(enabled: true, activeGames: [])
        try SelfTest.require(policy.decision(recording) == .stop, "Only closing the last selected game requests an automatic stop")
        policy.completedStop()

        var existing = GameAutoCapturePolicy()
        existing.update(enabled: true, activeGames: ["game.one"])
        _ = existing.decision(recording)
        existing.update(enabled: true, activeGames: [])
        try SelfTest.require(existing.decision(recording) == nil && !existing.ownsReplay, "A pre-existing replay stays user-owned after the game closes")
        existing.update(enabled: true, activeGames: ["game.one"])
        try SelfTest.require(existing.decision(idle) == nil, "A paused user-owned replay is not appropriated by autostart")

        var manual = GameAutoCapturePolicy()
        manual.update(enabled: true, activeGames: ["game.one"])
        let manualRecording = GameAutoCaptureRuntime(recording: true, canStart: false, canStop: false, manualRecording: true)
        try SelfTest.require(manual.decision(manualRecording) == nil && !manual.userOwnsReplay, "Manual recording defers automatic start without claiming ownership")
        try SelfTest.require(manual.decision(idle) == .start, "Deferred autostart can proceed once manual recording finishes")

        var manualTransition = GameAutoCapturePolicy()
        manualTransition.update(enabled: true, activeGames: ["game.one"])
        let busyManualTransition = GameAutoCaptureRuntime(recording: true, canStart: false, canStop: false)
        _ = manualTransition.decision(busyManualTransition)
        _ = manualTransition.decision(manualRecording)
        _ = manualTransition.decision(busyManualTransition)
        try SelfTest.require(!manualTransition.userOwnsReplay && manualTransition.decision(idle) == .start,
            "Busy manual setup/finish windows never adopt temporary engine capture as a user-owned replay")

        manual.completedStart(.started, ticket: manual.beginStart())
        manual.userRequestedStop()
        try SelfTest.require(manual.decision(recording) == .stop, "An explicit Stop also cleans up a late automatic start")
        manual.completedStop()
        try SelfTest.require(manual.decision(idle) == nil && manual.isSuppressed, "Explicit Stop prevents immediate restart while a game remains open")
        manual.update(enabled: true, activeGames: ["game.one", "game.two"])
        try SelfTest.require(manual.decision(idle) == nil, "Launching another selected game does not cancel a manual Stop override")
        manual.update(enabled: true, activeGames: [])
        manual.update(enabled: true, activeGames: ["game.two"])
        try SelfTest.require(manual.decision(idle) == .start, "Closing every selected game resets suppression for a new launch cycle")

        var blocked = GameAutoCapturePolicy()
        blocked.update(enabled: true, activeGames: ["game.one"])
        let deniedTicket = blocked.beginStart()
        blocked.completedStart(.failed("Denied"), ticket: deniedTicket)
        try SelfTest.require(blocked.decision(idle) == nil, "A denied start does not retry in a permission-prompt loop")
        blocked.update(enabled: true, activeGames: ["game.one", "game.two"])
        try SelfTest.require(blocked.decision(idle) == nil, "Other launches during a failed game cycle do not loop either")
        blocked.retry()
        try SelfTest.require(blocked.decision(idle) == .start, "The user can explicitly retry a failed start")
        print("PASS: automatic replay ownership, multiple games, existing replay, manual recording deferral, manual Stop suppression and denied-start policy")
    }

    private static func testController() async throws {
        let suite = "Spy.GameAutoCaptureTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        var processes = [GameAutoCaptureProcess(processID: 100, bundleID: "com.test.GameOne", name: "Game One")]
        var runtime = GameAutoCaptureRuntime(recording: false, canStart: true, canStop: true)
        var starts = 0, stops = 0
        let controller = GameAutoCaptureController(defaults: defaults, workspaceCenter: center, runningApplications: { processes }, terminationDelayNanoseconds: 0)
        controller.add(GameAutoCaptureApplication(bundleID: "COM.TEST.GAMEONE", name: "Game One"))
        controller.add(GameAutoCaptureApplication(bundleID: "com.test.GameOne", name: "Duplicate"))
        controller.add(GameAutoCaptureApplication(bundleID: "local.spy.mac", name: "Spy"))
        controller.add(GameAutoCaptureApplication(bundleID: "invalid id", name: "Invalid"))
        controller.add(GameAutoCaptureApplication(bundleID: "com.test.GameTwo", name: "Game Two"))
        controller.install(state: { runtime }, start: {
            starts += 1; runtime.recording = true; return .started
        }, stop: {
            guard controller.shouldStopAutomatically else { return false }
            stops += 1; runtime.recording = false; return true
        })
        await settle()
        try SelfTest.require(!controller.enabled && starts == 0 && controller.selectedApplications.count == 2, "Controller defaults to opt-out and accepts only unique valid applications")
        controller.enabled = true
        await settle()
        try SelfTest.require(starts == 1 && controller.ownsReplay, "An already-running selected game starts once when enabled")

        processes.append(GameAutoCaptureProcess(processID: 101, bundleID: "com.test.GameOne", name: "Game One"))
        processes.append(GameAutoCaptureProcess(processID: 200, bundleID: "com.test.GameTwo", name: "Game Two"))
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await settle()
        try SelfTest.require(starts == 1 && controller.activeApplications.count == 2, "Launch observer deduplicates game choices while retaining every running instance")
        processes.removeAll { $0.processID == 100 }
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await settle()
        try SelfTest.require(stops == 0 && controller.activeApplications.count == 2, "Closing one of two instances does not remove its active game")
        processes.removeAll { $0.processID == 101 }
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await settle()
        try SelfTest.require(stops == 0 && controller.activeApplications.count == 1, "A second selected game prevents stopping the buffer")
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await settle()
        try SelfTest.require(starts == 1 && stops == 0, "Switching focus never toggles automatic recording")
        processes = []
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await settle()
        try SelfTest.require(stops == 1 && !runtime.recording && !controller.ownsReplay, "Last-game termination stops only the controller-owned replay")

        let restored = GameAutoCaptureController(defaults: defaults, workspaceCenter: NotificationCenter(), runningApplications: { [] }, terminationDelayNanoseconds: 0)
        try SelfTest.require(restored.enabled && restored.selectedBundleIDs == controller.selectedBundleIDs, "Opt-in and selected bundle IDs persist in an isolated defaults suite")
        controller.uninstall()
        processes = [GameAutoCaptureProcess(processID: 300, bundleID: "com.test.GameOne", name: "Game One")]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await settle()
        try SelfTest.require(starts == 1, "Uninstall removes observers without clearing user settings")
        print("PASS: isolated launch/termination notifications, duplicate game processes, focus independence, persisted selection and observer cleanup")
    }

    private static func testFailuresAndOverrides() async throws {
        let suite = "Spy.GameAutoCaptureTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var processes = [GameAutoCaptureProcess(processID: 1, bundleID: "com.test.Game", name: "Game")]
        var runtime = GameAutoCaptureRuntime(recording: false, canStart: false, canStop: true)
        var starts = 0, stops = 0
        var deny = true, failStop = false
        let controller = GameAutoCaptureController(defaults: defaults, workspaceCenter: NotificationCenter(), runningApplications: { processes }, terminationDelayNanoseconds: 0)
        controller.add(GameAutoCaptureApplication(bundleID: "com.test.Game", name: "Game"))
        controller.enabled = true
        controller.install(state: { runtime }, start: {
            starts += 1
            if deny { return .failed("Доступ к записи экрана не выдан. Включите повтор вручную.") }
            runtime.recording = true; return .started
        }, stop: {
            guard controller.shouldStopAutomatically else { return false }
            stops += 1
            if failStop {
                // Saving toggles busy state but fails; those notifications must
                // not cause an endless autosave/stop retry loop.
                runtime.canStop = false; controller.runtimeChanged()
                runtime.canStop = true; controller.runtimeChanged()
                return false
            }
            runtime.recording = false; return true
        })
        await settle()
        try SelfTest.require(starts == 0, "Privacy, diagnostics, saving and other unavailable states defer start")
        runtime.canStart = true; controller.runtimeChanged()
        await settle()
        try SelfTest.require(starts == 1 && controller.error != nil, "A denied start is reported once without requesting permission")
        for _ in 0..<5 { controller.runtimeChanged(); controller.refreshRunningApplications() }
        await settle()
        try SelfTest.require(starts == 1, "Repeated runtime/process refreshes do not retry a denied start")
        deny = false; controller.retry()
        await settle()
        try SelfTest.require(starts == 2 && controller.ownsReplay, "An explicit retry can successfully start replay")
        controller.userRequestedStop(); runtime.recording = false; controller.runtimeChanged()
        await settle()
        controller.refreshRunningApplications(); controller.runtimeChanged()
        await settle()
        try SelfTest.require(starts == 2 && controller.isSuppressed, "A manual stop survives subsequent refreshes while the game stays open")
        processes = []; controller.refreshRunningApplications(); await settle()
        processes = [GameAutoCaptureProcess(processID: 2, bundleID: "com.test.Game", name: "Game")]
        controller.refreshRunningApplications(); await settle()
        try SelfTest.require(starts == 3, "A new game cycle releases the manual override")
        runtime.canStop = false; controller.runtimeChanged()
        processes = []; controller.refreshRunningApplications(); await settle()
        try SelfTest.require(stops == 0 && controller.ownsReplay, "Busy saving/manual/diagnostic transitions defer automatic stop")
        runtime.canStop = true; failStop = true; controller.runtimeChanged(); await settle()
        try SelfTest.require(stops == 1 && runtime.recording && controller.ownsReplay && controller.error != nil, "A failed autosave preserves capture ownership and does not loop")
        failStop = false; controller.retry(); await settle()
        try SelfTest.require(stops == 2 && !runtime.recording, "Explicit retry completes the previously deferred stop")
        controller.uninstall()

        let corrupt = Data("not JSON".utf8)
        defaults.set(corrupt, forKey: GameAutoCaptureController.applicationsKey)
        let broken = GameAutoCaptureController(defaults: defaults, workspaceCenter: NotificationCenter(), runningApplications: { [] })
        broken.add(GameAutoCaptureApplication(bundleID: "com.test.Other", name: "Other"))
        try SelfTest.require(!broken.configurationReadable && broken.error != nil && defaults.data(forKey: GameAutoCaptureController.applicationsKey) == corrupt, "Unreadable selection disables automatic starts and preserves saved data until explicit reset")
        print("PASS: safe busy deferral, denied-start backoff, explicit retries, manual Stop cycle, autosave-failure retention and unreadable-settings preservation")
    }

    private static func testRacesAndDebounce() async throws {
        let suite = "Spy.GameAutoCaptureTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var processes = [GameAutoCaptureProcess(processID: 1, bundleID: "com.test.Game", name: "Game")]
        var runtime = GameAutoCaptureRuntime(recording: false, canStart: true, canStop: true)
        var starts = 0, stops = 0
        var startGate: CheckedContinuation<Void, Never>?
        let controller = GameAutoCaptureController(defaults: defaults, workspaceCenter: NotificationCenter(), runningApplications: { processes }, terminationDelayNanoseconds: 25_000_000)
        controller.add(GameAutoCaptureApplication(bundleID: "com.test.Game", name: "Game"))
        controller.enabled = true
        controller.install(state: { runtime }, start: {
            starts += 1
            await withCheckedContinuation { startGate = $0 }
            runtime.recording = true; return .started
        }, stop: {
            guard controller.shouldStopAutomatically else { return false }
            stops += 1; runtime.recording = false; return true
        })
        await settle()
        try SelfTest.require(startGate != nil, "An automatic start can be suspended for a deterministic race test")
        controller.userRequestedStop()
        startGate?.resume(); startGate = nil
        await settle()
        try SelfTest.require(starts == 1 && stops == 1 && !runtime.recording && controller.isSuppressed, "Manual Stop during an in-flight start cleans up the late recording and suppresses restart")
        processes = []; controller.refreshRunningApplications()
        processes = [GameAutoCaptureProcess(processID: 2, bundleID: "com.test.Game", name: "Game")]
        controller.refreshRunningApplications()
        try await Task.sleep(nanoseconds: 40_000_000)
        await settle()
        try SelfTest.require(starts == 1 && controller.isSuppressed, "A transient relaunch cancels delayed termination and preserves the same manual override cycle")
        processes = []; controller.refreshRunningApplications()
        try await Task.sleep(nanoseconds: 40_000_000)
        await settle()
        processes = [GameAutoCaptureProcess(processID: 3, bundleID: "com.test.Game", name: "Game")]
        controller.refreshRunningApplications(); await settle()
        try SelfTest.require(startGate != nil && starts == 2, "A settled complete exit begins a fresh launch cycle")
        controller.userRequestedStart()
        startGate?.resume(); startGate = nil
        await settle()
        processes = []; controller.refreshRunningApplications()
        try await Task.sleep(nanoseconds: 40_000_000)
        await settle()
        try SelfTest.require(runtime.recording && !controller.ownsReplay && stops == 1, "Manual Start during an in-flight automatic start adopts the replay and protects it after game exit")
        controller.uninstall()
        print("PASS: in-flight manual Start/Stop races, transient relaunch grace period and a fully closed game cycle")
    }
}
