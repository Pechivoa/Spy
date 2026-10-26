import AppKit
import Foundation

@MainActor extension AppModel {
    var recordingConfiguration: RecordingConfig {
        RecordingConfig(displayID: displayID, quality: recording ? (recordingQuality ?? effectiveQuality) : effectiveQuality, audio: systemAudio,
            microphone: microphone, seconds: max(30, effectiveMinutes * 60),
            windowID: captureMode == .window ? windowID : nil, microphoneID: microphoneID.isEmpty ? nil : microphoneID,
            excludedBundleIDs: privacy.excludedBundleIDs, microphoneCleanup: microphoneCleanup)
    }

    func setupAutomation() {
        automationInstalled = true
        gameAutoCapture.onDiagnostic = { [weak self] text in self?.journal.record(.info, "Автозапуск для игр", text) }
        gameAutoCapture.install(state: { [weak self] in
            guard let self else { return GameAutoCaptureRuntime(recording: false, canStart: false, canStop: false) }
            let idle = !self.busy && !self.saving && !self.shuttingDown && !self.diagnosticsBusy && !self.switchingConfiguration
            return GameAutoCaptureRuntime(recording: self.recording,
                canStart: idle && self.sessionRestorationFinished && !self.privacy.isBlocked && !self.manualPrivacyPause && self.minutes > 0,
                canStop: idle && !self.manualRecording, manualRecording: self.manualRecording)
        }, start: { [weak self] in
            guard let self else { return .deferred }
            guard !self.busy, !self.saving, !self.shuttingDown, !self.diagnosticsBusy, !self.privacy.isBlocked else { return .deferred }
            self.preferences.set(true, forKey: "gameOwnedReplay")
            await self.start(requestPermission: false)
            if self.recording { return .started }
            self.preferences.set(false, forKey: "gameOwnedReplay")
            return .failed(self.captureIssue ?? self.error ?? "Не удалось запустить повтор. Проверьте доступ к экрану и настройки записи.")
        }, stop: { [weak self] in
            guard let self else { return false }
            return await self.finishGameReplay()
        })
    }

    func automationRuntimeChanged() {
        guard automationInstalled else { return }
        gameAutoCapture.runtimeChanged()
    }

    func queueAutoMoment(_ marker: ReplayMarker) {
        guard autoMomentClips.enabled else { return }
        let id = UUID()
        let levels = AudioLevels(system: Float(systemVolume), microphone: Float(microphoneVolume))
        let separate = separateAudio
        markerCaptureTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.autoMomentClips.capture(marker: marker, levels: levels, separateAudio: separate)
            self.markerCaptureTasks.removeValue(forKey: id)
        }
    }

    func flushAutoMoments() async {
        while let task = markerCaptureTasks.values.first { await task.value }
        await autoMomentClips.flushPending()
    }

    func publishAutoMoment(_ job: AutoMomentClipJob) async throws -> URL {
        // A stable UUID destination makes recovery safe across a crash after the
        // final rename, before the controller commits its completion sidecar.
        let stem = "Spy_Auto_" + job.id.uuidString
        let destination = libraryURL.appendingPathComponent(stem + ".mov").spyFileURL
        if FileManager.default.fileExists(atPath: destination.path) {
            storeMarkers(job.markers, for: destination)
            return destination
        }
        guard libraryAvailable else { throw SpyError.message("Папка видео недоступна. Автоклип оставлен для восстановления.") }
        autoClipExports += 1
        protectedAutoClipURLs.insert(destination)
        defer {
            autoClipExports -= 1
            refreshDisk()
            Task {
                await autoMomentClips.waitUntilIdle()
                protectedAutoClipURLs.remove(destination)
                if autoCleanup { await cleanupLibrary(protecting: [destination]) }
                await reconcilePendingChanges()
            }
        }
        let partial = libraryURL.appendingPathComponent("." + stem + ".mov")
        do {
            try? FileManager.default.removeItem(at: partial)
            try await job.playback.export(range: job.range, to: partial, separateAudio: job.separateAudio, editableMicrophone: true)
            try FileManager.default.moveItem(at: partial, to: destination)
            storeMarkers(job.markers, for: destination)
            await reloadClips()
            if let clip = clips.first(where: { $0.url == destination }), !shuttingDown {
                notifySaved(clip, title: "Автоклип сохранён")
            }
            message = "Автоклип сохранён · " + clockText(job.range.end - job.range.start)
            return destination
        } catch { try? FileManager.default.removeItem(at: partial); throw error }
    }

    /// Only the game controller's own replay is saved and stopped. Pin first so
    /// an unavailable library leaves both the live buffer and recovery intact.
    func finishGameReplay() async -> Bool {
        guard recording, !manualRecording, !busy, !saving, !diagnosticsBusy, !shuttingDown else { return false }
        busy = true
        defer { busy = false; refreshRecoveryFolders(); Task { await reconcilePendingChanges() } }
        do {
            await flushAutoMoments()
            if engine.testStats().frameCount > 0 {
                let snapshot = try await engine.snapshot(seconds: effectiveMinutes * 60)
                let folder = cacheURL.appendingPathComponent("record-replay-game-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.moveItem(at: snapshot.directory, to: folder)
                let retained = SpySnapshot(directory: folder, urls: snapshot.urls.map { folder.appendingPathComponent($0.lastPathComponent) },
                    requestedSeconds: snapshot.requestedSeconds, sourceIntervals: snapshot.sourceIntervals,
                    markers: snapshot.markers, captureSessionID: snapshot.captureSessionID)
                try JSONEncoder().encode(snapshot.requestedSeconds).write(to: folder.appendingPathComponent("replay-seconds.json"), options: .atomic)
                saving = true
                do { try await saveManualSnapshot(retained, replaySession: true) }
                catch { saving = false; throw error }
                saving = false
            }
            guard gameAutoCapture.shouldStopAutomatically else { return false }
            await engine.stop()
            recording = false; privacyPaused = false; manualPrivacyPause = false; stats = BufferStats(); audioMeter = AudioMeter()
            setReplayIntent(false); endCaptureActivity()
            journal.record(.info, "Автозапуск для игр", "Последняя выбранная игра закрыта. Буфер сохранён; повтор остановлен.")
            return true
        } catch {
            journal.record(.error, "Автосохранение игры", describeError(error))
            message = "Не удалось сохранить буфер игры. Повтор продолжает работать; исходники доступны для восстановления."
            return false
        }
    }

    func runRecordingCheck() async {
        guard !diagnosticsBusy, !busy, !saving, !shuttingDown, !switchingConfiguration else { return }
        guard !privacy.isBlocked, !manualPrivacyPause, !privacyPaused else {
            message = "Проверка доступна после завершения паузы приватности."
            return
        }
        do { try privacy.validateConfiguration() }
        catch { showError(error.localizedDescription, topic: "Проверка записи"); return }
        diagnosticsBusy = true
        defer { diagnosticsBusy = false; Task { await reconcilePendingChanges() } }
        await recordingDiagnostics.run(config: recordingConfiguration, existingEngine: recording ? engine : nil)
        let results = recordingDiagnostics.results
        journal.record(results.contains(where: { $0.status == .failed }) ? .error : results.contains(where: { $0.status == .warning }) ? .warning : .info, "Проверка записи", recordingDiagnostics.reportText)
    }
}
