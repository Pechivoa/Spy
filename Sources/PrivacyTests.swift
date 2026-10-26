import AppKit
import Foundation

@MainActor enum PrivacyTests {
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Spy.PrivacyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        let browser = PrivacyApplication(bundleID: "com.example.Browser", name: "Browser")
        let mail = PrivacyApplication(bundleID: "com.example.Mail", name: "Mail")
        var lockHint = false
        let controller = PrivacyController(defaults: defaults, workspaceCenter: workspace, distributedCenter: distributed, runningApplications: { [browser, mail, browser] }, screenLockHint: { lockHint })
        try SelfTest.require(controller.pauseOnLock && controller.excludedApplications.isEmpty && controller.runningApplications.count == 2, "Privacy defaults preserve recording sources and deduplicate the available app list")
        var filterUpdates = 0
        var blocked: [Bool] = []
        controller.install(onBlockingChanged: { blocked.append($0) }, onFilterRefresh: { filterUpdates += 1 })
        controller.add(browser)
        controller.add(PrivacyApplication(bundleID: "COM.EXAMPLE.BROWSER", name: "Duplicate"))
        controller.add(PrivacyApplication(bundleID: "local.spy.mac", name: "Spy"))
        controller.add(PrivacyApplication(bundleID: "bad bundle id", name: "Invalid"))
        try SelfTest.require(controller.excludedApplications.count == 1 && filterUpdates == 1, "Only unique valid non-Spy exclusions trigger filter updates")
        try SelfTest.require(CapturePrivacyPolicy.excludes("COM.EXAMPLE.BROWSER", selected: controller.excludedBundleIDs) && !CapturePrivacyPolicy.excludes(mail.bundleID, selected: controller.excludedBundleIDs), "Exclusion matching is stable across bundle-ID capitalization")
        try SelfTest.require(CapturePrivacyPolicy.excludes("local.spy.mac", selected: []), "Spy stays excluded even with an empty user exclusion list")
        var rejected = false
        do { try CapturePrivacyPolicy.validateWindowOwner(browser.bundleID, selected: controller.excludedBundleIDs) } catch { rejected = true }
        try SelfTest.require(rejected, "Direct capture of an excluded app's window is rejected")
        try CapturePrivacyPolicy.validateWindowOwner(mail.bundleID, selected: controller.excludedBundleIDs)
        let restored = PrivacyController(defaults: defaults, workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter(), runningApplications: { [] })
        try SelfTest.require(restored.excludedBundleIDs == controller.excludedBundleIDs, "Exclusions survive a new controller without OS permission changes")
        controller.applicationChanged(bundleID: browser.bundleID)
        controller.applicationChanged(bundleID: mail.bundleID)
        try SelfTest.require(filterUpdates == 2, "Newly launched excluded processes refresh capture filtering; other apps do not")
        controller.remove(browser)
        try SelfTest.require(controller.excludedApplications.isEmpty && filterUpdates == 3, "Removing an exclusion refreshes the filter and persists")
        print("PASS: persisted exclusions, deduplication, case-normalized filtering, direct-window denial and new-process refresh")

        try SelfTest.require(blocked == [false], "Install reports the initial unblocked state once")
        controller.setBlocked(true, reason: .screenLocked)
        controller.setBlocked(true, reason: .screenLocked)
        controller.setBlocked(true, reason: .displayAsleep)
        controller.setBlocked(false, reason: .displayAsleep)
        try SelfTest.require(blocked == [false, true] && controller.isBlocked, "Duplicate lock events do not double-pause; display wake cannot resume a locked screen")
        controller.setBlocked(true, reason: .sessionInactive)
        controller.setBlocked(false, reason: .screenLocked)
        try SelfTest.require(controller.isBlocked && blocked.count == 2, "Unlock cannot resume while the user session remains inactive")
        controller.setBlocked(false, reason: .sessionInactive)
        try SelfTest.require(blocked == [false, true, false], "Resume is requested only when every blocking reason clears")
        controller.setBlocked(true, reason: .screenLocked)
        controller.pauseOnLock = false
        try SelfTest.require(!controller.isBlocked && blocked.suffix(2) == [true, false], "Lock pause opt-out does not alter exclusions")
        controller.pauseOnLock = true
        try SelfTest.require(controller.isBlocked && blocked.last == true, "Re-enabling lock pause applies the current lock state")
        controller.setBlocked(false, reason: .screenLocked)
        print("PASS: combined lock/session/display reasons, duplicate notifications, opt-out and safe resume transitions")

        // Isolated notification centers exercise the real observer path without
        // locking the user's Mac or touching its privacy settings.
        distributed.post(name: PrivacyController.screenLocked, object: nil)
        for _ in 0..<8 { await Task.yield() }
        try SelfTest.require(controller.isBlocked, "Distributed lock notification reaches the controller")
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        distributed.post(name: PrivacyController.screenUnlocked, object: nil)
        for _ in 0..<8 { await Task.yield() }
        try SelfTest.require(controller.isBlocked, "Real observer path keeps inactive sessions paused after unlock")
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        for _ in 0..<8 { await Task.yield() }
        try SelfTest.require(!controller.isBlocked, "Session activation releases the remaining pause")
        controller.setBlocked(true, reason: .displayAsleep)
        lockHint = true
        let transitionsBeforeWake = blocked.count
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for _ in 0..<8 { await Task.yield() }
        try SelfTest.require(controller.isBlocked && blocked.count == transitionsBeforeWake, "Wake discovers a missed lock event without briefly resuming capture")
        lockHint = false
        distributed.post(name: PrivacyController.screenUnlocked, object: nil)
        for _ in 0..<8 { await Task.yield() }
        try SelfTest.require(!controller.isBlocked, "Actual unlock resumes after a missed-lock wake hint")
        controller.uninstall()
        distributed.post(name: PrivacyController.screenLocked, object: nil)
        for _ in 0..<8 { await Task.yield() }
        try SelfTest.require(!controller.isBlocked, "Uninstall removes observers and prevents late callbacks")
        let initiallyLocked = PrivacyController(defaults: defaults, workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter(), runningApplications: { [] }, initialScreenLocked: true)
        var initialState: Bool?
        initiallyLocked.install(onBlockingChanged: { initialState = $0 }, onFilterRefresh: {})
        try SelfTest.require(initialState == true, "A supplied initial lock state blocks capture before its first frame")
        initiallyLocked.uninstall()
        print("PASS: real notification wiring in isolated centers, observer cleanup and initial-lock guard")
        defaults.set(Data("broken exclusions".utf8), forKey: "privacyExcludedApplications")
        let broken = PrivacyController(defaults: defaults, workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter(), runningApplications: { [] })
        var blockedConfiguration = false
        do { try broken.validateConfiguration() } catch { blockedConfiguration = true }
        broken.add(browser)
        try SelfTest.require(blockedConfiguration && !broken.exclusionsReadable && broken.excludedApplications.isEmpty && broken.error != nil, "Corrupted exclusions fail closed instead of silently enabling private windows")
        broken.resetUnreadableExclusions()
        try broken.validateConfiguration()
        broken.add(browser)
        try SelfTest.require(broken.exclusionsReadable && broken.excludedBundleIDs.contains(browser.id), "Explicit reset repairs only the damaged exclusion list")
        print("PASS: unreadable exclusions block capture and require an explicit reset")
    }
}
