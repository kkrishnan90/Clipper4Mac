#!/usr/bin/env bash
# Build Clipper locally and install it through Homebrew, without a published
# release. Creates a *local* tap named kkrishnan90/clipper (same name as the
# future GitHub tap) whose cask points at the local DMG via file://, so the
# install command is identical to the public one:
#
#   brew install --cask kkrishnan90/clipper/clipper
#
#   scripts/brew-local.sh                # build DMG (native arch) → brew install
#   scripts/brew-local.sh --skip-build   # reuse dist/Clipper-<v>.dmg
#
# `brew uninstall|reinstall|zap --cask clipper` work as usual. To switch to the
# published tap later: `brew untap kkrishnan90/clipper` then install again.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
[[ "${1:-}" == "--skip-build" ]] || scripts/build-macos.sh --dmg

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -n1)
DMG="$PWD/dist/Clipper-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "missing $DMG"; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

TAP=kkrishnan90/clipper
TAP_DIR="$(brew --repository)/Library/Taps/kkrishnan90/homebrew-clipper"
if [[ ! -d "$TAP_DIR" ]]; then
  echo "▸ brew tap-new $TAP (local)"
  brew tap-new --no-git "$TAP" >/dev/null
elif [[ -d "$TAP_DIR/.git" ]] && git -C "$TAP_DIR" remote get-url origin 2>/dev/null | grep -q github.com; then
  echo "$TAP is the published GitHub tap; run 'brew untap $TAP' first to use a local build."; exit 1
fi
mkdir -p "$TAP_DIR/Casks"
sed -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
    -e "s|^  url \".*\",\$|  url \"file://${DMG}\"|" \
    -e '/^      verified: /d' \
    -e '/^  livecheck do/,/^  end/d' \
    packaging/homebrew/Casks/clipper.rb > "$TAP_DIR/Casks/clipper.rb"

echo "▸ brew install --cask $TAP/clipper"
brew uninstall --cask clipper >/dev/null 2>&1 || true
brew install --cask "$TAP/clipper"
open -a Clipper
echo "✓ installed via Homebrew (local tap $TAP). Manage with: brew {list|reinstall|uninstall|zap} --cask clipper"
