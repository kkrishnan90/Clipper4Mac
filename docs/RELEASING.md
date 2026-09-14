# Releasing Clipper

## One-time setup

1. Create the GitHub repos:
   - `kkrishnan90/Clipper4Mac` – this code.
   - `kkrishnan90/homebrew-clipper4mac` – the tap. It only needs `Casks/clipper4mac.rb`
     (copy `packaging/homebrew/Casks/clipper4mac.rb` there for the first release;
     the workflow keeps it updated afterwards).
2. In `kkrishnan90/Clipper4Mac` → Settings → Secrets → Actions, add
   `HOMEBREW_TAP_TOKEN`: a fine-grained PAT with **Contents: Read & write** on
   `homebrew-clipper4mac` only.
3. (Optional – removes the `xattr -cr` step and the Accessibility re-prompt on
   every update.) Apple Developer ID: export your *Developer ID Application*
   certificate as `.p12`, then add `APPLE_CERTIFICATE` (base64 of the p12),
   `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD` (anything),
   `APPLE_SIGNING_IDENTITY` (`Developer ID Application: Your Name (TEAMID)`),
   `APPLE_ID`, `APPLE_APP_PASSWORD` (app-specific password), `APPLE_TEAM_ID`.
   `scripts/build-macos.sh` signs with the hardened runtime and notarises via
   `notarytool` when these exist.

## Shipping a version

```sh
# 1. bump (workspace.package.version is the single source of truth)
sed -i '' 's/^version = ".*"/version = "0.2.1"/' Cargo.toml
cargo update -w            # refresh Cargo.lock
git commit -am "v0.2.1"

# 2. tag → CI does the rest
git tag v0.2.1 && git push && git push origin v0.2.1
```

The **Release** workflow then:

1. runs the engine tests,
2. builds `Clipper-0.2.1.dmg` (arm64 + x86_64) on `macos-15` / Xcode 16.2,
3. creates GitHub Release `v0.2.1` with the DMG attached,
4. computes the sha256 and pushes an updated `Casks/clipper4mac.rb` to the tap.

Users get it with `brew upgrade --cask clipper4mac`.

## Local build (no CI)

Requirements: macOS 14+, Xcode 16.0+ (`xcode-select --install` is not enough –
SwiftPM needs the full Xcode toolchain), Rust (`rustup`), ImageMagick for the
icon (`brew install imagemagick`, optional).

```sh
scripts/gen-icons.sh                       # once: macos/Resources/AppIcon.icns
scripts/build-macos.sh --install           # native arch → /Applications/Clipper.app, launches it
scripts/build-macos.sh --universal --dmg   # what CI runs → dist/Clipper-<v>.dmg
scripts/build-macos.sh --debug             # fast iteration; app in dist/
```

> **Accessibility permission and ad-hoc signing.** macOS ties the
> Accessibility grant to the app's code signature. Ad-hoc signatures (`-`)
> change on every build, so a rebuilt Clipper will ask again. For day-to-day
> development create a self-signed "Code Signing" certificate in Keychain
> Access (e.g. `Clipper Dev`) and export `CODESIGN_IDENTITY="Clipper Dev"`;
> the grant then survives rebuilds.

To publish a local DMG manually: upload it to a GitHub Release named
`v<version>`, then in the tap set `version` and `sha256`
(`shasum -a 256 dist/Clipper-<v>.dmg`) in `Casks/clipper4mac.rb`.

## Testing the cask before publishing

```sh
brew install --cask ./packaging/homebrew/Casks/clipper4mac.rb   # after filling in sha256
brew audit --cask --strict clipper
brew style packaging/homebrew/Casks/clipper4mac.rb
```

## Checking from Linux

There is no Swift toolchain on Linux for AppKit, but everything below the FFI
line can be verified:

```sh
cargo test --workspace                       # engine + FFI façade tests
scripts/check-macos-on-linux.sh clippy       # cross-check the darwin target
scripts/check-macos-on-linux.sh bindings     # regenerate and read ClipperCore.swift
```

## Regenerating the architecture diagram

`docs/img/architecture.png` is rendered from `docs/img/architecture.mmd`:

```sh
curl -sf -o docs/img/architecture.png -H 'Content-Type: text/plain' \
  --data-binary @docs/img/architecture.mmd https://kroki.io/mermaid/png
```
