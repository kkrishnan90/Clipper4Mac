//! Data model shared by the storage layer and the FFI façade
//! (`clipper-ffi` converts these into UniFFI records for Swift).

use serde::{Deserialize, Serialize};

/// High-level classification of a clipboard entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Text,
    Link,
    Color,
    Image,
    Files,
}

impl ItemKind {
    pub fn label(self) -> &'static str {
        match self {
            ItemKind::Text => "Text",
            ItemKind::Link => "Link",
            ItemKind::Color => "Color",
            ItemKind::Image => "Image",
            ItemKind::Files => "Files",
        }
    }
}

/// Sub-classification for file entries, derived from the extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Image,
    Video,
    Audio,
    Document,
    Archive,
    Code,
    Folder,
    #[default]
    Other,
}

impl MediaKind {
    pub fn from_path(path: &str) -> MediaKind {
        if path.ends_with('/') {
            return MediaKind::Folder;
        }
        let ext = std::path::Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .unwrap_or_default();
        match ext.as_str() {
            "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" | "heif" | "bmp" | "tif" | "tiff"
            | "svg" | "avif" | "ico" => MediaKind::Image,
            "mp4" | "mov" | "m4v" | "mkv" | "avi" | "webm" | "wmv" | "flv" | "mpg" | "mpeg"
            | "3gp" => MediaKind::Video,
            "mp3" | "wav" | "aac" | "m4a" | "flac" | "ogg" | "aiff" | "aif" | "wma" | "opus" => {
                MediaKind::Audio
            }
            "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "key" | "pages"
            | "numbers" | "txt" | "md" | "rtf" | "csv" | "epub" => MediaKind::Document,
            "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" | "7z" | "rar" | "dmg" | "pkg" => {
                MediaKind::Archive
            }
            "rs" | "py" | "js" | "ts" | "tsx" | "jsx" | "go" | "java" | "kt" | "swift" | "c"
            | "cc" | "cpp" | "h" | "hpp" | "m" | "mm" | "rb" | "php" | "sh" | "zsh" | "json"
            | "yaml" | "yml" | "toml" | "xml" | "html" | "css" | "scss" | "sql" | "proto" => {
                MediaKind::Code
            }
            _ => MediaKind::Other,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub media: MediaKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
}

impl FileEntry {
    pub fn from_path(path: &str) -> FileEntry {
        let trimmed = path.trim_end_matches('/');
        let name = std::path::Path::new(trimmed)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(trimmed)
            .to_string();
        let meta = std::fs::metadata(trimmed).ok();
        let media = if meta.as_ref().map(|m| m.is_dir()).unwrap_or(false) {
            MediaKind::Folder
        } else {
            MediaKind::from_path(path)
        };
        FileEntry {
            path: trimmed.to_string(),
            name,
            media,
            size: meta.and_then(|m| if m.is_file() { Some(m.len()) } else { None }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SourceApp {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageMeta {
    pub width: u32,
    pub height: u32,
    /// `png`, `tiff`, `jpeg`, …
    pub format: String,
}

impl ImageMeta {
    pub fn new(width: u32, height: u32, format: &str) -> Self {
        ImageMeta {
            width,
            height,
            format: format.to_string(),
        }
    }
}

/// Where the bytes of a payload live.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum PayloadRef {
    /// Small payloads are stored inline (base64 in JSON) to avoid a file per tiny snippet.
    Inline {
        #[serde(with = "b64")]
        data: Vec<u8>,
    },
    /// Large payloads are stored in the content-addressed blob store.
    Blob { hash: String, size: u64 },
}

impl PayloadRef {
    pub fn size(&self) -> u64 {
        match self {
            PayloadRef::Inline { data } => data.len() as u64,
            PayloadRef::Blob { size, .. } => *size,
        }
    }
    pub fn blob_hash(&self) -> Option<&str> {
        match self {
            PayloadRef::Blob { hash, .. } => Some(hash),
            _ => None,
        }
    }
}

/// An alternate representation of the same clipboard content (e.g. the HTML
/// or RTF flavour that accompanies plain text) keyed by its UTI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Representation {
    pub uti: String,
    pub payload: PayloadRef,
}

/// A persisted clipboard entry. This is what goes into the database (as JSON).
///
/// All non-essential fields are `#[serde(default)]` so that older records
/// keep loading after schema additions – a record is never rejected merely
/// because it predates a field.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: u64,
    pub kind: ItemKind,
    /// Single-line, truncated preview used in the list.
    pub title: String,
    /// Primary payload: UTF-8 text for Text/Link/Color, PNG/TIFF bytes for
    /// Image, newline-separated paths for Files.
    pub payload: PayloadRef,
    #[serde(default)]
    pub representations: Vec<Representation>,
    /// Small PNG thumbnail (≤ ~320px) for images / image files.
    #[serde(default, with = "b64_opt", skip_serializing_if = "Option::is_none")]
    pub thumbnail: Option<Vec<u8>>,
    /// Bounded searchable text excerpt for large blob-backed text items (> inline_limit).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_excerpt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageMeta>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<FileEntry>,
    /// Normalised colour (e.g. `#ff8800`) when `kind == Color`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub byte_size: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub char_count: Option<u32>,
    /// blake3 of the canonical content, used for de-duplication.
    pub hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceApp>,
    pub first_copied_at: i64,
    pub last_copied_at: i64,
    #[serde(default = "one")]
    pub copy_count: u32,
    #[serde(default)]
    pub pinned: bool,
}

fn one() -> u32 {
    1
}

impl Item {
    /// Iterates over every blob hash referenced by this item.
    pub fn blob_hashes(&self) -> impl Iterator<Item = &str> {
        self.payload.blob_hash().into_iter().chain(
            self.representations
                .iter()
                .filter_map(|r| r.payload.blob_hash()),
        )
    }
}

/// Lightweight projection of an [`Item`] sent to the UI. Never contains the
/// full payload – the UI asks for it explicitly when previewing.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemSummary {
    pub id: u64,
    pub kind: ItemKind,
    pub title: String,
    /// True if a thumbnail PNG is available via [`History::thumbnail_png`].
    pub has_thumbnail: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageMeta>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub files: Vec<FileEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    pub byte_size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub char_count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceApp>,
    pub first_copied_at: i64,
    pub last_copied_at: i64,
    pub copy_count: u32,
    pub pinned: bool,
    /// Which representations exist (`public.html`, `public.rtf`, …).
    #[serde(default)]
    pub flavors: Vec<String>,
}

impl From<&Item> for ItemSummary {
    fn from(it: &Item) -> Self {
        ItemSummary {
            id: it.id,
            kind: it.kind,
            title: it.title.clone(),
            has_thumbnail: it.thumbnail.is_some(),
            image: it.image.clone(),
            files: it.files.clone(),
            color: it.color.clone(),
            byte_size: it.byte_size,
            char_count: it.char_count,
            source: it.source.clone(),
            first_copied_at: it.first_copied_at,
            last_copied_at: it.last_copied_at,
            copy_count: it.copy_count,
            pinned: it.pinned,
            flavors: it.representations.iter().map(|r| r.uti.clone()).collect(),
        }
    }
}

/// Full detail for the preview pane: summary + (bounded) text body.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemDetail {
    #[serde(flatten)]
    pub summary: ItemSummary,
    /// UTF-8 text body, truncated to `text_truncated_at` bytes if huge.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    pub text_truncated: bool,
    /// Full-size image as data URL (only for `Image`, bounded by size).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_data_url: Option<String>,
}

pub(crate) mod b64 {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

pub(crate) mod b64_opt {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
        match bytes {
            Some(b) => s.serialize_some(&base64::engine::general_purpose::STANDARD.encode(b)),
            None => s.serialize_none(),
        }
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        let s: Option<String> = Option::deserialize(d)?;
        match s {
            None => Ok(None),
            Some(s) => base64::engine::general_purpose::STANDARD
                .decode(s.as_bytes())
                .map(Some)
                .map_err(serde::de::Error::custom),
        }
    }
}
