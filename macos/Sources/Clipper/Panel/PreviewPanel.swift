import AppKit
import ClipperCore
import Observation
import SwiftUI

/// Observable state backing the reusable non-activating `PreviewPanel`.
@MainActor
@Observable
final class PreviewPanelState {
    var item: ItemSummary?
}

/// Dedicated non-activating side `NSPanel` for item previews.
///
/// Replaces SwiftUI's `.popover()` (whose internal `_NSPopoverWindow` can steal
/// key status, trigger `FloatingPanel.resignKey()`, and activate `NSApp`).
/// This panel *never* becomes key, never steals focus from the host app or
/// search box, reuses a single `NSHostingView` without flicker, and auto-flips
/// to the left edge when the main panel is near the right side of the display.
@MainActor
final class PreviewPanel: NSPanel {
    private let state = PreviewPanelState()
    private let panelSize = NSSize(width: 360, height: 380)
    var onPointerExited: (() -> Void)?

    init(core: CoreService) {
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 380)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: PreviewPanelHostView(state: state, core: core) { [weak self] in
            self?.onPointerExited?()
        })
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    /// Never steal key or main status under any circumstance.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows or updates the preview beside `anchorWindow`.
    func show(item: ItemSummary, beside anchorWindow: NSWindow) {
        state.item = item

        let parentFrame = anchorWindow.frame
        let screen = PopupPosition.screenContaining(NSPoint(x: parentFrame.midX, y: parentFrame.midY))
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8

        // Prefer placing to the right; flip cleanly to the left if clipped.
        let rightX = parentFrame.maxX + gap
        let leftX = parentFrame.minX - gap - panelSize.width
        let x: CGFloat
        if rightX + panelSize.width <= visible.maxX - 6 {
            x = rightX
        } else if leftX >= visible.minX + 6 {
            x = leftX
        } else {
            x = rightX
        }

        // Align top edges with the main panel, then clamp vertically.
        let targetY = parentFrame.maxY - panelSize.height
        let candidate = NSRect(origin: NSPoint(x: x, y: targetY), size: panelSize)
        let finalFrame = PopupPosition.clamp(candidate, to: screen)

        setFrame(finalFrame, display: true)
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func hide() {
        state.item = nil
        if isVisible {
            orderOut(nil)
        }
    }
}

private struct PreviewPanelHostView: View {
    @Bindable var state: PreviewPanelState
    let core: CoreService
    let onHoverExit: () -> Void

    var body: some View {
        Group {
            if let item = state.item {
                PreviewView(item: item, core: core)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
            }
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
        .onHover { inside in
            if !inside { onHoverExit() }
        }
    }
}
