//! Review a Pull Request: the org's open PRs to pick one to review with
//! Claude. Those asked of you come first; filters narrow by whose they
//! are, the repository, drafts and bots, and typing matches the title, repo,
//! number, branch or a person. Up and Down move, Return reviews, Escape
//! closes.

use crate::charts::Theme;
use crate::prs::{PrItem, PrState};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, FontWeight, KeyDownEvent, SharedString, Window};

pub enum PickerEvent {
    Pick(PrItem),
    Cancel,
}

impl EventEmitter<PickerEvent> for PrPicker {}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Whose {
    AskedOfMe,
    Mine,
    Others,
    All,
}

pub struct PrPicker {
    me: Option<String>,
    prs: Option<Result<Vec<PrItem>, String>>,
    search: Entity<editor::Editor>,
    whose: Whose,
    repo: Option<String>,
    drafts: bool,
    bots: bool,
    selected: usize,
    /// The search as last seen, so the selection resets only when it
    /// changes (the editor redraws for its cursor too).
    last_search: String,
    rows: gpui::ScrollHandle,
}

impl PrPicker {
    pub fn new(org: String, me: Option<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Search titles, repos, numbers, branches or people", window, cx);
            editor
        });
        cx.observe(&search, |this, search, cx| {
            let text = search.read(cx).text(cx);
            if text != this.last_search {
                this.last_search = text;
                this.selected = 0;
                this.rows.scroll_to_top_of_item(0);
                cx.notify();
            }
        })
        .detach();
        window.focus(&gpui::Focusable::focus_handle(search.read(cx), cx), cx);
        cx.spawn(async move |this, cx| {
            let loaded = cx.background_executor().spawn(async move { crate::prs::load(&org) }).await;
            this.update(cx, |this, cx| {
                // Asked of me first is the most useful start, if there are any.
                let asked = loaded.as_ref().map(|prs| prs.iter().filter(|p| this.asked_of_me(p)).count()).unwrap_or(0);
                if asked == 0 {
                    this.whose = Whose::All;
                }
                this.prs = Some(loaded.map(|prs| prs.into_iter().filter(|p| p.state == PrState::Open).collect()));
                cx.notify();
            })
            .ok();
        })
        .detach();
        Self {
            me,
            prs: None,
            search,
            whose: Whose::AskedOfMe,
            repo: None,
            drafts: false,
            bots: false,
            selected: 0,
            last_search: String::new(),
            rows: gpui::ScrollHandle::new(),
        }
    }

    fn asked_of_me(&self, pr: &PrItem) -> bool {
        self.me.as_deref().is_some_and(|me| pr.reviewers.iter().any(|r| r.requested && r.login.eq_ignore_ascii_case(me)))
    }

    fn mine(&self, pr: &PrItem) -> bool {
        self.me.as_deref().is_some_and(|me| pr.author.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(me)))
    }

    /// The open PRs through every filter but the repository's, for its
    /// counts; then through that too.
    fn shown(&self, cx: &gpui::App) -> (Vec<(String, usize)>, Vec<PrItem>) {
        let Some(Ok(prs)) = &self.prs else { return (Vec::new(), Vec::new()) };
        let search = self.search.read(cx).text(cx);
        let mut matching: Vec<&PrItem> = prs
            .iter()
            .filter(|p| self.drafts || !p.draft)
            .filter(|p| self.bots || !p.author_is_bot)
            .filter(|p| match self.whose {
                Whose::AskedOfMe => self.asked_of_me(p),
                Whose::Mine => self.mine(p),
                Whose::Others => !self.mine(p),
                Whose::All => true,
            })
            .filter(|p| crate::prs::matches_search(&search, p))
            .collect();
        let mut repos: Vec<(String, usize)> = Vec::new();
        for pr in &matching {
            match repos.iter_mut().find(|(r, _)| *r == pr.repo) {
                Some(entry) => entry.1 += 1,
                None => repos.push((pr.repo.clone(), 1)),
            }
        }
        repos.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        if let Some(repo) = &self.repo {
            matching.retain(|p| &p.repo == repo);
        }
        matching.sort_by(|a, b| self.asked_of_me(b).cmp(&self.asked_of_me(a)).then(b.updated_at.cmp(&a.updated_at)));
        (repos, matching.into_iter().cloned().collect())
    }

    fn key(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        let count = self.shown(cx).1.len();
        match event.keystroke.key.as_str() {
            "escape" => cx.emit(PickerEvent::Cancel),
            "down" => {
                self.selected = (self.selected + 1).min(count.saturating_sub(1));
                self.rows.scroll_to_item(self.selected);
            }
            "up" => {
                self.selected = self.selected.saturating_sub(1);
                self.rows.scroll_to_item(self.selected);
            }
            "enter" => {
                if let Some(pr) = self.shown(cx).1.into_iter().nth(self.selected) {
                    cx.emit(PickerEvent::Pick(pr));
                }
            }
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
    }
}

fn ago(at: chrono::DateTime<chrono::Utc>) -> String {
    let minutes = (chrono::Utc::now() - at).num_minutes().max(0);
    match minutes {
        0..60 => format!("{minutes}m"),
        60..1440 => format!("{}h", minutes / 60),
        _ => format!("{}d", minutes / 1440),
    }
}

impl Render for PrPicker {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let (repos, shown) = self.shown(cx);
        let selected = self.selected.min(shown.len().saturating_sub(1));
        let chip = |id: SharedString, label: String, on: bool| {
            div()
                .id(id)
                .flex_none()
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .border_1()
                .border_color(if on { theme.selected } else { theme.border })
                .when(on, |d| d.bg(theme.selected.opacity(0.15)))
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
        };
        let whose = |label: &str, value: Whose, cx: &mut Context<Self>| {
            chip(SharedString::from(format!("whose-{label}")), label.to_string(), self.whose == value).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.whose = value;
                this.selected = 0;
                cx.notify();
            }))
        };
        let body = match &self.prs {
            None => div().p_4().text_sm().text_color(theme.secondary).child("Loading pull requests").into_any_element(),
            Some(Err(error)) => div().p_4().text_sm().text_color(theme.critical()).child(format!("Couldn't read the pull requests: {error}")).into_any_element(),
            Some(Ok(_)) if shown.is_empty() => div().p_4().text_sm().text_color(theme.secondary).child("No open pull requests match.").into_any_element(),
            Some(Ok(_)) => div()
                .id("picker-rows")
                .flex_1()
                .min_h_0()
                .overflow_y_scroll()
                .track_scroll(&self.rows)
                .children(shown.into_iter().enumerate().map(|(i, pr)| {
                    let asked = self.asked_of_me(&pr);
                    let on = i == selected;
                    let picked = pr.clone();
                    div()
                        .id(("picker-row", i))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_3()
                        .px_3()
                        .py_1p5()
                        .cursor_pointer()
                        .when(on, |d| d.bg(theme.row_selected))
                        .hover(|s| s.bg(theme.row_selected.opacity(0.6)))
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(PickerEvent::Pick(picked.clone()))))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(div().truncate().child(pr.title.clone()))
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .gap_2()
                                        .text_xs()
                                        .text_color(theme.secondary)
                                        .child(format!("{}#{}", pr.repo_name, pr.number))
                                        .when_some(pr.author.clone(), |d, a| d.child(a))
                                        .when(pr.draft, |d| d.child("Draft")),
                                ),
                        )
                        .when(asked, |d| d.child(div().flex_none().px_1p5().rounded_full().text_xs().bg(theme.selected.opacity(0.18)).text_color(theme.selected).child("Asked of you")))
                        .when_some(pr.additions.zip(pr.deletions), |d, (a, del)| {
                            d.child(
                                div()
                                    .flex_none()
                                    .flex()
                                    .flex_row()
                                    .gap_1()
                                    .text_xs()
                                    .child(div().text_color(theme.good()).child(format!("+{a}")))
                                    .child(div().text_color(theme.critical()).child(format!("-{del}"))),
                            )
                        })
                        .child(div().flex_none().w(px(34.)).text_xs().text_color(theme.tertiary).child(ago(pr.updated_at)))
                }))
                .into_any_element(),
        };
        div()
            .id("pr-picker")
            .occlude()
            .w(px(680.))
            .h(px(560.))
            .flex()
            .flex_col()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_xl()
            .shadow_lg()
            .overflow_hidden()
            .capture_key_down(cx.listener(Self::key))
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .p_3()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Review a Pull Request"))
                    .child(div().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(self.search.clone()))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .gap_1()
                            .child(whose("Asked of me", Whose::AskedOfMe, cx))
                            .child(whose("Mine", Whose::Mine, cx))
                            .child(whose("Not mine", Whose::Others, cx))
                            .child(whose("All", Whose::All, cx))
                            .child(div().w(px(8.)))
                            .child(chip("drafts".into(), "Drafts".into(), self.drafts).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.drafts = !this.drafts;
                                cx.notify();
                            })))
                            .child(chip("bots".into(), "Bots".into(), self.bots).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.bots = !this.bots;
                                cx.notify();
                            }))),
                    )
                    .when(repos.len() > 1 || self.repo.is_some(), |d| {
                        d.child(div().flex().flex_row().flex_wrap().gap_1().children(repos.into_iter().take(12).map(|(repo, count)| {
                            let on = self.repo.as_deref() == Some(repo.as_str());
                            let name = repo.rsplit('/').next().unwrap_or(&repo).to_string();
                            let value = repo.clone();
                            chip(SharedString::from(format!("repo-{repo}")), format!("{name} {count}"), on).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.repo = if this.repo.as_deref() == Some(value.as_str()) { None } else { Some(value.clone()) };
                                this.selected = 0;
                                cx.notify();
                            }))
                        })))
                    }),
            )
            .child(body)
            .child(
                div()
                    .flex_none()
                    .px_3()
                    .py_1p5()
                    .border_t_1()
                    .border_color(theme.border)
                    .text_xs()
                    .text_color(theme.tertiary)
                    .child("↑↓ to move · Return to review · Esc to close"),
            )
    }
}
