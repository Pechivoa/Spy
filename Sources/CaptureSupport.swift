import AppKit
import AVFoundation
import ScreenCaptureKit

/// Core Graphics preflight is advisory for manual starts. ScreenCaptureKit
/// makes the authoritative access decision; no privacy grants are changed here.
@MainActor struct CaptureAccess {
    var screenAllowed: () -> Bool
    var microphoneStatus: () -> AVAuthorizationStatus
    var requestMicrophone: () async -> Bool
    static var live: CaptureAccess {
        CaptureAccess(screenAllowed: { CGPreflightScreenCaptureAccess() },
                      microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
                      requestMicrophone: { await AVCaptureDevice.requestAccess(for: .audio) })
    }
    static func isScreenDenial(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == SCStreamErrorDomain && value.code == SCStreamError.Code.userDeclined.rawValue
    }
}

@MainActor extension AppModel {
    var screenPermissionHelp: String {
        "macOS не дала этой версии Spy доступ к экрану. Откройте настройки → «Запись экрана и системного звука». Если Spy уже включён, выключите и снова включите его, затем перезапустите Spy."
    }
    func blockScreenCapture() {
        needsPermission = true
        captureIssue = screenPermissionHelp
        startupStatus = nil
        journal.record(.warning, "Доступ к экрану", screenPermissionHelp)
    }
    func refreshCaptureAccess() {
        guard !busy, !recording else { return }
        if needsPermission && captureAccess.screenAllowed() {
            needsPermission = false; captureIssue = nil
            message = "Доступ к экрану получен. Нажмите «Включить повтор»."
            journal.record(.info, "Доступ к экрану", "Повторная проверка после возврата в Spy: доступ получен.")
        }
        if needsMicrophonePermission && captureAccess.microphoneStatus() == .authorized {
            needsMicrophonePermission = false
            if !needsPermission { captureIssue = nil }
        }
    }
    func handleCaptureFailure(_ value: String) async {
        captureFailure = value
        captureIssue = value
        journal.record(.error, "Запись", value)
        // A failure during start must be handled by start's catch. Dropping
        // stop() because busy is true used to leave a false "recording" state.
        guard startupStatus == nil else { return }
        if captureRecovery.installed && lastReplayEnabled && !manualRecording && !shuttingDown {
            captureRecovery.schedule(target: recoveryTarget, reason: value)
        }
        if busy {
            pendingCaptureStop = true
            return
        }
        await stop(preserveReplayIntent: true)
    }
    func flushCaptureFailure() {
        guard pendingCaptureStop, !busy else { return }
        pendingCaptureStop = false
        Task { await stop(preserveReplayIntent: true) }
    }
    func restartSpy() {
        guard !recording, !busy, !saving, !previewMode else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = ["-c", "for i in {1..100}; do /bin/kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$2\"; /bin/sleep 0.1; done", "Spy-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do {
            try helper.run()
            journal.record(.info, "Перезапуск", "Перезапуск Spy для применения разрешений macOS.")
            NSApp.terminate(nil)
        } catch { showError("Не удалось перезапустить Spy: " + error.localizedDescription, topic: "Перезапуск", details: describeError(error)) }
    }
}
