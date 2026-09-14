import AppKit
import ClipperCore
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let core: CoreService

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            StorageTab(core: core)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            IgnoreTab()
                .tabItem { Label("Ignore", systemImage: "nosign") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralTab: View {
    @State private var launchAtLogin = AppDelegate.launchAtLogin
    @AppStorage(PrefKey.pasteOnSelect) private var pasteOnSelect = true
    @AppStorage(PrefKey.pastePlainByDefault) private var pastePlainByDefault = false
    @AppStorage(PrefKey.clearOnQuit) private var clearOnQuit = false
    @State private var accessibilityGranted = Paster.isTrusted

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Open Clipper:", name: .popup)
                KeyboardShortcuts.Recorder("Pin item:", name: .pin)
                KeyboardShortcuts.Recorder("Delete item:", name: .delete)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in AppDelegate.launchAtLogin = v }
                Toggle("Clear history when quitting (keeps pinned)", isOn: $clearOnQuit)
            }
            Section {
                Toggle("Paste automatically", isOn: $pasteOnSelect)
                Text("Hold ⇧ while selecting to copy without pasting.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Paste without formatting by default", isOn: $pastePlainByDefault)
                Text("Hold ⌥ while selecting to invert. Clipper always stores every format, so nothing is lost either way.")
                    .font(.caption).foregroundStyle(.secondary)
                if pasteOnSelect, !accessibilityGranted {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Pasting needs Accessibility permission.")
                        Spacer()
                        Button("Open System Settings…") {
                            Paster.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = Paster.isTrusted
        }
    }
}

private struct AppearanceTab: View {
    @AppStorage(PrefKey.popupPosition) private var popupPosition = PopupPosition.cursor.rawValue
    @AppStorage(PrefKey.menuIcon) private var menuIcon = MenuIcon.paperclip.rawValue
    @AppStorage(PrefKey.showApplicationIcons) private var showAppIcons = false
    @AppStorage(PrefKey.showSearch) private var showSearch = true
    @AppStorage(PrefKey.showFooter) private var showFooter = true
    @AppStorage(PrefKey.showPreview) private var showPreview = true
    @AppStorage(PrefKey.previewDelayMs) private var previewDelayMs = 1500
    @AppStorage(PrefKey.imageMaxHeight) private var imageMaxHeight = 40

    var body: some View {
        Form {
            Section {
                Picker("Popup appears:", selection: $popupPosition) {
                    ForEach(PopupPosition.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Menu bar icon:", selection: $menuIcon) {
                    ForEach(MenuIcon.allCases) { icon in
                        Label(icon.title, systemImage: icon.symbolName).tag(icon.rawValue)
                    }
                }
            }
            Section {
                Toggle("Show search field", isOn: $showSearch)
                Toggle("Show footer", isOn: $showFooter)
                Toggle("Show application icons", isOn: $showAppIcons)
                Stepper("Image row height: \(imageMaxHeight) pt", value: $imageMaxHeight, in: 20...120, step: 10)
            }
            Section {
                Toggle("Show preview on hover", isOn: $showPreview)
                if showPreview {
                    Stepper(
                        "Preview delay: \(Double(previewDelayMs) / 1000, specifier: "%.1f") s",
                        value: $previewDelayMs, in: 0...5000, step: 250
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StorageTab: View {
    let core: CoreService
    @AppStorage(PrefKey.maxItems) private var maxItems = 500
    @AppStorage(PrefKey.storeImages) private var storeImages = true
    @AppStorage(PrefKey.storeFiles) private var storeFiles = true
    @AppStorage(PrefKey.keepRichText) private var keepRichText = true
    @AppStorage(PrefKey.maxImageMB) private var maxImageMB = 64
    @AppStorage(PrefKey.clipboardCheckIntervalMs) private var intervalMs = 500
    @State private var stats: HistoryStats?

    var body: some View {
        Form {
            Section {
                Stepper("Keep up to \(maxItems) items", value: $maxItems, in: 10...10000, step: 50)
                Toggle("Store images", isOn: $storeImages)
                Toggle("Store files", isOn: $storeFiles)
                Toggle("Keep all formats (RTF, HTML, app-specific types)", isOn: $keepRichText)
                Text("Off: only plain text, PNG and file paths are kept. On: pasting reproduces the copy exactly.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Skip images larger than \(maxImageMB) MB", value: $maxImageMB, in: 1...512, step: 8)
                Stepper("Check clipboard every \(intervalMs) ms", value: $intervalMs, in: 100...2000, step: 100)
            }
            Section("On disk") {
                if let stats {
                    LabeledContent("Items", value: "\(stats.items) (\(stats.pinned) pinned)")
                    LabeledContent("Index", value: ByteCountFormatter.string(fromByteCount: Int64(stats.dbBytes), countStyle: .file))
                    LabeledContent("Blobs", value: ByteCountFormatter.string(fromByteCount: Int64(stats.blobBytes), countStyle: .file))
                    LabeledContent("Location") {
                        Button(stats.dataDir) {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: stats.dataDir)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
                HStack {
                    Button("Compact") { core.compact(); stats = core.stats() }
                    Spacer()
                    Button("Clear History…", role: .destructive) {
                        AppDelegate.shared?.model.clear(all: false)
                        stats = core.stats()
                    }
                    Button("Clear Everything…", role: .destructive) {
                        AppDelegate.shared?.model.clear(all: true)
                        stats = core.stats()
                    }
                }
            }
            Section {
                Text("Clipper never uses SQLite. The index is a copy-on-write redb database; every payload is a content-addressed file written with write-tmp → fsync → rename, so a crash can't leave a half-written record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { stats = core.stats() }
        .onChange(of: core.revision) { _, _ in stats = core.stats() }
    }
}

private struct IgnoreTab: View {
    @AppStorage(PrefKey.ignoreAllAppsExceptListed) private var invert = false
    @State private var apps: [String] = UserDefaults.standard.stringArray(forKey: PrefKey.ignoredApps) ?? []
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Picker("", selection: $invert) {
                    Text("Ignore copies from these apps").tag(false)
                    Text("Only record copies from these apps").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section {
                List(selection: $selection) {
                    ForEach(apps, id: \.self) { bundle in
                        HStack {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                Text(FileManager.default.displayName(atPath: url.path))
                                Text(bundle).foregroundStyle(.secondary).font(.caption)
                            } else {
                                Text(bundle)
                            }
                        }
                        .tag(bundle)
                    }
                }
                .frame(minHeight: 180)
                HStack {
                    Button("Add Application…", action: addApp)
                    Button("Remove") {
                        apps.removeAll { $0 == selection }
                        save()
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
            }
            Section {
                Text("Apps that mark copies as concealed or transient (1Password, Bitwarden, Keychain Access…) are skipped automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(apps, forKey: PrefKey.ignoredApps)
    }
}
