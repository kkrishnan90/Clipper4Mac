//! Crash-safe metadata persistence on top of [`redb`].
//!
//! Only small JSON records live here; blobs live in [`crate::blob`].
//! Each write is a single ACID transaction. If the file cannot be opened
//! (torn write on a dying disk, a downgrade, cosmic rays…) we *never* refuse
//! to start: the broken file is moved aside and a fresh database is created.

use crate::model::Item;
use crate::{CoreError, Result};
use redb::{Database, ReadableDatabase, ReadableTable, ReadableTableMetadata, TableDefinition};
use std::path::{Path, PathBuf};

/// id → JSON(Item)
const ITEMS: TableDefinition<u64, &str> = TableDefinition::new("items_v1");
/// content hash → id (for O(1) de-duplication)
const HASHES: TableDefinition<&str, u64> = TableDefinition::new("hashes_v1");
/// misc counters
const META: TableDefinition<&str, u64> = TableDefinition::new("meta_v1");

const META_NEXT_ID: &str = "next_id";

pub struct Store {
    db: Database,
    path: PathBuf,
}

/// Outcome of loading all records, including how many were self-healed away.
#[derive(Debug, Default)]
pub struct LoadReport {
    pub items: Vec<Item>,
    pub dropped_corrupt: usize,
}

impl Store {
    /// Opens (or creates) the database at `path`. If the file exists but is
    /// unreadable it is renamed to `<path>.corrupt-<unix-ts>` and recreated.
    pub fn open_or_recover(path: impl AsRef<Path>) -> Result<Store> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        match Self::open_inner(&path) {
            Ok(db) => Ok(Store { db, path }),
            Err(first_err) => {
                log::error!("history db unreadable ({first_err}); moving aside and recreating");
                let quarantine = path.with_extension(format!("redb.corrupt-{}", crate::now_ms()));
                if path.exists() {
                    std::fs::rename(&path, &quarantine)?;
                }
                let db = Self::open_inner(&path)?;
                Ok(Store { db, path })
            }
        }
    }

    fn open_inner(path: &Path) -> Result<Database> {
        let mut builder = Database::builder();
        // 4 MiB page cache is plenty for metadata-only records since the live
        // index is already held in memory.
        builder.set_cache_size(4 * 1024 * 1024);
        builder.set_repair_callback(|session| {
            log::warn!(
                "redb repairing history database ({:.0}% done)",
                session.progress() * 100.0
            );
        });
        let db = builder.create(path)?;
        // Make sure the tables exist so readers never see TableDoesNotExist.
        let txn = db.begin_write()?;
        {
            txn.open_table(ITEMS)?;
            txn.open_table(HASHES)?;
            txn.open_table(META)?;
        }
        txn.commit()?;
        Ok(db)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Allocates a fresh monotonically increasing id.
    pub fn next_id(&self) -> Result<u64> {
        let txn = self.db.begin_write()?;
        let id = {
            let mut meta = txn.open_table(META)?;
            let current = meta.get(META_NEXT_ID)?.map(|g| g.value()).unwrap_or(1);
            meta.insert(META_NEXT_ID, current + 1)?;
            current
        };
        txn.commit()?;
        Ok(id)
    }

    /// Allocates a fresh id and inserts `item` (plus its hash index entry) in
    /// a single atomic write transaction (one fsync instead of two).
    pub fn put_new(&self, item: &mut Item) -> Result<()> {
        let txn = self.db.begin_write()?;
        let id = {
            let mut meta = txn.open_table(META)?;
            let current = meta.get(META_NEXT_ID)?.map(|g| g.value()).unwrap_or(1);
            meta.insert(META_NEXT_ID, current + 1)?;
            current
        };
        item.id = id;
        let json = serde_json::to_string(item)?;
        {
            let mut items = txn.open_table(ITEMS)?;
            let mut hashes = txn.open_table(HASHES)?;
            items.insert(item.id, json.as_str())?;
            hashes.insert(item.hash.as_str(), item.id)?;
        }
        txn.commit()?;
        Ok(())
    }

    /// Inserts or replaces an item (and its hash index entry) atomically.
    pub fn put(&self, item: &Item) -> Result<()> {
        let json = serde_json::to_string(item)?;
        let txn = self.db.begin_write()?;
        {
            let mut items = txn.open_table(ITEMS)?;
            let mut hashes = txn.open_table(HASHES)?;
            items.insert(item.id, json.as_str())?;
            hashes.insert(item.hash.as_str(), item.id)?;
        }
        txn.commit()?;
        Ok(())
    }

    /// Persists several items in one transaction.
    pub fn put_many<'a>(&self, iter: impl IntoIterator<Item = &'a Item>) -> Result<()> {
        let txn = self.db.begin_write()?;
        {
            let mut items = txn.open_table(ITEMS)?;
            let mut hashes = txn.open_table(HASHES)?;
            for item in iter {
                let json = serde_json::to_string(item)?;
                items.insert(item.id, json.as_str())?;
                hashes.insert(item.hash.as_str(), item.id)?;
            }
        }
        txn.commit()?;
        Ok(())
    }

    pub fn get(&self, id: u64) -> Result<Option<Item>> {
        let txn = self.db.begin_read()?;
        let items = txn.open_table(ITEMS)?;
        match items.get(id)? {
            Some(guard) => Ok(Some(serde_json::from_str(guard.value())?)),
            None => Ok(None),
        }
    }

    pub fn delete(&self, id: u64) -> Result<Option<Item>> {
        let txn = self.db.begin_write()?;
        let removed = {
            let mut items = txn.open_table(ITEMS)?;
            let mut hashes = txn.open_table(HASHES)?;
            let removed = items.remove(id)?.map(|g| g.value().to_string());
            let parsed: Option<Item> = removed.and_then(|json| serde_json::from_str(&json).ok());
            if let Some(it) = &parsed {
                // Only drop the hash pointer if it still points at us.
                let points_here = hashes.get(it.hash.as_str())?.map(|g| g.value()) == Some(id);
                if points_here {
                    hashes.remove(it.hash.as_str())?;
                }
            }
            parsed
        };
        txn.commit()?;
        Ok(removed)
    }

    pub fn delete_many(&self, ids: &[u64]) -> Result<usize> {
        let txn = self.db.begin_write()?;
        let mut n = 0;
        {
            let mut items = txn.open_table(ITEMS)?;
            let mut hashes = txn.open_table(HASHES)?;
            for id in ids {
                if let Some(g) = items.remove(*id)? {
                    n += 1;
                    if let Ok(it) = serde_json::from_str::<Item>(g.value()) {
                        let points_here =
                            hashes.get(it.hash.as_str())?.map(|g| g.value()) == Some(*id);
                        if points_here {
                            hashes.remove(it.hash.as_str())?;
                        }
                    }
                }
            }
        }
        txn.commit()?;
        Ok(n)
    }

    pub fn find_by_hash(&self, hash: &str) -> Result<Option<u64>> {
        let txn = self.db.begin_read()?;
        let hashes = txn.open_table(HASHES)?;
        Ok(hashes.get(hash)?.map(|g| g.value()))
    }

    /// Loads every record, silently dropping (and deleting) ones that no
    /// longer parse so a single bad row can never take the UI down.
    pub fn load_all(&self) -> Result<LoadReport> {
        let mut report = LoadReport::default();
        let mut bad_ids = Vec::new();
        {
            let txn = self.db.begin_read()?;
            let items = txn.open_table(ITEMS)?;
            for entry in items.iter()? {
                let (k, v) = entry?;
                match serde_json::from_str::<Item>(v.value()) {
                    Ok(item) => report.items.push(item),
                    Err(e) => {
                        log::warn!("dropping unreadable history record {}: {e}", k.value());
                        bad_ids.push(k.value());
                    }
                }
            }
        }
        if !bad_ids.is_empty() {
            report.dropped_corrupt = bad_ids.len();
            let _ = self.delete_many(&bad_ids);
        }
        Ok(report)
    }

    pub fn len(&self) -> Result<u64> {
        let txn = self.db.begin_read()?;
        let items = txn.open_table(ITEMS)?;
        Ok(items.len()?)
    }

    pub fn is_empty(&self) -> Result<bool> {
        Ok(self.len()? == 0)
    }

    /// Removes everything except the given ids.
    pub fn retain(&self, keep: &[u64]) -> Result<usize> {
        let ids: Vec<u64> = {
            let txn = self.db.begin_read()?;
            let items = txn.open_table(ITEMS)?;
            let mut ids = Vec::new();
            for entry in items.iter()? {
                let (k, _) = entry?;
                if !keep.contains(&k.value()) {
                    ids.push(k.value());
                }
            }
            ids
        };
        self.delete_many(&ids)
    }

    /// Reclaims free pages. Safe to call any time; cheap when nothing to do.
    pub fn compact(&mut self) -> Result<bool> {
        self.db.compact().map_err(|e| CoreError::Db(e.to_string()))
    }

    pub fn file_size(&self) -> u64 {
        std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::*;

    fn item(id: u64, text: &str) -> Item {
        Item {
            id,
            kind: ItemKind::Text,
            title: text.into(),
            payload: PayloadRef::Inline {
                data: text.as_bytes().to_vec(),
            },
            representations: vec![],
            thumbnail: None,
            search_excerpt: None,
            image: None,
            files: vec![],
            color: None,
            byte_size: text.len() as u64,
            char_count: Some(text.chars().count() as u32),
            hash: crate::blob::hash_bytes(text.as_bytes()),
            source: None,
            first_copied_at: 1,
            last_copied_at: 1,
            copy_count: 1,
            pinned: false,
        }
    }

    #[test]
    fn roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open_or_recover(dir.path().join("h.redb")).unwrap();
        let id = store.next_id().unwrap();
        let it = item(id, "hello world");
        store.put(&it).unwrap();
        assert_eq!(store.get(id).unwrap().unwrap(), it);
        assert_eq!(store.find_by_hash(&it.hash).unwrap(), Some(id));
        assert_eq!(store.len().unwrap(), 1);
        let removed = store.delete(id).unwrap().unwrap();
        assert_eq!(removed.id, id);
        assert_eq!(store.find_by_hash(&it.hash).unwrap(), None);
        assert!(store.is_empty().unwrap());
    }

    #[test]
    fn ids_are_monotonic_across_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("h.redb");
        let a = {
            let store = Store::open_or_recover(&p).unwrap();
            store.next_id().unwrap()
        };
        let store = Store::open_or_recover(&p).unwrap();
        assert!(store.next_id().unwrap() > a);
    }

    #[test]
    fn recovers_from_garbage_file() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("h.redb");
        std::fs::write(&p, b"this is definitely not a redb file").unwrap();
        let store = Store::open_or_recover(&p).unwrap();
        assert!(store.is_empty().unwrap());
        let quarantined = std::fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().contains("corrupt"));
        assert!(quarantined, "broken db should be moved aside, not deleted");
    }

    #[test]
    fn unreadable_records_are_dropped_not_fatal() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open_or_recover(dir.path().join("h.redb")).unwrap();
        store.put(&item(1, "good")).unwrap();
        // Inject a bad row directly.
        let txn = store.db.begin_write().unwrap();
        txn.open_table(ITEMS)
            .unwrap()
            .insert(2u64, "{not json")
            .unwrap();
        txn.commit().unwrap();
        let report = store.load_all().unwrap();
        assert_eq!(report.items.len(), 1);
        assert_eq!(report.dropped_corrupt, 1);
        assert_eq!(store.len().unwrap(), 1);
    }
}
