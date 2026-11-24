import AppKit
import ClipperCore
import ImageIO
import Observation
import os

/// Owns the Rust engine handle, in-memory image/icon caches, and publishes
/// history changes to SwiftUI.
@MainActor
@Observable
final class CoreService {
    nonisolated static let bundleId = "com.kkrishnan90.clipper"
    /// Password managers that predate the nspasteboard.org markers.
    static let knownSecretApps: Set<String> = [
        "com.agilebits.onepassword7", "com.1password.1password", "com.apple.keychainaccess",
    ]

    nonisolated let engine: Clipper?
    let startupError: String?
    /// Bumped on every mutation; views observe it to reload when visible.
    private(set) var revision = 0
    private(set) var lastIngested: ItemSummary?

    nonisolated private let ioQueue = DispatchQueue(label: "\(CoreService.bundleId).io", qos: .utility)
    nonisolated private let log = Logger(subsystem: CoreService.bundleId, category: "core")

    // Caches eliminate synchronous UniFFI + PNG decode + LaunchServices IPC
    // inside `HistoryRow.body` on every selection/hover tick.
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.countLimit = 250
        return c
    }()
    private let appIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 150
        return c
    }()
    private let fileIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 150
        return c
    }()

    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipper", isDirectory: true)
    }()

    init() {
        initLogging(subsystem: CoreService.bundleId, verbose: false)
        do {
            let opened = try Clipper.open(
                dataDir: CoreService.dataDirectory.path,
                policy: CoreService.policyFromDefaults()
            )
            engine = opened
            startupError = nil
            // Sweep orphaned blobs off the main thread shortly after launch.
            ioQueue.asyncAfter(deadline: .now() + 2.0) {
                opened.sweepOrphans()
            }
        } catch {
            engine = nil
            startupError = "\(error)"
            Logger(subsystem: CoreService.bundleId, category: "core")
                .error("engine failed to open: \(String(describing: error))")
        }
    }

    // MARK: Storage policy

    static func policyFromDefaults() -> StoragePolicy {
        let d = UserDefaults.standard
        return StoragePolicy(
            maxItems: UInt32(clamping: d.integer(forKey: PrefKey.maxItems)),
            storeImages: d.bool(forKey: PrefKey.storeImages),
            storeFiles: d.bool(forKey: PrefKey.storeFiles),
            keepRichText: d.bool(forKey: PrefKey.keepRichText),
            maxImageMb: UInt32(clamping: d.integer(forKey: PrefKey.maxImageMB))
        )
    }

    /// Re-reads the policy keys from `UserDefaults` and pushes them to Rust.
    func applyPolicyFromDefaults() {
        guard let engine else { return }
        do {
            let applied = try engine.setStoragePolicy(policy: CoreService.policyFromDefaults())
            let d = UserDefaults.standard
            d.set(Int(applied.maxItems), forKey: PrefKey.maxItems)
            d.set(Int(applied.maxImageMb), forKey: PrefKey.maxImageMB)
            bump()
        } catch {
            log.error("setStoragePolicy failed: \(String(describing: error))")
        }
    }

    // MARK: Ingest

    nonisolated func ingest(_ snapshot: Snapshot) {
        ioQueue.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                if let item = try engine.ingest(snapshot: snapshot) {
                    Task { @MainActor in
                        self.thumbnailCache.removeObject(forKey: NSNumber(value: item.id))
                        self.lastIngested = item
                        self.bump()
                    }
                }
            } catch {
                self.log.error("ingest failed: \(String(describing: error))")
            }
        }
    }

    // MARK: Reads & Caches

    func list(query: String, kind: ItemKind? = nil, pinnedOnly: Bool = false, limit: UInt32 = 300) -> [ItemSummary] {
        guard let engine else { return [] }
        let q = ListQuery(query: query, kind: kind, pinnedOnly: pinnedOnly, offset: 0, limit: limit)
        return (try? engine.list(query: q).items) ?? []
    }

    func detail(_ id: UInt64, maxTextBytes: UInt32 = 64 * 1024) -> ItemDetail? {
        try? engine?.detail(id: id, maxTextBytes: maxTextBytes)
    }

    /// Loads item text detail off the main thread for `PreviewView`.
    func loadDetailAsync(_ id: UInt64, maxTextBytes: UInt32 = 64 * 1024) async -> ItemDetail? {
        guard let engine else { return nil }
        return await withCheckedContinuation { cont in
            ioQueue.async {
                cont.resume(returning: try? engine.detail(id: id, maxTextBytes: maxTextBytes))
            }
        }
    }

    /// Cached list thumbnail. Only hits UniFFI + PNG decode once per item.
    func thumbnail(_ id: UInt64) -> NSImage? {
        let key = NSNumber(value: id)
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let engine, let data = try? engine.thumbnail(id: id), let img = NSImage(data: data) else {
            return nil
        }
        thumbnailCache.setObject(img, forKey: key)
        return img
    }

    /// Cached application icon for a bundle identifier (avoids LaunchServices IPC in `body`).
    func appIcon(forBundleId bundleId: String) -> NSImage? {
        let key = bundleId as NSString
        if let cached = appIconCache.object(forKey: key) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        appIconCache.setObject(icon, forKey: key)
        return icon
    }

    /// Cached file icon (avoids IconServices/filesystem IPC in `body`).
    func fileIcon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = fileIconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        fileIconCache.setObject(icon, forKey: key)
        return icon
    }

    /// Loads and downsamples an image off the main thread for `PreviewView`,
    /// avoiding 50–100 MB RGBA bitmap allocations on MainActor.
    func loadPreviewImageAsync(_ id: UInt64, maxPixelSize: Int = 960) async -> NSImage? {
        guard let engine else { return nil }
        return await withCheckedContinuation { cont in
            ioQueue.async {
                guard let imgData = try? engine.image(id: id) else {
                    cont.resume(returning: nil)
                    return
                }
                let nsData = imgData.bytes as CFData
                if let src = CGImageSourceCreateWithData(nsData, nil) {
                    let opts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    ]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                        cont.resume(returning: NSImage(cgImage: cg, size: .zero))
                        return
                    }
                }
                cont.resume(returning: NSImage(data: imgData.bytes))
            }
        }
    }

    func pasteContent(_ id: UInt64, plainTextOnly: Bool) -> PasteContent? {
        try? engine?.pasteContent(id: id, plainTextOnly: plainTextOnly)
    }

    func stats() -> HistoryStats? { engine?.stats() }

    // MARK: Mutations

    /// Records usage asynchronously so dismissing the panel and pasting never
    /// waits on a synchronous `redb` fsync or triggers a pre-close UI jump.
    func touchAsync(_ id: UInt64) {
        guard let engine else { return }
        ioQueue.async { [weak self] in
            _ = try? engine.touch(id: id)
            Task { @MainActor [weak self] in
                self?.bump()
            }
        }
    }

    func setPinned(_ id: UInt64, _ pinned: Bool) {
        _ = try? engine?.setPinned(id: id, pinned: pinned)
        bump()
    }

    func delete(_ id: UInt64) {
        thumbnailCache.removeObject(forKey: NSNumber(value: id))
        try? engine?.delete(id: id)
        bump()
    }

    @discardableResult
    func undoDelete() -> ItemSummary? {
        guard let restored = try? engine?.undoDelete() else { return nil }
        bump()
        return restored
    }

    @discardableResult
    func clear(keepPinned: Bool) -> Int {
        thumbnailCache.removeAllObjects()
        let n = (try? engine?.clear(keepPinned: keepPinned)) ?? 0
        bump()
        return Int(n)
    }

    func compact() {
        try? engine?.compact()
        bump()
    }

    private func bump() { revision &+= 1 }
}
