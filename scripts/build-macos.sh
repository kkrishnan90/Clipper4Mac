#!/usr/bin/env bash
# Builds Clipper.app (and optionally a .dmg) on macOS.
#
#   scripts/build-macos.sh                  # release, native arch → dist/Clipper.app
#   scripts/build-macos.sh --universal      # arm64 + x86_64 (slower)
#   scripts/build-macos.sh --dmg            # …plus dist/Clipper-<version>.dmg
#   scripts/build-macos.sh --debug          # swift build -c debug (fast iteration)
#   scripts/build-macos.sh --install        # copy into /Applications and launch
#
# Pipeline
#   1. cargo build -p clipper-ffi (staticlib) per target, lipo'd into macos/Libs/
#   2. cargo run -p uniffi-bindgen → macos/Sources/{ClipperCore,ClipperCoreFFI/include}
#   3. swift build (SwiftPM) in macos/
#   4. Assemble the .app bundle, copy resource bundles, sign, (dmg)
#
# Env: CODESIGN_IDENTITY  – "Developer ID Application: …" (default: ad-hoc "-")
#      NOTARY_PROFILE     – keychain profile for `xcrun notarytool` (optional)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

[[ "$(uname)" == "Darwin" ]] || { echo "This script must run on macOS."; exit 1; }
command -v cargo >/dev/null || { echo "Install Rust first: https://rustup.rs"; exit 1; }
command -v swift >/dev/null || { echo "Install Xcode 16 or newer (swift-tools 5.11 is required by KeyboardShortcuts 2.3)."; exit 1; }

UNIVERSAL=0; DMG=0; CONFIG=release; INSTALL=0
for a in "$@"; do
  case "$a" in
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1 ;;
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    *) echo "unknown flag $a"; exit 2 ;;
  esac
done

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n1)
BUILD=$(date +%Y%m%d%H%M)
HOST_ARCH=$(uname -m)
[[ $HOST_ARCH == arm64 ]] && HOST_TRIPLE=aarch64-apple-darwin || HOST_TRIPLE=x86_64-apple-darwin
if [[ $UNIVERSAL == 1 ]]; then
  TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin)
else
  TRIPLES=("$HOST_TRIPLE")
fi
CARGO_PROFILE_FLAG=(); [[ $CONFIG == release ]] && CARGO_PROFILE_FLAG=(--release)
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}

echo "▸ Rust engine ($CONFIG) for: ${TRIPLES[*]}"
LIBS=()
for t in "${TRIPLES[@]}"; do
  rustup target add "$t" >/dev/null
  cargo build -p clipper-ffi ${CARGO_PROFILE_FLAG[@]+"${CARGO_PROFILE_FLAG[@]}"} --target "$t"
  LIBS+=("$CARGO_TARGET_DIR/$t/$CONFIG/libclipper_ffi.a")
done
mkdir -p macos/Libs
if [[ ${#LIBS[@]} -gt 1 ]]; then
  lipo -create "${LIBS[@]}" -output macos/Libs/libclipper_ffi.a
else
  cp "${LIBS[0]}" macos/Libs/libclipper_ffi.a
fi

echo "▸ Swift bindings (uniffi-bindgen $(cargo run -q -p uniffi-bindgen -- --version 2>/dev/null | head -n1))"
GEN=$(mktemp -d)
# Library mode reads crates/clipper-ffi/uniffi.toml automatically.
cargo run -q -p uniffi-bindgen -- generate \
  "$CARGO_TARGET_DIR/${TRIPLES[0]}/$CONFIG/libclipper_ffi.dylib" \
  --language swift --out-dir "$GEN" --no-format
install -m 644 "$GEN/ClipperCore.swift"    macos/Sources/ClipperCore/ClipperCore.swift
install -m 644 "$GEN/ClipperCoreFFI.h"     macos/Sources/ClipperCoreFFI/include/ClipperCoreFFI.h
# SwiftPM synthesises the module map for a C target; the generated one is not needed.
rm -rf "$GEN"

echo "▸ swift build -c $CONFIG"
pushd macos >/dev/null
SWIFT_ARCH_FLAGS=()
if [[ $UNIVERSAL == 1 ]]; then SWIFT_ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
# ${arr[@]+"${arr[@]}"}: empty arrays trip `set -u` on macOS's bash 3.2.
swift build -c "$CONFIG" ${SWIFT_ARCH_FLAGS[@]+"${SWIFT_ARCH_FLAGS[@]}"}
BIN_DIR=$(swift build -c "$CONFIG" ${SWIFT_ARCH_FLAGS[@]+"${SWIFT_ARCH_FLAGS[@]}"} --show-bin-path)
popd >/dev/null

echo "▸ assembling Clipper.app"
APP=dist/Clipper.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Clipper" "$APP/Contents/MacOS/Clipper"
# SwiftPM resource bundles (KeyboardShortcuts localisations) must sit next to
# the executable's Resources or Bundle.module traps at runtime.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" macos/Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f macos/Resources/AppIcon.icns ]]; then
  cp macos/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  (no macos/Resources/AppIcon.icns – run scripts/gen-icons.sh; using generic icon)"
fi

IDENTITY=${CODESIGN_IDENTITY:--}
echo "▸ codesign ($IDENTITY)"
# Hardened runtime is required for notarisation; harmless for ad-hoc.
find "$APP/Contents/Resources" -name '*.bundle' -exec codesign --force --options runtime -s "$IDENTITY" {} \;
codesign --force --options runtime --entitlements macos/Resources/Clipper.entitlements -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ $APP  (v$VERSION, $(lipo -archs "$APP/Contents/MacOS/Clipper"))"

if [[ $DMG == 1 ]]; then
  DMG_PATH="dist/Clipper-$VERSION.dmg"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Clipper" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
  rm -rf "$STAGE"
  if [[ $IDENTITY != "-" ]]; then
    codesign --force -s "$IDENTITY" "$DMG_PATH"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      echo "▸ notarizing"
      xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG_PATH"
    fi
  fi
  echo "✓ $DMG_PATH"
  echo "  sha256: $(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
fi

if [[ $INSTALL == 1 ]]; then
  echo "▸ installing to /Applications"
  osascript -e 'tell application "Clipper" to quit' 2>/dev/null || true
  rm -rf /Applications/Clipper.app
  cp -R "$APP" /Applications/Clipper.app
  chmod -R u+w /Applications/Clipper.app
  [[ $IDENTITY == "-" ]] && xattr -cr /Applications/Clipper.app
  open /Applications/Clipper.app
  echo "✓ Clipper is in your menu bar. Press ⇧⌘V."
  if [[ $IDENTITY == "-" ]]; then
    echo "  Note: ad-hoc signatures change on every build, so macOS will ask for the"
    echo "  Accessibility permission again after each reinstall. Use a stable"
    echo "  CODESIGN_IDENTITY (self-signed cert or Developer ID) to avoid that."
  fi
fi
