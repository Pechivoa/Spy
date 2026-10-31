import Foundation

@MainActor extension AppModel {
    func setupPrivacy() {
        privacy.onDiagnostic = { [weak self] text in self?.journal.record(.warning, "Приватность", text) }
        privacy.install(onBlockingChanged: { [weak self] _ in self?.requestPrivacyState() }, onFilterRefresh: { [weak self] in self?.refreshPrivacyExclusions() })
        performance.start()
    }
    func requestPrivacyState() {
        if privacy.isBlocked || manualPrivacyPause { recordingDiagnostics.cancel() }
        automationRuntimeChanged()
        let blocked = privacy.isBlocked || manualPrivacyPause
        if blocked { soundpad.blockNow("Пауза приватности. Передача звука выключена.") }
        engine.requestPrivacyBlock(blocked)
        pendingPrivacyUpdate = true
        Task { await reconcilePrivacyState() }
    }
    func togglePrivacyPause() {
        guard recording, !busy, !shuttingDown else { return }
        manualPrivacyPause.toggle()
        requestPrivacyState()
    }
    func reconcilePrivacyState() async {
        guard !shuttingDown else { return }
        guard !busy, !privacyTransitionRunning else { pendingPrivacyUpdate = true; return }
        pendingPrivacyUpdate = false
        let blocked = privacy.isBlocked || manualPrivacyPause
        engine.requestPrivacyBlock(blocked)
        if blocked {
            guard recording, !privacyPaused else { return }
            privacyTransitionRunning = true; busy = true
            defer { privacyTransitionRunning = false; busy = false }
            privacyPaused = true
            do {
                try await engine.pauseForPrivacy()
                message = "Запись на паузе. Накопленное видео сохранено в буфере."
                journal.record(.info, "Приватность", "Захват приостановлен без очистки буфера.")
            } catch {
                journal.record(.error, "Пауза записи", describeError(error))
                message = "Запись заблокирована для приватности. Подробности — в журнале."
            }
        } else if privacyPaused && recording {
            privacyTransitionRunning = true; busy = true
            defer { privacyTransitionRunning = false; busy = false }
            do {
                try privacy.validateConfiguration()
                try await engine.resumeAfterPrivacy(excluding: privacy.excludedBundleIDs)
                guard !privacy.isBlocked, !manualPrivacyPause else { pendingPrivacyUpdate = true; return }
                privacyPaused = false
                message = "Запись продолжена; прежний буфер сохранён."
                journal.record(.info, "Приватность", "Захват возобновлён с текущими исключениями.")
            } catch {
                journal.record(.error, "Возобновление записи", describeError(error))
                message = "Не удалось продолжить запись. Остановите и включите повтор снова."
            }
        } else if !recording && lastReplayEnabled && !busy && !saving {
            await restoreLastSession()
        }
    }
    func refreshPrivacyExclusions() {
        soundpad.privacyUpdated()
        recordingDiagnostics.cancel()
        let ids = privacy.excludedBundleIDs
        engine.requestPrivacyFilter(ids)
        Task {
            do {
                try privacy.validateConfiguration()
                try await engine.refreshPrivacyExclusions(ids)
            } catch is CancellationError {
                // A newer filter or an explicit stop owns the stream now.
            } catch {
                engine.requestPrivacyBlock(true)
                if recording {
                    do { try await engine.pauseForPrivacy() }
                    catch { journal.record(.error, "Остановка для приватности", describeError(error)) }
                    if recording && !shuttingDown { privacyPaused = true; manualPrivacyPause = true }
                }
                captureIssue = error.localizedDescription
                journal.record(.error, "Исключения приложений", describeError(error))
            }
        }
    }
}
