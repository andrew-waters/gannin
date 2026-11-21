//! Notes: markdown you keep for yourself, each with a category and links to
//! what it's about (`links.rs`). One file per note in `~/.gannin/notes/`,
//! front matter then the text, so they can be read, grepped and backed up
//! outside the app. They stay on this Mac unless you share one, which
//! commits a copy to the org's harness; nothing sends them to Marra's claude.
//!
//! `NotesStore` holds the notes, their categories and the todos (`todos.rs`)
//! for every window at once, so a note added on a PR shows in Marra and the
//! other way round.

use crate::links::Link;
use crate::todos::Todo;
use chrono::{DateTime, Local};
use gpui::{App, AppContext, Context, Entity, Global};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
pub struct Note {
    pub id: String,
    /// A category's id, from `note_categories.json`.
    pub category: Option<String>,
    /// As `Link` writes them.
    pub links: Vec<String>,
    /// The org whose home harness has a copy; none while it's private.
    pub shared: Option<String>,
    /// `fingerprint` of what was last committed, to tell when the shared
    /// copy is behind.
    pub published: Option<String>,
    pub created: DateTime<Local>,
    pub updated: DateTime<Local>,
    pub body: String,
    /// Who wrote it, on a teammate's shared note; none on your own.
    pub author: Option<String>,
}

impl Note {
    /// The first line with text, without a heading's `#`s.
    pub fn title(&self) -> String {
        let line = self.body.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
        let line = line.trim_start_matches('#').trim();
        if line.is_empty() { "Untitled".into() } else { line.to_string() }
    }

    /// The text after the title, as one line for a list's second line.
    pub fn preview(&self) -> String {
        let mut lines = self.body.lines().map(str::trim).filter(|l| !l.is_empty());
        lines.next();
        lines.collect::<Vec<_>>().join(" ")
    }

    pub fn has_link(&self, link: &str) -> bool {
        self.links.iter().any(|l| l == link)
    }

    /// Whether the shared copy is behind this one.
    pub fn unpublished(&self) -> bool {
        self.shared.is_some() && self.published.as_deref() != Some(&fingerprint(&self.body, &self.links, self.category.as_deref()))
    }
}

/// A short hash of what a shared copy holds, stable across builds (FNV-1a).
pub fn fingerprint(body: &str, links: &[String], category: Option<&str>) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in body.bytes().chain(links.join(",").bytes()).chain(category.unwrap_or("").bytes()) {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Category {
    pub id: String,
    pub name: String,
    /// One of the theme's colour slots.
    pub colour: usize,
}

fn folder() -> PathBuf {
    crate::paths::app_dir().join("notes")
}

fn categories_path() -> PathBuf {
    crate::paths::app_dir().join("note_categories.json")
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_string()
}

/// The file's text: front matter, then the note as written.
pub fn render(note: &Note) -> String {
    let mut out = String::from("---\n");
    out.push_str(&format!("id: {}\n", note.id));
    if let Some(category) = &note.category {
        out.push_str(&format!("category: {category}\n"));
    }
    out.push_str(&format!("links: [{}]\n", note.links.join(", ")));
    if let Some(org) = &note.shared {
        out.push_str(&format!("shared: {org}\n"));
    }
    if let Some(published) = &note.published {
        out.push_str(&format!("published: {published}\n"));
    }
    if let Some(author) = &note.author {
        out.push_str(&format!("author: {author}\n"));
    }
    out.push_str(&format!("created: {}\n", note.created.to_rfc3339()));
    out.push_str(&format!("updated: {}\n", note.updated.to_rfc3339()));
    out.push_str("---\n");
    out.push_str(&note.body);
    out
}

/// A note from its file's text; none without front matter and an id.
pub fn parse(text: &str) -> Option<Note> {
    let lines: Vec<&str> = text.lines().collect();
    let fields = crate::harness_doc::front_matter(&lines)?;
    // The text starts after the second `---` line.
    let mut offset = 0;
    let mut fences = 0;
    for line in text.split_inclusive('\n') {
        offset += line.len();
        if line.trim() == "---" {
            fences += 1;
            if fences == 2 {
                break;
            }
        }
    }
    let text_of = |key: &str| fields.get(key).and_then(|v| v.text());
    let date = |key: &str| text_of(key).and_then(|t| DateTime::parse_from_rfc3339(&t).ok()).map(|d| d.with_timezone(&Local));
    let created = date("created").unwrap_or_else(Local::now);
    Some(Note {
        id: text_of("id")?,
        category: text_of("category"),
        links: fields.get("links").map(|v| v.list()).unwrap_or_default(),
        shared: text_of("shared"),
        published: text_of("published"),
        created,
        updated: date("updated").unwrap_or(created),
        body: text[offset.min(text.len())..].to_string(),
        author: text_of("author"),
    })
}

/// Every note in the folder; any that won't read are left out.
pub fn load_all() -> Vec<Note> {
    let Ok(entries) = std::fs::read_dir(folder()) else { return Vec::new() };
    entries
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "md"))
        .filter_map(|e| std::fs::read_to_string(e.path()).ok())
        .filter_map(|text| parse(&text))
        .collect()
}

/// Writes to a temporary file and moves it over, so a half-written note is
/// never read back.
pub fn save(note: &Note) {
    let folder = folder();
    let _ = std::fs::create_dir_all(&folder);
    let path = folder.join(format!("{}.md", note.id));
    let temporary = path.with_extension("md.tmp");
    if std::fs::write(&temporary, render(note)).is_ok() {
        let _ = std::fs::rename(&temporary, &path);
    }
}

pub fn delete(id: &str) {
    let _ = std::fs::remove_file(folder().join(format!("{id}.md")));
}

pub fn load_categories() -> Vec<Category> {
    std::fs::read(categories_path()).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

pub fn save_categories(categories: &[Category]) {
    let path = categories_path();
    let Ok(json) = serde_json::to_vec_pretty(categories) else { return };
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, json).is_ok() {
        let _ = std::fs::rename(&temporary, &path);
    }
}

/// "09:14" today, "Mon" this week, else "12 Nov".
pub fn when(at: DateTime<Local>) -> String {
    let now = Local::now();
    if at.date_naive() == now.date_naive() {
        at.format("%H:%M").to_string()
    } else if (now - at).num_days() < 7 {
        at.format("%a").to_string()
    } else {
        at.format("%-d %b").to_string()
    }
}

/// Where your shared copy of a note lives in a harness.
pub fn shared_path(login: &str, id: &str) -> String {
    format!("notes/{login}/{id}.md")
}

/// The shared copy: the note as you have it, saying who wrote it.
pub fn render_shared(note: &Note, login: &str) -> String {
    render(&Note { shared: None, published: None, author: Some(login.to_string()), ..note.clone() })
}

/// Teammates' shared notes in the org's harnesses, read from `notes/<login>/`;
/// yours are left out, being in your own list already. Fetches and runs
/// git: call off the main thread.
pub fn read_shared(org: &str, login: Option<&str>) -> Vec<Note> {
    let mut out = Vec::new();
    for snapshot in crate::harness_git::snapshots(org) {
        for (path, text) in snapshot.under("notes/") {
            let Some(mut note) = parse(text) else { continue };
            let by = path.split('/').nth(1).unwrap_or_default().to_string();
            if login.is_some_and(|l| l.eq_ignore_ascii_case(&by)) {
                continue;
            }
            note.author = Some(note.author.unwrap_or(by));
            note.shared = Some(org.to_string());
            out.push(note);
        }
    }
    out
}

pub struct NotesGlobal(pub Entity<NotesStore>);
impl Global for NotesGlobal {}

/// Your notes, their categories and your todos, read once and written as
/// they change; teammates' shared notes as last read from the harnesses.
pub struct NotesStore {
    pub notes: Vec<Note>,
    pub categories: Vec<Category>,
    pub todos: Vec<Todo>,
    pub shared: Vec<Note>,
    _refresh: gpui::Task<()>,
}

impl NotesStore {
    pub fn get(cx: &mut App) -> Entity<NotesStore> {
        if let Some(global) = cx.try_global::<NotesGlobal>() {
            return global.0.clone();
        }
        let entity = cx.new(|cx| {
            // Teammates' shared notes: soon after launch (once Marra knows the
            // orgs with harnesses), then as often as harnesses are fetched.
            let refresh = cx.spawn(async move |this, cx| {
                cx.background_executor().timer(std::time::Duration::from_secs(15)).await;
                loop {
                    let Ok(orgs) = this.update(cx, |store: &mut NotesStore, cx| store.orgs(cx)) else { return };
                    let login = crate::auth::saved_viewer().map(|v| v.login);
                    let shared = cx.background_executor().spawn(async move { orgs.iter().flat_map(|org| read_shared(org, login.as_deref())).collect::<Vec<_>>() }).await;
                    if this
                        .update(cx, |store: &mut NotesStore, cx| {
                            if store.shared != shared {
                                store.shared = shared;
                                cx.notify();
                            }
                        })
                        .is_err()
                    {
                        return;
                    }
                    cx.background_executor().timer(std::time::Duration::from_secs(300)).await;
                }
            });
            NotesStore { notes: load_all(), categories: load_categories(), todos: crate::todos::load(), shared: Vec::new(), _refresh: refresh }
        });
        cx.set_global(NotesGlobal(entity.clone()));
        entity
    }

    /// The orgs to read shared notes from: those Marra knows have a
    /// harness, and those your notes are shared in.
    fn orgs(&self, cx: &App) -> Vec<String> {
        let mut orgs: Vec<String> = cx.try_global::<crate::marra_model::MarraGlobal>().map(|g| g.0.read(cx).harness_orgs.clone()).unwrap_or_default();
        orgs.extend(self.notes.iter().filter_map(|n| n.shared.clone()));
        orgs.sort_by_key(|o| o.to_lowercase());
        orgs.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
        orgs
    }

    /// The org a note would be shared in: where it is already, else its
    /// first PR's or issue's, else the first with a harness.
    pub fn share_org(&self, id: &str, cx: &App) -> Option<String> {
        let note = self.notes.iter().find(|n| n.id == id)?;
        note.shared
            .clone()
            .or_else(|| crate::links::parse_all(&note.links).iter().find_map(|l| l.org().map(str::to_string)))
            .or_else(|| cx.try_global::<crate::marra_model::MarraGlobal>().and_then(|g| g.0.read(cx).harness_orgs.first().cloned()))
    }

    /// Marks a note shared in `org` as of `fingerprint`, or private again.
    pub fn set_shared(&mut self, id: &str, shared: Option<(String, String)>, cx: &mut Context<Self>) {
        let Some(note) = self.notes.iter_mut().find(|n| n.id == id) else { return };
        (note.shared, note.published) = match shared {
            Some((org, fingerprint)) => (Some(org), Some(fingerprint)),
            None => (None, None),
        };
        save(note);
        cx.notify();
    }

    pub fn note(&self, id: &str) -> Option<&Note> {
        self.notes.iter().find(|n| n.id == id).or_else(|| self.shared.iter().find(|n| n.id == id))
    }

    pub fn category(&self, id: Option<&str>) -> Option<&Category> {
        self.categories.iter().find(|c| Some(c.id.as_str()) == id)
    }

    /// Notes (yours, then teammates') and todos that link to `link`.
    pub fn linked(&self, link: &Link) -> (Vec<&Note>, Vec<&Todo>) {
        let text = link.to_string();
        let notes = self.notes.iter().chain(self.shared.iter()).filter(|n| n.has_link(&text)).collect();
        let todos = self.todos.iter().filter(|t| t.links.iter().any(|l| *l == text)).collect();
        (notes, todos)
    }

    /// How many notes and open todos link to `link`.
    pub fn count(&self, link: &Link) -> usize {
        let (notes, todos) = self.linked(link);
        notes.len() + todos.iter().filter(|t| t.done.is_none()).count()
    }

    // MARK: Notes

    /// A new note with `body` and `links`; its id.
    pub fn new_note(&mut self, body: &str, links: Vec<Link>, cx: &mut Context<Self>) -> String {
        let now = Local::now();
        let note = Note {
            id: new_id(),
            category: None,
            links: links.iter().map(Link::to_string).collect(),
            shared: None,
            published: None,
            created: now,
            updated: now,
            body: body.to_string(),
            author: None,
        };
        let id = note.id.clone();
        save(&note);
        self.notes.push(note);
        cx.notify();
        id
    }

    /// Changes one of your notes and writes it, when there's a change.
    pub fn update(&mut self, id: &str, cx: &mut Context<Self>, change: impl FnOnce(&mut Note)) {
        let Some(note) = self.notes.iter_mut().find(|n| n.id == id) else { return };
        let before = note.clone();
        change(note);
        if *note != before {
            note.updated = Local::now();
            save(note);
            cx.notify();
        }
    }

    pub fn set_body(&mut self, id: &str, body: String, cx: &mut Context<Self>) {
        self.update(id, cx, |n| n.body = body);
    }

    pub fn set_category(&mut self, id: &str, category: Option<String>, cx: &mut Context<Self>) {
        self.update(id, cx, |n| n.category = category);
    }

    pub fn link(&mut self, id: &str, link: &Link, cx: &mut Context<Self>) {
        let text = link.to_string();
        self.update(id, cx, |n| {
            if !n.has_link(&text) {
                n.links.push(text);
            }
        });
    }

    pub fn unlink(&mut self, id: &str, link: &str, cx: &mut Context<Self>) {
        self.update(id, cx, |n| n.links.retain(|l| l != link));
    }

    /// Removes a note, and the links to it from todos and other notes.
    pub fn delete_note(&mut self, id: &str, cx: &mut Context<Self>) {
        delete(id);
        self.notes.retain(|n| n.id != id);
        let link = Link::Note(id.to_string()).to_string();
        for note in self.notes.iter_mut().filter(|n| n.has_link(&link)) {
            note.links.retain(|l| *l != link);
            save(note);
        }
        if self.todos.iter().any(|t| t.links.contains(&link)) {
            for todo in &mut self.todos {
                todo.links.retain(|l| *l != link);
            }
            crate::todos::save(&self.todos);
        }
        cx.notify();
    }

    // MARK: Categories

    pub fn add_category(&mut self, name: &str, cx: &mut Context<Self>) -> Option<String> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        if let Some(existing) = self.categories.iter().find(|c| c.name.eq_ignore_ascii_case(name)) {
            return Some(existing.id.clone());
        }
        let category = Category { id: new_id(), name: name.to_string(), colour: self.categories.len() % 8 };
        let id = category.id.clone();
        self.categories.push(category);
        save_categories(&self.categories);
        cx.notify();
        Some(id)
    }

    pub fn rename_category(&mut self, id: &str, name: &str, cx: &mut Context<Self>) {
        let name = name.trim();
        if let Some(category) = self.categories.iter_mut().find(|c| c.id == id).filter(|_| !name.is_empty()) {
            category.name = name.to_string();
            save_categories(&self.categories);
            cx.notify();
        }
    }

    /// The next colour along.
    pub fn recolour_category(&mut self, id: &str, cx: &mut Context<Self>) {
        if let Some(category) = self.categories.iter_mut().find(|c| c.id == id) {
            category.colour = (category.colour + 1) % 8;
            save_categories(&self.categories);
            cx.notify();
        }
    }

    /// Removes a category; its notes are left with none.
    pub fn remove_category(&mut self, id: &str, cx: &mut Context<Self>) {
        self.categories.retain(|c| c.id != id);
        save_categories(&self.categories);
        for note in self.notes.iter_mut().filter(|n| n.category.as_deref() == Some(id)) {
            note.category = None;
            save(note);
        }
        cx.notify();
    }

    // MARK: Todos

    pub fn add_todo(&mut self, text: &str, links: Vec<Link>, cx: &mut Context<Self>) {
        crate::todos::add(&mut self.todos, text, links.iter().map(Link::to_string).collect());
        cx.notify();
    }

    pub fn toggle_todo(&mut self, id: &str, cx: &mut Context<Self>) {
        crate::todos::toggle(&mut self.todos, id);
        cx.notify();
    }

    pub fn remove_todo(&mut self, id: &str, cx: &mut Context<Self>) {
        crate::todos::remove(&mut self.todos, id);
        cx.notify();
    }

    pub fn clear_done(&mut self, cx: &mut Context<Self>) {
        crate::todos::clear_done(&mut self.todos);
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(body: &str) -> Note {
        let now = Local::now();
        Note {
            id: "3f9a1c2e".into(),
            category: Some("design".into()),
            links: vec!["pr:ctrl-hub/clients#2581".into(), "note:aa11bb22".into()],
            shared: Some("ctrl-hub".into()),
            published: Some("0123456789abcdef".into()),
            created: now,
            updated: now,
            body: body.into(),
            author: None,
        }
    }

    #[test]
    fn a_note_reads_back_as_written() {
        let written = note("# Plan\n\nSome *text*.\n\n---\n\nAfter a rule.\n");
        let read = parse(&render(&written)).unwrap();
        assert_eq!(read.body, written.body);
        assert_eq!(read.links, written.links);
        assert_eq!((&read.category, &read.shared, &read.published), (&written.category, &written.shared, &written.published));
        assert_eq!(read.created.timestamp(), written.created.timestamp());
        assert_eq!(read.title(), "Plan");
        assert_eq!(read.preview(), "Some *text*. --- After a rule.");
    }

    #[test]
    fn a_private_note_without_links_reads_back() {
        let mut written = note("Just a line");
        written.links.clear();
        written.shared = None;
        written.published = None;
        let read = parse(&render(&written)).unwrap();
        assert!(read.links.is_empty() && read.shared.is_none());
        assert_eq!(read.title(), "Just a line");
    }

    #[test]
    fn a_shared_note_is_behind_once_edited() {
        let mut n = note("one");
        n.published = Some(fingerprint(&n.body, &n.links, n.category.as_deref()));
        assert!(!n.unpublished());
        n.body.push_str(" two");
        assert!(n.unpublished());
    }
}
