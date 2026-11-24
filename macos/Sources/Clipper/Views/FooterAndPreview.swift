import AppKit
import ClipperCore
import SwiftUI

/// Footer rows matching Maccy: Clear ⌥⌘⌫ (Clear all with ⇧ held),
/// Preferences… ⌘, · About · Quit ⌘Q, plus live modifier feedback when ⌥/⇧ held.
struct FooterView: View {
    @Bindable var model: HistoryModel
    @AppStorage(PrefKey.pasteOnSelect) private var pasteOnSelect = true
    @AppStorage(PrefKey.pastePlainByDefault) private var pastePlainByDefault = false

    var body: some View {
        VStack(spacing: 0) {
            if model.optionDown || model.shiftDown {
                HStack(spacing: 6) {
                    Image(systemName: "command")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                    Text(modifierHintText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.08))
            }

            FooterRow(
                title: model.shiftDown ? "Clear all" : "Clear",
                shortcut: model.shiftDown ? "⇧⌥⌘⌫" : "⌥⌘⌫",
                isHovered: model.hoveredFooter == .clear,
                onHover: { model.handleFooterHover(.clear, inside: $0) }
            ) {
                model.clear(all: model.shiftDown)
            }
            FooterRow(
                title: "Preferences…",
                shortcut: "⌘,",
                isHovered: model.hoveredFooter == .preferences,
                onHover: { model.handleFooterHover(.preferences, inside: $0) }
            ) {
                model.dismiss?(false)
                AppDelegate.shared?.openPreferences()
            }
            FooterRow(
                title: "About",
                shortcut: nil,
                isHovered: model.hoveredFooter == .about,
                onHover: { model.handleFooterHover(.about, inside: $0) }
            ) {
                model.dismiss?(false)
                AppDelegate.shared?.showAbout()
            }
            FooterRow(
                title: "Quit",
                shortcut: "⌘Q",
                isHovered: model.hoveredFooter == .quit,
                onHover: { model.handleFooterHover(.quit, inside: $0) }
            ) {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    private var modifierHintText: String {
        let willPaste = model.shiftDown ? !pasteOnSelect : pasteOnSelect
        let willPlain = model.optionDown ? !pastePlainByDefault : pastePlainByDefault
        switch (willPaste, willPlain) {
        case (true, true): return "⏎ Paste as plain text"
        case (true, false): return "⏎ Paste with formatting"
        case (false, true): return "⏎ Copy plain text only"
        case (false, false): return "⏎ Copy only (no paste)"
        }
    }
}

private struct FooterRow: View {
    let title: String
    let shortcut: String?
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(isHovered ? .white.opacity(0.85) : .secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isHovered ? .white : .primary)
        .padding(.horizontal, 12)
        .frame(height: 23)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.accentColor : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: action)
    }
}

/// Asynchronous content preview hosted inside the non-activating `PreviewPanel`.
/// Loads large text and downsampled images off MainActor via `.task(id:)` so
/// scrolling or hovering across heavy clips never drops frames.
struct PreviewView: View {
    let item: ItemSummary
    let core: CoreService

    @State private var loadedDetail: ItemDetail?
    @State private var loadedImage: NSImage?
    @State private var isLoading = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .frame(maxWidth: .infinity, maxHeight: 210, alignment: .topLeading)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if let source = item.source {
                    GridRow {
                        Text("Application:").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if let bundle = source.bundleId,
                               let icon = core.appIcon(forBundleId: bundle) {
                                Image(nsImage: icon)
                                    .resizable().frame(width: 14, height: 14)
                            }
                            Text(source.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                GridRow {
                    Text("First copy:").foregroundStyle(.secondary)
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(item.firstCopiedAt) / 1000)))
                }
                GridRow {
                    Text("Last copy:").foregroundStyle(.secondary)
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(item.lastCopiedAt) / 1000)))
                }
                GridRow {
                    Text("Copies:").foregroundStyle(.secondary)
                    Text("\(item.copyCount)")
                }
                GridRow {
                    Text("Size:").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                }
                if !item.flavors.isEmpty {
                    GridRow(alignment: .top) {
                        Text("Formats:").foregroundStyle(.secondary)
                        Text(item.flavors.prefix(4).joined(separator: "\n") + (item.flavors.count > 4 ? "\n+\(item.flavors.count - 4) more" : ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
            Text("⏎ paste · ⌥⏎ plain text · ⇧⏎ copy only · ⌘Y/Space preview")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .task(id: item.id) {
            loadedDetail = nil
            loadedImage = nil
            isLoading = true
            switch item.kind {
            case .image:
                let img = await core.loadPreviewImageAsync(item.id, maxPixelSize: 960)
                if !Task.isCancelled { loadedImage = img }
            case .text, .link:
                let detail = await core.loadDetailAsync(item.id, maxTextBytes: 64 * 1024)
                if !Task.isCancelled { loadedDetail = detail }
            case .files, .color:
                break
            }
            if !Task.isCancelled { isLoading = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let img = loadedImage ?? core.thumbnail(item.id) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 200, alignment: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Image").foregroundStyle(.secondary)
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.files, id: \.path) { f in
                        HStack(spacing: 6) {
                            Image(nsImage: core.fileIcon(forPath: f.path))
                                .resizable().frame(width: 16, height: 16)
                            Text(f.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .color:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: NSColor(cssColor: item.color ?? "") ?? .gray))
                    .frame(width: 48, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(item.title).font(.system(size: 13, design: .monospaced))
            }
        case .text, .link:
            VStack(alignment: .leading, spacing: 4) {
                ScrollView {
                    Text(loadedDetail?.text ?? item.title)
                        .font(.system(size: 11.5, design: item.kind == .text ? .monospaced : .default))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if loadedDetail?.textTruncated == true {
                    Text("Preview truncated at 64 KB — full content will be pasted.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
