import SwiftUI
import AppKit

/// Renders only this app's own view for build-time visual verification.
/// It does not capture the user's display or require screen permissions.
@MainActor enum PreviewRenderer {
    static func render(to url: URL, section: Int = 0, sourceURL: URL? = nil) async throws {
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        model.section = section == 6 ? 4 : section == 7 ? 5 : section == 9 || section == 11 || section == 12 || section == 13 || section == 16 || section == 17 ? 0 : section
        if section == 18 { model.section = 6 }
        if section == 19 { model.section = 7 }
        if section == 20 { model.section = 8 }
        if section == 21 { model.section = 0 }
        if section == 24 || section == 25 { model.section = 0 }
        model.message = "Пример интерфейса · демонстрационные данные"
        if section == 24 || section == 25 { model.message = nil }
        if let sourceURL {
            for index in 0..<3 {
                let copied = model.libraryURL.appendingPathComponent("Preview-\(index).mov")
                try FileManager.default.copyItem(at: sourceURL, to: copied)
                try model.metadata.set(ClipMetadata(name: ["Пример: Победа в раунде", "Пример: Красивый момент", "Пример: Рабочая запись"][index], favorite: index == 0), for: copied)
            }
            await model.reloadClips()
        }
        if section == 6 || section == 10 {
            model.profiles = [AppProfile(bundleID: "example.game", name: "Пример: Игра", settings: CaptureSettings(quality: .smooth, minutes: 10, systemAudio: true, microphone: true, microphoneID: "", systemVolume: 0.7, microphoneVolume: 0.5, separateAudio: true))]
        }
        if section == 7 { model.batterySaving = true; model.onBattery = true }
        if section == 18, let sourceURL {
            let folder = model.cacheURL.appendingPathComponent("record-replay-example-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: folder.appendingPathComponent("000001.mov"))
            model.refreshRecoveryFolders()
        }
        if section == 19 {
            for prefix in ["preview-", "record-replay-example-", "replay-"] {
                let folder = model.cacheURL.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(repeating: 0, count: 32_768).write(to: folder.appendingPathComponent("Example.bin"))
            }
        }
        if section == 20 {
            let began = Date().addingTimeInterval(-120)
            model.sessions.begin(id: UUID(), source: "Пример: экран Mac · 1080p / 60 FPS", at: began)
            model.sessions.event("pause", "Пауза приватности", at: began.addingTimeInterval(20))
            model.sessions.event("resume", "Запись продолжена", at: began.addingTimeInterval(40))
            if let clip = model.clips.first { model.sessions.saved(clip.url) }
            model.sessions.end(reason: "Сессия сохранена", at: began.addingTimeInterval(100))
        }
        if section == 21 {
            model.captureHealth.sample = CaptureTelemetry(began: 0, screen: 1, encoded: 1, wantsMicrophone: true)
            model.captureHealth.check(active: true, paused: false, now: 20)
        }
        if section == 9 {
            model.recording = true; model.manualRecording = true; model.microphone = true
            model.stats = BufferStats(seconds: 285, bytes: 220_000_000, frameCount: 9000, manualSeconds: 521, manualBytes: 470_000_000)
            model.audioMeter = AudioMeter(system: 0.12, microphone: 0.05)
        }
        if section == 3 {
            model.journal.record(.info, "Пример: запуск", "Spy 1.15.0 запущен. Журнал сохраняется между запусками.")
            model.journal.record(.info, "Пример: настройка клавиш", "Сохранить повтор → ⌃⇧S")
            model.journal.record(.warning, "Пример: доступ к экрану", "Разрешение ещё не получено. Разрешите Spy запись экрана в настройках macOS.")
            model.journal.record(.error, "Пример: захват экрана", "Не удалось запустить захват.\nДомен: com.apple.ScreenCaptureKit.SCStreamErrorDomain · Код: −3801")
        }
        if section == 11 { model.blockScreenCapture() }
        if section == 12 || section == 13 || section == 15 || section == 16 || section == 17 {
            model.recording = true
            model.stats = BufferStats(seconds: 118, bytes: 24_000_000, frameCount: 7000)
        }
        if section == 24 || section == 25 {
            model.recording = true
            model.stats = BufferStats(seconds: 612, bytes: 212_000_000, frameCount: 18_360)
        }
        if section == 16 || section == 17 { model.recoveryFolders = [model.cacheURL.appendingPathComponent("record-replay-crash-example")] }
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        let width: CGFloat = section == 24 ? 1060 : section == 25 ? 900 : section == 22 ? 720 : section == 15 ? 1040 : section == 14 ? 56 : section == 12 || section == 16 ? 340 : section == 13 || section == 17 ? 280 : section == 23 ? 720 : section == 4 ? 1040 : section == 5 ? 350 : section == 8 ? 112 : section == 10 ? 540 : 1160
        let height: CGFloat = section == 24 ? 800 : section == 25 ? 640 : section == 22 ? 540 : section == 15 ? 800 : section == 14 ? 18 : section == 12 || section == 16 ? 380 : section == 13 || section == 17 ? 150 : section == 23 ? 540 : section == 4 ? 800 : section == 5 ? 82 : section == 8 ? 24 : section == 10 ? 530 : section == 0 || section == 9 ? 1250 : section == 2 ? 1580 : section == 7 ? 1100 : 820
        let root: AnyView
        if (section == 15 || section == 22), let clip = model.clips.first {
            let preview = BufferPreview(directory: clip.url.deletingLastPathComponent(), clip: clip, capturedAt: Date())
            model.bufferPreview = preview
            root = AnyView(BufferPreviewSheet(preview: preview, model: model))
        }
        else if section == 12 || section == 13 || section == 16 || section == 17 || section == 24 || section == 25 { root = AnyView(SpyWindowView(model: model)) }
        else if (section == 4 || section == 23), let clip = model.clips.first { root = AnyView(PlayerSheet(clip: clip, model: model)) }
        else if section == 8 { root = AnyView(HUDView(value: HUDState(recording: true, manual: true, seconds: 521, bytes: 470_000_000, battery: true))) }
        else if section == 14 { root = AnyView(HUDView(value: HUDState(recording: true, manual: false, seconds: 521, bytes: 470_000_000, battery: false), width: 56, height: 18)) }
        else if section == 10, let profile = model.profiles.first { root = AnyView(ProfileEditorSheet(profile: profile, model: model)) }
        else if section == 5 { root = AnyView(SaveToastView(title: "Пример: повтор сохранён", detail: "00:30 · 24 МБ")) }
        else { root = AnyView(ContentView(model: model)) }
        let content = root.preferredColorScheme(.dark).frame(width: width, height: height)
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SpyError.message("Preview bitmap allocation failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SpyError.message("Preview render failed") }
        try data.write(to: url)
        window.contentView = nil
        print("UI preview: " + url.path)
    }
}
