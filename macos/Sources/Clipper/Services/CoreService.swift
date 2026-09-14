import AppKit
import ClipperCore
import Observation
import os

/// Owns the Rust engine handle and publishes history changes to SwiftUI.
///
/// Reads run on the main actor (they are sub-millisecond: the engine keeps an
/// in-memory index). `ingest` – which may decode a large image to build a
/// thumbnail – runs on a background queue.
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
    /// Bumped on every mutation; views observe it to reload.
    private(set) var revision = 0
    private(set) var lastIngested: ItemSummary?

    nonisolated private let ingestQueue = DispatchQueue(label: "\(CoreService.bundleId).ingest", qos: .utility)
    nonisolated private let log = Logger(subsystem: CoreService.bundleId, category: "core")

    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipper", isDirectory: true)
    }()

    init() {
        initLogging(subsystem: CoreService.bundleId, verbose: false)
        do {
            engine = try Clipper.open(
                dataDir: CoreService.dataDirectory.path,
                policy: CoreService.policyFromDefaults()
            )
            startupError = nil
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
            // Write back the clamped values so the UI shows what is in force.
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
        ingestQueue.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                if let item = try engine.ingest(snapshot: snapshot) {
                    Task { @MainActor in
                        self.lastIngested = item
                        self.bump()
                    }
                }
            } catch {
                self.log.error("ingest failed: \(String(describing: error))")
            }
        }
    }

    // MARK: Reads

    func list(query: String, kind: ItemKind? = nil, pinnedOnly: Bool = false, limit: UInt32 = 0) -> [ItemSummary] {
        guard let engine else { return [] }
        let q = ListQuery(query: query, kind: kind, pinnedOnly: pinnedOnly, offset: 0, limit: limit)
        return (try? engine.list(query: q).items) ?? []
    }

    func detail(_ id: UInt64, maxTextBytes: UInt32 = 200_000) -> ItemDetail? {
        try? engine?.detail(id: id, maxTextBytes: maxTextBytes)
    }

    func thumbnail(_ id: UInt64) -> NSImage? {
        guard let engine, let data = try? engine.thumbnail(id: id) else { return nil }
        return NSImage(data: data)
    }

    func image(_ id: UInt64) -> NSImage? {
        guard let engine, let img = try? engine.image(id: id) else { return nil }
        return NSImage(data: img.bytes)
    }

    func pasteContent(_ id: UInt64, plainTextOnly: Bool) -> PasteContent? {
        try? engine?.pasteContent(id: id, plainTextOnly: plainTextOnly)
    }

    func stats() -> HistoryStats? { engine?.stats() }

    // MARK: Mutations

    func touch(_ id: UInt64) {
        _ = try? engine?.touch(id: id)
        bump()
    }

    func setPinned(_ id: UInt64, _ pinned: Bool) {
        _ = try? engine?.setPinned(id: id, pinned: pinned)
        bump()
    }

    func delete(_ id: UInt64) {
        try? engine?.delete(id: id)
        bump()
    }

    @discardableResult
    func clear(keepPinned: Bool) -> Int {
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
