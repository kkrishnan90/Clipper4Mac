//! Thin wrapper around UniFFI's binding generator so the exact UniFFI version
//! used by `clipper-ffi` also generates the Swift code (they must match).
//!
//! Usage (from the repo root, after building `clipper-ffi`):
//!
//! ```text
//! cargo run -p uniffi-bindgen -- generate \
//!     target/<triple>/release/libclipper_ffi.dylib \
//!     --language swift --out-dir <dir>
//! ```
fn main() {
    uniffi::uniffi_bindgen_main()
}
