import AppKit
import ClipperCore
import KeyboardShortcuts
import Observation

/// Filter tabs shown in the compact filter bar (cycled via `Tab`).
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case images
    case links
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .text: "Text"
        case .images: "Images"
        case .links: "Links"
        case .files: "Files"
        }
    }

    var itemKind: ItemKind? {
        switch self {
        case .text: .text
        case .images: .image
        case .links: .link
        case .files: .files
        case .all, .pinned: nil
        }
    }

    var pinnedOnly: Bool { self == .pinned }
}

/// Identifies a footer action row so highlight state is strictly mutually
/// exclusive with history list selection (impossible for two rows to highlight
/// blue simultaneously, and never gets stuck across panel closes).
enum FooterAction: Hashable {
    case clear
    case preferences
    case about
    case quit
}

/// Tracks whether the latest selection change came from keyboard or mouse so
/// `ScrollViewReader` only auto-scrolls on keyboard navigation (preventing
/// `onHover` ↔ `scrollTo` bounce loops).
enum SelectionSource {
    case keyboard
    case mouse
    case programmatic
}

/// State behind the popup: visible items, search query, active filter,
/// unified selection, preview scheduling, undo banner, and keyboard/mouse actions.
@MainActor
@Observable
final class HistoryModel {
    let core: CoreService
    let watcher: ClipboardWatcher

    private(set) var items: [ItemSummary] = []
    /// Precomputed ordinal (`1…9`) lookup by item ID so `ForEach` can iterate
    /// directly by stable `item.id` with zero index-reconciliation glitches.
    private(set) var ordinalById: [UInt64: Int] = [:]
    /// ID of the last pinned item in `items` (to render the pinned/recent divider).
    private(set) var pinnedEndId: UInt64?

    /// Bound to the search field.
    var query = ""
    var activeFilter: HistoryFilter = .all
    /// Currently highlighted history row (mutually exclusive with `hoveredFooter`).
    var selectedId: UInt64?
    /// Currently hovered footer row (clears visual list highlight when non-nil).
    var hoveredFooter: FooterAction?
    var selectionSource: SelectionSource = .programmatic
    /// Monotonic token incremented whenever keyboard navigation should scroll
    /// `selectedId` into view.
    private(set) var scrollRequestToken = 0
    /// Monotonic token incremented whenever the search field should focus.
    private(set) var focusRequestToken = 0

    var previewedId: UInt64?
    /// True while the popup panel is on screen (gates background reloads).
    var isPanelOpen = false
    /// True when opened in Zero-Blur mode (host app keeps key window).
    var isZeroBlurActive = false
    /// Live modifier state for footer/hint feedback.
    var shiftDown = false
    var optionDown = false
    /// Mirrors `watcher.isPaused` for reactive UI banner.
    var isRecordingPaused = false
    /// Mirrors `Paster.isTrusted` (`AXIsProcessTrusted()`) reactively on every open.
    var isAccessibilityTrusted = Paster.isTrusted
    /// Non-nil for 5 seconds after deleting an item so user can press ⌘Z.
    var undoBannerTitle: String?

    /// Callbacks wired by `AppDelegate`.
    var dismiss: ((Bool) -> Void)? // parameter: restoreFocus
    var onPreviewChanged: ((ItemSummary?) -> Void)?
    var onRequestResize: (() -> Void)?
    var onPromoteToKeyWindow: (() -> Void)?
    var getPreviousApp: (() -> NSRunningApplication?)?
    var isPointerOverPreview: (() -> Bool)?

    private var observedRevision = -1
    private var searchTask: Task<Void, Never>?
    private var previewWorkItem: DispatchWorkItem?
    private var hoverExitWorkItem: DispatchWorkItem?
    private var undoHideWorkItem: DispatchWorkItem?
    /// Mouse position at the moment keyboard navigation occurred; `.onHover`
    /// ignores synthetic hover events caused by scrolling until the pointer
    /// physically moves.
    private var lastKeyboardMouseLocation: NSPoint?

    init(core: CoreService, watcher: ClipboardWatcher) {
        self.core = core
        self.watcher = watcher
        reload(keepSelection: false, autoSelectFirst: false)
    }

    // MARK: Lifecycle & Data

    func requestSearchFocus() {
        focusRequestToken &+= 1
    }

    /// Prepares fresh state right before opening the panel (single reload, zero flicker).
    /// - Parameter openedByMouse: When opened via menu-bar icon click, start
    ///   with *nothing* highlighted blue (just like a native macOS menu) until
    ///   the pointer hovers a row or the user presses an arrow key. When opened
    ///   via global hotkey, pre-select the first item for instant `Hotkey → ⏎`.
    func prepareForOpen(zeroBlur: Bool, openedByMouse: Bool) {
        searchTask?.cancel()
        cancelPreviewTimer()
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        previewedId = nil
        onPreviewChanged?(nil)
        hoveredFooter = nil
        shiftDown = false
        optionDown = false
        isRecordingPaused = watcher.isPaused
        isAccessibilityTrusted = Paster.isTrusted
        isZeroBlurActive = zeroBlur
        isPanelOpen = true
        lastKeyboardMouseLocation = nil

        // Reset query and filter BEFORE calling reload once.
        query = ""
        activeFilter = .all
        reload(keepSelection: false, autoSelectFirst: !openedByMouse)
        focusRequestToken &+= 1
    }

    func handlePanelClosed() {
        isPanelOpen = false
        isZeroBlurActive = false
        searchTask?.cancel()
        cancelPreviewTimer()
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        previewedId = nil
        onPreviewChanged?(nil)
        hoveredFooter = nil
        shiftDown = false
        optionDown = false
        lastKeyboardMouseLocation = nil
    }

    func reload(keepSelection: Bool = true, autoSelectFirst: Bool = true) {
        let previous = selectedId
        items = core.list(
            query: query,
            kind: activeFilter.itemKind,
            pinnedOnly: activeFilter.pinnedOnly
        )

        var ordinals: [UInt64: Int] = [:]
        ordinals.reserveCapacity(min(9, items.count))
        for (idx, it) in items.prefix(9).enumerated() {
            ordinals[it.id] = idx + 1
        }
        ordinalById = ordinals

        if let lastPinned = items.lastIndex(where: \.pinned), lastPinned < items.count - 1 {
            pinnedEndId = items[lastPinned].id
        } else {
            pinnedEndId = nil
        }

        observedRevision = core.revision
        selectionSource = .programmatic
        if keepSelection, let previous, items.contains(where: { $0.id == previous }) {
            selectedId = previous
        } else if autoSelectFirst {
            selectedId = items.first?.id
        } else {
            selectedId = nil
        }
        if let pid = previewedId, !items.contains(where: { $0.id == pid }) {
            setPreview(nil)
        }
        if isPanelOpen {
            onRequestResize?()
        }
    }

    func queryChanged() {
        searchTask?.cancel()
        hoveredFooter = nil
        if query.isEmpty {
            reload(keepSelection: false, autoSelectFirst: true)
            return
        }
        // Lightweight 35 ms debounce keeps rapid typing buttery smooth.
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            self.reload(keepSelection: false, autoSelectFirst: true)
        }
    }

    func setFilter(_ filter: HistoryFilter) {
        guard activeFilter != filter else { return }
        hoveredFooter = nil
        activeFilter = filter
        reload(keepSelection: false, autoSelectFirst: true)
    }

    func cycleFilter(reverse: Bool = false) {
        let all = HistoryFilter.allCases
        guard let idx = all.firstIndex(of: activeFilter) else { return }
        let next = reverse ? (idx - 1 + all.count) % all.count : (idx + 1) % all.count
        setFilter(all[next])
    }

    /// Cheap check views call from `onChange(of: core.revision)` — skipped when hidden!
    func reloadIfStale() {
        guard isPanelOpen else { return }
        if observedRevision != core.revision {
            reload(keepSelection: true, autoSelectFirst: selectedId != nil)
        }
    }

    var selectedItem: ItemSummary? {
        guard let selectedId else { return nil }
        return items.first { $0.id == selectedId }
    }

    var pinnedCount: Int { items.filter(\.pinned).count }

    // MARK: Selection & Hover (strictly single-highlight across list + footer)

    func select(offset: Int, wrap: Bool = false) {
        guard !items.isEmpty else { return }
        hoveredFooter = nil
        let idx = selectedId.flatMap { id in items.firstIndex { $0.id == id } }
        let next: Int
        if let idx {
            if wrap && abs(offset) == 1 {
                next = (idx + offset + items.count) % items.count
            } else {
                next = min(max(idx + offset, 0), items.count - 1)
            }
        } else {
            // Starting from no selection (e.g. opened via tray click):
            // ↓ picks the first item, ↑ picks the last item.
            next = offset >= 0 ? 0 : items.count - 1
        }
        lastKeyboardMouseLocation = NSEvent.mouseLocation
        selectionSource = .keyboard
        selectedId = items[next].id
        scrollRequestToken &+= 1
        if previewedId != nil {
            setPreview(items[next])
        }
    }

    func selectFirst() {
        guard let first = items.first else { return }
        hoveredFooter = nil
        lastKeyboardMouseLocation = NSEvent.mouseLocation
        selectionSource = .keyboard
        selectedId = first.id
        scrollRequestToken &+= 1
        if previewedId != nil { setPreview(first) }
    }

    func selectLast() {
        guard let last = items.last else { return }
        hoveredFooter = nil
        lastKeyboardMouseLocation = NSEvent.mouseLocation
        selectionSource = .keyboard
        selectedId = last.id
        scrollRequestToken &+= 1
        if previewedId != nil { setPreview(last) }
    }

    /// ⌘1…⌘9 pick the n-th visible row.
    func select(ordinal: Int) -> Bool {
        guard ordinal >= 1, ordinal <= min(9, items.count) else { return false }
        hoveredFooter = nil
        selectionSource = .keyboard
        selectedId = items[ordinal - 1].id
        return true
    }

    /// Called by `HistoryListView` on row hover. Ignores synthetic hover fires
    /// triggered by `scrollTo` when the pointer hasn't physically moved.
    func handleRowHover(item: ItemSummary, inside: Bool) {
        guard isPanelOpen else { return }
        if inside {
            hoverExitWorkItem?.cancel()
            hoverExitWorkItem = nil
            if let kbMouse = lastKeyboardMouseLocation {
                let now = NSEvent.mouseLocation
                let moved = hypot(now.x - kbMouse.x, now.y - kbMouse.y)
                if moved < 3.0 {
                    // Pointer hasn't moved since keyboard scroll — ignore!
                    return
                }
                lastKeyboardMouseLocation = nil
            }
            if hoveredFooter != nil { hoveredFooter = nil }
            selectionSource = .mouse
            if selectedId != item.id {
                selectedId = item.id
            }
            // If preview is already visible, switch immediately without re-waiting the delay!
            if previewedId != nil {
                cancelPreviewTimer()
                if previewedId != item.id {
                    setPreview(item)
                }
            } else {
                schedulePreview(for: item)
            }
        } else if previewedId == item.id {
            cancelPreviewTimer()
        }
    }

    /// Called when the pointer enters/leaves a footer row. Clears list selection
    /// highlight while hovering footer so two rows are NEVER highlighted blue at once.
    func handleFooterHover(_ action: FooterAction, inside: Bool) {
        guard isPanelOpen else { return }
        if inside {
            cancelPreviewTimer()
            setPreview(nil)
            selectedId = nil
            hoveredFooter = action
        } else if hoveredFooter == action {
            hoveredFooter = nil
        }
    }

    /// Gracefully hides hover-triggered preview when the pointer leaves the
    /// list, unless the pointer moved onto the sibling `PreviewPanel` to scroll.
    func handleListHoverExit() {
        cancelPreviewTimer()
        guard selectionSource == .mouse, previewedId != nil else { return }
        hoverExitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPanelOpen else { return }
            if self.isPointerOverPreview?() == true { return }
            self.setPreview(nil)
        }
        hoverExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    // MARK: Preview scheduling (single cancellable timer)

    func schedulePreview(for item: ItemSummary) {
        cancelPreviewTimer()
        let d = UserDefaults.standard
        guard d.bool(forKey: PrefKey.showPreview) else { return }
        let delayMs = max(0, d.integer(forKey: PrefKey.previewDelayMs))
        let itemId = item.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPanelOpen, self.selectedId == itemId, self.hoveredFooter == nil else { return }
            if let current = self.items.first(where: { $0.id == itemId }) {
                self.setPreview(current)
            }
        }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    func togglePreviewForSelected() {
        cancelPreviewTimer()
        guard let item = selectedItem ?? items.first else { return }
        if selectedId == nil { selectedId = item.id }
        if previewedId == item.id {
            setPreview(nil)
        } else {
            setPreview(item)
        }
    }

    func cancelPreviewTimer() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
    }

    private func setPreview(_ item: ItemSummary?) {
        previewedId = item?.id
        onPreviewChanged?(item)
    }

    // MARK: Actions

    /// Enter / click: write pasteboard, dismiss panel *immediately*, post ⌘V,
    /// and update usage metadata asynchronously so there is zero freeze or jump.
    func activate(_ id: UInt64? = nil, modifiers: NSEvent.ModifierFlags = []) {
        guard let id = id ?? selectedId ?? items.first?.id else { return }
        let d = UserDefaults.standard
        var paste = d.bool(forKey: PrefKey.pasteOnSelect)
        var plain = d.bool(forKey: PrefKey.pastePlainByDefault)
        if modifiers.contains(.shift) { paste.toggle() }
        if modifiers.contains(.option) { plain.toggle() }

        guard let content = core.pasteContent(id, plainTextOnly: plain) else { return }
        Paster.write(content, watcher: watcher)

        let wasZeroBlur = isZeroBlurActive
        let targetApp = getPreviousApp?()

        // Hide the panel BEFORE touching redb so there is zero visual jump or fsync stall.
        dismiss?(true)

        if paste {
            Paster.pasteWhenReady(targetApp: targetApp, zeroBlur: wasZeroBlur)
        }

        core.touchAsync(id)
    }

    func togglePin(_ id: UInt64? = nil) {
        guard let id = id ?? selectedId, let item = items.first(where: { $0.id == id }) else { return }
        core.setPinned(id, !item.pinned)
        reload(keepSelection: true, autoSelectFirst: true)
        selectedId = id
    }

    func delete(_ id: UInt64? = nil) {
        guard let id = id ?? selectedId else { return }
        let idx = items.firstIndex { $0.id == id } ?? 0
        let deletedTitle = items.first(where: { $0.id == id })?.title ?? "Item"
        core.delete(id)
        reload(keepSelection: false, autoSelectFirst: false)
        if !items.isEmpty {
            selectedId = items[min(idx, items.count - 1)].id
        }
        showUndoBanner(title: deletedTitle)
    }

    func undoDelete() {
        undoHideWorkItem?.cancel()
        undoHideWorkItem = nil
        undoBannerTitle = nil
        if let restored = core.undoDelete() {
            reload(keepSelection: false, autoSelectFirst: false)
            selectedId = restored.id
        }
    }

    private func showUndoBanner(title: String) {
        undoHideWorkItem?.cancel()
        undoBannerTitle = title
        let work = DispatchWorkItem { [weak self] in
            self?.undoBannerTitle = nil
        }
        undoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    /// Clear (unpinned) or clear everything, with the confirmation Maccy shows.
    func clear(all: Bool) {
        hoveredFooter = nil
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
        undoBannerTitle = nil
        core.clear(keepPinned: !all)
        reload(keepSelection: false, autoSelectFirst: false)
    }

    // MARK: Keyboard handling (shared by local monitor & Zero-Blur CGEvent tap)

    func handle(_ event: NSEvent, zeroBlurTextCapture: Bool = false) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        // Pin / delete shortcuts are user-configurable (Preferences › General).
        if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
            if shortcut == KeyboardShortcuts.getShortcut(for: .pin) {
                togglePin()
                return true
            }
            if shortcut == KeyboardShortcuts.getShortcut(for: .delete) {
                let isOptionDelete = event.keyCode == 51 && opt && !cmd && !ctrl
                if isOptionDelete && !query.isEmpty {
                    if zeroBlurTextCapture {
                        deleteLastWordInQuery()
                        queryChanged()
                        return true
                    }
                    return false
                }
                delete()
                return true
            }
        }

        // Control+N / Control+P (macOS / Emacs navigation)
        if ctrl && !cmd && !opt, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "n" { select(offset: 1, wrap: true); return true }
            if chars == "p" { select(offset: -1, wrap: true); return true }
        }

        switch event.keyCode {
        case 125: select(offset: 1, wrap: true); return true  // ↓
        case 126: select(offset: -1, wrap: true); return true // ↑
        case 121: select(offset: 10); return true             // page down
        case 116: select(offset: -10); return true            // page up
        case 115: selectFirst(); return true                  // home
        case 119: selectLast(); return true                   // end
        case 48: // tab -> cycle type filter
            if !cmd && !ctrl {
                cycleFilter(reverse: flags.contains(.shift))
                return true
            }
        case 36, 76: // return / keypad enter
            activate(modifiers: flags)
            return true
        case 53: // escape
            if previewedId != nil {
                setPreview(nil)
            } else if !query.isEmpty {
                query = ""
                queryChanged()
            } else if activeFilter != .all {
                activeFilter = .all
                reload(keepSelection: false, autoSelectFirst: true)
            } else {
                dismiss?(true)
            }
            return true
        case 51 where cmd && opt: // ⌥⌘⌫
            clear(all: flags.contains(.shift))
            return true
        case 49 where query.isEmpty && !cmd && !opt && !ctrl: // Space -> toggle preview
            togglePreviewForSelected()
            return true
        case 124 where query.isEmpty && !cmd && !opt && !ctrl: // → -> toggle preview
            togglePreviewForSelected()
            return true
        default:
            break
        }

        if cmd, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if select(ordinal: Int(chars)!) {
                    activate(modifiers: flags.subtracting(.command))
                    return true
                }
            case ",":
                dismiss?(false)
                AppDelegate.shared?.openPreferences()
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            case "j": select(offset: 1, wrap: true); return true
            case "k": select(offset: -1, wrap: true); return true
            case "y": togglePreviewForSelected(); return true
            case "z" where undoBannerTitle != nil && query.isEmpty:
                undoDelete()
                return true
            case "v" where zeroBlurTextCapture:
                if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                    let singleLine = str.components(separatedBy: .newlines).first ?? str
                    query.append(singleLine)
                    queryChanged()
                }
                return true
            default:
                break
            }
        }

        if zeroBlurTextCapture {
            if let popupShortcut = KeyboardShortcuts.getShortcut(for: .popup),
               KeyboardShortcuts.Shortcut(event: event) == popupShortcut {
                dismiss?(true)
                return true
            }
            if event.keyCode == 51 { // Backspace
                if cmd {
                    query = ""
                } else if opt {
                    deleteLastWordInQuery()
                } else if !query.isEmpty {
                    query.removeLast()
                }
                queryChanged()
                return true
            }
            if !cmd && !ctrl, let chars = event.characters, !chars.isEmpty {
                let printable = chars.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }
                if !printable.isEmpty {
                    query.append(String(String.UnicodeScalarView(printable)))
                    queryChanged()
                    return true
                }
            }
            return true
        }

        return false
    }

    private func deleteLastWordInQuery() {
        while query.last?.isWhitespace == true { query.removeLast() }
        while let last = query.last, !last.isWhitespace { query.removeLast() }
    }
}
