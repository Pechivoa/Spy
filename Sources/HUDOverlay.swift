import SwiftUI
import AppKit

enum HUDCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String { switch self { case .topLeft: return "Сверху слева"; case .topRight: return "Сверху справа"; case .bottomLeft: return "Снизу слева"; case .bottomRight: return "Снизу справа" } }
}
struct HUDState {
    var recording: Bool
    var manual: Bool
    var seconds: Double
    var bytes: Int64
    var battery: Bool
}
struct HUDView: View {
    let value: HUDState
    var width: CGFloat = 112
    var height: CGFloat = 24
    var body: some View {
        HStack(spacing: 5) {
            SpyMark().fill(Theme.accent).frame(width: 8, height: 10)
            Text(clockText(value.seconds)).lineLimit(1).minimumScaleFactor(0.65)
            if width >= 100 { Text("· " + fileSize(value.bytes)).foregroundStyle(Theme.muted).lineLimit(1) }
            Spacer(minLength: 0)
        }.font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6).frame(width: width, height: height).foregroundStyle(.white)
            .background(Theme.background.opacity(0.92), in: RoundedRectangle(cornerRadius: min(9, height / 2)))
            .overlay(RoundedRectangle(cornerRadius: min(9, height / 2)).stroke(Theme.border))
    }
}
@MainActor final class HUDOverlay: NSObject, NSWindowDelegate {
    static let minimumSize = CGSize(width: 56, height: 18)
    static let defaultSize = CGSize(width: 112, height: 24)
    private var panel: HUDPanel?
    private var surface: HUDSurface?
    private let preferences: UserDefaults
    private var lastDisplay: CGDirectDisplayID?
    private var lastCorner: HUDCorner?
    private var lastVisible: CGRect?
    private var applyingFrame = false
    var onHide: (() -> Void)?
    init(preferences: UserDefaults = .standard) { self.preferences = preferences; super.init() }
    static func frame(visible: CGRect, corner: HUDCorner, size: CGSize? = nil) -> CGRect {
        let size = size ?? defaultSize
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CGRect(x: left ? visible.minX + 20 : visible.maxX - size.width - 20, y: top ? visible.maxY - size.height - 20 : visible.minY + 20, width: size.width, height: size.height)
    }
    static func constrained(_ frame: CGRect, visible: CGRect) -> CGRect {
        let width = min(220, max(minimumSize.width, frame.width))
        let height = min(36, max(minimumSize.height, frame.height))
        return CGRect(x: max(visible.minX + 2, min(frame.minX, visible.maxX - width - 2)),
                      y: max(visible.minY + 2, min(frame.minY, visible.maxY - height - 2)), width: width, height: height)
    }
    func update(_ value: HUDState, enabled: Bool, displayID: CGDirectDisplayID, corner: HUDCorner) {
        guard enabled && value.recording else { hide(); return }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID } ?? NSScreen.main
        guard let screen else { return }
        let popup: HUDPanel
        if let panel { popup = panel } else {
            popup = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            popup.title = "Spy — индикатор"
            popup.level = .statusBar; popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
            popup.hidesOnDeactivate = false; popup.isFloatingPanel = true; popup.isOpaque = false
            popup.backgroundColor = .clear; popup.hasShadow = false; popup.ignoresMouseEvents = false; popup.isReleasedWhenClosed = false
            popup.isMovable = true; popup.isMovableByWindowBackground = true; popup.minSize = Self.minimumSize; popup.maxSize = CGSize(width: 220, height: 36)
            let view = HUDSurface()
            view.value = value
            view.autoresizingMask = [.width, .height]
            view.onResize = { [weak self] size in self?.setSize(size) }
            view.onHide = { [weak self] in self?.onHide?() }
            view.onReset = { [weak self] in self?.resetPosition() }
            popup.contentView = view
            surface = view
            var size = preferences.string(forKey: "hudSizeV2").map(NSSizeFromString) ?? Self.defaultSize
            size.width = min(220, max(Self.minimumSize.width, size.width)); size.height = min(36, max(Self.minimumSize.height, size.height))
            var position = Self.frame(visible: screen.visibleFrame, corner: corner, size: size)
            if preferences.string(forKey: "hudSavedCornerV2") == corner.rawValue,
               preferences.integer(forKey: "hudSavedDisplayV2") == Int(displayID),
               let saved = preferences.string(forKey: "hudFrameV2") {
                position.origin = NSRectFromString(saved).origin
            }
            applyingFrame = true
            popup.setFrame(Self.constrained(position, visible: screen.visibleFrame), display: true)
            applyingFrame = false
            panel = popup
            popup.delegate = self
            lastCorner = corner; lastDisplay = displayID; lastVisible = screen.visibleFrame
            persistFrame()
        }
        if lastCorner != corner || lastDisplay != displayID {
            applyingFrame = true
            popup.setFrame(Self.frame(visible: screen.visibleFrame, corner: corner, size: popup.frame.size), display: true)
            applyingFrame = false
            lastCorner = corner; lastDisplay = displayID
            persistFrame()
        } else if lastVisible != screen.visibleFrame {
            applyingFrame = true
            popup.setFrame(Self.constrained(popup.frame, visible: screen.visibleFrame), display: true)
            applyingFrame = false
            persistFrame()
        }
        lastVisible = screen.visibleFrame
        // Updating the counter must never reset the user's position or size.
        surface?.value = value; surface?.needsDisplay = true
        popup.orderFrontRegardless()
    }
    func setSize(_ requested: CGSize) {
        let size = CGSize(width: min(220, max(Self.minimumSize.width, requested.width)), height: min(36, max(Self.minimumSize.height, requested.height)))
        preferences.set(NSStringFromSize(size), forKey: "hudSizeV2")
        if let panel, let visible = lastVisible {
            let current = panel.frame
            panel.setFrame(Self.constrained(CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height), visible: visible), display: true)
            persistFrame()
        }
    }
    func resetPosition() {
        guard let panel, let corner = lastCorner, let visible = lastVisible else { return }
        panel.setFrame(Self.frame(visible: visible, corner: corner, size: panel.frame.size), display: true)
        persistFrame()
    }
    func windowDidMove(_ notification: Notification) { if !applyingFrame { persistFrame() } }
    func windowDidResize(_ notification: Notification) { surface?.needsDisplay = true; if !applyingFrame { persistFrame() } }
    private func persistFrame() {
        guard let panel else { return }
        preferences.set(NSStringFromRect(panel.frame), forKey: "hudFrameV2")
        preferences.set(NSStringFromSize(panel.frame.size), forKey: "hudSizeV2")
        preferences.set(lastCorner?.rawValue, forKey: "hudSavedCornerV2")
        preferences.set(lastDisplay.map { Int($0) }, forKey: "hudSavedDisplayV2")
    }
    func hide() { panel?.delegate = nil; panel?.orderOut(nil); panel = nil; surface = nil; lastCorner = nil; lastDisplay = nil; lastVisible = nil }

    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class HUDSurface: NSView {
        var value = HUDState(recording: true, manual: false, seconds: 0, bytes: 0, battery: false)
        var onResize: ((CGSize) -> Void)?
        var onHide: (() -> Void)?
        var onReset: (() -> Void)?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        override func draw(_ dirtyRect: NSRect) {
            let radius = min(9, bounds.height / 2)
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSColor(srgbRed: 0.075, green: 0.075, blue: 0.10, alpha: 0.92).setFill(); outline.fill()
            NSColor.white.withAlphaComponent(0.13).setStroke(); outline.lineWidth = 1; outline.stroke()
            NSColor(srgbRed: SpiderGlyph.accentRed, green: SpiderGlyph.accentGreen, blue: SpiderGlyph.accentBlue, alpha: 1).setFill()
            if let context = NSGraphicsContext.current?.cgContext {
                context.addPath(SpiderGlyph.path(in: CGRect(x: 5, y: (bounds.height - 10) / 2, width: 10, height: 10)))
                context.fillPath()
            }
            let label = clockText(value.seconds) + (bounds.width >= 100 ? " · " + fileSize(value.bytes) : "")
            let fontSize = min(12, max(9, (bounds.height - 4) * 0.46))
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
            let text = label as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(in: CGRect(x: 18, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 23), height: size.height), withAttributes: attributes)
            toolTip = "\(value.manual ? "Ручная запись" : "Повтор активен") · \(clockText(value.seconds)) · \(fileSize(value.bytes)). Перетащите индикатор; правый край меняет размер. Правый клик — скрыть."
            setAccessibilityLabel(toolTip)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
            addCursorRect(CGRect(x: bounds.maxX - 6, y: 0, width: 6, height: bounds.height), cursor: .resizeLeftRight)
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let location = convert(event.locationInWindow, from: nil)
            let resizing = location.x >= bounds.maxX - 6
            let start = window.frame, mouse = window.convertPoint(toScreen: event.locationInWindow)
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let point = window.convertPoint(toScreen: next.locationInWindow)
                let target: CGRect
                if resizing {
                    let size = CGSize(width: min(220, max(56, start.width + point.x - mouse.x)), height: min(36, max(18, start.height - point.y + mouse.y)))
                    target = CGRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height)
                } else {
                    target = start.offsetBy(dx: point.x - mouse.x, dy: point.y - mouse.y)
                }
                if let visible = window.screen?.visibleFrame { window.setFrame(HUDOverlay.constrained(target, visible: visible), display: true) }
            }
        }
        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            for (title, action) in [("Минимальный размер", #selector(makeMinimum)), ("Маленький размер", #selector(makeDefault)), ("Вернуть в угол", #selector(reset))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
            let hide = NSMenuItem(title: "Скрыть индикатор", action: #selector(hideIndicator), keyEquivalent: ""); hide.target = self; menu.addItem(hide)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        @objc private func makeMinimum() { onResize?(HUDOverlay.minimumSize) }
        @objc private func makeDefault() { onResize?(HUDOverlay.defaultSize) }
        @objc private func reset() { onReset?() }
        @objc private func hideIndicator() { onHide?() }
    }
}
