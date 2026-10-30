import AppKit
import SwiftUI
import AVFoundation

@MainActor enum PreviewWindowTests {
    static func run(directory: URL) async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(preview: true)
        defer { try? FileManager.default.removeItem(at: model.libraryURL.deletingLastPathComponent()) }
        let parent = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 280, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let parentFrame = parent.frame
        let previewFolder = model.cacheURL.appendingPathComponent("preview-window-test")
        try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
        let clip = Clip(url: previewFolder.appendingPathComponent("missing.mov"), date: Date(), bytes: 100, duration: 30)
        let preview = BufferPreview(directory: previewFolder, clip: clip, capturedAt: Date())
        model.bufferPreview = preview
        try SelfTest.require(model.bufferViewer.window == nil, "Headless models never open interactive viewers")
        let viewer = VideoViewerWindow()
        var closed = 0
        var saving = false
        viewer.present(title: "Preview geometry test", show: false, canClose: { !saving }, onClose: { closed += 1 }) {
            BufferPreviewSheet(preview: preview, model: model)
        }
        defer { viewer.dismiss(); parent.contentView = nil; parent.close() }
        guard let window = viewer.window else { throw SpyError.message("TEST FAILED: Independent viewer exists") }
        let host = window.contentView!
        try SelfTest.require(parent.frame == parentFrame && window.sheetParent == nil,
                             "Opening a viewer from a 280×150 mini-widget never inherits its size or changes it")
        try SelfTest.require(host.frame.height >= 540 && host.frame.width >= 720,
                             "Viewer has usable native dimensions before the video is loaded")
        try await Task.sleep(nanoseconds: 150_000_000)
        for size in [NSSize(width: 720, height: 540), NSSize(width: 1040, height: 800)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            guard let canvas = findCanvas(host) else { throw SpyError.message("TEST FAILED: Video canvas exists") }
            try SelfTest.require(canvas.frame.height >= 160 && abs(canvas.frame.width - size.width) < 2,
                                 "Video stays visible at minimum and standard window sizes: \(size), canvas \(canvas.frame)")
            try SelfTest.require(canvas.expandButton.isHidden && canvas.playerView.controlsStyle == .none,
                                 "Inline viewer has one control deck and no duplicate full-screen bar")
        }
        viewer.present(title: "Refreshed snapshot", show: false, canClose: { !saving }, onClose: { closed += 1 }) {
            BufferPreviewSheet(preview: preview, model: model)
        }
        try SelfTest.require(viewer.window === window && window.contentView!.frame.height == 800,
                             "Refreshing content reuses the resized window")
        saving = true
        window.performClose(nil)
        try SelfTest.require(viewer.window === window && closed == 0, "Native close protects an active export")
        saving = false
        window.performClose(nil)
        try SelfTest.require(viewer.window == nil && closed == 1 && window.contentView == nil,
                             "User close releases player content and invokes cleanup exactly once")
        viewer.dismiss()
        try SelfTest.require(closed == 1, "Programmatic dismissal is idempotent")
        viewer.present(title: "Saved movie", show: false, onClose: {}) { PlayerSheet(clip: clip, model: model) }
        viewer.window?.setContentSize(NSSize(width: 720, height: 540))
        viewer.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        guard let savedHost = viewer.window?.contentView, let savedCanvas = findCanvas(savedHost) else {
            throw SpyError.message("TEST FAILED: Saved-video canvas exists")
        }
        try SelfTest.require(abs(savedCanvas.frame.width - 720) < 2 && savedCanvas.frame.height >= 160,
                             "Saved-video actions never widen or clip the minimum window")
        viewer.dismiss()
        let small = VideoViewerWindow.contentSize(visible: NSRect(x: 0, y: 0, width: 800, height: 600))
        try SelfTest.require(small.width == 736 && small.height == 520, "Small displays reserve space for macOS chrome")
        model.closeBufferPreview()
        try SelfTest.require(!FileManager.default.fileExists(atPath: previewFolder.path), "Closing preview releases its pinned folder")
        print("PASS: independent preview dimensions, resize, single control deck, protected close, cleanup, small displays")
    }

    private static func findCanvas(_ view: NSView) -> FullSizePlayerHost? {
        if let canvas = view as? FullSizePlayerHost { return canvas }
        for child in view.subviews { if let canvas = findCanvas(child) { return canvas } }
        return nil
    }
}
