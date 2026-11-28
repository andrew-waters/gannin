//! One note, open to edit: its markdown highlighted as it's typed
//! (`markdown_lang.rs`), saved half a second after typing stops. Above it,
//! the category and what it links to (and what links to it); below, the
//! todos tied to it. A teammate's shared note opens read only.

use crate::charts::Theme;
use crate::links::{self, Link};
use crate::marra_view::{button, icon_button};
use crate::notes::NotesStore;
use crate::todos::Todo;
use editor::{Editor, EditorEvent};
use gpui::{div, prelude::*, px, AnyElement, ClickEvent, Context, Entity, EventEmitter, Focusable, FontWeight, KeyDownEvent, SharedString, Subscription, Task, Window};
use std::time::Duration;

pub enum NoteEvent {
    /// A link was clicked: the host opens the PR, issue or note.
    Open(Link),
    Deleted,
}

impl EventEmitter<NoteEvent> for NoteEditor {}

pub struct NoteEditor {
    pub id: String,
    store: Entity<NotesStore>,
    editor: Entity<Editor>,
    link_field: Entity<Editor>,
    todo_field: Entity<Editor>,
    category_field: Entity<Editor>,
    preview: bool,
    categories_open: bool,
    /// The category whose name the field is changing, in place of adding one.
    renaming: Option<String>,
    link_error: Option<String>,
    /// The harnesses to share in, open to pick one.
    share_picker: bool,
    /// While a share, update or unshare is with GitHub.
    sharing: bool,
    /// What the last one said: a failure, or a pull request left open.
    share_note: Option<String>,
    _save: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

fn field(placeholder: &str, window: &mut Window, cx: &mut Context<NoteEditor>) -> Entity<Editor> {
    cx.new(|cx| {
        let mut editor = Editor::single_line(window, cx);
        editor.set_placeholder_text(placeholder, window, cx);
        editor
    })
}

impl NoteEditor {
    pub fn new(id: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let store = NotesStore::get(cx);
        let (body, read_only) = store.read(cx).note(&id).map(|n| (n.body.clone(), n.author.is_some())).unwrap_or_default();
        let editor = cx.new(|cx| {
            let mut editor = Editor::multi_line(window, cx);
            editor.set_soft_wrap_mode(language::language_settings::SoftWrap::EditorWidth, cx);
            editor.set_show_gutter(false, cx);
            editor.set_placeholder_text("Write in markdown. The first line is the title.", window, cx);
            editor.set_text(body, window, cx);
            editor.set_read_only(read_only);
            editor
        });
        let buffer = editor.read(cx).buffer().read(cx).as_singleton();
        if let Some(buffer) = buffer {
            crate::markdown_lang::highlight(&buffer, cx);
        }
        let edits = cx.subscribe(&editor, |this: &mut Self, _, event: &EditorEvent, cx| {
            if matches!(event, EditorEvent::BufferEdited) {
                this.schedule_save(cx);
            }
        });
        let observe = cx.observe(&store, |_: &mut Self, _, cx| cx.notify());
        if !read_only {
            window.focus(&editor.focus_handle(cx), cx);
        }
        Self {
            id,
            store,
            editor,
            link_field: field("Link a PR or issue: paste its address", window, cx),
            todo_field: field("Add a todo for this note", window, cx),
            category_field: field("New category", window, cx),
            preview: read_only,
            categories_open: false,
            renaming: None,
            link_error: None,
            share_picker: false,
            sharing: false,
            share_note: None,
            _save: None,
            _subscriptions: vec![edits, observe],
        }
    }

    fn schedule_save(&mut self, cx: &mut Context<Self>) {
        self._save = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(500)).await;
            let _ = this.update(cx, |this, cx| this.save(cx));
        }));
    }

    /// Writes what's typed now; the host calls it before closing the note.
    pub fn save(&mut self, cx: &mut Context<Self>) {
        let body = self.editor.read(cx).text(cx);
        let id = self.id.clone();
        self.store.update(cx, |store, cx| store.set_body(&id, body, cx));
    }

    fn add_link(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.link_field.read(cx).text(cx);
        match links::from_input(&text) {
            Some(link) => {
                let id = self.id.clone();
                self.store.update(cx, |store, cx| store.link(&id, &link, cx));
                self.link_field.update(cx, |e, cx| e.set_text("", window, cx));
                self.link_error = None;
            }
            None if text.trim().is_empty() => {}
            None => self.link_error = Some("That isn't a GitHub PR or issue link".into()),
        }
        cx.notify();
    }

    fn add_todo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.todo_field.read(cx).text(cx);
        let link = Link::Note(self.id.clone());
        self.store.update(cx, |store, cx| store.add_todo(&text, vec![link], cx));
        self.todo_field.update(cx, |e, cx| e.set_text("", window, cx));
    }

    fn add_category(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = self.category_field.read(cx).text(cx);
        if let Some(category) = self.renaming.take() {
            self.store.update(cx, |store, cx| store.rename_category(&category, &name, cx));
            self.category_field.update(cx, |e, cx| {
                e.set_text("", window, cx);
                e.set_placeholder_text("New category", window, cx);
            });
            return;
        }
        let id = self.id.clone();
        self.store.update(cx, |store, cx| {
            if let Some(category) = store.add_category(&name, cx) {
                store.set_category(&id, Some(category), cx);
            }
        });
        self.category_field.update(cx, |e, cx| e.set_text("", window, cx));
    }

    fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let title = self.store.read(cx).note(&self.id).map(|n| n.title()).unwrap_or_default();
        let answer = window.prompt(gpui::PromptLevel::Warning, &format!("Delete \u{201c}{title}\u{201d}?"), Some("It's removed from this Mac, and from the todos linked to it."), &["Delete", "Cancel"], cx);
        cx.spawn(async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            let _ = this.update(cx, |this, cx| {
                this._save = None;
                let id = this.id.clone();
                this.store.update(cx, |store, cx| store.delete_note(&id, cx));
                cx.emit(NoteEvent::Deleted);
            });
        })
        .detach();
    }

    /// Share: straight to the confirmation when there's one harness to
    /// share in, else the harnesses to pick from.
    fn start_share(&mut self, cx: &mut Context<Self>) -> Option<String> {
        let choices = self.store.read(cx).share_choices(&self.id, cx);
        match choices.len() {
            0 => {
                self.share_note = Some("There's no harness to share it in: open a folder with one first.".into());
                None
            }
            1 => choices.into_iter().next().map(|(_, harness)| harness),
            _ => {
                self.share_picker = !self.share_picker;
                None
            }
        }
    }

    /// Shares the note with the team in `harness`, or updates its shared
    /// copy there: committed as `notes/<login>/<id>.md`, once you've said so.
    fn share(&mut self, harness: String, window: &mut Window, cx: &mut Context<Self>) {
        self.share_picker = false;
        self.save(cx);
        let Some(note) = self.store.read(cx).notes.iter().find(|n| n.id == self.id).cloned() else { return };
        let Some(login) = crate::auth::saved_viewer().map(|v| v.login) else {
            self.share_note = Some("Sign in to GitHub to share it.".into());
            cx.notify();
            return;
        };
        let path = crate::notes::shared_path(&login, &note.id);
        let first = note.shared.is_none();
        let detail = format!(
            "It's committed to {harness} as {path}. Anyone who can read {harness} can see it, and it shows on the PRs and issues it links to. Git keeps it in its history, so leave out customer details and anything else sensitive.{}",
            if first { " Later edits stay on this Mac until you update the shared copy." } else { "" }
        );
        let (title, label) = if first { ("Share this note with the team?", "Share") } else { ("Update the shared copy?", "Update") };
        let answer = window.prompt(gpui::PromptLevel::Info, title, Some(&detail), &[label, "Cancel"], cx);
        let text = crate::notes::render_shared(&note, &login);
        let fingerprint = crate::notes::fingerprint(&note.body, &note.links, note.category.as_deref());
        let headline = format!("{} note: {}", if first { "Share" } else { "Update" }, note.title());
        let shared_in = harness.clone();
        cx.spawn(async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            let _ = this.update(cx, |this, cx| {
                this.sharing = true;
                this.share_note = None;
                cx.notify();
            });
            let committed = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to GitHub first.")?;
                    crate::review_record::commit_file(&token, &harness, &path, &headline, &|_| Some(text.clone()))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.sharing = false;
                match committed {
                    Ok(left_open) => {
                        let id = this.id.clone();
                        this.store.update(cx, |store, cx| store.set_shared(&id, Some((shared_in, fingerprint)), cx));
                        this.share_note = left_open;
                    }
                    Err(error) => this.share_note = Some(format!("Couldn't share it: {error}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Takes the shared copy out of the harness, once you've said so; the
    /// note stays here.
    fn unshare(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(note) = self.store.read(cx).notes.iter().find(|n| n.id == self.id).cloned() else { return };
        let (Some(shared), Some(login)) = (note.shared.clone(), crate::auth::saved_viewer().map(|v| v.login)) else { return };
        let Some(harness) = crate::notes::shared_harness(&shared) else { return };
        let path = crate::notes::shared_path(&login, &note.id);
        let detail = format!("It's removed from {harness}, and stays on this Mac. Git's history still has the versions you shared.");
        let answer = window.prompt(gpui::PromptLevel::Warning, "Stop sharing this note?", Some(&detail), &["Stop Sharing", "Cancel"], cx);
        let headline = format!("Unshare note: {}", note.title());
        cx.spawn(async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            let _ = this.update(cx, |this, cx| {
                this.sharing = true;
                this.share_note = None;
                cx.notify();
            });
            let removed = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to GitHub first.")?;
                    crate::review_record::delete_file(&token, &harness, &path, &headline)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.sharing = false;
                match removed {
                    Ok(left_open) => {
                        let id = this.id.clone();
                        this.store.update(cx, |store, cx| store.set_shared(&id, None, cx));
                        this.share_note = left_open;
                    }
                    Err(error) => this.share_note = Some(format!("Couldn't stop sharing it: {error}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The harnesses to share in, the suggested one (the note's PR's or
    /// issue's org's home harness) first.
    fn share_row(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let choices = self.store.read(cx).share_choices(&self.id, cx);
        let mut row = div().flex_none().flex().flex_row().flex_wrap().items_center().gap_1p5().px_4().py_2().border_b_1().border_color(theme.border).bg(theme.sidebar);
        row = row.child(div().text_xs().text_color(theme.secondary).child("Share in"));
        for (n, (org, harness)) in choices.into_iter().enumerate() {
            let label = if harness.split('/').next().is_some_and(|owner| owner.eq_ignore_ascii_case(&org)) { harness.clone() } else { format!("{harness} ({org})") };
            row = row.child(
                chip(SharedString::from(format!("share-in-{n}")), Some("icons/user_group.svg"), label, n == 0, theme)
                    .when(n == 0, |d| d.tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Suggested: the harness of what it links to".into())).into()))
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.share(harness.clone(), window, cx))),
            );
        }
        row.child(div().id("share-cancel").text_xs().text_color(theme.selected).cursor_pointer().child("Cancel").on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
            this.share_picker = false;
            cx.notify();
        })))
        .into_any_element()
    }

    fn categories_row(&self, current: Option<&str>, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let categories = self.store.read(cx).categories.clone();
        let mut row = div().flex_none().flex().flex_row().flex_wrap().items_center().gap_1p5().px_4().py_2().border_b_1().border_color(theme.border).bg(theme.sidebar);
        row = row.child(
            chip("cat-none", None, "None", current.is_none(), theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                let id = this.id.clone();
                this.store.update(cx, |store, cx| store.set_category(&id, None, cx));
                this.categories_open = false;
                cx.notify();
            })),
        );
        for category in categories {
            let (pick, recolour, remove, rename) = (category.id.clone(), category.id.clone(), category.id.clone(), category.id.clone());
            let name = category.name.clone();
            let on = current == Some(category.id.as_str());
            row = row.child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .pl_1p5()
                    .pr_1()
                    .py_0p5()
                    .rounded_md()
                    .border_1()
                    .border_color(if on { theme.selected } else { theme.border })
                    .text_xs()
                    .child(
                        div()
                            .id(SharedString::from(format!("cat-colour-{}", category.id)))
                            .size(px(10.))
                            .rounded_full()
                            .bg(theme.slot(category.colour))
                            .cursor_pointer()
                            .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Change colour".into())).into())
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.store.update(cx, |store, cx| store.recolour_category(&recolour, cx)))),
                    )
                    .child(
                        div().id(SharedString::from(format!("cat-pick-{}", category.id))).cursor_pointer().text_color(theme.fg).child(category.name.clone()).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            let id = this.id.clone();
                            let category = pick.clone();
                            this.store.update(cx, |store, cx| store.set_category(&id, Some(category), cx));
                            this.categories_open = false;
                            cx.notify();
                        })),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("cat-rename-{}", category.id)))
                            .cursor_pointer()
                            .child(gpui::svg().path("icons/pencil.svg").size(px(10.)).text_color(theme.tertiary))
                            .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Rename".into())).into())
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                this.renaming = Some(rename.clone());
                                let name = name.clone();
                                this.category_field.update(cx, |e, cx| {
                                    e.set_text(name, window, cx);
                                    e.set_placeholder_text("Rename category", window, cx);
                                });
                                window.focus(&this.category_field.focus_handle(cx), cx);
                                cx.notify();
                            })),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("cat-remove-{}", category.id)))
                            .px_0p5()
                            .cursor_pointer()
                            .text_color(theme.tertiary)
                            .hover(|s| s.text_color(theme.fg))
                            .child("×")
                            .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Delete category (its notes keep their text)".into())).into())
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.store.update(cx, |store, cx| store.remove_category(&remove, cx)))),
                    ),
            );
        }
        row.child(
            div()
                .w(px(160.))
                .px_2()
                .py_0p5()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .bg(theme.bg)
                .text_xs()
                .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                    if event.keystroke.key == "enter" {
                        cx.stop_propagation();
                        this.add_category(window, cx);
                    }
                }))
                .child(self.category_field.clone()),
        )
        .into_any_element()
    }

    fn todos_section(&self, todos: Vec<Todo>, mine: bool, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let mut section = div().flex_none().flex().flex_col().gap_1().px_4().py_2().border_t_1().border_color(theme.border).bg(theme.sidebar);
        section = section.child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(if todos.is_empty() { "Todos".to_string() } else { format!("Todos · {}", todos.iter().filter(|t| t.done.is_none()).count()) }));
        let due_open = self.store.read(cx).due_menu.clone();
        for todo in todos {
            let listener = cx.listener({
                let id = todo.id.clone();
                move |this, _: &ClickEvent, _, cx| this.store.update(cx, |store, cx| store.toggle_todo(&id, cx))
            });
            let open = due_open.as_deref() == Some(todo.id.as_str());
            section = section.child(todo_row(&todo, open, theme, cx, listener));
        }
        if mine {
            section = section.child(
                div()
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.bg)
                    .text_sm()
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "enter" {
                            cx.stop_propagation();
                            this.add_todo(window, cx);
                        }
                    }))
                    .child(self.todo_field.clone()),
            );
        }
        section.into_any_element()
    }
}

/// A small rounded label: an optional icon, the text, and when `on`, the
/// accent border.
pub fn chip(id: impl Into<SharedString>, icon: Option<&'static str>, label: impl Into<SharedString>, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id.into())
        .flex()
        .flex_row()
        .items_center()
        .gap_1()
        .px_1p5()
        .py_0p5()
        .rounded_md()
        .border_1()
        .border_color(if on { theme.selected } else { theme.border })
        .text_xs()
        .text_color(theme.fg)
        .cursor_pointer()
        .hover(|s| s.bg(theme.row_selected))
        .when_some(icon, |d, icon| d.child(gpui::svg().path(icon).size(px(12.)).text_color(theme.secondary)))
        .child(div().max_w(px(220.)).truncate().child(label.into()))
}

/// A todo with its tick box, ticked or not by `on_toggle`, when it's due,
/// and (on hover) a way to open it in Marra to retitle it or add notes.
pub fn todo_row(todo: &Todo, due_open: bool, theme: &Theme, cx: &mut gpui::App, on_toggle: impl Fn(&ClickEvent, &mut Window, &mut gpui::App) + 'static) -> gpui::Stateful<gpui::Div> {
    let done = todo.done.is_some();
    div()
        .id(SharedString::from(format!("linked-todo-{}", todo.id)))
        .group("linked-todo")
        .flex()
        .flex_row()
        .items_center()
        .gap_2()
        .py_0p5()
        .cursor_pointer()
        .on_click(on_toggle)
        .child(
            div()
                .flex_none()
                .size(px(14.))
                .rounded(px(3.))
                .border_1()
                .flex()
                .items_center()
                .justify_center()
                .map(|d| if done { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected).text_xs().child("✓") } else { d.border_color(theme.secondary) }),
        )
        .child(div().flex_1().min_w_0().truncate().text_sm().text_color(if done { theme.secondary } else { theme.fg }).when(done, |d| d.line_through()).child(todo.text.clone()))
        .when(!todo.notes.is_empty(), |d| d.child(gpui::svg().flex_none().path(crate::icons::NOTE).size(px(11.)).text_color(theme.tertiary)))
        .child(due_chip(todo, todo.id.clone(), due_open, Some("linked-todo"), theme, cx))
        .child(open_todo_button(&todo.id, "linked-todo", theme))
}

/// Opens the todo in Marra, where its title and notes can be edited;
/// shown while `group` is hovered.
pub fn open_todo_button(id: &str, group: &'static str, theme: &Theme) -> AnyElement {
    let thread = format!("t:{id}");
    div()
        .id(SharedString::from(format!("open-todo-{group}-{id}")))
        .flex_none()
        .px_0p5()
        .rounded_sm()
        .invisible()
        .group_hover(group, |s| s.visible())
        .hover(|s| s.bg(theme.row_selected))
        .child(gpui::svg().path("icons/arrow_up_right.svg").size(px(12.)).text_color(theme.secondary))
        .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Open to edit it and add notes".into())).into())
        .on_click(move |_, _, cx| {
            cx.stop_propagation();
            let thread = thread.clone();
            cx.defer(move |cx| crate::marra_view::show_thread(Some(thread), cx));
        })
        .into_any_element()
}

/// A due date's colour: red once overdue or within the hour, orange on the
/// day.
pub fn due_colour(urgency: crate::todos::Urgency, theme: &Theme) -> gpui::Hsla {
    match urgency {
        crate::todos::Urgency::Overdue | crate::todos::Urgency::Imminent => theme.critical(),
        crate::todos::Urgency::Today => gpui::rgb(0xFF9F0A).into(),
        crate::todos::Urgency::Soon => theme.fg,
        crate::todos::Urgency::Later => theme.secondary,
    }
}

/// When a todo's due, opening a menu to change it. With none, it's "Due
/// Date", shown only while `group` is hovered when there's one; a done
/// todo just shows when it was due. `key` names its menu.
pub fn due_chip(todo: &Todo, key: String, open: bool, group: Option<&'static str>, theme: &Theme, cx: &mut gpui::App) -> AnyElement {
    let now = chrono::Local::now().naive_local();
    let (label, colour) = match todo.due {
        Some(due) if todo.done.is_some() => (crate::todos::due_label(due, todo.due_time, now).0, theme.tertiary),
        Some(due) => {
            let (label, urgency) = crate::todos::due_label(due, todo.due_time, now);
            (label, due_colour(urgency, theme))
        }
        None if todo.done.is_some() => return div().into_any_element(),
        None => ("Due Date".to_string(), theme.tertiary),
    };
    let id = key.clone();
    let pick_id = todo.id.clone();
    let unset = todo.due.is_none();
    let current = todo.due;
    let chip = div()
        .id(SharedString::from(format!("todo-due-{key}")))
        .flex_none()
        .px_1()
        .rounded_sm()
        .text_xs()
        .text_color(colour)
        .hover(|s| s.bg(theme.row_selected))
        .when(unset && !open, |d| match group {
            Some(group) => d.invisible().group_hover(group, |s| s.visible()),
            None => d,
        })
        .child(label)
        .when(todo.done.is_none(), |d| {
            d.cursor_pointer().on_click(move |_, window, cx| {
                cx.stop_propagation();
                let store = NotesStore::get(cx);
                store.update(cx, |s, cx| s.toggle_due_menu(&id, current, window, cx));
            })
        });
    let menu = open.then(|| {
        due_menu(&key, todo.when(), theme, cx, std::rc::Rc::new(move |due, cx| {
            let store = NotesStore::get(cx);
            store.update(cx, |s, cx| s.set_due(&pick_id, due, cx));
        }))
    });
    div().flex_none().child(chip).children(menu).into_any_element()
}

/// Where a due date is picked: typed as a day and maybe a time ("29 Nov
/// 14:00", "fri 9am", or a time alone for the day already set), a day on a
/// month's calendar, or a quick choice; and taken off. A day picked keeps
/// the time already set.
pub fn due_menu(key: &str, current: Option<crate::todos::When>, theme: &Theme, cx: &mut gpui::App, on_pick: std::rc::Rc<dyn Fn(Option<crate::todos::When>, &mut gpui::App)>) -> AnyElement {
    let now = chrono::Local::now().naive_local();
    let today = now.date();
    let store = NotesStore::get(cx);
    let (field, month, error) = {
        let s = store.read(cx);
        (s.due_field.clone(), s.due_month, s.due_error)
    };
    let time = current.and_then(|c| c.1);
    let close = |cx: &mut gpui::App| {
        let store = NotesStore::get(cx);
        store.update(cx, |s, cx| s.close_due_menu(cx));
    };
    let mut panel = div()
        .id(SharedString::from(format!("due-menu-{key}")))
        .mt_1()
        .w(px(252.))
        .flex()
        .flex_col()
        .gap_2()
        .p_2()
        .bg(theme.popover)
        .border_1()
        .border_color(theme.border)
        .rounded_lg()
        .shadow_lg()
        .occlude()
        .on_mouse_down_out(move |_, _, cx| close(cx));
    // Typed: Return sets it, Escape closes.
    if let Some(field) = field {
        let (typed, pick) = (field.clone(), on_pick.clone());
        let base = current.map(|c| c.0);
        panel = panel.child(
            div()
                .px_2()
                .py_1()
                .rounded_md()
                .border_1()
                .border_color(if error { theme.critical() } else { theme.border })
                .bg(theme.bg)
                .text_sm()
                .capture_key_down(move |event: &KeyDownEvent, _, cx| match event.keystroke.key.as_str() {
                    "enter" => {
                        cx.stop_propagation();
                        let text = typed.read(cx).text(cx);
                        match crate::todos::parse_when(&text, chrono::Local::now().naive_local(), base) {
                            Some(when) => pick(Some(when), cx),
                            None => {
                                let store = NotesStore::get(cx);
                                store.update(cx, |s, cx| s.set_due_error(true, cx));
                            }
                        }
                    }
                    "escape" => {
                        cx.stop_propagation();
                        let store = NotesStore::get(cx);
                        store.update(cx, |s, cx| s.close_due_menu(cx));
                    }
                    _ => {}
                })
                .child(field),
        );
        if error {
            panel = panel.child(div().text_xs().text_color(theme.critical()).child("Try 29 Nov, fri 9am, 14:00 or in 3 days"));
        }
    }
    // The month: a day clicked is the day, at the time already set.
    let shift = |by: i32, label: &'static str, id: String| {
        div()
            .id(SharedString::from(id))
            .px_1p5()
            .rounded_sm()
            .cursor_pointer()
            .text_color(theme.secondary)
            .hover(|s| s.bg(theme.row_selected).text_color(theme.fg))
            .child(label)
            .on_click(move |_, _, cx| {
                cx.stop_propagation();
                let store = NotesStore::get(cx);
                store.update(cx, |s, cx| s.shift_due_month(by, cx));
            })
    };
    let mut calendar = div().flex().flex_col().gap_0p5().child(
        div()
            .flex()
            .flex_row()
            .items_center()
            .text_sm()
            .child(div().flex_1().pl_1().font_weight(FontWeight::SEMIBOLD).child(month.format("%B %Y").to_string()))
            .child(shift(-1, "‹", format!("due-prev-{key}")))
            .child(shift(1, "›", format!("due-next-{key}"))),
    );
    let cell = || div().w(px(32.)).h(px(24.)).flex().items_center().justify_center().text_xs();
    calendar = calendar.child(div().flex().flex_row().children(["M", "T", "W", "T", "F", "S", "S"].into_iter().map(|d| cell().text_color(theme.tertiary).child(d))));
    for (w, week) in crate::todos::month_grid(month).into_iter().enumerate() {
        let mut row = div().flex().flex_row();
        for (d, (date, in_month)) in week.into_iter().enumerate() {
            let chosen = current.is_some_and(|c| c.0 == date);
            let pick = on_pick.clone();
            row = row.child(
                cell()
                    .id(SharedString::from(format!("due-day-{key}-{w}-{d}")))
                    .rounded_md()
                    .cursor_pointer()
                    .text_color(if chosen { theme.on_selected } else if !in_month || date < today { theme.tertiary } else { theme.fg })
                    .when(chosen, |c| c.bg(theme.selected))
                    .when(date == today && !chosen, |c| c.border_1().border_color(theme.selected))
                    .when(!chosen, |c| c.hover(|s| s.bg(theme.row_selected)))
                    .child(date.format("%-d").to_string())
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        pick(Some((date, time)), cx);
                    }),
            );
        }
        calendar = calendar.child(row);
    }
    panel = panel.child(calendar);
    // Quick choices, and taking the time or the date off.
    let quick = |id: String, label: String, when: Option<crate::todos::When>| {
        let pick = on_pick.clone();
        div()
            .id(SharedString::from(id))
            .px_1p5()
            .py_0p5()
            .rounded_md()
            .border_1()
            .border_color(theme.border)
            .text_xs()
            .cursor_pointer()
            .hover(|s| s.bg(theme.row_selected))
            .child(label)
            .on_click(move |_, _, cx| {
                cx.stop_propagation();
                pick(when, cx);
            })
    };
    let mut chips = div().flex().flex_row().flex_wrap().gap_1();
    for (i, (label, date)) in crate::todos::due_choices(today).into_iter().enumerate().filter(|(i, _)| *i != 0) {
        chips = chips.child(quick(format!("due-{key}-{i}"), label.to_string(), Some((date, time))));
    }
    if let Some((date, Some(_))) = current {
        chips = chips.child(quick(format!("due-{key}-no-time"), "No Time".into(), Some((date, None))));
    }
    if current.is_some() {
        chips = chips.child(quick(format!("due-{key}-none"), "No Due Date".into(), None));
    }
    panel = panel.child(chips);
    gpui::deferred(gpui::anchored().snap_to_window_with_margin(px(8.)).child(panel)).with_priority(3).into_any_element()
}

impl Render for NoteEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let store = self.store.read(cx);
        let Some(note) = store.note(&self.id).cloned() else {
            return div().flex_1().p_4().text_sm().text_color(theme.secondary).child("This note was deleted.").into_any_element();
        };
        let mine = note.author.is_none();
        let category = store.category(note.category.as_deref()).cloned();
        let this_note = Link::Note(self.id.clone());
        let (from, todos) = store.linked(&this_note);
        let from: Vec<(String, String)> = from.into_iter().map(|n| (n.id.clone(), n.title())).collect();
        let todos: Vec<Todo> = todos.into_iter().cloned().collect();
        let links: Vec<(String, Link, String)> = note
            .links
            .iter()
            .filter_map(|text| {
                let link = Link::parse(text)?;
                let label = match &link {
                    Link::Note(id) => store.note(id).map(|n| n.title()).unwrap_or_else(|| "Deleted note".into()),
                    other => other.short(),
                };
                Some((text.clone(), link, label))
            })
            .collect();

        // Category, links in and out, and what can be done to the note.
        let mut bar = div().flex_none().flex().flex_row().flex_wrap().items_center().gap_1p5().px_4().py_2().border_b_1().border_color(theme.border);
        bar = bar.child({
            let c = chip("note-category", None, category.as_ref().map(|c| c.name.clone()).unwrap_or_else(|| "No category".into()), self.categories_open, &theme);
            let c = match category.as_ref() {
                // The colour's dot ahead of the name.
                Some(category) => c.child(div().size(px(8.)).rounded_full().bg(theme.slot(category.colour))).flex_row_reverse(),
                None => c,
            };
            if mine {
                c.on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    this.categories_open = !this.categories_open;
                    cx.notify();
                }))
            } else {
                c.cursor_default()
            }
        });
        for (n, (text, link, label)) in links.into_iter().enumerate() {
            let opened = link.clone();
            bar = bar.child(
                chip(SharedString::from(format!("note-link-{n}")), Some(link.icon()), label, false, &theme)
                    .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(NoteEvent::Open(opened.clone()))))
                    .when(mine, |d| {
                        d.child(
                            div()
                                .id(SharedString::from(format!("note-unlink-{n}")))
                                .text_color(theme.tertiary)
                                .hover(|s| s.text_color(theme.fg))
                                .child("×")
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    cx.stop_propagation();
                                    let id = this.id.clone();
                                    this.store.update(cx, |store, cx| store.unlink(&id, &text, cx));
                                })),
                        )
                    }),
            );
        }
        // PRs and issues the text mentions count too.
        for (n, link) in note.mentioned().into_iter().enumerate() {
            let opened = link.clone();
            bar = bar.child(
                chip(SharedString::from(format!("note-mention-{n}")), Some(link.icon()), link.short(), false, &theme)
                    .opacity(0.8)
                    .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Mentioned in the text".into())).into())
                    .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(NoteEvent::Open(opened.clone())))),
            );
        }
        for (id, title) in from {
            let opened = Link::Note(id.clone());
            bar = bar.child(
                chip(SharedString::from(format!("note-from-{id}")), Some(crate::icons::NOTE), format!("From: {title}"), false, &theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(NoteEvent::Open(opened.clone())))),
            );
        }
        if mine {
            bar = bar.child(
                div()
                    .w(px(200.))
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .border_1()
                    .border_color(if self.link_error.is_some() { theme.critical() } else { theme.border })
                    .bg(theme.bg)
                    .text_xs()
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "enter" {
                            cx.stop_propagation();
                            this.add_link(window, cx);
                        }
                    }))
                    .child(self.link_field.clone()),
            );
        }
        if let Some(author) = &note.author {
            bar = bar.child(div().text_xs().text_color(theme.secondary).child(format!("Shared by {author}")));
        }
        bar = bar.child(div().flex_1());
        // Private, shared, or shared with edits since.
        if mine {
            if self.sharing {
                bar = bar.child(div().text_xs().text_color(theme.secondary).child("Talking to GitHub"));
            } else if let Some(shared) = &note.shared {
                let harness = crate::notes::shared_harness(shared).unwrap_or_else(|| shared.clone());
                bar = bar.child(
                    chip("note-shared", Some("icons/user_group.svg"), format!("Shared in {harness}"), false, &theme)
                        .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Stop sharing".into())).into())
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.unshare(window, cx))),
                );
                if note.unpublished() {
                    bar = bar.child(button("note-update-shared", "Update Shared Copy", true, &theme).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.share(harness.clone(), window, cx))));
                }
            } else {
                bar = bar.child(icon_button("note-share", "icons/user_group.svg", "Share with the team", self.share_picker, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                    if let Some(harness) = this.start_share(cx) {
                        this.share(harness, window, cx);
                    }
                    cx.notify();
                })));
            }
        }
        bar = bar.child(button("note-preview", if self.preview { "Edit" } else { "Preview" }, false, &theme).when(mine, |b| {
            b.on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                this.preview = !this.preview;
                if !this.preview {
                    window.focus(&this.editor.focus_handle(cx), cx);
                }
                cx.notify();
            }))
        }));
        if mine {
            bar = bar.child(icon_button("note-delete", "icons/trash.svg", "Delete note", false, &theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.delete(window, cx))));
        }
        let error = self.link_error.clone().or_else(|| self.share_note.clone());

        let body = if self.preview {
            div().id("note-preview-body").flex_1().min_h_0().overflow_y_scroll().px_4().py_3().child(crate::markdown::markdown(&format!("note-{}", self.id), &note.body, &theme)).into_any_element()
        } else {
            div().flex_1().min_h_0().px_3().py_2().child(self.editor.clone()).into_any_element()
        };
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(bar)
            .when_some(error, |d, e| d.child(div().px_4().py_1().text_xs().text_color(theme.critical()).child(e)))
            .when(self.categories_open && mine, |d| d.child(self.categories_row(note.category.as_deref(), &theme, cx)))
            .when(self.share_picker && mine && note.shared.is_none(), |d| d.child(self.share_row(&theme, cx)))
            .child(body)
            .child(self.todos_section(todos, mine, &theme, cx))
            .into_any_element()
    }
}

/// A single-line field for adding a todo in `linked_section`.
pub fn todo_field<V: 'static>(window: &mut Window, cx: &mut Context<V>) -> Entity<Editor> {
    cx.new(|cx| {
        let mut editor = Editor::single_line(window, cx);
        editor.set_placeholder_text("Add a todo", window, cx);
        editor
    })
}

/// The notes and todos about `link`, for its drawer, page or session. A
/// note opens in Marra; a todo ticks off here; New Note and the field
/// (when there is one) start them already linked. The host observes
/// `NotesStore` so this redraws as they change.
pub fn linked_section(link: &Link, field: Option<&Entity<Editor>>, theme: &Theme, cx: &mut gpui::App) -> AnyElement {
    let store = NotesStore::get(cx);
    let (notes, todos, due_open) = {
        let s = store.read(cx);
        let (notes, todos) = s.linked(link);
        let notes: Vec<(crate::notes::Note, Option<gpui::Hsla>, bool)> = notes.into_iter().map(|n| (n.clone(), s.category(n.category.as_deref()).map(|c| theme.slot(c.colour)), s.expanded.contains(&n.id))).collect();
        let mut todos: Vec<Todo> = todos.into_iter().cloned().collect();
        todos.sort_by_key(|t| (t.done.is_some(), t.due.is_none(), t.due, t.added));
        (notes, todos, s.due_menu.clone())
    };
    let key = link.to_string();
    let open_note = |id: String| move |_: &ClickEvent, _: &mut Window, cx: &mut gpui::App| {
        // After this window's update: a docked Marra shows in this window.
        let thread = format!("n:{id}");
        cx.defer(move |cx| crate::marra_view::show_thread(Some(thread), cx));
    };
    let new_note = {
        let (store, link) = (store.clone(), link.clone());
        move |_: &ClickEvent, _: &mut Window, cx: &mut gpui::App| {
            let id = store.update(cx, |s, cx| s.new_note("", vec![link.clone()], cx));
            let thread = format!("n:{id}");
            cx.defer(move |cx| crate::marra_view::show_thread(Some(thread), cx));
        }
    };
    let count = notes.len() + todos.iter().filter(|t| t.done.is_none()).count();
    let mut section = div().flex().flex_col().gap_1();
    section = section.child(
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .child(div().flex_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(if count == 0 { "Notes and todos".to_string() } else { format!("Notes and todos · {count}") }))
            .child(button(SharedString::from(format!("linked-new-note-{key}")), "New Note", false, theme).on_click(new_note)),
    );
    // Each note opens out to read here; the arrow opens it in Marra.
    for (note, dot, open) in notes {
        let (toggle_store, toggle_id) = (store.clone(), note.id.clone());
        let id = note.id.clone();
        section = section.child(
            div()
                .flex()
                .flex_col()
                .rounded_md()
                .when(open, |d| d.bg(theme.tile))
                .child(
                    div()
                        .id(SharedString::from(format!("linked-note-{key}-{id}")))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .py_0p5()
                        .px_1()
                        .rounded_md()
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.tile))
                        .on_click(move |_, _, cx| toggle_store.update(cx, |s, cx| s.toggle_expanded(&toggle_id, cx)))
                        .child(gpui::svg().path(if open { "icons/chevron_down.svg" } else { "icons/chevron_right.svg" }).size(px(10.)).text_color(theme.tertiary))
                        .child(gpui::svg().path(crate::icons::NOTE).size(px(12.)).text_color(dot.unwrap_or(theme.secondary)))
                        .child(div().flex_1().min_w_0().truncate().text_sm().text_color(theme.fg).child(note.title()))
                        .when_some(note.author.clone(), |d, a| d.child(div().flex_none().text_xs().text_color(theme.tertiary).child(a)))
                        .child(
                            div()
                                .id(SharedString::from(format!("linked-note-open-{key}-{id}")))
                                .flex_none()
                                .px_0p5()
                                .rounded_sm()
                                .hover(|s| s.bg(theme.row_selected))
                                .child(gpui::svg().path("icons/arrow_up_right.svg").size(px(12.)).text_color(theme.secondary))
                                .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Open in Marra".into())).into())
                                .on_click({
                                    let open = open_note(id.clone());
                                    move |event, window, cx| {
                                        cx.stop_propagation();
                                        open(event, window, cx);
                                    }
                                }),
                        ),
                )
                .when(!open && !note.preview().is_empty(), |d| d.child(div().pl(px(30.)).pr_1().truncate().text_xs().text_color(theme.secondary).child(note.preview())))
                .when(open, |d| {
                    d.child(
                        div()
                            .id(SharedString::from(format!("linked-note-body-{key}-{id}")))
                            .max_h(px(320.))
                            .overflow_y_scroll()
                            .px_3()
                            .pb_2()
                            .text_sm()
                            .child(crate::markdown::markdown(&format!("linked-note-md-{key}-{id}"), &note.body, theme)),
                    )
                }),
        );
    }
    for todo in todos {
        let (store, id) = (store.clone(), todo.id.clone());
        let open = due_open.as_deref() == Some(todo.id.as_str());
        section = section.child(todo_row(&todo, open, theme, cx, move |_, _, cx| store.update(cx, |s, cx| s.toggle_todo(&id, cx))).px_1());
    }
    if let Some(field) = field {
        let (store, link, field_entity) = (store.clone(), link.clone(), field.clone());
        section = section.child(
            div()
                .px_2()
                .py_0p5()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .bg(theme.bg)
                .text_sm()
                .capture_key_down(move |event: &KeyDownEvent, window, cx| {
                    if event.keystroke.key != "enter" {
                        return;
                    }
                    cx.stop_propagation();
                    let text = field_entity.read(cx).text(cx);
                    store.update(cx, |s, cx| s.add_todo(&text, vec![link.clone()], cx));
                    field_entity.update(cx, |e, cx| e.set_text("", window, cx));
                })
                .child(field.clone()),
        );
    }
    section.into_any_element()
}

/// How many notes and open todos are about `link`; a click opens its
/// drawer, where they're listed.
pub fn notes_chip(link: &Link, theme: &Theme, cx: &mut gpui::App) -> gpui::Stateful<gpui::Div> {
    let count = NotesStore::get(cx).read(cx).count(link);
    let link = link.clone();
    div()
        .id("notes-chip")
        .flex_none()
        .flex()
        .flex_row()
        .items_center()
        .gap_1()
        .px_2()
        .py_0p5()
        .rounded_md()
        .border_1()
        .border_color(theme.border)
        .text_xs()
        .text_color(if count > 0 { theme.fg } else { theme.secondary })
        .cursor_pointer()
        .hover(|s| s.bg(theme.row_selected))
        .child(gpui::svg().path(crate::icons::NOTE).size(px(14.)).text_color(if count > 0 { theme.slot(3) } else { theme.secondary }))
        .child(if count > 0 { count.to_string() } else { "Notes".into() })
        .tooltip(|_, cx| cx.new(|_| crate::issues::Tooltip("Your notes and todos about this".into())).into())
        // After this window's update, which the drawer opens in.
        .on_click(move |_, _, cx| {
            let link = link.clone();
            cx.defer(move |cx| crate::shell::open_link(&link, cx));
        })
}
