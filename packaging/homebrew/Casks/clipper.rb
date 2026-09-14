# Homebrew cask for Clipper.
#
# Lives in the tap repo `kkrishnan90/homebrew-clipper` at `Casks/clipper.rb`
# (this copy in the app repo is the source of truth; the release workflow
# pushes it to the tap with the version/sha256 filled in).
#
#   brew install --cask kkrishnan90/clipper/clipper
#
cask "clipper" do
  version "0.2.0"
  sha256 "REPLACED_BY_RELEASE_WORKFLOW"

  url "https://github.com/kkrishnan90/Clipper4Mac/releases/download/v#{version}/Clipper-#{version}.dmg",
      verified: "github.com/kkrishnan90/Clipper4Mac/"
  name "Clipper"
  desc "Native menu-bar clipboard manager with a Rust storage engine"
  homepage "https://github.com/kkrishnan90/Clipper4Mac"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"

  app "Clipper.app"

  # The DMG is ad-hoc signed (no Apple Developer ID yet), so Gatekeeper would
  # otherwise refuse to open it. Stripping the quarantine attribute is what
  # `xattr -cr` in the README does, automated.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/Clipper.app"],
                   sudo: false
  end

  uninstall quit:       "com.kkrishnan90.clipper",
            launchctl:  "com.kkrishnan90.clipper"

  zap trash: [
    "~/Library/Application Support/Clipper",
    "~/Library/Caches/com.kkrishnan90.clipper",
    "~/Library/HTTPStorages/com.kkrishnan90.clipper",
    "~/Library/Preferences/com.kkrishnan90.clipper.plist",
    "~/Library/Saved Application State/com.kkrishnan90.clipper.savedState",
  ]

  caveats <<~EOS
    Clipper lives in the menu bar. Press ⇧⌘V to open it (change it in Preferences).

    To let Clipper paste directly into other apps, grant it Accessibility
    access the first time it asks:
      System Settings → Privacy & Security → Accessibility → Clipper
  EOS
end
