//! The team's harness, as Gannin's sidebar lists it: plans, requirements,
//! decisions, findings, skills, prompts, learnings, research, refines and
//! specialists, each a page of its documents, newest first. A document opens
//! in a drawer with its facts and its text.
//!
//! Read with git from each of the org's harnesses' default branch
//! (`harness_git`), each document parsed as Gannin parses it
//! (`harness_doc`). Read only: writing or editing documents isn't here.

use crate::charts::Theme;
use chrono::{DateTime, Utc};
use gpui::{div, prelude::*, px, uniform_list, ClickEvent, Context, Entity, EventEmitter, FontWeight, SharedString, Window};
use std::ops::Range;
use std::sync::Arc;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum HarnessKind {
    Plans,
    Requirements,
    Decisions,
    Findings,
    Skills,
    Prompts,
    Learnings,
    Research,
    Refines,
    Specialists,
}

impl HarnessKind {
    pub const ALL: [HarnessKind; 10] = [
        HarnessKind::Plans,
        HarnessKind::Requirements,
        HarnessKind::Decisions,
        HarnessKind::Findings,
        HarnessKind::Skills,
        HarnessKind::Prompts,
        HarnessKind::Learnings,
        HarnessKind::Research,
        HarnessKind::Refines,
        HarnessKind::Specialists,
    ];

    pub fn title(self) -> &'static str {
        match self {
            HarnessKind::Plans => "Plans",
            HarnessKind::Requirements => "Requirements",
            HarnessKind::Decisions => "Decisions",
            HarnessKind::Findings => "Findings",
            HarnessKind::Skills => "Skills",
            HarnessKind::Prompts => "Prompts",
            HarnessKind::Learnings => "Learnings",
            HarnessKind::Research => "Research",
            HarnessKind::Refines => "Refines",
            HarnessKind::Specialists => "Specialists",
        }
    }
}

/// A document in the harness.
#[derive(Clone)]
pub struct Doc {
    pub path: String,
    pub harness: String,
    pub branch: String,
    pub kind: HarnessKind,
    pub title: String,
    pub text: String,
    pub status: Option<String>,
    pub summary: Option<String>,
    pub date: Option<DateTime<Utc>>,
    pub area: Option<String>,
    pub tasks: i64,
    pub tasks_done: i64,
    /// Issues it's about (`isSubject`) or mentions: (repo, number, about).
    pub references: Vec<(Option<String>, i64, bool)>,
    /// Every front matter field, for the drawer's facts.
    pub front_matter: Vec<(String, String)>,
    /// Has front matter and a summary, as Gannin's `followsStandard`.
    pub standard: bool,
}

impl Doc {
    pub fn url(&self) -> String {
        format!("https://github.com/{}/blob/{}/{}", self.harness, self.branch, self.path)
    }

    /// The text without its front matter, which the drawer shows as facts.
    pub fn body(&self) -> &str {
        let text = self.text.trim_start();
        if let Some(rest) = text.strip_prefix("---") {
            if let Some(end) = rest.find("\n---") {
                return rest[end + 4..].trim_start();
            }
        }
        text
    }
}

/// Every document in the org's harnesses. Fetches and runs git: call off
/// the main thread.
pub fn load(org: &str) -> Vec<Doc> {
    let mut docs: Vec<Doc> = crate::harness_git::snapshots(org)
        .iter()
        .flat_map(|snapshot| snapshot.files.iter().filter_map(|(path, text)| crate::harness_doc::parse(path, text, &snapshot.repo, &snapshot.branch)))
        .collect();
    // Newest first; undated ones after, by title.
    docs.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase())));
    docs
}

/// How many documents of each kind, for the Harness panel.
pub fn counts(docs: &[Doc]) -> std::collections::HashMap<HarnessKind, usize> {
    let mut counts = std::collections::HashMap::new();
    for doc in docs {
        *counts.entry(doc.kind).or_default() += 1;
    }
    counts
}

/// A row clicked: the workspace opens the document in a drawer.
pub struct OpenDoc(pub Doc);

impl EventEmitter<OpenDoc> for HarnessPage {}

pub struct HarnessPage {
    org: Option<String>,
    kind: HarnessKind,
    docs: Arc<Vec<Doc>>,
    rows: Vec<usize>,
    search: Entity<editor::Editor>,
    /// The window's Filter box, narrowing the list with the search.
    outer: String,
    loading: bool,
    generation: u64,
    _subscription: gpui::Subscription,
}

impl HarnessPage {
    pub fn new(org: Option<String>, kind: HarnessKind, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Title, summary, area or path", window, cx);
            editor
        });
        let subscription = cx.subscribe(&search, |page, _, event: &editor::EditorEvent, cx| {
            if matches!(event, editor::EditorEvent::BufferEdited) {
                page.refilter(cx);
                cx.notify();
            }
        });
        let mut page = Self { org, kind, docs: Arc::new(Vec::new()), rows: Vec::new(), search, outer: String::new(), loading: true, generation: 0, _subscription: subscription };
        page.load(cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.load(cx);
        }
    }

    /// The window's Filter box.
    pub fn set_outer(&mut self, text: &str, cx: &mut Context<Self>) {
        if self.outer != text {
            self.outer = text.to_string();
            self.refilter(cx);
            cx.notify();
        }
    }

    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.load(cx);
    }

    pub fn tab_count(&self) -> Option<String> {
        (!self.loading).then(|| self.rows.len().to_string())
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        self.generation += 1;
        let generation = self.generation;
        let kind = self.kind;
        cx.spawn(async move |this, cx| {
            let docs: Vec<Doc> = cx.background_executor().spawn(async move { load(&org).into_iter().filter(|d| d.kind == kind).collect() }).await;
            this.update(cx, |page, cx| {
                if page.generation == generation {
                    page.docs = Arc::new(docs);
                    page.loading = false;
                    page.refilter(cx);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    /// Every word typed is in the title, summary, area, status or path.
    fn refilter(&mut self, cx: &mut Context<Self>) {
        let typed = self.search.read(cx).text(cx);
        let words: Vec<String> = typed.split_whitespace().chain(self.outer.split_whitespace()).map(str::to_lowercase).collect();
        self.rows = self
            .docs
            .iter()
            .enumerate()
            .filter(|(_, d)| {
                let fields = [Some(d.title.as_str()), d.summary.as_deref(), d.area.as_deref(), d.status.as_deref(), Some(d.path.as_str())];
                let haystack: String = fields.iter().flatten().map(|f| f.to_lowercase()).collect::<Vec<_>>().join(" ");
                words.iter().all(|w| haystack.contains(w.as_str()))
            })
            .map(|(i, _)| i)
            .collect();
    }

    fn row(&self, index: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let doc = &self.docs[self.rows[index]];
        let opened = doc.clone();
        let plans = self.kind == HarnessKind::Plans;
        div()
            .id(("harness-doc", index))
            .w_full()
            .h(px(46.))
            .px_4()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .border_b_1()
            .border_color(theme.grid)
            .cursor_pointer()
            .hover(|s| s.bg(theme.tile))
            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(OpenDoc(opened.clone()))))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(div().truncate().child(doc.title.clone()))
                    .when_some(doc.summary.clone(), |d, s| d.child(div().text_xs().text_color(theme.secondary).truncate().child(s))),
            )
            .child(div().w(px(130.)).flex_none().truncate().text_color(theme.secondary).child(doc.area.clone().unwrap_or_default()))
            .child(div().w(px(110.)).flex_none().truncate().child(status_label(doc.status.as_deref())))
            .when(plans, |d| {
                d.child(
                    div()
                        .w(px(70.))
                        .flex_none()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_1p5()
                        .text_xs()
                        .text_color(theme.secondary)
                        .when(doc.tasks > 0, |d| {
                            d.child(crate::charts::progress_ring(doc.tasks_done, doc.tasks, 14., &theme)).child(format!("{}/{}", doc.tasks_done, doc.tasks))
                        }),
                )
            })
            .child(div().w(px(96.)).flex_none().text_color(theme.secondary).child(doc.date.map(|d| d.format("%-d %b %Y").to_string()).unwrap_or_default()))
    }
}

/// The documents about or mentioning any of these issues or PRs, as
/// Gannin's "Plans and requirements": only those that follow the standard,
/// with whether one is about them (`isSubject`); those about them first.
/// A bare `#12` (no repo) isn't matched: which repo it means isn't known here.
pub fn linked(docs: &[Doc], items: &[(String, i64)]) -> Vec<(Doc, bool)> {
    let mut found: Vec<(Doc, bool)> = docs
        .iter()
        .filter(|d| d.standard)
        .filter_map(|d| {
            let about: Vec<bool> = d
                .references
                .iter()
                .filter(|(repo, number, _)| repo.as_deref().is_some_and(|repo| items.iter().any(|(r, n)| r.eq_ignore_ascii_case(repo) && n == number)))
                .map(|r| r.2)
                .collect();
            (!about.is_empty()).then(|| (d.clone(), about.contains(&true)))
        })
        .collect();
    found.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.path.cmp(&b.0.path)));
    found
}

/// The linked documents' rows, for a session or a review: title, path (and
/// whether it only mentions the work), and its ticked tasks as a ring with
/// "done/total". A click asks the workspace to open it in a drawer.
pub fn plan_rows<T: EventEmitter<OpenDoc> + 'static>(id: &'static str, plans: &[(Doc, bool)], theme: &Theme, cx: &mut Context<T>) -> Vec<gpui::AnyElement> {
    plans
        .iter()
        .enumerate()
        .map(|(i, (doc, about))| {
            let opened = doc.clone();
            div()
                .id((id, i))
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .py_1()
                .cursor_pointer()
                .hover(|s| s.opacity(0.8))
                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(OpenDoc(opened.clone()))))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(div().text_sm().truncate().child(doc.title.clone()))
                        .child(div().text_xs().text_color(theme.secondary).truncate().child(if *about { doc.path.clone() } else { format!("{} · mentions it", doc.path) })),
                )
                .when(doc.tasks > 0, |d| {
                    d.child(
                        div()
                            .flex_none()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_1p5()
                            .text_xs()
                            .text_color(theme.secondary)
                            .child(crate::charts::progress_ring(doc.tasks_done, doc.tasks, 14., theme))
                            .child(format!("{}/{}", doc.tasks_done, doc.tasks)),
                    )
                })
                .into_any_element()
        })
        .collect()
}

/// The status in a word or two, as Gannin's `shortStatus`.
pub fn status_label(status: Option<&str>) -> String {
    let Some(status) = status else { return String::new() };
    let clause = status.split(|c| ".,;:(".contains(c)).next().unwrap_or(status).trim();
    let mut label: String = clause.chars().take(16).collect();
    if let Some(first) = label.get(..1) {
        label = format!("{}{}", first.to_uppercase(), &label[1..]);
    }
    label
}

impl Render for HarnessPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let plans = self.kind == HarnessKind::Plans;
        let header = div()
            .flex_none()
            .h(px(28.))
            .px_4()
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .border_b_1()
            .border_color(theme.border)
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .text_color(theme.secondary)
            .child(div().flex_1().child("Title"))
            .child(div().w(px(130.)).flex_none().child("Area"))
            .child(div().w(px(110.)).flex_none().child("Status"))
            .when(plans, |d| d.child(div().w(px(70.)).flex_none().child("Tasks")))
            .child(div().w(px(96.)).flex_none().child("Date"));
        let body = if self.loading {
            div().p_4().text_color(theme.secondary).child("Loading").into_any_element()
        } else if self.rows.is_empty() {
            let text = if self.docs.is_empty() { format!("No {} in the harness", self.kind.title().to_lowercase()) } else { "Nothing matches".into() };
            div().p_4().text_color(theme.secondary).child(text).into_any_element()
        } else {
            uniform_list(
                "harness-rows",
                self.rows.len(),
                cx.processor(|page, range: Range<usize>, window, cx| {
                    let theme = Theme::for_window(window);
                    range.map(|i| page.row(i, &theme, cx)).collect::<Vec<_>>()
                }),
            )
            .flex_1()
            .into_any_element()
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_4()
                    .py_3()
                    .child(div().w(px(260.)).px_2().py_0p5().rounded_full().bg(theme.tile).border_1().border_color(theme.border).child(self.search.clone()))
                    .child(div().text_xs().text_color(theme.secondary).child(SharedString::from(format!("{} of {}", self.rows.len(), self.docs.len())))),
            )
            .child(header)
            .child(div().flex_1().min_h_0().flex().flex_col().child(body))
    }
}
