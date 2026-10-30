import AppKit
import SwiftUI

/// A viewer must not inherit the mini-widget's 150-point sheet height.
/// Keep its native window and SwiftUI sizing independent of the main window.
@MainActor final class VideoViewerWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var onClose: (() -> Void)?
    private var canClose: () -> Bool = { true }
    private var frameName: String?

    static func contentSize(visible: NSRect) -> NSSize {
        NSSize(width: min(1040, max(320, visible.width - 64)),
               height: min(800, max(300, visible.height - 80)))
    }

    func present<Content: View>(title: String, frameName: String? = nil, show: Bool = true,
                               canClose: @escaping () -> Bool = { true },
                               onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.canClose = canClose; self.onClose = onClose
        if let window, let host = window.contentView as? NSHostingView<AnyView> {
            window.title = title
            host.rootView = AnyView(content())
            if show { bringForward() }
            return
        }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = Self.contentSize(visible: visible)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        self.window = window; self.frameName = frameName
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.background)
        window.contentMinSize = NSSize(width: min(720, size.width), height: min(540, size.height))
        window.delegate = self
        let host = NSHostingView(rootView: AnyView(content()))
        // Intrinsic SwiftUI size must never turn this into a short sheet or cap
        // a maximized window at the width of its toolbar.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
        if let frameName { _ = window.setFrameUsingName(frameName) }
        // Saved positions may belong to a disconnected display.
        var frame = window.frame
        let target = window.screen?.visibleFrame ?? visible
        frame.size.width = min(frame.width, target.width)
        frame.size.height = min(frame.height, target.height)
        frame.origin.x = min(max(frame.minX, target.minX), target.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, target.minY), target.maxY - frame.height)
        window.setFrame(frame, display: false)
        if show { bringForward() }
    }

    func bringForward() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        guard let window else { return }
        if let frameName { window.saveFrame(usingName: frameName) }
        self.window = nil; onClose = nil
        window.delegate = nil
        window.contentView = nil // releases the player, observers and fullscreen panel
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        dismiss()
        callback?()
    }
}

@MainActor extension AppModel {
    func presentBufferViewer() {
        guard !previewMode else { return }
        guard let preview = bufferPreview else { bufferViewer.dismiss(); return }
        bufferViewer.present(title: preview.recoveryOrigin == nil ? "Spy — Предпросмотр буфера" : "Spy — Восстановление",
            frameName: "Spy.BufferViewer", canClose: { [weak self] in self?.saving != true },
            onClose: { [weak self] in self?.closeBufferPreview() }) {
                BufferPreviewSheet(preview: preview, model: self).id(preview.id)
            }
    }

    func presentSavedViewer() {
        guard !previewMode else { return }
        guard let clip = selectedClip else { savedViewer.dismiss(); return }
        savedViewer.present(title: "Spy — " + clip.title, frameName: "Spy.SavedViewer",
            canClose: { [weak self] in self?.saving != true },
            onClose: { [weak self] in self?.selectedClip = nil }) {
                PlayerSheet(clip: clip, model: self).id(clip.id)
            }
    }
}
