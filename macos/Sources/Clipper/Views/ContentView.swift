import AppKit
import ClipperCore
import SwiftUI

/// The popup's content: vibrancy background → search → filter bar → banners → list → undo → footer.
struct ContentView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.showSearch) private var showSearch = true
    @AppStorage(PrefKey.showFilterBar) private var showFilterBar = true
    @AppStorage(PrefKey.showFooter) private var showFooter = true
    @AppStorage(PrefKey.pasteOnSelect) private var pasteOnSelect = true
    @AppStorage(PrefKey.zeroBlurMode) private var zeroBlurMode = true
    @AppStorage(PrefKey.popupPosition) private var popupPosition = PopupPosition.caret.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                SearchFieldView(
                    text: Binding(
                        get: { model.query },
                        set: { newValue in
                            if model.query != newValue {
                                model.query = newValue
                                model.queryChanged()
                            }
                        }
                    ),
                    focusToken: model.focusRequestToken,
                    isZeroBlur: model.isZeroBlurActive,
                    onClickInZeroBlur: { model.onPromoteToKeyWindow?() },
                    onClear: { model.requestSearchFocus() }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, showFilterBar ? 5 : 8)
            }

            if showFilterBar {
                FilterBarView(active: model.activeFilter, isPanelOpen: model.isPanelOpen) { filter in
                    model.setFilter(filter)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            if showSearch || showFilterBar {
                Divider()
            }

            if model.isRecordingPaused {
                StatusBanner(
                    icon: "pause.circle.fill",
                    tint: .orange,
                    text: "Recording paused",
                    actionTitle: "Resume"
                ) {
                    AppDelegate.shared?.togglePause()
                }
                Divider()
            } else if !model.isAccessibilityTrusted && (pasteOnSelect || zeroBlurMode || popupPosition == PopupPosition.caret.rawValue) {
                StatusBanner(
                    icon: "hand.raised.fill",
                    tint: .yellow,
                    text: "Accessibility needed for caret & focus",
                    actionTitle: "Enable…"
                ) {
                    // Dismiss the `.screenSaver`-level panel first so System
                    // Settings opens cleanly in front of everything.
                    model.dismiss?(false)
                    Paster.requestAccessibility()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("If Clipper is already checked after an update, remove (−) and re-add Clipper in Privacy & Security → Accessibility.")
                Divider()
            }

            HistoryListView(model: model)

            if let deletedTitle = model.undoBannerTitle {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                    Text("Deleted \"\(deletedTitle)\"")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo ⌘Z") { model.undoDelete() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
            }

            if showFooter {
                Divider()
                FooterView(model: model)
            }
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
        .onChange(of: model.core.revision) { _, _ in model.reloadIfStale() }
        .ignoresSafeArea()
    }
}

private struct StatusBanner: View {
    let icon: String
    let tint: Color
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08))
    }
}

/// Compact pill strip exposing Rust's `ItemKind` and `pinnedOnly` filters (also cycled with `Tab`).
/// Uses a subtle neutral active pill so `Color.accentColor` blue is reserved
/// exclusively for the single selected row below.
private struct FilterBarView: View {
    let active: HistoryFilter
    let isPanelOpen: Bool
    let onSelect: (HistoryFilter) -> Void
    @State private var hoveredFilter: HistoryFilter?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(HistoryFilter.allCases) { filter in
                    let isActive = filter == active
                    let isHover = isPanelOpen && (filter == hoveredFilter)
                    Button {
                        onSelect(filter)
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        isActive
                                            ? Color.primary.opacity(0.15)
                                            : (isHover ? Color.primary.opacity(0.07) : Color.clear)
                                    )
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(isActive ? Color.primary.opacity(0.12) : .clear, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hoveredFilter = inside ? filter : (hoveredFilter == filter ? nil : hoveredFilter)
                    }
                }
            }
        }
        .onChange(of: isPanelOpen) { _, open in
            if !open { hoveredFilter = nil }
        }
    }
}

/// `NSVisualEffectView` – the same material Maccy and system popovers use.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Search field that works reliably in both presentation modes:
/// - In **Zero-Blur Mode**: displays the live query driven by
///   `ZeroBlurKeyInterceptor` without stealing key focus from the host app.
///   Clicking it promotes the panel to key status for IME/cursor editing.
/// - In **Standard Key Mode**: uses an AppKit `NSTextField` explicitly focused
///   via `makeFirstResponder` on every `focusToken` bump.
struct SearchFieldView: View {
    @Binding var text: String
    let focusToken: Int
    let isZeroBlur: Bool
    let onClickInZeroBlur: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if isZeroBlur {
                HStack(spacing: 1) {
                    if text.isEmpty {
                        Text("Type to filter…")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(text)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(width: 1.5, height: 13)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onClickInZeroBlur() }
            } else {
                AppKitSearchTextField(text: $text, focusToken: focusToken)
                    .frame(height: 17)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
    }
}

/// Native `NSTextField` wrapper that guarantees first-responder focus on every
/// panel open (even when the panel reuses its `NSHostingView`).
private struct AppKitSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = "Search"
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingHead
        tf.cell?.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = nsView.window, window.isKeyWindow else { return }
                if window.firstResponder !== nsView.currentEditor() {
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var lastFocusToken = -1

        init(text: Binding<String>) { _text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            if text != tf.stringValue {
                text = tf.stringValue
            }
        }
    }
}

struct HistoryListView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.showApplicationIcons) private var showAppIcons = false
    @AppStorage(PrefKey.imageMaxHeight) private var imageMaxHeight = 40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    // Keyed directly by stable `item.id` so hover tracking areas
                    // never bleed across items when history reorders.
                    ForEach(model.items, id: \.id) { item in
                        row(item)
                        if model.pinnedEndId == item.id {
                            Divider()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                        }
                    }
                    if model.items.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 4)
            }
            .onHover { inside in
                if !inside { model.handleListHoverExit() }
            }
            // Only auto-scroll on explicit keyboard navigation — never on mouse hover!
            .onChange(of: model.scrollRequestToken) { _, _ in
                if let id = model.selectedId {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
    }

    private var emptyMessage: String {
        if !model.query.isEmpty { return "No matches" }
        if model.activeFilter != .all { return "No \(model.activeFilter.title.lowercased()) items" }
        return "No clipboard history yet"
    }

    @ViewBuilder
    private func row(_ item: ItemSummary) -> some View {
        // Strictly mutually exclusive with footer hover: at most ONE row in the
        // entire popup is ever highlighted blue.
        let isSelected = (model.hoveredFooter == nil) && (item.id == model.selectedId)
        HistoryRow(
            item: item,
            ordinal: model.ordinalById[item.id],
            selected: isSelected,
            highlightQuery: model.query,
            thumbnail: item.hasThumbnail ? model.core.thumbnail(item.id) : nil,
            appIcon: (showAppIcons && item.source?.bundleId != nil)
                ? model.core.appIcon(forBundleId: item.source!.bundleId!)
                : nil,
            fileIcon: (item.kind == .files && !item.hasThumbnail && item.files.first != nil)
                ? model.core.fileIcon(forPath: item.files[0].path)
                : nil,
            imageMaxHeight: imageMaxHeight
        )
        .equatable()
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture {
            model.activate(item.id, modifiers: NSEvent.modifierFlags)
        }
        .onHover { inside in
            model.handleRowHover(item: item, inside: inside)
        }
        .contextMenu {
            Button("Paste") { model.activate(item.id) }
            Button("Paste as Plain Text") { model.activate(item.id, modifiers: .option) }
            Button("Copy Only") { model.activate(item.id, modifiers: .shift) }
            Divider()
            Button("Preview") {
                model.selectedId = item.id
                model.togglePreviewForSelected()
            }
            if item.kind == .link, let url = URL(string: item.title) {
                Button("Open Link") {
                    model.dismiss?(false)
                    NSWorkspace.shared.open(url)
                }
            }
            if item.kind == .files, let first = item.files.first {
                Button("Reveal in Finder") {
                    model.dismiss?(false)
                    NSWorkspace.shared.selectFile(first.path, inFileViewerRootedAtPath: "")
                }
            }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item.id) }
            Button("Delete", role: .destructive) { model.delete(item.id) }
        }
    }
}

/// One 26-pt row: icon/thumbnail/swatch · title (with query highlight) · pin · ⌘n hint.
/// Conforms to `Equatable` so moving selection only re-renders the two affected rows.
struct HistoryRow: View, Equatable {
    let item: ItemSummary
    let ordinal: Int?
    let selected: Bool
    let highlightQuery: String
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let fileIcon: NSImage?
    let imageMaxHeight: Int

    static func == (lhs: HistoryRow, rhs: HistoryRow) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.title == rhs.item.title
            && lhs.item.pinned == rhs.item.pinned
            && lhs.item.hasThumbnail == rhs.item.hasThumbnail
            && lhs.ordinal == rhs.ordinal
            && lhs.selected == rhs.selected
            && lhs.highlightQuery == rhs.highlightQuery
            && lhs.imageMaxHeight == rhs.imageMaxHeight
            && (lhs.thumbnail === rhs.thumbnail)
            && (lhs.appIcon === rhs.appIcon)
            && (lhs.fileIcon === rhs.fileIcon)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            leading
            titleText
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13))
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            if let ordinal {
                Text("⌘\(ordinal)")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 25)
        .padding(.vertical, item.kind == .image ? 3 : 0)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.accentColor : .clear)
                .padding(.horizontal, 6)
        )
    }

    private var titleText: Text {
        let trimmed = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let range = item.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            return Text(item.title)
        }
        var attr = AttributedString(item.title)
        if let attrRange = Range(range, in: attr) {
            attr[attrRange].inlinePresentationIntent = .stronglyEmphasized
            if !selected {
                attr[attrRange].foregroundColor = .accentColor
            } else {
                attr[attrRange].underlineStyle = .single
            }
        }
        return Text(attr)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: CGFloat(imageMaxHeight))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        case .color:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(cssColor: item.color ?? "") ?? .gray))
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
        case .files:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        case .link:
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
        case .text:
            EmptyView()
        }
    }
}

extension NSColor {
    /// Parses `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(...)`, `rgba(...)`,
    /// `hsl(...)`, and `hsla(...)` CSS color values emitted by `clipper-core`.
    convenience init?(cssColor raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard let v = UInt64(hex, radix: 16) else { return nil }
            let r, g, b, a: CGFloat
            switch hex.count {
            case 3:
                r = CGFloat((v >> 8) & 0xF) / 15
                g = CGFloat((v >> 4) & 0xF) / 15
                b = CGFloat(v & 0xF) / 15
                a = 1
            case 4:
                r = CGFloat((v >> 12) & 0xF) / 15
                g = CGFloat((v >> 8) & 0xF) / 15
                b = CGFloat((v >> 4) & 0xF) / 15
                a = CGFloat(v & 0xF) / 15
            case 6:
                r = CGFloat((v >> 16) & 0xFF) / 255
                g = CGFloat((v >> 8) & 0xFF) / 255
                b = CGFloat(v & 0xFF) / 255
                a = 1
            case 8:
                r = CGFloat((v >> 24) & 0xFF) / 255
                g = CGFloat((v >> 16) & 0xFF) / 255
                b = CGFloat((v >> 8) & 0xFF) / 255
                a = CGFloat(v & 0xFF) / 255
            default:
                return nil
            }
            self.init(srgbRed: r, green: g, blue: b, alpha: a)
            return
        }

        if (s.hasPrefix("rgb(") || s.hasPrefix("rgba(")), s.hasSuffix(")"),
           let open = s.firstIndex(of: "(") {
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            let parts = inner.split { $0 == "," || $0 == " " || $0 == "/" }.map(String.init)
            guard parts.count >= 3 else { return nil }
            func channel(_ str: String) -> CGFloat? {
                if str.hasSuffix("%"), let p = Double(str.dropLast()) { return CGFloat(p / 100.0) }
                guard let v = Double(str) else { return nil }
                return CGFloat(v / 255.0)
            }
            func alpha(_ str: String) -> CGFloat? {
                if str.hasSuffix("%"), let p = Double(str.dropLast()) { return CGFloat(p / 100.0) }
                guard let v = Double(str) else { return nil }
                return CGFloat(v)
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            let a = parts.count >= 4 ? (alpha(parts[3]) ?? 1.0) : 1.0
            self.init(srgbRed: r, green: g, blue: b, alpha: a)
            return
        }

        if (s.hasPrefix("hsl(") || s.hasPrefix("hsla(")), s.hasSuffix(")"),
           let open = s.firstIndex(of: "(") {
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            let parts = inner.split { $0 == "," || $0 == " " || $0 == "/" }.map(String.init)
            guard parts.count >= 3 else { return nil }
            let hStr = parts[0].replacingOccurrences(of: "deg", with: "")
            guard let hDeg = Double(hStr),
                  let sPct = Double(parts[1].replacingOccurrences(of: "%", with: "")),
                  let lPct = Double(parts[2].replacingOccurrences(of: "%", with: ""))
            else { return nil }
            let a: CGFloat
            if parts.count >= 4 {
                let aStr = parts[3]
                if aStr.hasSuffix("%"), let p = Double(aStr.dropLast()) { a = CGFloat(p / 100.0) }
                else { a = CGFloat(Double(aStr) ?? 1.0) }
            } else {
                a = 1.0
            }
            let h = ((hDeg.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360.0
            let sat = max(0, min(1, sPct / 100.0))
            let lig = max(0, min(1, lPct / 100.0))
            let c = (1.0 - abs(2.0 * lig - 1.0)) * sat
            let x = c * (1.0 - abs((h * 6.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
            let m = lig - c / 2.0
            let (r1, g1, b1): (Double, Double, Double) = switch h * 6.0 {
            case ..<1: (c, x, 0)
            case ..<2: (x, c, 0)
            case ..<3: (0, c, x)
            case ..<4: (0, x, c)
            case ..<5: (x, 0, c)
            default:   (c, 0, x)
            }
            self.init(srgbRed: CGFloat(r1 + m), green: CGFloat(g1 + m), blue: CGFloat(b1 + m), alpha: a)
            return
        }

        return nil
    }
}
