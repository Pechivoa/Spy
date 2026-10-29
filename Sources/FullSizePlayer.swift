import SwiftUI
import AVKit

/// Covers the current display without creating an excluded fullscreen Space.
/// The same AVPlayerView moves between containers, keeping its item and controls.
struct FullSizePlayer: NSViewRepresentable {
    let player: AVPlayer?
    let title: String
    var editor: PlayerEditingState? = nil

    func makeNSView(context: Context) -> FullSizePlayerHost {
        FullSizePlayerHost(player: player, title: title, editor: editor)
    }
    func updateNSView(_ view: FullSizePlayerHost, context: Context) {
        view.update(player: player, title: title, editor: editor)
    }
    static func dismantleNSView(_ view: FullSizePlayerHost, coordinator: ()) {
        view.presentation.close(returnFocus: false)
        view.editor?.detachHost(view)
        view.playerView.player = nil
    }
}

@MainActor final class FullSizePlayerHost: NSView {
    let playerView = AVPlayerView()
    let expandButton = NSButton()
    let presentation = FullSizePlayerPresentation()
    private(set) var videoTitle: String
    private(set) var editor: PlayerEditingState?
    private var playerConstraints: [NSLayoutConstraint] = []
    static let entryBarHeight: CGFloat = 42

    init(player: AVPlayer?, title: String, editor: PlayerEditingState? = nil) {
        videoTitle = title
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.player = player
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "На весь экран")
        expandButton.title = "На весь экран"
        expandButton.imagePosition = .imageLeading
        expandButton.bezelStyle = .rounded
        expandButton.isBordered = true
        expandButton.wantsLayer = true
        expandButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        expandButton.layer?.cornerRadius = 7
        expandButton.contentTintColor = .white
        expandButton.toolTip = "На весь экран · выход — Esc"
        expandButton.setAccessibilityLabel("На весь экран")
        expandButton.identifier = NSUserInterfaceItemIdentifier("Spy.FullSizePlayer.Enter")
        expandButton.target = self; expandButton.action = #selector(expand)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(expandButton)
        NSLayoutConstraint.activate([
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            expandButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 142),
            expandButton.heightAnchor.constraint(equalToConstant: 30)
        ])
        restoreInlinePlayer()
        expandButton.isEnabled = player != nil
        editor?.attachHost(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(player: AVPlayer?, title: String, editor: PlayerEditingState? = nil) {
        if playerView.player !== player {
            presentation.close(returnFocus: false)
            playerView.player = player
        }
        videoTitle = title
        if self.editor !== editor { self.editor?.detachHost(self); self.editor = editor }
        editor?.attachHost(self)
        expandButton.isEnabled = player != nil
    }
    @objc private func expand() { presentation.present(self) }

    func movePlayer(to container: NSView, topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        NSLayoutConstraint.deactivate(playerConstraints)
        if playerView.superview !== container {
            playerView.removeFromSuperview()
            playerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(playerView, positioned: .below, relativeTo: container.subviews.first)
        }
        playerConstraints = [
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -(container === self ? Self.entryBarHeight : bottomInset))
        ]
        NSLayoutConstraint.activate(playerConstraints)
    }
    func restoreInlinePlayer() { movePlayer(to: self) }
}

@MainActor final class FullSizePlayerPresentation: NSObject, NSWindowDelegate {
    private(set) var panel: FullSizePlaybackPanel?
    private weak var host: FullSizePlayerHost?
    private weak var sourceWindow: NSWindow?
    private var previousPresentation: NSApplication.PresentationOptions?
    private var appliedPresentation: NSApplication.PresentationOptions?
    private var screenObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var activityMonitor: Any?
    private var idleTask: Task<Void, Never>?
    private var rateObservation: NSKeyValueObservation?
    private weak var controlsContainer: NSView?
    private weak var exitButton: NSButton?
    private weak var pinButton: NSButton?
    private var safeTop: CGFloat = 0
    private var editorHeight: CGFloat = 0
    private var lastPointer: NSPoint?
    private(set) var chromeHidden = false
    private(set) var chromePinned = false
    var chromeIdleInterval: Double = 2.5

    @discardableResult func present(_ host: FullSizePlayerHost, show: Bool = true) -> Bool {
        if let panel {
            if show { panel.makeKeyAndOrderFront(nil) }
            return true
        }
        guard host.playerView.player != nil, let screen = host.window?.screen ?? NSScreen.main else { return false }
        self.host = host; sourceWindow = host.window
        let panel = FullSizePlaybackPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Spy — " + host.videoTitle
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.backgroundColor = .black
        panel.isOpaque = true; panel.hasShadow = false
        panel.delegate = self
        panel.onExit = { [weak self] in self?.close() }

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        safeTop = max(0, screen.safeAreaInsets.top)
        let exit = NSButton(title: "Выйти · Esc", target: self, action: #selector(exitFullSize))
        exit.bezelStyle = .rounded
        exit.toolTip = "Вернуться к просмотру в окне"
        exit.setAccessibilityLabel("Выйти из полноэкранного просмотра")
        exit.identifier = NSUserInterfaceItemIdentifier("Spy.FullSizePlayer.Exit")
        exit.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(exit)
        NSLayoutConstraint.activate([
            exit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            exit.topAnchor.constraint(equalTo: content.topAnchor, constant: safeTop + 14),
            exit.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        let pin = NSButton(checkboxWithTitle: "Панель всегда видна", target: self, action: #selector(toggleChromePin))
        pin.identifier = NSUserInterfaceItemIdentifier("Spy.FullSizePlayer.PinControls")
        pin.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pin)
        NSLayoutConstraint.activate([
            pin.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            pin.topAnchor.constraint(equalTo: content.topAnchor, constant: safeTop + 14)
        ])
        pinButton = pin; exitButton = exit
        if let editor = host.editor {
            editorHeight = 238
            let controls = FullSizeEditingControlsContainer(editor: editor)
            controls.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(controls)
            controlsContainer = controls
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
                controls.heightAnchor.constraint(equalToConstant: editorHeight - 14)
            ])
        } else { editorHeight = 0 }
        host.movePlayer(to: content, topInset: safeTop + 58, bottomInset: editorHeight)
        panel.contentView = content
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel
        panel.acceptsMouseMovedEvents = true
        rateObservation = host.playerView.player?.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.noteInteraction() }
        }
        let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                guard let current = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayNumber }) else {
                    self.close(returnFocus: false); return
                }
                // Hiding the Dock/menu bar also emits this notification. Only
                // real geometry changes need an update; they must not dismiss it.
                if panel.frame != current.frame { panel.setFrame(current.frame, display: true) }
            }
        }
        if show {
            // SwiftUI sheets also register Escape. Consume both halves while
            // this panel is key, then restore the sheet after the key is released.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard event.keyCode == 53, self?.panel?.isKeyWindow == true else { return event }
                if event.type == .keyUp { self?.close() }
                return nil
            }
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
                if event.window === self?.panel { self?.noteInteraction(at: event.locationInWindow) }
                return event
            }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(host.playerView)
            lastPointer = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        }
        noteInteraction()
        return true
    }

    @objc private func exitFullSize() { close() }
    @objc private func toggleChromePin() {
        chromePinned = pinButton?.state == .on
        noteInteraction()
    }
    func noteInteraction(at point: NSPoint? = nil) {
        if let point { lastPointer = point }
        setChromeHidden(false)
        idleTask?.cancel()
        guard panel != nil, !chromePinned else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((self?.chromeIdleInterval ?? 2.5) * 1_000_000_000)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.panel != nil else { return }
                let pointerOverControls = self.lastPointer.map { point in
                    (self.controlsContainer?.frame.contains(point) ?? false) ||
                    (self.exitButton?.frame.contains(point) ?? false) || (self.pinButton?.frame.contains(point) ?? false)
                } ?? false
                guard !self.chromePinned, self.host?.playerView.player?.rate ?? 0 > 0, !pointerOverControls else { return }
                if self.host?.editor?.isSaving == true || self.host?.editor?.isStepping == true ||
                    self.host?.editor?.isSeeking == true || NSEvent.pressedMouseButtons != 0 {
                    // Finishing a seek or releasing a held mouse button must
                    // not permanently consume the only scheduled idle check.
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                    continue
                }
                self.setChromeHidden(true)
                return
            }
        }
    }
    func setControlsPinned(_ pinned: Bool) {
        chromePinned = pinned; pinButton?.state = pinned ? .on : .off; noteInteraction()
    }
    private func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden, let content = panel?.contentView else { return }
        chromeHidden = hidden
        controlsContainer?.isHidden = hidden; exitButton?.isHidden = hidden; pinButton?.isHidden = hidden
        host?.playerView.controlsStyle = hidden ? .none : .floating
        host?.movePlayer(to: content, topInset: hidden ? 0 : safeTop + 58, bottomInset: hidden ? 0 : editorHeight)
        content.layoutSubtreeIfNeeded()
    }

    func close(returnFocus: Bool = true) {
        guard let panel else { return }
        let restoreFocus = returnFocus && panel.isKeyWindow && NSApp.isActive
        idleTask?.cancel(); idleTask = nil
        rateObservation?.invalidate(); rateObservation = nil
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor); self.activityMonitor = nil }
        host?.playerView.controlsStyle = .floating
        chromeHidden = false; chromePinned = false; lastPointer = nil
        controlsContainer = nil; exitButton = nil; pinButton = nil
        self.panel = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        restorePresentation()
        host?.restoreInlinePlayer()
        host = nil
        panel.delegate = nil; panel.onExit = nil
        panel.orderOut(nil); panel.contentView = nil; panel.close()
        if restoreFocus { sourceWindow?.makeKeyAndOrderFront(nil) }
        sourceWindow = nil
    }
    func windowWillClose(_ notification: Notification) { close(returnFocus: false) }
    func windowDidBecomeKey(_ notification: Notification) {
        guard previousPresentation == nil else { return }
        previousPresentation = NSApp.presentationOptions
        var options = NSApp.presentationOptions
        options.remove([.hideDock, .hideMenuBar])
        options.insert([.autoHideDock, .autoHideMenuBar])
        appliedPresentation = options
        NSApp.presentationOptions = options
    }
    func windowDidResignKey(_ notification: Notification) { restorePresentation() }
    private func restorePresentation() {
        if let previousPresentation, NSApp.presentationOptions == appliedPresentation {
            NSApp.presentationOptions = previousPresentation
        }
        previousPresentation = nil; appliedPresentation = nil
    }
}

/// Keep the toolbar's preferred width local to this container. AppKit derives
/// a window's maximum size from its content constraints, so a <=1200 constraint
/// connected to the content view can shrink a 2560-point fullscreen window.
@MainActor final class FullSizeEditingControlsContainer: NSView {
    let controls: NSHostingView<FullscreenEditingToolbar>
    init(editor: PlayerEditingState) {
        controls = NSHostingView(rootView: FullscreenEditingToolbar(editor: editor))
        controls.sizingOptions = []
        super.init(frame: .zero)
        addSubview(controls)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = min(1200, bounds.width)
        controls.frame = NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }
}

final class FullSizePlaybackPanel: NSPanel {
    var onExit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { onExit?(); return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onExit?() }
}
