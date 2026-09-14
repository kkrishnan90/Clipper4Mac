//! Converts a raw clipboard [`Snapshot`] captured by the platform layer into
//! an [`Item`] ready for persistence.
//!
//! **Fidelity rule:** every pasteboard flavour is stored byte-for-byte and
//! written back unchanged on paste. Classification (text / link / colour /
//! image / files), the list title and the thumbnail are *derived* from those
//! bytes and never replace them. Pasting from Clipper therefore gives the
//! target application exactly the flavours the original copy offered –
//! Markdown stays Markdown, a spreadsheet range stays a range, RTF keeps its
//! formatting, and a TIFF screenshot is still a TIFF.

use crate::blob::{hash_bytes, BlobStore};
use crate::model::*;
use crate::thumbs;
use crate::Result;
use image::ImageFormat;

/// Well-known UTIs (`NSPasteboard.PasteboardType.*.rawValue`).
pub const UTI_UTF8: &str = "public.utf8-plain-text";
pub const UTI_UTF16_EXTERNAL: &str = "public.utf16-external-plain-text";
pub const UTI_UTF16: &str = "public.utf16-plain-text";
pub const UTI_HTML: &str = "public.html";
pub const UTI_RTF: &str = "public.rtf";
pub const UTI_RTFD: &str = "com.apple.flat-rtfd";
pub const UTI_PNG: &str = "public.png";
pub const UTI_TIFF: &str = "public.tiff";
pub const UTI_JPEG: &str = "public.jpeg";
pub const UTI_PDF: &str = "com.adobe.pdf";
pub const UTI_FILE_URL: &str = "public.file-url";
pub const UTI_URL: &str = "public.url";

/// One flavour exactly as read from `NSPasteboard` (`item.data(forType:)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawFlavor {
    pub uti: String,
    pub data: Vec<u8>,
}

impl RawFlavor {
    pub fn new(uti: impl Into<String>, data: impl Into<Vec<u8>>) -> Self {
        RawFlavor {
            uti: uti.into(),
            data: data.into(),
        }
    }
}

/// Everything on the pasteboard at one `changeCount`: all flavours of all
/// pasteboard items, flattened in pasteboard order (multiple items are
/// almost always multiple files; some apps split one copy into two items).
#[derive(Debug, Default, Clone)]
pub struct Snapshot {
    pub flavors: Vec<RawFlavor>,
    pub source: Option<SourceApp>,
    /// `org.nspasteboard.ConcealedType` was present (password managers).
    pub concealed: bool,
    /// `org.nspasteboard.TransientType` / auto-generated content.
    pub transient: bool,
}

impl Snapshot {
    /// Convenience constructor: a plain-text copy.
    pub fn text(s: &str) -> Snapshot {
        Snapshot {
            flavors: vec![RawFlavor::new(UTI_UTF8, s.as_bytes())],
            ..Default::default()
        }
    }

    pub fn with(mut self, uti: &str, data: impl Into<Vec<u8>>) -> Snapshot {
        self.flavors.push(RawFlavor::new(uti, data));
        self
    }

    pub fn has(&self, uti: &str) -> bool {
        self.flavors.iter().any(|f| f.uti == uti)
    }

    pub fn first(&self, uti: &str) -> Option<&[u8]> {
        self.flavors
            .iter()
            .find(|f| f.uti == uti)
            .map(|f| f.data.as_slice())
    }

    /// Plain text, preferring UTF-8 and falling back to the UTF-16 flavours.
    /// Returned exactly as copied – no trimming or newline normalisation.
    pub fn plain_text(&self) -> Option<String> {
        if let Some(b) = self.first(UTI_UTF8) {
            return Some(String::from_utf8_lossy(b).into_owned());
        }
        if let Some(b) = self.first(UTI_UTF16_EXTERNAL) {
            return decode_utf16(b, true);
        }
        if let Some(b) = self.first(UTI_UTF16) {
            return decode_utf16(b, false);
        }
        None
    }

    /// Absolute paths of every `public.file-url` flavour, URL-decoded.
    pub fn file_paths(&self) -> Vec<String> {
        self.flavors
            .iter()
            .filter(|f| f.uti == UTI_FILE_URL)
            .filter_map(|f| file_url_to_path(&String::from_utf8_lossy(&f.data)))
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.flavors.is_empty()
    }
}

/// Decodes UTF-16 with an optional BOM; native endianness when absent.
fn decode_utf16(b: &[u8], external: bool) -> Option<String> {
    if b.len() < 2 {
        return None;
    }
    let (be, body) = match (b[0], b[1]) {
        (0xFE, 0xFF) => (true, &b[2..]),
        (0xFF, 0xFE) => (false, &b[2..]),
        _ => (external && cfg!(target_endian = "big"), b),
    };
    let units: Vec<u16> = body
        .chunks_exact(2)
        .map(|c| {
            if be {
                u16::from_be_bytes([c[0], c[1]])
            } else {
                u16::from_le_bytes([c[0], c[1]])
            }
        })
        .collect();
    Some(String::from_utf16_lossy(&units))
}

/// `file:///Users/me/My%20File.txt` → `/Users/me/My File.txt`.
pub fn file_url_to_path(url: &str) -> Option<String> {
    let url = url.trim_end_matches(['\0', '\n', '\r']);
    let rest = url.strip_prefix("file://")?;
    // Strip an optional host (`file://localhost/…`).
    let path = match rest.find('/') {
        Some(0) => rest,
        Some(i) => &rest[i..],
        None => return None,
    };
    let decoded = percent_decode(path);
    Some(decoded.trim_end_matches('/').to_string()).filter(|p| !p.is_empty())
}

pub fn percent_decode(s: &str) -> String {
    fn hex(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Debug, Clone)]
pub struct IngestOptions {
    /// Payloads at or below this size are stored inline in the DB record.
    pub inline_limit: usize,
    pub store_images: bool,
    pub store_files: bool,
    /// Skip images larger than this (bytes) to protect memory/disk.
    pub max_image_bytes: usize,
    /// Only thumbnail image *files* smaller than this.
    pub file_thumb_max_bytes: u64,
    /// Keep every flavour (HTML, RTF, app-private types…) alongside the
    /// essential one. When `false` only plain text / PNG / file URLs are kept.
    pub keep_rich_text: bool,
    /// Longest title, in chars.
    pub title_chars: usize,
    /// Any single non-essential flavour above this size is dropped.
    pub max_flavor_bytes: usize,
}

impl Default for IngestOptions {
    fn default() -> Self {
        IngestOptions {
            inline_limit: 32 * 1024,
            store_images: true,
            store_files: true,
            max_image_bytes: 64 * 1024 * 1024,
            file_thumb_max_bytes: 24 * 1024 * 1024,
            keep_rich_text: true,
            title_chars: 200,
            max_flavor_bytes: 64 * 1024 * 1024,
        }
    }
}

fn store_payload(bytes: &[u8], blobs: &BlobStore, opts: &IngestOptions) -> Result<PayloadRef> {
    if bytes.len() <= opts.inline_limit {
        Ok(PayloadRef::Inline {
            data: bytes.to_vec(),
        })
    } else {
        let hash = blobs.put(bytes)?;
        Ok(PayloadRef::Blob {
            hash,
            size: bytes.len() as u64,
        })
    }
}

fn base_item(kind: ItemKind, title: String, payload: PayloadRef, hash: String) -> Item {
    let now = crate::now_ms();
    Item {
        id: 0,
        kind,
        title,
        byte_size: payload.size(),
        payload,
        representations: Vec::new(),
        thumbnail: None,
        image: None,
        files: Vec::new(),
        color: None,
        char_count: None,
        hash,
        source: None,
        first_copied_at: now,
        last_copied_at: now,
        copy_count: 1,
        pinned: false,
    }
}

/// The flavours that survive `keep_rich_text = false`.
fn is_essential(uti: &str) -> bool {
    matches!(uti, UTI_UTF8 | UTI_PNG | UTI_FILE_URL | UTI_URL)
}

/// Stores every flavour of the snapshot verbatim as the item's
/// representations. Sizes are summed into `byte_size`.
pub fn store_flavors(
    item: &mut Item,
    snap: &Snapshot,
    blobs: &BlobStore,
    opts: &IngestOptions,
) -> Result<()> {
    let mut reps = Vec::with_capacity(snap.flavors.len());
    let mut total = 0u64;
    for f in &snap.flavors {
        let essential = is_essential(&f.uti);
        if !essential && !opts.keep_rich_text {
            continue;
        }
        if !essential && f.data.len() > opts.max_flavor_bytes {
            log::info!("dropping {}-byte flavour {}", f.data.len(), f.uti);
            continue;
        }
        let payload = store_payload(&f.data, blobs, opts)?;
        total += payload.size();
        reps.push(Representation {
            uti: f.uti.clone(),
            payload,
        });
    }
    item.representations = reps;
    item.byte_size = total;
    Ok(())
}

/// Builds an [`Item`] (with `id == 0`) from a snapshot, or `None` if the
/// snapshot should be ignored (empty, concealed, disabled kind…).
pub fn build_item(snap: Snapshot, blobs: &BlobStore, opts: &IngestOptions) -> Result<Option<Item>> {
    if snap.concealed || snap.transient || snap.is_empty() {
        return Ok(None);
    }

    let text = snap.plain_text().filter(|t| !t.trim().is_empty());
    let has_rich = snap.has(UTI_HTML) || snap.has(UTI_RTF) || snap.has(UTI_RTFD);
    let has_image = snap.has(UTI_PNG) || snap.has(UTI_TIFF);
    let files = snap.file_paths();

    let mut item = if !files.is_empty() {
        // 1. Files always win (Finder also puts the file name as plain text).
        if !opts.store_files {
            return Ok(None);
        }
        build_files(&files)
    } else if has_image && !(text.is_some() && has_rich) {
        // 2. Images – unless this looks like a rich-text/spreadsheet copy,
        //    where apps attach a rendered TIFF next to the real text.
        if !opts.store_images {
            return Ok(None);
        }
        match build_image(&snap, opts)? {
            Some(it) => it,
            None => return Ok(None),
        }
    } else if let Some(text) = text {
        // 3. Text.
        build_text(&text)
    } else if has_image && opts.store_images {
        // Image present but classified as rich text and no text? Fall back.
        match build_image(&snap, opts)? {
            Some(it) => it,
            None => return Ok(None),
        }
    } else if opts.keep_rich_text && (snap.plain_text().is_none() || has_rich) {
        // 4. Only app-private flavours (e.g. a shape copied in a design tool),
        //    or rich text whose plain flavour is blank (an empty table cell).
        build_opaque(&snap)
    } else {
        return Ok(None);
    };

    // The primary payload is stored separately so search / preview / dedup
    // never have to touch the raw flavours.
    let primary = std::mem::replace(&mut item.payload, PayloadRef::Inline { data: Vec::new() });
    item.payload = match primary {
        PayloadRef::Inline { data } => store_payload(&data, blobs, opts)?,
        other => other,
    };
    store_flavors(&mut item, &snap, blobs, opts)?;
    item.byte_size += item.payload.size();
    item.source = snap.source.clone();
    Ok(Some(item))
}

fn build_files(paths: &[String]) -> Item {
    let entries: Vec<FileEntry> = paths.iter().map(|p| FileEntry::from_path(p)).collect();
    let joined = paths.join("\n");
    let hash = hash_bytes(format!("files\u{0}{joined}").as_bytes());
    let title = match entries.len() {
        1 => entries[0].name.clone(),
        n => {
            let names: Vec<&str> = entries.iter().take(3).map(|e| e.name.as_str()).collect();
            let more = if n > 3 {
                format!(" +{}", n - 3)
            } else {
                String::new()
            };
            format!("{n} items · {}{more}", names.join(", "))
        }
    };
    let mut item = base_item(
        ItemKind::Files,
        truncate(&title, 200),
        PayloadRef::Inline {
            data: joined.into_bytes(),
        },
        hash,
    );
    if entries.len() == 1 && entries[0].media == MediaKind::Image {
        if let Some((thumb, meta)) = thumbs::thumbnail_from_file(&entries[0].path, 24 * 1024 * 1024)
        {
            item.thumbnail = Some(thumb);
            item.image = Some(meta);
        }
    }
    item.files = entries;
    item
}

fn build_image(snap: &Snapshot, opts: &IngestOptions) -> Result<Option<Item>> {
    // Prefer PNG (lossless, compact) for the primary payload. Fall back to
    // TIFF and transcode – the original TIFF flavour is still kept verbatim.
    let (bytes, hint) = match (snap.first(UTI_PNG), snap.first(UTI_TIFF)) {
        (Some(png), _) => (png, ImageFormat::Png),
        (None, Some(tiff)) => (tiff, ImageFormat::Tiff),
        (None, None) => return Ok(None),
    };
    if bytes.len() > opts.max_image_bytes {
        log::info!("skipping {}-byte image (over limit)", bytes.len());
        return Ok(None);
    }

    let decoded = thumbs::decode(bytes, Some(hint)).ok();
    let (payload_bytes, meta, thumb) = match decoded {
        Some(d) => {
            let meta = thumbs::meta_of(&d.image, ImageFormat::Png);
            let thumb = thumbs::thumbnail_png(&d.image).ok();
            let payload_bytes = if hint == ImageFormat::Png {
                bytes.to_vec()
            } else {
                thumbs::encode_png(&d.image)?
            };
            (payload_bytes, Some(meta), thumb)
        }
        None => {
            // Undecodable but still worth keeping – paste round-trips raw bytes.
            let meta = ImageMeta::new(0, 0, thumbs::format_name(hint));
            (bytes.to_vec(), Some(meta), None)
        }
    };

    let hash = hash_bytes(&payload_bytes);
    let title = match &meta {
        Some(m) if m.width > 0 => format!(
            "Image · {} × {} · {}",
            m.width,
            m.height,
            m.format.to_uppercase()
        ),
        _ => "Image".to_string(),
    };
    let mut item = base_item(
        ItemKind::Image,
        title,
        PayloadRef::Inline {
            data: payload_bytes,
        },
        hash,
    );
    item.image = meta;
    item.thumbnail = thumb;
    Ok(Some(item))
}

fn build_text(text: &str) -> Item {
    let hash = hash_bytes(text.as_bytes());
    let kind = classify_text(text);
    let title = make_title(text, 200);
    let mut item = base_item(
        kind,
        title,
        PayloadRef::Inline {
            data: text.as_bytes().to_vec(),
        },
        hash,
    );
    item.char_count = Some(text.chars().count().min(u32::MAX as usize) as u32);
    if kind == ItemKind::Color {
        item.color = normalize_color(text.trim());
    }
    item
}

/// A copy with no text, image or files – only private flavours. Kept so it
/// can be pasted back; titled by its most descriptive UTI.
fn build_opaque(snap: &Snapshot) -> Item {
    let mut hasher = blake3::Hasher::new();
    for f in &snap.flavors {
        hasher.update(f.uti.as_bytes());
        hasher.update(&[0]);
        hasher.update(&f.data);
        hasher.update(&[0]);
    }
    let hash = hasher.finalize().to_hex().to_string();
    let uti = snap
        .flavors
        .iter()
        .map(|f| f.uti.as_str())
        .find(|u| !u.starts_with("dyn."))
        .unwrap_or("data");
    let title = format!(
        "{} · {}",
        friendly_uti(uti),
        human_bytes(snap.flavors.iter().map(|f| f.data.len()).sum())
    );
    base_item(
        ItemKind::Text,
        title,
        PayloadRef::Inline {
            data: uti.as_bytes().to_vec(),
        },
        hash,
    )
}

fn friendly_uti(uti: &str) -> String {
    match uti {
        UTI_PDF => "PDF".into(),
        UTI_RTFD => "Rich text with attachments".into(),
        "com.apple.webarchive" => "Web archive".into(),
        other => other.rsplit('.').next().unwrap_or(other).replace('-', " "),
    }
}

pub fn human_bytes(n: usize) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

/// Single-line, whitespace-collapsed, truncated preview.
pub fn make_title(text: &str, max_chars: usize) -> String {
    let first = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    let collapsed: String = first.split_whitespace().collect::<Vec<_>>().join(" ");
    let more_lines = text.trim().lines().filter(|l| !l.trim().is_empty()).count() > 1;
    let mut t = truncate(&collapsed, max_chars);
    if more_lines && t.chars().count() < max_chars {
        t.push_str(" ⏎");
    }
    t
}

pub fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
}

pub fn classify_text(text: &str) -> ItemKind {
    let t = text.trim();
    if is_link(t) {
        ItemKind::Link
    } else if normalize_color(t).is_some() {
        ItemKind::Color
    } else {
        ItemKind::Text
    }
}

pub fn is_link(t: &str) -> bool {
    if t.is_empty() || t.contains(char::is_whitespace) || t.chars().count() > 2048 {
        return false;
    }
    let lower = t.to_ascii_lowercase();
    let schemes = [
        "http://", "https://", "ftp://", "ftps://", "mailto:", "file://", "ssh://",
    ];
    if schemes.iter().any(|s| lower.starts_with(s)) {
        return lower.len() > 8 && !lower.ends_with("://");
    }
    // Scheme-less: www.example.com / example.com/path
    if lower.starts_with("www.") && lower.matches('.').count() >= 2 {
        return true;
    }
    false
}

/// Accepts `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(...)`, `rgba(...)`,
/// `hsl(...)`, `hsla(...)` and returns a `#rrggbb[aa]` string when possible
/// (functional notations are returned as-is, lower-cased).
pub fn normalize_color(t: &str) -> Option<String> {
    if t.chars().count() > 40 {
        return None;
    }
    let lower = t.to_ascii_lowercase();
    if let Some(hex) = lower.strip_prefix('#') {
        if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        return match hex.len() {
            3 | 4 => Some(format!(
                "#{}",
                hex.chars().flat_map(|c| [c, c]).collect::<String>()
            )),
            6 | 8 => Some(format!("#{hex}")),
            _ => None,
        };
    }
    for f in ["rgba(", "rgb(", "hsla(", "hsl("] {
        if lower.starts_with(f) && lower.ends_with(')') {
            let inner = &lower[f.len()..lower.len() - 1];
            let ok = inner
                .split([',', ' ', '/'])
                .filter(|s| !s.is_empty())
                .all(|s| {
                    s.trim_end_matches(['%', 'd', 'e', 'g'])
                        .parse::<f32>()
                        .is_ok()
                });
            if ok {
                return Some(lower);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blobs() -> (tempfile::TempDir, BlobStore) {
        let d = tempfile::tempdir().unwrap();
        let b = BlobStore::open(d.path()).unwrap();
        (d, b)
    }

    #[test]
    fn classifies_text_kinds() {
        assert_eq!(classify_text("https://example.com/a?b=1"), ItemKind::Link);
        assert_eq!(classify_text("www.google.com"), ItemKind::Link);
        assert_eq!(classify_text("#ff8800"), ItemKind::Color);
        assert_eq!(classify_text("#f80"), ItemKind::Color);
        assert_eq!(classify_text("rgb(255, 136, 0)"), ItemKind::Color);
        assert_eq!(classify_text("hello https://x.y"), ItemKind::Text);
        assert_eq!(classify_text("#nothex"), ItemKind::Text);
        assert_eq!(normalize_color("#F80"), Some("#ff8800".into()));
    }

    #[test]
    fn title_is_single_line_and_truncated() {
        let t = make_title("  \n\n  first   line here\nsecond", 12);
        assert_eq!(t, "first line …");
        let t = make_title("one\ntwo", 50);
        assert_eq!(t, "one ⏎");
    }

    #[test]
    fn file_urls_decode() {
        assert_eq!(
            file_url_to_path("file:///Users/me/My%20File.txt").as_deref(),
            Some("/Users/me/My File.txt")
        );
        assert_eq!(
            file_url_to_path("file://localhost/tmp/a/").as_deref(),
            Some("/tmp/a")
        );
        assert_eq!(file_url_to_path("https://x"), None);
        assert_eq!(percent_decode("100%25%zz"), "100%%zz");
    }

    #[test]
    fn utf16_fallback() {
        let mut b = vec![0xFF, 0xFE];
        for u in "héllo".encode_utf16() {
            b.extend_from_slice(&u.to_le_bytes());
        }
        let snap = Snapshot::default().with(UTI_UTF16_EXTERNAL, b);
        assert_eq!(snap.plain_text().as_deref(), Some("héllo"));
    }

    #[test]
    fn text_keeps_every_flavor_verbatim() {
        let (_d, b) = blobs();
        let md = "# Title\n\n- item **bold**\n\n```rs\nfn x() {}\n```\n";
        let snap = Snapshot::text(md)
            .with(UTI_HTML, "<h1>Title</h1>")
            .with(UTI_RTF, b"{\\rtf1 Title}".to_vec())
            .with("com.example.private", vec![1, 2, 3]);
        let item = build_item(snap, &b, &IngestOptions::default())
            .unwrap()
            .unwrap();
        assert_eq!(item.kind, ItemKind::Text);
        assert_eq!(item.char_count, Some(md.chars().count() as u32));
        assert!(matches!(&item.payload, PayloadRef::Inline { data } if data == md.as_bytes()));
        let utis: Vec<&str> = item
            .representations
            .iter()
            .map(|r| r.uti.as_str())
            .collect();
        assert_eq!(
            utis,
            vec![UTI_UTF8, UTI_HTML, UTI_RTF, "com.example.private"]
        );
        assert!(matches!(
            &item.representations[3].payload,
            PayloadRef::Inline { data } if data == &vec![1, 2, 3]
        ));
        // Title is derived; payload untouched (leading '#' and newlines kept).
        assert_eq!(item.title, "# Title ⏎");
    }

    #[test]
    fn keep_rich_text_false_keeps_only_essentials() {
        let (_d, b) = blobs();
        let snap = Snapshot::text("x")
            .with(UTI_HTML, "<b>x</b>")
            .with("dyn.abc", vec![0]);
        let opts = IngestOptions {
            keep_rich_text: false,
            ..Default::default()
        };
        let item = build_item(snap, &b, &opts).unwrap().unwrap();
        assert_eq!(item.representations.len(), 1);
        assert_eq!(item.representations[0].uti, UTI_UTF8);
    }

    #[test]
    fn large_text_goes_to_blob_store() {
        let (_d, b) = blobs();
        let big = "x".repeat(100_000);
        let opts = IngestOptions::default();
        let item = build_item(Snapshot::text(&big), &b, &opts)
            .unwrap()
            .unwrap();
        match &item.payload {
            PayloadRef::Blob { hash, size } => {
                assert_eq!(*size, 100_000);
                assert_eq!(b.get(hash).unwrap(), big.as_bytes());
            }
            _ => panic!("expected blob"),
        }
        // The verbatim flavour shares the same content-addressed blob.
        assert_eq!(
            item.representations[0].payload.blob_hash(),
            item.payload.blob_hash()
        );
    }

    #[test]
    fn concealed_and_empty_are_ignored() {
        let (_d, b) = blobs();
        let o = IngestOptions::default();
        let mut s = Snapshot::text("pw");
        s.concealed = true;
        assert!(build_item(s, &b, &o).unwrap().is_none());
        assert!(build_item(Snapshot::text("   "), &b, &o).unwrap().is_none());
        assert!(build_item(Snapshot::default(), &b, &o).unwrap().is_none());
    }

    #[test]
    fn rich_text_with_rendered_tiff_prefers_text() {
        let (_d, b) = blobs();
        let snap = Snapshot::text("A1\tB1")
            .with(UTI_HTML, "<table></table>")
            .with(UTI_TIFF, vec![0; 10]);
        let item = build_item(snap, &b, &IngestOptions::default())
            .unwrap()
            .unwrap();
        assert_eq!(item.kind, ItemKind::Text);
        assert!(item.representations.iter().any(|r| r.uti == UTI_TIFF));
    }

    #[test]
    fn png_snapshot_builds_image_with_thumbnail() {
        let (_d, b) = blobs();
        let img = image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            640,
            480,
            image::Rgba([9, 9, 9, 255]),
        ));
        let png = thumbs::encode_png(&img).unwrap();
        let snap = Snapshot::text("ignored").with(UTI_PNG, png);
        let item = build_item(snap, &b, &IngestOptions::default())
            .unwrap()
            .unwrap();
        assert_eq!(item.kind, ItemKind::Image);
        assert!(item.thumbnail.is_some());
        assert_eq!(item.image.as_ref().unwrap().width, 640);
        assert!(item.title.contains("640 × 480"));
    }

    #[test]
    fn files_snapshot() {
        let (_d, b) = blobs();
        let snap = Snapshot::text("movie.mov")
            .with(UTI_FILE_URL, "file:///tmp/a/movie.mov")
            .with(UTI_FILE_URL, "file:///tmp/b/my%20notes.md");
        let item = build_item(snap, &b, &IngestOptions::default())
            .unwrap()
            .unwrap();
        assert_eq!(item.kind, ItemKind::Files);
        assert_eq!(item.files.len(), 2);
        assert_eq!(item.files[0].media, MediaKind::Video);
        assert_eq!(item.files[1].path, "/tmp/b/my notes.md");
        assert!(item.title.starts_with("2 items"));
        assert_eq!(
            item.representations
                .iter()
                .filter(|r| r.uti == UTI_FILE_URL)
                .count(),
            2
        );
    }

    #[test]
    fn opaque_private_flavors_are_kept() {
        let (_d, b) = blobs();
        let snap = Snapshot::default().with("com.adobe.pdf", vec![b'%', b'P', b'D', b'F']);
        let item = build_item(snap, &b, &IngestOptions::default())
            .unwrap()
            .unwrap();
        assert!(item.title.starts_with("PDF"));
        assert_eq!(item.representations[0].uti, "com.adobe.pdf");
    }
}
