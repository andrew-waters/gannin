//! Prompt shortcuts: buttons beside "Tell claude something" that send a
//! saved text to claude, for what's typed again and again ("is that on
//! main?", "remove the worktrees"). The team's, kept in its home harness as
//! `shortcuts/<name>.md`: the label in the front matter, the text as the
//! body, so they can be written by hand in a pull request too. Read from
//! the harness's default branch in the background when a session opens;
//! "+" adds one and a right-click edits or deletes it, each a commit to the
//! harness (a pull request merged at once when the branch needs one) that
//! goes only from the form's Save to Harness or Delete from Harness.
//!
//! `ShortcutBar` is the buttons and their form, a view of its own that each
//! composer holds; it emits `SendShortcut` and the composer sends the text
//! as if typed.

use crate::charts::Theme;
use gpui::{anchored, deferred, div, prelude::*, px, ClickEvent, Focusable, Context, Entity, EventEmitter, FontWeight, KeyDownEvent, MouseButton, MouseDownEvent, SharedString, Window};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, PartialEq)]
pub struct Shortcut {
    pub label: String,
    pub text: String,
    /// Its file in the harness.
    pub path: String,
}

const FOLDER: &str = "shortcuts/";

/// Each org's shortcuts as last read or written, and the orgs being read.
fn store() -> &'static Mutex<HashMap<String, Vec<Shortcut>>> {
    static STORE: OnceLock<Mutex<HashMap<String, Vec<Shortcut>>>> = OnceLock::new();
    STORE.get_or_init(Default::default)
}

fn reading() -> &'static Mutex<HashSet<String>> {
    static READING: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    READING.get_or_init(Default::default)
}

pub fn for_org(org: &str) -> Vec<Shortcut> {
    store().lock().ok().and_then(|s| s.get(org).cloned()).unwrap_or_default()
}

/// One file: `label:` in the front matter, else the file's name; the body
/// is the text.
fn parse(path: &str, file: &str) -> Option<Shortcut> {
    let mut label = None;
    let mut body = file;
    if let Some(rest) = file.strip_prefix("---\n") {
        if let Some((front, after)) = rest.split_once("\n---") {
            for line in front.lines() {
                if let Some(value) = line.strip_prefix("label:") {
                    let value = value.trim();
                    label = Some(serde_json::from_str::<String>(value).unwrap_or_else(|_| value.trim_matches(['\'', '"']).to_string()));
                }
            }
            body = after.trim_start_matches('-');
        }
    }
    let text = body.trim().to_string();
    if text.is_empty() {
        return None;
    }
    let stem = path.trim_start_matches(FOLDER).trim_end_matches(".md").replace('-', " ");
    Some(Shortcut { label: label.filter(|l| !l.is_empty()).unwrap_or(stem), text, path: path.to_string() })
}

fn render_file(label: &str, text: &str) -> String {
    format!("---\nlabel: {}\n---\n\n{}\n", serde_json::to_string(label).unwrap_or_default(), text.trim())
}

/// Reads the org's shortcuts from its home harness. Runs git: call off the
/// main thread.
fn read(org: &str, harness: &str) -> Vec<Shortcut> {
    let Some(snapshot) = crate::harness_git::snapshot(org, harness) else { return Vec::new() };
    let mut list: Vec<Shortcut> = snapshot.under(FOLDER).filter(|(p, _)| p.ends_with(".md")).filter_map(|(p, t)| parse(p, t)).collect();
    list.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
    list
}

/// A shortcut was clicked: send its text.
pub struct SendShortcut(pub String);

/// The form open: which shortcut (None for a new one), its fields, and
/// whether it's committing or what went wrong.
struct Form {
    editing: Option<Shortcut>,
    label: Entity<editor::Editor>,
    text: Entity<editor::Editor>,
    busy: bool,
    error: Option<String>,
}

pub struct ShortcutBar {
    /// The org and its home harness, once the session's known.
    place: Option<(String, String)>,
    form: Option<Form>,
    /// Whether the session can take a message now.
    enabled: bool,
}

impl EventEmitter<SendShortcut> for ShortcutBar {}

impl ShortcutBar {
    pub fn new() -> Self {
        Self { place: None, form: None, enabled: true }
    }

    /// The org and harness the shortcuts come from; read once per org in
    /// the background.
    pub fn set_place(&mut self, org: &str, harness: &str, cx: &mut Context<Self>) {
        let place = (org.to_string(), harness.to_string());
        if self.place.as_ref() == Some(&place) {
            return;
        }
        self.place = Some(place);
        let first = reading().lock().map(|mut r| r.insert(org.to_string())).unwrap_or(false);
        if first {
            let (org, harness) = (org.to_string(), harness.to_string());
            cx.spawn(async move |_, cx| {
                let found = cx.background_executor().spawn({
                    let (org, harness) = (org.clone(), harness.clone());
                    async move { read(&org, &harness) }
                })
                .await;
                if let Ok(mut s) = store().lock() {
                    s.insert(org, found);
                }
                cx.update(|cx| cx.refresh_windows());
            })
            .detach();
        }
        cx.notify();
    }

    pub fn set_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        if self.enabled != enabled {
            self.enabled = enabled;
            cx.notify();
        }
    }

    fn open_form(&mut self, editing: Option<Shortcut>, window: &mut Window, cx: &mut Context<Self>) {
        let label = cx.new(|cx| {
            let mut e = editor::Editor::single_line(window, cx);
            e.set_placeholder_text("Label", window, cx);
            if let Some(s) = &editing {
                e.set_text(s.label.clone(), window, cx);
            }
            e
        });
        let text = cx.new(|cx| {
            let mut e = editor::Editor::auto_height(3, 10, window, cx);
            e.set_placeholder_text("What to tell claude", window, cx);
            if let Some(s) = &editing {
                e.set_text(s.text.clone(), window, cx);
            }
            e
        });
        window.focus(&label.focus_handle(cx), cx);
        self.form = Some(Form { editing, label, text, busy: false, error: None });
        cx.notify();
    }

    /// Where a new shortcut's file goes: its label as a slug, not one the
    /// harness has.
    fn new_path(org: &str, label: &str) -> String {
        let taken: Vec<String> = for_org(org).into_iter().map(|s| s.path).collect();
        let base = crate::launch::slug(label, 40);
        let base = if base.is_empty() { "shortcut".to_string() } else { base };
        let mut path = format!("{FOLDER}{base}.md");
        let mut n = 2;
        while taken.contains(&path) {
            path = format!("{FOLDER}{base}-{n}.md");
            n += 1;
        }
        path
    }

    /// Commits it to the harness, from Save to Harness (or Delete from
    /// Harness, `delete`), then keeps the form's result in the store.
    fn commit(&mut self, delete: bool, cx: &mut Context<Self>) {
        let Some((org, harness)) = self.place.clone() else { return };
        let Some(form) = self.form.as_mut() else { return };
        let label = form.label.read(cx).text(cx).trim().to_string();
        let text = form.text.read(cx).text(cx).trim().to_string();
        if !delete && text.is_empty() {
            form.error = Some("Give it some text to send.".into());
            cx.notify();
            return;
        }
        let label = if label.is_empty() { text.chars().take(24).collect() } else { label };
        let path = form.editing.as_ref().map(|s| s.path.clone()).unwrap_or_else(|| Self::new_path(&org, &label));
        let old = form.editing.clone();
        form.busy = true;
        form.error = None;
        cx.notify();
        let shortcut = Shortcut { label: label.clone(), text: text.clone(), path: path.clone() };
        let (repo, file) = (harness.clone(), path.clone());
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to change the team's shortcuts.")?;
                    if delete {
                        crate::review_record::delete_file(&token, &repo, &file, &format!("Remove the {label} shortcut"))
                    } else {
                        let body = render_file(&label, &text);
                        crate::review_record::commit_file(&token, &repo, &file, &format!("Shortcut: {label}"), &|_| Some(body.clone()))
                    }
                })
                .await;
            this.update(cx, |bar, cx| {
                match result {
                    Ok(note) => {
                        if let Ok(mut s) = store().lock() {
                            let list = s.entry(org.clone()).or_default();
                            list.retain(|s| Some(&s.path) != old.as_ref().map(|o| &o.path));
                            if !delete {
                                list.push(shortcut);
                                list.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
                            }
                        }
                        match note {
                            // Left in a pull request that couldn't merge: say so.
                            Some(note) => {
                                if let Some(form) = bar.form.as_mut() {
                                    form.busy = false;
                                    form.error = Some(note);
                                }
                            }
                            None => bar.form = None,
                        }
                        cx.refresh_windows();
                    }
                    Err(error) => {
                        if let Some(form) = bar.form.as_mut() {
                            form.busy = false;
                            form.error = Some(format!("Couldn't commit to the harness: {error}"));
                        }
                        cx.notify();
                    }
                }
            })
            .ok();
        })
        .detach();
    }

    fn button(id: SharedString, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div().id(id).flex_none().max_w(px(160.)).truncate().px_2().py_0p5().rounded_md().border_1().border_color(theme.border).text_sm()
    }

    fn form_panel(&self, form: &Form, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let editing = form.editing.is_some();
        let harness = self.place.as_ref().map(|p| p.1.clone()).unwrap_or_default();
        let file = form.editing.as_ref().map(|s| s.path.clone()).unwrap_or_else(|| format!("{FOLDER}<label>.md"));
        let field = |child: Entity<editor::Editor>| div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(child);
        let busy = form.busy;
        let action = |id: &'static str, label: &'static str, prominent: bool| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_sm()
                .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
                .when(!busy, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)))
                .when(busy, |d| d.opacity(0.5))
                .child(label)
        };
        div()
            .id("shortcut-form")
            .occlude()
            .mb_2()
            .w(px(400.))
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .bg(theme.popover)
            .shadow_lg()
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    cx.stop_propagation();
                    this.form = None;
                    cx.notify();
                }
            }))
            .child(div().font_weight(FontWeight::SEMIBOLD).child(if editing { "Edit Team Shortcut" } else { "New Team Shortcut" }))
            .child(field(form.label.clone()))
            .child(field(form.text.clone()))
            .child(div().text_xs().text_color(theme.secondary).child(format!("Everyone on the team gets it beside Tell claude something. Saving commits {file} to {harness}.")))
            .when_some(form.error.clone(), |d, e| d.child(div().text_xs().text_color(theme.critical()).child(e)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .when(editing, |d| {
                        d.child(action("shortcut-delete", "Delete from Harness", false).text_color(theme.critical()).when(!busy, |d| d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.commit(true, cx)))))
                    })
                    .child(div().flex_1())
                    .child(action("shortcut-cancel", "Cancel", false).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.form = None;
                        cx.notify();
                    })))
                    .child(action("shortcut-save", if busy { "Committing" } else { "Save to Harness" }, true).when(!busy, |d| d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.commit(false, cx))))),
            )
    }
}

impl Render for ShortcutBar {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let Some((org, _)) = self.place.clone() else { return div().into_any_element() };
        let enabled = self.enabled;
        let shortcuts = for_org(&org);
        let form = self.form.as_ref().map(|f| self.form_panel(f, &theme, cx).into_any_element());
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .children(shortcuts.into_iter().enumerate().map(|(i, s)| {
                let text = s.text.clone();
                let tip = s.text.clone();
                let edited = s.clone();
                Self::button(SharedString::from(format!("shortcut-{i}")), &theme)
                    .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(format!("{tip}\n\nRight-click to edit"))).into())
                    .when(enabled, |d| {
                        d.cursor_pointer().hover(|s| s.bg(theme.row_selected)).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(SendShortcut(text.clone()))))
                    })
                    .when(!enabled, |d| d.opacity(0.4))
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |this, _: &MouseDownEvent, window, cx| {
                            cx.stop_propagation();
                            this.open_form(Some(edited.clone()), window, cx);
                        }),
                    )
                    .child(s.label)
            }))
            .child(
                div()
                    .relative()
                    .child(
                        Self::button("shortcut-add".into(), &theme)
                            .cursor_pointer()
                            .text_color(theme.secondary)
                            .hover(|s| s.bg(theme.row_selected).text_color(theme.fg))
                            .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Add a team shortcut: a button that sends a saved prompt, kept in the harness".into())).into())
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                if this.form.is_some() {
                                    this.form = None;
                                    cx.notify();
                                } else {
                                    this.open_form(None, window, cx);
                                }
                            }))
                            .child("+"),
                    )
                    .when_some(form, |d, form| d.child(deferred(anchored().anchor(gpui::Anchor::BottomRight).snap_to_window_with_margin(px(8.)).child(form)).with_priority(1))),
            )
            .into_any_element()
    }
}
