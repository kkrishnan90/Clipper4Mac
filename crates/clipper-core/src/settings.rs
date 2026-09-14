//! User preferences. Persisted as pretty JSON with an atomic write so the
//! file is never left half-written.

use crate::Result;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PopupPosition {
    /// Spotlight-style: top-centre of the screen that has the mouse cursor.
    #[default]
    Center,
    /// At the mouse cursor.
    Cursor,
    /// Anchored under the menu-bar icon.
    Tray,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    #[default]
    System,
    Dark,
    Light,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Global hotkey in `global-hotkey` syntax, e.g. `Cmd+Shift+V`.
    pub hotkey: String,
    /// Maximum number of unpinned items to keep.
    pub max_items: u32,
    /// Paste into the frontmost app right after selecting (needs Accessibility).
    pub paste_on_select: bool,
    /// Strip HTML/RTF flavours when pasting (⇧⏎ toggles per paste).
    pub paste_plain_text: bool,
    pub launch_at_login: bool,
    pub popup_position: PopupPosition,
    pub theme: Theme,
    /// Bundle identifiers whose copies are ignored (password managers, etc.).
    pub ignored_apps: Vec<String>,
    /// How often to poll `NSPasteboard.changeCount` (ms).
    pub poll_interval_ms: u32,
    pub store_images: bool,
    pub store_files: bool,
    pub keep_rich_text: bool,
    /// Hide the popup as soon as it loses focus.
    pub hide_on_blur: bool,
    /// Show the preview pane on the right of the popup.
    pub show_preview: bool,
    /// Play the system "tink" when something is copied to history.
    pub sound_on_copy: bool,
    /// Skip images larger than this many MiB.
    pub max_image_mb: u32,
    /// Show the menu-bar icon.
    pub show_menu_bar_icon: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            hotkey: "Cmd+Shift+V".to_string(),
            max_items: 500,
            paste_on_select: true,
            paste_plain_text: false,
            launch_at_login: false,
            popup_position: PopupPosition::Center,
            theme: Theme::System,
            ignored_apps: vec![
                "com.agilebits.onepassword7".into(),
                "com.1password.1password".into(),
                "com.apple.keychainaccess".into(),
                "com.bitwarden.desktop".into(),
            ],
            poll_interval_ms: 200,
            store_images: true,
            store_files: true,
            keep_rich_text: true,
            hide_on_blur: true,
            show_preview: true,
            sound_on_copy: false,
            max_image_mb: 64,
            show_menu_bar_icon: true,
        }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Settings {
        match std::fs::read_to_string(path) {
            Ok(s) => match serde_json::from_str::<Settings>(&s) {
                Ok(cfg) => cfg.sanitised(),
                Err(e) => {
                    log::warn!("settings.json unreadable ({e}); using defaults");
                    Settings::default()
                }
            },
            Err(_) => Settings::default(),
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    /// Clamp values into sane ranges so a hand-edited file can't wedge the app.
    pub fn sanitised(mut self) -> Settings {
        self.max_items = self.max_items.clamp(10, 10_000);
        self.poll_interval_ms = self.poll_interval_ms.clamp(50, 2_000);
        self.max_image_mb = self.max_image_mb.clamp(1, 512);
        if self.hotkey.trim().is_empty() {
            self.hotkey = Settings::default().hotkey;
        }
        self
    }

    pub fn ingest_options(&self) -> crate::ingest::IngestOptions {
        crate::ingest::IngestOptions {
            store_images: self.store_images,
            store_files: self.store_files,
            keep_rich_text: self.keep_rich_text,
            max_image_bytes: self.max_image_mb as usize * 1024 * 1024,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_load_roundtrip_and_sanitise() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("settings.json");
        let s = Settings {
            max_items: 999_999,
            hotkey: "Cmd+Shift+C".into(),
            ..Default::default()
        };
        s.save(&p).unwrap();
        let loaded = Settings::load(&p);
        assert_eq!(loaded.max_items, 10_000);
        assert_eq!(loaded.hotkey, "Cmd+Shift+C");
    }

    #[test]
    fn partial_json_fills_defaults() {
        let s: Settings = serde_json::from_str(r#"{"hotkey":"Alt+V"}"#).unwrap();
        assert_eq!(s.hotkey, "Alt+V");
        assert_eq!(s.max_items, 500);
    }
}
