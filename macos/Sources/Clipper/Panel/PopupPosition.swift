import AppKit

/// Where the popup appears. Same options (and defaults) as Maccy.
enum PopupPosition: String, CaseIterable, Identifiable {
    case cursor
    case statusItem
    case window
    case center
    case lastPosition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: "At mouse cursor"
        case .statusItem: "Under menu bar icon"
        case .window: "Centered in active window"
        case .center: "Centered on screen"
        case .lastPosition: "Where it was last time"
        }
    }

    /// Bottom-left origin for a panel of `size`, clamped to the visible frame
    /// of the relevant screen.
    func origin(size: NSSize, statusBarButton: NSStatusBarButton?) -> NSPoint {
        switch self {
        case .cursor:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let rect = NSRect(origin: NSPoint(x: mouse.x, y: mouse.y - size.height), size: size)
            return clamp(rect, to: screen).origin

        case .statusItem:
            guard let button = statusBarButton, let window = button.window else {
                return PopupPosition.center.origin(size: size, statusBarButton: nil)
            }
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            let rect = NSRect(
                origin: NSPoint(x: screenRect.minX, y: screenRect.minY - size.height),
                size: size
            )
            return clamp(rect, to: window.screen ?? NSScreen.main).origin

        case .window:
            if let frontmost = frontmostWindowFrame() {
                let rect = NSRect(
                    origin: NSPoint(x: frontmost.midX - size.width / 2, y: frontmost.midY - size.height / 2),
                    size: size
                )
                let screen = NSScreen.screens.first { $0.frame.intersects(frontmost) } ?? NSScreen.main
                return clamp(rect, to: screen).origin
            }
            return PopupPosition.center.origin(size: size, statusBarButton: nil)

        case .center:
            let screen = NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)

        case .lastPosition:
            let d = UserDefaults.standard
            if d.object(forKey: PrefKey.lastX) != nil {
                let rect = NSRect(
                    origin: NSPoint(x: d.double(forKey: PrefKey.lastX), y: d.double(forKey: PrefKey.lastY)),
                    size: size
                )
                let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
                return clamp(rect, to: screen).origin
            }
            return PopupPosition.center.origin(size: size, statusBarButton: nil)
        }
    }

    private func clamp(_ rect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return rect }
        var r = rect
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        if r.minY < visible.minY { r.origin.y = visible.minY }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        return r
    }

    /// Frame of the frontmost app's main window in screen coordinates
    /// (Quartz window list, flipped to AppKit's bottom-left origin).
    private func frontmostWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: x, y: primaryHeight - y - h, width: w, height: h)
        }
        return nil
    }
}
