import AppKit
import ClipperCore
import KeyboardShortcuts
import Observation

/// State behind the popup: the visible items, the search query, the
/// selection, and the actions the keyboard/mouse trigger on them.
@MainActor
@Observable
final class HistoryModel {
    let core: CoreService
    let watcher: ClipboardWatcher

    private(set) var items: [ItemSummary] = []
    /// Bound to the search field; `ContentView` calls `queryChanged()`.
    var query = ""
    var selectedId: UInt64?
    var previewedId: UInt64?
    /// Set by the panel controller so actions can close the popup.
    var dismiss: (() -> Void)?
    /// Set while the ⇧ key is down (footer shows "Clear all").
    var shiftDown = false

    private var observedRevision = -1

    init(core: CoreService, watcher: ClipboardWatcher) {
        self.core = core
        self.watcher = watcher
        reload(keepSelection: false)
    }

    // MARK: Data

    func reload(keepSelection: Bool = true) {
        let previous = selectedId
        items = core.list(query: query)
        observedRevision = core.revision
        if keepSelection, let previous, items.contains(where: { $0.id == previous }) {
            selectedId = previous
        } else {
            selectedId = items.first?.id
        }
        if let previewedId, !items.contains(where: { $0.id == previewedId }) {
            self.previewedId = nil
        }
    }

    func queryChanged() { reload(keepSelection: false) }

    /// Cheap check views call from `onChange(of: core.revision)`.
    func reloadIfStale() {
        if observedRevision != core.revision { reload() }
    }

    var selectedItem: ItemSummary? {
        items.first { $0.id == selectedId }
    }

    var pinnedCount: Int { items.filter(\.pinned).count }

    // MARK: Selection

    func select(offset: Int) {
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.id == selectedId } ?? -1
        let next = min(max(idx + offset, 0), items.count - 1)
        selectedId = items[next].id
    }

    func selectFirst() { selectedId = items.first?.id }
    func selectLast() { selectedId = items.last?.id }

    /// ⌘1…⌘9 pick the n-th visible row.
    func select(ordinal: Int) -> Bool {
        guard ordinal >= 1, ordinal <= min(9, items.count) else { return false }
        selectedId = items[ordinal - 1].id
        return true
    }

    // MARK: Actions

    /// Enter / click: copy back and (by default) paste into the previous app.
    /// ⌥ inverts the plain-text preference, ⇧ inverts the paste-vs-copy one.
    func activate(_ id: UInt64? = nil, modifiers: NSEvent.ModifierFlags = []) {
        guard let id = id ?? selectedId else { return }
        let d = UserDefaults.standard
        var paste = d.bool(forKey: PrefKey.pasteOnSelect)
        var plain = d.bool(forKey: PrefKey.pastePlainByDefault)
        if modifiers.contains(.shift) { paste.toggle() }
        if modifiers.contains(.option) { plain.toggle() }

        guard let content = core.pasteContent(id, plainTextOnly: plain) else { return }
        Paster.write(content, watcher: watcher)
        core.touch(id)
        dismiss?()

        if paste {
            // Give the previous app a moment to regain key status.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !Paster.pressCommandV() {
                    Paster.requestAccessibility()
                }
            }
        }
    }

    func togglePin(_ id: UInt64? = nil) {
        guard let id = id ?? selectedId, let item = items.first(where: { $0.id == id }) else { return }
        core.setPinned(id, !item.pinned)
        reload()
        selectedId = id
    }

    func delete(_ id: UInt64? = nil) {
        guard let id = id ?? selectedId else { return }
        let idx = items.firstIndex { $0.id == id } ?? 0
        core.delete(id)
        reload(keepSelection: false)
        if !items.isEmpty {
            selectedId = items[min(idx, items.count - 1)].id
        }
    }

    /// Clear (unpinned) or clear everything, with the confirmation Maccy shows.
    func clear(all: Bool) {
        let d = UserDefaults.standard
        if !d.bool(forKey: PrefKey.suppressClearAlert) {
            let alert = NSAlert()
            alert.messageText = all ? "Clear all history?" : "Clear history?"
            alert.informativeText = all
                ? "Every item, including pinned ones, will be removed. This cannot be undone."
                : "Pinned items are kept. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                d.set(true, forKey: PrefKey.suppressClearAlert)
            }
            guard response == .alertFirstButtonReturn else { return }
        }
        core.clear(keepPinned: !all)
        reload(keepSelection: false)
    }

    // MARK: Keyboard

    /// Handles a key event from the panel's local monitor. Returns `true`
    /// when consumed.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)

        // Pin / delete shortcuts are user-configurable (Preferences › General).
        if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
            if shortcut == KeyboardShortcuts.getShortcut(for: .pin) { togglePin(); return true }
            if shortcut == KeyboardShortcuts.getShortcut(for: .delete) { delete(); return true }
        }

        switch event.keyCode {
        case 125: select(offset: 1); return true // ↓
        case 126: select(offset: -1); return true // ↑
        case 121: select(offset: 10); return true // page down
        case 116: select(offset: -10); return true // page up
        case 115: selectFirst(); return true // home
        case 119: selectLast(); return true // end
        case 36, 76: // return / keypad enter
            activate(modifiers: flags)
            return true
        case 53: // escape
            if !query.isEmpty { query = "" } else { dismiss?() }
            return true
        case 51 where cmd && flags.contains(.option): // ⌥⌘⌫
            clear(all: flags.contains(.shift))
            return true
        default:
            break
        }

        if cmd, let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if select(ordinal: Int(chars)!) { activate(modifiers: flags.subtracting(.command)); return true }
            case ",":
                dismiss?()
                AppDelegate.shared?.openPreferences()
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            case "j": select(offset: 1); return true
            case "k": select(offset: -1); return true
            default: break
            }
        }
        return false
    }
}
