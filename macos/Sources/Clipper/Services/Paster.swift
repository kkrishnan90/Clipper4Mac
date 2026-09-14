import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipperCore

/// Writes history items back to the pasteboard and optionally simulates ⌘V.
enum Paster {
    /// Puts every captured flavour back on the pasteboard, byte-for-byte and
    /// in the original order. File URLs go through `writeObjects` so multiple
    /// files paste correctly in Finder (same trick as Maccy); all other
    /// flavours are set directly on the general pasteboard item.
    @MainActor
    static func write(_ content: PasteContent, watcher: ClipboardWatcher) {
        let pb = NSPasteboard.general
        pb.clearContents()

        let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
        var fileItems: [NSPasteboardItem] = []
        for flavor in content.flavors {
            if flavor.uti == fileURLType {
                let item = NSPasteboardItem()
                item.setData(flavor.data, forType: .fileURL)
                fileItems.append(item)
            } else {
                pb.setData(flavor.data, forType: NSPasteboard.PasteboardType(flavor.uti))
            }
        }
        if !fileItems.isEmpty {
            pb.writeObjects(fileItems)
        }
        pb.setString("", forType: ClipboardWatcher.fromClipperType)
        watcher.skipNextChange()
    }

    /// True when the app may post keyboard events into other apps.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy › Accessibility.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Simulates ⌘V in the frontmost app. Returns `false` when Accessibility
    /// permission is missing (the content is still on the pasteboard).
    @discardableResult
    static func pressCommandV() -> Bool {
        guard isTrusted else { return false }
        // Keycode for `v` on the current keyboard layout (falls back to ANSI).
        let keyCode = CGKeyCode(keyCodeForV() ?? UInt16(kVK_ANSI_V))
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Don't let our synthetic event be swallowed while the user still
        // holds the hotkey's modifiers.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Looks up the virtual key that produces "v" on the active input source.
    private static func keyCodeForV() -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt16? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            for code in UInt16(0)...127 {
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeys, chars.count, &length, &chars
                )
                if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                    return code
                }
            }
            return nil
        }
    }
}
