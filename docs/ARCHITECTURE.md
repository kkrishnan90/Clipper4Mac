# Architecture

```
┌────────────────────────────── Clipper.app ──────────────────────────────┐
│  Swift / AppKit / SwiftUI  (macos/Sources/Clipper)                      │
│                                                                         │
│  NSStatusItem ─┐   KeyboardShortcuts (⇧⌘V)                              │
│                ├──▶ FloatingPanel (non-activating NSPanel, .screenSaver) │
│  ⌥/right-click ┘        └─ NSHostingView ▸ ContentView (SwiftUI)        │
│                              search · rows · footer · preview popover   │
│                                                                         │
│  ClipboardWatcher ── every 500 ms: NSPasteboard.changeCount             │
│     reads *all* flavours of *all* items ──▶ Snapshot ─┐                 │
│  Paster ◀── PasteContent (all flavours back) ─────────┼── CGEvent ⌘V    │
│                                                       │                 │
│ ═════════════════ UniFFI (generated ClipperCore.swift) ═════════════════ │
│                                                       ▼                 │
│  Rust  crates/clipper-ffi  (#[uniffi::export] façade, static lib)       │
│        crates/clipper-core (engine)                                     │
│           ingest · history · store (redb) · blob (BLAKE3 CAS) · thumbs  │
│                                                                         │
│  ~/Library/Application Support/Clipper/                                 │
│     ├─ history.redb          index, copy-on-write, ACID                 │
│     └─ blobs/ab/<blake3>     every pasteboard flavour, verbatim         │
└─────────────────────────────────────────────────────────────────────────┘
```

Clipper is what Maccy is – a status-item app with a floating panel, built
from AppKit/SwiftUI controls – with the storage engine replaced by Rust.
No web view, no Electron, no custom chrome.

## Swift shell (`macos/`)

| File | Responsibility |
| --- | --- |
| `main.swift` | Plain `NSApplication` entry; registers defaults before anything reads them. |
| `AppDelegate.swift` | Status item (template SF Symbol), right-click menu, panel lifecycle, global hotkey, local key monitors, Preferences window, About panel, launch-at-login (`SMAppService`), clear-on-quit. |
| `Panel/FloatingPanel.swift` | Maccy's panel verbatim in behaviour: `.nonactivatingPanel`, `level = .screenSaver`, `.moveToActiveSpace`, closes on `resignKey`, highlights the status button, animated vertical resize. |
| `Panel/PopupPosition.swift` | Cursor / status item / active window / centre / last position. |
| `Services/ClipboardWatcher.swift` | Polls `changeCount`; captures **every** `NSPasteboardItem.types` flavour with `data(forType:)`, flattened across items; honours `org.nspasteboard.*` concealed/transient markers and the ignore list; skips Clipper's own writes. |
| `Services/Paster.swift` | Writes all flavours back with `setData(_:forType:)` (file URLs via `writeObjects`, one item each), then posts ⌘V through `CGEvent` on the session tap. Keycode is resolved for the active layout with `UCKeyTranslate`. |
| `Services/CoreService.swift` | Owns the UniFFI `Clipper` object. Reads on the main actor (sub-ms, in-memory index); `ingest` on a utility queue. Publishes a `revision` counter for SwiftUI. |
| `HistoryModel.swift` | Items, query, selection, keyboard chords (↑↓, ⏎, ⌥⏎ plain, ⇧⏎ copy-only, ⌘1–9, ⌥P, ⌥⌫, ⌥⌘⌫ clear, ⌘, , ⌘Q, esc). |
| `Views/*` | `ContentView` (vibrancy + search + list + footer), `HistoryRow` (22 pt), `FooterView`, `PreviewView` (application, first/last copy, count, size, formats), `SettingsView` (General / Appearance / Storage / Ignore). |

## Rust engine (`crates/`)

### `clipper-ffi` – the FFI façade

`uniffi::setup_scaffolding!` + `#[uniffi::export]`. One object, `Clipper`,
plus plain records (`ItemSummary`, `Snapshot`, `PasteContent`, `StoragePolicy`,
…) and a flat `ClipperError`. `cargo run -p uniffi-bindgen` turns the built
library into `ClipperCore.swift` + `ClipperCoreFFI.h`; SwiftPM links the
static library from `macos/Libs/`.

### `clipper-core` – platform-independent, unit-tested (41 tests)

| Module | Responsibility |
| --- | --- |
| `ingest` | `Snapshot { flavors: [RawFlavor { uti, data }] }` → `Item`. Derives kind/title/thumbnail (files › image › colour › link › text), then **stores every flavour verbatim**. Copies with only private flavours are kept as opaque items. Concealed/transient snapshots are dropped. |
| `history` | Façade with one `parking_lot::Mutex` around the in-memory index; blob I/O outside the lock. Dedup by content hash bumps `copyCount` and refreshes the stored flavours. `paste_content(id, plain)` returns all flavours in original order (plain mode: UTF-8 + file URLs only). Cap enforcement never evicts pinned items. |
| `store` | redb tables `items_v1`, `hashes_v1`, `meta_v1`. `open_or_recover` quarantines an unreadable file instead of crashing. |
| `blob` | Content-addressed payloads, `tmp → fsync → rename`. |
| `thumbs` | PNG thumbnails ≤ 320 px; TIFF→PNG transcode for previews. |
| `search` | Case/diacritic-insensitive substring + subsequence scoring over title, source and file names. |

## Fidelity guarantee

"Paste exactly what was copied" is implemented by never interpreting the
clipboard: the watcher stores each flavour's bytes, and `Paster` puts the
same bytes back under the same UTIs in the same order. Markdown from an
editor comes back as the same `public.utf8-plain-text`; a table from
Numbers comes back with its `public.html`, `public.rtf` and private
`com.apple.iWork.*` flavours; a Finder selection comes back as file URLs.
The only user-controlled exception is "Paste without formatting" (⌥⏎),
which sends plain text and file URLs only.

## Reliability design (requirement #5)

1. **No SQLite.** redb is a single-file copy-on-write B-tree with shadow
   paging; commits are atomic at the OS level. No WAL to lose, no journal to
   replay.
2. **Payloads outside the index.** Values are immutable files named by their
   BLAKE3 hash; the index stays small.
3. **Defensive load.** Each row is deserialised individually; a bad row is
   deleted and logged. Items whose blob vanished are dropped; orphans swept.
4. **Recovery, not crash loops.** An unopenable DB is renamed aside.
5. **Bounded memory.** In-memory state is summaries + small thumbnails, capped
   by `maxItems`. Images above `maxImageMb` are skipped.

## Threading

- Main actor: AppKit, SwiftUI, all engine reads (`list`, `detail`, `thumbnail`).
- `ingest` queue (utility QoS): image decode + thumbnail + blob write.
- Rust `History` is `Send + Sync`; a single mutex guards the index, held only
  for in-memory work.
