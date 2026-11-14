//! A consolidated, single-window shell: the title bar with the org
//! switcher, the navigation sidebar, pages as tabs (a session, its terminal
//! and its code change, is a tab too, in place of the Claude Code window),
//! and on the right the menu bar's "Your work", which lists what's in
//! flight and switches to it.

use crate::charts::{histogram_cell, spark_bars, Theme};
use crate::data;
use crate::format::{compact_duration, duration_or_dash, percent, relative_date};
use crate::detail::{self, IssueText, Workflow};
use crate::projects::{self, Project};
use crate::issues::{pill, ColumnDrag, IssueItem, IssuesPage, IssuesSaved, OpenIssue};
use crate::auth::{self, DeviceCode, Poll, Viewer};
use crate::avatars::avatar;
use crate::markdown::markdown;
use chrono::{DateTime, Local, Utc};
use std::sync::Arc;
use crate::metrics::RepoStats;
use crate::page::{ActionsPage, OpenRepo};
use crate::session::{self, Changed, Kind, SessionPage, State};
use crate::prs::{OpenPr, PrItem, PrState, PrsPage, PrsSaved, ReviewPrs};
use crate::state::{CiSaved, SavedState, SavedTab};
use crate::work::{self, Pr, Work};
use gpui::{
    actions, anchored, Focusable, black, deferred, div, ease_out_quint, prelude::*, px, relative, Animation, AnimationExt, AnyElement, ClickEvent, Context, App, Entity, FocusHandle, FontWeight, KeyBinding,
    KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, SharedString, Subscription, Window,
    WindowAppearance,
};
use std::collections::HashSet;
use std::path::PathBuf;

actions!(shell, [ToggleSidebar, ToggleInspector, ToggleSync, Refresh, NewClaudeSession, NewTerminal, NewAsk, NewQuickChange, NewPlan, CloseTab, NextTab, PreviousTab, OpenSwitcher]);

pub fn key_bindings() -> Vec<KeyBinding> {
    vec![
        KeyBinding::new("ctrl-cmd-s", ToggleSidebar, None),
        KeyBinding::new("cmd-alt-i", ToggleInspector, None),
        KeyBinding::new("cmd-t", NewClaudeSession, None),
        KeyBinding::new("ctrl-`", NewTerminal, None),
        KeyBinding::new("cmd-w", CloseTab, None),
        KeyBinding::new("cmd-shift-right", NextTab, None),
        KeyBinding::new("cmd-shift-left", PreviousTab, None),
        KeyBinding::new("cmd-shift-]", NextTab, None),
        KeyBinding::new("cmd-shift-[", PreviousTab, None),
        // ⇧⌘[ and ⇧⌘] arrive as ⌘{ and ⌘}, as Zed binds them.
        KeyBinding::new("cmd-}", NextTab, None),
        KeyBinding::new("cmd-{", PreviousTab, None),
        KeyBinding::new("ctrl-tab", NextTab, None),
        KeyBinding::new("ctrl-shift-tab", PreviousTab, None),
        KeyBinding::new("cmd-alt-o", OpenSwitcher, None),
        KeyBinding::new("cmd-r", Refresh, None),
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
    /// A session's tab, by the pilot's own number for it. Not restored at
    /// launch: its terminal ended with the last run.
    Session(u32),
    /// A kind of document in the team's harness.
    Harness(crate::harness::HarnessKind),
    /// The review panel in each state, from a made-up PR (the pilot's own).
    ReviewPreview,
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
            Nav::Session(_) => "Session",
            Nav::Harness(kind) => kind.title(),
            Nav::ReviewPreview => "Review Preview",
        }
    }
}

enum Row {
    Item(Nav),
    /// A row with rows under it, behind a disclosure triangle.
    // Used again once Projects, Views and Everyone are ported.
    #[allow(dead_code)]
    Group(Nav, Vec<Nav>),
}

struct Section {
    id: &'static str,
    /// Untitled sections can't be collapsed.
    title: Option<&'static str>,
    rows: Vec<Row>,
}

/// The sidebar in `OrgSidebar`'s order, with only the pages the pilot has.
/// The rest are commented out where they'd go, as a list of what's left
/// to port; a section with none is left out.
fn sections() -> Vec<Section> {
    use Nav::*;
    use Row::Item;
    vec![
        // Section { id: "top", title: None, rows: vec![Item(Dashboard), Item(Inbox)] },
        Section {
            id: "work",
            title: Some("Work"),
            rows: vec![
                Item(PullRequests),
                Item(Issues),
                // Item(Epics),
                // Item(Repositories),
                // Group(Projects, vec![]),
                // Group(Views, vec![]),
            ],
        },
        Section {
            id: "delivery",
            title: Some("Delivery"),
            rows: vec![
                Item(Scorecards),
                // Item(PrFlow),
                // Item(IssueFlow),
                // Item(Releases),
                // Item(Investments),
                // Item(RdTime),
                Item(Ci),
            ],
        },
        Section {
            id: "team",
            title: Some("Team"),
            rows: vec![
                // Group(Everyone, vec![]),
                Item(Activity),
                // Item(TimeOff),
            ],
        },
        // Section {
        //     id: "rituals",
        //     title: Some("Rituals"),
        //     rows: vec![Item(Standup), Item(Recap), Item(Prioritisation), Item(Planning), Item(Refine), Item(Hygiene)],
        // },
        // The team's harness is a panel of its own (`harness_panel`).
        // Section {
        //     id: "agents",
        //     title: Some("Agents"),
        //     rows: vec![Item(AgentMetrics), Item(WaitingOnYou), Item(Routines), Item(Queue)],
        // },
    ]
}

/// What a tab is, for its icon and the tab bar's filter; in the order
/// grouped tabs go.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub enum TabKind {
    Pages,
    Work,
    Reviews,
    Plans,
    Asks,
}

impl TabKind {
    const ALL: [TabKind; 5] = [TabKind::Pages, TabKind::Work, TabKind::Reviews, TabKind::Plans, TabKind::Asks];

    fn title(self) -> &'static str {
        match self {
            TabKind::Pages => "Pages",
            TabKind::Work => "Work",
            TabKind::Reviews => "Reviews",
            TabKind::Plans => "Plans",
            TabKind::Asks => "Asks",
        }
    }

    fn icon(self) -> &'static str {
        match self {
            TabKind::Pages => "icons/file.svg",
            TabKind::Work => "icons/pull_request.svg",
            TabKind::Reviews => "icons/eye.svg",
            TabKind::Plans => "icons/list_todo.svg",
            TabKind::Asks => "icons/chat.svg",
        }
    }
}

#[derive(Clone, Copy)]
enum Edge {
    Harness,
    Sidebar,
    Inspector,
}

/// What the inspector shows; issues open in drawers instead.
enum Inspected {
    Repo(RepoStats),
}

/// An issue or a pull request in a drawer.
struct Drawer {
    /// Unique per drawer opened, so each one slides in once.
    seq: usize,
    item: DrawerItem,
    /// Its description and comments: nil while they load, then whatever
    /// Gannin's caches had.
    text: Option<Option<Arc<IssueText>>>,
}

enum DrawerItem {
    Issue(IssueDrawer),
    Pull(PrItem),
    Doc(crate::harness::Doc),
}

/// An issue, with its parent and sub-issues looked up when it opened.
struct IssueDrawer {
    issue: IssueItem,
    parent: Option<IssueItem>,
    sub_issues: Vec<IssueItem>,
}

/// Wide enough for the issue and its board fields side by side, as
/// `IssueWindow` lays them out; narrower windows cap it.
const DRAWER_WIDTH: f32 = 900.0;
/// How far each drawer beneath the top one shows, as `drawerPeek`.
const DRAWER_PEEK: f32 = 14.0;

/// The workload sync's state, for the title bar.
#[derive(Default)]
struct SyncStatus {
    running: bool,
    error: Option<String>,
    /// The steps of the sync under way, or of the last one.
    progress: crate::sync::Progress,
    /// The org being synced now, or last.
    org: Option<String>,
    /// Recent syncs, newest first.
    runs: Vec<SyncRun>,
    open: bool,
    prefs: crate::state::SyncPrefs,
    /// When Your Work's live query last ran.
    work_at: Option<std::time::Instant>,
}

/// One sync, for the popover's log.
struct SyncRun {
    org: String,
    at: chrono::DateTime<chrono::Utc>,
    took: std::time::Duration,
    result: Result<crate::sync::Report, String>,
}

/// Signing in with GitHub, step by step, as `SignInView`.
enum SignIn {
    Requesting,
    Code { code: DeviceCode, copied: bool },
    Finishing,
    Failed(String),
}

/// What a tab shows: a page of its own (so two Issues tabs can be filtered
/// differently), or nothing of its own (a session's, or an unported page).
#[derive(Clone)]
enum Page {
    Issues(Entity<IssuesPage>),
    Prs(Entity<PrsPage>),
    Ci(Entity<ActionsPage>),
    Scorecard(Entity<crate::scorecard::ScorecardPage>),
    Activity(Entity<crate::activity::ActivityPage>),
    Harness(Entity<crate::harness::HarnessPage>),
    ReviewPreview(Entity<crate::review_preview::ReviewPreview>),
    None,
}

/// A tab: its page, and the name given it. A named tab is a view of its
/// own: the sidebar never switches to it or replaces it.
struct Tab {
    id: u64,
    nav: Nav,
    name: Option<String>,
    page: Page,
}

/// A tab being dragged: where it was, and its name for the drag image.
#[derive(Clone)]
struct DraggedTab(usize, String);

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
    /// A tab being renamed (by its id), in Zed's single-line editor.
    renaming: Option<(u64, Entity<editor::Editor>)>,
    _rename_subscription: Option<Subscription>,
    orgs: Vec<String>,
    org: Option<String>,
    /// The org's projects, each a harness, and the one picked by its id.
    projects: Vec<Project>,
    project: Option<String>,
    /// How the org's issues move through its board, for drawer timing.
    workflow: Workflow,
    collapsed_sections: HashSet<&'static str>,
    expanded_groups: HashSet<Nav>,
    tabs: Vec<Tab>,
    next_tab: u64,
    /// What a new tab of each page starts from.
    templates: (IssuesSaved, PrsSaved, CiSaved),
    active: usize,
    inspector: Option<Inspected>,
    sidebar_open: bool,
    inspector_open: bool,
    sidebar_width: f32,
    harness_width: f32,
    inspector_width: f32,
    resizing: Option<Edge>,
    switcher: Option<Switcher>,
    /// Bottom first; the last is on top.
    drawers: Vec<Drawer>,
    drawer_seq: usize,
    /// Every issue, never shown: what drawers and Your Work look up.
    issues: Entity<IssuesPage>,
    sessions: Vec<Entity<SessionPage>>,
    next_session: u32,
    /// Reviews asked of you and your PRs, from the org's PR cache.
    work: Work,
    /// Who's signed in to the pilot with GitHub.
    viewer: Option<Viewer>,
    sign_in: Option<SignIn>,
    /// Polls GitHub while signing in; dropping it stops.
    sign_in_task: Option<gpui::Task<()>>,
    account_open: bool,
    /// The tab bar's "+" menu is open.
    new_menu_open: bool,
    /// The Harness panel shows, beside the navigation when that's open too.
    harness_open: bool,
    /// How many documents of each kind the org's harnesses hold.
    harness_counts: std::collections::HashMap<crate::harness::HarnessKind, usize>,
    /// New Plan, New Ask or New Quick Change, over the window.
    launch_form: Option<(Entity<crate::launch_form::LaunchForm>, Subscription)>,
    /// Review a Pull Request's picker, while it's open.
    pr_picker: Option<(Entity<crate::pr_picker::PrPicker>, Subscription)>,
    /// The tab bar's filter by kind (None is all), whether tabs group by
    /// kind, and whether its menu is open.
    tab_filter: Option<TabKind>,
    group_tabs: bool,
    tab_filter_open: bool,
    /// Sessions being reopened at launch, which open without switching.
    reopening: usize,
    /// Explain's sheet, while it's open.
    explain: Option<(Entity<crate::explain::ExplainSheet>, Subscription)>,
    sync: SyncStatus,
    _sync_loop: Option<gpui::Task<()>>,
    /// What was last written, so unchanged state isn't written again.
    last_saved: Option<SavedState>,
    _subscriptions: Vec<Subscription>,
}

impl Workspace {
    fn snapshot(&self, cx: &App) -> SavedState {
        SavedState {
            org: self.org.clone(),
            project: self.project.clone(),
            tabs: Vec::new(),
            views: self
                .tabs
                .iter()
                .filter(|tab| !matches!(tab.nav, Nav::Session(_)))
                .map(|tab| SavedTab {
                    nav: tab.nav,
                    name: tab.name.clone(),
                    issues: match &tab.page {
                        Page::Issues(page) => Some(page.read(cx).saved()),
                        _ => None,
                    },
                    prs: match &tab.page {
                        Page::Prs(page) => Some(page.read(cx).saved()),
                        _ => None,
                    },
                    ci: match &tab.page {
                        Page::Ci(page) => Some(page.read(cx).saved()),
                        _ => None,
                    },
                })
                .collect(),
            sessions: self
                .tabs
                .iter()
                .filter_map(|tab| match tab.nav {
                    Nav::Session(id) => self.session(id, cx).and_then(|p| p.read(cx).launch.as_ref().map(|l| l.id.clone())),
                    _ => None,
                })
                .collect(),
            // Sessions open after the views, so the index counts the views.
            active: self.tabs.iter().take(self.active).filter(|tab| !matches!(tab.nav, Nav::Session(_))).count(),
            sidebar_open: self.sidebar_open,
            harness_open: self.harness_open,
            tab_filter: self.tab_filter,
            group_tabs: self.group_tabs,
            inspector_open: self.inspector_open,
            dock_open: false,
            sidebar_width: self.sidebar_width,
            inspector_width: self.inspector_width,
            dock_height: 220.0,
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
            tab_names: Vec::new(),
            sync: self.sync.prefs.clone(),
            ci: self.template_ci(cx),
            issues: self.template_issues(cx),
            prs: self.template_prs(cx),
        }
    }

    /// Writes the state when it differs from what was last written. Panel
    /// drags are left until they end, rather than written on every move.
    fn persist(&mut self, cx: &App) {
        let resizing_column = self.tabs.iter().any(|tab| match &tab.page {
            Page::Issues(page) => page.read(cx).is_resizing(),
            Page::Prs(page) => page.read(cx).is_resizing(),
            _ => false,
        });
        if self.resizing.is_some() || resizing_column {
            return;
        }
        let state = self.snapshot(cx);
        if self.last_saved.as_ref() != Some(&state) {
            state.save();
            self.last_saved = Some(state);
        }
    }

    pub fn new(saved: SavedState, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // The window's close button is a quit (it's the only window), so it
        // asks the same way.
        let this = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            let Some(this) = this.upgrade() else { return true };
            let running = !this.read(cx).running(cx).is_empty();
            if running {
                this.update(cx, |this, cx| this.quit(window, cx));
            }
            !running
        });
        let views = Self::saved_views(&saved);
        let sessions = saved.sessions.clone();
        let active = saved.active;
        let mut workspace = Self::build(saved, window, cx);
        for view in &views {
            let tab = workspace.make_tab(view.nav, Some(view), window, cx);
            workspace.tabs.push(tab);
        }
        workspace.active = active.min(workspace.tabs.len().saturating_sub(1));
        workspace.load_viewer(cx);
        // The sessions that were open come back, claude resuming in each.
        let launches = crate::launch::saved();
        for id in &sessions {
            if let Some(launch) = launches.iter().find(|l| &l.id == id).cloned() {
                let folder = launch.harness_path.clone();
                workspace.reopening += 1;
                workspace.open_session(Kind::Claude, folder, Some(launch), window, cx);
            }
        }
        if workspace.harness_open {
            workspace.load_harness_counts(cx);
        }
        crate::github::set_reserve(workspace.sync.prefs.reserve);
        workspace.start_sync_loop(cx);
        workspace.load_settings(cx);
        workspace
    }

    /// The tabs saved; from before tabs had controls of their own, each page
    /// with the one set of controls and the names given then.
    fn saved_views(saved: &SavedState) -> Vec<SavedTab> {
        if !saved.views.is_empty() {
            return saved.views.clone();
        }
        saved
            .tabs
            .iter()
            .filter(|nav| !matches!(nav, Nav::Session(_)))
            .map(|&nav| SavedTab {
                nav,
                name: saved.tab_names.iter().find(|(n, _)| *n == nav).map(|(_, name)| name.clone()),
                issues: (nav == Nav::Issues).then(|| saved.issues.clone()),
                prs: (nav == Nav::PullRequests).then(|| saved.prs.clone()),
                ci: (nav == Nav::Ci).then(|| saved.ci.clone()),
            })
            .collect()
    }

    /// Reads the org's projects and workflow off the main thread, then
    /// keeps the pages to the project picked (or the first, as Gannin
    /// falls back to home).
    fn load_settings(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        self.load_work(org.clone(), cx);
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
        for page in self.pages() {
            match page {
                Page::Issues(page) => page.update(cx, |page, cx| page.set_focus(focus.clone(), cx)),
                Page::Prs(page) => page.update(cx, |page, cx| page.set_focus(focus.clone(), cx)),
                Page::Ci(page) => page.update(cx, |page, cx| page.set_focus(focus.clone(), cx)),
                _ => {}
            }
        }
        cx.notify();
    }

    fn choose_project(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        self.project = Some(id);
        self.switcher = None;
        self.drawers.clear();
        self.inspector = None;
        window.focus(&self.focus, cx);
        self.apply_focus(cx);
    }

    fn build(saved: SavedState, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let sync_prefs = saved.sync.clone();
        let orgs = data::orgs();
        // The saved org, while it still has a cache.
        let org = saved.org.clone().filter(|org| orgs.contains(org)).or_else(|| orgs.first().cloned());
        // Every issue, for drawers and Your Work; tabs have pages of their own.
        let issues = cx.new(|cx| IssuesPage::new(org.clone(), &IssuesSaved::default(), window, cx));
        let subscriptions = vec![cx.observe_window_appearance(window, |_, window, cx| {
            crate::zed::follow_appearance(window, cx);
            cx.notify();
        })];
        crate::zed::follow_appearance(window, cx);
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            focus,
            switcher_focus: cx.focus_handle(),
            renaming: None,
            _rename_subscription: None,
            orgs,
            org,
            projects: Vec::new(),
            project: saved.project.clone(),
            workflow: Workflow::default(),
            collapsed_sections: sections().iter().map(|s| s.id).filter(|id| saved.collapsed_sections.iter().any(|c| c == id)).collect(),
            expanded_groups: saved.expanded_groups.iter().copied().collect(),
            active: 0,
            tabs: Vec::new(),
            next_tab: 0,
            templates: (saved.issues.clone(), saved.prs.clone(), saved.ci.clone()),
            inspector: None,
            sidebar_open: saved.sidebar_open,
            tab_filter: saved.tab_filter,
            group_tabs: saved.group_tabs,
            harness_open: saved.harness_open,
            inspector_open: saved.inspector_open,
            sidebar_width: saved.sidebar_width,
            harness_width: saved.sidebar_width,
            inspector_width: saved.inspector_width,
            last_saved: Some(saved),
            resizing: None,
            switcher: None,
            drawers: Vec::new(),
            drawer_seq: 0,
            issues,
            sessions: Vec::new(),
            next_session: 1,
            work: Work::default(),
            viewer: None,
            sign_in: None,
            sign_in_task: None,
            account_open: false,
            new_menu_open: false,
            harness_counts: Default::default(),
            launch_form: None,
            pr_picker: None,
            explain: None,
            reopening: 0,
            tab_filter_open: false,
            sync: SyncStatus { prefs: sync_prefs, ..SyncStatus::default() },
            _sync_loop: None,
            _subscriptions: subscriptions,
        }
    }

    /// Shows `nav`: switches to a tab of it that hasn't been named, else
    /// puts it in the current tab, else (Command held, or the current tab is
    /// named or a session's) opens a new tab beside it. A named tab is a view
    /// someone made, so it's never switched to or replaced from here.
    fn navigate(&mut self, nav: Nav, new_tab: bool, window: &mut Window, cx: &mut Context<Self>) {
        // Drawers belong to the page under them.
        self.drawers.clear();
        let reusable = |tab: &Tab| tab.name.is_none() && !matches!(tab.nav, Nav::Session(_));
        if !new_tab {
            if let Some(index) = self.tabs.iter().position(|tab| tab.nav == nav && reusable(tab)) {
                self.activate(index, window, cx);
                return;
            }
        }
        let tab = self.make_tab(nav, None, window, cx);
        if !new_tab && self.tabs.get(self.active).is_some_and(reusable) {
            self.tabs[self.active] = tab;
        } else if self.tabs.is_empty() {
            self.tabs.push(tab);
            self.active = 0;
        } else {
            self.tabs.insert(self.active + 1, tab);
            self.active += 1;
        }
        self.focus_current(window, cx);
        cx.notify();
    }

    /// A tab for `nav`, with a page of its own made from `saved` (a saved
    /// tab's controls), else from the templates with nothing filtered.
    fn make_tab(&mut self, nav: Nav, saved: Option<&SavedTab>, window: &mut Window, cx: &mut Context<Self>) -> Tab {
        let org = self.org.clone();
        let page = match nav {
            Nav::Issues => {
                let state = saved.and_then(|s| s.issues.clone()).unwrap_or_else(|| self.template_issues(cx).fresh());
                Page::Issues(cx.new(|cx| IssuesPage::new(org, &state, window, cx)))
            }
            Nav::PullRequests => {
                let state = saved.and_then(|s| s.prs.clone()).unwrap_or_else(|| self.template_prs(cx).fresh());
                let page = cx.new(|cx| PrsPage::new(org, &state, window, cx));
                let me = self.viewer.as_ref().map(|v| v.login.clone());
                page.update(cx, |page, cx| page.set_me(me, cx));
                Page::Prs(page)
            }
            Nav::Ci => {
                let state = saved.and_then(|s| s.ci.clone()).unwrap_or_else(|| self.template_ci(cx));
                Page::Ci(cx.new(|cx| ActionsPage::new(org, &state, window, cx)))
            }
            Nav::Scorecards => Page::Scorecard(cx.new(|cx| crate::scorecard::ScorecardPage::new(org, cx))),
            Nav::Activity => Page::Activity(cx.new(|cx| crate::activity::ActivityPage::new(org, cx))),
            Nav::ReviewPreview => Page::ReviewPreview(cx.new(|cx| crate::review_preview::ReviewPreview::new(window, cx))),
            Nav::Harness(kind) => Page::Harness(cx.new(|cx| crate::harness::HarnessPage::new(org, kind, window, cx))),
            _ => Page::None,
        };
        let subscriptions = Self::watch(&page, window, cx);
        self._subscriptions.extend(subscriptions);
        let focus = self.focus_repos();
        match &page {
            Page::Issues(p) => p.update(cx, |p, cx| p.set_focus(focus, cx)),
            Page::Prs(p) => p.update(cx, |p, cx| p.set_focus(focus, cx)),
            Page::Ci(p) => p.update(cx, |p, cx| p.set_focus(focus, cx)),
            _ => {}
        }
        self.next_tab += 1;
        Tab { id: self.next_tab, nav, name: saved.and_then(|s| s.name.clone()), page }
    }

    /// Opens drawers, the inspector and saving from a page's events.
    fn watch(page: &Page, window: &mut Window, cx: &mut Context<Self>) -> Vec<Subscription> {
        match page {
            Page::Issues(page) => vec![
                // A row picked in a list replaces the stack.
                cx.subscribe(page, |this, _, event: &OpenIssue, cx| {
                    this.drawers.clear();
                    this.push_drawer(event.0.clone(), cx);
                }),
                // Also redraws the tab, which shows the page's count.
                cx.observe(page, |this, _, cx| {
                    this.persist(cx);
                    cx.notify();
                }),
            ],
            Page::Prs(page) => vec![
                cx.subscribe(page, |this, _, event: &OpenPr, cx| {
                    this.drawers.clear();
                    this.push_pr_drawer(event.0.clone(), cx);
                }),
                cx.subscribe_in(page, window, |this, _, event: &ReviewPrs, window, cx| this.review_many(event.0.clone(), window, cx)),
                cx.observe(page, |this, _, cx| {
                    this.persist(cx);
                    cx.notify();
                }),
            ],
            Page::Ci(page) => vec![
                cx.subscribe(page, |this, _, event: &OpenRepo, cx| {
                    this.inspector = Some(Inspected::Repo(event.0.clone()));
                    this.inspector_open = true;
                    cx.notify();
                }),
                cx.observe(page, |this, _, cx| this.persist(cx)),
            ],
            // An issue opens in a drawer when the store has it, else on
            // GitHub; a PR on GitHub.
            Page::Activity(page) => vec![cx.subscribe(page, |this, _, event: &crate::activity::OpenItem, cx| {
                match event.issue_id.as_deref().and_then(|id| this.issues.read(cx).issue(id)) {
                    Some(issue) => {
                        this.drawers.clear();
                        this.push_drawer(issue, cx);
                    }
                    None => cx.open_url(&event.url),
                }
            })],
            Page::Harness(page) => vec![cx.subscribe(page, |this, _, event: &crate::harness::OpenDoc, cx| {
                this.drawers.clear();
                let id = event.0.path.clone();
                this.open_drawer(DrawerItem::Doc(event.0.clone()), id, cx);
            })],
            _ => Vec::new(),
        }
    }

    /// Every tab's page.
    fn pages(&self) -> Vec<Page> {
        self.tabs.iter().map(|tab| tab.page.clone()).collect()
    }

    fn current_page(&self) -> Page {
        self.tabs.get(self.active).map_or(Page::None, |tab| tab.page.clone())
    }

    /// The controls a new tab starts from: the current tab's of that page,
    /// else the first such tab's, else what was saved.
    fn template_issues(&self, cx: &App) -> IssuesSaved {
        let current = self.current_page();
        let pages = std::iter::once(&current).chain(self.tabs.iter().map(|t| &t.page));
        pages.into_iter().find_map(|p| if let Page::Issues(p) = p { Some(p.read(cx).saved()) } else { None }).unwrap_or_else(|| self.templates.0.clone())
    }

    fn template_prs(&self, cx: &App) -> PrsSaved {
        let current = self.current_page();
        let pages = std::iter::once(&current).chain(self.tabs.iter().map(|t| &t.page));
        pages.into_iter().find_map(|p| if let Page::Prs(p) = p { Some(p.read(cx).saved()) } else { None }).unwrap_or_else(|| self.templates.1.clone())
    }

    fn template_ci(&self, cx: &App) -> CiSaved {
        let current = self.current_page();
        let pages = std::iter::once(&current).chain(self.tabs.iter().map(|t| &t.page));
        pages.into_iter().find_map(|p| if let Page::Ci(p) = p { Some(p.read(cx).saved()) } else { None }).unwrap_or_else(|| self.templates.2.clone())
    }

    fn session(&self, id: u32, cx: &App) -> Option<&Entity<SessionPage>> {
        self.sessions.iter().find(|s| s.read(cx).id == id)
    }

    /// Switches to a tab, giving a session's terminal the keyboard.
    fn activate(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if self.active != index {
            self.drawers.clear();
        }
        self.active = index.min(self.tabs.len().saturating_sub(1));
        // A tab the filter hides (a new one, say) shows all again.
        if let (Some(kind), Some(tab)) = (self.tab_filter, self.tabs.get(self.active)) {
            if self.tab_kind(tab, cx) != kind {
                self.tab_filter = None;
            }
        }
        self.focus_current(window, cx);
        cx.notify();
    }

    fn focus_current(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.current() {
            Some(Nav::Session(id)) => {
                if let Some(page) = self.session(id, cx) {
                    let handle = page.focus_handle(cx);
                    window.focus(&handle, cx);
                }
            }
            _ => window.focus(&self.focus, cx),
        }
    }

    /// Asks where to start, then opens the session in a tab of its own.
    fn new_session(&mut self, kind: Kind, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(gpui::PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some(match kind {
                Kind::Claude => "Start Claude Code Here".into(),
                Kind::Shell => "Open Terminal Here".into(),
            }),
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            let Some(folder) = paths.into_iter().next() else { return };
            this.update_in(cx, |this, window, cx| this.open_session(kind, folder, None, window, cx)).ok();
        })
        .detach();
    }

    /// Opens a session in a tab of its own: a terminal in `folder`, or a
    /// launch's start script.
    fn open_session(&mut self, kind: Kind, folder: PathBuf, launch: Option<crate::launch::Launch>, window: &mut Window, cx: &mut Context<Self>) {
        let task = session::spawn_terminal(kind, folder.clone(), launch.as_ref(), window, cx);
        cx.spawn_in(window, async move |this, cx| {
            let builder = match task.await {
                Ok(builder) => builder,
                Err(error) => {
                    eprintln!("Couldn't start the terminal: {error:#}");
                    return;
                }
            };
            this.update_in(cx, |this, window, cx| {
                let id = this.next_session;
                this.next_session += 1;
                let page = cx.new(|cx| SessionPage::new(id, kind, folder, launch, builder, window, cx));
                this._subscriptions.push(cx.subscribe(&page, |_, _, _: &Changed, cx| cx.notify()));
                this._subscriptions.push(cx.subscribe_in(&page, window, |this, _, event: &crate::review_panel::ExplainPr, window, cx| {
                    this.open_explain(event.0.clone(), event.1.clone(), window, cx)
                }));
                this.sessions.push(page);
                this.drawers.clear();
                this.next_tab += 1;
                let tab = Tab { id: this.next_tab, nav: Nav::Session(id), name: None, page: Page::None };
                this.tabs.push(tab);
                // Sessions reopened at launch don't take the tab that was showing.
                if this.reopening > 0 {
                    this.reopening -= 1;
                    cx.notify();
                } else {
                    this.activate(this.tabs.len() - 1, window, cx);
                }
            })
            .ok();
        })
        .detach();
    }

    // MARK: Launching, as Gannin starts sessions

    /// The harness that covers `repo`: the project whose repos include it,
    /// else the org's first.
    fn harness_for(&self, repo: &str) -> Option<String> {
        self.projects.iter().find(|p| p.repos.iter().any(|r| r == repo)).or(self.projects.first()).map(|p| p.id.clone())
    }

    /// The tab already showing a launch about `subject_id` of this flow.
    fn session_for(&self, subject_id: &str, flow: crate::launch::Flow, cx: &App) -> Option<usize> {
        self.tabs.iter().position(|tab| match tab.nav {
            Nav::Session(id) => self.session(id, cx).and_then(|p| p.read(cx).launch.as_ref()).is_some_and(|l| {
                l.flow == flow && l.subject.as_ref().is_some_and(|s| s.id == subject_id)
            }),
            _ => false,
        })
    }

    /// A launch the pilot started before about `subject_id` (in an earlier
    /// run), to resume.
    fn saved_launch(subject_id: &str, flow: crate::launch::Flow) -> Option<crate::launch::Launch> {
        crate::launch::saved().into_iter().find(|l| l.flow == flow && l.subject.as_ref().is_some_and(|s| s.id == subject_id))
    }

    /// Shows a session about the subject if there is one (opening it again
    /// from an earlier run), and says whether it did.
    fn show_session(&mut self, subject_id: &str, flow: crate::launch::Flow, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if let Some(index) = self.session_for(subject_id, flow, cx) {
            self.drawers.clear();
            self.activate(index, window, cx);
            return true;
        }
        if let Some(launch) = Self::saved_launch(subject_id, flow) {
            self.drawers.clear();
            let folder = launch.harness_path.clone();
            self.open_session(Kind::Claude, folder, Some(launch), window, cx);
            return true;
        }
        false
    }

    /// Prepares a launch's files and opens it.
    fn start_launch(&mut self, launch: crate::launch::Launch, brief: &str, prompt: &str, disallow_edits: bool, window: &mut Window, cx: &mut Context<Self>) {
        if let Err(error) = launch.prepare(brief, prompt, disallow_edits) {
            let _ = window.prompt(gpui::PromptLevel::Critical, "Couldn't start the session", Some(&error.to_string()), &["OK"], cx);
            return;
        }
        self.drawers.clear();
        let folder = launch.harness_path.clone();
        self.open_session(Kind::Claude, folder, Some(launch), window, cx);
    }

    fn no_harness(window: &mut Window, cx: &mut App) {
        let _ = window.prompt(
            gpui::PromptLevel::Info,
            "No harness for this org",
            Some("Sessions run in the org's harness. Pick or create it in Gannin's org Settings, under Harness."),
            &["OK"],
            cx,
        );
    }

    /// Work on This: Claude Code on the issue in the harness, with Gannin's
    /// brief and opening prompt; or the session it already has.
    fn work_on(&mut self, issue: IssueItem, window: &mut Window, cx: &mut Context<Self>) {
        use crate::launch::{self, Flow, Launch, Subject};
        if self.show_session(&issue.id, Flow::Work, window, cx) {
            return;
        }
        let (Some(org), Some(harness)) = (self.org.clone(), self.harness_for(&issue.repo)) else {
            return Self::no_harness(window, cx);
        };
        let branch = launch::issue_branch(issue.number, &issue.title);
        let reference = format!("{}#{}", issue.repo, issue.number);
        let subject = Subject { id: issue.id.clone(), repo: issue.repo.clone(), number: issue.number, title: issue.title.clone(), url: issue.url.clone() };
        let launch = Launch::new(Flow::Work, format!("#{} {}", issue.number, issue.title), &org, &harness, branch.clone(), Some(subject));
        let text = detail::load_text(&issue.id);
        let parent = issue.parent_id.as_deref().and_then(|id| self.issues.read(cx).issue(id));
        let brief = work_brief(&issue, text.as_ref(), parent.as_ref(), &launch);
        let prompt = launch::opening_prompt(&reference, &issue.title, &branch);
        self.start_launch(launch, &brief, &prompt, false, window, cx);
    }

    /// Review with Claude: a session in the harness with edits disallowed,
    /// Gannin's review prompt, and its findings beside the terminal.
    fn review_pr(&mut self, pr: PrItem, window: &mut Window, cx: &mut Context<Self>) {
        use crate::launch::{self, Flow, Launch, Subject};
        if self.show_session(&pr.id, Flow::Review, window, cx) {
            return;
        }
        let (Some(org), Some(harness)) = (self.org.clone(), self.harness_for(&pr.repo)) else {
            return Self::no_harness(window, cx);
        };
        let branch = format!("review-{}-{}", pr.repo_name, pr.number);
        let subject = Subject { id: pr.id.clone(), repo: pr.repo.clone(), number: pr.number, title: pr.title.clone(), url: pr.url.clone() };
        let launch = Launch::new(Flow::Review, format!("Review {}#{}", pr.repo_name, pr.number), &org, &harness, branch.clone(), Some(subject));
        let brief = format!("# Review of {}#{}: {}\n\n{}\n", pr.repo, pr.number, pr.title, pr.url);
        let prompt = launch::review_prompt(&pr.repo, pr.number, &pr.title, &pr.url, &branch);
        self.start_launch(launch, &brief, &prompt, true, window, cx);
    }

    /// Review with Claude for several PRs picked together: each in a tab of
    /// its own (or the review it has), after asking, since each runs claude.
    fn review_many(&mut self, prs: Vec<PrItem>, window: &mut Window, cx: &mut Context<Self>) {
        if prs.len() == 1 {
            return self.review_pr(prs[0].clone(), window, cx);
        }
        let list: Vec<String> = prs.iter().map(|p| format!("{}#{} {}", p.repo_name, p.number, p.title)).collect();
        let detail = format!("{}\n\nEach runs Claude Code in a tab of its own. A PR with a review already open shows that one.", list.join("\n"));
        let answer = window.prompt(gpui::PromptLevel::Info, &format!("Start {} reviews?", prs.len()), Some(&detail), &["Start Reviews", "Cancel"], cx);
        cx.spawn_in(window, async move |this, cx| {
            if answer.await == Ok(0) {
                this.update_in(cx, |this, window, cx| {
                    for pr in prs {
                        this.review_pr(pr, window, cx);
                    }
                })
                .ok();
            }
        })
        .detach();
    }

    /// New Plan, New Ask or New Quick Change; a plan can be for an issue.
    fn open_form(&mut self, flow: crate::launch::Flow, issue: Option<IssueItem>, window: &mut Window, cx: &mut Context<Self>) {
        use crate::launch_form::{FormEvent, LaunchForm};
        if self.projects.is_empty() {
            return Self::no_harness(window, cx);
        }
        let projects = self.projects.clone();
        let form = cx.new(|cx| LaunchForm::new(flow, projects, issue, window, cx));
        let subscription = cx.subscribe_in(&form, window, |this, _, event: &FormEvent, window, cx| {
            this.launch_form = None;
            if let FormEvent::Start(started) = event {
                this.start_from_form(started, window, cx);
            } else {
                this.focus_current(window, cx);
            }
            cx.notify();
        });
        self.launch_form = Some((form, subscription));
        cx.notify();
    }

    /// Review a Pull Request: pick one of the org's open PRs to review.
    fn open_pr_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        use crate::pr_picker::{PickerEvent, PrPicker};
        let Some(org) = self.org.clone() else { return };
        let me = self.viewer.as_ref().map(|v| v.login.clone());
        let picker = cx.new(|cx| PrPicker::new(org, me, window, cx));
        let subscription = cx.subscribe_in(&picker, window, |this, _, event: &PickerEvent, window, cx| {
            this.pr_picker = None;
            match event {
                PickerEvent::Pick(pr) => this.review_pr(pr.clone(), window, cx),
                PickerEvent::Cancel => this.focus_current(window, cx),
            }
            cx.notify();
        });
        self.pr_picker = Some((picker, subscription));
        cx.notify();
    }

    fn start_from_form(&mut self, started: &crate::launch_form::Started, window: &mut Window, cx: &mut Context<Self>) {
        use crate::launch::{self, Flow, Launch, Subject};
        let Some(org) = self.org.clone() else { return };
        let harness = started.harness.clone();
        match started.flow {
            Flow::Plan => {
                let topic = started.text.clone();
                let slug = launch::slug(&topic, 40);
                let branch = format!("plan-{}", if slug.is_empty() { "plan" } else { slug.as_str() });
                let subject = started.issue.as_ref().map(|i| Subject { id: i.id.clone(), repo: i.repo.clone(), number: i.number, title: i.title.clone(), url: i.url.clone() });
                let launch = Launch::new(Flow::Plan, format!("Plan: {}", launch::short_title(&topic)), &org, &harness, branch.clone(), subject);
                let mut brief = format!("# Planning: {topic}\n\n");
                let reference = started.issue.as_ref().map(|i| (format!("{}#{}", i.repo, i.number), i.number, i.repo.clone()));
                if let Some(issue) = &started.issue {
                    brief.push_str(&format!("Planning {}#{}: {}\n", issue.repo, issue.number, issue.title));
                }
                let mut prompt = launch::planning_prompt(&topic, &branch, reference.as_ref().map(|(r, n, repo)| (r.as_str(), *n, repo.as_str())));
                if !started.extra.is_empty() {
                    prompt.push_str("\n\n");
                    prompt.push_str(&started.extra);
                }
                self.start_launch(launch, &brief, &prompt, false, window, cx);
            }
            Flow::Ask => {
                let title = launch::short_title(&started.text);
                let mut launch = Launch::new(Flow::Ask, format!("Ask: {title}"), &org, &harness, String::new(), None);
                launch.branch = format!("ask-{}-{}", chrono::Local::now().format("%Y-%m-%d"), launch.id[..8].to_lowercase());
                let brief = launch::ask_brief(&title, &harness, &launch.harness_path, &launch.branch);
                let prompt = launch::ask_prompt(&started.text, &launch.branch);
                // What Gannin puts in context/: here, only what it holds.
                let context = launch.dir().join("context");
                let _ = std::fs::create_dir_all(&context);
                let _ = std::fs::write(
                    context.join("README.md"),
                    format!("# {org}, as the Gannin pilot sees it\n\nThe pilot doesn't write Gannin's org view here yet: use `gh` and the code for what the question needs.\n\nWritten {}.\n", chrono::Utc::now().to_rfc3339()),
                );
                self.start_launch(launch, &brief, &prompt, false, window, cx);
            }
            Flow::QuickChange => {
                let Some(repo) = started.repo.clone() else { return };
                let title = if started.extra.is_empty() { launch::short_title(&started.text) } else { started.extra.clone() };
                let mut launch = Launch::new(Flow::QuickChange, format!("Quick change: {title}"), &org, &harness, String::new(), None);
                let hex = launch.id[..4].to_lowercase();
                let slug = launch::slug(&title, 32);
                launch.branch = if slug.is_empty() { format!("quick-{hex}") } else { format!("quick-{slug}-{hex}") };
                let brief = format!(
                    "# Quick change in {repo}: {title}\n\n## A quick change\n\nStarted from a quick note in Gannin rather than a written-up issue, and there's no issue for it. It's meant to be small: a snag, a tweak or a one-line fix in {repo}. It needs no plan document. If it turns out bigger than that (more than one repo, a design decision to make, or more than a short piece of work), stop and say so before going further, so it can be written up as an issue.\n\n## The note\n\n{}\n\n{}",
                    started.text,
                    launch::working_here(&harness, &launch.harness_path, &launch.branch, None, &repo, true)
                );
                let prompt = launch::quick_change_prompt(&repo, &title, &launch.branch, false);
                self.start_launch(launch, &brief, &prompt, false, window, cx);
            }
            _ => {}
        }
    }

    /// Plan This: the New Plan form for the issue; or its planning session.
    fn plan_issue(&mut self, issue: IssueItem, window: &mut Window, cx: &mut Context<Self>) {
        if self.show_session(&issue.id, crate::launch::Flow::Plan, window, cx) {
            return;
        }
        self.open_form(crate::launch::Flow::Plan, Some(issue), window, cx);
    }

    /// Explain: Claude explains the PR in plain terms, as an Ask session
    /// about it, so the conversation can carry on.
    fn explain_pr(&mut self, pr: PrItem, window: &mut Window, cx: &mut Context<Self>) {
        let subject = crate::launch::Subject { id: pr.id.clone(), repo: pr.repo.clone(), number: pr.number, title: pr.title.clone(), url: pr.url.clone() };
        self.open_explain(subject, Vec::new(), window, cx);
    }

    /// Explain, as Gannin's: a conversation with claude about the PR in a
    /// sheet, without a terminal.
    fn open_explain(&mut self, subject: crate::launch::Subject, walkthrough: Vec<crate::review::Area>, window: &mut Window, cx: &mut Context<Self>) {
        let sheet = cx.new(|cx| crate::explain::ExplainSheet::new(subject, walkthrough, window, cx));
        let subscription = cx.subscribe_in(&sheet, window, |this, _, _: &crate::explain::CloseExplain, window, cx| {
            this.explain = None;
            this.focus_current(window, cx);
            cx.notify();
        });
        self.explain = Some((sheet, subscription));
        cx.notify();
    }

    /// The org's PR cache, read off the main thread.
    fn load_work(&mut self, org: String, cx: &mut Context<Self>) {
        self.sync.work_at = Some(std::time::Instant::now());
        cx.spawn(async move |this, cx| {
            let loaded = org.clone();
            let login = this.update(cx, |this, _| this.viewer.as_ref().map(|v| v.login.clone())).ok().flatten();
            // Live when signed in, else (or when GitHub can't answer) the cache.
            let work = cx
                .background_executor()
                .spawn(async move {
                    let live = login.is_some().then(auth::token).flatten().and_then(|token| work::load_live(&token, login.clone()).ok());
                    live.unwrap_or_else(|| work::load(&loaded, login))
                })
                .await;
            this.update(cx, |this, cx| {
                if this.org.as_deref() == Some(org.as_str()) {
                    this.work = work;
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    // MARK: Sync

    /// Checks once a minute whether the org is due a sync: signed in, five
    /// minutes since the last, and GitHub's budget not low or refused.
    fn start_sync_loop(&mut self, cx: &mut Context<Self>) {
        self._sync_loop = Some(cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(std::time::Duration::from_secs(60)).await;
            let Ok(()) = this.update(cx, |this, cx| {
                let every = chrono::Duration::minutes(this.sync.prefs.workload_minutes.max(1) as i64);
                let due = this.org.as_deref().is_some_and(|org| crate::sync::last_synced(org).is_none_or(|at| chrono::Utc::now() - at >= every));
                if due && !crate::github::should_hold_off() {
                    this.sync_now(None, false, cx);
                }
                // Your Work's live query, on its own interval.
                let work = this.sync.prefs.work_minutes;
                let work_due = work > 0 && this.sync.work_at.is_none_or(|at| at.elapsed() >= std::time::Duration::from_secs(work as u64 * 60));
                if work_due && this.viewer.is_some() && !crate::github::should_hold_off() {
                    if let Some(org) = this.org.clone() {
                        this.load_work(org, cx);
                    }
                }
            }) else {
                return;
            };
        }));
    }

    /// Syncs an org (the current one by default) now, then has its pages
    /// read their caches again. `full` searches everything, not only what
    /// changed, as Gannin's Full Refresh.
    fn sync_now(&mut self, org: Option<String>, full: bool, cx: &mut Context<Self>) {
        if self.sync.running || self.viewer.is_none() {
            return;
        }
        let Some(org) = org.or_else(|| self.org.clone()) else { return };
        let viewer = self.viewer.as_ref().map(|v| v.login.clone());
        self.sync.running = true;
        self.sync.error = None;
        self.sync.org = Some(org.clone());
        self.sync.progress = Default::default();
        let progress = self.sync.progress.clone();
        let options = crate::sync::Options {
            lookback_days: self.sync.prefs.lookback_days.unwrap_or_else(crate::sync::gannin_lookback_days),
            full_every: chrono::Duration::hours(self.sync.prefs.full_hours.max(1) as i64),
        };
        cx.notify();
        // The popover's steps tick off as they finish.
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(std::time::Duration::from_millis(250)).await;
            let Ok(running) = this.update(cx, |this, cx| {
                cx.notify();
                this.sync.running
            }) else {
                return;
            };
            if !running {
                return;
            }
        })
        .detach();
        cx.spawn(async move |this, cx| {
            let synced_org = org.clone();
            let started = std::time::Instant::now();
            let result = cx
                .background_executor()
                .spawn(async move {
                    let token = auth::token().ok_or(crate::github::Error::Unauthorised)?;
                    crate::sync::sync_org(&token, &synced_org, viewer.as_deref(), full, options, &progress)
                })
                .await;
            this.update(cx, |this, cx| {
                this.sync.running = false;
                let result = result.map_err(|e| e.to_string());
                match &result {
                    Ok(_) if this.org.as_deref() == Some(org.as_str()) => this.refresh_pages(cx),
                    Ok(_) => {}
                    Err(error) => this.sync.error = Some(error.clone()),
                }
                this.sync.runs.insert(0, SyncRun { org: org.clone(), at: chrono::Utc::now(), took: started.elapsed(), result });
                this.sync.runs.truncate(6);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// After a sync: every page re-reads the pilot's caches.
    fn refresh_pages(&mut self, cx: &mut Context<Self>) {
        if self.harness_open {
            self.load_harness_counts(cx);
        }
        self.issues.update(cx, |page, cx| page.reload(cx));
        for page in self.pages() {
            match page {
                Page::Issues(page) => page.update(cx, |page, cx| page.reload(cx)),
                Page::Prs(page) => page.update(cx, |page, cx| page.reload(cx)),
                Page::Scorecard(page) => page.update(cx, |page, cx| page.reload(cx)),
                Page::Activity(page) => page.update(cx, |page, cx| page.reload(cx)),
                Page::Harness(page) => page.update(cx, |page, cx| page.reload(cx)),
                _ => {}
            }
        }
        if let Some(org) = self.org.clone() {
            self.load_work(org, cx);
        }
    }

    /// "Synced 3m ago", "Syncing", or why it isn't; a click opens the sync
    /// popover.
    fn sync_button(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let last = self.org.as_deref().and_then(crate::sync::last_synced);
        let label: String = if self.sync.running {
            let steps = self.sync.progress.lock().map(|s| (s.iter().filter(|s| s.done).count(), s.len())).unwrap_or_default();
            if steps.1 > 0 { format!("Syncing {} of {}", steps.0, steps.1) } else { "Syncing".into() }
        } else if let Some(until) = crate::github::paused_until() {
            format!("Paused to {}", until.with_timezone(&Local).format("%H:%M"))
        } else if self.sync.error.is_some() {
            "Sync failed".into()
        } else if let Some(at) = last {
            format!("Synced {}", crate::format::table_date(at))
        } else {
            "Sync".into()
        };
        let open = self.sync.open;
        // While it runs, a thin bar beneath the label fills as it goes.
        let fraction = self.sync_fraction();
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("sync")
                    .px_2()
                    .py_0p5()
                    .mr_2()
                    .rounded_md()
                    .text_xs()
                    .cursor_pointer()
                    .text_color(if self.sync.error.is_some() { theme.critical() } else { theme.secondary })
                    .when(open, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        cx.stop_propagation();
                        // A second click closes the panel it opened.
                        if this.sync.open {
                            this.sync.open = false;
                            cx.notify();
                        } else {
                            this.refresh(cx);
                        }
                    }))
                    .child(label)
                    .when_some(fraction.filter(|_| self.sync.running), |d, f| {
                        d.child(div().mt_0p5().h(px(2.)).w_full().rounded_full().bg(theme.tile).child(div().h_full().w(relative(f)).rounded_full().bg(theme.selected)))
                    }),
            )
    }

    /// How far through the sync under way is, 0 to 1, by its steps.
    fn sync_fraction(&self) -> Option<f32> {
        let steps = self.sync.progress.lock().ok()?;
        (!steps.is_empty()).then(|| steps.iter().map(|s| s.fraction()).sum::<f32>() / steps.len() as f32)
    }

    /// A refresh by hand (the sync button, Command-R): syncs now and shows
    /// the Sync panel. The background syncs leave it as it is.
    fn refresh(&mut self, cx: &mut Context<Self>) {
        self.sync.open = true;
        self.sync_now(None, false, cx);
        cx.notify();
    }

    /// The Sync panel on the right, after Gannin's sync panel: the budget,
    /// the steps of the sync under way (or the last), each org and when it
    /// last synced, Refresh and Full Refresh, and the last few syncs.
    fn sync_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .w(px(320.))
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
                    .child(div().flex_1().text_color(theme.secondary).child("Sync"))
                    .child(
                        div()
                            .id("close-sync")
                            .px_1()
                            .rounded_sm()
                            .cursor_pointer()
                            .text_color(theme.tertiary)
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.sync.open = false;
                                cx.notify();
                            }))
                            .child("×"),
                    ),
            )
            .child(div().id("sync-body").flex_1().min_h_0().overflow_y_scroll().child(self.sync_body(theme, cx)))
    }

    /// Settings, as Gannin's Settings › Sync for what the pilot fetches.
    fn sync_settings(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let prefs = &self.sync.prefs;
        let quiet = |text: &str| div().text_xs().text_color(theme.secondary).child(text.to_string());
        let title = |text: &str| div().text_xs().font_weight(FontWeight::MEDIUM).child(text.to_string());
        let chip = |id: SharedString, label: String, on: bool| {
            div()
                .id(id)
                .px_1p5()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.row_selected))
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
        };
        let minutes = |m: u32| if m >= 60 { format!("{}h", m / 60) } else { format!("{m}m") };
        let hours = |h: u32| if h >= 24 { format!("{}d", h / 24) } else { format!("{h}h") };
        let row = |children: Vec<gpui::AnyElement>| div().p_0p5().flex().flex_row().flex_wrap().gap_0p5().rounded_md().bg(theme.tile).children(children);
        let workload: Vec<gpui::AnyElement> = [2u32, 5, 10, 15, 30, 60]
            .into_iter()
            .map(|m| {
                chip(SharedString::from(format!("workload-{m}")), minutes(m), prefs.workload_minutes == m)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.sync.prefs.workload_minutes = m;
                        this.persist(cx);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let full: Vec<gpui::AnyElement> = [6u32, 12, 24, 72, 168]
            .into_iter()
            .map(|h| {
                chip(SharedString::from(format!("full-{h}")), hours(h), prefs.full_hours == h)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.sync.prefs.full_hours = h;
                        this.persist(cx);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let work: Vec<gpui::AnyElement> = [0u32, 1, 2, 5, 10, 15, 30, 60]
            .into_iter()
            .map(|m| {
                chip(SharedString::from(format!("work-{m}")), if m == 0 { "Off".into() } else { minutes(m) }, prefs.work_minutes == m)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.sync.prefs.work_minutes = m;
                        this.persist(cx);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let reserve: Vec<gpui::AnyElement> = [250i64, 500, 1000, 1500, 2500]
            .into_iter()
            .map(|points| {
                chip(SharedString::from(format!("reserve-{points}")), format!("{points}"), prefs.reserve == points)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.sync.prefs.reserve = points;
                        crate::github::set_reserve(points);
                        this.persist(cx);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let lookback = prefs.lookback_days.unwrap_or_else(crate::sync::gannin_lookback_days);
        let step = |id: &'static str, label: &'static str, by: i64| {
            chip(id.into(), label.into(), false).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                let now = this.sync.prefs.lookback_days.unwrap_or_else(crate::sync::gannin_lookback_days);
                this.sync.prefs.lookback_days = Some((now + by).clamp(1, 90));
                this.persist(cx);
                cx.notify();
            }))
        };
        // Each setting a group of its own, with a divider between them.
        let divider = || div().my_1().h(px(1.)).bg(theme.border);
        let group = || div().flex().flex_col().gap_1();
        div()
            .flex()
            .flex_col()
            .gap_1p5()
            .pt_2()
            .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.tertiary).child("Settings"))
            .child(group().child(title("Open PRs and issues, every")).child(row(workload)).child(quiet("What changed since the last fetch, and PRs merged in the lookback.")))
            .child(divider())
            .child(group().child(title("Everything searched again, every")).child(row(full)))
            .child(divider())
            .child(group().child(title("Your reviews and PRs, every")).child(row(work)).child(quiet("PRs your review is asked on, your own PRs and your issues, for Your Work.")))
            .child(divider())
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(title(&format!("Merged work from the last {lookback} days")))
                    .child(div().flex_1())
                    .child(row(vec![step("lookback-less", "−", -1).into_any_element(), step("lookback-more", "+", 1).into_any_element()])),
            )
            .child(quiet("The lookback applies on the next refresh, which searches everything again."))
            .child(divider())
            .child(title("Keep in reserve (points)"))
            .child(row(reserve))
            .child(quiet("Automatic fetches wait for the reset once fewer are left, so what you open or Refresh still has budget."))
    }

    fn sync_body(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let now = chrono::Utc::now();
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let heading = |text: &str| div().pt_2().pb_0p5().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.tertiary).child(text.to_string());
        let link = |id: SharedString, label: &str, enabled: bool| {
            div()
                .id(id)
                .text_xs()
                .text_color(if enabled { theme.selected } else { theme.tertiary })
                .when(enabled, |d| d.cursor_pointer())
                .child(label.to_string())
        };
        // GitHub's hourly budget: share left and the time to its reset.
        let budget = match (crate::github::rate_limit(), crate::github::paused_until()) {
            (_, Some(until)) => div().text_color(theme.critical()).text_xs().child(format!(
                "GitHub's rate limit is spent: syncing waits until {}",
                until.with_timezone(&Local).format("%H:%M")
            )),
            (Some(rate), None) => {
                let share = rate.remaining as f32 / rate.limit.max(1) as f32;
                let minutes = (rate.reset_at - now).num_minutes().max(0);
                let tint = if rate.is_low() { theme.critical() } else { theme.good() };
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .justify_between()
                            .child(quiet(format!("{:.0}% of GitHub's hourly budget left", share * 100.)))
                            .child(quiet(if minutes < 1 { "<1m to reset".into() } else { format!("{minutes}m to reset") })),
                    )
                    .child(div().h(px(4.)).w_full().rounded_full().bg(theme.tile).child(div().h_full().w(relative(share)).rounded_full().bg(tint)))
                    .child(quiet(format!("{} of {} points; automatic syncs hold off under {}", rate.remaining, rate.limit, crate::github::reserve())))
            }
            _ => quiet("GitHub's budget shows after the first sync.".into()),
        };
        let steps = self.sync.progress.lock().map(|s| s.clone()).unwrap_or_default();
        let current = self.sync.org.clone().or_else(|| self.org.clone()).unwrap_or_default();
        let run = div()
            .flex()
            .flex_col()
            .gap_0p5()
            .child(heading(&if self.sync.running { format!("Syncing {current}") } else if steps.is_empty() { "Last sync".into() } else { format!("Last sync of {current}") }))
            .map(|d| {
                if steps.is_empty() {
                    d.child(quiet("Nothing synced yet this session.".into()))
                } else {
                    let running = self.sync.running;
                    let overall = self.sync_fraction().unwrap_or(0.);
                    d.when(running, |d| {
                        d.child(div().my_1().h(px(4.)).w_full().rounded_full().bg(theme.tile).child(div().h_full().w(relative(overall)).rounded_full().bg(theme.selected)))
                    })
                    .children(steps.into_iter().map(|step| {
                        let fraction = step.fraction();
                        let tally = match (step.done, step.count, step.total) {
                            (true, Some(n), _) => n.to_string(),
                            (false, _, Some(total)) => format!("{} of {total}", step.fetched),
                            _ => String::new(),
                        };
                        div()
                            .flex()
                            .flex_col()
                            .gap_0p5()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .child(div().w(px(14.)).text_color(if step.done { theme.good() } else { theme.tertiary }).child(if step.done { "✓" } else { "•" }))
                                    .child(div().flex_1().text_xs().child(step.title))
                                    .child(quiet(tally)),
                            )
                            .when(running && !step.done && step.total.is_some(), |d| {
                                d.child(div().ml(px(22.)).h(px(3.)).rounded_full().bg(theme.tile).child(div().h_full().w(relative(fraction)).rounded_full().bg(theme.blue())))
                            })
                    }))
                }
            })
            .when_some(self.sync.error.clone(), |d, e| d.child(div().text_xs().text_color(theme.critical()).child(e)));
        let can_sync = !self.sync.running && self.viewer.is_some();
        let orgs = div().flex().flex_col().gap_0p5().child(heading("Orgs")).children(self.orgs.iter().enumerate().map(|(i, org)| {
            let last = crate::sync::last_synced(org);
            let synced = org.clone();
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .child(div().flex_1().text_xs().when(self.org.as_deref() == Some(org.as_str()), |d| d.font_weight(FontWeight::SEMIBOLD)).child(org.clone()))
                .child(quiet(last.map(|at| format!("synced {}", crate::format::table_date(at))).unwrap_or_else(|| "not yet".into())))
                .child(link(SharedString::from(format!("sync-org-{i}")), "Sync", can_sync).when(can_sync, |d| {
                    d.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.sync_now(Some(synced.clone()), false, cx)))
                }))
        }));
        let log = (!self.sync.runs.is_empty()).then(|| {
            div().flex().flex_col().gap_0p5().child(heading("Recent")).children(self.sync.runs.iter().map(|run| {
                let what = match &run.result {
                    Ok(report) => format!(
                        "{} · {} PRs, {} issues",
                        if report.full { "full" } else { "changes" },
                        report.pull_requests,
                        report.issues
                    ),
                    Err(error) => error.clone(),
                };
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .text_xs()
                    .child(div().w(px(44.)).flex_none().text_color(theme.secondary).child(run.at.with_timezone(&Local).format("%H:%M").to_string()))
                    .child(div().flex_1().truncate().text_color(if run.result.is_err() { theme.critical() } else { theme.fg }).child(format!("{} · {what}", run.org)))
                    .child(div().text_color(theme.tertiary).child(format!("{:.1}s", run.took.as_secs_f32())))
            }))
        });
        div()
            .p_3()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .child(div().flex_1().font_weight(FontWeight::SEMIBOLD).child("Sync"))
                    .child(link("sync-refresh".into(), "Refresh", can_sync).when(can_sync, |d| {
                        d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.sync_now(None, false, cx)))
                    }))
                    .child(link("sync-full".into(), "Full Refresh", can_sync).when(can_sync, |d| {
                        d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.sync_now(None, true, cx)))
                    })),
            )
            .child(budget)
            .child(run)
            .child(orgs)
            .children(log)
            .child(self.sync_settings(theme, cx))
            .child(quiet(
                "Synced into the pilot's own copy. Metrics, work logs and CI runs are read from Gannin's caches."
                    .into(),
            ))
    }

    // MARK: Account

    /// Who was signed in, from the pilot's own file and keychain item, then
    /// checked with GitHub (a rejected token signs out).
    fn load_viewer(&mut self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            let saved = cx.background_executor().spawn(async { auth::saved_viewer() }).await;
            let had = saved.is_some();
            this.update(cx, |this, cx| this.set_viewer(saved, cx)).ok();
            if had {
                if let Some(checked) = cx.background_executor().spawn(async { auth::validate() }).await {
                    this.update(cx, |this, cx| this.set_viewer(checked, cx)).ok();
                }
            }
        })
        .detach();
    }

    fn set_viewer(&mut self, viewer: Option<Viewer>, cx: &mut Context<Self>) {
        if self.viewer != viewer {
            self.viewer = viewer;
            let me = self.viewer.as_ref().map(|v| v.login.clone());
            for page in self.pages() {
                if let Page::Prs(page) = page {
                    page.update(cx, |page, cx| page.set_me(me.clone(), cx));
                }
            }
            // Your Work is read as whoever is signed in.
            if let Some(org) = self.org.clone() {
                self.load_work(org, cx);
            }
            cx.notify();
        }
    }

    /// GitHub's device flow: a code to enter on github.com, then a poll
    /// until it's authorised, as Gannin's sign-in.
    fn start_sign_in(&mut self, cx: &mut Context<Self>) {
        self.account_open = false;
        self.sign_in = Some(SignIn::Requesting);
        self.sign_in_task = Some(cx.spawn(async move |this, cx| {
            let fail = |message: String, this: &gpui::WeakEntity<Self>, cx: &mut gpui::AsyncApp| {
                this.update(cx, |this, cx| {
                    this.sign_in = Some(SignIn::Failed(message));
                    cx.notify();
                })
                .ok();
            };
            let code = match cx.background_executor().spawn(async { auth::request_code() }).await {
                Ok(code) => code,
                Err(message) => return fail(message, &this, cx),
            };
            let deadline = std::time::Instant::now() + code.expires_in();
            let mut interval = code.interval();
            let polled = code.clone();
            if this
                .update(cx, |this, cx| {
                    this.sign_in = Some(SignIn::Code { code, copied: false });
                    cx.notify();
                })
                .is_err()
            {
                return;
            }
            let token = loop {
                cx.background_executor().timer(interval).await;
                if std::time::Instant::now() > deadline {
                    return fail("The code expired before you authorised. Try again.".into(), &this, cx);
                }
                let code = polled.clone();
                match cx.background_executor().spawn(async move { auth::poll(&code, interval) }).await {
                    Poll::Token(token) => break token,
                    Poll::Wait(next) => interval = next,
                    Poll::Failed(message) => return fail(message, &this, cx),
                }
            };
            this.update(cx, |this, cx| {
                this.sign_in = Some(SignIn::Finishing);
                cx.notify();
            })
            .ok();
            match cx.background_executor().spawn(async move { auth::complete(&token) }).await {
                Ok(viewer) => {
                    this.update(cx, |this, cx| {
                        this.sign_in = None;
                        this.set_viewer(Some(viewer), cx);
                    })
                    .ok();
                }
                Err(message) => fail(message, &this, cx),
            }
        }));
        cx.notify();
    }

    fn cancel_sign_in(&mut self, cx: &mut Context<Self>) {
        self.sign_in = None;
        self.sign_in_task = None;
        cx.notify();
    }

    fn sign_out(&mut self, cx: &mut Context<Self>) {
        self.account_open = false;
        cx.background_executor().spawn(async { auth::sign_out() }).detach();
        self.set_viewer(None, cx);
    }

    /// At the right of the title bar, as Zed's: the avatar with a menu when
    /// signed in, else Sign In.
    fn account(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let Some(viewer) = self.viewer.clone() else {
            return div()
                .id("sign-in")
                .px_2()
                .py_0p5()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    this.start_sign_in(cx);
                }))
                .child("Sign In")
                .into_any_element();
        };
        let open = self.account_open;
        let item = |id: &'static str, label: &'static str| {
            div().id(id).mx_1().px_2().py_1().rounded_md().cursor_pointer().hover(|s| s.bg(theme.row_selected)).child(label)
        };
        let profile = format!("https://github.com/{}", viewer.login);
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("account")
                    .p_0p5()
                    .rounded_full()
                    .cursor_pointer()
                    .when(open, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        cx.stop_propagation();
                        this.account_open = !this.account_open;
                        cx.notify();
                    }))
                    .child(avatar(&viewer.login, viewer.avatar_url.as_deref(), 22., theme, cx)),
            )
            .when(open, |d| {
                d.child(
                    deferred(
                        anchored().anchor(gpui::Anchor::TopRight).snap_to_window_with_margin(px(8.)).child(
                            div()
                                .id("account-menu")
                                .occlude()
                                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                                .mt_1()
                                .w(px(240.))
                                .py_1()
                                .flex()
                                .flex_col()
                                .bg(theme.popover)
                                .border_1()
                                .border_color(theme.border)
                                .rounded_lg()
                                .shadow_lg()
                                .child(
                                    div()
                                        .px_3()
                                        .py_1p5()
                                        .flex()
                                        .flex_col()
                                        .when_some(viewer.name.clone(), |d, name| d.child(div().font_weight(FontWeight::MEDIUM).child(name)))
                                        .child(div().text_xs().text_color(theme.secondary).child(format!("{} on GitHub", viewer.login))),
                                )
                                .child(div().my_1().h(px(1.)).bg(theme.border))
                                .child(item("account-profile", "Open Profile on GitHub").on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    this.account_open = false;
                                    cx.open_url(&profile);
                                    cx.notify();
                                })))
                                .child(item("account-sign-out", "Sign Out").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.sign_out(cx)))),
                        ),
                    )
                    .with_priority(2),
                )
            })
            .into_any_element()
    }

    /// The device flow's sheet, over the window.
    fn sign_in_sheet(&self, step: &SignIn, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let button = |id: &'static str, label: &'static str, prominent: bool| {
            div()
                .id(id)
                .px_3()
                .py_1()
                .rounded_md()
                .cursor_pointer()
                .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
                .hover(|s| s.opacity(0.85))
                .child(label)
        };
        let cancel = button("sign-in-cancel", "Cancel", false).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.cancel_sign_in(cx)));
        let body = match step {
            SignIn::Requesting => div().text_color(theme.secondary).child("Asking GitHub for a code").into_any_element(),
            SignIn::Finishing => div().text_color(theme.secondary).child("Signing in").into_any_element(),
            SignIn::Failed(message) => div()
                .flex()
                .flex_col()
                .gap_3()
                .child(div().text_color(gpui::rgb(0xFF453A)).child(message.clone()))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .gap_2()
                        .child(button("sign-in-retry", "Try Again", true).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.start_sign_in(cx))))
                        .child(cancel),
                )
                .into_any_element(),
            SignIn::Code { code, copied } => {
                let user_code = code.user_code.clone();
                let uri = code.verification_uri.clone();
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(div().text_color(theme.secondary).child("Enter this code on GitHub:"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(
                                div()
                                    .px_4()
                                    .py_2()
                                    .rounded_lg()
                                    .bg(theme.tile)
                                    .font_family("Menlo")
                                    .text_size(px(28.))
                                    .font_weight(FontWeight::BOLD)
                                    .child(user_code.clone()),
                            )
                            .child(
                                button("sign-in-copy", if *copied { "Copied" } else { "Copy" }, false).on_click(cx.listener(
                                    move |this, _: &ClickEvent, _, cx| {
                                        cx.write_to_clipboard(gpui::ClipboardItem::new_string(user_code.clone()));
                                        if let Some(SignIn::Code { copied, .. }) = this.sign_in.as_mut() {
                                            *copied = true;
                                        }
                                        cx.notify();
                                    },
                                )),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .child(button("sign-in-open", "Open GitHub", true).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&uri))))
                            .child(cancel),
                    )
                    .child(div().text_xs().text_color(theme.secondary).child("Waiting for you to authorise"))
                    .into_any_element()
            }
        };
        div()
            .id("sign-in-scrim")
            .absolute()
            .top_0()
            .left_0()
            .right_0()
            .bottom_0()
            .occlude()
            .bg(gpui::black().opacity(0.35))
            .flex()
            .items_center()
            .justify_center()
            .child(
                div()
                    .id("sign-in-sheet")
                    .w(px(420.))
                    .p_5()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .rounded_xl()
                    .shadow_lg()
                    .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Sign in with GitHub"))
                    .child(
                        div()
                            .text_xs()
                            .text_color(theme.secondary)
                            .child("The pilot keeps its own sign-in: signing out here leaves Gannin signed in."),
                    )
                    .child(body),
            )
    }

    /// Sessions whose process is still running.
    fn running(&self, cx: &App) -> Vec<Entity<SessionPage>> {
        self.sessions.iter().filter(|s| s.read(cx).state != State::Ended).cloned().collect()
    }

    /// What ending a session leaves behind, for the confirmations.
    fn ending_detail(pages: &[Entity<SessionPage>], cx: &App) -> String {
        let mut lines: Vec<String> = pages
            .iter()
            .map(|page| {
                let page = page.read(cx);
                format!("{} ({}) in {}", page.title(cx), page.state.label(), page.folder(cx).display())
            })
            .collect();
        let claude = pages.iter().any(|p| p.read(cx).kind == Kind::Claude);
        lines.push(String::new());
        lines.push("Its process ends. Files it changed and commits it made stay where they are.".into());
        if claude {
            lines.push("To pick a Claude Code session up again, run claude --continue in its folder.".into());
        }
        lines.join("\n")
    }

    /// Closing the last tab leaves an empty pane, as Zed's does; the window
    /// stays open. A session still running asks first, as ending the tab
    /// ends its process.
    fn close_tab(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(nav) = self.tabs.get(index).map(|tab| tab.nav) else { return };
        if let Nav::Session(id) = nav {
            if let Some(review) = self.session(id, cx).and_then(|p| p.read(cx).review()) {
                return self.close_review(id, review, window, cx);
            }
        }
        if let Nav::Session(id) = nav {
            if let Some(page) = self.session(id, cx).filter(|p| p.read(cx).state != State::Ended).cloned() {
                let title = page.read(cx).title(cx);
                let detail = Self::ending_detail(&[page], cx);
                let answer = window.prompt(
                    gpui::PromptLevel::Warning,
                    &format!("End \u{201c}{title}\u{201d}?"),
                    Some(&detail),
                    &["End Session", "Cancel"],
                    cx,
                );
                cx.spawn_in(window, async move |this, cx| {
                    if answer.await == Ok(0) {
                        this.update(cx, |this, cx| {
                            if let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(id)) {
                                this.remove_tab(index, cx);
                            }
                        })
                        .ok();
                    }
                })
                .detach();
                return;
            }
        }
        self.remove_tab(index, cx);
    }

    /// Closing a review's tab says what happens to it: one not posted
    /// offers Post Review first. Claude stops; the review, the person's
    /// dismissals and edits and the conversation stay in the session's
    /// folder, and opening the review from the PR again resumes it.
    fn close_review(&mut self, id: u32, review: Entity<crate::review_panel::ReviewPanel>, window: &mut Window, cx: &mut Context<Self>) {
        let (has_result, posted, kept) = review.read(cx).closing();
        let title = self.session(id, cx).map(|p| p.read(cx).title(cx)).unwrap_or_default();
        let after = "Claude stops. The review, your dismissals and edits stay, and opening the review from the pull request again picks it up where it was.";
        let (message, detail, buttons): (String, String, &[&str]) = if has_result && !posted {
            (
                format!("Close \u{201c}{title}\u{201d} without posting it?"),
                format!(
                    "Claude's review, with {}, hasn't been posted to GitHub.\n\n{after}",
                    match kept {
                        0 => "no findings kept".to_string(),
                        1 => "1 finding".to_string(),
                        n => format!("{n} findings"),
                    }
                ),
                &["Post Review", "Close Review", "Cancel"],
            )
        } else {
            (format!("Close \u{201c}{title}\u{201d}?"), after.to_string(), &["Close Review", "Cancel"])
        };
        let answer = window.prompt(gpui::PromptLevel::Warning, &message, Some(&detail), buttons, cx);
        let offers_post = buttons.len() == 3;
        cx.spawn_in(window, async move |this, cx| {
            let choice = answer.await.ok();
            this.update_in(cx, |this, window, cx| {
                let close = if offers_post { choice == Some(1) } else { choice == Some(0) };
                if offers_post && choice == Some(0) {
                    if let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(id)) {
                        this.activate(index, window, cx);
                    }
                    review.update(cx, |review, cx| review.start_post(window, cx));
                } else if close {
                    // The record's last update, as Gannin's Finish makes it.
                    review.update(cx, |review, cx| review.record_on_close(cx));
                    if let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(id)) {
                        this.remove_tab(index, cx);
                    }
                }
            })
            .ok();
        })
        .detach();
    }

    /// Quitting with sessions running asks first, as Gannin's quit guard does.
    pub fn quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let running = self.running(cx);
        if running.is_empty() {
            return cx.quit();
        }
        let message = match running.len() {
            1 => "Quit and end the session that's running?".to_string(),
            n => format!("Quit and end the {n} sessions that are running?"),
        };
        let detail = Self::ending_detail(&running, cx);
        let answer = window.prompt(gpui::PromptLevel::Warning, &message, Some(&detail), &["Quit", "Cancel"], cx);
        cx.spawn(async move |_, cx| {
            if answer.await == Ok(0) {
                cx.update(|cx| cx.quit());
            }
        })
        .detach();
    }

    fn remove_tab(&mut self, index: usize, cx: &mut Context<Self>) {
        if index >= self.tabs.len() {
            return;
        }
        // Dropping a session's terminal ends its process (a hangup).
        if let Nav::Session(id) = self.tabs.remove(index).nav {
            self.sessions.retain(|s| s.read(cx).id != id);
        }
        if self.active >= self.tabs.len() || self.active > index {
            self.active = self.active.saturating_sub(1);
        }
        cx.notify();
    }

    fn current(&self) -> Option<Nav> {
        self.tabs.get(self.active).map(|tab| tab.nav)
    }

    fn push_drawer(&mut self, issue: IssueItem, cx: &mut Context<Self>) {
        let store = self.issues.read(cx);
        let parent = issue.parent_id.as_deref().and_then(|id| store.issue(id));
        let sub_issues = store.sub_issues(&issue.id);
        let id = issue.id.clone();
        self.open_drawer(DrawerItem::Issue(IssueDrawer { issue, parent, sub_issues }), id, cx);
    }

    fn push_pr_drawer(&mut self, pr: PrItem, cx: &mut Context<Self>) {
        let id = pr.id.clone();
        self.open_drawer(DrawerItem::Pull(pr), id, cx);
    }

    fn open_drawer(&mut self, item: DrawerItem, id: String, cx: &mut Context<Self>) {
        self.drawer_seq += 1;
        let seq = self.drawer_seq;
        self.drawers.push(Drawer { seq, item, text: None });
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
                            .child(match &drawer.item {
                                DrawerItem::Issue(item) => self.issue_page(drawer, item, theme, cx).into_any_element(),
                                DrawerItem::Pull(pr) => self.pr_page(drawer, pr, theme, cx).into_any_element(),
                                DrawerItem::Doc(doc) => self.doc_page(drawer, doc, theme, cx).into_any_element(),
                            }),
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
                    .child({
                        let kind = match &drawer.item {
                            DrawerItem::Issue(_) => "Issue",
                            DrawerItem::Pull(_) => "Pull Request",
                            DrawerItem::Doc(doc) => doc.kind.title(),
                        };
                        if count > 1 {
                            format!("{kind} · {} of {count}", self.drawers.iter().position(|d| d.seq == drawer.seq).unwrap_or(0) + 1)
                        } else {
                            kind.into()
                        }
                    }),
            )
            .children(self.drawer_actions(drawer, theme, cx))
            .child(button("close-drawer", "×").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.pop_drawer(cx))))
    }

    /// The drawer bar's buttons, as `IssueSheet`'s and the PR drawer's:
    /// Open on GitHub, then what Claude can do with it.
    fn drawer_actions(&self, drawer: &Drawer, theme: &Theme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        use crate::launch::Flow;
        let seq = drawer.seq;
        let action = |id: &'static str, label: String, tip: String| {
            div()
                .id((id, seq))
                .px_2()
                .py_0p5()
                .rounded_md()
                .cursor_pointer()
                .border_1()
                .border_color(theme.border)
                .hover(|s| s.bg(theme.row_selected))
                .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
                .child(label)
        };
        let mut actions: Vec<AnyElement> = Vec::new();
        match &drawer.item {
            DrawerItem::Issue(item) => {
                let issue = item.issue.clone();
                let url = issue.url.clone();
                actions.push(
                    action("issue-github", "Open on GitHub".into(), "Open this issue on GitHub".into())
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .into_any_element(),
                );
                let has_session = self.session_for(&issue.id, Flow::Work, cx).is_some() || Self::saved_launch(&issue.id, Flow::Work).is_some();
                let harness = self.harness_for(&issue.repo).unwrap_or_default();
                let (label, tip) = if has_session {
                    ("Open Session", format!("Show this issue's Claude Code session, in {harness}"))
                } else {
                    ("Work on This", format!("Work on this issue with Claude Code, in {harness}"))
                };
                let has_plan = self.session_for(&issue.id, Flow::Plan, cx).is_some() || Self::saved_launch(&issue.id, Flow::Plan).is_some();
                let planned = issue.clone();
                actions.push(
                    if has_plan {
                        action("plan-this", "Open Planning".into(), "Show this issue's planning session".into())
                    } else {
                        action("plan-this", "Plan This".into(), "Plan this issue with the team: requirements, design and tasks, then its sub-issues".into())
                    }
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.plan_issue(planned.clone(), window, cx)))
                    .into_any_element(),
                );
                actions.push(
                    action("work-on-this", label.into(), tip)
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.work_on(issue.clone(), window, cx)))
                        .into_any_element(),
                );
            }
            DrawerItem::Doc(doc) => {
                let url = doc.url();
                actions.push(
                    action("doc-github", "Open on GitHub".into(), "Open this document in the harness on GitHub".into())
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .into_any_element(),
                );
            }
            DrawerItem::Pull(pr) => {
                let url = pr.url.clone();
                actions.push(
                    action("pr-github", "Open on GitHub".into(), "Open this pull request on GitHub".into())
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .into_any_element(),
                );
                // Reviews are for open PRs, as Gannin's drawer offers them.
                if pr.state == PrState::Open {
                    let has_review = self.session_for(&pr.id, Flow::Review, cx).is_some() || Self::saved_launch(&pr.id, Flow::Review).is_some();
                    let (label, tip) = if has_review {
                        ("Open Review", "Show Claude's review of this PR".to_string())
                    } else {
                        ("Review with Claude", "Have Claude review this PR, then go through its findings and post the review to GitHub".to_string())
                    };
                    let reviewed = pr.clone();
                    actions.push(
                        action("review-with-claude", label.into(), tip)
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.review_pr(reviewed.clone(), window, cx)))
                            .into_any_element(),
                    );
                    let explained = pr.clone();
                    actions.push(
                        action("explain", "Explain".into(), "Have Claude explain what this PR changes and why, in plain terms".into())
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.explain_pr(explained.clone(), window, cx)))
                            .into_any_element(),
                    );
                }
            }
        }
        actions
    }

    /// The parent and sub-issues, each opening a drawer on top.
    fn related(&self, drawer: &IssueDrawer, seq: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
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
                                .id(("show-in-list", seq))
                                .pb_1()
                                .text_xs()
                                .text_color(theme.selected)
                                .cursor_pointer()
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                    this.navigate(Nav::Issues, false, window, cx);
                                    if let Page::Issues(page) = this.current_page() {
                                        page.update(cx, |page, cx| page.set_scope(Some(parent.clone()), cx));
                                    }
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
        self.issues.update(cx, |page, cx| page.set_org(Some(org.clone()), cx));
        self.harness_counts.clear();
        if self.harness_open {
            self.load_harness_counts(cx);
        }
        for page in self.pages() {
            match page {
                Page::Issues(page) => page.update(cx, |page, cx| {
                    page.set_focus(None, cx);
                    page.set_org(Some(org.clone()), cx)
                }),
                Page::Prs(page) => page.update(cx, |page, cx| {
                    page.set_focus(None, cx);
                    page.set_org(Some(org.clone()), cx)
                }),
                Page::Ci(page) => page.update(cx, |page, cx| {
                    page.set_focus(None, cx);
                    page.set_org(Some(org.clone()), cx)
                }),
                Page::Scorecard(page) => page.update(cx, |page, cx| page.set_org(Some(org.clone()), cx)),
                Page::Activity(page) => page.update(cx, |page, cx| page.set_org(Some(org.clone()), cx)),
                Page::Harness(page) => page.update(cx, |page, cx| page.set_org(Some(org.clone()), cx)),
                _ => {}
            }
        }
        self.load_settings(cx);
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn open_switcher(&mut self, pick: Pick, window: &mut Window, cx: &mut Context<Self>) {
        let current = match pick {
            Pick::Org => self.org.clone(),
            Pick::Project => self.project.clone(),
        };
        let highlighted = self.switcher_items(pick, "").iter().position(|(_, key)| Some(key) == current.as_ref()).unwrap_or(0);
        self.switcher = Some(Switcher { pick, query: String::new(), highlighted });
        window.focus(&self.switcher_focus, cx);
        cx.notify();
    }

    fn close_switcher(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.switcher = None;
        window.focus(&self.focus, cx);
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
        let width = f32::from(size.width);
        let x = f32::from(event.position.x);
        match edge {
            Edge::Sidebar => self.sidebar_width = x.clamp(180.0, 420.0),
            Edge::Harness => {
                let left = if self.sidebar_open { self.sidebar_width } else { 0. };
                self.harness_width = (x - left).clamp(180.0, 420.0)
            }
            Edge::Inspector => self.inspector_width = (width - x).clamp(260.0, 640.0),
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
            Edge::Sidebar | Edge::Harness => handle.top_0().bottom_0().right(px(-3.)).w(px(6.)).cursor_col_resize(),
            Edge::Inspector => handle.top_0().bottom_0().left(px(-3.)).w(px(6.)).cursor_col_resize(),
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
            .child(div().flex_1())
            .when(self.viewer.is_some(), |d| d.child(self.sync_button(theme, cx)))
            .child(self.account(theme, cx))
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

    /// Reads how many documents of each kind the org's harnesses hold, off
    /// the main thread, for the Harness panel.
    fn load_harness_counts(&mut self, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        cx.spawn(async move |this, cx| {
            let counts = cx.background_executor().spawn(async move { crate::harness::counts(&crate::harness::load(&org)) }).await;
            this.update(cx, |this, cx| {
                this.harness_counts = counts;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Shows or hides the Harness panel; its counts load as it opens.
    fn toggle_harness(&mut self, cx: &mut Context<Self>) {
        self.harness_open = !self.harness_open;
        if self.harness_open {
            self.load_harness_counts(cx);
        }
    }

    // MARK: Status bar

    /// Along the foot of the window, as Zed's: panel toggles at each end
    /// and the page's own status between them.
    fn status_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let toggle = |id: &'static str, icon: &'static str, tip: &'static str, on: bool, cx: &mut Context<Self>, action: fn(&mut Self, &mut Context<Self>)| {
            div()
                .id(id)
                .p_1()
                .rounded_md()
                .cursor_pointer()
                .when(on, |d| d.bg(theme.row_selected))
                .hover(|s| s.bg(theme.row_selected))
                .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.to_string())).into())
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    action(this, cx);
                    cx.stop_propagation();
                    cx.notify();
                }))
                .child(gpui::svg().path(icon).size(px(16.)).text_color(if on { theme.fg } else { theme.secondary }))
        };
        div()
            .h(px(28.))
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .px_2()
            .bg(theme.sidebar)
            .border_t_1()
            .border_color(theme.border)
            .child(toggle("toggle-sidebar", "icons/list_tree.svg", "Navigation  ⌃⌘S", self.sidebar_open, cx, |this, _| {
                this.sidebar_open = !this.sidebar_open
            }))
            .child(toggle("toggle-harness", "icons/book.svg", "Harness", self.harness_open, cx, |this, cx| this.toggle_harness(cx)))
            .child(div().flex_1())
            .child(toggle(
                "toggle-sync",
                "icons/arrow_circle.svg",
                "Sync  ⌘R refreshes",
                self.sync.open,
                cx,
                |this, _| this.sync.open = !this.sync.open,
            ))
            .child(toggle(
                "toggle-inspector",
                "icons/user_check.svg",
                "Your Work  ⌥⌘I",
                self.inspector_open,
                cx,
                |this, _| this.inspector_open = !this.inspector_open,
            ))
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
            .child(div().id("nav").flex_1().min_h_0().overflow_y_scroll().px_2().pb_3().children(rows))
            // Settings isn't ported yet.
            // .child(
            //     div()
            //         .flex_none()
            //         .p_2()
            //         .border_t_1()
            //         .border_color(theme.border)
            //         .child(self.nav_row(Nav::Settings, 0, None, current, theme, cx)),
            // )
            .child(self.resize_handle("resize-sidebar", Edge::Sidebar, cx))
    }

    /// The team's harness: its kinds of document, each with a count, beside
    /// the navigation.
    fn harness_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let current = self.current();
        div()
            .relative()
            .w(px(self.harness_width))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .bg(theme.sidebar)
            .border_r_1()
            .border_color(theme.border)
            .child(
                div()
                    .id("harness-panel")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .px_2()
                    .pb_3()
                    .child(div().mt_3().mb_0p5().px_2().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.tertiary).child("Harness"))
                    .children(crate::harness::HarnessKind::ALL.into_iter().map(|kind| self.nav_row(Nav::Harness(kind), 0, None, current, theme, cx))),
            )
            .child(self.resize_handle("resize-harness", Edge::Harness, cx))
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
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                this.navigate(nav, event.modifiers().platform, window, cx)
            }))
            // SF Symbols aren't reachable from GPUI; icons need an SVG set.
            .child(div().w(px(16.)).flex().justify_center().child(div().w(px(6.)).h(px(6.)).rounded_full().bg(theme.tertiary)))
            .child(div().flex_1().overflow_hidden().whitespace_nowrap().child(nav.title()))
            .when_some(
                match nav {
                    Nav::Harness(kind) => self.harness_counts.get(&kind).copied(),
                    _ => None,
                },
                |d, count| d.child(div().text_xs().text_color(theme.secondary).child(count.to_string())),
            )
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

    /// A tab's name: the one given it, else its page's (a session's from
    /// its terminal).
    fn tab_name(&self, tab: &Tab, cx: &App) -> String {
        if let Some(name) = &tab.name {
            return name.clone();
        }
        Self::page_name(self, tab.nav, cx)
    }

    fn page_name(&self, nav: Nav, cx: &App) -> String {
        match nav {
            Nav::Session(id) => self.session(id, cx).map_or("Session".into(), |p| p.read(cx).title(cx)),
            nav => nav.title().into(),
        }
    }

    /// Opens the tab's name in an editor with it all selected.
    fn start_rename(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else { return };
        let name = self.tab_name(tab, cx);
        let field = cx.new(|cx| {
            let mut field = editor::Editor::single_line(window, cx);
            field.set_text(name, window, cx);
            field.select_all(&editor::actions::SelectAll, window, cx);
            field
        });
        // Clicking away keeps the name.
        self._rename_subscription = Some(cx.subscribe(&field, |this, _, event: &editor::EditorEvent, cx| {
            if matches!(event, editor::EditorEvent::Blurred) {
                this.finish_rename(true, cx);
            }
        }));
        let handle = field.focus_handle(cx);
        self.renaming = Some((id, field));
        window.focus(&handle, cx);
        cx.notify();
    }

    /// Keeps the name typed; an empty one, or the page's own, clears it, so
    /// the tab is ordinary again.
    fn finish_rename(&mut self, keep: bool, cx: &mut Context<Self>) {
        let Some((id, field)) = self.renaming.take() else { return };
        self._rename_subscription = None;
        if keep {
            let name = field.read(cx).text(cx).trim().to_string();
            let Some(index) = self.tabs.iter().position(|t| t.id == id) else { return };
            let own = self.page_name(self.tabs[index].nav, cx);
            self.tabs[index].name = (!name.is_empty() && name != own).then_some(name);
        }
        cx.notify();
    }

    /// Enter keeps the name and Escape drops it, before the editor sees them.
    fn rename_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keep = match event.keystroke.key.as_str() {
            "enter" => true,
            "escape" => false,
            _ => return,
        };
        cx.stop_propagation();
        self.finish_rename(keep, cx);
        self.focus_current(window, cx);
    }

    /// Drops a dragged tab onto another's place; the active tab stays active.
    fn move_tab(&mut self, from: usize, to: usize, cx: &mut Context<Self>) {
        if from == to || from >= self.tabs.len() || to >= self.tabs.len() {
            return;
        }
        let active = self.tabs.get(self.active).map(|t| t.id);
        let moved = self.tabs.remove(from);
        self.tabs.insert(to, moved);
        if let Some(active) = active {
            self.active = self.tabs.iter().position(|t| t.id == active).unwrap_or(0);
        }
        cx.notify();
    }

    fn tab_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .h(px(32.))
            .flex_none()
            .flex()
            .flex_row()
            .bg(theme.sidebar)
            .border_b_1()
            .border_color(theme.border)
            .child(self.tab_filter_menu(theme, cx))
            .child(self.tabs(theme, cx))
            .child(self.new_menu(theme, cx))
    }

    /// The "+" at the right of the tab bar, as the Claude Code window's in
    /// Gannin: a menu of what can start in a tab of its own.
    fn new_menu(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let open = self.new_menu_open;
        let item = |id: &'static str, label: &'static str, keys: Option<&'static str>, run: fn(&mut Self, &mut Window, &mut Context<Self>)| {
            div()
                .id(id)
                .mx_1()
                .px_2()
                .py_1()
                .rounded_md()
                .flex()
                .flex_row()
                .justify_between()
                .gap_4()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
                .when_some(keys, |d, keys| d.child(div().text_color(theme.tertiary).child(keys)))
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.new_menu_open = false;
                    run(this, window, cx);
                    cx.notify();
                }))
        };
        div()
            .flex_none()
            .h_full()
            .flex()
            .items_center()
            .px_1()
            .border_l_1()
            .border_color(theme.border)
            .child(
                div()
                    .id("new-tab")
                    .px_2()
                    .rounded_md()
                    .cursor_pointer()
                    .text_color(theme.secondary)
                    .when(open, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        cx.stop_propagation();
                        this.new_menu_open = !this.new_menu_open;
                        cx.notify();
                    }))
                    .child("+"),
            )
            .when(open, |d| {
                d.child(
                    deferred(
                        anchored().anchor(gpui::Anchor::TopRight).snap_to_window_with_margin(px(8.)).child(
                            div()
                                .id("new-menu")
                                .occlude()
                                .on_mouse_down_out(cx.listener(|this, _: &MouseDownEvent, _, cx| {
                                    this.new_menu_open = false;
                                    cx.notify();
                                }))
                                .mt(px(28.))
                                .w(px(220.))
                                .py_1()
                                .flex()
                                .flex_col()
                                .bg(theme.popover)
                                .border_1()
                                .border_color(theme.border)
                                .rounded_lg()
                                .shadow_lg()
                                .child(item("new-menu-claude", "New Claude Code", Some("⌘T"), |this, window, cx| this.new_session(Kind::Claude, window, cx)))
                                .child(item("new-menu-terminal", "New Terminal", Some("⌃`"), |this, window, cx| this.new_session(Kind::Shell, window, cx)))
                                .child(div().my_1().h(px(1.)).bg(theme.border))
                                .child(item("new-menu-ask", "New Ask", None, |this, window, cx| this.open_form(crate::launch::Flow::Ask, None, window, cx)))
                                .child(item("new-menu-quick", "Quick Change", None, |this, window, cx| {
                                    this.open_form(crate::launch::Flow::QuickChange, None, window, cx)
                                }))
                                .child(item("new-menu-plan", "New Plan", None, |this, window, cx| this.open_form(crate::launch::Flow::Plan, None, window, cx)))
                                .child(div().my_1().h(px(1.)).bg(theme.border))
                                .child(item("new-menu-review", "Review a Pull Request", None, |this, window, cx| this.open_pr_picker(window, cx))),
                        ),
                    )
                    .with_priority(2),
                )
            })
    }

    fn tabs(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        // The tabs showing, in order: those of the kind picked, grouped by
        // kind with its icon between groups when asked.
        let mut order: Vec<usize> = (0..self.tabs.len()).filter(|&i| self.tab_filter.is_none_or(|k| self.tab_kind(&self.tabs[i], cx) == k)).collect();
        if self.group_tabs {
            order.sort_by_key(|&i| self.tab_kind(&self.tabs[i], cx) as u8);
        }
        let mut elements: Vec<AnyElement> = Vec::new();
        let mut last: Option<TabKind> = None;
        for index in order {
            let kind = self.tab_kind(&self.tabs[index], cx);
            if self.group_tabs && self.tab_filter.is_none() && last != Some(kind) {
                elements.push(
                    div()
                        .flex_none()
                        .h_full()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_1()
                        .px_2()
                        .border_r_1()
                        .border_color(theme.border)
                        .bg(theme.tile)
                        .text_xs()
                        .text_color(theme.tertiary)
                        .child(gpui::svg().path(kind.icon()).size(px(12.)).text_color(theme.tertiary))
                        .child(kind.title())
                        .into_any_element(),
                );
            }
            last = Some(kind);
            elements.push(self.tab_element(index, theme, cx).into_any_element());
        }
        div().id("tabs").flex_1().min_w_0().h_full().flex().flex_row().overflow_x_scroll().children(elements)
    }

    /// Next or previous among the tabs showing, in the order they show.
    fn step_tab(&mut self, by: i32, window: &mut Window, cx: &mut Context<Self>) {
        let mut order: Vec<usize> = (0..self.tabs.len()).filter(|&i| self.tab_filter.is_none_or(|k| self.tab_kind(&self.tabs[i], cx) == k)).collect();
        if self.group_tabs {
            order.sort_by_key(|&i| self.tab_kind(&self.tabs[i], cx) as u8);
        }
        if order.is_empty() {
            return;
        }
        let at = order.iter().position(|&i| i == self.active).unwrap_or(0) as i32;
        let next = (at + by).rem_euclid(order.len() as i32) as usize;
        self.activate(order[next], window, cx);
    }

    fn tab_element(&self, index: usize, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
                let tab = &self.tabs[index];
                let (kind, kind_tint) = (self.tab_kind(tab, cx), self.tab_tint(tab, theme, cx));
                let (nav, id, page) = (tab.nav, tab.id, tab.page.clone());
                let active = index == self.active;
                let label = self.tab_name(tab, cx);
                let landing = theme.row_selected;
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
                    // A double click renames; a single one switches.
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        if event.click_count() == 2 {
                            this.start_rename(id, window, cx);
                        } else {
                            this.activate(index, window, cx);
                        }
                    }))
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |this, _: &MouseDownEvent, window, cx| {
                            cx.stop_propagation();
                            this.start_rename(id, window, cx);
                        }),
                    )
                    // Drag a tab onto another to move it there.
                    .on_drag(DraggedTab(index, label.clone()), |dragged, _, _, cx| cx.new(|_| ColumnDrag(dragged.1.clone())))
                    .drag_over::<DraggedTab>(move |style, _, _, _| style.bg(landing))
                    .on_drop(cx.listener(move |this, dragged: &DraggedTab, _, cx| this.move_tab(dragged.0, index, cx)))
                    .child(gpui::svg().path(kind.icon()).size(px(14.)).flex_none().text_color(kind_tint))
                    .when_some(match nav {
                        Nav::Session(id) => self.session(id, cx).map(|p| p.read(cx).state),
                        _ => None,
                    }, |d, state| d.child(div().size(px(7.)).rounded_full().bg(state_tint(state, theme))))
                    .map(|d| match &self.renaming {
                        Some((renamed, field)) if *renamed == id => d.child(
                            div()
                                .id(("rename-tab", index))
                                .capture_key_down(cx.listener(Self::rename_key))
                                // Clicks in the field place the cursor, not
                                // switch or drag the tab.
                                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                                .on_click(|_, _, cx| cx.stop_propagation())
                                .w(px(180.))
                                .px_1()
                                .rounded_sm()
                                .border_1()
                                .border_color(theme.selected)
                                .bg(theme.bg)
                                .child(field.clone()),
                        ),
                        _ => d.child(div().max_w(px(220.)).truncate().child(label.clone())),
                    })
                    .when_some(match &page {
                        _ if self.renaming.as_ref().is_some_and(|(r, _)| *r == id) => None,
                        Page::Issues(page) => page.read(cx).tab_count(),
                        Page::Prs(page) => page.read(cx).tab_count(),
                        Page::Harness(page) => page.read(cx).tab_count(),
                        _ => None,
                    }, |d, count| {
                        d.child(div().text_xs().text_color(theme.secondary).child(count))
                    })
                    .child(
                        div()
                            .id(("close-tab", index))
                            .px_1()
                            .rounded_sm()
                            .text_color(theme.tertiary)
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                cx.stop_propagation();
                                this.close_tab(index, window, cx);
                            }))
                            .child("×"),
                    )
    }

    /// What kind of tab it is, for its icon and the tab bar's filter.
    fn tab_kind(&self, tab: &Tab, cx: &App) -> TabKind {
        use crate::launch::Flow;
        match tab.nav {
            Nav::Session(id) => match self.session(id, cx).and_then(|p| p.read(cx).launch.as_ref().map(|l| l.flow)) {
                Some(Flow::Review) => TabKind::Reviews,
                Some(Flow::Work) | Some(Flow::QuickChange) => TabKind::Work,
                Some(Flow::Plan) => TabKind::Plans,
                _ => TabKind::Asks,
            },
            _ => TabKind::Pages,
        }
    }

    /// The icon's colour: a review's verdict once it has one.
    fn tab_tint(&self, tab: &Tab, theme: &Theme, cx: &App) -> gpui::Hsla {
        if let Nav::Session(id) = tab.nav {
            if let Some(verdict) = self.session(id, cx).and_then(|p| p.read(cx).review()).and_then(|r| r.read(cx).verdict()) {
                return match verdict.as_str() {
                    "approve" => theme.good(),
                    "request_changes" => theme.critical(),
                    _ => theme.secondary,
                };
            }
        }
        theme.secondary
    }

    /// Whether a tab's session is waiting on the person.
    fn tab_needs_you(&self, tab: &Tab, cx: &App) -> bool {
        matches!(tab.nav, Nav::Session(id) if self.session(id, cx).is_some_and(|p| p.read(cx).state == State::NeedsYou))
    }

    /// At the left of the tab bar: which kind of tab shows, and grouping.
    fn tab_filter_menu(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let open = self.tab_filter_open;
        let counts: Vec<(TabKind, usize, bool)> = TabKind::ALL
            .into_iter()
            .map(|k| {
                let of: Vec<&Tab> = self.tabs.iter().filter(|t| self.tab_kind(t, cx) == k).collect();
                (k, of.len(), of.iter().any(|t| self.tab_needs_you(t, cx)))
            })
            .filter(|(_, n, _)| *n > 0)
            .collect();
        // A tab hidden by the filter that needs the person shows on the button.
        let hidden_needs = self.tab_filter.is_some() && self.tabs.iter().any(|t| Some(self.tab_kind(t, cx)) != self.tab_filter && self.tab_needs_you(t, cx));
        let orange: gpui::Hsla = gpui::rgb(0xFF9F0A).into();
        let row = |id: SharedString, icon: Option<&'static str>, label: String, count: Option<usize>, needs: bool, on: bool| {
            div()
                .id(id)
                .mx_1()
                .px_2()
                .py_1()
                .rounded_md()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .child(div().w(px(12.)).text_color(theme.selected).child(if on { "✓" } else { "" }))
                .when_some(icon, |d, icon| d.child(gpui::svg().path(icon).size(px(14.)).text_color(theme.secondary)))
                .child(div().flex_1().child(label))
                .when(needs, |d| d.child(div().size(px(7.)).rounded_full().bg(orange)))
                .when_some(count, |d, n| d.child(div().text_xs().text_color(theme.tertiary).child(n.to_string())))
        };
        let label = self.tab_filter.map(|k| k.title()).unwrap_or("All");
        div()
            .flex_none()
            .h_full()
            .flex()
            .items_center()
            .px_1()
            .border_r_1()
            .border_color(theme.border)
            .child(
                div()
                    .id("tab-filter")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .px_1p5()
                    .py_0p5()
                    .rounded_md()
                    .cursor_pointer()
                    .text_xs()
                    .text_color(if self.tab_filter.is_some() { theme.selected } else { theme.secondary })
                    .when(open, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        cx.stop_propagation();
                        this.tab_filter_open = !this.tab_filter_open;
                        cx.notify();
                    }))
                    .child(gpui::svg().path(self.tab_filter.map(|k| k.icon()).unwrap_or("icons/filter.svg")).size(px(14.)).text_color(if self.tab_filter.is_some() { theme.selected } else { theme.secondary }))
                    .child(label)
                    .when(hidden_needs, |d| d.child(div().size(px(7.)).rounded_full().bg(orange))),
            )
            .when(open, |d| {
                let mut menu = div()
                    .id("tab-filter-menu")
                    .occlude()
                    .on_mouse_down_out(cx.listener(|this, _: &MouseDownEvent, _, cx| {
                        this.tab_filter_open = false;
                        cx.notify();
                    }))
                    .mt(px(28.))
                    .w(px(220.))
                    .py_1()
                    .flex()
                    .flex_col()
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .rounded_lg()
                    .shadow_lg()
                    .child(row("tab-filter-all".into(), None, "All".into(), Some(self.tabs.len()), false, self.tab_filter.is_none()).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.tab_filter = None;
                        this.tab_filter_open = false;
                        cx.notify();
                    })));
                for (kind, count, needs) in counts {
                    menu = menu.child(
                        row(SharedString::from(format!("tab-filter-{}", kind.title())), Some(kind.icon()), kind.title().into(), Some(count), needs, self.tab_filter == Some(kind)).on_click(cx.listener(
                            move |this, _: &ClickEvent, window, cx| {
                                this.tab_filter = Some(kind);
                                this.tab_filter_open = false;
                                // Show one of that kind if the tab showing isn't.
                                if this.tabs.get(this.active).is_none_or(|t| this.tab_kind(t, cx) != kind) {
                                    if let Some(first) = this.tabs.iter().position(|t| this.tab_kind(t, cx) == kind) {
                                        this.activate(first, window, cx);
                                    }
                                }
                                cx.notify();
                            },
                        )),
                    );
                }
                let grouped = self.group_tabs;
                menu = menu.child(div().my_1().h(px(1.)).bg(theme.border)).child(row("tab-group".into(), None, "Group by kind".into(), None, false, grouped).on_click(cx.listener(
                    move |this, _: &ClickEvent, _, cx| {
                        this.group_tabs = !grouped;
                        this.tab_filter_open = false;
                        cx.notify();
                    },
                )));
                d.child(deferred(anchored().snap_to_window_with_margin(px(8.)).child(menu)).with_priority(2))
            })
    }

    fn page(&self, theme: &Theme, cx: &App) -> AnyElement {
        match self.current() {
            Some(Nav::Session(id)) => match self.session(id, cx) {
                Some(page) => page.clone().into_any_element(),
                None => div().into_any_element(),
            },
            _ if !matches!(self.current_page(), Page::None) => match self.current_page() {
                Page::Issues(page) => page.into_any_element(),
                Page::Prs(page) => page.into_any_element(),
                Page::Ci(page) => page.into_any_element(),
                Page::Scorecard(page) => page.into_any_element(),
                Page::Activity(page) => page.into_any_element(),
                Page::Harness(page) => page.into_any_element(),
                Page::ReviewPreview(page) => page.into_any_element(),
                Page::None => div().into_any_element(),
            },
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

    // MARK: Your work

    /// The menu bar's list in the window: sessions wanting you first, then
    /// reviews asked of you, your PRs needing you, the rest of your PRs,
    /// the sessions still working, and issues assigned to you. A session or
    /// an issue switches to its tab; a PR opens on GitHub (no PR page yet).
    fn your_work(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let mut waiting: Vec<&Entity<SessionPage>> =
            self.sessions.iter().filter(|s| matches!(s.read(cx).state, State::NeedsYou | State::YourTurn)).collect();
        waiting.sort_by_key(|s| (s.read(cx).state.rank(), s.read(cx).since));
        let working: Vec<&Entity<SessionPage>> = self.sessions.iter().filter(|s| s.read(cx).state == State::Working).collect();
        let ended: Vec<&Entity<SessionPage>> = self.sessions.iter().filter(|s| s.read(cx).state == State::Ended).collect();
        let needing: Vec<&Pr> = self.work.mine.iter().filter(|p| p.needs().is_some_and(|n| n != "Ready to merge")).collect();
        let others: Vec<&Pr> = self.work.mine.iter().filter(|p| !p.needs().is_some_and(|n| n != "Ready to merge")).collect();
        let assigned = match &self.work.login {
            Some(login) => self.issues.read(cx).assigned_to(login),
            None => Vec::new(),
        };
        let count = waiting.len() + self.work.reviews.len() + needing.len();
        let orange: gpui::Hsla = gpui::rgb(0xFF9F0A).into();
        let red: gpui::Hsla = gpui::rgb(0xFF453A).into();
        let green: gpui::Hsla = gpui::rgb(0x30D158).into();

        let section = |title: &'static str, count: usize, tint: gpui::Hsla| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .px_1()
                .pt_3()
                .pb_1()
                .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(title))
                .child(
                    div()
                        .px_1p5()
                        .rounded_full()
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .bg(tint.opacity(0.18))
                        .text_color(tint)
                        .child(count.to_string()),
                )
        };
        let row = |id: (&'static str, usize), tint: gpui::Hsla, title: String, detail: String| {
            div()
                .id(id)
                .flex()
                .flex_row()
                .items_start()
                .gap_2()
                .px_1()
                .py_1()
                .rounded_md()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .child(div().mt(px(5.)).size(px(8.)).flex_none().rounded_full().bg(tint))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(div().truncate().child(title))
                        .child(div().text_xs().text_color(theme.secondary).truncate().child(detail)),
                )
        };
        let session_row = |index: usize, page: &Entity<SessionPage>, cx: &mut Context<Self>| {
            let p = page.read(cx);
            let id = p.id;
            let detail = format!("{} · {}", p.state.label(), relative_date(p.since.with_timezone(&Utc), Utc::now()));
            row(("work-session", index), state_tint(p.state, theme), p.title(cx), detail).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                if let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(id)) {
                    this.activate(index, window, cx);
                }
            }))
        };
        let pr_row = |index: usize, pr: &Pr, tint: gpui::Hsla, detail: String, cx: &mut Context<Self>| {
            let url = pr.url.clone();
            row(("work-pr", index), tint, pr.title.clone(), detail).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
        };
        let mine_tint = |pr: &Pr| match pr.needs() {
            Some("Checks failing") => red,
            Some("Changes requested" | "Conflicts") => orange,
            Some("Ready to merge") => green,
            _ => theme.tertiary,
        };

        let mut list = div().flex().flex_col();
        let mut index = 0;
        if count == 0 {
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap_1()
                    .py_4()
                    .child(div().text_color(green).text_lg().child("✓"))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("All clear"))
                    .child(
                        div()
                            .text_xs()
                            .text_color(theme.secondary)
                            .text_center()
                            .child("No reviews waiting, nothing failing, no session waiting on you."),
                    ),
            );
        }
        if !waiting.is_empty() {
            list = list.child(section("Sessions waiting on you", waiting.len(), orange));
            for page in &waiting {
                list = list.child(session_row(index, page, cx));
                index += 1;
            }
        }
        if !self.work.reviews.is_empty() {
            list = list.child(section("Reviews asked of you", self.work.reviews.len(), theme.selected));
            for pr in &self.work.reviews {
                let detail = format!(
                    "{}#{}{} · {}",
                    pr.short_repo(),
                    pr.number,
                    pr.author.as_ref().map(|a| format!(" · {a}")).unwrap_or_default(),
                    relative_date(pr.updated, Utc::now())
                );
                list = list.child(pr_row(index, pr, theme.selected, detail, cx));
                index += 1;
            }
        }
        if !needing.is_empty() {
            list = list.child(section("Your PRs needing you", needing.len(), red));
            for pr in &needing {
                let detail = format!("{}#{} · {}", pr.short_repo(), pr.number, pr.standing());
                list = list.child(pr_row(index, pr, mine_tint(pr), detail, cx));
                index += 1;
            }
        }
        if !working.is_empty() {
            list = list.child(section("Sessions working", working.len(), green));
            for page in &working {
                list = list.child(session_row(index, page, cx));
                index += 1;
            }
        }
        if !others.is_empty() {
            list = list.child(section("Your other PRs", others.len(), theme.secondary));
            for pr in &others {
                let detail = format!("{}#{} · {}", pr.short_repo(), pr.number, pr.standing());
                list = list.child(pr_row(index, pr, mine_tint(pr), detail, cx));
                index += 1;
            }
        }
        if let Some(live) = self.work.issues.clone().filter(|i| !i.is_empty()) {
            list = list.child(section("Assigned to you", live.len(), green));
            for issue in live.into_iter().take(8) {
                let detail = format!("{}#{} · updated {}", issue.repo.rsplit('/').next().unwrap_or(&issue.repo), issue.number, relative_date(issue.updated, Utc::now()));
                let (id, url) = (issue.id.clone(), issue.url.clone());
                list = list.child(row(("work-issue", index), green, issue.title.clone(), detail).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    // In a drawer when it's this org's, else on GitHub.
                    match this.issues.read(cx).issue(&id) {
                        Some(found) => {
                            this.navigate(Nav::Issues, false, window, cx);
                            this.push_drawer(found, cx);
                        }
                        None => cx.open_url(&url),
                    }
                })));
                index += 1;
            }
        } else if !assigned.is_empty() {
            list = list.child(section("Assigned to you", assigned.len(), green));
            for issue in assigned.into_iter().take(8) {
                let detail = format!("{}#{} · updated {}", issue.repo_name, issue.number, relative_date(issue.updated_at.unwrap_or(issue.created_at), Utc::now()));
                let title = issue.title.clone();
                list = list.child(row(("work-issue", index), green, title, detail).on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.navigate(Nav::Issues, false, window, cx);
                    this.push_drawer(issue.clone(), cx);
                })));
                index += 1;
            }
        }
        if !ended.is_empty() {
            list = list.child(section("Ended", ended.len(), theme.tertiary));
            for page in &ended {
                list = list.child(session_row(index, page, cx));
                index += 1;
            }
        }

        let summary = match &self.work.login {
            Some(login) => format!(
                "{} · {} · {}",
                login,
                match count {
                    0 => "nothing waiting".to_string(),
                    1 => "1 thing waiting".to_string(),
                    n => format!("{n} things waiting"),
                },
                if self.work.live { "live from GitHub" } else { "from the cache" }
            ),
            None => "Not signed in: only sessions show".to_string(),
        };
        div()
            .flex()
            .flex_col()
            .child(div().text_xs().text_color(theme.secondary).child(summary))
            .child(list)
    }

    // MARK: Inspector

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
            None => self.your_work(theme, cx).into_any_element(),
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
                    .child(div().flex_1().text_color(theme.secondary).child(if self.inspector.is_some() { "Repository" } else { "Your Work" }))
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
            .when(self.inspector.is_some(), |d| {
                d.child(
                    div()
                        .id("back-to-work")
                        .px_3()
                        .pt_2()
                        .text_xs()
                        .cursor_pointer()
                        .text_color(theme.selected)
                        .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.inspector = None;
                            cx.notify();
                        }))
                        .child("‹ Your Work"),
                )
            })
            .child(div().id("inspector-body").flex_1().min_h_0().overflow_y_scroll().p_3().child(body))
            .child(self.resize_handle("resize-inspector", Edge::Inspector, cx))
    }

    /// An issue as `IssueWindow` shows it: the title and headline facts
    /// across the top; the timeline, board history, linked pull requests,
    /// description, comments, parent and sub-issues on the left; and the
    /// assignees and board fields on the right.
    fn issue_page(&self, drawer: &Drawer, item: &IssueDrawer, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let issue = &item.issue;
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
            .child(self.related(item, drawer.seq, theme, cx));

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

    /// A pull request as `PullRequestColumn` shows it: the title and
    /// headline facts; activity, linked issues, description and comments on
    /// the left; the people on the right.
    fn pr_page(&self, drawer: &Drawer, pr: &PrItem, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let seq = drawer.seq;
        let now = Utc::now();
        let date = |t: DateTime<Utc>| t.with_timezone(&Local).format("%-d %b %Y").to_string();
        let fact = |label: &str, value: String| {
            div()
                .min_w(px(140.))
                .flex()
                .flex_col()
                .gap_0p5()
                .child(div().text_xs().text_color(theme.secondary).child(label.to_string()))
                .child(value)
        };
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
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

        let mut facts = vec![fact("Status", pr.status_title().to_string())];
        if let Some(branch) = &pr.branch {
            facts.push(fact("Branch", branch.clone()));
        }
        if let Some(checks) = pr.checks {
            facts.push(fact("Checks", checks.title().into()));
        }
        if let (Some(a), Some(d)) = (pr.additions, pr.deletions) {
            let files = pr.files.map(|f| format!("{f} file{}, ", if f == 1 { "" } else { "s" })).unwrap_or_default();
            facts.push(fact("Size", format!("{files}+{a} −{d}")));
        }
        facts.push(fact("Opened", format!("{}{}", date(pr.created_at), pr.author.as_ref().map(|a| format!(" by {a}")).unwrap_or_default())));
        if let Some(first) = pr.first_commit_at {
            facts.push(fact("First commit", date(first)));
        }
        if let Some(ready) = pr.ready_at {
            facts.push(fact("Ready for review", date(ready)));
        }
        match pr.state {
            PrState::Merged => facts.push(fact(
                "Merged",
                format!("{}{}", pr.merged_at.map(date).unwrap_or_default(), pr.merged_by.as_ref().map(|m| format!(" by {m}")).unwrap_or_default()),
            )),
            PrState::Closed => facts.push(fact("Closed without merging", pr.closed_at.map(date).unwrap_or_default())),
            PrState::Open => {
                facts.push(fact("Updated", relative_date(pr.updated_at, now)));
                if let Some(commit) = pr.last_commit_at {
                    facts.push(fact("Last commit", relative_date(commit, now)));
                }
            }
        }

        let url = pr.url.clone();
        let header = div()
            .flex()
            .flex_col()
            .gap_3()
            .px_5()
            .py_4()
            .border_b_1()
            .border_color(theme.border)
            .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(pr.title.clone()))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .id(("pr-link", seq))
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                            .child(format!("{}#{}", pr.repo, pr.number)),
                    )
                    .child(crate::prs::state_pill(pr, theme))
                    .when_some(pr.standing.filter(|_| pr.state == PrState::Open), |d, standing| {
                        d.child(div().text_color(standing.color(theme)).child(standing.title()))
                    })
                    .when(pr.is_stale(now), |d| d.child(pill("Stale", theme.secondary))),
            )
            .child(div().flex().flex_row().flex_wrap().gap_x_6().gap_y_3().children(facts));

        // Activity: commits and reviews from the work log, newest first.
        enum Event<'a> {
            Commit(&'a crate::prs::Commit),
            Review(&'a crate::prs::Review),
        }
        let mut events: Vec<(DateTime<Utc>, Event)> = pr.commits.iter().map(|c| (c.authored_at, Event::Commit(c))).collect();
        events.extend(pr.reviews.iter().map(|r| (r.submitted_at, Event::Review(r))));
        events.sort_by(|a, b| b.0.cmp(&a.0));
        let activity = (!events.is_empty()).then(|| {
            div().flex().flex_col().gap_1().child(heading("Activity", Some(events.len()))).children(events.iter().enumerate().map(|(i, (at, event))| {
                let (tint, kind, who, what, link) = match event {
                    Event::Commit(c) => (
                        theme.blue(),
                        "Commit",
                        c.author.clone().unwrap_or_default(),
                        format!("{} · {} lines", c.message.lines().next().unwrap_or(""), c.additions + c.deletions),
                        c.url.clone(),
                    ),
                    Event::Review(r) => {
                        let (tint, kind) = match r.state.as_str() {
                            "APPROVED" => (theme.good(), "Approved"),
                            "CHANGES_REQUESTED" => (theme.orange(), "Changes requested"),
                            "DISMISSED" => (theme.secondary, "Dismissed"),
                            _ => (theme.secondary, "Commented"),
                        };
                        (tint, kind, r.author.clone(), String::new(), None)
                    }
                };
                div()
                    .id(SharedString::from(format!("pr-event-{seq}-{i}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .py_0p5()
                    .when_some(link, |d, url| d.cursor_pointer().hover(|s| s.bg(theme.tile)).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))))
                    .child(div().size(px(8.)).flex_none().rounded_full().bg(tint))
                    .child(div().flex_none().w(px(120.)).child(kind))
                    .child(div().flex_none().font_weight(FontWeight::MEDIUM).child(who))
                    .child(div().flex_1().min_w_0().truncate().text_color(theme.secondary).child(what))
                    .child(quiet(at.with_timezone(&Local).format("%-d %b, %H:%M").to_string()))
            }))
        });

        // Linked issues open on top, from the issue store when it has them.
        let linked = (!pr.linked.is_empty()).then(|| {
            div().flex().flex_col().gap_1().child(heading("Linked issues", Some(pr.linked.len()))).children(pr.linked.iter().enumerate().map(|(i, issue)| {
                let (id, url) = (issue.id.clone(), issue.url.clone());
                let closed = issue.state.as_deref() == Some("CLOSED");
                div()
                    .id(SharedString::from(format!("pr-linked-{seq}-{i}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .py_1()
                    .px_2()
                    .rounded_md()
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.tile))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| match this.issues.read(cx).issue(&id) {
                        Some(found) => this.push_drawer(found, cx),
                        None => cx.open_url(&url),
                    }))
                    .child(if closed { pill("Closed", theme.slot(6)) } else { pill("Open", theme.good()) })
                    .child(div().flex_1().truncate().child(issue.title.clone()))
                    .child(div().text_color(theme.secondary).child(match issue.repo.as_deref().filter(|r| *r != pr.repo) {
                        Some(repo) => format!("{}#{}", repo.rsplit('/').next().unwrap_or(repo), issue.number),
                        None => format!("#{}", issue.number),
                    }))
            }))
        });

        let text: Option<&IssueText> = drawer.text.as_ref().and_then(|t| t.as_deref());
        let description = div().flex().flex_col().gap_1().child(heading("Description", None)).child(match &drawer.text {
            None => quiet("Loading".into()).into_any_element(),
            Some(None) => quiet("Not in Gannin's caches yet: open it in Gannin once, or on GitHub.".into()).into_any_element(),
            Some(Some(t)) if t.body.trim().is_empty() => div().text_color(theme.tertiary).child("No description").into_any_element(),
            Some(Some(t)) => markdown(&format!("pr-description-{seq}"), &t.body, theme),
        });
        let comments = text.filter(|t| !t.comments.is_empty()).map(|t| {
            let count = t.comment_count.unwrap_or(t.comments.len());
            div().flex().flex_col().gap_3().child(heading("Comments", Some(count))).children(t.comments.iter().enumerate().map(|(i, comment)| {
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
                            .when_some(comment.at, |d, at| d.child(quiet(relative_date(at, now)))),
                    )
                    .child(markdown(&format!("pr-comment-{seq}-{i}"), &comment.body, theme))
            }))
        });

        let left = div()
            .flex_1()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_6()
            .p_5()
            .children(activity)
            .children(linked)
            .child(description)
            .children(comments);

        // The people, each with where they stand.
        let group = |title: &str| div().pb_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(title.to_string());
        let person = |login: &str, avatar_url: Option<&str>, name: Option<String>, note: Option<String>, cx: &mut Context<Self>| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .py_0p5()
                .child(avatar(login, avatar_url, 20., theme, cx))
                .child(div().flex_1().min_w_0().truncate().child(name.unwrap_or_else(|| login.to_string())))
                .when_some(note, |d, note| d.child(div().text_xs().text_color(theme.secondary).child(note)))
        };
        let mut right = div().w(px(280.)).flex_none().flex().flex_col().gap_5().p_4().border_l_1().border_color(theme.border);
        if let Some(login) = &pr.author {
            right = right.child(
                div().flex().flex_col().child(group("Author")).child(person(login, pr.author_avatar.as_deref(), pr.author_name.clone(), pr.author_is_bot.then(|| "bot".into()), cx)),
            );
        }
        let mut assignees = div().flex().flex_col().child(group("Assignees"));
        if pr.assignees.is_empty() {
            assignees = assignees.child(div().text_color(theme.tertiary).child("Nobody"));
        }
        for (login, url) in &pr.assignees {
            assignees = assignees.child(person(login, url.as_deref(), None, None, cx));
        }
        let mut reviewers = div().flex().flex_col().child(group("Reviewers"));
        if pr.reviewers.is_empty() {
            reviewers = reviewers.child(div().text_color(theme.tertiary).child("Nobody asked yet"));
        }
        for reviewer in &pr.reviewers {
            reviewers = reviewers.child(person(&reviewer.login, reviewer.avatar.as_deref(), reviewer.name.clone(), Some(reviewer.standing().into()), cx));
        }
        right = right.child(assignees).child(reviewers);

        div().flex().flex_col().child(header).child(div().flex().flex_row().items_start().child(left).child(right))
    }

    /// A harness document: its title, status, date and path; what it's
    /// about; its front matter as facts; and its text.
    fn doc_page(&self, drawer: &Drawer, doc: &crate::harness::Doc, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let seq = drawer.seq;
        let quiet = |text: String| div().text_xs().text_color(theme.secondary).child(text);
        let fact = |label: &str, value: String| {
            div()
                .min_w(px(140.))
                .flex()
                .flex_col()
                .gap_0p5()
                .child(div().text_xs().text_color(theme.secondary).child(label.to_string()))
                .child(value)
        };
        let mut facts = Vec::new();
        if let Some(status) = &doc.status {
            facts.push(fact("Status", crate::harness::status_label(Some(status))));
        }
        if let Some(date) = doc.date {
            facts.push(fact("Date", date.format("%-d %b %Y").to_string()));
        }
        if let Some(area) = &doc.area {
            facts.push(fact("Area", area.clone()));
        }
        if doc.tasks > 0 {
            facts.push(
                div()
                    .min_w(px(140.))
                    .flex()
                    .flex_col()
                    .gap_0p5()
                    .child(div().text_xs().text_color(theme.secondary).child("Tasks"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(crate::charts::progress_ring(doc.tasks_done, doc.tasks, 16., theme))
                            .child(format!("{} of {} done", doc.tasks_done, doc.tasks)),
                    ),
            );
        }
        for (key, value) in doc.front_matter.iter().filter(|(k, _)| !matches!(k.as_str(), "domains" | "issues" | "date")) {
            let label = key.replace(['_', '-'], " ");
            let label = format!("{}{}", label.get(..1).unwrap_or("").to_uppercase(), label.get(1..).unwrap_or(""));
            facts.push(fact(&label, value.clone()));
        }
        // The issues it's about first, then those it mentions; each opens in
        // a drawer when the store has it.
        let mut references = doc.references.clone();
        references.sort_by_key(|r| !r.2);
        let issues = (!references.is_empty()).then(|| {
            div().flex().flex_col().gap_1().child(div().font_weight(FontWeight::SEMIBOLD).child("Issues")).children(references.into_iter().enumerate().map(|(i, (repo, number, about))| {
                let repo = repo.unwrap_or_default();
                let found = self.issues.read(cx).issue_by_number(&repo, number);
                let title = found.as_ref().map(|f| f.title.clone()).unwrap_or_default();
                let url = format!("https://github.com/{repo}/issues/{number}");
                div()
                    .id(SharedString::from(format!("doc-issue-{seq}-{i}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .py_0p5()
                    .px_2()
                    .rounded_md()
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.tile))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| match &found {
                        Some(issue) => this.push_drawer(issue.clone(), cx),
                        None => cx.open_url(&url),
                    }))
                    .child(div().text_color(theme.selected).child(format!("{}#{number}", repo.rsplit('/').next().unwrap_or(&repo))))
                    .child(div().flex_1().truncate().child(title))
                    .child(quiet(if about { "about".into() } else { "mentions".into() }))
            }))
        });
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .px_5()
                    .py_4()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(doc.title.clone()))
                    .child(quiet(format!("{} · {}", doc.harness, doc.path)))
                    .when_some(doc.summary.clone(), |d, s| d.child(div().text_color(theme.secondary).child(s)))
                    .child(div().flex().flex_row().flex_wrap().gap_x_6().gap_y_3().children(facts)),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_6()
                    .p_5()
                    .children(issues)
                    .child(markdown(&format!("doc-{seq}"), doc.body(), theme)),
            )
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
                            this.navigate(Nav::Settings, false, window, cx);
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

/// `SessionBrief.make` for an issue: its facts, description, recent
/// comments, and how work goes in the harness.
fn work_brief(issue: &IssueItem, text: Option<&IssueText>, parent: Option<&IssueItem>, launch: &crate::launch::Launch) -> String {
    let reference = format!("{}#{}", issue.repo, issue.number);
    let mut out = format!("# {reference}: {}\n\n{}\n\n", issue.title, issue.url);
    let mut facts = vec![format!(
        "- State: {}",
        match (issue.is_open(), issue.not_planned) {
            (true, _) => "open",
            (false, true) => "closed, not planned",
            (false, false) => "closed",
        }
    )];
    if let Some(kind) = &issue.issue_type {
        facts.push(format!("- Type: {kind}"));
    }
    if !issue.labels.is_empty() {
        facts.push(format!("- Labels: {}", issue.labels.join(", ")));
    }
    if let Some(milestone) = &issue.milestone {
        facts.push(format!("- Milestone: {milestone}"));
    }
    if let Some(author) = &issue.author_login {
        facts.push(format!("- Opened by: @{author}, {}", issue.created_at.with_timezone(&Local).format("%-d %b %Y")));
    }
    if !issue.assignee_logins.is_empty() {
        facts.push(format!("- Assignees: {}", issue.assignee_logins.iter().map(|l| format!("@{l}")).collect::<Vec<_>>().join(", ")));
    }
    if let Some(parent) = parent {
        facts.push(format!("- Parent: #{} {} ({})", parent.number, parent.title, parent.url));
    }
    for (board, values) in &issue.boards {
        let fields: Vec<String> = values.iter().map(|(name, value)| format!("{name} {value}")).collect();
        facts.push(format!("- Board \"{board}\": {}", fields.join(", ")));
    }
    for pr in &issue.linked_prs {
        let state = if pr.merged_at.is_some() { "merged".to_string() } else { pr.state.to_lowercase() };
        facts.push(format!("- Linked PR: #{}, {state} ({})", pr.number, pr.url));
    }
    out.push_str(&facts.join("\n"));
    out.push_str("\n\n## Description\n\n");
    match text.map(|t| t.body.trim()).filter(|b| !b.is_empty()) {
        Some(body) => out.push_str(body),
        None => out.push_str("(No description.)"),
    }
    out.push_str("\n\n");
    if let Some(text) = text.filter(|t| !t.comments.is_empty()) {
        let total = text.comment_count.unwrap_or(text.comments.len());
        if total > text.comments.len() {
            out.push_str(&format!("## Recent comments ({} of {total})\n\n", text.comments.len()));
        } else {
            out.push_str("## Comments\n\n");
        }
        for comment in &text.comments {
            let at = comment.at.map(|at| format!(", {}", at.with_timezone(&Local).format("%-d %b %Y %H:%M"))).unwrap_or_default();
            out.push_str(&format!("### @{}{at}\n\n{}\n\n", comment.author, comment.body.trim()));
        }
    }
    out.push_str(&crate::launch::working_here(&launch.harness_repo, &launch.harness_path, &launch.branch, Some(&reference), &issue.repo, false));
    out
}

/// A session's state as a colour, as `SessionState.color`.
fn state_tint(state: State, theme: &Theme) -> gpui::Hsla {
    match state {
        State::NeedsYou => gpui::rgb(0xFF9F0A).into(),
        State::YourTurn => theme.selected,
        State::Working => gpui::rgb(0x30D158).into(),
        State::Ended => theme.tertiary,
    }
}


impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.persist(cx);
        // Only the session in view reads its folder's changes.
        let current = self.current();
        for page in &self.sessions {
            let visible = current == Some(Nav::Session(page.read(cx).id));
            page.update(cx, |page, cx| page.set_visible(visible, cx));
        }
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
                    .child(self.page(&theme, cx))
                    .when(!self.drawers.is_empty(), |d| d.child(self.drawer_stack(&theme, cx))),
            )
;
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
            .on_action(cx.listener(|this, _: &NewClaudeSession, window, cx| this.new_session(Kind::Claude, window, cx)))
            .on_action(cx.listener(|this, _: &NewTerminal, window, cx| this.new_session(Kind::Shell, window, cx)))
            .on_action(cx.listener(|this, _: &Refresh, _, cx| this.refresh(cx)))
            .on_action(cx.listener(|this, _: &ToggleSync, _, cx| {
                this.sync.open = !this.sync.open;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &NewAsk, window, cx| this.open_form(crate::launch::Flow::Ask, None, window, cx)))
            .on_action(cx.listener(|this, _: &NewQuickChange, window, cx| this.open_form(crate::launch::Flow::QuickChange, None, window, cx)))
            .on_action(cx.listener(|this, _: &NewPlan, window, cx| this.open_form(crate::launch::Flow::Plan, None, window, cx)))
            .on_action(cx.listener(|this, _: &CloseTab, window, cx| this.close_tab(this.active, window, cx)))
            .on_action(cx.listener(|this, _: &NextTab, window, cx| this.step_tab(1, window, cx)))
            .on_action(cx.listener(|this, _: &PreviousTab, window, cx| this.step_tab(-1, window, cx)))
            .on_action(cx.listener(|this, _: &OpenSwitcher, window, cx| this.open_switcher(Pick::Org, window, cx)))
            // Escape closes the top drawer; the switcher takes it first when open.
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" && this.sign_in.is_some() {
                    this.cancel_sign_in(cx);
                    cx.stop_propagation();
                } else if event.keystroke.key == "escape" && (this.account_open || this.new_menu_open) {
                    this.account_open = false;
                    this.new_menu_open = false;
                    cx.notify();
                    cx.stop_propagation();
                } else if event.keystroke.key == "escape" && this.switcher.is_none() && !this.drawers.is_empty() {
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
                    .when(self.harness_open, |d| d.child(self.harness_panel(&theme, cx)))
                    .child(center)
                    .when(self.inspector_open, |d| d.child(self.inspector(&theme, cx)))
                    .when(self.sync.open, |d| d.child(self.sync_panel(&theme, cx))),
            )
            .child(self.status_bar(&theme, cx))
            .when(self.switcher.is_some(), |d| d.child(self.switcher_backdrop(cx)))
            .when(self.account_open, |d| {
                d.child(
                    div()
                        .id("account-backdrop")
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .bottom_0()
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _: &MouseDownEvent, _, cx| {
                                this.account_open = false;
                                cx.notify();
                            }),
                        ),
                )
            })
            .when_some(self.sign_in.as_ref(), |d, step| d.child(self.sign_in_sheet(step, &theme, cx)))
            .when_some(self.explain.as_ref().map(|(sheet, _)| sheet.clone()), |d, sheet| {
                d.child(
                    div()
                        .id("explain-scrim")
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .bottom_0()
                        .occlude()
                        .bg(gpui::black().opacity(0.35))
                        .flex()
                        .justify_center()
                        .pt(px(60.))
                        .child(sheet),
                )
            })
            .when_some(self.pr_picker.as_ref().map(|(picker, _)| picker.clone()), |d, picker| {
                d.child(
                    div()
                        .id("picker-scrim")
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .bottom_0()
                        .occlude()
                        .bg(gpui::black().opacity(0.35))
                        .flex()
                        .justify_center()
                        .pt(px(70.))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _: &MouseDownEvent, window, cx| {
                                this.pr_picker = None;
                                this.focus_current(window, cx);
                                cx.notify();
                            }),
                        )
                        .child(div().on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation()).child(picker)),
                )
            })
            .when_some(self.launch_form.as_ref().map(|(form, _)| form.clone()), |d, form| {
                d.child(
                    div()
                        .id("form-scrim")
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .bottom_0()
                        .occlude()
                        .bg(gpui::black().opacity(0.35))
                        .flex()
                        .justify_center()
                        .pt(px(90.))
                        .child(form),
                )
            })
    }
}
