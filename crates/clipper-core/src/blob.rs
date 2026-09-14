//! Content-addressed blob store.
//!
//! Layout: `<root>/ab/abcdef…` where the directory is the first two hex
//! characters of the blake3 hash. Writes are atomic (`tmp → fsync → rename`),
//! so a blob can never be observed half-written, and identical content is
//! stored exactly once.

use crate::{CoreError, Result};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct BlobStore {
    root: PathBuf,
}

/// Hex-encoded blake3 hash of `bytes`.
pub fn hash_bytes(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

impl BlobStore {
    pub fn open(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        Ok(BlobStore { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn path_for(&self, hash: &str) -> PathBuf {
        let prefix = if hash.len() >= 2 { &hash[..2] } else { "00" };
        self.root.join(prefix).join(hash)
    }

    pub fn exists(&self, hash: &str) -> bool {
        self.path_for(hash).is_file()
    }

    /// Stores `bytes`, returning its hash. No-op if already present.
    pub fn put(&self, bytes: &[u8]) -> Result<String> {
        let hash = hash_bytes(bytes);
        let final_path = self.path_for(&hash);
        if final_path.is_file() {
            return Ok(hash);
        }
        if let Some(parent) = final_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = final_path.with_extension(format!("tmp-{}", std::process::id()));
        {
            let mut f = fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
        }
        // rename(2) is atomic on POSIX filesystems (APFS included).
        if let Err(e) = fs::rename(&tmp, &final_path) {
            let _ = fs::remove_file(&tmp);
            // Another writer may have raced us; that is fine.
            if !final_path.is_file() {
                return Err(e.into());
            }
        }
        Ok(hash)
    }

    pub fn get(&self, hash: &str) -> Result<Vec<u8>> {
        let path = self.path_for(hash);
        fs::read(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                CoreError::BlobMissing(hash.to_string())
            } else {
                e.into()
            }
        })
    }

    pub fn remove(&self, hash: &str) -> Result<()> {
        let path = self.path_for(hash);
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Removes every blob whose hash is not in `keep`, plus stray temp files.
    /// Returns the number of files deleted.
    pub fn sweep<F: Fn(&str) -> bool>(&self, keep: F) -> Result<usize> {
        let mut removed = 0;
        let Ok(dirs) = fs::read_dir(&self.root) else {
            return Ok(0);
        };
        for dir in dirs.flatten() {
            let Ok(files) = fs::read_dir(dir.path()) else {
                continue;
            };
            for f in files.flatten() {
                let name = f.file_name().to_string_lossy().to_string();
                let is_tmp = name.contains(".tmp-");
                if (is_tmp || !keep(&name)) && fs::remove_file(f.path()).is_ok() {
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// Total bytes on disk.
    pub fn disk_usage(&self) -> u64 {
        let mut total = 0;
        let Ok(dirs) = fs::read_dir(&self.root) else {
            return 0;
        };
        for dir in dirs.flatten() {
            let Ok(files) = fs::read_dir(dir.path()) else {
                continue;
            };
            for f in files.flatten() {
                if let Ok(m) = f.metadata() {
                    total += m.len();
                }
            }
        }
        total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_get_roundtrip_and_dedup() {
        let dir = tempfile::tempdir().unwrap();
        let store = BlobStore::open(dir.path()).unwrap();
        let h1 = store.put(b"hello").unwrap();
        let h2 = store.put(b"hello").unwrap();
        assert_eq!(h1, h2);
        assert_eq!(store.get(&h1).unwrap(), b"hello");
        assert!(store.exists(&h1));
        store.remove(&h1).unwrap();
        assert!(!store.exists(&h1));
        assert!(matches!(store.get(&h1), Err(CoreError::BlobMissing(_))));
    }

    #[test]
    fn sweep_removes_unreferenced() {
        let dir = tempfile::tempdir().unwrap();
        let store = BlobStore::open(dir.path()).unwrap();
        let keep = store.put(b"keep").unwrap();
        let drop = store.put(b"drop").unwrap();
        let n = store.sweep(|h| h == keep).unwrap();
        assert_eq!(n, 1);
        assert!(store.exists(&keep));
        assert!(!store.exists(&drop));
    }
}
