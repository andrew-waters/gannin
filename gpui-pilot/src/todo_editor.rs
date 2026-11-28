//! A todo opened in Marra: its title and your notes on it, saved as you
//! type; when it's due; what it links to; and, for one from a plan, the
//! plan and the item's own wording, which retitling it here leaves alone.

use crate::charts::Theme;
use crate::links::Link;
use crate::notes::NotesStore;
use editor::{Editor, EditorEvent};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, FontWeight, SharedString, Subscription, Task, Window};
use std::time::Duration;

pub enum TodoEvent {
    Open(Link),
    Removed,
}

pub struct TodoEditor {
    pub id: String,
    store: Entity<NotesStore>,
    title: Entity<Editor>,
    notes: Entity<Editor>,
    _save: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<TodoEvent> for TodoEditor {}

impl TodoEditor {
    pub fn new(id: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let store = NotesStore::get(cx);
        let (text, notes) = store.read(cx).todo(&id).map(|t| (t.text.clone(), t.notes.clone())).unwrap_or_default();
        let title = cx.new(|cx| {
            let mut editor = Editor::single_line(window, cx);
            editor.set_placeholder_text("Title", window, cx);
            editor.set_text(text, window, cx);
            editor
        });
        let notes = cx.new(|cx| {
            let mut editor = Editor::multi_line(window, cx);
            editor.set_soft_wrap_mode(language::language_settings::SoftWrap::EditorWidth, cx);
            editor.set_show_gutter(false, cx);
            editor.set_placeholder_text("Your notes on it. They stay on this Mac.", window, cx);
            editor.set_text(notes, window, cx);
            editor
        });
        let edited = |this: &mut Self, _: Entity<Editor>, event: &EditorEvent, cx: &mut Context<Self>| {
            if matches!(event, EditorEvent::BufferEdited) {
                this.schedule_save(cx);
            }
        };
        let subscriptions = vec![cx.subscribe(&title, edited), cx.subscribe(&notes, edited), cx.observe(&store, |_: &mut Self, _, cx| cx.notify())];
        Self { id, store, title, notes, _save: None, _subscriptions: subscriptions }
    }

    fn schedule_save(&mut self, cx: &mut Context<Self>) {
        self._save = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(400)).await;
            let _ = this.update(cx, |this, cx| this.save(cx));
        }));
    }

    /// Writes what's typed now; the host calls it before closing the todo.
    pub fn save(&mut self, cx: &mut Context<Self>) {
        let (title, notes) = (self.title.read(cx).text(cx), self.notes.read(cx).text(cx));
        let id = self.id.clone();
        self.store.update(cx, |store, cx| store.edit_todo(&id, &title, &notes, cx));
    }
}

impl Render for TodoEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let (todo, menu_open) = {
            let s = self.store.read(cx);
            (s.todo(&self.id).cloned(), s.due_menu.as_deref() == Some(self.id.as_str()))
        };
        let Some(todo) = todo else {
            return div().flex_1().p_4().text_sm().text_color(theme.secondary).child("This todo was removed.").into_any_element();
        };
        let done = todo.done.is_some();
        let label = |text: &str| div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text.to_string());
        let field = |editor: Entity<Editor>| div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(editor);

        // Done, when it's due, and taking it off the list.
        let toggle_id = todo.id.clone();
        let remove_id = todo.id.clone();
        let bar = div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .child(
                div()
                    .id("todo-editor-done")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1p5()
                    .text_sm()
                    .cursor_pointer()
                    .child(div().size(px(14.)).rounded(px(3.)).border_1().flex().items_center().justify_center().map(|d| if done { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected).text_xs().child("✓") } else { d.border_color(theme.secondary) }))
                    .child(if done { "Done" } else { "Mark Done" })
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.store.update(cx, |s, cx| s.toggle_todo(&toggle_id, cx)))),
            )
            .child(crate::note_editor::due_chip(&todo, todo.id.clone(), menu_open, None, &theme, cx))
            .child(div().flex_1())
            .child(crate::marra_view::button("todo-editor-remove", "Remove", false, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.store.update(cx, |s, cx| s.remove_todo(&remove_id, cx));
                cx.emit(TodoEvent::Removed);
            })));

        // Where it's from: the plan and its item's own words, and links.
        let mut from = div().flex().flex_col().gap_1();
        if let Some(plan) = todo.plan.clone() {
            let url = plan.url();
            from = from
                .child(label("From the plan"))
                .child(div().flex().flex_row().child(crate::note_editor::chip("todo-editor-plan", Some(crate::harness::HarnessKind::Plans.icon()), plan.title.clone(), false, &theme).on_click(move |_, _, cx| cx.open_url(&url))))
                .child(div().text_sm().text_color(theme.secondary).child(format!("Item: {}", plan.item)))
                .when(todo.text != plan.item, |d| d.child(div().text_xs().text_color(theme.tertiary).child("Your title is yours: the plan keeps its wording.")));
        }
        let links = crate::links::parse_all(&todo.links);
        if !links.is_empty() {
            let store = self.store.read(cx);
            let chips: Vec<gpui::AnyElement> = links
                .into_iter()
                .enumerate()
                .map(|(n, link)| {
                    let text = match &link {
                        Link::Note(id) => store.note(id).map(|n| n.title()).unwrap_or_else(|| "Deleted note".into()),
                        other => other.short(),
                    };
                    crate::note_editor::chip(SharedString::from(format!("todo-editor-link-{n}")), Some(link.icon()), text, false, &theme)
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(TodoEvent::Open(link.clone()))))
                        .into_any_element()
                })
                .collect();
            from = from.child(label("About")).child(div().flex().flex_row().flex_wrap().gap_1().children(chips));
        }

        div()
            .id("todo-editor")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_3()
            .p_4()
            .child(bar)
            .child(div().flex().flex_col().gap_1().child(label("Title")).child(field(self.title.clone()).text_base()))
            .child(from)
            .child(div().flex().flex_col().gap_1().child(label("Notes")).child(field(self.notes.clone()).min_h(px(160.)).text_sm()))
            .child(div().text_xs().text_color(theme.tertiary).child(format!("Added {}", crate::todos::when(todo.added))))
            .into_any_element()
    }
}
