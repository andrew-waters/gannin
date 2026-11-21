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
/// Merged: a branch joining the line it came from.
pub const MERGE: &str = "icons/gannin_merge.svg";
/// A note: a page of text (Zed's).
pub const NOTE: &str = "icons/file_text_outlined.svg";

const OWN: &[(&str, &str)] = &[
    (
        ISSUE,
        r#"<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="5" stroke="black" stroke-width="1.2"/><circle cx="8" cy="8" r="1.3" fill="black"/></svg>"#,
    ),
    (
        MERGE,
        r#"<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><g stroke="black" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="9" r="1.5"/><path d="M4.5 5v6M4.5 5c0 2.2 1.8 4 4 4H10"/></g></svg>"#,
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
