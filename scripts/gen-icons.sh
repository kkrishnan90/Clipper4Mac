#!/usr/bin/env bash
# Rasterises assets/icon.svg into macos/Resources/AppIcon.icns.
# Requires ImageMagick 7 (`brew install imagemagick`). Uses Apple's iconutil
# when available (macOS) and falls back to scripts/make_icns.py elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=macos/Resources/AppIcon.icns
mkdir -p macos/Resources

if command -v magick >/dev/null 2>&1; then IM=magick; else IM=convert; fi
render() { # render <size> <out>  (clipped to the squircle mask)
  local m; m=$(mktemp).png
  "$IM" -background black -density 384 assets/icon-mask.svg -resize "$1x$1" -colorspace gray -depth 8 "$m"
  "$IM" -background none -density 384 assets/icon.svg -resize "$1x$1" "$m" -alpha off -compose CopyOpacity -composite -depth 8 -strip "$2"
  rm -f "$m"
}

tmp=$(mktemp -d)
if command -v iconutil >/dev/null 2>&1; then
  set="$tmp/AppIcon.iconset"; mkdir -p "$set"
  for s in 16 32 128 256 512; do
    render "$s" "$set/icon_${s}x${s}.png"
    render "$((s*2))" "$set/icon_${s}x${s}@2x.png"
  done
  iconutil -c icns "$set" -o "$OUT"
else
  for s in 16 32 64 128 256 512 1024; do render "$s" "$tmp/$s.png"; done
  python3 scripts/make_icns.py "$OUT" \
    16="$tmp/16.png" 32="$tmp/32.png" 64="$tmp/64.png" 128="$tmp/128.png" \
    256="$tmp/256.png" 512="$tmp/512.png" 1024="$tmp/1024.png"
fi
rm -rf "$tmp"
echo "✓ $OUT"
