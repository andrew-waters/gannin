//! The team's harness, as Gannin's sidebar lists it: plans, requirements,
//! decisions, findings, skills, prompts, learnings, research, refines and
//! specialists, each a page of its documents, newest first. A document opens
//! in a drawer with its facts and its text.
//!
//! Read from the harness index Gannin keeps (`Application Support/Harness/
//! <org>@<owner>~<name>.json`, every harness the org has), which holds each
//! document whole: its title, status, summary, front matter and text. Read
//! only: writing or editing documents isn't here.

use crate::charts::Theme;
use chrono::{DateTime, Utc};
use gpui::{div, prelude::*, px, uniform_list, ClickEvent, Context, Entity, EventEmitter, FontWeight, SharedString, Window};
use serde_json::Value;
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

    fn from_title(title: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.title() == title)
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

fn support() -> std::path::PathBuf {
    std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default().join("Library/Application Support")
}

/// Every document in the org's harnesses. Large: call off the main thread.
pub fn load(org: &str) -> Vec<Doc> {
    let prefix = format!("{org}@");
    let mut docs = Vec::new();
    for entry in std::fs::read_dir(support().join("Harness")).into_iter().flatten().flatten() {
        if !entry.file_name().to_string_lossy().starts_with(&prefix) {
            continue;
        }
        let Some(index) = std::fs::read(entry.path()).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { continue };
        let harness = index["repo"].as_str().unwrap_or("").to_string();
        let branch = index["branch"].as_str().unwrap_or("main").to_string();
        for doc in index["documents"].as_array().into_iter().flatten() {
            let Some(kind) = doc["kind"].as_str().and_then(HarnessKind::from_title) else { continue };
            let text = |v: &Value| v.as_str().map(str::to_string).filter(|s| !s.is_empty());
            let area = doc["domains"].as_array().and_then(|d| d.first()).and_then(|d| d.as_str()).map(str::to_string).or_else(|| text(&doc["module"]));
            let references = doc["references"]
                .as_array()
                .map(|r| r.iter().filter_map(|r| Some((r["repo"].as_str().map(str::to_string), r["number"].as_i64()?, r["isSubject"] == true))).collect())
                .unwrap_or_default();
            let mut front_matter: Vec<(String, String)> = doc["frontMatter"]
                .as_object()
                .map(|m| {
                    m.iter()
                        .filter(|(k, _)| !matches!(k.as_str(), "summary" | "status" | "type"))
                        .map(|(k, v)| (k.clone(), v.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default()))
                        .filter(|(_, v)| !v.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            front_matter.sort();
            docs.push(Doc {
                path: doc["path"].as_str().unwrap_or("").to_string(),
                harness: harness.clone(),
                branch: branch.clone(),
                kind,
                title: doc["title"].as_str().unwrap_or("Untitled").to_string(),
                text: doc["text"].as_str().unwrap_or("").to_string(),
                status: text(&doc["status"]),
                summary: text(&doc["summary"]),
                date: doc["date"].as_str().and_then(|d| d.parse().ok()),
                area,
                tasks: doc["tasks"].as_i64().unwrap_or(0),
                tasks_done: doc["tasksDone"].as_i64().unwrap_or(0),
                references,
                front_matter,
            });
        }
    }
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
        let mut page = Self { org, kind, docs: Arc::new(Vec::new()), rows: Vec::new(), search, loading: true, generation: 0, _subscription: subscription };
        page.load(cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.load(cx);
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
        let words: Vec<String> = self.search.read(cx).text(cx).split_whitespace().map(str::to_lowercase).collect();
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
                d.child(div().w(px(70.)).flex_none().text_color(theme.secondary).child(if doc.tasks > 0 { format!("{} of {}", doc.tasks_done, doc.tasks) } else { String::new() }))
            })
            .child(div().w(px(96.)).flex_none().text_color(theme.secondary).child(doc.date.map(|d| d.format("%-d %b %Y").to_string()).unwrap_or_default()))
    }
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
