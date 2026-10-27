import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor extension AppModel {
    func captureMaskPreview() async throws -> NSImage {
        guard !recording, !busy, !saving, !diagnosticsBusy else {
            throw SpyError.message("Остановите повтор перед редактированием приватных областей.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        if captureMode == .window {
            guard let selected = content.windows.first(where: { $0.windowID == windowID }) else {
                throw SpyError.message("Выбранное окно недоступно. Выберите окно на главном экране.")
            }
            try CapturePrivacyPolicy.validateWindowOwner(selected.owningApplication?.bundleIdentifier, selected: privacy.excludedBundleIDs, ownBundleID: Bundle.main.bundleIdentifier ?? "local.spy.mac")
            filter = SCContentFilter(desktopIndependentWindow: selected)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw SpyError.message("Выбранный монитор отключён.") }
            let excluded = content.applications.filter { CapturePrivacyPolicy.excludes($0.bundleIdentifier, selected: privacy.excludedBundleIDs, ownBundleID: Bundle.main.bundleIdentifier ?? "local.spy.mac") }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        }
        let size = filter.contentRect.size
        let scale = min(1, 1280 / max(1, size.width), 800 / max(1, size.height))
        let config = SCStreamConfiguration()
        config.width = max(2, Int(size.width * scale)); config.height = max(2, Int(size.height * scale))
        config.showsCursor = false; config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
