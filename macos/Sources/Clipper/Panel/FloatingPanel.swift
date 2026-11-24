import AppKit
import SwiftUI

/// Non-activating floating panel that hosts the SwiftUI history list.
///
/// Supports two presentation modes:
/// 1. **Zero-Blur Mode** (default when Accessibility is granted): orders front
///    with `orderFrontRegardless()` *without* calling `makeKey()`, paired with
///    `ZeroBlurKeyInterceptor`. The previously focused app's text field never
///    even receives `windowDidResignKey:` — the caret stays blinking live.
/// 2. **Standard Non-Activating Key Mode** (automatic fallback when
///    Accessibility is not granted, or when the user clicks the search field):
///    calls `makeKey()`, explicitly focuses the search field on every open, and
///    deterministically restores focus to `previousApp` on dismiss.
final class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    private let statusBarButton: NSStatusBarButton?
    private var onClose: (() -> Void)?
    private var globalClickMonitor: Any?

    private(set) var isPresented = false
    /// Controls `canBecomeKey`. Set `false` in Zero-Blur mode so the host
    /// window keeps key status; flipped `true` if standard key mode is active
    /// or the user clicks into the search field.
    private(set) var acceptsKeyWindow = false
    /// The application that was frontmost right before the panel opened.
    private(set) var previousApp: NSRunningApplication?
    /// True if `makeKey()` was called during this presentation session.
    private(set) var didTakeKeyWindow = false
    /// Optional reference to the sibling preview panel so click-outside
    /// detection ignores clicks inside the preview panel.
    weak var siblingPreviewPanel: NSPanel?

    init(
        contentRect: NSRect,
        statusBarButton: NSStatusBarButton?,
        onClose: (() -> Void)? = nil,
        @ViewBuilder view: () -> Content
    ) {
        self.statusBarButton = statusBarButton
        self.onClose = onClose

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        delegate = self
        isFloatingPanel = true
        level = .screenSaver
        // Avoid `.stationary` which can fight `.moveToActiveSpace` across
        // macOS Spaces and multi-monitor full-screen transitions.
        collectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Disabled so micro-drags while clicking rows never swallow clicks or
        // silently relocate the popup.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = FirstMouseHostingView(rootView: view())
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { acceptsKeyWindow }
    override var canBecomeMain: Bool { false }

    /// Prevent AppKit from clamping our frame against the *previous* screen
    /// when moving across multi-monitor displays; `PopupPosition` already
    /// clamps accurately to the target display's `visibleFrame`.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: Presentation

    func open(
        width: CGFloat,
        height: CGFloat,
        at position: PopupPosition,
        zeroBlur: Bool
    ) {
        // Capture the active foreground app BEFORE ordering front so we can
        // restore focus reliably if anything activates Clipper.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }

        let size = NSSize(width: width, height: height)
        let targetFrame = position.frame(size: size, statusBarButton: statusBarButton)

        // Single atomic geometry update prevents monitor-snap glitches.
        setFrame(targetFrame, display: true)

        acceptsKeyWindow = !zeroBlur
        didTakeKeyWindow = !zeroBlur

        // Smooth subtle fade-in without coordinate jumping.
        alphaValue = 0
        if zeroBlur {
            orderFrontRegardless()
        } else {
            // In standard key-panel mode (when Accessibility / Zero-Blur is not
            // active), explicitly entering WindowServer's activation stack lets
            // `NSApp.hide(nil)` on dismiss atomically restore key focus to the
            // exact previous window and input field.
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        isPresented = true
        if position == .statusItem {
            statusBarButton?.isHighlighted = true
        }
        installClickOutsideMonitor()
    }

    /// Promotes a Zero-Blur panel to accept key status (e.g. when the user
    /// explicitly clicks into the search field for IME/selection editing).
    func promoteToKeyWindow() {
        guard isPresented, !acceptsKeyWindow else { return }
        acceptsKeyWindow = true
        didTakeKeyWindow = true
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Dismisses the panel without destroying it, optionally restoring focus
    /// to `previousApp` if Clipper took key status or became active.
    func dismissPanel(restoreFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        removeClickOutsideMonitor()
        statusBarButton?.isHighlighted = false
        siblingPreviewPanel?.orderOut(nil)
        orderOut(nil)

        let shouldRestore = restoreFocus && (didTakeKeyWindow || NSApp.isActive)
        didTakeKeyWindow = false
        acceptsKeyWindow = false

        onClose?()

        if shouldRestore {
            // Yield cooperative activation (macOS 14+) and hide our accessory
            // app so WindowServer atomically restores key window + first
            // responder to the exact input field in `previousApp`.
            if let app = previousApp, !app.isTerminated {
                NSApp.yieldActivation(to: app)
                app.activate(options: [])
            }
            NSApp.hide(nil)
        }
    }

    override func close() {
        dismissPanel(restoreFocus: true)
    }

    /// Resize height smoothly while keeping the top edge anchored in place
    /// (clamped to the current screen's `visibleFrame`).
    func verticallyResize(to height: CGFloat, animated: Bool = true) {
        let clampedHeight = max(minSize.height, height)
        guard abs(frame.height - clampedHeight) > 2 else { return }
        var newFrame = frame
        newFrame.size.height = clampedHeight
        newFrame.origin.y = frame.maxY - clampedHeight
        let targetScreen = PopupPosition.screenContaining(NSPoint(x: newFrame.midX, y: newFrame.midY))
        newFrame = PopupPosition.clamp(newFrame, to: targetScreen)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    // MARK: Click-outside monitor (essential in Zero-Blur mode)

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPresented else { return }
                let loc = NSEvent.mouseLocation
                if self.frame.contains(loc) { return }
                if let preview = self.siblingPreviewPanel, preview.isVisible, preview.frame.contains(loc) { return }
                // Clicking inside the status bar button is handled by its own toggle action.
                if let btn = self.statusBarButton, let win = btn.window {
                    let btnRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))
                    if btnRect.contains(loc) { return }
                }
                // User clicked another window; don't yank focus back to previousApp.
                self.dismissPanel(restoreFocus: false)
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: NSWindowDelegate

    override func resignKey() {
        super.resignKey()
        // Only auto-dismiss on resignKey when we were actually the key window
        // and no modal alert of ours is open.
        if isPresented, didTakeKeyWindow, NSApp.modalWindow == nil {
            dismissPanel(restoreFocus: false)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard isPresented else { return }
        // Only persist user-driven resizes (when dragging the resize edge).
        if inLiveResize {
            UserDefaults.standard.set(frame.width, forKey: PrefKey.windowWidth)
            UserDefaults.standard.set(frame.height, forKey: PrefKey.windowHeight)
        }
    }
}

/// Ensures SwiftUI buttons and row taps inside a non-key Zero-Blur `NSPanel`
/// always fire on the very first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
