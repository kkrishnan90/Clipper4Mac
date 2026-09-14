import AppKit
import ClipperCore
import SwiftUI

/// Footer rows exactly like Maccy's: Clear ⌥⌘⌫ (Clear all with ⇧ held),
/// Preferences… ⌘, · About · Quit ⌘Q.
struct FooterView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            FooterRow(
                title: model.shiftDown ? "Clear all" : "Clear",
                shortcut: model.shiftDown ? "⇧⌥⌘⌫" : "⌥⌘⌫"
            ) {
                model.clear(all: model.shiftDown)
            }
            FooterRow(title: "Preferences…", shortcut: "⌘,") {
                model.dismiss?()
                AppDelegate.shared?.openPreferences()
            }
            FooterRow(title: "About", shortcut: nil) {
                model.dismiss?()
                AppDelegate.shared?.showAbout()
            }
            FooterRow(title: "Quit", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FooterRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(hovering ? .white.opacity(0.85) : .secondary)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(hovering ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.accentColor : .clear)
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// The "look deeper" popover: content preview plus the metadata Maccy shows.
struct PreviewView: View {
    let item: ItemSummary
    let core: CoreService

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
                .frame(maxWidth: 480, maxHeight: 320, alignment: .topLeading)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let source = item.source {
                    GridRow {
                        Text("Application:").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if let bundle = source.bundleId,
                               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 14, height: 14)
                            }
                            Text(source.name)
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
                    Text("Number of copies:").foregroundStyle(.secondary)
                    Text("\(item.copyCount)")
                }
                GridRow {
                    Text("Size:").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                }
                if !item.flavors.isEmpty {
                    GridRow(alignment: .top) {
                        Text("Formats:").foregroundStyle(.secondary)
                        Text(item.flavors.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
            Text("Press ⏎ to paste, ⌥⏎ for plain text, ⇧⏎ to copy only.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let img = core.image(item.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("Image").foregroundStyle(.secondary)
            }
        case .files:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.files, id: \.path) { f in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16)
                        Text(f.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        case .color:
            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: NSColor(hex: item.color ?? "") ?? .gray))
                    .frame(width: 48, height: 48)
                Text(item.title).font(.system(size: 13, design: .monospaced))
            }
        case .text, .link:
            ScrollView {
                Text(core.detail(item.id, maxTextBytes: 64 * 1024)?.text ?? item.title)
                    .font(.system(size: 12, design: item.kind == .text ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
