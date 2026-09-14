//! The facade the application talks to. Owns the in-memory index (sorted:
//! pinned first, then most-recent first), the [`Store`] and the [`BlobStore`].
//!
//! All methods take `&self`; a single mutex guards the index so the clipboard
//! watcher thread and the UI thread can share one `Arc<History>`.

use crate::blob::BlobStore;
use crate::ingest::{
    self, IngestOptions, RawFlavor, Snapshot, UTI_FILE_URL, UTI_PNG, UTI_TIFF, UTI_UTF8,
};
use crate::model::*;
use crate::search;
use crate::settings::Settings;
use crate::store::Store;
use crate::{CoreError, Result};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub struct History {
    inner: Mutex<Inner>,
    blobs: BlobStore,
    data_dir: PathBuf,
}

struct Inner {
    store: Store,
    items: Vec<Item>,
    by_hash: HashMap<String, u64>,
    max_items: u32,
    opts: IngestOptions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ListQuery {
    pub query: String,
    pub kind: Option<ItemKind>,
    pub pinned_only: bool,
    pub offset: usize,
    /// `0` means "no limit".
    pub limit: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListResult {
    pub items: Vec<ItemSummary>,
    pub total: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryStats {
    pub items: usize,
    pub pinned: usize,
    pub db_bytes: u64,
    pub blob_bytes: u64,
    pub data_dir: String,
}

/// Everything needed to write an item back to the pasteboard: the captured
/// flavours, byte-for-byte, in pasteboard order.
#[derive(Debug, Clone, Default)]
pub struct PasteContent {
    pub kind: Option<ItemKind>,
    pub flavors: Vec<RawFlavor>,
}

impl PasteContent {
    pub fn first(&self, uti: &str) -> Option<&[u8]> {
        self.flavors
            .iter()
            .find(|f| f.uti == uti)
            .map(|f| f.data.as_slice())
    }

    pub fn plain_text(&self) -> Option<String> {
        self.first(UTI_UTF8)
            .map(|b| String::from_utf8_lossy(b).into_owned())
    }
}

/// `/Users/me/My File.txt` → `file:///Users/me/My%20File.txt`
pub fn path_to_file_url(path: &str) -> String {
    let mut out = String::from("file://");
    for b in path.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"-._~/!$&'()*+,;=:@".contains(&b);
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn sort_items(items: &mut [Item]) {
    items.sort_by(|a, b| {
        b.pinned
            .cmp(&a.pinned)
            .then(b.last_copied_at.cmp(&a.last_copied_at))
            .then(b.id.cmp(&a.id))
    });
}

impl History {
    pub fn open(data_dir: &Path, settings: &Settings) -> Result<History> {
        std::fs::create_dir_all(data_dir)?;
        let blobs = BlobStore::open(data_dir.join("blobs"))?;
        let store = Store::open_or_recover(data_dir.join("history.redb"))?;
        let report = store.load_all()?;
        if report.dropped_corrupt > 0 {
            log::warn!(
                "self-healed {} unreadable history records",
                report.dropped_corrupt
            );
        }

        // Drop records whose blobs went missing (e.g. user deleted the folder).
        let mut items = Vec::with_capacity(report.items.len());
        let mut missing = Vec::new();
        for it in report.items {
            if it.blob_hashes().all(|h| blobs.exists(h)) {
                items.push(it);
            } else {
                missing.push(it.id);
            }
        }
        if !missing.is_empty() {
            log::warn!("dropping {} records with missing blobs", missing.len());
            store.delete_many(&missing)?;
        }
        sort_items(&mut items);

        let by_hash = items.iter().map(|i| (i.hash.clone(), i.id)).collect();
        let mut inner = Inner {
            store,
            items,
            by_hash,
            max_items: settings.max_items,
            opts: settings.ingest_options(),
        };
        let evicted = inner.enforce_cap()?;
        let h = History {
            inner: Mutex::new(inner),
            blobs,
            data_dir: data_dir.to_path_buf(),
        };
        h.remove_orphan_blobs_for(&evicted);
        h.sweep_orphan_blobs();
        Ok(h)
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn apply_settings(&self, settings: &Settings) -> Result<()> {
        let evicted = {
            let mut g = self.inner.lock();
            g.max_items = settings.max_items;
            g.opts = settings.ingest_options();
            g.enforce_cap()?
        };
        self.remove_orphan_blobs_for(&evicted);
        Ok(())
    }

    /// Records a new clipboard snapshot. Returns the (new or refreshed) item.
    pub fn ingest(&self, snap: Snapshot) -> Result<Option<ItemSummary>> {
        let opts = self.inner.lock().opts.clone();
        let Some(mut item) = ingest::build_item(snap, &self.blobs, &opts)? else {
            return Ok(None);
        };

        let evicted;
        let summary;
        {
            let mut g = self.inner.lock();
            if let Some(&existing_id) = g.by_hash.get(&item.hash) {
                // Same content copied again: bump instead of duplicating, but
                // adopt the *new* flavours so a paste reproduces the latest
                // copy exactly (the same text copied from another app may
                // carry different rich representations).
                if let Some(pos) = g.items.iter().position(|i| i.id == existing_id) {
                    let ex = &mut g.items[pos];
                    let mut stale = Item {
                        id: 0,
                        representations: std::mem::take(&mut ex.representations),
                        ..ex.clone()
                    };
                    ex.last_copied_at = item.last_copied_at;
                    ex.copy_count = ex.copy_count.saturating_add(1);
                    ex.representations = std::mem::take(&mut item.representations);
                    ex.byte_size = item.byte_size;
                    if item.source.is_some() {
                        ex.source = item.source.take();
                    }
                    let snapshot = ex.clone();
                    g.store.put(&snapshot)?;
                    sort_items(&mut g.items);
                    drop(g);
                    // Old flavours' blobs may now be unreferenced.
                    stale.payload = PayloadRef::Inline { data: Vec::new() };
                    self.remove_orphan_blobs_for(std::slice::from_ref(&stale));
                    return Ok(Some(ItemSummary::from(&snapshot)));
                }
            }
            item.id = g.store.next_id()?;
            g.store.put(&item)?;
            g.by_hash.insert(item.hash.clone(), item.id);
            summary = ItemSummary::from(&item);
            g.items.push(item);
            sort_items(&mut g.items);
            evicted = g.enforce_cap()?;
        }
        self.remove_orphan_blobs_for(&evicted);
        Ok(Some(summary))
    }

    pub fn list(&self, q: &ListQuery) -> ListResult {
        let g = self.inner.lock();
        let query = q.query.trim();
        let mut scored: Vec<(i32, &Item)> = g
            .items
            .iter()
            .filter(|i| q.kind.map_or(true, |k| i.kind == k))
            .filter(|i| !q.pinned_only || i.pinned)
            .filter_map(|i| {
                if query.is_empty() {
                    return Some((0, i));
                }
                let body = inline_text(i);
                search::score(query, &search::haystack(i, body)).map(|s| (s, i))
            })
            .collect();
        if !query.is_empty() {
            scored.sort_by(|a, b| {
                b.0.cmp(&a.0)
                    .then(b.1.last_copied_at.cmp(&a.1.last_copied_at))
            });
        }
        let total = scored.len();
        let iter = scored.into_iter().skip(q.offset);
        let items: Vec<ItemSummary> = if q.limit > 0 {
            iter.take(q.limit)
                .map(|(_, i)| ItemSummary::from(i))
                .collect()
        } else {
            iter.map(|(_, i)| ItemSummary::from(i)).collect()
        };
        ListResult { items, total }
    }

    pub fn summary(&self, id: u64) -> Result<ItemSummary> {
        let g = self.inner.lock();
        g.find(id).map(ItemSummary::from)
    }

    /// Detail for the preview pane. Text is truncated at `max_text_bytes`
    /// (on a char boundary); full image is included only when `with_image`.
    pub fn detail(&self, id: u64, max_text_bytes: usize, with_image: bool) -> Result<ItemDetail> {
        let item = {
            let g = self.inner.lock();
            g.find(id)?.clone()
        };
        let summary = ItemSummary::from(&item);
        let mut text = None;
        let mut truncated = false;
        let mut image_data_url = None;
        match item.kind {
            ItemKind::Text | ItemKind::Link | ItemKind::Color | ItemKind::Files => {
                let bytes = self.payload_bytes(&item.payload)?;
                let s = String::from_utf8_lossy(&bytes);
                if s.len() > max_text_bytes {
                    let mut cut = max_text_bytes;
                    while cut > 0 && !s.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    text = Some(s[..cut].to_string());
                    truncated = true;
                } else {
                    text = Some(s.into_owned());
                }
            }
            ItemKind::Image => {
                if with_image {
                    use base64::Engine;
                    let bytes = self.payload_bytes(&item.payload)?;
                    let mime = match item.image.as_ref().map(|m| m.format.as_str()) {
                        Some("tiff") => "image/tiff",
                        Some("jpeg") => "image/jpeg",
                        Some("gif") => "image/gif",
                        Some("webp") => "image/webp",
                        _ => "image/png",
                    };
                    image_data_url = Some(format!(
                        "data:{mime};base64,{}",
                        base64::engine::general_purpose::STANDARD.encode(bytes)
                    ));
                }
            }
        }
        Ok(ItemDetail {
            summary,
            text,
            text_truncated: truncated,
            image_data_url,
        })
    }

    /// Raw PNG bytes of the list thumbnail, if the item has one.
    pub fn thumbnail_png(&self, id: u64) -> Result<Option<Vec<u8>>> {
        let g = self.inner.lock();
        Ok(g.find(id)?.thumbnail.clone())
    }

    /// Full-size image bytes plus their format (`png`, `tiff`, …) for image
    /// items; `None` for everything else.
    pub fn image_bytes(&self, id: u64) -> Result<Option<(Vec<u8>, String)>> {
        let item = {
            let g = self.inner.lock();
            g.find(id)?.clone()
        };
        if item.kind != ItemKind::Image {
            return Ok(None);
        }
        let bytes = self.payload_bytes(&item.payload)?;
        let format = item
            .image
            .as_ref()
            .map(|m| m.format.clone())
            .unwrap_or_else(|| "png".to_string());
        Ok(Some((bytes, format)))
    }

    /// Loads every flavour of the item, byte-for-byte as captured, in the
    /// original pasteboard order. With `plain_text_only` the rich flavours
    /// are dropped (⌥⏎ "paste without formatting").
    pub fn paste_content(&self, id: u64, plain_text_only: bool) -> Result<PasteContent> {
        let item = {
            let g = self.inner.lock();
            g.find(id)?.clone()
        };
        let mut flavors = Vec::with_capacity(item.representations.len() + 1);
        for rep in &item.representations {
            let keep = !plain_text_only || matches!(rep.uti.as_str(), UTI_UTF8 | UTI_FILE_URL);
            if keep {
                flavors.push(RawFlavor {
                    uti: rep.uti.clone(),
                    data: self.payload_bytes(&rep.payload)?,
                });
            }
        }

        // Records that carry no essential flavour (older schema, or
        // `keep_rich_text` filtering) are reconstructed from the primary
        // payload so they always paste.
        let has = |u: &str| flavors.iter().any(|f| f.uti == u);
        match item.kind {
            ItemKind::Image if !has(UTI_PNG) && !has(UTI_TIFF) => {
                let bytes = self.payload_bytes(&item.payload)?;
                let uti = match item.image.as_ref().map(|m| m.format.as_str()) {
                    Some("tiff") => UTI_TIFF,
                    Some("jpeg") => ingest::UTI_JPEG,
                    _ => UTI_PNG,
                };
                flavors.insert(0, RawFlavor::new(uti, bytes));
            }
            ItemKind::Files if !has(UTI_FILE_URL) => {
                for f in &item.files {
                    flavors.push(RawFlavor::new(UTI_FILE_URL, path_to_file_url(&f.path)));
                }
            }
            ItemKind::Text | ItemKind::Link | ItemKind::Color if !has(UTI_UTF8) => {
                let bytes = self.payload_bytes(&item.payload)?;
                flavors.insert(0, RawFlavor::new(UTI_UTF8, bytes));
            }
            _ => {}
        }

        Ok(PasteContent {
            kind: Some(item.kind),
            flavors,
        })
    }

    /// Marks the item as just-used: moves it to the top and bumps the counter.
    pub fn touch(&self, id: u64) -> Result<ItemSummary> {
        let mut g = self.inner.lock();
        let pos = g
            .items
            .iter()
            .position(|i| i.id == id)
            .ok_or(CoreError::NotFound(id))?;
        g.items[pos].last_copied_at = crate::now_ms();
        g.items[pos].copy_count = g.items[pos].copy_count.saturating_add(1);
        let snapshot = g.items[pos].clone();
        g.store.put(&snapshot)?;
        sort_items(&mut g.items);
        Ok(ItemSummary::from(&snapshot))
    }

    pub fn set_pinned(&self, id: u64, pinned: bool) -> Result<ItemSummary> {
        let evicted;
        let summary;
        {
            let mut g = self.inner.lock();
            let pos = g
                .items
                .iter()
                .position(|i| i.id == id)
                .ok_or(CoreError::NotFound(id))?;
            g.items[pos].pinned = pinned;
            let snapshot = g.items[pos].clone();
            g.store.put(&snapshot)?;
            sort_items(&mut g.items);
            summary = ItemSummary::from(&snapshot);
            evicted = g.enforce_cap()?;
        }
        self.remove_orphan_blobs_for(&evicted);
        Ok(summary)
    }

    pub fn delete(&self, id: u64) -> Result<()> {
        let removed = {
            let mut g = self.inner.lock();
            let pos = g
                .items
                .iter()
                .position(|i| i.id == id)
                .ok_or(CoreError::NotFound(id))?;
            let it = g.items.remove(pos);
            g.by_hash.remove(&it.hash);
            g.store.delete(id)?;
            it
        };
        self.remove_orphan_blobs_for(&[removed]);
        Ok(())
    }

    /// Removes all (or all unpinned) items. Returns how many were removed.
    pub fn clear(&self, keep_pinned: bool) -> Result<usize> {
        let removed = {
            let mut g = self.inner.lock();
            let (keep, drop): (Vec<Item>, Vec<Item>) = std::mem::take(&mut g.items)
                .into_iter()
                .partition(|i| keep_pinned && i.pinned);
            g.items = keep;
            g.by_hash = g.items.iter().map(|i| (i.hash.clone(), i.id)).collect();
            let ids: Vec<u64> = drop.iter().map(|i| i.id).collect();
            g.store.delete_many(&ids)?;
            drop
        };
        let n = removed.len();
        self.remove_orphan_blobs_for(&removed);
        Ok(n)
    }

    pub fn stats(&self) -> HistoryStats {
        let g = self.inner.lock();
        HistoryStats {
            items: g.items.len(),
            pinned: g.items.iter().filter(|i| i.pinned).count(),
            db_bytes: g.store.file_size(),
            blob_bytes: self.blobs.disk_usage(),
            data_dir: self.data_dir.display().to_string(),
        }
    }

    /// Reclaims database space and deletes orphaned blobs.
    pub fn compact(&self) -> Result<()> {
        {
            let mut g = self.inner.lock();
            g.store.compact()?;
        }
        self.sweep_orphan_blobs();
        Ok(())
    }

    // ----- internals -------------------------------------------------------

    fn payload_bytes(&self, p: &PayloadRef) -> Result<Vec<u8>> {
        match p {
            PayloadRef::Inline { data } => Ok(data.clone()),
            PayloadRef::Blob { hash, .. } => self.blobs.get(hash),
        }
    }

    /// Deletes blobs referenced by `gone` unless another live item still uses them.
    fn remove_orphan_blobs_for(&self, gone: &[Item]) {
        if gone.is_empty() {
            return;
        }
        let live: HashSet<String> = {
            let g = self.inner.lock();
            g.items
                .iter()
                .flat_map(|i| i.blob_hashes().map(str::to_string))
                .collect()
        };
        for it in gone {
            for h in it.blob_hashes() {
                if !live.contains(h) {
                    if let Err(e) = self.blobs.remove(h) {
                        log::warn!("failed to remove blob {h}: {e}");
                    }
                }
            }
        }
    }

    fn sweep_orphan_blobs(&self) {
        let live: HashSet<String> = {
            let g = self.inner.lock();
            g.items
                .iter()
                .flat_map(|i| i.blob_hashes().map(str::to_string))
                .collect()
        };
        match self.blobs.sweep(|h| live.contains(h)) {
            Ok(0) => {}
            Ok(n) => log::info!("swept {n} orphaned blobs"),
            Err(e) => log::warn!("blob sweep failed: {e}"),
        }
    }
}

impl Inner {
    fn find(&self, id: u64) -> Result<&Item> {
        self.items
            .iter()
            .find(|i| i.id == id)
            .ok_or(CoreError::NotFound(id))
    }

    /// Evicts the oldest unpinned items beyond `max_items`. Returns them so
    /// the caller can clean up blobs outside the lock.
    fn enforce_cap(&mut self) -> Result<Vec<Item>> {
        let unpinned = self.items.iter().filter(|i| !i.pinned).count();
        let over = unpinned.saturating_sub(self.max_items as usize);
        if over == 0 {
            return Ok(Vec::new());
        }
        // Items are sorted newest-first; the oldest unpinned are at the tail.
        let mut victims = Vec::with_capacity(over);
        let mut idx = self.items.len();
        while victims.len() < over && idx > 0 {
            idx -= 1;
            if !self.items[idx].pinned {
                victims.push(self.items.remove(idx));
            }
        }
        let ids: Vec<u64> = victims.iter().map(|i| i.id).collect();
        for v in &victims {
            self.by_hash.remove(&v.hash);
        }
        self.store.delete_many(&ids)?;
        Ok(victims)
    }
}

/// Text body for search when the payload is stored inline (cheap; no I/O).
fn inline_text(item: &Item) -> Option<&str> {
    match (&item.kind, &item.payload) {
        (ItemKind::Image, _) => None,
        (_, PayloadRef::Inline { data }) => std::str::from_utf8(data).ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_snap(t: &str) -> Snapshot {
        Snapshot::text(t)
    }

    fn open(dir: &Path, max: u32) -> History {
        let s = Settings {
            max_items: max,
            ..Default::default()
        };
        History::open(dir, &s).unwrap()
    }

    #[test]
    fn ingest_list_dedup_and_order() {
        let dir = tempfile::tempdir().unwrap();
        let h = open(dir.path(), 100);
        h.ingest(text_snap("one")).unwrap().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        h.ingest(text_snap("two")).unwrap().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let again = h.ingest(text_snap("one")).unwrap().unwrap();
        assert_eq!(again.copy_count, 2);

        let r = h.list(&ListQuery::default());
        assert_eq!(r.total, 2);
        assert_eq!(r.items[0].title, "one", "re-copied item moves to the top");
        assert_eq!(r.items[1].title, "two");
    }

    #[test]
    fn search_filters_and_ranks() {
        let dir = tempfile::tempdir().unwrap();
        let h = open(dir.path(), 100);
        for t in [
            "https://github.com/kkrishnan90/Clipper4Mac",
            "Interview with Jagjyot",
            "kotak bank",
        ] {
            h.ingest(text_snap(t)).unwrap();
        }
        let r = h.list(&ListQuery {
            query: "github".into(),
            ..Default::default()
        });
        assert_eq!(r.total, 1);
        assert_eq!(r.items[0].kind, ItemKind::Link);
        let r = h.list(&ListQuery {
            kind: Some(ItemKind::Link),
            ..Default::default()
        });
        assert_eq!(r.total, 1);
        let r = h.list(&ListQuery {
            query: "zzz".into(),
            ..Default::default()
        });
        assert_eq!(r.total, 0);
    }

    #[test]
    fn cap_evicts_oldest_unpinned_and_persists() {
        let dir = tempfile::tempdir().unwrap();
        {
            let h = open(dir.path(), 10);
            let first = h.ingest(text_snap("keep me")).unwrap().unwrap();
            h.set_pinned(first.id, true).unwrap();
            for i in 0..15 {
                std::thread::sleep(std::time::Duration::from_millis(1));
                h.ingest(text_snap(&format!("item {i}"))).unwrap();
            }
            let r = h.list(&ListQuery::default());
            assert_eq!(r.total, 11, "10 unpinned + 1 pinned");
            assert!(r.items[0].pinned);
            assert_eq!(r.items[0].title, "keep me");
        }
        // Reopen: state survives.
        let h = open(dir.path(), 10);
        let r = h.list(&ListQuery::default());
        assert_eq!(r.total, 11);
        assert_eq!(h.stats().pinned, 1);
    }

    #[test]
    fn delete_clear_and_blob_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let h = open(dir.path(), 100);
        let big = h.ingest(text_snap(&"y".repeat(200_000))).unwrap().unwrap();
        let small = h.ingest(text_snap("small")).unwrap().unwrap();
        assert!(h.stats().blob_bytes >= 200_000);
        h.delete(big.id).unwrap();
        assert_eq!(h.stats().blob_bytes, 0, "orphaned blob removed");
        h.set_pinned(small.id, true).unwrap();
        h.ingest(text_snap("gone")).unwrap();
        assert_eq!(h.clear(true).unwrap(), 1);
        assert_eq!(h.list(&ListQuery::default()).total, 1);
        assert_eq!(h.clear(false).unwrap(), 1);
        assert_eq!(h.list(&ListQuery::default()).total, 0);
    }

    #[test]
    fn detail_and_paste_content() {
        let dir = tempfile::tempdir().unwrap();
        let h = open(dir.path(), 100);
        let snap = Snapshot::text("Hi").with(ingest::UTI_HTML, "<b>Hi</b>");
        let s = h.ingest(snap).unwrap().unwrap();
        let d = h.detail(s.id, 1024, false).unwrap();
        assert_eq!(d.text.as_deref(), Some("Hi"));
        assert!(!d.text_truncated);
        let p = h.paste_content(s.id, false).unwrap();
        assert_eq!(p.plain_text().as_deref(), Some("Hi"));
        assert_eq!(p.first(ingest::UTI_HTML), Some(&b"<b>Hi</b>"[..]));
        let p = h.paste_content(s.id, true).unwrap();
        assert!(p.first(ingest::UTI_HTML).is_none());
        assert_eq!(p.plain_text().as_deref(), Some("Hi"));
        let touched = h.touch(s.id).unwrap();
        assert_eq!(touched.copy_count, 2);
        assert!(matches!(
            h.detail(9999, 10, false),
            Err(CoreError::NotFound(9999))
        ));
    }

    #[test]
    fn paste_is_byte_exact_and_dedup_refreshes_flavors() {
        let dir = tempfile::tempdir().unwrap();
        let h = open(dir.path(), 100);
        let md = "# Notes\r\n\r\n* one\t\n* two  \n\n```sh\necho hi\n```\n";
        let a = h
            .ingest(Snapshot::text(md).with(ingest::UTI_HTML, "<h1>Notes</h1>"))
            .unwrap()
            .unwrap();
        let p = h.paste_content(a.id, false).unwrap();
        assert_eq!(p.first(ingest::UTI_UTF8), Some(md.as_bytes()));
        assert_eq!(p.flavors.len(), 2);

        // Same text again from another app with RTF instead of HTML.
        let b = h
            .ingest(Snapshot::text(md).with(ingest::UTI_RTF, b"{\\rtf1 Notes}".to_vec()))
            .unwrap()
            .unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(b.copy_count, 2);
        let p = h.paste_content(b.id, false).unwrap();
        let utis: Vec<&str> = p.flavors.iter().map(|f| f.uti.as_str()).collect();
        assert_eq!(utis, vec![ingest::UTI_UTF8, ingest::UTI_RTF]);
        assert_eq!(p.first(ingest::UTI_UTF8), Some(md.as_bytes()));
    }

    #[test]
    fn path_to_file_url_roundtrip() {
        let p = "/Users/me/My File (1).txt";
        let url = path_to_file_url(p);
        assert_eq!(url, "file:///Users/me/My%20File%20(1).txt");
        assert_eq!(ingest::file_url_to_path(&url).as_deref(), Some(p));
    }

    #[test]
    fn missing_blob_records_are_dropped_on_open() {
        let dir = tempfile::tempdir().unwrap();
        {
            let h = open(dir.path(), 100);
            h.ingest(text_snap(&"z".repeat(100_000))).unwrap();
            h.ingest(text_snap("fine")).unwrap();
        }
        std::fs::remove_dir_all(dir.path().join("blobs")).unwrap();
        let h = open(dir.path(), 100);
        let r = h.list(&ListQuery::default());
        assert_eq!(r.total, 1);
        assert_eq!(r.items[0].title, "fine");
    }
}
