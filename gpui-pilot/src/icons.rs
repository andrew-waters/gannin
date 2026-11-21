//! The app's assets: Zed's, with a few icons of our own in front for what
//! Zed's set has no shape for (an issue), drawn in the same 16px, 1.2
//! stroke style so they sit beside Zed's.

use gpui::{AssetSource, SharedString};
use std::borrow::Cow;

/// An open issue: a ring with a dot, as issues are drawn everywhere.
pub const ISSUE: &str = "icons/gannin_issue.svg";
/// A closed issue: a ring with a tick (Zed's).
pub const ISSUE_CLOSED: &str = "icons/todo_complete.svg";
pub const PULL: &str = "icons/pull_request.svg";
/// Merged: GitHub's git-merge mark (Octicons, MIT), a branch joining
/// the line it came from.
pub const MERGE: &str = "icons/gannin_merge.svg";
/// Tabs down a column on the left: a window with its left strip filled.
pub const TABS_LEFT: &str = "icons/gannin_tabs_left.svg";
/// Tabs across the top: a window with its top strip filled.
pub const TABS_TOP: &str = "icons/gannin_tabs_top.svg";
/// A note: a page of text (Zed's).
pub const NOTE: &str = "icons/file_text_outlined.svg";

const OWN: &[(&str, &str)] = &[
    (
        TABS_LEFT,
        r#"<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="3" width="12" height="10" rx="1.5" stroke="black" stroke-width="1.2"/><rect x="2.6" y="3.6" width="3.9" height="8.8" rx="0.9" fill="black"/></svg>"#,
    ),
    (
        TABS_TOP,
        r#"<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="2" y="3" width="12" height="10" rx="1.5" stroke="black" stroke-width="1.2"/><rect x="2.6" y="3.6" width="10.8" height="2.8" rx="0.9" fill="black"/></svg>"#,
    ),
    (
        ISSUE,
        r#"<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="5" stroke="black" stroke-width="1.2"/><circle cx="8" cy="8" r="1.3" fill="black"/></svg>"#,
    ),
    (
        MERGE,
        r#"<svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"><path fill="black" d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Z"/></svg>"#,
    ),
];

/// An issue's icon by whether it's open.
pub fn issue(open: bool) -> &'static str {
    if open { ISSUE } else { ISSUE_CLOSED }
}

pub struct Assets;

impl AssetSource for Assets {
    fn load(&self, path: &str) -> anyhow::Result<Option<Cow<'static, [u8]>>> {
        match OWN.iter().find(|(p, _)| *p == path) {
            Some((_, svg)) => Ok(Some(Cow::Borrowed(svg.as_bytes()))),
            None => assets::Assets.load(path),
        }
    }

    fn list(&self, path: &str) -> anyhow::Result<Vec<SharedString>> {
        let mut found = assets::Assets.list(path)?;
        found.extend(OWN.iter().filter(|(p, _)| p.starts_with(path)).map(|(p, _)| SharedString::from(*p)));
        Ok(found)
    }
}
