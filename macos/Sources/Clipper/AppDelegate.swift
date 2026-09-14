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

    private func updateStatusIcon() {
        let raw = UserDefaults.standard.string(forKey: PrefKey.menuIcon) ?? MenuIcon.paperclip.rawValue
        let icon = MenuIcon(rawValue: raw) ?? .paperclip
        let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: "Clipper")
        image?.isTemplate = true
        statusItem?.button?.image = image
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
    @objc private func togglePause() { watcher.isPaused.toggle() }

    // MARK: Panel

    private func setupPanel() {
        let d = UserDefaults.standard
        let width = max(300, d.double(forKey: PrefKey.windowWidth))
        let height = max(300, d.double(forKey: PrefKey.windowHeight))
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            statusBarButton: statusItem?.button,
            onClose: { [weak self] in self?.panelDidClose() }
        ) { [model] in
            ContentView(model: model)
        }
        panel.minSize = NSSize(width: 300, height: 200)
        self.panel = panel
        model.dismiss = { [weak self] in self?.panel?.close() }
    }

    func togglePopup(at requested: PopupPosition? = nil) {
        guard let panel else { return }
        if panel.isPresented {
            panel.close()
            return
        }
        model.reload(keepSelection: false)
        model.query = ""
        let raw = UserDefaults.standard.string(forKey: PrefKey.popupPosition) ?? PopupPosition.cursor.rawValue
        let position = requested ?? PopupPosition(rawValue: raw) ?? .cursor
        panel.open(height: max(300, UserDefaults.standard.double(forKey: PrefKey.windowHeight)), at: position)
    }

    private func panelDidClose() {
        model.previewedId = nil
        model.shiftDown = false
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
        // Key events while our panel is key never reach SwiftUI's focus
        // system first, so route them through the model (arrows, ⏎, ⌘n…).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isPresented, event.window === panel else { return event }
            return self.model.handle(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let panel = self.panel, panel.isPresented else { return event }
            self.model.shiftDown = event.modifierFlags.contains(.shift)
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
