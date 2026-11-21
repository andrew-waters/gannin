//! A pull request's changes in Zed's diff view: one file for a review's
//! file detail (`PrDiff`, the file at the PR's merge base against its
//! head), or every file one commit changed (`CommitDiff`, against its
//! parent). Hunks show inline, as a session's Changes shows them
//! (`changes::add_file_diff`), and the PR's review threads sit under the
//! lines they're on, as editor blocks.
//!
//! Read from GitHub off the main thread: the merge base once per PR and
//! head (REST compare, as GitHub's own diff is against it), a commit's
//! files (REST), the text on each side (GraphQL) and the review threads
//! (GraphQL). An added file has no base and a deleted one no head. Read
//! only.

use crate::charts::Theme;
use editor::display_map::{BlockContext, BlockPlacement, BlockProperties, BlockStyle};
use editor::{Editor, EditorMode};
use gpui::{div, prelude::*, px, App, Context, Entity, FontWeight, Window};
use language::{Buffer, Capability, Point};
use multi_buffer::MultiBuffer;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

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
fn read(repo: &str, number: i64, path: &str) -> Result<(String, String, Vec<ReviewThread>), String> {
    let token = crate::auth::token().ok_or("Sign in to read the diff.")?;
    let (base, head) = commits(&token, repo, number)?;
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let data = crate::github::graphql(
        &token,
        "query($owner: String!, $name: String!, $base: String!, $head: String!) { repository(owner: $owner, name: $name) { base: object(expression: $base) { ... on Blob { text isBinary } } head: object(expression: $head) { ... on Blob { text isBinary } } } }",
        json!({ "owner": owner, "name": name, "base": format!("{base}:{path}"), "head": format!("{head}:{path}") }),
    )
    .map_err(|e| e.to_string())?;
    let repo_data = &data["repository"];
    if repo_data["base"]["isBinary"] == true || repo_data["head"]["isBinary"] == true {
        return Err("A binary file: no diff to show.".into());
    }
    let side = |key: &str| repo_data[key]["text"].as_str().unwrap_or_default().to_string();
    // Threads are a nicety: the diff shows without them.
    let threads = review_threads(&token, repo, number).unwrap_or_default();
    Ok((side("base"), side("head"), threads))
}

// MARK: - Review threads

/// A review thread on the PR, as placing it on a line needs.
#[derive(Clone)]
pub struct ReviewThread {
    path: String,
    /// Its line in the PR's latest code; none once outdated.
    line: Option<i64>,
    /// Its line in the commit it was left on, and that commit.
    original_line: Option<i64>,
    commit: Option<String>,
    /// RIGHT for the new code, LEFT for a removed line.
    side: String,
    resolved: bool,
    comments: Vec<(String, String)>,
}

/// The PR's review threads. Blocking.
fn review_threads(token: &str, repo: &str, number: i64) -> Result<Vec<ReviewThread>, String> {
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let data = crate::github::graphql(
        token,
        "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { isResolved path line originalLine diffSide comments(first: 30) { nodes { body author { login } originalCommit { oid } } } } } } } }",
        json!({ "owner": owner, "name": name, "number": number }),
    )
    .map_err(|e| e.to_string())?;
    let nodes = |v: &Value| v["nodes"].as_array().cloned().unwrap_or_default();
    Ok(nodes(&data["repository"]["pullRequest"]["reviewThreads"])
        .iter()
        .map(|t| {
            let comments = nodes(&t["comments"]);
            ReviewThread {
                path: t["path"].as_str().unwrap_or_default().to_string(),
                line: t["line"].as_i64(),
                original_line: t["originalLine"].as_i64(),
                commit: comments.first().and_then(|c| c["originalCommit"]["oid"].as_str()).map(str::to_string),
                side: t["diffSide"].as_str().unwrap_or("RIGHT").to_string(),
                resolved: t["isResolved"].as_bool().unwrap_or(false),
                comments: comments.iter().map(|c| (c["author"]["login"].as_str().unwrap_or("ghost").to_string(), c["body"].as_str().unwrap_or_default().to_string())).collect(),
            }
        })
        .collect())
}

/// A thread to place: the line (from 1) in the file as shown.
#[derive(Clone)]
struct Placed {
    line: u32,
    resolved: bool,
    comments: Vec<(String, String)>,
}

/// The threads on `path` in the PR's latest code. A removed line's
/// thread (LEFT) has no line in it, so it's left out.
fn latest_on(threads: &[ReviewThread], path: &str) -> Vec<Placed> {
    threads
        .iter()
        .filter(|t| t.path == path && t.side == "RIGHT")
        .filter_map(|t| Some(Placed { line: u32::try_from(t.line?).ok()?, resolved: t.resolved, comments: t.comments.clone() }))
        .collect()
}

/// The threads left on `path` at commit `sha`, on the lines they were on.
fn at_commit(threads: &[ReviewThread], path: &str, sha: &str) -> Vec<Placed> {
    threads
        .iter()
        .filter(|t| t.path == path && t.side == "RIGHT" && t.commit.as_deref() == Some(sha))
        .filter_map(|t| Some(Placed { line: u32::try_from(t.original_line?).ok()?, resolved: t.resolved, comments: t.comments.clone() }))
        .collect()
}

/// How many editor lines a thread's block takes: a line for each author,
/// its text wrapped at about 100 characters, and a little room.
fn block_height(thread: &Placed) -> u32 {
    let mut lines = 1;
    for (_, body) in &thread.comments {
        lines += 1;
        lines += body.lines().map(|l| (l.chars().count() as u32).div_ceil(100).max(1)).sum::<u32>();
    }
    lines.min(40)
}

fn render_thread(thread: &Placed, cx: &mut BlockContext) -> gpui::AnyElement {
    let theme = Theme::for_window(cx.window);
    div()
        .pl(cx.anchor_x)
        .pr_4()
        .py_1()
        .w_full()
        .child(
            div()
                .max_w(px(780.))
                .flex()
                .flex_col()
                .gap_1p5()
                .px_3()
                .py_2()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .bg(theme.tile)
                .when(thread.resolved, |d| d.opacity(0.65))
                .children(thread.comments.iter().enumerate().map(|(i, (who, body))| {
                    div()
                        .flex()
                        .flex_col()
                        .when(i > 0, |d| d.pt_1p5().border_t_1().border_color(theme.border))
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .gap_2()
                                .text_xs()
                                .child(div().font_weight(FontWeight::SEMIBOLD).child(who.clone()))
                                .when(i == 0 && thread.resolved, |d| d.child(div().text_color(theme.secondary).child("Resolved"))),
                        )
                        .child(div().text_sm().child(body.clone()))
                })),
        )
        .into_any_element()
}

/// Puts `threads` under their lines in `buffer`'s excerpts.
fn place_threads(editor: &Entity<Editor>, multibuffer: &Entity<MultiBuffer>, buffer: &Entity<Buffer>, threads: Vec<Placed>, cx: &mut App) {
    if threads.is_empty() {
        return;
    }
    let last = buffer.read(cx).max_point().row;
    let blocks: Vec<BlockProperties<editor::Anchor>> = threads
        .into_iter()
        .filter_map(|thread| {
            let row = thread.line.saturating_sub(1).min(last);
            let anchor = multibuffer.read(cx).buffer_point_to_anchor(buffer, Point::new(row, 0), cx)?;
            let height = block_height(&thread);
            Some(BlockProperties {
                placement: BlockPlacement::Below(anchor),
                height: Some(height),
                style: BlockStyle::Sticky,
                render: Arc::new(move |cx| render_thread(&thread, cx)),
                priority: 0,
            })
        })
        .collect();
    editor.update(cx, |editor, cx| {
        editor.insert_blocks(blocks, None, cx);
    });
}

/// A read-only editor over a new multibuffer, its hunks expanded.
fn diff_editor(window: &mut Window, cx: &mut App) -> (Entity<MultiBuffer>, Entity<Editor>) {
    let multibuffer = cx.new(|_| MultiBuffer::new(Capability::ReadOnly));
    let editor = cx.new(|cx| {
        let mut editor = Editor::new(EditorMode::full(), multibuffer.clone(), None, window, cx);
        editor.set_read_only(true);
        editor.set_expand_all_diff_hunks(cx);
        editor
    });
    (multibuffer, editor)
}

enum State {
    Loading,
    Ready,
    Failed(String),
}

// MARK: - One file of the PR

pub struct PrDiff {
    editor: Entity<Editor>,
    state: State,
}

impl PrDiff {
    pub fn new(repo: String, number: i64, path: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (multibuffer, editor) = diff_editor(window, cx);
        let shown = editor.clone();
        cx.spawn(async move |this, cx| {
            let (repo_for_read, path_for_read) = (repo.clone(), path.clone());
            let found = cx.background_executor().spawn(async move { read(&repo_for_read, number, &path_for_read) }).await;
            this.update(cx, |view, cx| {
                match found {
                    Ok((base, head, threads)) => {
                        let deleted = head.is_empty() && !base.is_empty();
                        let placed = latest_on(&threads, &path);
                        let keep = placed.iter().map(|t| t.line.saturating_sub(1)).collect();
                        let mb = multibuffer.clone();
                        crate::changes::add_file_diff(&multibuffer, 0, &path, std::path::PathBuf::new(), format!("{repo}#{number}"), deleted, &base, &head, keep, move |buffer, cx| place_threads(&shown, &mb, &buffer, placed, cx), cx);
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

// MARK: - Every file one commit changed

/// Files read from one commit, at most; a bigger commit says how many it left out.
const MOST_FILES: usize = 80;

struct CommitFile {
    path: String,
    base: String,
    head: String,
    deleted: bool,
}

struct CommitRead {
    files: Vec<CommitFile>,
    /// Binary files, and files past `MOST_FILES`.
    left_out: usize,
    threads: Vec<ReviewThread>,
}

/// A commit's changed files, each against the commit's first parent, and
/// the PR's review threads. Blocking.
fn read_commit(repo: &str, number: i64, sha: &str) -> Result<CommitRead, String> {
    let token = crate::auth::token().ok_or("Sign in to read the commit.")?;
    let commit = crate::github::rest_get(&token, &format!("repos/{repo}/commits/{sha}")).map_err(|(_, e)| e)?;
    let parent = commit["parents"][0]["sha"].as_str().map(str::to_string);
    let listed = commit["files"].as_array().cloned().unwrap_or_default();
    let mut left_out = listed.len().saturating_sub(MOST_FILES);
    let listed: Vec<&Value> = listed.iter().take(MOST_FILES).collect();
    // Both sides of every file in one query, by variables e0, e1, and so on.
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let mut fields = Vec::new();
    let mut params = vec!["$owner: String!".to_string(), "$name: String!".to_string()];
    let mut vars = serde_json::Map::new();
    vars.insert("owner".into(), json!(owner));
    vars.insert("name".into(), json!(name));
    for (i, f) in listed.iter().enumerate() {
        let path = f["filename"].as_str().unwrap_or_default();
        let before = f["previous_filename"].as_str().unwrap_or(path);
        if let Some(parent) = &parent {
            params.push(format!("$b{i}: String!"));
            vars.insert(format!("b{i}"), json!(format!("{parent}:{before}")));
            fields.push(format!("b{i}: object(expression: $b{i}) {{ ... on Blob {{ text isBinary }} }}"));
        }
        params.push(format!("$h{i}: String!"));
        vars.insert(format!("h{i}"), json!(format!("{sha}:{path}")));
        fields.push(format!("h{i}: object(expression: $h{i}) {{ ... on Blob {{ text isBinary }} }}"));
    }
    let texts = if listed.is_empty() {
        Value::Null
    } else {
        let query = format!("query({}) {{ repository(owner: $owner, name: $name) {{ {} }} }}", params.join(", "), fields.join(" "));
        crate::github::graphql(&token, &query, Value::Object(vars)).map_err(|e| e.to_string())?["repository"].clone()
    };
    let mut files = Vec::new();
    for (i, f) in listed.iter().enumerate() {
        let (b, h) = (&texts[format!("b{i}")], &texts[format!("h{i}")]);
        if b["isBinary"] == true || h["isBinary"] == true {
            left_out += 1;
            continue;
        }
        files.push(CommitFile {
            path: f["filename"].as_str().unwrap_or_default().to_string(),
            base: b["text"].as_str().unwrap_or_default().to_string(),
            head: h["text"].as_str().unwrap_or_default().to_string(),
            deleted: f["status"] == "removed",
        });
    }
    let threads = review_threads(&token, repo, number).unwrap_or_default();
    Ok(CommitRead { files, left_out, threads })
}

/// Every file one commit of the PR changed, with the review threads left
/// on that commit under their lines.
pub struct CommitDiff {
    editor: Entity<Editor>,
    state: State,
    short: String,
    headline: String,
    url: String,
    files: usize,
    left_out: usize,
}

impl CommitDiff {
    pub fn new(repo: String, number: i64, sha: String, headline: String, url: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (multibuffer, editor) = diff_editor(window, cx);
        let shown = editor.clone();
        let short: String = sha.chars().take(7).collect();
        let label = short.clone();
        cx.spawn(async move |this, cx| {
            let (repo_for_read, sha_for_read) = (repo.clone(), sha.clone());
            let found = cx.background_executor().spawn(async move { read_commit(&repo_for_read, number, &sha_for_read) }).await;
            this.update(cx, |view, cx| {
                match found {
                    Ok(read) => {
                        view.files = read.files.len();
                        view.left_out = read.left_out;
                        for (i, file) in read.files.into_iter().enumerate() {
                            let placed = at_commit(&read.threads, &file.path, &sha);
                            let keep = placed.iter().map(|t| t.line.saturating_sub(1)).collect();
                            let (mb, editor) = (multibuffer.clone(), shown.clone());
                            crate::changes::add_file_diff(&multibuffer, i as u64, &file.path, std::path::PathBuf::new(), label.clone(), file.deleted, &file.base, &file.head, keep, move |buffer, cx| place_threads(&editor, &mb, &buffer, placed, cx), cx);
                        }
                        view.state = State::Ready;
                    }
                    Err(e) => view.state = State::Failed(e),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        Self { editor, state: State::Loading, short, headline, url, files: 0, left_out: 0 }
    }
}

impl Render for CommitDiff {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let url = self.url.clone();
        let summary = match &self.state {
            State::Loading => "Reading the commit from GitHub".to_string(),
            State::Failed(e) => format!("Couldn't show the commit: {e}"),
            State::Ready if self.left_out > 0 => format!("{} {} shown, {} left out (binary, or past the first {MOST_FILES})", self.files, if self.files == 1 { "file" } else { "files" }, self.left_out),
            State::Ready => format!("{} {} changed", self.files, if self.files == 1 { "file" } else { "files" }),
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_4()
                    .py_2()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().flex_none().font_family(crate::zed::MONO).text_xs().text_color(theme.secondary).child(self.short.clone()))
                    .child(div().flex_1().min_w_0().truncate().font_weight(FontWeight::SEMIBOLD).child(self.headline.clone()))
                    .child(div().flex_none().text_sm().text_color(theme.secondary).child(summary))
                    .when(!url.is_empty(), |d| {
                        d.child(
                            div()
                                .id("commit-github")
                                .flex_none()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_1p5()
                                .px_2()
                                .py_0p5()
                                .rounded_md()
                                .border_1()
                                .border_color(theme.border)
                                .text_sm()
                                .cursor_pointer()
                                .hover(|s| s.bg(theme.row_selected))
                                .on_click(cx.listener(move |_, _: &gpui::ClickEvent, _, cx| cx.open_url(&url)))
                                .child(gpui::svg().path("icons/github.svg").size(px(14.)).flex_none().text_color(theme.fg))
                                .child("Open on GitHub"),
                        )
                    }),
            )
            .when(matches!(self.state, State::Ready), |d| d.child(div().flex_1().min_h_0().child(self.editor.clone())))
    }
}
