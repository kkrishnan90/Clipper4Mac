import AppKit
import ApplicationServices

/// Where the popup appears. Defaults to `.caret` (near active text input /
/// caret, falling back seamlessly to mouse cursor).
enum PopupPosition: String, CaseIterable, Identifiable {
    case caret
    case cursor
    case statusItem
    case window
    case center
    case lastPosition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caret: "Near text cursor (or mouse)"
        case .cursor: "At mouse cursor"
        case .statusItem: "Under menu bar icon"
        case .window: "Centered in active window"
        case .center: "Centered on screen"
        case .lastPosition: "Where it was last time"
        }
    }

    /// Computes the target panel frame (origin + size) anchored smoothly to the
    /// requested location, flipping above the anchor when near the bottom of
    /// the screen and clamping within the active display's `visibleFrame`.
    func frame(size: NSSize, statusBarButton: NSStatusBarButton?) -> NSRect {
        let origin = self.origin(size: size, statusBarButton: statusBarButton)
        return NSRect(origin: origin, size: size)
    }

    /// Bottom-left origin for a panel of `size`, clamped to the visible frame
    /// of the relevant screen.
    func origin(size: NSSize, statusBarButton: NSStatusBarButton?) -> NSPoint {
        switch self {
        case .caret:
            if let anchor = Self.focusedInputAnchorRect() {
                let screen = Self.screenContaining(NSPoint(x: anchor.midX, y: anchor.midY))
                return Self.placeNear(anchorRect: anchor, size: size, on: screen).origin
            }
            return PopupPosition.cursor.origin(size: size, statusBarButton: statusBarButton)

        case .cursor:
            let mouse = NSEvent.mouseLocation
            let screen = Self.screenContaining(mouse)
            // Treat the pointer as a tiny anchor box so we can flip above it
            // cleanly when invoked in the lower half of the display.
            let anchor = NSRect(x: mouse.x, y: mouse.y - 4, width: 1, height: 8)
            return Self.placeNear(anchorRect: anchor, size: size, on: screen).origin

        case .statusItem:
            guard let button = statusBarButton, let window = button.window else {
                return PopupPosition.center.origin(size: size, statusBarButton: nil)
            }
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            let rect = NSRect(
                origin: NSPoint(x: screenRect.minX, y: screenRect.minY - size.height - 4),
                size: size
            )
            return Self.clamp(rect, to: window.screen ?? Self.screenContaining(screenRect.origin)).origin

        case .window:
            if let frontmost = Self.frontmostWindowFrame() {
                let rect = NSRect(
                    origin: NSPoint(x: frontmost.midX - size.width / 2, y: frontmost.midY - size.height / 2),
                    size: size
                )
                let screen = NSScreen.screens.first { $0.frame.intersects(frontmost) }
                    ?? Self.screenContaining(NSPoint(x: frontmost.midX, y: frontmost.midY))
                return Self.clamp(rect, to: screen).origin
            }
            return PopupPosition.center.origin(size: size, statusBarButton: nil)

        case .center:
            let screen = Self.activeScreen()
            let visible = screen?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)

        case .lastPosition:
            let d = UserDefaults.standard
            if d.object(forKey: PrefKey.lastX) != nil {
                let rect = NSRect(
                    origin: NSPoint(x: d.double(forKey: PrefKey.lastX), y: d.double(forKey: PrefKey.lastY)),
                    size: size
                )
                let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? Self.activeScreen()
                return Self.clamp(rect, to: screen).origin
            }
            return PopupPosition.center.origin(size: size, statusBarButton: nil)
        }
    }

    // MARK: Smart placement & clamping

    /// Places `size` below `anchorRect` with a small gap; if there isn't room
    /// below and there is more room above, flips cleanly above `anchorRect` so
    /// the popup never covers the text field the user is typing into.
    private static func placeNear(anchorRect: NSRect, size: NSSize, on screen: NSScreen?) -> NSRect {
        let gap: CGFloat = 6
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: anchorRect.minX, y: anchorRect.minY - gap - size.height, width: size.width, height: size.height)
        }

        let spaceBelow = anchorRect.minY - visible.minY - gap
        let spaceAbove = visible.maxY - anchorRect.maxY - gap

        let y: CGFloat
        if spaceBelow >= size.height {
            y = anchorRect.minY - gap - size.height
        } else if spaceAbove >= size.height || spaceAbove > spaceBelow {
            y = anchorRect.maxY + gap
        } else {
            y = anchorRect.minY - gap - size.height
        }

        let candidate = NSRect(x: anchorRect.minX, y: y, width: size.width, height: size.height)
        return clamp(candidate, to: screen)
    }

    static func clamp(_ rect: NSRect, to screen: NSScreen?, margin: CGFloat = 6) -> NSRect {
        guard let visible = screen?.visibleFrame else { return rect }
        let minX = visible.minX + margin
        let maxX = visible.maxX - margin
        let minY = visible.minY + margin
        let maxY = visible.maxY - margin
        var r = rect
        if r.width > (maxX - minX) {
            r.origin.x = visible.minX
        } else {
            if r.maxX > maxX { r.origin.x = maxX - r.width }
            if r.minX < minX { r.origin.x = minX }
        }
        if r.height > (maxY - minY) {
            r.origin.y = visible.minY
        } else {
            if r.minY < minY { r.origin.y = minY }
            if r.maxY > maxY { r.origin.y = maxY - r.height }
        }
        return r
    }

    // MARK: Multi-monitor helpers

    /// Screen containing `point` using inclusive bounds (so touching the exact
    /// top/right display edge never falls back to the wrong monitor), with a
    /// nearest-screen fallback.
    static func screenContaining(_ point: NSPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { s in
            let f = s.frame
            return point.x >= f.minX && point.x <= f.maxX && point.y >= f.minY && point.y <= f.maxY
        }) {
            return exact
        }
        // Nearest screen by clamped Euclidean distance.
        return NSScreen.screens.min { a, b in
            distanceSquared(point, to: a.frame) < distanceSquared(point, to: b.frame)
        } ?? NSScreen.main
    }

    private static func distanceSquared(_ p: NSPoint, to r: NSRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Screen the user is currently interacting with (frontmost window if
    /// available, otherwise the screen under the mouse pointer).
    static func activeScreen() -> NSScreen? {
        if let win = frontmostWindowFrame(),
           let s = NSScreen.screens.first(where: { $0.frame.intersects(win) }) {
            return s
        }
        return screenContaining(NSEvent.mouseLocation)
    }

    /// Primary display height (the screen whose AppKit origin is `(0, 0)`),
    /// used to convert Quartz/Accessibility top-left Y to AppKit bottom-left Y.
    private static func primaryScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.screens.first?.frame.height ?? 0
    }

    private static func quartzToAppKit(_ rect: CGRect) -> NSRect {
        let primaryH = primaryScreenHeight()
        return NSRect(
            x: rect.origin.x,
            y: primaryH - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    // MARK: 4-tier Accessibility caret resolver

    /// Resolves the screen rect (in AppKit coordinates) of the active text
    /// insertion caret, or the focused input control if caret bounds aren't
    /// exposed by the target app. Returns `nil` when no text input is focused
    /// or Accessibility permission is not granted.
    private static func focusedInputAnchorRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        let element = focusedRef as! AXUIElement

        // Tier 1: Exact caret bounds for `AXSelectedTextRange`.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            let rangeVal = rangeRef as! AXValue
            if let rect = boundsForRange(element: element, rangeValue: rangeVal), isValidCaretRect(rect) {
                return quartzToAppKit(rect)
            }

            // Tier 2: Many Electron / Chromium / Xcode views return an empty
            // rect for a zero-length caret range. Query the character right
            // before the caret and anchor to its trailing edge.
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeVal, .cfRange, &cfRange), cfRange.location > 0 {
                var prevRange = CFRange(location: cfRange.location - 1, length: 1)
                if let prevVal = AXValueCreate(.cfRange, &prevRange),
                   let rect = boundsForRange(element: element, rangeValue: prevVal),
                   isValidCaretRect(rect) {
                    let trailing = CGRect(x: rect.maxX, y: rect.origin.y, width: 2, height: rect.height)
                    return quartzToAppKit(trailing)
                }
            }
        }

        // Tier 3: Focused element frame (`AXPosition` + `AXSize`) — only for
        // text-accepting controls (text fields, text areas, combo boxes, web
        // areas) so we don't anchor to a full window or desktop.
        guard isTextInputElement(element) else { return nil }
        if let elemRect = elementFrame(element), elemRect.width > 0, elemRect.height > 0 {
            let appKitElem = quartzToAppKit(elemRect)
            // If the input is a large multiline editor (e.g., VS Code / web
            // area) without caret bounds, fall back to mouse if the mouse is
            // already inside the editor; otherwise anchor near its top-left.
            if appKitElem.height > 200 {
                let mouse = NSEvent.mouseLocation
                if appKitElem.contains(mouse) {
                    return NSRect(x: mouse.x, y: mouse.y - 4, width: 1, height: 8)
                }
                return NSRect(x: appKitElem.minX + 12, y: appKitElem.maxY - 28, width: 2, height: 20)
            }
            return appKitElem
        }

        return nil
    }

    private static func boundsForRange(element: AXUIElement, rangeValue: AXValue) -> CGRect? {
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard err == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func isValidCaretRect(_ rect: CGRect) -> Bool {
        // Reject uninitialised `(0, 0, 0, 0)` or implausibly giant rects.
        guard rect.height > 1, rect.height < 400 else { return false }
        if rect.origin == .zero && rect.width == 0 { return false }
        return true
    }

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef
        ) == .success, let role = roleRef as? String else {
            return false
        }
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
            "AXWebArea",
        ]
        return textRoles.contains(role)
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz)
        else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// Frame of the frontmost app's main window in screen coordinates
    /// (Quartz window list, flipped to AppKit's bottom-left origin).
    private static func frontmostWindowFrame() -> NSRect? {
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
            return quartzToAppKit(CGRect(x: x, y: y, width: w, height: h))
        }
        return nil
    }
}
