//! Thumbnail generation and image normalisation.

use crate::model::ImageMeta;
use crate::Result;
use image::{DynamicImage, ImageFormat, ImageReader};
use std::io::Cursor;

/// Longest edge of generated thumbnails, in pixels.
pub const THUMB_EDGE: u32 = 320;

pub struct Decoded {
    pub image: DynamicImage,
    pub format: ImageFormat,
}

pub fn decode(bytes: &[u8], hint: Option<ImageFormat>) -> Result<Decoded> {
    let mut reader = ImageReader::new(Cursor::new(bytes));
    match hint {
        Some(f) => reader.set_format(f),
        None => reader = reader.with_guessed_format()?,
    }
    let format = reader.format().unwrap_or(ImageFormat::Png);
    // Guard against decompression bombs: refuse > 512 MP.
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(32_768);
    limits.max_image_height = Some(32_768);
    limits.max_alloc = Some(1024 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode()?;
    Ok(Decoded { image, format })
}

pub fn encode_png(img: &DynamicImage) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), ImageFormat::Png)?;
    Ok(out)
}

/// Produces a PNG thumbnail whose longest edge is `THUMB_EDGE`.
pub fn thumbnail_png(img: &DynamicImage) -> Result<Vec<u8>> {
    let t = if img.width() > THUMB_EDGE || img.height() > THUMB_EDGE {
        img.thumbnail(THUMB_EDGE, THUMB_EDGE)
    } else {
        img.clone()
    };
    encode_png(&t)
}

pub fn meta_of(img: &DynamicImage, format: ImageFormat) -> ImageMeta {
    ImageMeta::new(img.width(), img.height(), format_name(format))
}

/// Re-encodes PNG bytes as TIFF (for apps that only accept `public.tiff`).
pub fn png_to_tiff(png: &[u8]) -> Result<Vec<u8>> {
    let d = decode(png, Some(ImageFormat::Png))?;
    let mut out = Vec::new();
    d.image
        .write_to(&mut Cursor::new(&mut out), ImageFormat::Tiff)?;
    Ok(out)
}

pub fn format_name(f: ImageFormat) -> &'static str {
    match f {
        ImageFormat::Png => "png",
        ImageFormat::Jpeg => "jpeg",
        ImageFormat::Gif => "gif",
        ImageFormat::WebP => "webp",
        ImageFormat::Tiff => "tiff",
        ImageFormat::Bmp => "bmp",
        _ => "image",
    }
}

/// Reads an image file from disk (bounded) and returns a thumbnail + meta.
pub fn thumbnail_from_file(path: &str, max_bytes: u64) -> Option<(Vec<u8>, ImageMeta)> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > max_bytes {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    let decoded = decode(&bytes, None).ok()?;
    let thumb = thumbnail_png(&decoded.image).ok()?;
    Some((thumb, meta_of(&decoded.image, decoded.format)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn sample(w: u32, h: u32) -> Vec<u8> {
        let img = RgbaImage::from_pixel(w, h, Rgba([200, 40, 90, 255]));
        encode_png(&DynamicImage::ImageRgba8(img)).unwrap()
    }

    #[test]
    fn thumbnail_is_bounded() {
        let png = sample(1600, 900);
        let d = decode(&png, None).unwrap();
        let t = thumbnail_png(&d.image).unwrap();
        let td = decode(&t, Some(ImageFormat::Png)).unwrap();
        assert!(td.image.width() <= THUMB_EDGE && td.image.height() <= THUMB_EDGE);
        assert_eq!(meta_of(&d.image, d.format).width, 1600);
    }

    #[test]
    fn tiff_roundtrips_to_png() {
        let img = DynamicImage::ImageRgba8(RgbaImage::from_pixel(8, 8, Rgba([1, 2, 3, 255])));
        let mut tiff = Vec::new();
        img.write_to(&mut Cursor::new(&mut tiff), ImageFormat::Tiff)
            .unwrap();
        let d = decode(&tiff, Some(ImageFormat::Tiff)).unwrap();
        assert_eq!(d.format, ImageFormat::Tiff);
        let png = encode_png(&d.image).unwrap();
        assert_eq!(&png[..4], b"\x89PNG");
    }
}
