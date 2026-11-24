import AppKit
import ClipperCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    let core = CoreService()
    private(set) lazy var watcher = ClipboardWatcher(core: core)
    private(set) lazy var model = HistoryModel(core: core, watcher: watcher)

    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel<ContentView>?
    private var previewPanel: PreviewPanel?
    private let zeroBlurInterceptor = ZeroBlurKeyInterceptor()
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var settingsWindowController: NSWindowController?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app (also set via LSUIElement so no Dock icon flashes).
        NSApp.setActivationPolicy(.accessory)

        if let error = core.startupError {
            let alert = NSAlert()
            alert.messageText = "Clipper could not open its history"
            alert.informativeText = error
            alert.runModal()
        }

        setupStatusItem()
        setupPanel()
        setupHotkey()
        setupMonitors()
        watcher.start()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyDefaults() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        zeroBlurInterceptor.stop()
        if UserDefaults.standard.bool(forKey: PrefKey.clearOnQuit) {
            core.clear(keepPinned: true)
        }
    }

    /// Re-opening from Finder / `open -a Clipper` shows the popup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePopup(at: .center)
        return false
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusIcon()
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Clipper"
        }
    }

    func updateStatusIcon() {
        let raw = UserDefaults.standard.string(forKey: PrefKey.menuIcon) ?? MenuIcon.paperclip.rawValue
        let icon = MenuIcon(rawValue: raw) ?? .paperclip
        let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: "Clipper")
        image?.isTemplate = true
        statusItem?.button?.image = image
        // Visually dim the icon when recording is paused so users never forget!
        statusItem?.button?.appearsDisabled = watcher.isPaused
        statusItem?.button?.toolTip = watcher.isPaused ? "Clipper (Paused)" : "Clipper"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopup(at: .statusItem)
        }
    }

    /// Right-click on the icon: the standard small menu.
    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Clipper", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let pause = NSMenuItem(
            title: watcher.isPaused ? "Resume Recording" : "Pause Recording",
            action: #selector(togglePause), keyEquivalent: ""
        )
        menu.addItem(pause)
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferencesFromMenu), keyEquivalent: ",")
        menu.addItem(withTitle: "About Clipper", action: #selector(showAboutFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.target == nil { item.target = self }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openFromMenu() { togglePopup(at: .statusItem) }
    @objc private func openPreferencesFromMenu() { openPreferences() }
    @objc private func showAboutFromMenu() { showAbout() }

    @objc func togglePause() {
        watcher.isPaused.toggle()
        model.isRecordingPaused = watcher.isPaused
        updateStatusIcon()
    }

    // MARK: Panel & PreviewPanel

    private func setupPanel() {
        let d = UserDefaults.standard
        let width = max(320, d.double(forKey: PrefKey.windowWidth))
        let height = max(240, d.double(forKey: PrefKey.windowHeight))

        let preview = PreviewPanel(core: core)
        self.previewPanel = preview
        preview.onPointerExited = { [weak self] in
            guard let self, let panel = self.panel, panel.isPresented else { return }
            // Hide hover-opened preview when leaving the preview panel unless
            // the pointer moved back onto the main panel.
            if !panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
                self.model.handleListHoverExit()
            }
        }

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            statusBarButton: statusItem?.button,
            onClose: { [weak self] in self?.panelDidClose() }
        ) { [model] in
            ContentView(model: model)
        }
        panel.minSize = NSSize(width: 300, height: 180)
        panel.siblingPreviewPanel = preview
        self.panel = panel

        model.dismiss = { [weak self] restoreFocus in
            self?.panel?.dismissPanel(restoreFocus: restoreFocus)
        }
        model.onPreviewChanged = { [weak self] item in
            guard let self, let panel = self.panel, panel.isPresented else {
                self?.previewPanel?.hide()
                return
            }
            if let item {
                self.previewPanel?.show(item: item, beside: panel)
            } else {
                self.previewPanel?.hide()
            }
        }
        model.onRequestResize = { [weak self] in
            guard let self, let panel = self.panel, panel.isPresented else { return }
            let target = self.idealPanelHeight()
            panel.verticallyResize(to: target, animated: true)
        }
        model.onPromoteToKeyWindow = { [weak self] in
            guard let self, let panel = self.panel, panel.isPresented else { return }
            // Stop Zero-Blur tap so native AppKit text field receives IME/selection events cleanly.
            self.zeroBlurInterceptor.stop()
            self.model.isZeroBlurActive = false
            panel.promoteToKeyWindow()
            self.model.requestSearchFocus()
        }
        model.getPreviousApp = { [weak self] in
            self?.panel?.previousApp
        }
        model.isPointerOverPreview = { [weak self] in
            guard let preview = self?.previewPanel, preview.isVisible else { return false }
            return preview.frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
        }
    }

    /// Computes a compact height fitted to the current item count, capped at
    /// the user's preferred maximum height (default 460 pt instead of 800 pt).
    private func idealPanelHeight() -> CGFloat {
        let d = UserDefaults.standard
        let maxHeight = max(340, min(720, d.double(forKey: PrefKey.windowHeight)))
        let showSearch = d.bool(forKey: PrefKey.showSearch)
        let showFilter = d.bool(forKey: PrefKey.showFilterBar)
        let showFooter = d.bool(forKey: PrefKey.showFooter)
        let imageRowHeight = CGFloat(max(22, d.integer(forKey: PrefKey.imageMaxHeight))) + 8

        var chrome: CGFloat = 12 // list vertical padding + dividers
        if showSearch { chrome += 44 }
        if showFilter { chrome += 30 }
        if showFooter { chrome += 98 }
        let needsAXBanner = !Paster.isTrusted && (
            d.bool(forKey: PrefKey.pasteOnSelect)
            || d.bool(forKey: PrefKey.zeroBlurMode)
            || (d.string(forKey: PrefKey.popupPosition) ?? PopupPosition.caret.rawValue) == PopupPosition.caret.rawValue
        )
        if watcher.isPaused || needsAXBanner {
            chrome += 28
        }
        if model.undoBannerTitle != nil { chrome += 30 }

        let listHeight: CGFloat
        if model.items.isEmpty {
            listHeight = 68
        } else {
            var sum: CGFloat = 0
            for item in model.items.prefix(30) {
                sum += (item.kind == .image && item.hasThumbnail) ? imageRowHeight : 26
                if sum + chrome >= maxHeight { break }
            }
            if model.pinnedEndId != nil { sum += 9 }
            listHeight = max(52, sum)
        }

        return min(CGFloat(maxHeight), max(180, chrome + listHeight))
    }

    func togglePopup(at requested: PopupPosition? = nil) {
        guard let panel else { return }
        if panel.isPresented {
            panel.dismissPanel(restoreFocus: true)
            return
        }

        let d = UserDefaults.standard
        let raw = d.string(forKey: PrefKey.popupPosition) ?? PopupPosition.caret.rawValue
        let position = requested ?? PopupPosition(rawValue: raw) ?? .caret

        // Attempt Zero-Blur Mode (keeps host app's text input completely focused!)
        // when enabled and Accessibility is trusted.
        let wantZeroBlur = d.bool(forKey: PrefKey.zeroBlurMode) && Paster.isTrusted
        var zeroBlurActive = false
        if wantZeroBlur {
            zeroBlurActive = zeroBlurInterceptor.start(
                onKeyDown: { [weak self] event in
                    guard let self, let panel = self.panel, panel.isPresented else { return false }
                    return self.model.handle(event, zeroBlurTextCapture: true)
                },
                onFlagsChanged: { [weak self] flags in
                    guard let self, let panel = self.panel, panel.isPresented else { return }
                    self.model.shiftDown = flags.contains(.shift)
                    self.model.optionDown = flags.contains(.option)
                }
            )
        }

        // Single clean reset + reload BEFORE computing ideal height & opening.
        // Clicking the menu bar icon starts with no row pre-highlighted (native
        // menu feel); pressing the global hotkey pre-selects item #1 for instant ⏎.
        let openedByMouse = (requested == .statusItem)
        model.prepareForOpen(zeroBlur: zeroBlurActive, openedByMouse: openedByMouse)

        let width = max(320, d.double(forKey: PrefKey.windowWidth))
        let height = idealPanelHeight()
        panel.open(width: width, height: height, at: position, zeroBlur: zeroBlurActive)
    }

    private func panelDidClose() {
        zeroBlurInterceptor.stop()
        previewPanel?.hide()
        model.handlePanelClosed()
        if let panel {
            UserDefaults.standard.set(panel.frame.origin.x, forKey: PrefKey.lastX)
            UserDefaults.standard.set(panel.frame.origin.y, forKey: PrefKey.lastY)
        }
    }

    // MARK: Hotkey & keyboard

    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .popup) { [weak self] in
            Task { @MainActor in self?.togglePopup() }
        }
        // Pin/delete are popup-local chords, not global hotkeys. Recording a
        // shortcut re-enables its name, so disable again on every change.
        let local: [KeyboardShortcuts.Name] = [.pin, .delete]
        KeyboardShortcuts.disable(local)
        NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: .main
        ) { note in
            if let name = note.userInfo?["name"] as? KeyboardShortcuts.Name, local.contains(name) {
                KeyboardShortcuts.disable(name)
            }
        }
    }

    private func setupMonitors() {
        // Local monitors handle key events when the panel IS key (standard mode
        // or after the user clicked into the Search field).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isPresented, event.window === panel else { return event }
            return self.model.handle(event, zeroBlurTextCapture: false) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let panel = self.panel, panel.isPresented else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.model.shiftDown = flags.contains(.shift)
            self.model.optionDown = flags.contains(.option)
            return event
        }
    }

    // MARK: Preferences / About

    func openPreferences() {
        if settingsWindowController == nil {
            let hosting = NSHostingController(rootView: SettingsView(core: core))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Clipper Preferences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Clipper",
            .credits: NSAttributedString(
                string: "Native clipboard history for macOS.\nEngine: clipper-core \(engineVersion()) (Rust).",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
    }

    // MARK: Preferences → runtime

    private var appliedFingerprint = ""

    private func applyDefaults() {
        let d = UserDefaults.standard
        let policy = CoreService.policyFromDefaults()
        let fingerprint = [
            d.string(forKey: PrefKey.menuIcon) ?? "",
            String(d.integer(forKey: PrefKey.clipboardCheckIntervalMs)),
            String(describing: policy),
        ].joined(separator: "|")
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint
        updateStatusIcon()
        watcher.start() // picks up a changed poll interval
        core.applyPolicyFromDefaults()
    }

    /// Launch at login via the modern API (macOS 13+); no helper bundle.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login: \(error)")
            }
        }
    }
}
