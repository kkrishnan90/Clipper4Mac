//! UniFFI surface of Clipper's Rust engine, consumed by the Swift app in
//! `macos/`.
//!
//! Division of labour:
//! * **Swift** owns everything platform-specific – `NSPasteboard` polling,
//!   the menu-bar item, the panel, keyboard handling, user preferences in
//!   `UserDefaults`, Accessibility/paste.
//! * **Rust** (this crate + `clipper-core`) owns storage, de-duplication,
//!   eviction, search and thumbnailing. It is handed raw pasteboard snapshots
//!   and a [`StoragePolicy`], and hands back plain records.
//!
//! Every method on [`Clipper`] is thread-safe; the Swift side calls `ingest`
//! from a background queue and the read methods from the main actor.

#![deny(unsafe_op_in_unsafe_fn)]
#![warn(missing_debug_implementations)]

uniffi::setup_scaffolding!("clipper_core");

use clipper_core::{self as core, History};
use parking_lot::RwLock;
use std::path::PathBuf;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors crossing the FFI boundary. Flattened to a message per variant so
/// Swift can show them without knowing the Rust internals.
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ClipperError {
    #[error("I/O error: {0}")]
    Io(String),
    #[error("storage error: {0}")]
    Storage(String),
    #[error("item not found")]
    NotFound(String),
    #[error("{0}")]
    Other(String),
}

impl From<core::CoreError> for ClipperError {
    fn from(e: core::CoreError) -> Self {
        match e {
            core::CoreError::Io(e) => ClipperError::Io(e.to_string()),
            core::CoreError::Db(m) | core::CoreError::BlobMissing(m) => ClipperError::Storage(m),
            core::CoreError::NotFound(id) => ClipperError::NotFound(id.to_string()),
            core::CoreError::Serde(e) => ClipperError::Other(e.to_string()),
            core::CoreError::Image(m) | core::CoreError::Other(m) => ClipperError::Other(m),
        }
    }
}

type FfiResult<T> = std::result::Result<T, ClipperError>;

// ---------------------------------------------------------------------------
// Records & enums (mirrors of clipper-core types with FFI-friendly shapes)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ItemKind {
    Text,
    Link,
    Color,
    Image,
    Files,
}

impl From<core::ItemKind> for ItemKind {
    fn from(k: core::ItemKind) -> Self {
        match k {
            core::ItemKind::Text => ItemKind::Text,
            core::ItemKind::Link => ItemKind::Link,
            core::ItemKind::Color => ItemKind::Color,
            core::ItemKind::Image => ItemKind::Image,
            core::ItemKind::Files => ItemKind::Files,
        }
    }
}

impl From<ItemKind> for core::ItemKind {
    fn from(k: ItemKind) -> Self {
        match k {
            ItemKind::Text => core::ItemKind::Text,
            ItemKind::Link => core::ItemKind::Link,
            ItemKind::Color => core::ItemKind::Color,
            ItemKind::Image => core::ItemKind::Image,
            ItemKind::Files => core::ItemKind::Files,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
    Document,
    Archive,
    Code,
    Folder,
    Other,
}

impl From<core::MediaKind> for MediaKind {
    fn from(m: core::MediaKind) -> Self {
        match m {
            core::MediaKind::Image => MediaKind::Image,
            core::MediaKind::Video => MediaKind::Video,
            core::MediaKind::Audio => MediaKind::Audio,
            core::MediaKind::Document => MediaKind::Document,
            core::MediaKind::Archive => MediaKind::Archive,
            core::MediaKind::Code => MediaKind::Code,
            core::MediaKind::Folder => MediaKind::Folder,
            core::MediaKind::Other => MediaKind::Other,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub media: MediaKind,
    pub size: Option<u64>,
}

impl From<core::FileEntry> for FileEntry {
    fn from(f: core::FileEntry) -> Self {
        FileEntry {
            path: f.path,
            name: f.name,
            media: f.media.into(),
            size: f.size,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SourceApp {
    pub name: String,
    pub bundle_id: Option<String>,
}

impl From<core::SourceApp> for SourceApp {
    fn from(s: core::SourceApp) -> Self {
        SourceApp {
            name: s.name,
            bundle_id: s.bundle_id,
        }
    }
}

impl From<SourceApp> for core::SourceApp {
    fn from(s: SourceApp) -> Self {
        core::SourceApp {
            name: s.name,
            bundle_id: s.bundle_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImageMeta {
    pub width: u32,
    pub height: u32,
    /// `png`, `tiff`, `jpeg`, …
    pub format: String,
}

impl From<core::ImageMeta> for ImageMeta {
    fn from(m: core::ImageMeta) -> Self {
        ImageMeta {
            width: m.width,
            height: m.height,
            format: m.format,
        }
    }
}

/// One row of the history list. Never carries payload bytes; ask for
/// [`Clipper::thumbnail`], [`Clipper::detail`] or [`Clipper::paste_content`].
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemSummary {
    pub id: u64,
    pub kind: ItemKind,
    pub title: String,
    pub has_thumbnail: bool,
    pub image: Option<ImageMeta>,
    pub files: Vec<FileEntry>,
    /// Normalised `#rrggbb` when `kind == Color`.
    pub color: Option<String>,
    pub byte_size: u64,
    pub char_count: Option<u32>,
    pub source: Option<SourceApp>,
    /// Unix milliseconds.
    pub first_copied_at: i64,
    pub last_copied_at: i64,
    pub copy_count: u32,
    pub pinned: bool,
    /// UTIs of every stored flavour, in pasteboard order.
    pub flavors: Vec<String>,
}

impl From<core::ItemSummary> for ItemSummary {
    fn from(s: core::ItemSummary) -> Self {
        ItemSummary {
            id: s.id,
            kind: s.kind.into(),
            title: s.title,
            has_thumbnail: s.thumbnail.is_some(),
            image: s.image.map(Into::into),
            files: s.files.into_iter().map(Into::into).collect(),
            color: s.color,
            byte_size: s.byte_size,
            char_count: s.char_count,
            source: s.source.map(Into::into),
            first_copied_at: s.first_copied_at,
            last_copied_at: s.last_copied_at,
            copy_count: s.copy_count,
            pinned: s.pinned,
            flavors: s.flavors,
        }
    }
}

/// Summary plus a bounded text body for the preview.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemDetail {
    pub summary: ItemSummary,
    pub text: Option<String>,
    pub text_truncated: bool,
}

/// Full-size image bytes for the preview.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImageData {
    pub bytes: Vec<u8>,
    /// `png`, `tiff`, `jpeg`, …
    pub format: String,
}

/// One pasteboard flavour exactly as read with `NSPasteboardItem.data(forType:)`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Flavor {
    /// `NSPasteboard.PasteboardType.rawValue`, e.g. `public.utf8-plain-text`.
    pub uti: String,
    pub data: Vec<u8>,
}

impl From<Flavor> for core::RawFlavor {
    fn from(f: Flavor) -> Self {
        core::RawFlavor {
            uti: f.uti,
            data: f.data,
        }
    }
}

impl From<core::RawFlavor> for Flavor {
    fn from(f: core::RawFlavor) -> Self {
        Flavor {
            uti: f.uti,
            data: f.data,
        }
    }
}

/// Everything on the pasteboard at one `changeCount`: every flavour of every
/// pasteboard item, flattened in order. Stored verbatim; nothing is
/// normalised, so a paste reproduces the original copy byte-for-byte.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct Snapshot {
    pub flavors: Vec<Flavor>,
    pub source: Option<SourceApp>,
    /// `org.nspasteboard.ConcealedType` was present (password managers).
    pub concealed: bool,
    /// `org.nspasteboard.TransientType` / auto-generated content.
    pub transient: bool,
}

impl From<Snapshot> for core::Snapshot {
    fn from(s: Snapshot) -> Self {
        core::Snapshot {
            flavors: s.flavors.into_iter().map(Into::into).collect(),
            source: s.source.map(Into::into),
            concealed: s.concealed,
            transient: s.transient,
        }
    }
}

/// What to write back to the pasteboard: the captured flavours, unchanged,
/// in their original order. Swift calls `setData(_:forType:)` for each and
/// `writeObjects` for `public.file-url` entries.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct PasteContent {
    pub kind: Option<ItemKind>,
    pub flavors: Vec<Flavor>,
}

impl From<core::PasteContent> for PasteContent {
    fn from(p: core::PasteContent) -> Self {
        PasteContent {
            kind: p.kind.map(Into::into),
            flavors: p.flavors.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ListQuery {
    /// Free-text query; empty returns everything. Matching is
    /// case-insensitive on title and body.
    pub query: String,
    pub kind: Option<ItemKind>,
    pub pinned_only: bool,
    pub offset: u32,
    /// `0` means no limit.
    pub limit: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ListResult {
    pub items: Vec<ItemSummary>,
    pub total: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryStats {
    pub items: u32,
    pub pinned: u32,
    pub db_bytes: u64,
    pub blob_bytes: u64,
    pub data_dir: String,
}

impl From<core::HistoryStats> for HistoryStats {
    fn from(s: core::HistoryStats) -> Self {
        HistoryStats {
            items: s.items as u32,
            pinned: s.pinned as u32,
            db_bytes: s.db_bytes,
            blob_bytes: s.blob_bytes,
            data_dir: s.data_dir,
        }
    }
}

/// The subset of preferences the engine needs. All other preferences live in
/// `UserDefaults` on the Swift side.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StoragePolicy {
    /// Maximum number of unpinned items to keep (10…10 000).
    pub max_items: u32,
    pub store_images: bool,
    pub store_files: bool,
    /// Keep HTML/RTF flavours alongside plain text.
    pub keep_rich_text: bool,
    /// Skip images larger than this many MiB.
    pub max_image_mb: u32,
}

impl Default for StoragePolicy {
    fn default() -> Self {
        let s = core::Settings::default();
        StoragePolicy {
            max_items: s.max_items,
            store_images: s.store_images,
            store_files: s.store_files,
            keep_rich_text: s.keep_rich_text,
            max_image_mb: s.max_image_mb,
        }
    }
}

impl StoragePolicy {
    fn to_settings(&self) -> core::Settings {
        core::Settings {
            max_items: self.max_items,
            store_images: self.store_images,
            store_files: self.store_files,
            keep_rich_text: self.keep_rich_text,
            max_image_mb: self.max_image_mb,
            ..core::Settings::default()
        }
        .sanitised()
    }

    fn from_settings(s: &core::Settings) -> Self {
        StoragePolicy {
            max_items: s.max_items,
            store_images: s.store_images,
            store_files: s.store_files,
            keep_rich_text: s.keep_rich_text,
            max_image_mb: s.max_image_mb,
        }
    }
}

/// Default storage policy (used by Swift to seed `UserDefaults`).
#[uniffi::export]
pub fn default_storage_policy() -> StoragePolicy {
    StoragePolicy::default()
}

/// Engine version, for the About panel.
#[uniffi::export]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Route Rust `log` output to the unified logging system. Idempotent.
#[uniffi::export]
pub fn init_logging(subsystem: String, verbose: bool) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let level = if verbose {
            log::LevelFilter::Debug
        } else {
            log::LevelFilter::Info
        };
        #[cfg(feature = "oslog")]
        {
            let _ = oslog::OsLogger::new(&subsystem).level_filter(level).init();
        }
        #[cfg(not(feature = "oslog"))]
        {
            let _ = subsystem;
            log::set_max_level(level);
        }
    });
}

// ---------------------------------------------------------------------------
// The engine object
// ---------------------------------------------------------------------------

/// Handle to one history database. Cheap to clone on the Swift side (it is an
/// `Arc`); create exactly one per data directory.
#[derive(uniffi::Object)]
pub struct Clipper {
    history: History,
    policy: RwLock<StoragePolicy>,
    data_dir: PathBuf,
}

impl std::fmt::Debug for Clipper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Clipper")
            .field("data_dir", &self.data_dir)
            .finish()
    }
}

#[uniffi::export]
impl Clipper {
    /// Opens (or creates) the database under `data_dir`. Self-heals corrupt
    /// records and drops entries whose blobs disappeared; never refuses to
    /// start because of bad data.
    #[uniffi::constructor]
    pub fn open(data_dir: String, policy: StoragePolicy) -> FfiResult<Arc<Self>> {
        let dir = PathBuf::from(data_dir);
        let settings = policy.to_settings();
        let history = History::open(&dir, &settings)?;
        log::info!("clipper engine opened at {}", dir.display());
        Ok(Arc::new(Clipper {
            history,
            policy: RwLock::new(StoragePolicy::from_settings(&settings)),
            data_dir: dir,
        }))
    }

    pub fn data_dir(&self) -> String {
        self.data_dir.to_string_lossy().into_owned()
    }

    pub fn storage_policy(&self) -> StoragePolicy {
        self.policy.read().clone()
    }

    /// Applies a new policy (clamped to sane ranges) and evicts immediately if
    /// the cap shrank. Returns the policy as applied.
    pub fn set_storage_policy(&self, policy: StoragePolicy) -> FfiResult<StoragePolicy> {
        let settings = policy.to_settings();
        self.history.apply_settings(&settings)?;
        let applied = StoragePolicy::from_settings(&settings);
        *self.policy.write() = applied.clone();
        Ok(applied)
    }

    /// Records a pasteboard snapshot. Returns the new (or refreshed, when it
    /// de-duplicated against an existing entry) item, or `None` when nothing
    /// was stored (empty, concealed, transient, or filtered by policy).
    pub fn ingest(&self, snapshot: Snapshot) -> FfiResult<Option<ItemSummary>> {
        Ok(self.history.ingest(snapshot.into())?.map(Into::into))
    }

    pub fn list(&self, query: ListQuery) -> FfiResult<ListResult> {
        let res = self.history.list(&core::ListQuery {
            query: query.query,
            kind: query.kind.map(Into::into),
            pinned_only: query.pinned_only,
            offset: query.offset as usize,
            limit: query.limit as usize,
        });
        Ok(ListResult {
            items: res.items.into_iter().map(Into::into).collect(),
            total: res.total as u32,
        })
    }

    pub fn summary(&self, id: u64) -> FfiResult<ItemSummary> {
        Ok(self.history.summary(id)?.into())
    }

    /// Summary plus up to `max_text_bytes` of the text body.
    pub fn detail(&self, id: u64, max_text_bytes: u32) -> FfiResult<ItemDetail> {
        let d = self.history.detail(id, max_text_bytes as usize, false)?;
        Ok(ItemDetail {
            summary: d.summary.into(),
            text: d.text,
            text_truncated: d.text_truncated,
        })
    }

    /// PNG thumbnail bytes for the row, if any.
    pub fn thumbnail(&self, id: u64) -> FfiResult<Option<Vec<u8>>> {
        Ok(self.history.thumbnail_png(id)?)
    }

    /// Full-size image for the preview (image items only).
    pub fn image(&self, id: u64) -> FfiResult<Option<ImageData>> {
        Ok(self
            .history
            .image_bytes(id)?
            .map(|(bytes, format)| ImageData { bytes, format }))
    }

    /// Everything needed to write the item to the pasteboard. With
    /// `plain_text_only`, rich flavours are omitted.
    pub fn paste_content(&self, id: u64, plain_text_only: bool) -> FfiResult<PasteContent> {
        Ok(self.history.paste_content(id, plain_text_only)?.into())
    }

    /// Marks the item as just used: bumps its counter and moves it to the top.
    pub fn touch(&self, id: u64) -> FfiResult<ItemSummary> {
        Ok(self.history.touch(id)?.into())
    }

    pub fn set_pinned(&self, id: u64, pinned: bool) -> FfiResult<ItemSummary> {
        Ok(self.history.set_pinned(id, pinned)?.into())
    }

    pub fn delete(&self, id: u64) -> FfiResult<()> {
        Ok(self.history.delete(id)?)
    }

    /// Removes every item (or every unpinned item). Returns how many went.
    pub fn clear(&self, keep_pinned: bool) -> FfiResult<u32> {
        Ok(self.history.clear(keep_pinned)? as u32)
    }

    pub fn stats(&self) -> HistoryStats {
        self.history.stats().into()
    }

    /// Compacts the database file and removes orphaned blobs.
    pub fn compact(&self) -> FfiResult<()> {
        Ok(self.history.compact()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_tmp() -> (tempfile::TempDir, Arc<Clipper>) {
        let dir = tempfile::tempdir().unwrap();
        let c = Clipper::open(
            dir.path().to_string_lossy().into_owned(),
            StoragePolicy::default(),
        )
        .unwrap();
        (dir, c)
    }

    const UTF8: &str = "public.utf8-plain-text";

    fn text_snapshot(s: &str) -> Snapshot {
        Snapshot {
            flavors: vec![Flavor {
                uti: UTF8.into(),
                data: s.as_bytes().to_vec(),
            }],
            source: Some(SourceApp {
                name: "Test".into(),
                bundle_id: Some("com.example.test".into()),
            }),
            ..Default::default()
        }
    }

    #[test]
    fn ingest_list_paste_roundtrip() {
        let (_d, c) = open_tmp();
        let item = c.ingest(text_snapshot("hello world")).unwrap().unwrap();
        assert_eq!(item.kind, ItemKind::Text);
        assert_eq!(item.title, "hello world");
        assert!(!item.has_thumbnail);

        let list = c.list(ListQuery::default()).unwrap();
        assert_eq!(list.total, 1);
        assert_eq!(list.items[0].id, item.id);

        let paste = c.paste_content(item.id, false).unwrap();
        assert_eq!(paste.kind, Some(ItemKind::Text));
        assert_eq!(paste.flavors.len(), 1);
        assert_eq!(paste.flavors[0].uti, UTF8);
        assert_eq!(paste.flavors[0].data, b"hello world");
    }

    #[test]
    fn dedup_bumps_copy_count() {
        let (_d, c) = open_tmp();
        let a = c.ingest(text_snapshot("dup")).unwrap().unwrap();
        let b = c.ingest(text_snapshot("dup")).unwrap().unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(b.copy_count, 2);
        assert_eq!(c.list(ListQuery::default()).unwrap().total, 1);
    }

    #[test]
    fn concealed_is_dropped() {
        let (_d, c) = open_tmp();
        let mut s = text_snapshot("secret");
        s.concealed = true;
        assert!(c.ingest(s).unwrap().is_none());
    }

    #[test]
    fn search_pin_delete_clear() {
        let (_d, c) = open_tmp();
        let a = c.ingest(text_snapshot("alpha bravo")).unwrap().unwrap();
        let b = c.ingest(text_snapshot("charlie")).unwrap().unwrap();

        let hits = c
            .list(ListQuery {
                query: "bravo".into(),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(hits.items.len(), 1);
        assert_eq!(hits.items[0].id, a.id);

        let pinned = c.set_pinned(a.id, true).unwrap();
        assert!(pinned.pinned);
        // Pinned items sort first even though `b` is newer.
        assert_eq!(c.list(ListQuery::default()).unwrap().items[0].id, a.id);

        c.delete(b.id).unwrap();
        assert!(matches!(c.summary(b.id), Err(ClipperError::NotFound(_))));

        assert_eq!(c.clear(true).unwrap(), 0);
        assert_eq!(c.clear(false).unwrap(), 1);
        assert_eq!(c.stats().items, 0);
    }

    #[test]
    fn policy_is_clamped_and_applied() {
        let (_d, c) = open_tmp();
        let applied = c
            .set_storage_policy(StoragePolicy {
                max_items: 1,
                ..StoragePolicy::default()
            })
            .unwrap();
        assert_eq!(applied.max_items, 10);
        assert_eq!(c.storage_policy().max_items, 10);
    }

    #[test]
    fn image_roundtrip_has_thumbnail() {
        let (_d, c) = open_tmp();
        // 2×2 red PNG.
        let mut png = Vec::new();
        {
            use std::io::Cursor;
            let img = image::RgbaImage::from_pixel(2, 2, image::Rgba([255, 0, 0, 255]));
            img.write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
                .unwrap();
        }
        let item = c
            .ingest(Snapshot {
                flavors: vec![Flavor {
                    uti: "public.png".into(),
                    data: png.clone(),
                }],
                ..Default::default()
            })
            .unwrap()
            .unwrap();
        assert_eq!(item.kind, ItemKind::Image);
        assert!(item.has_thumbnail);
        assert!(c.thumbnail(item.id).unwrap().is_some());
        let img = c.image(item.id).unwrap().unwrap();
        assert_eq!(img.format, "png");
        assert_eq!(img.bytes, png);
        let paste = c.paste_content(item.id, false).unwrap();
        assert_eq!(paste.flavors[0].uti, "public.png");
        assert_eq!(paste.flavors[0].data, png);
    }

    #[test]
    fn markdown_and_private_flavors_roundtrip_exactly() {
        let (_d, c) = open_tmp();
        let md = "## Heading\n\n1. *a*\n2. **b**\n\n| x | y |\n|---|---|\n";
        let snap = Snapshot {
            flavors: vec![
                Flavor {
                    uti: UTF8.into(),
                    data: md.as_bytes().to_vec(),
                },
                Flavor {
                    uti: "public.html".into(),
                    data: b"<h2>Heading</h2>".to_vec(),
                },
                Flavor {
                    uti: "com.example.editor".into(),
                    data: vec![0, 1, 2, 3],
                },
            ],
            ..Default::default()
        };
        let item = c.ingest(snap.clone()).unwrap().unwrap();
        assert_eq!(
            item.flavors,
            vec![
                "public.utf8-plain-text",
                "public.html",
                "com.example.editor"
            ]
        );
        let paste = c.paste_content(item.id, false).unwrap();
        assert_eq!(paste.flavors, snap.flavors);
        let plain = c.paste_content(item.id, true).unwrap();
        assert_eq!(plain.flavors.len(), 1);
        assert_eq!(plain.flavors[0].data, md.as_bytes());
    }
}
