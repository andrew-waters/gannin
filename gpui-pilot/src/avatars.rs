//! GitHub avatars, drawn from files. GPUI loads images from a URL only
//! through an HTTP client the app provides, which the pilot doesn't have,
//! so each avatar is downloaded once with the system's `curl` into the
//! pilot's own cache and drawn from there. Until it arrives, the person's
//! initial stands in.

use crate::charts::Theme;
use gpui::{div, img, prelude::*, px, AnyElement, App, Hsla};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

fn folder() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Caches/GanninGPUIPilot/avatars")
}

fn file(login: &str) -> PathBuf {
    let safe: String = login.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    folder().join(format!("{safe}.png"))
}

/// Logins being fetched, so each is asked for once.
static FETCHING: Mutex<Option<HashSet<String>>> = Mutex::new(None);

/// The avatar's file once it's here; until then, starts fetching it.
fn path(login: &str, url: Option<&str>, cx: &mut App) -> Option<PathBuf> {
    let file = file(login);
    if file.exists() {
        return Some(file);
    }
    {
        let mut fetching = FETCHING.lock().ok()?;
        if !fetching.get_or_insert_with(HashSet::new).insert(login.to_string()) {
            return None;
        }
    }
    // The URL the store has, at a small size; else GitHub's by login.
    let source = match url {
        Some(url) => format!("{url}{}s=64", if url.contains('?') { "&" } else { "?" }),
        None => format!("https://github.com/{login}.png?size=64"),
    };
    let target = file.clone();
    let task = cx.background_executor().spawn(async move {
        let _ = std::fs::create_dir_all(folder());
        let partial = target.with_extension("part");
        let fetched = std::process::Command::new("/usr/bin/curl")
            .args(["-sSfL", "--max-time", "15", "-o"])
            .arg(&partial)
            .arg(&source)
            .status()
            .is_ok_and(|s| s.success());
        fetched && std::fs::rename(&partial, &target).is_ok()
    });
    cx.spawn(async move |cx| {
        if task.await {
            cx.update(|cx| cx.refresh_windows());
        }
    })
    .detach();
    None
}

/// A round avatar, or the person's initial while it loads.
pub fn avatar(login: &str, url: Option<&str>, size: f32, theme: &Theme, cx: &mut App) -> AnyElement {
    match path(login, url, cx) {
        Some(file) => img(file).size(px(size)).flex_none().rounded_full().into_any_element(),
        None => {
            let initial = login.chars().next().map(|c| c.to_ascii_uppercase().to_string()).unwrap_or_default();
            div()
                .size(px(size))
                .flex_none()
                .rounded_full()
                .bg(theme.row_selected)
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(size * 0.55))
                .text_color(theme.secondary)
                .child(initial)
                .into_any_element()
        }
    }
}

/// Several avatars overlapping a little, as `AvatarStack`.
pub fn stack(people: &[(String, Option<String>)], size: f32, theme: &Theme, cx: &mut App) -> AnyElement {
    let ring: Hsla = theme.bg;
    div()
        .flex()
        .flex_row()
        .children(people.iter().take(5).enumerate().map(|(i, (login, url))| {
            div()
                .when(i > 0, |d| d.ml(px(-size * 0.3)))
                .rounded_full()
                .border_1()
                .border_color(ring)
                .child(avatar(login, url.as_deref(), size, theme, cx))
        }))
        .when(people.len() > 5, |d| {
            d.child(div().ml_1().text_xs().text_color(theme.secondary).child(format!("+{}", people.len() - 5)))
        })
        .into_any_element()
}
