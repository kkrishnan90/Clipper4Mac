import Foundation
import KeyboardShortcuts

/// `UserDefaults` keys. UI/behaviour preferences live here; the storage
/// policy is mirrored into the Rust engine via `StoragePolicy`.
enum PrefKey {
    static let popupPosition = "popupPosition"
    static let pasteOnSelect = "pasteOnSelect"
    static let pastePlainByDefault = "pastePlainByDefault"
    static let showApplicationIcons = "showApplicationIcons"
    static let showPreview = "showPreview"
    static let previewDelayMs = "previewDelayMs"
    static let showSearch = "showSearch"
    static let showFooter = "showFooter"
    static let menuIcon = "menuIcon"
    static let ignoredApps = "ignoredApps"
    static let ignoreAllAppsExceptListed = "ignoreAllAppsExceptListed"
    static let clearOnQuit = "clearOnQuit"
    static let suppressClearAlert = "suppressClearAlert"
    static let clipboardCheckIntervalMs = "clipboardCheckIntervalMs"
    static let windowWidth = "windowWidth"
    static let windowHeight = "windowHeight"
    static let lastX = "lastPositionX"
    static let lastY = "lastPositionY"
    static let imageMaxHeight = "imageMaxHeight"
    // Storage policy (pushed to Rust).
    static let maxItems = "maxItems"
    static let storeImages = "storeImages"
    static let storeFiles = "storeFiles"
    static let keepRichText = "keepRichText"
    static let maxImageMB = "maxImageMB"

    /// Register defaults once at launch so `@AppStorage` and
    /// `UserDefaults.standard` agree before any preference is touched.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            popupPosition: PopupPosition.cursor.rawValue,
            pasteOnSelect: true,
            pastePlainByDefault: false,
            showApplicationIcons: false,
            showPreview: true,
            previewDelayMs: 1500,
            showSearch: true,
            showFooter: true,
            menuIcon: MenuIcon.paperclip.rawValue,
            ignoredApps: [
                "com.agilebits.onepassword7",
                "com.1password.1password",
                "com.apple.keychainaccess",
                "com.bitwarden.desktop",
            ],
            ignoreAllAppsExceptListed: false,
            clearOnQuit: false,
            suppressClearAlert: false,
            clipboardCheckIntervalMs: 500,
            windowWidth: 450,
            windowHeight: 800,
            imageMaxHeight: 40,
            maxItems: 500,
            storeImages: true,
            storeFiles: true,
            keepRichText: true,
            maxImageMB: 64,
        ])
    }
}

/// SF Symbols usable as the status-item image. All are template images so
/// they follow the menu bar's light/dark appearance automatically.
enum MenuIcon: String, CaseIterable, Identifiable {
    case paperclip
    case clipboard = "doc.on.clipboard"
    case scissors
    case list = "list.clipboard"

    var id: String { rawValue }
    var symbolName: String { rawValue }
    var title: String {
        switch self {
        case .paperclip: "Paperclip"
        case .clipboard: "Clipboard"
        case .scissors: "Scissors"
        case .list: "List"
        }
    }
}

extension KeyboardShortcuts.Name {
    /// ⇧⌘V – opens the popup. Users change it in Preferences › General.
    static let popup = Self("popup", default: .init(.v, modifiers: [.command, .shift]))
    /// ⌥P – pin/unpin the selected item.
    static let pin = Self("pin", default: .init(.p, modifiers: [.option]))
    /// ⌥⌫ – delete the selected item.
    static let delete = Self("delete", default: .init(.delete, modifiers: [.option]))
}
