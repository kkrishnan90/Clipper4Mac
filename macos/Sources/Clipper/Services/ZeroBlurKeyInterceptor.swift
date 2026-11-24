import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Temporary session `CGEvent` tap enabled *only* while `FloatingPanel` is open
/// in Zero-Blur Mode.
///
/// Because `FloatingPanel` never calls `makeKey()` in Zero-Blur Mode, the user's
/// active browser/IDE/Slack window keeps key status and its text cursor stays
/// live without blurring. This interceptor captures keyboard navigation, action
/// shortcuts, and search typing while the popup is visible, consuming them so
/// nothing leaks into the underlying input field.
@MainActor
final class ZeroBlurKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onKeyDown: ((NSEvent) -> Bool)?
    private var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?

    var isActive: Bool { eventTap != nil }

    /// Attempts to install the session tap. Returns `false` if Accessibility
    /// permission is missing (caller transparently falls back to key-panel mode).
    @discardableResult
    func start(
        onKeyDown: @escaping (NSEvent) -> Bool,
        onFlagsChanged: @escaping (NSEvent.ModifierFlags) -> Void
    ) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }

        self.onKeyDown = onKeyDown
        self.onFlagsChanged = onFlagsChanged

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, cgEvent, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let interceptor = Unmanaged<ZeroBlurKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleCGEvent(type: type, cgEvent: cgEvent)
            },
            userInfo: refcon
        ) else {
            self.onKeyDown = nil
            self.onFlagsChanged = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        onKeyDown = nil
        onFlagsChanged = nil
    }

    /// Runs on the main run loop because `runLoopSource` is attached to
    /// `CFRunLoopGetMain()`.
    private nonisolated func handleCGEvent(
        type: CGEventType,
        cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(cgEvent)
            }

            guard let nsEvent = NSEvent(cgEvent: cgEvent) else {
                return Unmanaged.passUnretained(cgEvent)
            }

            if type == .flagsChanged {
                onFlagsChanged?(nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
                return Unmanaged.passUnretained(cgEvent)
            }

            if type == .keyDown {
                // Consume handled events so they never reach the host app's input.
                if let handler = onKeyDown, handler(nsEvent) {
                    return nil
                }
            }

            return Unmanaged.passUnretained(cgEvent)
        }
    }
}
