#!/usr/bin/env bash
# Type-check / lint the *macOS* build of the Rust engine from a Linux box
# (e.g. a CI runner) without an Apple SDK. `cargo check` never links, and the
# only C code in the graph (blake3's assembly is opt-out'd, ring etc. are not
# used) compiles with the fake cc shim. Requires clang + rustup.
#
#   ./scripts/check-macos-on-linux.sh            # cargo check
#   ./scripts/check-macos-on-linux.sh clippy     # cargo clippy -D warnings
#   ./scripts/check-macos-on-linux.sh bindings   # regenerate Swift bindings from the Linux .so
set -euo pipefail
cd "$(dirname "$0")/.."
rustup target add aarch64-apple-darwin >/dev/null
export CC_aarch64_apple_darwin="$PWD/scripts/linux/fakecc"
export CXX_aarch64_apple_darwin="$PWD/scripts/linux/fakecc"
export AR_aarch64_apple_darwin="$(command -v ar)"
PKGS=(-p clipper-core -p clipper-ffi -p uniffi-bindgen)
case "${1:-check}" in
  check)  cargo check  "${PKGS[@]}" --target aarch64-apple-darwin --all-targets --features clipper-ffi/oslog ;;
  clippy) cargo clippy "${PKGS[@]}" --target aarch64-apple-darwin --all-targets --features clipper-ffi/oslog -- -D warnings ;;
  bindings)
    # UniFFI metadata is architecture-independent, so the host build is enough
    # to inspect the generated Swift API.
    cargo build -p clipper-ffi
    out=${2:-/tmp/clipper-bindings}
    rm -rf "$out"
    cargo run -q -p uniffi-bindgen -- generate "target/debug/libclipper_ffi.so" \
      --language swift --out-dir "$out" --no-format
    echo "→ $out"; ls -la "$out" ;;
  *) echo "usage: $0 [check|clippy|bindings [out-dir]]"; exit 2 ;;
esac
