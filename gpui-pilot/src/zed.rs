//! Zed's own views, run outside Zed. Its terminal and editor read their
//! settings, theme and fonts from globals Zed sets up at launch, so the
//! same ones are set up here, from Zed's built-in defaults: the pilot
//! reads no Zed settings file of the user's.

use gpui::{App, KeyBinding};

pub fn init(cx: &mut App) {
    release_channel::init(release_channel::AppVersion::load(env!("CARGO_PKG_VERSION"), None, None), cx);
    settings::init(cx);
    theme_settings::init(theme::LoadThemes::All(Box::new(assets::Assets)), cx);
    // Zed's monospace and UI fonts, which its default settings name.
    assets::Assets.load_fonts(cx).ok();
    editor::init(cx);
    terminal_view::init(cx);
    cx.bind_keys(terminal_and_editor_keys(cx));
}

/// Zed's default macOS bindings for its terminal and editor only. The rest
/// (panes, docks, the workspace) name actions nothing here handles, and
/// the shell's own bindings must win for Command-W and the like.
fn terminal_and_editor_keys(cx: &App) -> Vec<KeyBinding> {
    let Ok(content) = settings::KeymapFile::load_asset_allow_partial_failure(settings::DEFAULT_KEYMAP_PATH, cx) else {
        return Vec::new();
    };
    content
        .into_iter()
        .filter(|binding| {
            binding.predicate().is_some_and(|predicate| {
                let text = predicate.to_string();
                (text.contains("Terminal") || text.starts_with("Editor")) && !text.contains("Workspace") && !text.contains("Pane")
            })
        })
        .collect()
}

/// Follows the system's light or dark appearance, as Zed's workspace does.
pub fn follow_appearance(window: &gpui::Window, cx: &mut App) {
    *theme::SystemAppearance::global_mut(cx) = theme::SystemAppearance(window.appearance().into());
    theme_settings::reload_theme(cx);
}
