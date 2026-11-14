//! A session's code change, in Zed's own diff view: each file changed since
//! its branch left the default branch, committed or not, as an excerpt of
//! its hunks in one multibuffer, with the editor showing what was removed
//! and added inline, as Zed's Uncommitted Changes does.
//!
//! Claude rarely edits where it starts: a harness root is a detached HEAD,
//! and its rules have Claude make a worktree and commit there. So, as
//! Gannin's session Changes reads every worktree under the issue's folder,
//! this reads the repo the terminal is in plus every worktree of it made
//! since the session started (other sessions' older worktrees stay out).
//!
//! Git is read with the CLI (as Gannin does, so the user's config applies),
//! off the main thread, and only while the tab shows.

use buffer_diff::BufferDiff;
use editor::{Editor, EditorMode};
use gpui::{div, prelude::*, px, App, Context, Entity, FocusHandle, Focusable, SharedString, Task, Window};
use language::{Buffer, Capability, DiskState, File, LocalFile, Point};
use multi_buffer::{MultiBuffer, PathKey};
use settings::WorktreeId;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use util::paths::PathStyle;
use util::rel_path::RelPath;

use crate::charts::Theme;

/// One changed file: its path in the repo, what git calls it, and the text
/// on each side.
#[derive(Clone, PartialEq)]
struct Changed {
    path: String,
    status: Status,
    base: String,
    current: String,
}

#[derive(Clone, Copy, PartialEq)]
enum Status {
    Modified,
    Added,
    Deleted,
    Untracked,
}

impl Status {
    fn letter(self) -> &'static str {
        match self {
            Status::Modified => "M",
            Status::Added => "A",
            Status::Deleted => "D",
            Status::Untracked => "?",
        }
    }
}

/// A worktree (or the repo's own folder) and what's changed in it.
#[derive(Clone, PartialEq)]
struct Tree {
    path: PathBuf,
    /// Its branch, else its folder's name.
    label: String,
    /// What it's compared with, for the header.
    base: String,
    files: Vec<Changed>,
}

/// What a read found: the repo's folder first, then worktrees.
#[derive(Clone, PartialEq)]
struct Read {
    trees: Vec<Tree>,
}

/// A file in the list: which worktree, its path, status and line counts.
struct Count {
    tree: String,
    path: String,
    status: Status,
    added: usize,
    removed: usize,
}

pub struct ChangesView {
    /// Where to look: the terminal's folder now, else where it started.
    folder: Box<dyn Fn(&App) -> Option<PathBuf>>,
    editor: Entity<Editor>,
    multibuffer: Entity<MultiBuffer>,
    read: Option<Result<Read, String>>,
    /// Each file's line counts, for the list.
    counts: Vec<Count>,
    visible: bool,
    _poll: Task<()>,
}

impl ChangesView {
    pub fn new(folder: impl Fn(&App) -> Option<PathBuf> + 'static, since: SystemTime, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let multibuffer = cx.new(|_| MultiBuffer::new(Capability::ReadOnly));
        let editor = cx.new(|cx| {
            let mut editor = Editor::new(EditorMode::full(), multibuffer.clone(), None, window, cx);
            editor.set_read_only(true);
            editor.set_expand_all_diff_hunks(cx);
            editor
        });
        // Every two seconds while it shows: cheap (one git status), and a
        // session's edits appear without asking.
        let poll = cx.spawn(async move |this, cx| loop {
            let Ok(Some(folder)) = this.update(cx, |this, cx| this.visible.then(|| (this.folder)(cx)).flatten()) else {
                cx.background_executor().timer(Duration::from_secs(2)).await;
                if this.upgrade().is_none() {
                    return;
                }
                continue;
            };
            let read = cx.background_executor().spawn(async move { read(&folder, since) }).await;
            if this.update(cx, |this, cx| this.apply(read, cx)).is_err() {
                return;
            }
            cx.background_executor().timer(Duration::from_secs(2)).await;
        });
        Self { folder: Box::new(folder), editor, multibuffer, read: None, counts: Vec::new(), visible: false, _poll: poll }
    }

    /// Reads only while its tab shows.
    pub fn set_visible(&mut self, visible: bool) {
        self.visible = visible;
    }

    pub fn file_count(&self) -> usize {
        self.counts.len()
    }

    fn apply(&mut self, read: Result<Read, String>, cx: &mut Context<Self>) {
        if self.read.as_ref() == Some(&read) {
            return;
        }
        match &read {
            Ok(found) => self.show(found, cx),
            Err(_) => {
                self.multibuffer.update(cx, |multibuffer, cx| multibuffer.clear(cx));
                self.counts.clear();
            }
        }
        self.read = Some(read);
        cx.notify();
    }

    /// Rebuilds the multibuffer: one excerpt per file, its hunks with three
    /// lines around each, and the file's diff against git's copy.
    fn show(&mut self, found: &Read, cx: &mut Context<Self>) {
        self.multibuffer.update(cx, |multibuffer, cx| multibuffer.clear(cx));
        self.counts.clear();
        let files = found.trees.iter().enumerate().flat_map(|(t, tree)| tree.files.iter().enumerate().map(move |(f, file)| (t, f, tree, file)));
        for (tree_index, index, tree, file) in files {
            let Ok(rel) = RelPath::new(Path::new(&file.path), PathStyle::local()) else { continue };
            let rel: Arc<RelPath> = rel.into_arc();
            let named = Arc::new(ChangedFile {
                path: rel.clone(),
                root: tree.path.clone(),
                label: tree.label.clone(),
                deleted: file.status == Status::Deleted,
            });
            let buffer = cx.new(|cx| {
                let mut buffer = Buffer::local(file.current.clone(), cx);
                buffer.file_updated(named, cx);
                buffer.set_capability(Capability::ReadOnly, cx);
                buffer
            });
            let base = cx.new(|cx| {
                let mut base = Buffer::local(file.base.clone(), cx);
                base.set_capability(Capability::ReadOnly, cx);
                base
            });
            let snapshot = buffer.read(cx).text_snapshot();
            let diff = cx.new(|cx| BufferDiff::new_with_base_text_buffer(&snapshot, base.clone(), cx));
            let base_snapshot = base.read(cx).snapshot();
            let update = diff.read(cx).update_diff(snapshot.clone(), &base_snapshot, Some(Arc::from(file.base.as_str())), cx);
            let (added, removed) = line_counts(&file.base, &file.current);
            self.counts.push(Count { tree: tree.label.clone(), path: file.path.clone(), status: file.status, added, removed });
            let multibuffer = self.multibuffer.clone();
            let key = PathKey::with_sort_prefix(((tree_index as u64) << 32) | index as u64, rel);
            cx.spawn(async move |_, cx| {
                let update = update.await;
                cx.update(|cx| {
                    diff.update(cx, |diff, cx| {
                        diff.set_snapshot(update, cx);
                    });
                    let buffer_snapshot = buffer.read(cx).snapshot();
                    let ranges: Vec<std::ops::Range<Point>> = diff
                        .read(cx)
                        .snapshot(cx)
                        .hunks_intersecting_range(
                            text::Anchor::min_max_range_for_buffer(buffer_snapshot.remote_id()),
                            &buffer_snapshot,
                        )
                        .map(|hunk| {
                            use text::ToPoint;
                            hunk.buffer_range.start.to_point(&buffer_snapshot)..hunk.buffer_range.end.to_point(&buffer_snapshot)
                        })
                        .collect();
                    multibuffer.update(cx, |multibuffer, cx| {
                        multibuffer.set_excerpts_for_path(key, buffer, ranges, 3, cx);
                        multibuffer.add_diff(diff, cx);
                    });
                });
            })
            .detach();
        }
    }

    fn header(&self, theme: &Theme) -> impl IntoElement {
        let (title, detail): (SharedString, SharedString) = match &self.read {
            None => ("Reading the folder".into(), SharedString::default()),
            Some(Err(error)) => ("No changes to show".into(), error.clone().into()),
            Some(Ok(found)) => {
                let (added, removed) = self.counts.iter().fold((0, 0), |(a, r), c| (a + c.added, r + c.removed));
                let changed: Vec<&Tree> = found.trees.iter().filter(|t| !t.files.is_empty()).collect();
                let title = match changed.as_slice() {
                    [] => found.trees.first().map(|t| t.label.clone()).unwrap_or_default(),
                    [tree] => format!("{} against {}", tree.label, tree.base),
                    trees => format!("{} worktrees", trees.len()),
                };
                (
                    title.into(),
                    match self.counts.len() {
                        0 => "No changes yet: none in the folder, and no worktree made since the session started has any".to_string(),
                        n => format!("{n} file{} changed, +{added} −{removed}", if n == 1 { "" } else { "s" }),
                    }
                    .into(),
                )
            }
        };
        div()
            .flex_none()
            .flex()
            .flex_col()
            .px_3()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .child(div().font_weight(gpui::FontWeight::MEDIUM).child(title))
            .child(div().text_xs().text_color(theme.secondary).child(detail))
    }

    fn file_list(&self, theme: &Theme) -> impl IntoElement {
        div()
            .id("changed-files")
            .w(px(240.))
            .flex_none()
            .h_full()
            .overflow_y_scroll()
            .border_r_1()
            .border_color(theme.border)
            .py_1()
            .children(self.counts.iter().enumerate().map(|(index, count)| {
                let Count { tree, path, status, added, removed } = count;
                let first_of_tree = index == 0 || self.counts[index - 1].tree != *tree;
                let (folder, name) = match path.rsplit_once('/') {
                    Some((folder, name)) => (folder.to_string(), name.to_string()),
                    None => (String::new(), path.clone()),
                };
                let tint = match status {
                    Status::Deleted => gpui::red(),
                    Status::Added | Status::Untracked => gpui::green(),
                    Status::Modified => theme.selected,
                };
                let row = div()
                    .px_3()
                    .py_0p5()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_xs()
                    .child(div().w(px(10.)).text_color(tint).child(status.letter()))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().truncate().child(name))
                            .when(!folder.is_empty(), |d| d.child(div().truncate().text_color(theme.tertiary).child(folder))),
                    )
                    .child(div().text_color(gpui::green()).child(format!("+{added}")))
                    .child(div().text_color(gpui::red()).child(format!("−{removed}")));
                div()
                    .flex()
                    .flex_col()
                    .when(first_of_tree, |d| {
                        d.child(div().px_3().pt_2().pb_0p5().text_xs().font_weight(gpui::FontWeight::SEMIBOLD).text_color(theme.secondary).truncate().child(tree.clone()))
                    })
                    .child(row)
            }))
    }
}

impl Focusable for ChangesView {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.editor.focus_handle(cx)
    }
}

impl Render for ChangesView {
    fn render(&mut self, window: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(self.header(&theme))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_row()
                    .when(!self.counts.is_empty(), |d| d.child(self.file_list(&theme)))
                    .child(div().flex_1().min_w_0().h_full().child(self.editor.clone())),
            )
    }
}

// MARK: - Reading git

fn git(root: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .arg("--no-optional-locks")
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("Couldn't run git: {e}"))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// Files bigger than this are listed but not diffed, so a generated file
/// can't stall the view.
const MAX_BYTES: u64 = 1_000_000;

fn text(bytes: Vec<u8>) -> String {
    String::from_utf8_lossy(&bytes).trim().to_string()
}

fn read(folder: &Path, since: SystemTime) -> Result<Read, String> {
    let root = git(folder, &["rev-parse", "--show-toplevel"]).map_err(|_| format!("{} isn't in a git repository", folder.display()))?;
    let root = PathBuf::from(text(root));
    // Every worktree of the repo, the main folder first.
    let list = git(&root, &["worktree", "list", "--porcelain"])?;
    let mut worktrees: Vec<(PathBuf, Option<String>)> = Vec::new();
    for line in String::from_utf8_lossy(&list).lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            worktrees.push((PathBuf::from(path), None));
        } else if let (Some(branch), Some(last)) = (line.strip_prefix("branch refs/heads/"), worktrees.last_mut()) {
            last.1 = Some(branch.to_string());
        }
    }
    let mut trees = Vec::new();
    for (index, (path, branch)) in worktrees.into_iter().enumerate() {
        // The folder the terminal is in, the repo's own, and worktrees made
        // since the session started.
        let wanted = index == 0 || path == root || made_since(&path, since);
        if !wanted || !path.is_dir() {
            continue;
        }
        let label = branch.unwrap_or_else(|| path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
        trees.push(read_tree(&path, label)?);
    }
    Ok(Read { trees })
}

/// Whether the worktree was added after `since`, by its folder in the
/// repo's `.git/worktrees`.
fn made_since(path: &Path, since: SystemTime) -> bool {
    let Ok(pointer) = std::fs::read_to_string(path.join(".git")) else { return false };
    let Some(admin) = pointer.trim().strip_prefix("gitdir: ") else { return false };
    std::fs::metadata(admin).and_then(|m| m.created()).is_ok_and(|created| created >= since)
}

/// A worktree's changes since its branch left the default branch (where it
/// has none of its own, HEAD: what's uncommitted).
fn read_tree(path: &Path, label: String) -> Result<Tree, String> {
    let (base, base_label) = ["origin/HEAD", "origin/main", "origin/master"]
        .iter()
        .find_map(|upstream| git(path, &["merge-base", "HEAD", upstream]).ok().map(|b| (text(b), upstream.to_string())))
        .unwrap_or_else(|| ("HEAD".to_string(), "HEAD".to_string()));
    let head = git(path, &["rev-parse", "HEAD"]).map(text).unwrap_or_default();
    let base_label = if base == head { "HEAD (uncommitted)".to_string() } else { base_label };
    let mut found: Vec<(String, Status)> = Vec::new();
    let tracked = git(path, &["diff", "--no-renames", "--name-status", "-z", &base])?;
    let mut fields = tracked.split(|b| *b == 0).filter(|f| !f.is_empty());
    while let (Some(code), Some(file)) = (fields.next(), fields.next()) {
        let status = match code.first() {
            Some(b'A') => Status::Added,
            Some(b'D') => Status::Deleted,
            _ => Status::Modified,
        };
        found.push((String::from_utf8_lossy(file).into_owned(), status));
    }
    let untracked = git(path, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    for file in untracked.split(|b| *b == 0).filter(|f| !f.is_empty()) {
        found.push((String::from_utf8_lossy(file).into_owned(), Status::Untracked));
    }
    let mut files = Vec::new();
    for (file, status) in found {
        let on_disk = path.join(&file);
        if on_disk.is_dir() || std::fs::metadata(&on_disk).is_ok_and(|m| m.len() > MAX_BYTES) {
            continue;
        }
        let before = match status {
            Status::Untracked | Status::Added => String::new(),
            _ => git(path, &["show", &format!("{base}:{file}")]).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default(),
        };
        let current = if status == Status::Deleted { String::new() } else { std::fs::read_to_string(&on_disk).unwrap_or_default() };
        // Binary files have no lines to show.
        if before.contains('\0') || current.contains('\0') {
            continue;
        }
        files.push(Changed { path: file, status, base: before, current });
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(Tree { path: path.to_path_buf(), label, base: base_label, files })
}

/// Added and removed lines, counted the way `git diff --numstat` would for
/// a plain line diff.
fn line_counts(base: &str, current: &str) -> (usize, usize) {
    let old: Vec<&str> = base.lines().collect();
    let new: Vec<&str> = current.lines().collect();
    let (mut start, mut old_end, mut new_end) = (0, old.len(), new.len());
    while start < old_end && start < new_end && old[start] == new[start] {
        start += 1;
    }
    while old_end > start && new_end > start && old[old_end - 1] == new[new_end - 1] {
        old_end -= 1;
        new_end -= 1;
    }
    // Lines in the changed middle on one side and not the other.
    let olds: std::collections::HashMap<&str, usize> = old[start..old_end].iter().fold(Default::default(), |mut m, l| {
        *m.entry(*l).or_insert(0) += 1;
        m
    });
    let mut remaining = olds.clone();
    let mut added = 0;
    for line in &new[start..new_end] {
        match remaining.get_mut(line) {
            Some(n) if *n > 0 => *n -= 1,
            _ => added += 1,
        }
    }
    let removed = (old_end - start) - (new_end - start - added);
    (added, removed)
}

// MARK: - A file for the editor's headers

/// What the editor's file header names: the path in the repo. Read only:
/// the pilot never writes a file.
struct ChangedFile {
    path: Arc<RelPath>,
    root: PathBuf,
    /// The worktree's branch, shown before the path.
    label: String,
    deleted: bool,
}

impl File for ChangedFile {
    fn as_local(&self) -> Option<&dyn LocalFile> {
        None
    }

    fn disk_state(&self) -> DiskState {
        DiskState::Historic { was_deleted: self.deleted }
    }

    fn path(&self) -> &Arc<RelPath> {
        &self.path
    }

    fn full_path(&self, _: &App) -> PathBuf {
        PathBuf::from(&self.label).join(self.path.as_std_path())
    }

    fn file_system_abs_path(&self, _: &App) -> Option<PathBuf> {
        Some(self.root.join(self.path.as_std_path()))
    }

    fn path_style(&self, _: &App) -> PathStyle {
        PathStyle::local()
    }

    fn file_name<'a>(&'a self, _: &'a App) -> &'a str {
        self.path.file_name().unwrap_or("")
    }

    fn worktree_id(&self, _: &App) -> WorktreeId {
        WorktreeId::from_usize(0)
    }

    fn to_proto(&self, _: &App) -> rpc::proto::File {
        rpc::proto::File { path: self.path.as_unix_str().to_string(), ..Default::default() }
    }

    fn is_private(&self) -> bool {
        false
    }

    fn can_open(&self) -> bool {
        false
    }
}
