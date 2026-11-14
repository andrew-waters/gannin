//! A consolidated, single-window shell: the title bar with the org
//! switcher, the navigation sidebar, pages as tabs, an inspector on the
//! right (in place of drawers and the Pull Request, Issue and Explain
//! windows) and a dock for Claude Code sessions (in place of its window).
//! Structure only: CI is the one real page.

use crate::charts::{histogram_cell, spark_bars, Theme};
use crate::data;
use crate::format::{compact_duration, duration_or_dash, percent, relative_date};
use crate::detail::{self, IssueText, Workflow};
use crate::projects::{self, Project};
use crate::issues::{pill, IssueItem, IssuesPage, OpenIssue};
use crate::avatars::avatar;
use crate::markdown::markdown;
use chrono::{DateTime, Local, Utc};
use std::sync::Arc;
use crate::metrics::RepoStats;
use crate::page::{ActionsPage, OpenRepo};
use crate::state::SavedState;
use gpui::{
    actions, anchored, black, deferred, div, ease_out_quint, prelude::*, px, relative, Animation, AnimationExt, AnyElement, ClickEvent, Context, App, Entity, FocusHandle, FontWeight, KeyBinding,
    KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, SharedString, Subscription, Window,
    WindowAppearance,
};
use std::collections::HashSet;

actions!(workspace, [ToggleSidebar, ToggleInspector, ToggleDock, CloseTab, OpenSwitcher]);

pub fn key_bindings() -> Vec<KeyBinding> {
    vec![
        KeyBinding::new("ctrl-cmd-s", ToggleSidebar, None),
        KeyBinding::new("cmd-alt-i", ToggleInspector, None),
        KeyBinding::new("cmd-j", ToggleDock, None),
        KeyBinding::new("cmd-w", CloseTab, None),
        KeyBinding::new("cmd-alt-o", OpenSwitcher, None),
    ]
}

const TITLE_BAR: f32 = 38.0;
/// Room for the traffic lights at the left of the title bar.
const TRAFFIC_LIGHTS: f32 = 78.0;

// MARK: - Navigation

/// A sidebar row, as `WorkloadTab` and `SidebarItem` name them.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum Nav {
    Dashboard,
    Inbox,
    PullRequests,
    Issues,
    Epics,
    Repositories,
    Projects,
    Views,
    Scorecards,
    PrFlow,
    IssueFlow,
    Releases,
    Investments,
    RdTime,
    Ci,
    Everyone,
    Activity,
    TimeOff,
    Standup,
    Recap,
    Prioritisation,
    Planning,
    Refine,
    Hygiene,
    Onboarding,
    HarnessWorkflows,
    AgentMetrics,
    WaitingOnYou,
    Routines,
    Queue,
    Settings,
}

impl Nav {
    pub fn title(self) -> &'static str {
        match self {
            Nav::Dashboard => "Dashboard",
            Nav::Inbox => "Inbox",
            Nav::PullRequests => "Pull Requests",
            Nav::Issues => "Issues",
            Nav::Epics => "Epics",
            Nav::Repositories => "Repositories",
            Nav::Projects => "Projects",
            Nav::Views => "Views",
            Nav::Scorecards => "Scorecards",
            Nav::PrFlow => "PR flow",
            Nav::IssueFlow => "Issue flow",
            Nav::Releases => "Releases",
            Nav::Investments => "Investments",
            Nav::RdTime => "R&D Time",
            Nav::Ci => "CI",
            Nav::Everyone => "Everyone",
            Nav::Activity => "Activity",
            Nav::TimeOff => "Time Off",
            Nav::Standup => "Standup",
            Nav::Recap => "Recap",
            Nav::Prioritisation => "Prioritisation",
            Nav::Planning => "Planning",
            Nav::Refine => "Design and Refine",
            Nav::Hygiene => "Board Hygiene",
            Nav::Onboarding => "Onboarding",
            Nav::HarnessWorkflows => "Workflows",
            Nav::AgentMetrics => "Metrics",
            Nav::WaitingOnYou => "Waiting on You",
            Nav::Routines => "Routines",
            Nav::Queue => "Queue",
            Nav::Settings => "Settings",
        }
    }
}

enum Row {
    Item(Nav),
    /// A row with rows under it, behind a disclosure triangle.
    Group(Nav, Vec<Nav>),
}

struct Section {
    id: &'static str,
    /// Untitled sections can't be collapsed.
    title: Option<&'static str>,
    rows: Vec<Row>,
}

/// The sidebar in `OrgSidebar`'s order.
fn sections() -> Vec<Section> {
    use Nav::*;
    use Row::{Group, Item};
    vec![
        Section { id: "top", title: None, rows: vec![Item(Dashboard), Item(Inbox)] },
        Section {
            id: "work",
            title: Some("Work"),
            rows: vec![
                Item(PullRequests),
                Item(Issues),
                Item(Epics),
                Item(Repositories),
                Group(Projects, vec![]),
                Group(Views, vec![]),
            ],
        },
        Section {
            id: "delivery",
            title: Some("Delivery"),
            rows: vec![
                Item(Scorecards),
                Item(PrFlow),
                Item(IssueFlow),
                Item(Releases),
                Item(Investments),
                Item(RdTime),
                Item(Ci),
            ],
        },
        Section { id: "team", title: Some("Team"), rows: vec![Group(Everyone, vec![]), Item(Activity), Item(TimeOff)] },
        Section {
            id: "rituals",
            title: Some("Rituals"),
            rows: vec![Item(Standup), Item(Recap), Item(Prioritisation), Item(Planning), Item(Refine), Item(Hygiene)],
        },
        Section { id: "harness", title: Some("Harness"), rows: vec![Item(Onboarding), Item(HarnessWorkflows)] },
        Section {
            id: "agents",
            title: Some("Agents"),
            rows: vec![Item(AgentMetrics), Item(WaitingOnYou), Item(Routines), Item(Queue)],
        },
    ]
}

#[derive(Clone, Copy)]
enum Edge {
    Sidebar,
    Inspector,
    Dock,
}

/// What the inspector shows; issues open in drawers instead.
enum Inspected {
    Repo(RepoStats),
}

/// An issue in a drawer, with its parent and sub-issues looked up when it
/// opened.
struct Drawer {
    /// Unique per drawer opened, so each one slides in once.
    seq: usize,
    issue: IssueItem,
    parent: Option<IssueItem>,
    sub_issues: Vec<IssueItem>,
    /// Its description and comments: nil while they load, then whatever
    /// Gannin's caches had.
    text: Option<Option<Arc<IssueText>>>,
}

/// Wide enough for the issue and its board fields side by side, as
/// `IssueWindow` lays them out; narrower windows cap it.
const DRAWER_WIDTH: f32 = 900.0;
/// How far each drawer beneath the top one shows, as `drawerPeek`.
const DRAWER_PEEK: f32 = 14.0;

/// What a title bar switcher picks.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Pick {
    Org,
    Project,
}

/// A switcher open in the title bar, as Zed's project picker.
struct Switcher {
    pick: Pick,
    query: String,
    highlighted: usize,
}

pub struct Workspace {
    focus: FocusHandle,
    switcher_focus: FocusHandle,
    orgs: Vec<String>,
    org: Option<String>,
    /// The org's projects, each a harness, and the one picked by its id.
    projects: Vec<Project>,
    project: Option<String>,
    /// How the org's issues move through its board, for drawer timing.
    workflow: Workflow,
    collapsed_sections: HashSet<&'static str>,
    expanded_groups: HashSet<Nav>,
    tabs: Vec<Nav>,
    active: usize,
    inspector: Option<Inspected>,
    sidebar_open: bool,
    inspector_open: bool,
    dock_open: bool,
    sidebar_width: f32,
    inspector_width: f32,
    dock_height: f32,
    resizing: Option<Edge>,
    switcher: Option<Switcher>,
    /// Bottom first; the last is on top.
    drawers: Vec<Drawer>,
    drawer_seq: usize,
    actions_page: Entity<ActionsPage>,
    issues: Entity<IssuesPage>,
    /// What was last written, so unchanged state isn't written again.
    last_saved: Option<SavedState>,
    _subscriptions: Vec<Subscription>,
}

impl Workspace {
    fn snapshot(&self, cx: &App) -> SavedState {
        SavedState {
            org: self.org.clone(),
            project: self.project.clone(),
            tabs: self.tabs.clone(),
            active: self.active,
            sidebar_open: self.sidebar_open,
            inspector_open: self.inspector_open,
            dock_open: self.dock_open,
            sidebar_width: self.sidebar_width,
            inspector_width: self.inspector_width,
            dock_height: self.dock_height,
            collapsed_sections: {
                let mut ids: Vec<String> = self.collapsed_sections.iter().map(|id| id.to_string()).collect();
                ids.sort();
                ids
            },
            expanded_groups: {
                let mut groups: Vec<Nav> = self.expanded_groups.iter().copied().collect();
                groups.sort_by_key(|nav| format!("{nav:?}"));
                groups
            },
            ci: self.actions_page.read(cx).saved(),
            issues: self.issues.read(cx).saved(),
        }
    }

    /// Writes the state when it differs from what was last written. Panel
    /// drags are left until they end, rather than written on every move.
    fn persist(&mut self, cx: &App) {
        if self.resizing.is_some() || self.issues.read(cx).is_resizing() {
            return;
        }
        let state = self.snapshot(cx);
        if self.last_saved.as_ref() != Some(&state) {
            state.save();
            self.last_saved = Some(state);
        }
    }

    pub fn new(saved: SavedState, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut workspace = Self::build(saved, window, cx);
        workspace.load_settings(cx);
        workspace
    }

    /// Reads the org's projects and workflow off the main thread, then
    /// keeps the pages to the project picked (or the first, as Gannin
    /// falls back to home).
    fn load_settings(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        cx.spawn(async move |this, cx| {
            let loaded = org.clone();
            let settings = cx.background_executor().spawn(async move { projects::load(&loaded) }).await;
            this.update(cx, |this, cx| {
                if this.org.as_deref() != Some(org.as_str()) {
                    return;
                }
                this.projects = settings.projects;
                this.workflow = settings.workflow;
                if !this.project.as_ref().is_some_and(|id| this.projects.iter().any(|p| &p.id == id)) {
                    this.project = this.projects.first().map(|p| p.id.clone());
                }
                this.apply_focus(cx);
            })
            .ok();
        })
        .detach();
    }

    /// The picked project's repos, for the pages; none for every repo.
    fn focus_repos(&self) -> Option<Vec<String>> {
        let project = self.projects.iter().find(|p| Some(&p.id) == self.project.as_ref())?;
        (!project.repos.is_empty()).then(|| project.repos.clone())
    }

    fn apply_focus(&mut self, cx: &mut Context<Self>) {
        let focus = self.focus_repos();
        self.actions_page.update(cx, |page, cx| page.set_focus(focus.clone(), cx));
        self.issues.update(cx, |page, cx| page.set_focus(focus, cx));
        cx.notify();
    }

    fn choose_project(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.project = Some(id);
        self.switcher = None;
        self.drawers.clear();
        self.inspector = None;
        window.focus(&self.focus);
        self.apply_focus(cx);
    }

    fn build(saved: SavedState, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let orgs = data::orgs();
        // The saved org, while it still has a cache.
        let org = saved.org.clone().filter(|org| orgs.contains(org)).or_else(|| orgs.first().cloned());
        let actions_page = cx.new(|cx| ActionsPage::new(org.clone(), &saved.ci, window, cx));
        let issues = cx.new(|cx| IssuesPage::new(org.clone(), &saved.issues, window, cx));
        // A row picked in a list replaces the stack, as a list row does today.
        let open_issue = |this: &mut Self, _: Entity<IssuesPage>, event: &OpenIssue, cx: &mut Context<Self>| {
            this.drawers.clear();
            this.push_drawer(event.0.clone(), cx);
        };
        let subscriptions = vec![
            cx.subscribe(&actions_page, |this, _, event: &OpenRepo, cx| {
                this.inspector = Some(Inspected::Repo(event.0.clone()));
                this.inspector_open = true;
                cx.notify();
            }),
            cx.subscribe(&issues, open_issue),
            cx.observe_window_appearance(window, |_, _, cx| cx.notify()),
            // Page controls change without the workspace redrawing.
            cx.observe(&actions_page, |this, _, cx| this.persist(cx)),
            // Also redraws the tab, which shows the page's count.
            cx.observe(&issues, |this, _, cx| {
                this.persist(cx);
                cx.notify();
            }),
        ];
        let tabs: Vec<Nav> = saved.tabs.clone();
        let focus = cx.focus_handle();
        window.focus(&focus);
        Self {
            focus,
            switcher_focus: cx.focus_handle(),
            orgs,
            org,
            projects: Vec::new(),
            project: saved.project.clone(),
            workflow: Workflow::default(),
            collapsed_sections: sections().iter().map(|s| s.id).filter(|id| saved.collapsed_sections.iter().any(|c| c == id)).collect(),
            expanded_groups: saved.expanded_groups.iter().copied().collect(),
            active: saved.active.min(tabs.len().saturating_sub(1)),
            tabs,
            inspector: None,
            sidebar_open: saved.sidebar_open,
            inspector_open: saved.inspector_open,
            dock_open: saved.dock_open,
            sidebar_width: saved.sidebar_width,
            inspector_width: saved.inspector_width,
            dock_height: saved.dock_height,
            last_saved: Some(saved),
            resizing: None,
            switcher: None,
            drawers: Vec::new(),
            drawer_seq: 0,
            actions_page,
            issues,
            _subscriptions: subscriptions,
        }
    }

    /// Shows `nav` in the current tab, or a new one with Command held. A
    /// page already open in a tab is switched to instead.
    fn navigate(&mut self, nav: Nav, new_tab: bool, cx: &mut Context<Self>) {
        // Drawers belong to the page under them.
        self.drawers.clear();
        if let Some(index) = self.tabs.iter().position(|tab| *tab == nav) {
            self.active = index;
        } else if new_tab || self.tabs.is_empty() {
            self.tabs.push(nav);
            self.active = self.tabs.len() - 1;
        } else {
            self.tabs[self.active] = nav;
        }
        cx.notify();
    }

    /// Closing the last tab leaves an empty pane, as Zed's does; the window
    /// stays open.
    fn close_tab(&mut self, index: usize, cx: &mut Context<Self>) {
        if index >= self.tabs.len() {
            return;
        }
        self.tabs.remove(index);
        if self.active >= self.tabs.len() || self.active > index {
            self.active = self.active.saturating_sub(1);
        }
        cx.notify();
    }

    fn current(&self) -> Option<Nav> {
        self.tabs.get(self.active).copied()
    }

    fn push_drawer(&mut self, issue: IssueItem, cx: &mut Context<Self>) {
        let store = self.issues.read(cx);
        let parent = issue.parent_id.as_deref().and_then(|id| store.issue(id));
        let sub_issues = store.sub_issues(&issue.id);
        self.drawer_seq += 1;
        let seq = self.drawer_seq;
        let id = issue.id.clone();
        self.drawers.push(Drawer { seq, issue, parent, sub_issues, text: None });
        // The description and comments, read from Gannin's caches off the
        // main thread.
        cx.spawn(async move |this, cx| {
            let text = cx.background_executor().spawn(async move { detail::load_text(&id).map(Arc::new) }).await;
            this.update(cx, |this, cx| {
                if let Some(drawer) = this.drawers.iter_mut().find(|d| d.seq == seq) {
                    drawer.text = Some(text);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn pop_drawer(&mut self, cx: &mut Context<Self>) {
        if self.drawers.pop().is_some() {
            cx.notify();
        }
    }

    /// The drawers over the page: the scrim, then each drawer, those
    /// beneath the top one peeking out to its left.
    fn drawer_stack(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let count = self.drawers.len();
        div()
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .bottom_0()
            .child(
                div()
                    .id("drawer-scrim")
                    .absolute()
                    .top_0()
                    .left_0()
                    .right_0()
                    .bottom_0()
                    .bg(black().opacity(if theme.dark { 0.35 } else { 0.18 }))
                    .occlude()
                    .on_mouse_down(MouseButton::Left, cx.listener(|this, _: &MouseDownEvent, _, cx| this.pop_drawer(cx))),
            )
            .children(self.drawers.iter().enumerate().filter(|(i, _)| count - 1 - i <= 3).map(|(index, drawer)| {
                let depth = count - 1 - index;
                let offset = depth as f32 * DRAWER_PEEK;
                let on_top = depth == 0;
                div()
                    .id(("drawer", drawer.seq))
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .right(px(offset))
                    .w(px(DRAWER_WIDTH))
                    .max_w(relative(0.96))
                    .flex()
                    .flex_col()
                    .bg(theme.bg)
                    .border_l_1()
                    .border_color(theme.border)
                    .shadow_lg()
                    .occlude()
                    // A drawer beneath the top one goes back to it.
                    .when(!on_top, |d| {
                        d.cursor_pointer().on_mouse_down(
                            MouseButton::Left,
                            cx.listener(move |this, _: &MouseDownEvent, _, cx| {
                                this.drawers.truncate(index + 1);
                                cx.stop_propagation();
                                cx.notify();
                            }),
                        )
                    })
                    .child(self.drawer_header(drawer, count, theme, cx))
                    .child(
                        div()
                            .id(("drawer-body", drawer.seq))
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .when(!on_top, |d| d.opacity(0.6))
                            .child(self.issue_page(drawer, theme, cx)),
                    )
                    .with_animation(
                        ("drawer-slide", drawer.seq),
                        Animation::new(std::time::Duration::from_millis(240)).with_easing(ease_out_quint()),
                        move |drawer, delta| drawer.right(px(offset - (DRAWER_WIDTH + 24.) * (1.0 - delta))),
                    )
            }))
    }

    fn drawer_header(&self, drawer: &Drawer, count: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let button = |id: &'static str, label: &'static str| {
            div()
                .id((id, drawer.seq))
                .px_2()
                .py_0p5()
                .rounded_md()
                .cursor_pointer()
                .text_color(theme.secondary)
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
        };
        div()
            .h(px(36.))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .px_3()
            .bg(theme.sidebar)
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex_1()
                    .text_color(theme.secondary)
                    .child(if count > 1 { format!("Issue · {} of {count}", self.drawers.iter().position(|d| d.seq == drawer.seq).unwrap_or(0) + 1) } else { "Issue".into() }),
            )
            .child(button("close-drawer", "×").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.pop_drawer(cx))))
    }

    /// The parent and sub-issues, each opening a drawer on top.
    fn related(&self, drawer: &Drawer, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let row = |issue: &IssueItem, key: &'static str, cx: &mut Context<Self>| {
            let opened = issue.clone();
            div()
                .id((key, issue.number as usize))
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .py_1()
                .px_2()
                .rounded_md()
                .cursor_pointer()
                .hover(|s| s.bg(theme.tile))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.push_drawer(opened.clone(), cx)))
                .when(!issue.is_open(), |d| d.child(pill("Closed", theme.slot(6))))
                .child(div().flex_1().overflow_hidden().whitespace_nowrap().child(issue.title.clone()))
                .child(div().text_color(theme.secondary).child(format!("#{}", issue.number)))
        };
        let heading = |text: String| div().pt_4().pb_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text);
        let mut section = div().flex().flex_col();
        if let Some(parent) = &drawer.parent {
            section = section.child(heading("Parent".into())).child(row(parent, "parent", cx));
        }
        if !drawer.sub_issues.is_empty() {
            let open = drawer.sub_issues.iter().filter(|i| i.is_open()).count();
            let parent = drawer.issue.id.clone();
            section = section
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_end()
                        .child(div().flex_1().child(heading(format!("Sub-issues · {open} of {} open", drawer.sub_issues.len()))))
                        .child(
                            div()
                                .id(("show-in-list", drawer.seq))
                                .pb_1()
                                .text_xs()
                                .text_color(theme.selected)
                                .cursor_pointer()
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    this.issues.update(cx, |page, cx| page.set_scope(Some(parent.clone()), cx));
                                    this.navigate(Nav::Issues, false, cx);
                                }))
                                .child("Show in list"),
                        ),
                )
                .children(drawer.sub_issues.iter().map(|issue| row(issue, "sub-issue", cx)));
        }
        section
    }

    fn choose_org(&mut self, org: String, window: &mut Window, cx: &mut Context<Self>) {
        self.org = Some(org.clone());
        self.inspector = None;
        self.drawers.clear();
        self.switcher = None;
        // The new org's projects arrive with its settings.
        self.projects.clear();
        self.project = None;
        self.actions_page.update(cx, |page, cx| {
            page.set_focus(None, cx);
            page.set_org(Some(org.clone()), cx)
        });
        self.issues.update(cx, |page, cx| {
            page.set_focus(None, cx);
            page.set_org(Some(org), cx)
        });
        self.load_settings(cx);
        window.focus(&self.focus);
        cx.notify();
    }

    fn open_switcher(&mut self, pick: Pick, window: &mut Window, cx: &mut Context<Self>) {
        let current = match pick {
            Pick::Org => self.org.clone(),
            Pick::Project => self.project.clone(),
        };
        let highlighted = self.switcher_items(pick, "").iter().position(|(_, key)| Some(key) == current.as_ref()).unwrap_or(0);
        self.switcher = Some(Switcher { pick, query: String::new(), highlighted });
        window.focus(&self.switcher_focus);
        cx.notify();
    }

    fn close_switcher(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.switcher = None;
        window.focus(&self.focus);
        cx.notify();
    }

    /// What a switcher lists, as (label, key), narrowed by `query`.
    fn switcher_items(&self, pick: Pick, query: &str) -> Vec<(String, String)> {
        let query = query.to_lowercase();
        let all: Vec<(String, String)> = match pick {
            Pick::Org => self.orgs.iter().map(|o| (o.clone(), o.clone())).collect(),
            Pick::Project => self.projects.iter().map(|p| (p.name.clone(), p.id.clone())).collect(),
        };
        all.into_iter().filter(|(label, _)| label.to_lowercase().contains(&query)).collect()
    }

    fn choose(&mut self, pick: Pick, key: String, window: &mut Window, cx: &mut Context<Self>) {
        match pick {
            Pick::Org => self.choose_org(key, window, cx),
            Pick::Project => self.choose_project(key, window, cx),
        }
    }

    /// The switcher's search field, by hand: GPUI has no text input of its
    /// own (Zed's is its editor), so this takes printable keys and Backspace.
    fn switcher_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(switcher) = self.switcher.as_ref() else { return };
        let pick = switcher.pick;
        let matches = self.switcher_items(pick, &switcher.query);
        let keystroke = &event.keystroke;
        match keystroke.key.as_str() {
            "escape" => {
                cx.stop_propagation();
                return self.close_switcher(window, cx);
            }
            "enter" => {
                if let Some((_, key)) = matches.get(switcher.highlighted).cloned() {
                    self.choose(pick, key, window, cx);
                }
                return;
            }
            _ => {}
        }
        let Some(switcher) = self.switcher.as_mut() else { return };
        match keystroke.key.as_str() {
            "down" => switcher.highlighted = (switcher.highlighted + 1).min(matches.len().saturating_sub(1)),
            "up" => switcher.highlighted = switcher.highlighted.saturating_sub(1),
            "backspace" => {
                switcher.query.pop();
                switcher.highlighted = 0;
            }
            _ => {
                let modified = keystroke.modifiers.platform || keystroke.modifiers.control;
                match &keystroke.key_char {
                    Some(text) if !modified && !text.chars().any(char::is_control) => {
                        switcher.query.push_str(text);
                        switcher.highlighted = 0;
                    }
                    _ => return,
                }
            }
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn drag(&mut self, event: &MouseMoveEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(edge) = self.resizing else { return };
        if event.pressed_button != Some(MouseButton::Left) {
            self.resizing = None;
            cx.notify();
            return;
        }
        let size = window.viewport_size();
        let (width, height) = (f32::from(size.width), f32::from(size.height));
        let (x, y) = (f32::from(event.position.x), f32::from(event.position.y));
        match edge {
            Edge::Sidebar => self.sidebar_width = x.clamp(180.0, 420.0),
            Edge::Inspector => self.inspector_width = (width - x).clamp(260.0, 640.0),
            Edge::Dock => self.dock_height = (height - y).max(120.0).min((height - 200.0).max(120.0)),
        }
        cx.notify();
    }

    fn resize_handle(&self, id: &'static str, edge: Edge, cx: &mut Context<Self>) -> impl IntoElement {
        let handle = div()
            .id(id)
            .absolute()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _: &MouseDownEvent, _, cx| {
                    this.resizing = Some(edge);
                    cx.stop_propagation();
                    cx.notify();
                }),
            );
        match edge {
            Edge::Sidebar => handle.top_0().bottom_0().right(px(-3.)).w(px(6.)).cursor_col_resize(),
            Edge::Inspector => handle.top_0().bottom_0().left(px(-3.)).w(px(6.)).cursor_col_resize(),
            Edge::Dock => handle.left_0().right_0().top(px(-3.)).h(px(6.)).cursor_row_resize(),
        }
    }

    // MARK: Title bar

    fn title_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let org = self.org.clone().unwrap_or_else(|| "No org".into());
        div()
            .id("title-bar")
            .h(px(TITLE_BAR))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .pl(px(TRAFFIC_LIGHTS))
            .pr_3()
            .bg(theme.sidebar)
            .border_b_1()
            .border_color(theme.border)
            // A double click zooms, as the system title bar does.
            .on_click(|event: &ClickEvent, window, _| {
                if event.click_count() == 2 {
                    window.titlebar_double_click();
                }
            })
            .child(self.switcher_button(Pick::Org, org, theme, cx))
            .when(!self.projects.is_empty(), |d| {
                let name = self
                    .projects
                    .iter()
                    .find(|p| Some(&p.id) == self.project.as_ref())
                    .map_or_else(|| "No project".to_string(), |p| p.name.clone());
                d.child(div().text_color(theme.tertiary).child("/")).child(self.switcher_button(Pick::Project, name, theme, cx))
            })
    }

    /// A title bar button opening its switcher, drawn beneath it, as Zed's
    /// branch picker: the org as plain text, the project as a tinted chip.
    fn switcher_button(&self, pick: Pick, label: String, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let open = self.switcher.as_ref().is_some_and(|s| s.pick == pick);
        let chip = pick == Pick::Project;
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .id(match pick {
                        Pick::Org => "org-button",
                        Pick::Project => "project-button",
                    })
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .cursor_pointer()
                    .map(|d| {
                        if chip {
                            d.text_color(theme.selected).bg(theme.selected.opacity(if open { 0.28 } else { 0.16 }))
                        } else {
                            d.text_color(theme.fg).when(open, |d| d.bg(theme.row_selected))
                        }
                    })
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        cx.stop_propagation();
                        if open {
                            this.close_switcher(window, cx);
                        } else {
                            this.open_switcher(pick, window, cx);
                        }
                    }))
                    .child(label),
            )
            .when_some(self.switcher.as_ref().filter(|_| open), |d, switcher| {
                d.child(deferred(anchored().snap_to_window_with_margin(px(8.)).child(self.switcher_panel(switcher, theme, cx))).with_priority(2))
            })
    }

    // MARK: Status bar

    /// Along the foot of the window, as Zed's: panel toggles at each end
    /// and the page's own status between them.
    fn status_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let status = match self.current() {
            Some(Nav::Ci) => self.actions_page.read(cx).status(),
            Some(Nav::Issues) => self.issues.read(cx).status(),
            Some(nav) => format!("{}: not ported", nav.title()),
            None => String::new(),
        };
        let toggle = |id: &'static str, label: &'static str, on: bool, cx: &mut Context<Self>, action: fn(&mut Self)| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.row_selected))
                .hover(|s| s.bg(theme.row_selected))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    action(this);
                    cx.stop_propagation();
                    cx.notify();
                }))
                .child(label)
        };
        div()
            .h(px(26.))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .px_2()
            .text_xs()
            .bg(theme.sidebar)
            .border_t_1()
            .border_color(theme.border)
            .child(toggle("toggle-sidebar", "Sidebar", self.sidebar_open, cx, |this| this.sidebar_open = !this.sidebar_open))
            .child(toggle("toggle-dock", "Claude Code", self.dock_open, cx, |this| this.dock_open = !this.dock_open))
            .child(div().flex_1().px_2().overflow_hidden().whitespace_nowrap().text_color(theme.secondary).child(status))
            .child(div().px_2().text_color(theme.tertiary).child("Read only, from Gannin's caches"))
            .child(toggle("toggle-inspector", "Inspector", self.inspector_open, cx, |this| {
                this.inspector_open = !this.inspector_open
            }))
    }

    // MARK: Sidebar

    fn sidebar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let current = self.current();
        let mut rows: Vec<AnyElement> = Vec::new();
        for section in sections() {
            let collapsed = self.collapsed_sections.contains(section.id);
            if let Some(title) = section.title {
                let id = section.id;
                rows.push(
                    div()
                        .id(id)
                        .flex()
                        .flex_row()
                        .items_center()
                        .mt_3()
                        .mb_0p5()
                        .px_2()
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(theme.tertiary)
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            if !this.collapsed_sections.remove(id) {
                                this.collapsed_sections.insert(id);
                            }
                            cx.notify();
                        }))
                        .child(div().flex_1().child(title))
                        .child(if collapsed { "▸" } else { "▾" })
                        .into_any_element(),
                );
            }
            if collapsed {
                continue;
            }
            for row in section.rows {
                match row {
                    Row::Item(nav) => rows.push(self.nav_row(nav, 0, None, current, theme, cx).into_any_element()),
                    Row::Group(nav, children) => {
                        let expanded = self.expanded_groups.contains(&nav);
                        rows.push(self.nav_row(nav, 0, Some(expanded), current, theme, cx).into_any_element());
                        if expanded {
                            if children.is_empty() {
                                rows.push(
                                    div()
                                        .pl(px(34.))
                                        .py_0p5()
                                        .text_xs()
                                        .text_color(theme.tertiary)
                                        .child("Not loaded in the pilot")
                                        .into_any_element(),
                                );
                            }
                            for child in children {
                                rows.push(self.nav_row(child, 1, None, current, theme, cx).into_any_element());
                            }
                        }
                    }
                }
            }
        }

        div()
            .relative()
            .w(px(self.sidebar_width))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .bg(theme.sidebar)
            .border_r_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .p_2()
                    .child(placeholder_button("New Ask", theme))
                    .child(placeholder_button("Quick Change", theme)),
            )
            .child(div().id("nav").flex_1().min_h_0().overflow_y_scroll().px_2().pb_3().children(rows))
            .child(
                div()
                    .flex_none()
                    .p_2()
                    .border_t_1()
                    .border_color(theme.border)
                    .child(self.nav_row(Nav::Settings, 0, None, current, theme, cx)),
            )
            .child(self.resize_handle("resize-sidebar", Edge::Sidebar, cx))
    }

    /// A row: icon slot, title, and a disclosure triangle for a group.
    fn nav_row(
        &self,
        nav: Nav,
        depth: usize,
        expanded: Option<bool>,
        current: Option<Nav>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selected = current == Some(nav);
        div()
            .id(SharedString::from(format!("nav-{nav:?}")))
            .h(px(26.))
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .pl(px(8. + depth as f32 * 18.))
            .pr_2()
            .rounded_md()
            .cursor_pointer()
            .when(selected, |d| d.bg(theme.row_selected))
            .when(!selected, |d| d.hover(|s| s.bg(theme.row_selected.opacity(0.5))))
            .on_click(cx.listener(move |this, event: &ClickEvent, _, cx| {
                this.navigate(nav, event.modifiers().platform, cx)
            }))
            // SF Symbols aren't reachable from GPUI; icons need an SVG set.
            .child(div().w(px(16.)).flex().justify_center().child(div().w(px(6.)).h(px(6.)).rounded_full().bg(theme.tertiary)))
            .child(div().flex_1().overflow_hidden().whitespace_nowrap().child(nav.title()))
            .when_some(expanded, |d, expanded| {
                d.child(
                    div()
                        .id(SharedString::from(format!("disclose-{nav:?}")))
                        .px_1()
                        .text_xs()
                        .text_color(theme.tertiary)
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            if !this.expanded_groups.remove(&nav) {
                                this.expanded_groups.insert(nav);
                            }
                            cx.stop_propagation();
                            cx.notify();
                        }))
                        .child(if expanded { "▾" } else { "▸" }),
                )
            })
    }

    // MARK: Tabs and pages

    fn tab_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("tabs")
            .h(px(32.))
            .flex_none()
            .flex()
            .flex_row()
            .overflow_x_scroll()
            .bg(theme.sidebar)
            .border_b_1()
            .border_color(theme.border)
            .children(self.tabs.iter().enumerate().map(|(index, nav)| {
                let active = index == self.active;
                div()
                    .id(("tab", index))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .pl_3()
                    .pr_2()
                    .h_full()
                    .border_r_1()
                    .border_color(theme.border)
                    .cursor_pointer()
                    .text_color(if active { theme.fg } else { theme.secondary })
                    .when(active, |d| d.bg(theme.bg))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        if this.active != index {
                            this.drawers.clear();
                        }
                        this.active = index;
                        cx.notify();
                    }))
                    .child(nav.title())
                    .when_some(if *nav == Nav::Issues { self.issues.read(cx).tab_count() } else { None }, |d, count| {
                        d.child(div().text_xs().text_color(theme.secondary).child(count))
                    })
                    .child(
                        div()
                            .id(("close-tab", index))
                            .px_1()
                            .rounded_sm()
                            .text_color(theme.tertiary)
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                cx.stop_propagation();
                                this.close_tab(index, cx);
                            }))
                            .child("×"),
                    )
            }))
    }

    fn page(&self, theme: &Theme) -> AnyElement {
        match self.current() {
            Some(Nav::Ci) => self.actions_page.clone().into_any_element(),
            Some(Nav::Issues) => self.issues.clone().into_any_element(),
            Some(nav) => div()
                .size_full()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap_2()
                .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(nav.title()))
                .child(
                    div()
                        .text_color(theme.secondary)
                        .child("Not ported in the pilot. CI and Issues are real pages."),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(theme.tertiary)
                        .child("Command-click a sidebar row to open it in a new tab."),
                )
                .into_any_element(),
            None => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_color(theme.tertiary)
                .child("No page open. Pick one in the sidebar.")
                .into_any_element(),
        }
    }

    // MARK: Inspector and dock

    fn inspector(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let body: AnyElement = match &self.inspector {
            Some(Inspected::Repo(repo)) => {
                let stat = |label: &'static str, value: String| {
                    div()
                        .flex()
                        .flex_row()
                        .justify_between()
                        .py_1()
                        .border_b_1()
                        .border_color(theme.grid)
                        .child(div().text_color(theme.secondary).child(label))
                        .child(value)
                };
                div()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(repo.short_name.clone()))
                            .child(div().text_xs().text_color(theme.secondary).child(repo.repo.clone())),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .child(stat("Run time", compact_duration(repo.current.run_time)))
                            .child(stat("Share of the org", percent(Some(repo.share))))
                            .child(stat("Runs", repo.current.runs.to_string()))
                            .child(stat("Failure rate", percent(repo.current.counts.failure_rate())))
                            .child(stat("Median", duration_or_dash(repo.current.duration.median)))
                            .child(stat("p90", duration_or_dash(repo.current.duration.p90))),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(div().text_xs().text_color(theme.secondary).child("Run time by week"))
                            .child(spark_bars(&repo.weeks.iter().map(|w| w.run_time).collect::<Vec<_>>(), theme)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(div().text_xs().text_color(theme.secondary).child("Durations"))
                            .child(histogram_cell(&repo.histogram, theme)),
                    )
                    .into_any_element()
            }
            None => div()
                .text_color(theme.secondary)
                .child("Click a repository on CI to open it here.")
                .into_any_element(),
        };
        div()
            .relative()
            .w(px(self.inspector_width))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .border_l_1()
            .border_color(theme.border)
            .child(
                div()
                    .h(px(32.))
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .px_3()
                    .bg(theme.sidebar)
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().flex_1().text_color(theme.secondary).child("Inspector"))
                    .child(
                        div()
                            .id("close-inspector")
                            .px_1()
                            .rounded_sm()
                            .cursor_pointer()
                            .text_color(theme.tertiary)
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.inspector_open = false;
                                cx.notify();
                            }))
                            .child("×"),
                    ),
            )
            .child(div().id("inspector-body").flex_1().min_h_0().overflow_y_scroll().p_4().child(body))
            .child(self.resize_handle("resize-inspector", Edge::Inspector, cx))
    }

    /// An issue as `IssueWindow` shows it: the title and headline facts
    /// across the top; the timeline, board history, linked pull requests,
    /// description, comments, parent and sub-issues on the left; and the
    /// assignees and board fields on the right.
    fn issue_page(&self, drawer: &Drawer, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let issue = &drawer.issue;
        let seq = drawer.seq;
        let now = Utc::now();
        let timing = detail::timing(issue, &self.workflow, now);
        let text: Option<&IssueText> = drawer.text.as_ref().and_then(|t| t.as_deref());
        let date = |t: DateTime<Utc>| t.with_timezone(&Local).format("%-d %b %Y").to_string();

        // Headline facts, as `IssueWindow.header`.
        let fact = |label: &str, value: String| {
            div()
                .min_w(px(140.))
                .flex()
                .flex_col()
                .gap_0p5()
                .child(div().text_xs().text_color(theme.secondary).child(label.to_string()))
                .child(value)
        };
        let percent = |v: f64| format!("{:.0}%", v * 100.0);
        let mut facts = vec![fact("Created", date(issue.created_at))];
        if let Some(author) = &issue.author_login {
            facts.push(fact("Opened by", author.clone()));
        }
        if let Some(closed) = issue.closed_at {
            facts.push(fact(if issue.not_planned { "Closed, not planned" } else { "Closed" }, date(closed)));
        }
        if !issue.assignee_logins.is_empty() {
            facts.push(fact("Assignees", issue.assignee_logins.join(", ")));
        }
        if let Some(kind) = &issue.issue_type {
            facts.push(fact("Type", kind.clone()));
        }
        facts.push(fact(
            "In progress",
            timing
                .cycle
                .map(|c| format!("{}{}", compact_duration(c), if timing.in_progress { " so far" } else { "" }))
                .unwrap_or_else(|| "Not started".into()),
        ));
        if let Some(lead) = timing.lead {
            facts.push(fact("Lead time", compact_duration(lead)));
        }
        if let Some(flow) = timing.flow {
            facts.push(fact("Flow efficiency", percent(flow)));
        }
        if let Some(creep) = timing.scope_creep {
            facts.push(fact("Scope creep", format!("{} of {}", percent(creep), issue.sub_issues_added_at.len())));
        }
        match issue.reopened_at.len() {
            0 => {}
            1 => facts.push(fact("Reopened", "Once".into())),
            n => facts.push(fact("Reopened", format!("{n} times"))),
        }

        let url = issue.url.clone();
        let header = div()
            .flex()
            .flex_col()
            .gap_3()
            .px_5()
            .py_4()
            .border_b_1()
            .border_color(theme.border)
            .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(issue.title.clone()))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .id(("issue-link", seq))
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                            .child(format!("{}#{}", issue.repo, issue.number)),
                    )
                    .child(match (issue.is_open(), issue.not_planned) {
                        (true, _) => pill("Open", theme.good()),
                        (false, true) => pill("Not planned", theme.secondary),
                        (false, false) => pill("Completed", theme.slot(6)),
                    }),
            )
            .child(div().flex().flex_row().flex_wrap().gap_x_6().gap_y_3().children(facts))
            .when(!issue.labels.is_empty(), |d| {
                d.child(div().flex().flex_row().flex_wrap().gap_1p5().children(issue.labels.iter().zip(&issue.label_colors).map(
                    |(label, color)| {
                        let tint = color.as_deref().and_then(|hex| u32::from_str_radix(hex, 16).ok()).map(|hex| -> gpui::Hsla { gpui::rgb(hex).into() });
                        div()
                            .px_2()
                            .py_0p5()
                            .rounded_full()
                            .text_xs()
                            .bg(tint.map_or(theme.tile, |t| t.opacity(0.28)))
                            .when_some(tint, |d, t| d.border_1().border_color(t.opacity(0.6)))
                            .child(label.clone())
                    },
                )))
            });

        // The left column.
        let heading = |title: &str, count: Option<usize>| {
            div()
                .flex()
                .flex_row()
                .gap_1p5()
                .pb_1()
                .font_weight(FontWeight::SEMIBOLD)
                .child(title.to_string())
                .when_some(count, |d, n| d.child(div().text_color(theme.secondary).font_weight(FontWeight::NORMAL).child(n.to_string())))
        };
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);

        let days = detail::timeline(issue, text);
        let moments: usize = days.iter().map(|(_, m)| m.len()).sum();
        let mut moment_id = 0usize;
        let timeline = div().flex().flex_col().gap_2().child(heading("Timeline", Some(moments))).children(days.into_iter().map(|(day, moments)| {
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(day.format("%a %-d %b %Y").to_string()))
                .children(moments.into_iter().map(|moment| {
                    moment_id += 1;
                    let link = moment.url.clone();
                    div()
                        .id(SharedString::from(format!("moment-{seq}-{moment_id}")))
                        .flex()
                        .flex_row()
                        .gap_2()
                        .when_some(link, |d, url| {
                            d.cursor_pointer().hover(|s| s.bg(theme.tile)).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        })
                        .child(div().w(px(40.)).flex_none().text_xs().text_color(theme.secondary).child(moment.at.with_timezone(&Local).format("%H:%M").to_string()))
                        .child(div().flex_none().font_weight(FontWeight::MEDIUM).child(moment.who))
                        .child(div().flex_1().min_w_0().truncate().text_color(theme.secondary).child(moment.what))
                }))
        }));

        let changes: Vec<&crate::issues::StatusChange> = issue.status_changes.iter().filter(|c| self.workflow.counts(c)).collect();
        let board_status = (!changes.is_empty()).then(|| {
            div().flex().flex_col().gap_1().child(heading("Board status", Some(changes.len()))).children(changes.iter().map(|change| {
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .w(px(8.))
                            .h(px(8.))
                            .rounded_full()
                            .bg(if self.workflow.is_in_progress(&change.status) { theme.blue() } else { theme.secondary.opacity(0.4) }),
                    )
                    .child(change.status.clone())
                    .when_some(change.project_title.clone(), |d, t| d.child(div().text_color(theme.secondary).child(t)))
                    .child(div().flex_1())
                    .child(quiet(change.at.with_timezone(&Local).format("%-d %b %Y, %H:%M").to_string()))
            }))
        });

        let pr_rows = |title: &str, prs: &[crate::issues::LinkedPr], key: &str, cx: &mut Context<Self>| {
            (!prs.is_empty()).then(|| {
                div().flex().flex_col().gap_1().child(heading(title, Some(prs.len()))).children(prs.iter().map(|pr| {
                    let url = pr.url.clone();
                    let (label, color) = if pr.merged_at.is_some() {
                        ("Merged", theme.slot(6))
                    } else if pr.state == "CLOSED" {
                        ("Closed", theme.critical())
                    } else {
                        ("Open", theme.good())
                    };
                    let (when, at) = match pr.activity_at.iter().max() {
                        Some(last) => ("active", *last),
                        None => ("opened", pr.created_at),
                    };
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(
                            div()
                                .id(SharedString::from(format!("{key}-{seq}-{}", pr.url)))
                                .text_color(theme.selected)
                                .cursor_pointer()
                                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                                .child(pr.repo.as_ref().map_or(format!("#{}", pr.number), |r| format!("{r}#{}", pr.number))),
                        )
                        .child(pill(label, color))
                        .child(div().flex_1())
                        .child(quiet(format!("{when} {}", relative_date(at, now))))
                }))
            })
        };
        let linked = pr_rows("Linked pull requests", &issue.linked_prs, "linked", cx);
        let mentioned = pr_rows("Mentioned in pull requests", &issue.mentioned_prs, "mentioned", cx);

        let description = div().flex().flex_col().gap_1().child(heading("Description", None)).child(match &drawer.text {
            None => quiet("Loading".into()).into_any_element(),
            Some(None) => quiet("Not in Gannin's caches yet: open it in Gannin once, or on GitHub.".into()).into_any_element(),
            Some(Some(t)) if t.body.trim().is_empty() => div().text_color(theme.tertiary).child("No description").into_any_element(),
            Some(Some(t)) => markdown(&format!("description-{seq}"), &t.body, theme),
        });

        let comments = text.map(|t| {
            let count = t.comment_count.unwrap_or(t.comments.len());
            let earlier = count.saturating_sub(t.comments.len());
            let issue_url = issue.url.clone();
            div()
                .flex()
                .flex_col()
                .gap_3()
                .child(heading("Comments", Some(count)))
                .when(earlier > 0, |d| {
                    d.child(
                        div()
                            .id(("earlier-comments", seq))
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&issue_url)))
                            .child(format!("{earlier} earlier comments on GitHub")),
                    )
                })
                .children(t.comments.iter().enumerate().map(|(i, comment)| {
                    let link = comment.url.clone();
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(div().font_weight(FontWeight::MEDIUM).child(comment.author.clone()))
                                .when_some(comment.at, |d, at| d.child(quiet(relative_date(at, now))))
                                .child(div().flex_1())
                                .when_some(link, |d, url| {
                                    d.child(
                                        div()
                                            .id(("comment-link", seq * 1000 + i))
                                            .text_xs()
                                            .text_color(theme.selected)
                                            .cursor_pointer()
                                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                                            .child("Open"),
                                    )
                                }),
                        )
                        .child(markdown(&format!("comment-{seq}-{i}"), &comment.body, theme))
                }))
        });

        let left = div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_6()
            .p_5()
            .child(timeline)
            .children(board_status)
            .children(linked)
            .children(mentioned)
            .child(description)
            .children(comments)
            .child(self.related(drawer, theme, cx));

        // The right column, as `IssueWindow`'s form: assignees, then each
        // board's fields.
        let group = |title: String| div().pb_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(title);
        let row = |name: &str, value: String| {
            div()
                .flex()
                .flex_row()
                .gap_2()
                .py_1()
                .border_b_1()
                .border_color(theme.grid)
                .child(div().w(px(100.)).flex_none().text_color(theme.secondary).child(name.to_string()))
                .child(div().flex_1().min_w_0().child(value))
        };
        let right = div()
            .w(px(280.))
            .flex_none()
            .flex()
            .flex_col()
            .gap_5()
            .p_4()
            .border_l_1()
            .border_color(theme.border)
            .child(div().flex().flex_col().child(group("Assignees".into())).map(|d| {
                if issue.assignees.is_empty() {
                    d.child(div().text_color(theme.tertiary).child("Nobody"))
                } else {
                    d.children(issue.assignees.iter().zip(&issue.assignee_logins).zip(&issue.assignee_avatars).map(|((name, login), url)| {
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .py_0p5()
                            .child(avatar(login, url.as_deref(), 20., theme, cx))
                            .child(name.clone())
                            .when(name != login, |d| d.child(div().text_color(theme.secondary).child(login.clone())))
                    }))
                }
            }))
            .children(issue.boards.iter().map(|(board, values)| {
                div().flex().flex_col().child(group(board.clone())).children(values.iter().map(|(name, value)| row(name, value.clone())))
            }))
            .when(issue.has_history && issue.boards.is_empty(), |d| d.child(div().text_color(theme.tertiary).child("Not on a board")))
            .when_some(issue.milestone.clone(), |d, m| d.child(div().flex().flex_col().child(group("Milestone".into())).child(m)));

        div().flex().flex_col().child(header).child(div().flex().flex_row().items_start().child(left).child(right))
    }

    fn dock(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .relative()
            .h(px(self.dock_height))
            .flex_none()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .border_t_1()
            .border_color(theme.border)
            .child(
                div()
                    .h(px(30.))
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_3()
                    .bg(theme.sidebar)
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().font_weight(FontWeight::MEDIUM).child("Claude Code"))
                    .child(div().text_xs().text_color(theme.tertiary).child("A tab per session would sit here")),
            )
            .child(
                div()
                    .flex_1()
                    .p_4()
                    .text_color(theme.secondary)
                    .child("Sessions dock here in place of the Claude Code window. The terminal is the next pilot."),
            )
            .child(self.resize_handle("resize-dock", Edge::Dock, cx))
    }

    // MARK: Switcher

    /// Behind an open switcher: a click anywhere else closes it.
    fn switcher_backdrop(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("switcher-backdrop")
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .bottom_0()
            .occlude()
            .on_mouse_down(MouseButton::Left, cx.listener(|this, _: &MouseDownEvent, window, cx| this.close_switcher(window, cx)))
    }

    /// The second line under an org: which of its caches the pilot found.
    fn org_detail(&self, org: &str) -> String {
        let support = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default().join("Library/Application Support");
        let has = |folder: &str| support.join(folder).join(format!("{org}.json")).exists();
        let mut found = Vec::new();
        if has("StoredIssues") {
            found.push("Issues");
        }
        if has("Actions") {
            found.push("CI");
        }
        if found.is_empty() { "Nothing cached yet".into() } else { found.join(" • ") }
    }

    fn switcher_panel(&self, switcher: &Switcher, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let pick = switcher.pick;
        let matches = self.switcher_items(pick, &switcher.query);
        let current = match pick {
            Pick::Org => self.org.clone(),
            Pick::Project => self.project.clone(),
        };
        let (prompt, none, action) = match pick {
            Pick::Org => ("Find an org", "No org matches", "Org settings"),
            Pick::Project => ("Find a project", "No project matches", "Project settings"),
        };
        div()
            .id("switcher")
            .track_focus(&self.switcher_focus)
            .on_key_down(cx.listener(Self::switcher_key))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .occlude()
            .mt_1()
            .w(px(420.))
            .max_h(px(520.))
            .flex()
            .flex_col()
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded_lg()
            .shadow_lg()
            .overflow_hidden()
            // The search, caret first, as Zed's.
            .child(
                div()
                    .px_3()
                    .py_2p5()
                    .text_base()
                    .border_b_1()
                    .border_color(theme.border)
                    .flex()
                    .flex_row()
                    .child(div().text_color(theme.selected).child(if switcher.query.is_empty() { "|" } else { "" }))
                    .map(|d| {
                        if switcher.query.is_empty() {
                            d.child(div().text_color(theme.tertiary).child(prompt))
                        } else {
                            d.child(switcher.query.clone()).child(div().text_color(theme.selected).child("|"))
                        }
                    }),
            )
            // Actions first, then the list.
            .child(
                div().flex().flex_col().py_1().border_b_1().border_color(theme.border).child(
                    div()
                        .id("switcher-settings")
                        .mx_1()
                        .px_2()
                        .py_1p5()
                        .rounded_md()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_3()
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.row_selected))
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.close_switcher(window, cx);
                            this.navigate(Nav::Settings, false, cx);
                        }))
                        .child(div().w(px(16.)).text_color(theme.secondary).child("⚙"))
                        .child(action),
                ),
            )
            .child(
                div()
                    .id("switcher-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .py_1()
                    .children(matches.iter().enumerate().map(|(index, (label, key))| {
                        let highlighted = index == switcher.highlighted;
                        let is_current = current.as_ref() == Some(key);
                        let chosen = key.clone();
                        let detail = match pick {
                            Pick::Org => self.org_detail(key),
                            Pick::Project => self.projects.iter().find(|p| &p.id == key).map_or_else(String::new, |p| {
                                let repos = match p.repos.len() {
                                    0 => "every repo".to_string(),
                                    1 => "1 repo".to_string(),
                                    n => format!("{n} repos"),
                                };
                                format!("{repos} • {}", p.id)
                            }),
                        };
                        div()
                            .id(("switcher-item", index))
                            .mx_1()
                            .px_2()
                            .py_1p5()
                            .rounded_md()
                            .flex()
                            .flex_row()
                            .items_start()
                            .gap_3()
                            .cursor_pointer()
                            .when(highlighted, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.choose(pick, chosen.clone(), window, cx)))
                            .child(div().w(px(16.)).pt_0p5().text_color(theme.selected).child(if is_current { "✓" } else { "" }))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .child(div().text_base().truncate().child(label.clone()))
                                    .child(div().text_sm().text_color(theme.secondary).truncate().child(detail)),
                            )
                    }))
                    .when(matches.is_empty(), |d| d.child(div().px_3().py_2().text_color(theme.secondary).child(none))),
            )
    }
}

fn placeholder_button(label: &'static str, theme: &Theme) -> impl IntoElement {
    div()
        .flex_1()
        .py_1()
        .flex()
        .justify_center()
        .rounded_md()
        .border_1()
        .border_color(theme.border)
        .text_color(theme.secondary)
        .child(label)
}

impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.persist(cx);
        let theme = Theme::new(matches!(window.appearance(), WindowAppearance::Dark | WindowAppearance::VibrantDark));
        let center = div()
            .flex_1()
            .min_w_0()
            .h_full()
            .flex()
            .flex_col()
            .child(self.tab_bar(&theme, cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .child(self.page(&theme))
                    .when(!self.drawers.is_empty(), |d| d.child(self.drawer_stack(&theme, cx))),
            )
            .when(self.dock_open, |d| d.child(self.dock(&theme, cx)));
        div()
            .id("workspace")
            .key_context("Workspace")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &ToggleSidebar, _, cx| {
                this.sidebar_open = !this.sidebar_open;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &ToggleInspector, _, cx| {
                this.inspector_open = !this.inspector_open;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &ToggleDock, _, cx| {
                this.dock_open = !this.dock_open;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &CloseTab, _, cx| this.close_tab(this.active, cx)))
            .on_action(cx.listener(|this, _: &OpenSwitcher, window, cx| this.open_switcher(Pick::Org, window, cx)))
            // Escape closes the top drawer; the switcher takes it first when open.
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" && this.switcher.is_none() && !this.drawers.is_empty() {
                    this.pop_drawer(cx);
                    cx.stop_propagation();
                }
            }))
            .on_mouse_move(cx.listener(Self::drag))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _: &MouseUpEvent, _, cx| {
                    if this.resizing.take().is_some() {
                        cx.notify();
                    }
                }),
            )
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .text_color(theme.fg)
            .font_family(".SystemUIFont")
            .text_sm()
            .child(self.title_bar(&theme, cx))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_row()
                    .when(self.sidebar_open, |d| d.child(self.sidebar(&theme, cx)))
                    .child(center)
                    .when(self.inspector_open, |d| d.child(self.inspector(&theme, cx))),
            )
            .child(self.status_bar(&theme, cx))
            .when(self.switcher.is_some(), |d| d.child(self.switcher_backdrop(cx)))
    }
}
