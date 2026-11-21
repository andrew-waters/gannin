//! Issues and pull requests the person has starred, by node ID, kept at the
//! top of their lists whatever the sort and filters. One set for every
//! window, org and tab, in `~/.gannin/stars.json`; node IDs are unique across
//! GitHub, so issues and pull requests share it.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

static STARS: Mutex<Option<BTreeSet<String>>> = Mutex::new(None);
/// Bumped on every change, so a page drawn from an older set refilters.
static GENERATION: AtomicU64 = AtomicU64::new(1);

fn path() -> PathBuf {
    crate::paths::app_dir().join("stars.json")
}

fn with<T>(f: impl FnOnce(&mut BTreeSet<String>) -> T) -> T {
    let mut guard = STARS.lock().unwrap_or_else(|e| e.into_inner());
    let stars = guard.get_or_insert_with(|| std::fs::read(path()).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default());
    f(stars)
}

pub fn is_starred(id: &str) -> bool {
    with(|stars| stars.contains(id))
}

/// Stars it, or takes its star off, and saves.
pub fn toggle(id: &str) {
    let json = with(|stars| {
        if !stars.remove(id) {
            stars.insert(id.to_string());
        }
        serde_json::to_vec_pretty(stars).ok()
    });
    GENERATION.fetch_add(1, Ordering::Relaxed);
    if let Some(json) = json {
        let _ = std::fs::create_dir_all(crate::paths::app_dir());
        let _ = std::fs::write(path(), json);
    }
}

pub fn generation() -> u64 {
    GENERATION.load(Ordering::Relaxed)
}

/// The star at a row's leading edge: filled when starred, otherwise hollow
/// and shown only while the row (a `group("row")`) is hovered.
pub fn star_button(id: gpui::ElementId, starred: bool, theme: &crate::charts::Theme) -> gpui::Stateful<gpui::Div> {
    use gpui::{InteractiveElement, ParentElement, Styled, div, prelude::FluentBuilder, px};
    let color = theme.star();
    let faint = theme.tertiary;
    div()
        .id(id)
        .flex_none()
        .w(px(18.))
        .h(px(18.))
        .flex()
        .items_center()
        .justify_center()
        .rounded_sm()
        .cursor_pointer()
        .text_sm()
        .when_else(starred, |d| d.text_color(color).child("★"), |d| d.text_color(faint.opacity(0.)).group_hover("row", move |s| s.text_color(faint)).hover(move |s| s.text_color(color)).child("☆"))
}

/// Starred rows' wash, and the line under the last of them.
pub fn pinned_tint(theme: &crate::charts::Theme) -> gpui::Hsla {
    theme.star().opacity(if theme.dark { 0.08 } else { 0.07 })
}

pub fn pinned_edge(theme: &crate::charts::Theme) -> gpui::Hsla {
    theme.star().opacity(0.55)
}
