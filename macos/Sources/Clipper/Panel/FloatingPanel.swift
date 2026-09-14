import AppKit
import SwiftUI

/// Non-activating floating panel that hosts the SwiftUI history list.
///
/// Behaviour follows Maccy's `FloatingPanel`: it never activates the app (so
/// the previously focused app keeps focus and ⌘V lands there), floats above
/// full-screen apps, closes when it loses key status, and highlights the
/// status-bar button while attached to it.
final class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
    private let statusBarButton: NSStatusBarButton?
    private var onClose: (() -> Void)?

    private(set) var isPresented = false

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
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: view())
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Presentation

    func toggle(height: CGFloat, at position: PopupPosition) {
        if isPresented {
            close()
        } else {
            open(height: height, at: position)
        }
    }

    func open(height: CGFloat, at position: PopupPosition) {
        let size = NSSize(width: frame.width, height: height)
        setContentSize(size)
        setFrameOrigin(position.origin(size: size, statusBarButton: statusBarButton))
        orderFrontRegardless()
        makeKey()
        isPresented = true
        if position == .statusItem {
            statusBarButton?.isHighlighted = true
        }
    }

    override func close() {
        guard isPresented else { return }
        isPresented = false
        statusBarButton?.isHighlighted = false
        super.close()
        onClose?()
    }

    /// Animate a height change while keeping the top edge in place, so the
    /// panel grows downwards from the status item / cursor.
    func verticallyResize(to height: CGFloat) {
        var newFrame = frame
        newFrame.size.height = height
        newFrame.origin.y = frame.maxY - height
        if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if newFrame.minY < visible.minY {
                newFrame.origin.y = visible.minY
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: NSWindowDelegate

    override func resignKey() {
        super.resignKey()
        // Keep the panel while one of our own alerts (e.g. "Clear history?")
        // is in front; otherwise clicking anywhere else dismisses it.
        if NSApp.modalWindow == nil {
            close()
        }
    }

    func windowDidResize(_ notification: Notification) {
        UserDefaults.standard.set(frame.width, forKey: PrefKey.windowWidth)
        UserDefaults.standard.set(frame.height, forKey: PrefKey.windowHeight)
    }
}
