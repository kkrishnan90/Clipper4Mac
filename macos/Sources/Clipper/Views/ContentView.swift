import AppKit
import ClipperCore
import SwiftUI

/// The popup's content: vibrancy background → search → list → footer.
struct ContentView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.showSearch) private var showSearch = true
    @AppStorage(PrefKey.showFooter) private var showFooter = true

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                SearchFieldView(text: $model.query)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider()
            }
            HistoryListView(model: model)
            if showFooter {
                Divider()
                FooterView(model: model)
            }
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .onChange(of: model.core.revision) { _, _ in model.reloadIfStale() }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .ignoresSafeArea()
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

/// Plain text field that takes focus when the popup opens; arrow keys and
/// Enter are intercepted by the panel's key monitor so they never move the
/// insertion point.
struct SearchFieldView: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { focused = true }
            if !text.isEmpty {
                Button {
                    text = ""
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

struct HistoryListView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.showPreview) private var showPreview = true
    @AppStorage(PrefKey.previewDelayMs) private var previewDelayMs = 1500

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let pinnedEnd = model.items.lastIndex(where: \.pinned) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                            if index == pinnedEnd { Divider().padding(.horizontal, 10) }
                        }
                    } else {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                        }
                    }
                    if model.items.isEmpty {
                        Text(model.query.isEmpty ? "No clipboard history yet" : "No matches")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedId) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ItemSummary, index: Int) -> some View {
        HistoryRow(
            item: item,
            ordinal: index < 9 ? index + 1 : nil,
            selected: item.id == model.selectedId,
            thumbnail: item.hasThumbnail ? model.core.thumbnail(item.id) : nil
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture { model.activate(item.id, modifiers: NSApp.currentEvent?.modifierFlags ?? []) }
        .onHover { inside in
            if inside {
                model.selectedId = item.id
                schedulePreview(for: item.id)
            } else if model.previewedId == item.id {
                model.previewedId = nil
            }
        }
        .popover(isPresented: previewBinding(for: item.id), arrowEdge: .trailing) {
            PreviewView(item: item, core: model.core)
        }
        .contextMenu {
            Button("Paste") { model.activate(item.id) }
            Button("Paste as Plain Text") { model.activate(item.id, modifiers: .option) }
            Button("Copy Only") { model.activate(item.id, modifiers: .shift) }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item.id) }
            Button("Delete", role: .destructive) { model.delete(item.id) }
        }
    }

    private func previewBinding(for id: UInt64) -> Binding<Bool> {
        Binding(
            get: { model.previewedId == id },
            set: { if !$0, model.previewedId == id { model.previewedId = nil } }
        )
    }

    private func schedulePreview(for id: UInt64) {
        guard showPreview else { return }
        let delay = Double(max(0, previewDelayMs)) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if model.selectedId == id, model.dismiss != nil {
                model.previewedId = id
            }
        }
    }
}

/// One 22-pt row: icon/thumbnail/swatch · title · ⌘n hint.
struct HistoryRow: View {
    let item: ItemSummary
    let ordinal: Int?
    let selected: Bool
    let thumbnail: NSImage?
    @AppStorage(PrefKey.showApplicationIcons) private var showAppIcons = false
    @AppStorage(PrefKey.imageMaxHeight) private var imageMaxHeight = 40

    var body: some View {
        HStack(spacing: 8) {
            if showAppIcons, let bundle = item.source?.bundleId,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            leading
            Text(item.title)
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
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(minHeight: 22)
        .padding(.vertical, item.kind == .image ? 3 : 0)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.accentColor : .clear)
                .padding(.horizontal, 5)
        )
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
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        case .color:
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(hex: item.color ?? "") ?? .gray))
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
        case .files:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if let first = item.files.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
        case .link:
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.secondary)
        case .text:
            EmptyView()
        }
    }
}

extension NSColor {
    /// Parses `#rgb`, `#rrggbb`, `#rrggbbaa` (what the engine normalises to).
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            (r, g, b, a) = (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, 1)
        case 8:
            (r, g, b, a) = (
                CGFloat((v >> 24) & 0xFF) / 255, CGFloat((v >> 16) & 0xFF) / 255,
                CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255
            )
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
