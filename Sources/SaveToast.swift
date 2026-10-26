import SwiftUI
import AppKit

struct SaveToastView: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 14) {
            SpyMark().fill(Theme.accent).frame(width: 28, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.green)
        }.padding(18).frame(width: 350, height: 82).background(Theme.panel, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.13)))
    }
}

@MainActor final class SaveToast {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    static func frame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.maxX - 370, y: visible.maxY - 102, width: 350, height: 82)
    }
    func show(title: String, detail: String, displayID: CGDirectDisplayID) {
        dismissWork?.cancel(); panel?.orderOut(nil)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID } ?? NSScreen.main
        guard let screen else { return }
        let popup = NSPanel(contentRect: Self.frame(in: screen.visibleFrame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.level = .statusBar
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        if #available(macOS 13.0, *) { popup.collectionBehavior.insert(.canJoinAllApplications) }
        popup.hidesOnDeactivate = false; popup.isFloatingPanel = true
        popup.isOpaque = false; popup.backgroundColor = .clear; popup.hasShadow = true
        popup.ignoresMouseEvents = true; popup.isReleasedWhenClosed = false
        popup.contentView = NSHostingView(rootView: SaveToastView(title: title, detail: detail).preferredColorScheme(.dark))
        panel = popup; popup.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self, weak popup] in popup?.orderOut(nil); self?.panel = nil }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
