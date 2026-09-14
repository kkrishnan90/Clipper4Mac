//! # clipper-core
//!
//! The platform-agnostic heart of Clipper. Everything that does not touch
//! `NSPasteboard` lives here so that it can be unit-tested on any OS:
//!
//! * [`model`]    – the data model (`Item`, `ItemKind`, payload references…)
//! * [`blob`]     – content-addressed blob store for large payloads (images, big text)
//! * [`store`]    – crash-safe metadata persistence on top of `redb` (no SQLite!)
//! * [`ingest`]   – turns a raw clipboard [`Snapshot`] into an [`Item`]
//! * [`search`]   – fuzzy ranking used by the popup's search box
//! * [`history`]  – the in-memory index + orchestration facade the app talks to
//! * [`settings`] – user preferences with atomic JSON persistence
//!
//! ## Why not SQLite?
//! Most OSS clipboard managers eventually hit a corrupted `.sqlite` file
//! (usually a WAL that was not checkpointed before a crash / force-quit /
//! power loss) and start returning garbage rows. Clipper avoids the entire
//! class of problems:
//!
//! 1. Metadata lives in [`redb`], a pure-Rust, ACID, copy-on-write B-tree
//!    (no WAL, every commit is atomic; a torn write is rolled back on open).
//! 2. Large payloads never enter the database. They are written to a
//!    content-addressed blob store using `write-tmp → fsync → rename`, so a
//!    blob is either fully present or absent – never half-written.
//! 3. Every record is self-validating JSON. On load, unreadable records or
//!    records whose blob is missing are dropped instead of poisoning the UI.
//! 4. If the database *still* cannot be opened, it is moved aside
//!    (`history.redb.corrupt-<ts>`) and a fresh one is created; the app always
//!    starts.

pub mod blob;
pub mod error;
pub mod history;
pub mod ingest;
pub mod model;
pub mod search;
pub mod settings;
pub mod store;
pub mod thumbs;

pub use error::{CoreError, Result};
pub use history::{History, HistoryStats, ListQuery, PasteContent};
pub use ingest::{RawFlavor, Snapshot};
pub use model::*;
pub use settings::{PopupPosition, Settings, Theme};

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
