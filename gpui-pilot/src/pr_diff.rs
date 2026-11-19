//! One file of a pull request in Zed's diff view, for a review's file
//! detail: the file at the PR's merge base against its head, its hunks
//! shown inline, as a session's Changes shows them (`changes::add_file_diff`).
//!
//! Read from GitHub off the main thread: the merge base once per PR and
//! head (REST compare, as GitHub's own diff is against it), then the file's
//! text on each side (one GraphQL query). An added file has no base and a
//! deleted one no head. Read only.

use crate::charts::Theme;
use editor::{Editor, EditorMode};
use gpui::{div, prelude::*, Context, Entity, Window};
use language::Capability;
use multi_buffer::MultiBuffer;
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// Each PR's merge base and head, by "owner/repo#123" and head, so going
/// through a review's files asks GitHub once.
fn bases() -> &'static Mutex<HashMap<String, (String, String)>> {
    static BASES: OnceLock<Mutex<HashMap<String, (String, String)>>> = OnceLock::new();
    BASES.get_or_init(Default::default)
}

/// The merge base and head commits. Blocking.
fn commits(token: &str, repo: &str, number: i64) -> Result<(String, String), String> {
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let data = crate::github::graphql(
        token,
        "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { baseRefOid headRefOid } } }",
        json!({ "owner": owner, "name": name, "number": number }),
    )
    .map_err(|e| e.to_string())?;
    let pr = &data["repository"]["pullRequest"];
    let (base, head) = (pr["baseRefOid"].as_str().unwrap_or_default().to_string(), pr["headRefOid"].as_str().unwrap_or_default().to_string());
    let key = format!("{repo}#{number}");
    if let Some(found) = bases().lock().ok().and_then(|b| b.get(&key).cloned()).filter(|(_, h)| *h == head) {
        return Ok(found);
    }
    // GitHub diffs against where the branch left its base, not the base's tip.
    let compare = crate::github::rest_get(token, &format!("repos/{repo}/compare/{base}...{head}")).map_err(|(_, e)| e)?;
    let merge_base = compare["merge_base_commit"]["sha"].as_str().unwrap_or(&base).to_string();
    if let Ok(mut b) = bases().lock() {
        b.insert(key, (merge_base.clone(), head.clone()));
    }
    Ok((merge_base, head))
}

/// The file's text at the merge base and at the head; empty on a side it
/// isn't. Blocking.
fn read(repo: &str, number: i64, path: &str) -> Result<(String, String), String> {
    let token = crate::auth::token().ok_or("Sign in to read the diff.")?;
    let (base, head) = commits(&token, repo, number)?;
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let data = crate::github::graphql(
        &token,
        "query($owner: String!, $name: String!, $base: String!, $head: String!) { repository(owner: $owner, name: $name) { base: object(expression: $base) { ... on Blob { text isBinary } } head: object(expression: $head) { ... on Blob { text isBinary } } } }",
        json!({ "owner": owner, "name": name, "base": format!("{base}:{path}"), "head": format!("{head}:{path}") }),
    )
    .map_err(|e| e.to_string())?;
    let repo = &data["repository"];
    if repo["base"]["isBinary"] == true || repo["head"]["isBinary"] == true {
        return Err("A binary file: no diff to show.".into());
    }
    let side = |key: &str| repo[key]["text"].as_str().unwrap_or_default().to_string();
    Ok((side("base"), side("head")))
}

enum State {
    Loading,
    Ready,
    Failed(String),
}

pub struct PrDiff {
    editor: Entity<Editor>,
    state: State,
}

impl PrDiff {
    pub fn new(repo: String, number: i64, path: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let multibuffer = cx.new(|_| MultiBuffer::new(Capability::ReadOnly));
        let editor = cx.new(|cx| {
            let mut editor = Editor::new(EditorMode::full(), multibuffer.clone(), None, window, cx);
            editor.set_read_only(true);
            editor.set_expand_all_diff_hunks(cx);
            editor
        });
        cx.spawn(async move |this, cx| {
            let (repo_for_read, path_for_read) = (repo.clone(), path.clone());
            let found = cx.background_executor().spawn(async move { read(&repo_for_read, number, &path_for_read) }).await;
            this.update(cx, |view, cx| {
                match found {
                    Ok((base, head)) => {
                        let deleted = head.is_empty() && !base.is_empty();
                        crate::changes::add_file_diff(&multibuffer, 0, &path, std::path::PathBuf::new(), format!("{repo}#{number}"), deleted, &base, &head, cx);
                        view.state = State::Ready;
                    }
                    Err(e) => view.state = State::Failed(e),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        Self { editor, state: State::Loading }
    }
}

impl Render for PrDiff {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        match &self.state {
            State::Loading => div().p_3().text_sm().text_color(theme.secondary).child("Reading the diff from GitHub").into_any_element(),
            State::Failed(e) => div().p_3().text_sm().text_color(theme.secondary).child(format!("Couldn't show the diff: {e}")).into_any_element(),
            State::Ready => div().size_full().child(self.editor.clone()).into_any_element(),
        }
    }
}
