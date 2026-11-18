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
use crate::prs::{OpenPr, PrItem, PrState, PrsPage, PrsSaved, ReviewPrs, ShowReview};
use crate::state::{remove_slot, CiSaved, SavedState, SavedTab};
use crate::work::{self, Pr, Work};
use gpui::{
    actions, anchored, Focusable, black, deferred, div, ease_out_quint, prelude::*, px, relative, Animation, AnimationExt, AnyElement, ClickEvent, Context, App, Entity, FocusHandle, FontWeight, KeyBinding,
    KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, SharedString, Subscription, Window,
    WindowAppearance,
};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

actions!(shell, [ToggleSidebar, ToggleInspector, ToggleSync, ToggleTabsOnLeft, Refresh, NewClaudeSession, NewTerminal, NewAsk, NewQuickChange, NewPlan, CloseTab, NextTab, PreviousTab, OpenSwitcher, OpenFolder, NewWindow]);

pub fn key_bindings() -> Vec<KeyBinding> {
    vec![
        KeyBinding::new(crate::zed::keys("ctrl-secondary-s"), ToggleSidebar, None),
        KeyBinding::new(crate::zed::keys("secondary-alt-i"), ToggleInspector, None),
        KeyBinding::new(crate::zed::keys("secondary-t"), NewClaudeSession, None),
        KeyBinding::new("ctrl-`", NewTerminal, None),
        KeyBinding::new(crate::zed::keys("secondary-w"), CloseTab, None),
        KeyBinding::new(crate::zed::keys("secondary-shift-n"), NewWindow, None),
        KeyBinding::new(crate::zed::keys("secondary-shift-right"), NextTab, None),
        KeyBinding::new(crate::zed::keys("secondary-shift-left"), PreviousTab, None),
        KeyBinding::new(crate::zed::keys("secondary-shift-]"), NextTab, None),
        KeyBinding::new(crate::zed::keys("secondary-shift-["), PreviousTab, None),
        // ⇧⌘[ and ⇧⌘] arrive as ⌘{ and ⌘}, as Zed binds them.
        KeyBinding::new(crate::zed::keys("secondary-}"), NextTab, None),
        KeyBinding::new(crate::zed::keys("secondary-{"), PreviousTab, None),
        KeyBinding::new("ctrl-tab", NextTab, None),
        KeyBinding::new("ctrl-shift-tab", PreviousTab, None),
        KeyBinding::new(crate::zed::keys("secondary-alt-o"), OpenSwitcher, None),
        KeyBinding::new(crate::zed::keys("secondary-o"), OpenFolder, None),
        KeyBinding::new(crate::zed::keys("secondary-r"), Refresh, None),
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
    /// The scheduler: its week and month.
    SchedulePreview,
    /// The workflow editor.
    WorkflowsPreview,
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
            Nav::SchedulePreview => "Schedule",
            Nav::WorkflowsPreview => "Workflows",
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
        // Claude Code's agents: the workflows sessions run through.
        Section { id: "agents", title: Some("Agents"), rows: vec![Item(AgentMetrics), Item(SchedulePreview), Item(WorkflowsPreview)] },
    ]
}

/// The orgs being synced now, by any window.
static SYNCING: std::sync::Mutex<std::collections::BTreeSet<String>> = std::sync::Mutex::new(std::collections::BTreeSet::new());

/// The window every Gannin window opens with: its own title bar, with the
/// traffic lights over it.
pub fn window_options(cx: &App) -> gpui::WindowOptions {
    gpui::WindowOptions {
        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(None, gpui::size(px(1440.), px(940.)), cx))),
        titlebar: Some(gpui::TitlebarOptions { title: Some("Gannin".into()), appears_transparent: true, traffic_light_position: Some(gpui::point(px(14.), px(12.))) }),
        ..Default::default()
    }
}

/// Whether a tab's session runs: pages and live sessions are active, a
/// session whose claude has ended is stopped.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
pub enum TabStatus {
    Active,
    Stopped,
}

impl TabStatus {
    fn title(self) -> &'static str {
        match self {
            TabStatus::Active => "Active",
            TabStatus::Stopped => "Stopped",
        }
    }
}

/// What Resume All tells each session Pause All stopped.
const RESUME: &str = "Carry on from where you were interrupted.";

/// What a tab is, for its icon and the tab bar's filter; in the order
/// grouped tabs go.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, serde::Serialize, serde::Deserialize)]
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

struct NewIssueSubpage {
    form: Entity<crate::new_issue::NewIssueForm>,
    _subscription: Subscription,
    tab: u64,
    showing: bool,
}

/// An issue or a pull request in a drawer.
struct Drawer {
    /// Unique per drawer opened, so each one slides in once.
    seq: usize,
    item: DrawerItem,
    /// Its description and comments: nil while they load, then what's
    /// cached, then what GitHub sent.
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
    SchedulePreview(Entity<crate::schedule_page::SchedulePage>),
    WorkflowsPreview(Entity<crate::workflows_page::WorkflowsPage>),
    AgentMetrics(Entity<crate::agent_metrics::AgentMetricsPage>),
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
    /// Open Recent: the folders opened, and opening another.
    Folder,
    Project,
}

/// A switcher open in the title bar, as Zed's project picker.
struct Switcher {
    pick: Pick,
    query: String,
    highlighted: usize,
    /// Typing a path on this server to open, in place of the list.
    server: Option<crate::servers::Server>,
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
    /// The folder the window has open, as a Zed window has a project: its
    /// org's harnesses there are the window's projects, and its sessions
    /// run where it is (this Mac or a server).
    folder: Option<crate::folders::Opened>,
    /// The folder saved, kept while it can't be read (a server that's
    /// off), so it isn't forgotten.
    saved_folder: Option<crate::folders::Location>,
    /// A folder being read, by its place, for the title bar.
    opening: Option<String>,
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
    /// Tabs in a column on the left, in place of the bar across the top.
    tabs_on_left: bool,
    inspector_open: bool,
    sidebar_width: f32,
    harness_width: f32,
    inspector_width: f32,
    resizing: Option<Edge>,
    switcher: Option<Switcher>,
    /// The Remotes popover, open under the title bar.
    remotes: Option<Entity<crate::remotes::Remotes>>,
    /// Servers whose check is running, by key.
    checking_servers: std::collections::HashSet<String>,
    _remotes_subscription: Option<Subscription>,
    /// Bottom first; the last is on top.
    drawers: Vec<Drawer>,
    drawer_seq: usize,
    /// Every issue, never shown: what drawers and Your Work look up.
    issues: Entity<IssuesPage>,
    sessions: Vec<Entity<SessionPage>>,
    next_session: u32,
    /// Marra, docked down the right of this window (⌘J), when it's docked.
    pub marra_dock: Option<Entity<crate::marra_view::MarraView>>,
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
    /// New Issue: a subpage over the tab it was opened on (whose page
    /// stays as it was beneath), kept when you go back from it so it
    /// resumes. The tab's ID, and whether it's showing.
    new_issue: Option<NewIssueSubpage>,
    /// The tab bar's filter by kind (None is all), whether tabs group by
    /// kind, and whether its menu is open.
    tab_filter: Option<TabKind>,
    /// Active or stopped tabs only; None is both.
    tab_status: Option<TabStatus>,
    /// The tab bar's search: a PR or issue number finds the sessions that
    /// own it (their subject, or a PR they opened); words match names.
    tab_search: Entity<editor::Editor>,
    /// Each session's PR numbers, read from its `pr` hook file at most every
    /// few seconds, by launch.
    session_prs: std::cell::RefCell<std::collections::HashMap<String, (std::time::Instant, Vec<i64>)>>,
    group_tabs: bool,
    tab_filter_open: bool,
    /// Sessions Pause All stopped, for Resume All to start again.
    paused_sessions: std::collections::HashSet<u32>,
    /// Kinds whose group of tabs is folded away.
    collapsed_kinds: std::collections::HashSet<TabKind>,
    /// Which window this is, for where its state is saved (0 is the first).
    slot: usize,
    /// Closed by the person: its state is gone and must never be written
    /// again, though its pages may still update (a fetch finishing) and
    /// call `persist` after the window's gone, which would bring it back
    /// at the next launch.
    closed: bool,
    /// Sessions being reopened at launch, which open without switching,
    /// but for the one that was showing (by its launch).
    reopening: usize,
    show_on_reopen: Option<String>,
    /// The schedule's clock (the first window only), how often it's
    /// ticked, and this window, for the clock to act in.
    _scheduler: Option<gpui::Task<()>>,
    schedule_ticks: u64,
    window_handle: Option<gpui::AnyWindowHandle>,
    /// Workflows for launches being started, by launch id.
    launch_workflows: std::collections::HashMap<String, crate::workflows::Workflow>,
    /// Scheduled issues being scouted now, and a scheduled start's
    /// scouting for its brief, while it's being started.
    scouting: std::collections::HashSet<String>,
    prepared: Option<String>,
    /// Add to Schedule's sheet, while it's open.
    schedule_sheet: Option<(Entity<crate::schedule_sheet::ScheduleSheet>, Subscription)>,
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
            folder: self.folder.as_ref().map(|f| f.location.clone()).or_else(|| self.saved_folder.clone()),
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
                    Nav::Session(id) => self.session(id, cx).and_then(|p| p.read(cx).saved_key()),
                    _ => None,
                })
                .collect(),
            plain_sessions: self
                .tabs
                .iter()
                .filter_map(|tab| match tab.nav {
                    Nav::Session(id) => self.session(id, cx).and_then(|p| {
                        let page = p.read(cx);
                        let id = page.claude_id.clone().filter(|_| page.launch.is_none())?;
                        Some(crate::state::PlainSession { id, location: page.location() })
                    }),
                    _ => None,
                })
                .collect(),
            active_session: match self.current() {
                Some(Nav::Session(id)) => self.session(id, cx).and_then(|p| p.read(cx).saved_key()),
                _ => None,
            },
            // Sessions open after the views, so the index counts the views.
            active: self.tabs.iter().take(self.active).filter(|tab| !matches!(tab.nav, Nav::Session(_))).count(),
            sidebar_open: self.sidebar_open,
            tabs_on_left: self.tabs_on_left,
            harness_open: self.harness_open,
            tab_filter: self.tab_filter,
            tab_status: self.tab_status,
            group_tabs: self.group_tabs,
            collapsed_kinds: {
                let mut kinds: Vec<TabKind> = self.collapsed_kinds.iter().copied().collect();
                kinds.sort_by_key(|k| *k as u8);
                kinds
            },
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
        if self.closed || self.resizing.is_some() || resizing_column {
            return;
        }
        let state = self.snapshot(cx);
        if self.last_saved.as_ref() != Some(&state) {
            state.save_slot(self.slot);
            self.last_saved = Some(state);
        }
    }

    pub fn new(saved: SavedState, slot: usize, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // Closing a window with sessions running asks first, as they end
        // with it; a closed window (but the first) doesn't open again.
        let this = cx.entity().downgrade();
        window.on_window_should_close(cx, move |window, cx| {
            let Some(entity) = this.upgrade() else { return true };
            let running = entity.read(cx).running(cx);
            let close = Self::confirm_close(running, slot, this.clone(), window, cx);
            if close {
                entity.update(cx, |workspace, _| workspace.closed = true);
            }
            close
        });
        let views = Self::saved_views(&saved);
        let sessions = saved.sessions.clone();
        let plain_sessions = saved.plain_sessions.clone();
        let active_session = saved.active_session.clone();
        let active = saved.active;
        let mut workspace = Self::build(saved, window, cx);
        workspace.slot = slot;
        workspace.window_handle = Some(window.window_handle());
        if slot == 0 {
            // Scouts ended with the app: theirs start again.
            let mut sched = crate::schedule::Schedule::load();
            let before = sched.readiness.len();
            sched.readiness.retain(|_, r| r.state != "scouting");
            if sched.readiness.len() != before {
                sched.save();
            }
            workspace.start_scheduler(cx);
        }
        // Settings held only the servers, now in the title bar's Remotes.
        for view in views.iter().filter(|v| v.nav != Nav::Settings) {
            let tab = workspace.make_tab(view.nav, Some(view), window, cx);
            workspace.tabs.push(tab);
        }
        workspace.active = active.min(workspace.tabs.len().saturating_sub(1));
        workspace.load_viewer(cx);
        // The sessions that were open come back, claude resuming in each;
        // the one that was showing shows again.
        workspace.show_on_reopen = active_session;
        let launches = crate::launch::saved();
        for id in &sessions {
            if let Some(plain) = id.strip_prefix("plain:").and_then(|id| plain_sessions.iter().find(|p| p.id == id)).cloned() {
                workspace.reopening += 1;
                workspace.open_session_on(Kind::Claude, plain.location.path, None, plain.location.server, Some(plain.id), window, cx);
            } else if let Some(launch) = launches.iter().find(|l| &l.id == id).cloned() {
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
        // The folder it had open; a window from before folders opens its
        // project's harness, where it's checked out here.
        let folder = workspace.saved_folder.clone().or_else(|| {
            let (org, project) = (workspace.org.clone()?, workspace.project.clone()?);
            let path = crate::launch::harness_path(&org, &project);
            path.is_dir().then(|| crate::folders::Location::here(path))
        });
        if let Some(folder) = folder {
            workspace.open_folder(folder, false, window, cx);
        }
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
                this.projects = this.folder_projects(settings.projects);
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
        // The Workflows pages follow the window's project.
        let (org, project) = (self.org.clone(), self.project.clone());
        for page in self.pages() {
            if let Page::WorkflowsPreview(page) = page {
                page.update(cx, |page, cx| page.set_project(org.clone(), project.clone(), cx));
            }
        }
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
        let tab_search = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Find PR #", window, cx);
            editor
        });
        let subscriptions = vec![
            cx.observe_window_appearance(window, |_, window, cx| {
                crate::zed::follow_appearance(window, cx);
                cx.notify();
            }),
            cx.subscribe(&tab_search, |_, _, event: &editor::EditorEvent, cx| {
                if matches!(event, editor::EditorEvent::BufferEdited) {
                    cx.notify();
                }
            }),
        ];
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
            folder: None,
            saved_folder: saved.folder.clone(),
            opening: None,
            workflow: Workflow::default(),
            collapsed_sections: sections().iter().map(|s| s.id).filter(|id| saved.collapsed_sections.iter().any(|c| c == id)).collect(),
            expanded_groups: saved.expanded_groups.iter().copied().collect(),
            active: 0,
            tabs: Vec::new(),
            next_tab: 0,
            templates: (saved.issues.clone(), saved.prs.clone(), saved.ci.clone()),
            inspector: None,
            sidebar_open: saved.sidebar_open,
            tabs_on_left: saved.tabs_on_left,
            collapsed_kinds: saved.collapsed_kinds.iter().copied().collect(),
            tab_filter: saved.tab_filter,
            tab_status: saved.tab_status,
            tab_search,
            session_prs: Default::default(),
            group_tabs: saved.group_tabs,
            harness_open: saved.harness_open,
            inspector_open: saved.inspector_open,
            sidebar_width: saved.sidebar_width,
            harness_width: saved.sidebar_width,
            inspector_width: saved.inspector_width,
            last_saved: Some(saved),
            resizing: None,
            switcher: None,
            remotes: None,
            checking_servers: Default::default(),
            _remotes_subscription: None,
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
            new_issue: None,
            pr_picker: None,
            explain: None,
            schedule_sheet: None,
            scouting: Default::default(),
            prepared: None,
            launch_workflows: Default::default(),
            _scheduler: None,
            schedule_ticks: 0,
            window_handle: None,
            marra_dock: None,
            reopening: 0,
            slot: 0,
            closed: false,
            show_on_reopen: None,
            tab_filter_open: false,
            paused_sessions: Default::default(),
            sync: SyncStatus { prefs: sync_prefs, ..SyncStatus::default() },
            _sync_loop: None,
            _subscriptions: subscriptions,
        }
    }

    /// Shows `nav`: switches to a tab of it that hasn't been named, else
    /// puts it in the current tab, else (Command held, or the current tab is
    /// named, a session's, or holds a New Issue draft) opens a new tab beside
    /// it. A named tab is a view someone made, and a draft is work started,
    /// so neither is switched to or replaced from here.
    fn navigate(&mut self, nav: Nav, new_tab: bool, window: &mut Window, cx: &mut Context<Self>) {
        // Drawers belong to the page under them.
        self.drawers.clear();
        let draft_tab = self.new_issue.as_ref().map(|s| s.tab);
        let reusable = |tab: &Tab| tab.name.is_none() && !matches!(tab.nav, Nav::Session(_)) && Some(tab.id) != draft_tab;
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
                let reviewing = self.reviewing(cx);
                page.update(cx, |page, cx| page.set_reviewing(reviewing, cx));
                Page::Prs(page)
            }
            Nav::Ci => {
                let state = saved.and_then(|s| s.ci.clone()).unwrap_or_else(|| self.template_ci(cx));
                Page::Ci(cx.new(|cx| ActionsPage::new(org, &state, window, cx)))
            }
            Nav::Scorecards => Page::Scorecard(cx.new(|cx| crate::scorecard::ScorecardPage::new(org, cx))),
            Nav::Activity => Page::Activity(cx.new(|cx| crate::activity::ActivityPage::new(org, cx))),
            Nav::ReviewPreview => Page::ReviewPreview(cx.new(|cx| crate::review_preview::ReviewPreview::new(window, cx))),
            Nav::SchedulePreview => Page::SchedulePreview(cx.new(|cx| crate::schedule_page::SchedulePage::new(org.clone(), window, cx))),
            Nav::WorkflowsPreview => Page::WorkflowsPreview(cx.new(|cx| crate::workflows_page::WorkflowsPage::new(org.clone(), self.project.clone(), window, cx))),
            Nav::Harness(kind) => Page::Harness(cx.new(|cx| crate::harness::HarnessPage::new(org, kind, window, cx))),
            Nav::AgentMetrics => Page::AgentMetrics(cx.new(|cx| crate::agent_metrics::AgentMetricsPage::new(org.clone(), cx))),
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
                cx.subscribe_in(page, window, |this, _, event: &crate::issues::WorkOnIssues, window, cx| this.work_on_many(event.0.clone(), window, cx)),
                cx.subscribe_in(page, window, |this, _, _: &crate::issues::NewIssue, window, cx| this.open_new_issue(None, window, cx)),
                cx.subscribe_in(page, window, |this, _, event: &crate::issues::ScheduleIssues, window, cx| this.schedule_issues(event.0.clone(), window, cx)),
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
                cx.subscribe_in(page, window, |this, _, event: &ShowReview, window, cx| {
                    this.show_session(&event.0.id, crate::launch::Flow::Review, window, cx);
                }),
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
            Page::SchedulePreview(page) => vec![cx.subscribe_in(page, window, |this, _, event: &crate::schedule_page::RunNow, window, cx| this.run_now(&event.0, window, cx))],
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

    /// The window's sessions, for Marra.
    pub fn session_pages(&self) -> &[Entity<SessionPage>] {
        &self.sessions
    }

    /// Your Work as the window has it, for Marra.
    pub fn work_lists(&self) -> &Work {
        &self.work
    }

    /// Shows a session's tab, for Marra's Open.
    pub fn reveal_session(&mut self, id: u32, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(index) = self.tabs.iter().position(|t| t.nav == Nav::Session(id)) {
            self.drawers.clear();
            self.activate(index, window, cx);
        }
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
        // A tab the filters hide (a new one, say) shows all again.
        if let (Some(kind), Some(tab)) = (self.tab_filter, self.tabs.get(self.active)) {
            if self.tab_kind(tab, cx) != kind {
                self.tab_filter = None;
            }
        }
        if let (Some(status), Some(tab)) = (self.tab_status, self.tabs.get(self.active)) {
            if self.tab_status_of(tab, cx) != status {
                self.tab_status = None;
            }
        }
        if !self.tab_query(cx).is_empty() && self.tabs.get(self.active).is_some_and(|t| !self.tab_matches_search(t, cx)) {
            self.tab_search.update(cx, |e, cx| e.set_text("", window, cx));
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

    /// Opens the session in a tab of its own, in the window's folder: on
    /// this Mac, or over ssh in that folder on the window's server. Only a
    /// window with no folder asks where to start.
    fn new_session(&mut self, kind: Kind, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(location) = self.folder.as_ref().map(|f| f.location.clone()) {
            self.open_session_on(kind, location.path, None, location.server, None, window, cx);
            return;
        }
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

    /// Move to Server: asks first, naming the server (the window's folder's,
    /// else the only one set up), then moves the session there off the main
    /// thread and resumes it there in its tab's place.
    fn move_to_server(&mut self, session: u32, launch: crate::launch::Launch, window: &mut Window, cx: &mut Context<Self>) {
        let servers = crate::servers::load().servers;
        let server = self.folder.as_ref().and_then(|f| f.location.server.clone()).or_else(|| (servers.len() == 1).then(|| servers[0].clone()));
        let Some(server) = server else {
            let _ = window.prompt(
                gpui::PromptLevel::Info,
                "Which server?",
                Some("Open the session's harness on the server (Remotes in the title bar), then Move to Server from that window."),
                &["OK"],
                cx,
            );
            return;
        };
        let detail = format!(
            "Its worktrees go to {name} at the same commits, with what isn't committed, and Claude's conversation with them. Nothing is pushed to GitHub. The copies on this Mac stay as they are. Then it resumes on {name}.",
            name = server.name()
        );
        let Some(page) = self.session(session, cx).cloned() else { return };
        if page.read(cx).moving.is_some() {
            return;
        }
        let answer = window.prompt(gpui::PromptLevel::Info, &format!("Move this session to {}?", server.name()), Some(&detail), &["Move", "Cancel"], cx);
        cx.spawn_in(window, async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            // The page is covered until the move ends; the step it's on is
            // read from the move as it goes.
            let title = format!("Moving to {}", server.name());
            let step = std::sync::Arc::new(std::sync::Mutex::new("Starting".to_string()));
            let started = cx
                .update(|window, cx| {
                    page.update(cx, |page, cx| {
                        if page.moving.is_some() {
                            return false;
                        }
                        page.moving = Some((title.clone(), "Starting".into()));
                        cx.notify();
                        true
                    }) && {
                        // Keys would still reach the terminal under the cover.
                        window.blur(cx);
                        true
                    }
                })
                .unwrap_or(false);
            if !started {
                return;
            }
            let task = cx.background_executor().spawn({
                let step = step.clone();
                async move {
                    crate::session_move::move_to(&launch, &server, &|now| {
                        if let Ok(mut s) = step.lock() {
                            *s = now;
                        }
                    })
                }
            });
            let ticker = cx.spawn({
                let page = page.downgrade();
                let step = step.clone();
                async move |cx| loop {
                    cx.background_executor().timer(std::time::Duration::from_millis(200)).await;
                    let now = step.lock().map(|s| s.clone()).unwrap_or_default();
                    let alive = page
                        .update(cx, |page, cx| {
                            if let Some((_, shown)) = page.moving.as_mut() {
                                if *shown != now {
                                    *shown = now;
                                    cx.notify();
                                }
                            }
                        })
                        .is_ok();
                    if !alive {
                        return;
                    }
                }
            });
            let moved = task.await;
            drop(ticker);
            page.update(cx, |page, cx| {
                page.moving = None;
                cx.notify();
            });
            this.update_in(cx, |this, window, cx| match moved {
                Ok(launch) => {
                    if let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(session)) {
                        this.remove_tab(index, cx);
                    }
                    let folder = launch.harness_path.clone();
                    this.open_session(Kind::Claude, folder, Some(launch), window, cx);
                }
                Err(error) => {
                    let _ = window.prompt(gpui::PromptLevel::Warning, "Couldn't move the session", Some(&error), &["OK"], cx);
                }
            })
            .ok();
        })
        .detach();
    }

    /// Opens a session in a tab of its own: a terminal in `folder`, or a
    /// launch's start script.
    fn open_session(&mut self, kind: Kind, folder: PathBuf, launch: Option<crate::launch::Launch>, window: &mut Window, cx: &mut Context<Self>) {
        self.open_session_on(kind, folder, launch, None, None, window, cx);
    }

    /// As `open_session`, for a plain session on `server`: `folder` is a
    /// path there. A plain Claude Code session gets a conversation ID of its
    /// own (or `claude_id`, reopening one), so it can be saved and resumed.
    fn open_session_on(&mut self, kind: Kind, folder: PathBuf, launch: Option<crate::launch::Launch>, server: Option<crate::servers::Server>, claude_id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let claude_id = (kind == Kind::Claude && launch.is_none()).then(|| claude_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string()));
        let task = session::spawn_terminal(kind, folder.clone(), launch.as_ref(), server.as_ref(), claude_id.as_deref(), window, cx);
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
                let page = cx.new(|cx| {
                    let mut page = SessionPage::new(id, kind, folder, launch, server, builder, window, cx);
                    page.claude_id = claude_id;
                    page
                });
                this._subscriptions.push(cx.subscribe(&page, |this, _, _: &Changed, cx| {
                    this.sync_reviewing(cx);
                    cx.notify();
                }));
                this._subscriptions.push(cx.subscribe_in(&page, window, move |this, page, event: &crate::work_panel::WorkEvent, window, cx| {
                    let launch = page.read(cx).launch.clone();
                    if let (crate::work_panel::WorkEvent::MoveToServer, Some(launch)) = (event, launch.clone()) {
                        this.move_to_server(id, launch, window, cx);
                        return;
                    }
                    let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(id)) else { return };
                    this.remove_tab(index, cx);
                    match (event, launch) {
                        // Resume: a new terminal in its place, claude carrying on.
                        (crate::work_panel::WorkEvent::Resume, Some(launch)) => {
                            let folder = launch.harness_path.clone();
                            this.open_session(Kind::Claude, folder, Some(launch), window, cx);
                        }
                        // Forget (or after Finish): the pilot's record of it goes; its files stay.
                        (crate::work_panel::WorkEvent::Forget, Some(launch)) => {
                            launch.remove_dir();
                        }
                        _ => {}
                    }
                }));
                this._subscriptions.push(cx.subscribe_in(&page, window, |this, _, event: &crate::review_panel::ExplainPr, window, cx| {
                    this.open_explain(event.0.clone(), event.1.clone(), window, cx)
                }));
                this._subscriptions.push(cx.subscribe(&page, |this, _, event: &crate::harness::OpenDoc, cx| {
                    this.drawers.clear();
                    let id = event.0.path.clone();
                    this.open_drawer(DrawerItem::Doc(event.0.clone()), id, cx);
                }));
                this.sessions.push(page);
                this.sync_reviewing(cx);
                this.drawers.clear();
                this.next_tab += 1;
                let tab = Tab { id: this.next_tab, nav: Nav::Session(id), name: None, page: Page::None };
                this.tabs.push(tab);
                // Sessions reopened at launch don't take the tab that was showing.
                if this.reopening > 0 {
                    this.reopening -= 1;
                    let reopened = this.session(id, cx).and_then(|p| p.read(cx).saved_key());
                    if reopened.is_some() && reopened == this.show_on_reopen {
                        this.show_on_reopen = None;
                        this.activate(this.tabs.len() - 1, window, cx);
                    }
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

    /// Whether this window's folder is on a server, where sessions are meant to run.
    fn on_server(&self) -> bool {
        self.folder.as_ref().is_some_and(|f| f.location.server.is_some())
    }

    /// Where a repo's harness is for this window: its server (None for this
    /// Mac) and the harness's path there, as `new_launch` would use.
    fn place_for(&self, repo: &str) -> Option<(Option<crate::servers::Server>, PathBuf)> {
        let org = self.org.clone()?;
        let harness = self.harness_for(repo)?;
        let path = self
            .folder
            .as_ref()
            .and_then(|f| f.harnesses.iter().find(|h| h.repo_id(&org).eq_ignore_ascii_case(&harness)))
            .map(|h| h.path.clone())
            .unwrap_or_else(|| crate::launch::harness_path(&org, &harness));
        Some((self.folder.as_ref().and_then(|f| f.location.server.clone()), path))
    }

    /// Another window that suits the work better than this one by `fit`
    /// (whether its harness covers it, and whether it's on a server): the
    /// schedule runs in the first window, whose folder may be on this Mac
    /// while the harness the work needs is open on a server in another.
    fn better_window(&self, fit: impl Fn(&Workspace) -> Option<(bool, bool)>, cx: &App) -> Option<gpui::WindowHandle<Workspace>> {
        let own = fit(self);
        let best = cx
            .windows()
            .into_iter()
            .filter(|h| Some(*h) != self.window_handle)
            .filter_map(|h| h.downcast::<Workspace>())
            .filter_map(|w| w.read(cx).ok().and_then(|ws| fit(ws)).map(|f| (w, f)))
            .max_by_key(|(_, f)| *f)?;
        own.is_none_or(|own| best.1 > own).then_some(best.0)
    }

    /// The PRs with a review session in a tab, by id: whether it's running.
    fn reviewing(&self, cx: &App) -> HashMap<String, bool> {
        self.sessions
            .iter()
            .filter_map(|s| {
                let s = s.read(cx);
                let launch = s.launch.as_ref().filter(|l| l.flow == crate::launch::Flow::Review)?;
                Some((launch.subject.as_ref()?.id.clone(), s.state != State::Ended))
            })
            .fold(HashMap::new(), |mut map, (id, running)| {
                *map.entry(id).or_insert(false) |= running;
                map
            })
    }

    /// Tells the PR tables which PRs have a review session open.
    fn sync_reviewing(&mut self, cx: &mut Context<Self>) {
        let reviewing = self.reviewing(cx);
        for tab in &self.tabs {
            if let Page::Prs(page) = &tab.page {
                let reviewing = reviewing.clone();
                page.update(cx, |page, cx| page.set_reviewing(reviewing, cx));
            }
        }
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
        // An earlier run, only where this window runs sessions: one that ran
        // on this Mac isn't reopened from a server's window, or the reverse.
        let server = self.folder.as_ref().and_then(|f| f.location.server.clone());
        let earlier = crate::launch::saved().into_iter().find(|l| l.flow == flow && l.server == server && l.subject.as_ref().is_some_and(|s| s.id == subject_id));
        if let Some(launch) = earlier {
            self.drawers.clear();
            let folder = launch.harness_path.clone();
            self.open_session(Kind::Claude, folder, Some(launch), window, cx);
            return true;
        }
        false
    }

    /// Prepares a launch's files and opens it.
    /// Starts a launch, after checking the harness is on its default
    /// branch: sessions read the team's instructions from it, so one left
    /// on another branch or a detached commit would start on stale ones.
    /// Then it asks: switch it back (and pull) and start, start anyway, or
    /// not start.
    fn start_launch(&mut self, launch: crate::launch::Launch, brief: &str, prompt: &str, disallow_edits: bool, window: &mut Window, cx: &mut Context<Self>) {
        // On a server, the harness checked is there: its start script pulls it.
        if launch.server.is_some() {
            return self.start_now(launch, brief, prompt, disallow_edits, window, cx);
        }
        let (brief, prompt) = (brief.to_string(), prompt.to_string());
        let harness = launch.harness_path.clone();
        let check = cx.background_executor().spawn(async move { crate::launch::harness_branch(&harness) });
        let unattended = launch.unattended.is_some();
        cx.spawn_in(window, async move |this, cx| {
            let found = check.await;
            this.update_in(cx, |this, window, cx| {
                // Nobody's there to answer for a scheduled start: it goes ahead.
                let Some(off) = found.filter(|_| !unattended) else {
                    return this.start_now(launch, &brief, &prompt, disallow_edits, window, cx);
                };
                let place = launch.harness_path.display().to_string().replace(&std::env::var("HOME").unwrap_or_default(), "~");
                let detail = format!(
                    "{place} is {}, not on {}, so this session would read the team's instructions as they are there, not the latest.{}",
                    off.on,
                    off.default,
                    if off.clean { "" } else { "\n\nIt has changes to tracked files, so it can't be switched here: put it back on its default branch yourself, or start anyway." }
                );
                let buttons: &[&str] = if off.clean { &["Switch and Start", "Start Anyway", "Cancel"] } else { &["Start Anyway", "Cancel"] };
                let answer = window.prompt(gpui::PromptLevel::Warning, &format!("The harness isn't on {}", off.default), Some(&detail), buttons, cx);
                let clean = off.clean;
                let default = off.default.clone();
                cx.spawn_in(window, async move |this, cx| {
                    let choice = answer.await.ok();
                    let (switch, start) = match (clean, choice) {
                        (true, Some(0)) => (true, true),
                        (true, Some(1)) | (false, Some(0)) => (false, true),
                        _ => (false, false),
                    };
                    if !start {
                        return;
                    }
                    if switch {
                        let harness = launch.harness_path.clone();
                        let switched = cx.background_executor().spawn(async move { crate::launch::switch_harness(&harness, &default) }).await;
                        if let Err(error) = switched {
                            this.update_in(cx, |_, window, cx| {
                                let _ = window.prompt(gpui::PromptLevel::Critical, "Couldn't switch the harness", Some(&error), &["OK"], cx);
                            })
                            .ok();
                            return;
                        }
                    }
                    this.update_in(cx, |this, window, cx| this.start_now(launch, &brief, &prompt, disallow_edits, window, cx)).ok();
                })
                .detach();
            })
            .ok();
        })
        .detach();
    }

    fn start_now(&mut self, launch: crate::launch::Launch, brief: &str, prompt: &str, disallow_edits: bool, window: &mut Window, cx: &mut Context<Self>) {
        let workflow = self.launch_workflows.remove(&launch.id);
        let gate = workflow.as_ref().is_some_and(|w| !w.steps_when(crate::workflows::When::Local).is_empty());
        if let Err(error) = launch.prepare(brief, prompt, disallow_edits, gate) {
            let _ = window.prompt(gpui::PromptLevel::Critical, "Couldn't start the session", Some(&error.to_string()), &["OK"], cx);
            return;
        }
        if let Some(workflow) = workflow {
            self.start_workflow(&launch, workflow, cx);
        }
        self.drawers.clear();
        let folder = launch.harness_path.clone();
        self.open_session(Kind::Claude, folder, Some(launch), window, cx);
    }

    /// Keeps the workflow with the session, and runs its prepare steps
    /// while the start script waits (`preparing`), adding their notes to the
    /// brief.
    fn start_workflow(&mut self, launch: &crate::launch::Launch, workflow: crate::workflows::Workflow, cx: &mut Context<Self>) {
        use crate::work_flow::{prepare, write_run, Run};
        let dir = launch.dir();
        let _ = std::fs::write(dir.join("workflow.json"), serde_json::to_vec_pretty(&workflow).unwrap_or_default());
        let has_prepare = workflow.steps_when(crate::workflows::When::Prepare).iter().any(|s| s.command.is_none());
        write_run(&dir, &Run { workflow: workflow.name.clone(), prepare: if has_prepare { "running".into() } else { "skipped".into() }, ..Default::default() });
        if !has_prepare {
            return;
        }
        let _ = std::fs::write(dir.join("preparing"), "");
        let harness = launch.harness_path.clone();
        cx.background_executor()
            .spawn(async move {
                let specialists = crate::workflows::specialists(&harness);
                let brief = std::fs::read_to_string(dir.join("brief.md")).unwrap_or_default();
                let notes = prepare(&harness, &brief, &workflow, &specialists);
                let _ = std::fs::write(dir.join("brief.md"), format!("{brief}{notes}"));
                if let Some(mut run) = crate::work_flow::read_run(&dir) {
                    run.prepare = "done".into();
                    write_run(&dir, &run);
                }
                let _ = std::fs::remove_file(dir.join("preparing"));
            })
            .detach();
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
        self.work_on_with(issue, None, window, cx);
    }

    /// Work on This, attended or (`unattended`, with the PR gap's minutes)
    /// started by the schedule. Returns the launch's id when it started one.
    fn work_on_with(&mut self, issue: IssueItem, unattended: Option<u32>, window: &mut Window, cx: &mut Context<Self>) -> Option<String> {
        use crate::launch::{self, Flow, Subject};
        if unattended.is_none() && self.show_session(&issue.id, Flow::Work, window, cx) {
            return None;
        }
        // The schedule never starts a second session on an issue.
        if unattended.is_some() && (self.session_for(&issue.id, Flow::Work, cx).is_some() || Self::saved_launch(&issue.id, Flow::Work).is_some()) {
            return None;
        }
        let (Some(org), Some(harness)) = (self.org.clone(), self.harness_for(&issue.repo)) else {
            if unattended.is_none() {
                Self::no_harness(window, cx);
            }
            return None;
        };
        let branch = launch::issue_branch(issue.number, &issue.title);
        let reference = format!("{}#{}", issue.repo, issue.number);
        let subject = Subject { id: issue.id.clone(), repo: issue.repo.clone(), number: issue.number, title: issue.title.clone(), url: issue.url.clone() };
        let mut launch = self.new_launch(Flow::Work, format!("#{} {}", issue.number, issue.title), &org, &harness, branch.clone(), Some(subject));
        launch.unattended = unattended;
        let text = detail::load_text(&org, &issue.id);
        let parent = issue.parent_id.as_deref().and_then(|id| self.issues.read(cx).issue(id));
        let mut brief = work_brief(&issue, text.as_ref(), parent.as_ref(), &launch);
        let prompt = launch::opening_prompt(&reference, &issue.title, &branch);
        // Your workflow for Work on This; Gannin's own runs the session alone.
        let workflow = crate::workflows::default_for("work", Some(&launch.harness_path));
        if !workflow.is_built_in() {
            let specialists = crate::workflows::specialists(&launch.harness_path);
            brief.push_str(&crate::work_flow::brief_section(&workflow, &specialists));
            self.launch_workflows.insert(launch.id.clone(), workflow);
        }
        if unattended.is_some() {
            brief.push_str(crate::schedule::UNATTENDED);
        }
        // Scouted when it was scheduled: its notes and decisions are in the
        // brief, so the workflow's prepare steps needn't run again.
        if let Some(prepared) = self.prepared.clone() {
            brief.push_str(&prepared);
            if let Some(workflow) = self.launch_workflows.get_mut(&launch.id) {
                let kinds: Vec<crate::workflows::When> = workflow.staged().iter().map(|(k, _)| *k).collect();
                let mut k = kinds.into_iter();
                workflow.stages.retain(|_| k.next() != Some(crate::workflows::When::Prepare));
            }
        }
        let id = launch.id.clone();
        self.start_launch(launch, &brief, &prompt, false, window, cx);
        Some(id)
    }

    /// Review with Claude: a session in the harness with edits disallowed,
    /// Gannin's review prompt, and its findings beside the terminal.
    fn review_pr(&mut self, pr: PrItem, window: &mut Window, cx: &mut Context<Self>) {
        self.review_pr_with(pr, None, window, cx);
    }

    /// Review with Claude, attended or started by a review window
    /// (`unattended`): that one posts by itself when it's done.
    fn review_pr_with(&mut self, pr: PrItem, unattended: Option<u32>, window: &mut Window, cx: &mut Context<Self>) {
        self.review_subject(crate::launch::Subject { id: pr.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url }, unattended, window, cx);
    }

    /// How well this window suits reviewing a PR in `repo`, for Marra to
    /// pick one: None when its org isn't the repo's or it has no harness;
    /// else whether a harness lists the repo, and whether it runs on a
    /// server (where sessions are meant to run).
    pub fn review_fit(&self, repo: &str) -> Option<(bool, bool)> {
        let owner = repo.split('/').next()?;
        if !self.org.as_deref().is_some_and(|o| o.eq_ignore_ascii_case(owner)) || self.projects.is_empty() {
            return None;
        }
        let listed = self.projects.iter().any(|p| p.repos.iter().any(|r| r == repo));
        let on_server = self.folder.as_ref().is_some_and(|f| f.location.server.is_some());
        Some((listed, on_server))
    }

    /// Review with Claude, from Marra's Needs you: a review request.
    pub fn review_for_marra(&mut self, subject: crate::launch::Subject, window: &mut Window, cx: &mut Context<Self>) {
        self.review_subject(subject, None, window, cx);
    }

    /// The window to review a PR in `repo` from: one whose harness lists
    /// the repo, one on a server first (where sessions are meant to run),
    /// as Marra and the review window choose. A window being updated can't
    /// be read, so call it from outside any (deferred).
    pub fn review_window_for(repo: &str, cx: &App) -> Option<gpui::WindowHandle<Workspace>> {
        cx.windows()
            .into_iter()
            .filter_map(|w| w.downcast::<Workspace>())
            .filter_map(|w| w.read(cx).ok().and_then(|ws| ws.review_fit(repo)).map(|fit| (w, fit)))
            .max_by_key(|(_, (listed, on_server))| (*listed, *on_server))
            .map(|(w, _)| w)
    }

    /// From Marra: a session's issue in its drawer, when this window's org
    /// has it. False when it hasn't (a PR, or another org's issue), so the
    /// caller opens it on GitHub instead.
    pub fn open_subject_for_marra(&mut self, subject: &crate::launch::Subject, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let found = self.issues.read(cx).issue(&subject.id).or_else(|| self.issues.read(cx).issue_by_number(&subject.repo, subject.number));
        let Some(issue) = found else { return false };
        self.navigate(Nav::Issues, false, window, cx);
        self.push_drawer(issue, cx);
        true
    }

    fn review_subject(&mut self, pr: crate::launch::Subject, unattended: Option<u32>, window: &mut Window, cx: &mut Context<Self>) {
        use crate::launch::{self, Flow, Subject};
        let repo_name = pr.repo.rsplit('/').next().unwrap_or(&pr.repo).to_string();
        if unattended.is_none() && self.show_session(&pr.id, Flow::Review, window, cx) {
            return;
        }
        let (Some(org), Some(harness)) = (self.org.clone(), self.harness_for(&pr.repo)) else {
            if unattended.is_none() {
                Self::no_harness(window, cx);
            }
            return;
        };
        let branch = format!("review-{}-{}", repo_name, pr.number);
        let subject = Subject { id: pr.id.clone(), repo: pr.repo.clone(), number: pr.number, title: pr.title.clone(), url: pr.url.clone() };
        let mut launch = self.new_launch(Flow::Review, format!("Review {}#{}", repo_name, pr.number), &org, &harness, branch.clone(), Some(subject));
        launch.unattended = unattended;
        if unattended.is_some() {
            // It posts by itself once its review is in.
            let _ = std::fs::create_dir_all(launch.dir());
            let _ = std::fs::write(launch.dir().join("auto-post"), "");
        }
        let brief = format!("# Review of {}#{}: {}\n\n{}\n", pr.repo, pr.number, pr.title, pr.url);
        let sensitive = crate::risk::sensitive_paths(&launch.harness_path, &pr.repo);
        let prompt = launch::review_prompt(&pr.repo, pr.number, &pr.title, &pr.url, &branch, &sensitive);
        self.start_launch(launch, &brief, &prompt, true, window, cx);
    }

    /// Work on This for several issues picked together: each in a tab of
    /// its own (or the session it has), after asking, since each runs claude.
    fn work_on_many(&mut self, issues: Vec<IssueItem>, window: &mut Window, cx: &mut Context<Self>) {
        if issues.len() == 1 {
            return self.work_on(issues[0].clone(), window, cx);
        }
        let list: Vec<String> = issues.iter().map(|i| format!("#{} {}", i.number, i.title)).collect();
        let detail = format!("{}\n\nEach runs Claude Code in a tab of its own, in a worktree of its own. An issue with a session already shows that one.", list.join("\n"));
        let answer = window.prompt(gpui::PromptLevel::Info, &format!("Start work on {} issues?", issues.len()), Some(&detail), &["Start Work", "Cancel"], cx);
        cx.spawn_in(window, async move |this, cx| {
            if answer.await == Ok(0) {
                this.update_in(cx, |this, window, cx| {
                    for issue in issues {
                        this.work_on(issue, window, cx);
                    }
                })
                .ok();
            }
        })
        .detach();
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

    // MARK: The schedule

    /// The schedule's clock: every half minute while the app is open, in
    /// the first window only.
    fn start_scheduler(&mut self, cx: &mut Context<Self>) {
        self._scheduler = Some(cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(std::time::Duration::from_secs(30)).await;
            let Some(window) = this.update(cx, |this, _| this.window_handle).ok().flatten() else { return };
            if window.update(cx, |_, window, cx| {
                this.update(cx, |this, cx| this.schedule_tick(window, cx)).ok();
            }).is_err() {
                return;
            }
        }));
    }

    /// Starts what's due, marks what was missed, moves sequences on, lets
    /// one waiting pull request through when the gap has passed, and fills
    /// review windows.
    fn schedule_tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        use crate::schedule::{due, RunState, Schedule};
        let mut sched = Schedule::load();
        let before = sched.clone();
        let now = chrono::Utc::now();
        let gap = sched.settings.gap_minutes;
        // The gap: the hook writes when it last let one through.
        let gap_dir = crate::schedule::gap_dir();
        if let Some(last) = std::fs::read_to_string(gap_dir.join("last")).ok().and_then(|t| t.trim().parse::<i64>().ok()).and_then(|t| chrono::DateTime::from_timestamp(t, 0)) {
            if sched.last_pr.is_none_or(|held| held < last) {
                sched.last_pr = Some(last);
            }
        }
        if sched.last_pr.is_none_or(|last| now - last >= chrono::Duration::minutes(gap as i64)) {
            let mut waiting: Vec<(std::time::SystemTime, String)> = std::fs::read_dir(gap_dir.join("requests"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.file_name().to_string_lossy().to_string())))
                .collect();
            waiting.sort();
            if let Some((_, id)) = waiting.first() {
                let _ = std::fs::create_dir_all(gap_dir.join("allow"));
                let _ = std::fs::write(gap_dir.join("allow").join(id), "");
                let _ = std::fs::remove_file(gap_dir.join("requests").join(id));
                sched.last_pr = Some(now);
                self.tell_session(id, "The gap since the last unattended pull request has passed: open this one now.", cx);
            }
        }
        if !sched.settings.paused_all {
            // The first tick after launch: anything whose time passed while
            // the app was closed is missed, never caught up. After that, an
            // item held for its decisions starts late, once it's ready.
            let first_tick = self.schedule_ticks == 0;
            let ready = |sched: &Schedule, id: &str| sched.readiness.get(id).is_some_and(|r| r.is_ready());
            // Issue starts.
            for i in 0..sched.starts.len() {
                let start = sched.starts[i].clone();
                if start.paused || start.run != RunState::Waiting {
                    continue;
                }
                match due(start.at, now) {
                    Some(false) if first_tick => {
                        sched.starts[i].run = RunState::Missed { at: now };
                        sched.note(&start.id, &start.issue.label(), "missed", "The app wasn't open.");
                    }
                    Some(_) if ready(&sched, &start.issue.id) => {
                        let run = self.start_scheduled(&start.issue, gap, window, cx, now, &sched);
                        let outcome = if matches!(run, RunState::Started { .. }) { "started" } else { "failed" };
                        sched.note(&start.id, &start.issue.label(), outcome, "");
                        sched.starts[i].run = run;
                    }
                    _ => {}
                }
            }
            // Sequences: one item at a time, each at least the interval after
            // the one before started. The next is the first that's ready: one
            // still needing decisions is skipped, and comes back once it's
            // ready.
            for i in 0..sched.sequences.len() {
                let mut seq = sched.sequences[i].clone();
                if seq.paused {
                    continue;
                }
                seq.runs.resize(seq.items.len(), RunState::Waiting);
                if seq.runs.iter().any(|r| matches!(r, RunState::Started { .. })) {
                    continue;
                }
                let last = seq.runs.iter().filter_map(|r| match r {
                    RunState::Done { at, .. } => Some(*at),
                    _ => None,
                }).max();
                let earliest = last.map(|at| at + chrono::Duration::minutes(seq.interval.max(5) as i64)).unwrap_or(seq.start);
                if now < earliest {
                    continue;
                }
                if last.is_none() && first_tick && due(seq.start, now) == Some(false) {
                    seq.runs[0] = RunState::Missed { at: now };
                    seq.paused = true;
                    sched.note(&seq.id, &seq.name, "missed", "The app wasn't open at its start.");
                    sched.sequences[i] = seq;
                    continue;
                }
                let Some(next) = (0..seq.items.len()).find(|&n| seq.runs[n] == RunState::Waiting && ready(&sched, &seq.items[n].id)) else { continue };
                let item = seq.items[next].clone();
                seq.runs[next] = self.start_scheduled(&item, gap, window, cx, now, &sched);
                // A failed item pauses the sequence, so later ones don't pile up.
                if matches!(seq.runs[next], RunState::Failed { .. }) {
                    seq.paused = true;
                }
                sched.note(&seq.id, &item.label(), if seq.paused { "failed" } else { "started" }, &seq.name);
                sched.sequences[i] = seq;
            }
            // Scouting what's been scheduled and not scouted yet.
            self.start_scouts(&mut sched, cx);
            // Recurring prompts.
            let today = chrono::Local::now().date_naive();
            let weekday = chrono::Datelike::weekday(&today).num_days_from_monday();
            for i in 0..sched.prompts.len() {
                let prompt = sched.prompts[i].clone();
                if prompt.paused || !prompt.weekdays.contains(&weekday) || prompt.last == Some(today) {
                    continue;
                }
                match due(crate::schedule::at(today, prompt.start), now) {
                    Some(true) => {
                        let started = self.start_prompt(&prompt.name, &prompt.text, window, cx);
                        sched.prompts[i].last = Some(today);
                        sched.note(&prompt.id, &prompt.name, if started { "started" } else { "failed" }, "");
                    }
                    Some(false) => {
                        sched.prompts[i].last = Some(today);
                        sched.note(&prompt.id, &prompt.name, "missed", "The app wasn't open.");
                    }
                    None => {}
                }
            }
            // A review window: one more review of a PR asked of you, up to
            // the number at once.
            if sched.window_now(chrono::Local::now()).is_some() {
                self.fill_review_window(sched.settings.reviews_at_once, gap, window, cx);
            }
        }
        if sched != before {
            sched.save();
        }
        // Done: started runs whose work is complete, checked off the main
        // thread every couple of minutes.
        self.schedule_ticks += 1;
        if self.schedule_ticks % 4 == 0 {
            self.check_scheduled_done(cx);
        }
    }

    /// Starts a scheduled issue unattended, with what scouting it found and
    /// the decisions made in its brief.
    fn start_scheduled(&mut self, issue: &crate::schedule::IssueRef, gap: u32, window: &mut Window, cx: &mut Context<Self>, now: chrono::DateTime<chrono::Utc>, sched: &crate::schedule::Schedule) -> crate::schedule::RunState {
        use crate::schedule::RunState;
        let Some(item) = self.issues.read(cx).issue(&issue.id) else {
            return RunState::Failed { reason: "The issue isn't in this window's org.".into(), at: now };
        };
        let prepared = sched.readiness.get(&issue.id).map(|r| r.brief());
        let repo = item.repo.clone();
        let started = match self.better_window(|ws| ws.review_fit(&repo), cx) {
            // Where its harness runs: another window's server.
            Some(other) => other
                .update(cx, |ws, window, cx| {
                    ws.prepared = prepared;
                    let started = ws.work_on_with(item, Some(gap), window, cx);
                    ws.prepared = None;
                    started
                })
                .ok()
                .flatten(),
            None => {
                self.prepared = prepared;
                let started = self.work_on_with(item, Some(gap), window, cx);
                self.prepared = None;
                started
            }
        };
        match started {
            Some(launch) => RunState::Started { launch, at: now },
            None => RunState::Failed { reason: "It already has a session, or no harness covers its repo.".into(), at: now },
        }
    }

    /// Scouts scheduled issues that haven't been, two at a time, off the
    /// main thread, each in the harness that covers its repo.
    fn start_scouts(&mut self, sched: &mut crate::schedule::Schedule, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        for issue in crate::schedule::unscouted(sched) {
            if self.scouting.len() >= 2 {
                break;
            }
            // Where the session it prepares would run: a server's harness
            // open in another window first.
            let elsewhere = self.better_window(|ws| ws.review_fit(&issue.repo), cx).and_then(|w| w.read(cx).ok().and_then(|ws| ws.place_for(&issue.repo)));
            let Some((server, path)) = elsewhere.or_else(|| self.place_for(&issue.repo)) else { continue };
            let _ = &org;
            sched.readiness.insert(issue.id.clone(), crate::schedule::Readiness { state: "scouting".into(), ..Default::default() });
            self.scouting.insert(issue.id.clone());
            let id = issue.id.clone();
            cx.spawn(async move |this, cx| {
                let found = cx.background_executor().spawn(async move { crate::schedule::scout(&path, &issue, server.as_ref()) }).await;
                let mut sched = crate::schedule::Schedule::load();
                sched.readiness.insert(id.clone(), found);
                sched.save();
                this.update(cx, |this, cx| {
                    this.scouting.remove(&id);
                    cx.notify();
                })
                .ok();
            })
            .detach();
        }
    }

    /// Kicks scouting off now, for what was just scheduled.
    fn scout_now(&mut self, cx: &mut Context<Self>) {
        let mut sched = crate::schedule::Schedule::load();
        let before = sched.clone();
        self.start_scouts(&mut sched, cx);
        if sched != before {
            sched.save();
        }
    }

    /// Marks started runs done once their work is: a PR merged, or open
    /// with its checks passing and no comments from others left open.
    fn check_scheduled_done(&mut self, cx: &mut Context<Self>) {
        use crate::schedule::{RunState, Schedule};
        let sched = Schedule::load();
        let started: Vec<String> = sched
            .starts
            .iter()
            .map(|s| &s.run)
            .chain(sched.sequences.iter().flat_map(|q| q.runs.iter()))
            .filter_map(|r| match r {
                RunState::Started { launch, .. } => Some(launch.clone()),
                _ => None,
            })
            .collect();
        if started.is_empty() {
            return;
        }
        cx.spawn(async move |_, cx| {
            cx.background_executor()
                .spawn(async move {
                    let Some(token) = crate::auth::token() else { return };
                    let viewer = crate::auth::saved_viewer().map(|v| v.login).unwrap_or_default();
                    let launches = crate::launch::saved();
                    let mut done = Vec::new();
                    for id in started {
                        let Some(launch) = launches.iter().find(|l| l.id == id) else { continue };
                        let urls = launch.pull_requests();
                        if urls.is_empty() {
                            continue;
                        }
                        let prs = crate::work_live::pull_requests(&token, &urls, &viewer);
                        let complete = prs.iter().any(|p| p.state == crate::work_panel::PrState::Merged)
                            || prs.iter().any(|p| p.state == crate::work_panel::PrState::Open && p.failed.is_empty() && p.pending.is_empty() && p.feedback.iter().all(|f| f.location.is_none()));
                        if complete {
                            done.push(id);
                        }
                    }
                    if done.is_empty() {
                        return;
                    }
                    let mut sched = Schedule::load();
                    let now = chrono::Utc::now();
                    // Done keeps when it started, so the next item's interval
                    // counts from there.
                    let _ = now;
                    let finish = |r: &mut RunState| {
                        if let RunState::Started { launch, at } = r {
                            if done.contains(launch) {
                                *r = RunState::Done { launch: launch.clone(), at: *at };
                            }
                        }
                    };
                    for s in &mut sched.starts {
                        finish(&mut s.run);
                    }
                    for q in &mut sched.sequences {
                        q.runs.iter_mut().for_each(finish);
                    }
                    sched.save();
                })
                .await;
        })
        .detach();
    }

    /// Starts one review of an open PR where you're a requested reviewer
    /// and none has been started, while fewer than `at_once` are running.
    fn fill_review_window(&mut self, at_once: usize, gap: u32, window: &mut Window, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        let Some(me) = self.viewer.as_ref().map(|v| v.login.clone()) else { return };
        // Running in any window: a review it starts may go to another.
        let counts = |sessions: &[Entity<SessionPage>], cx: &App| {
            sessions
                .iter()
                .filter(|s| {
                    let s = s.read(cx);
                    s.state != State::Ended && s.launch.as_ref().is_some_and(|l| l.flow == crate::launch::Flow::Review && l.unattended.is_some())
                })
                .count()
        };
        let own = window.window_handle();
        let others: usize = cx
            .windows()
            .into_iter()
            .filter(|h| *h != own)
            .filter_map(|h| h.downcast::<Workspace>())
            .filter_map(|h| h.read(cx).ok().map(|ws| counts(&ws.sessions, cx)))
            .sum();
        let running = counts(&self.sessions, cx) + others;
        if running >= at_once {
            return;
        }
        let reviewed: Vec<String> = crate::launch::saved().into_iter().filter(|l| l.flow == crate::launch::Flow::Review).filter_map(|l| l.subject.map(|s| s.id)).collect();
        let Ok(prs) = crate::prs::load(&org) else { return };
        let next = prs.into_iter().find(|p| {
            p.state == PrState::Open && !p.draft && !reviewed.contains(&p.id) && p.reviewers.iter().any(|r| r.requested && r.login.eq_ignore_ascii_case(&me))
        });
        // In the window that suits it (a server's, where its harness is
        // there), not this one's folder, which may be on this Mac.
        if let Some(pr) = next {
            let subject = crate::launch::Subject { id: pr.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url };
            let here = self.window_handle.and_then(|h| h.downcast::<Workspace>());
            cx.defer(move |cx| {
                let Some(target) = Self::review_window_for(&subject.repo, cx).or(here) else { return };
                let _ = target.update(cx, |workspace, window, cx| workspace.review_subject(subject, Some(gap), window, cx));
            });
        }
    }

    /// A recurring prompt, as an Ask started by the schedule. Whether it
    /// started.
    fn start_prompt(&mut self, name: &str, text: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let (Some(org), Some(harness)) = (self.org.clone(), self.project.clone().or_else(|| self.projects.first().map(|p| p.id.clone()))) else { return false };
        // In a window with the same harness on a server, when this one's
        // folder is on this Mac.
        let fit = |ws: &Workspace| (ws.org.as_deref() == Some(org.as_str()) && ws.projects.iter().any(|p| p.id.eq_ignore_ascii_case(&harness))).then(|| (true, ws.on_server()));
        if let Some(other) = self.better_window(fit, cx) {
            let (name, text) = (name.to_string(), text.to_string());
            return other.update(cx, |ws, window, cx| ws.start_prompt_in(&name, &text, &org, &harness, window, cx)).unwrap_or(false);
        }
        self.start_prompt_in(name, text, &org, &harness, window, cx)
    }

    /// A recurring prompt, started in this window's harness.
    fn start_prompt_in(&mut self, name: &str, text: &str, org: &str, harness: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        use crate::launch::{self, Flow};
        let (org, harness) = (org.to_string(), harness.to_string());
        let mut launch = self.new_launch(Flow::Ask, name.to_string(), &org, &harness, String::new(), None);
        launch.branch = format!("ask-{}-{}", chrono::Local::now().format("%Y-%m-%d"), launch.id[..8].to_lowercase());
        launch.unattended = Some(crate::schedule::Schedule::load().settings.gap_minutes);
        let mut brief = launch::ask_brief(name, &harness, &launch.harness_path, &launch.branch);
        brief.push_str(crate::schedule::UNATTENDED);
        let prompt = launch::ask_prompt(text, &launch.branch);
        let context = launch.dir().join("context");
        let _ = std::fs::create_dir_all(&context);
        let _ = std::fs::write(context.join("README.md"), format!("# {org}\n\nStarted by the schedule: {name}.\n"));
        self.start_launch(launch, &brief, &prompt, false, window, cx);
        true
    }

    /// Add to Schedule: the issues as a sequence from the next half hour,
    /// in the order picked; then the Schedule shows, to move it.
    fn schedule_issues(&mut self, issues: Vec<IssueItem>, window: &mut Window, cx: &mut Context<Self>) {
        use crate::schedule::IssueRef;
        // An epic stands for its open sub-issues, in the order set on
        // GitHub; read off the main thread, then the sequence is made.
        let picked: Vec<(IssueRef, bool)> = issues.iter().map(|i| (IssueRef { id: i.id.clone(), repo: i.repo.clone(), number: i.number, title: i.title.clone(), url: i.url.clone() }, i.sub_issues > 0)).collect();
        let epic_name = (issues.len() == 1 && issues[0].sub_issues > 0).then(|| format!("#{} {}", issues[0].number, issues[0].title));
        cx.spawn_in(window, async move |this, cx| {
            let items: Vec<IssueRef> = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token();
                    let mut items: Vec<IssueRef> = Vec::new();
                    for (issue, epic) in picked {
                        let subs = if epic { token.as_deref().and_then(|t| crate::schedule::sub_issues_in_order(t, &issue.id).ok()).unwrap_or_default() } else { Vec::new() };
                        let add = if subs.is_empty() { vec![issue] } else { subs };
                        for item in add {
                            if !items.iter().any(|x| x.id == item.id) {
                                items.push(item);
                            }
                        }
                    }
                    items
                })
                .await;
            this.update_in(cx, |this, window, cx| {
                if items.is_empty() {
                    return;
                }
                // Then when: the sheet shows what's on, and where these land.
                let name = epic_name.clone().unwrap_or_else(|| if items.len() == 1 { items[0].label() } else { format!("{} issues", items.len()) });
                let sheet = cx.new(|cx| crate::schedule_sheet::ScheduleSheet::new(name, items, window, cx));
                let subscription = cx.subscribe_in(&sheet, window, |this, _, _: &crate::schedule_sheet::SheetEvent, window, cx| {
                    this.schedule_sheet = None;
                    // Scouting starts as soon as it's scheduled.
                    this.scout_now(cx);
                    this.focus_current(window, cx);
                    cx.notify();
                });
                this.schedule_sheet = Some((sheet, subscription));
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Run Now from the Schedule page: an issue start or a sequence's next
    /// item starts now, and a recurring prompt opens its Ask.
    fn run_now(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        use crate::schedule::{RunState, Schedule};
        let mut sched = Schedule::load();
        let gap = sched.settings.gap_minutes;
        let now = chrono::Utc::now();
        if let Some(i) = sched.starts.iter().position(|s| s.id == id) {
            let start = sched.starts[i].clone();
            // As the schedule starts it: where its harness runs.
            let run = self.start_scheduled(&start.issue, gap, window, cx, now, &sched);
            sched.starts[i].run = run;
            sched.note(id, &start.issue.label(), "started", "Run Now");
        } else if let Some(i) = sched.sequences.iter().position(|q| q.id == id) {
            let mut seq = sched.sequences[i].clone();
            seq.runs.resize(seq.items.len(), RunState::Waiting);
            // Missed or failed items go again; else the next waiting one.
            if let Some(next) = seq.runs.iter().position(|r| matches!(r, RunState::Waiting | RunState::Missed { .. } | RunState::Failed { .. })) {
                let item = seq.items[next].clone();
                seq.runs[next] = self.start_scheduled(&item, gap, window, cx, now, &sched);
                seq.paused = false;
                sched.note(id, &item.label(), "started", "Run Now");
            }
            sched.sequences[i] = seq;
        } else if let Some(p) = sched.prompts.iter().find(|p| p.id == id).cloned() {
            let started = self.start_prompt(&p.name, &p.text, window, cx);
            sched.note(id, &p.name, if started { "started" } else { "failed" }, "Run Now");
        }
        sched.save();
    }

    /// Types a message into a session's terminal, by its launch.
    fn tell_session(&mut self, launch_id: &str, text: &str, cx: &mut Context<Self>) {
        if let Some(page) = self.sessions.iter().find(|p| p.read(cx).launch.as_ref().is_some_and(|l| l.id == launch_id)).cloned() {
            page.update(cx, |page, cx| page.tell(text, cx));
        }
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

    /// New Issue, from the Issues page, the + menu, or an issue's drawer
    /// as New Sub-issue (`parent`): a subpage over the current tab. A
    /// draft kept from before resumes rather than starting again.
    fn open_new_issue(&mut self, parent: Option<IssueItem>, window: &mut Window, cx: &mut Context<Self>) {
        use crate::new_issue::{NewIssueEvent, NewIssueForm, Start};
        let Some(org) = self.org.clone() else { return };
        if self.viewer.is_none() {
            self.sync.error = Some("Sign in to GitHub to create issues.".into());
            return cx.notify();
        }
        let Some(tab) = self.tabs.get(self.active).map(|t| t.id) else { return };
        let back_title = self.tabs.get(self.active).map(|t| t.name.clone().unwrap_or_else(|| t.nav.title().to_string())).unwrap_or_default();
        if let Some(sub) = self.new_issue.as_mut() {
            sub.tab = tab;
            sub.showing = true;
            sub.form.update(cx, |form, cx| {
                form.set_back_title(back_title);
                if let Some(parent) = parent {
                    form.set_parent(parent, cx);
                }
                form.focus(window, cx);
            });
            return cx.notify();
        }
        let (repo, open_issues) = self.issues.read(cx).new_issue_start();
        let start = Start {
            repo: parent.as_ref().map(|p| p.repo.clone()).or(repo),
            parent,
            open_issues,
            board_number: self.workflow.project_number,
            viewer: self.viewer.as_ref().map(|v| v.login.clone()),
            projects: self.projects.clone(),
            back_title,
        };
        let form = cx.new(|cx| NewIssueForm::new(org, start, window, cx));
        let subscription = cx.subscribe_in(&form, window, |this, _, event: &NewIssueEvent, window, cx| {
            match event {
                NewIssueEvent::Back => {
                    if let Some(sub) = this.new_issue.as_mut() {
                        sub.showing = false;
                    }
                    this.focus_current(window, cx);
                }
                NewIssueEvent::Created(created) => {
                    this.new_issue = None;
                    this.show_created(created.clone(), cx);
                }
                NewIssueEvent::Cancel => {
                    this.new_issue = None;
                    this.focus_current(window, cx);
                }
            }
            cx.notify();
        });
        self.new_issue = Some(NewIssueSubpage { form, _subscription: subscription, tab, showing: true });
        cx.notify();
    }

    /// The New Issue subpage, when it's showing over the tab in view.
    fn new_issue_showing(&self) -> Option<Entity<crate::new_issue::NewIssueForm>> {
        let tab = self.tabs.get(self.active)?.id;
        self.new_issue.as_ref().filter(|s| s.showing && s.tab == tab).map(|s| s.form.clone())
    }

    /// Fetches a new issue into the store, then lists and opens it.
    fn show_created(&mut self, created: crate::new_issue::Created, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        cx.spawn(async move |this, cx| {
            let id = created.id.clone();
            let issue = cx
                .background_executor()
                .spawn(async move {
                    let token = auth::token()?;
                    crate::sync::refresh_item(&token, &org, &id).ok()?;
                    crate::issues::load_one(&org, &id)
                })
                .await;
            this.update(cx, |this, cx| {
                this.issues.update(cx, |page, cx| page.reload(cx));
                match issue {
                    Some(issue) => {
                        this.drawers.clear();
                        this.push_drawer(issue, cx);
                    }
                    None => cx.open_url(&created.url),
                }
            })
            .ok();
        })
        .detach();
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
        use crate::launch::{self, Flow, Subject};
        let Some(org) = self.org.clone() else { return };
        let harness = started.harness.clone();
        match started.flow {
            Flow::Plan => {
                let topic = started.text.clone();
                let slug = launch::slug(&topic, 40);
                let branch = format!("plan-{}", if slug.is_empty() { "plan" } else { slug.as_str() });
                let subject = started.issue.as_ref().map(|i| Subject { id: i.id.clone(), repo: i.repo.clone(), number: i.number, title: i.title.clone(), url: i.url.clone() });
                let launch = self.new_launch(Flow::Plan, format!("Plan: {}", launch::short_title(&topic)), &org, &harness, branch.clone(), subject);
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
                let mut launch = self.new_launch(Flow::Ask, format!("Ask: {title}"), &org, &harness, String::new(), None);
                launch.branch = format!("ask-{}-{}", chrono::Local::now().format("%Y-%m-%d"), launch.id[..8].to_lowercase());
                let brief = launch::ask_brief(&title, &harness, &launch.harness_path, &launch.branch);
                let prompt = launch::ask_prompt(&started.text, &launch.branch);
                // What Gannin puts in context/: here, only what it holds.
                let context = launch.dir().join("context");
                let _ = std::fs::create_dir_all(&context);
                let _ = std::fs::write(
                    context.join("README.md"),
                    format!("# {org}\n\nGannin's org view isn't written here yet: use `gh` and the code for what the question needs.\n\nWritten {}.\n", chrono::Utc::now().to_rfc3339()),
                );
                self.start_launch(launch, &brief, &prompt, false, window, cx);
            }
            Flow::QuickChange => {
                let Some(repo) = started.repo.clone() else { return };
                let title = if started.extra.is_empty() { launch::short_title(&started.text) } else { started.extra.clone() };
                let mut launch = self.new_launch(Flow::QuickChange, format!("Quick change: {title}"), &org, &harness, String::new(), None);
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
        // Two windows on one org sync it once.
        if !SYNCING.lock().map(|mut s| s.insert(org.clone())).unwrap_or(false) {
            return;
        }
        let viewer = self.viewer.as_ref().map(|v| v.login.clone());
        self.sync.running = true;
        self.sync.error = None;
        self.sync.org = Some(org.clone());
        self.sync.progress = Default::default();
        let progress = self.sync.progress.clone();
        let options = crate::sync::Options {
            lookback_days: self.sync.prefs.lookback_days.unwrap_or_else(crate::sync::default_lookback_days),
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
            if let Ok(mut syncing) = SYNCING.lock() {
                syncing.remove(&org);
            }
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
                Page::AgentMetrics(page) => page.update(cx, |page, cx| page.reload(cx)),
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

    /// The sync button: syncs now and shows the Sync panel. The background
    /// syncs and Command-R leave it as it is.
    fn refresh(&mut self, cx: &mut Context<Self>) {
        self.sync.open = true;
        self.sync_now(None, false, cx);
        self.refresh_runs(cx);
        cx.notify();
    }

    /// Fetches the workflow runs for every CI tab now, whatever their age.
    fn refresh_runs(&mut self, cx: &mut Context<Self>) {
        for page in self.pages() {
            if let Page::Ci(page) = page {
                page.update(cx, |page, cx| page.sync_runs(true, cx));
            }
        }
    }

    /// Command-R (View › Refresh): syncs now in the background, the panel
    /// left as it is; the sync button's bar shows it going, and red if it fails.
    fn refresh_quietly(&mut self, cx: &mut Context<Self>) {
        self.sync_now(None, false, cx);
        self.refresh_runs(cx);
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
        let lookback = prefs.lookback_days.unwrap_or_else(crate::sync::default_lookback_days);
        let step = |id: &'static str, label: &'static str, by: i64| {
            chip(id.into(), label.into(), false).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                let now = this.sync.prefs.lookback_days.unwrap_or_else(crate::sync::default_lookback_days);
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
                "Synced into its own copy of the caches."
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
                            .child("Signing out here leaves the Swift app signed in: each keeps its own sign-in."),
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
            // Not while it's moving to a server: the move needs its folder
            // and the tab is replaced when it's done.
            if self.session(id, cx).is_some_and(|p| p.read(cx).moving.is_some()) {
                return;
            }
            if let Some(review) = self.session(id, cx).and_then(|p| p.read(cx).review()) {
                return self.close_review(id, review, window, cx);
            }
            if let Some(work) = self.session(id, cx).and_then(|p| p.read(cx).work()) {
                return self.close_work(id, work, window, cx);
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

    /// Closing a Work on This tab says what it leaves: claude stops, and
    /// the worktree with anything not committed or pushed stays, to pick up
    /// again from the issue. With every PR merged it offers Finish.
    fn close_work(&mut self, id: u32, work: Entity<crate::work_panel::WorkPanel>, window: &mut Window, cx: &mut Context<Self>) {
        let (notes, merged) = work.read(cx).closing();
        let title = self.session(id, cx).map(|p| p.read(cx).title(cx)).unwrap_or_default();
        let mut detail = String::new();
        if !notes.is_empty() {
            detail.push_str(&notes.join("\n"));
            detail.push_str("\n\n");
        }
        detail.push_str("Claude stops. The worktree and its changes stay, and Work on This on the issue picks the session up again.");
        let buttons: &[&str] = if merged { &["Finish and Remove Worktrees", "Close", "Cancel"] } else { &["Close", "Cancel"] };
        let answer = window.prompt(gpui::PromptLevel::Warning, &format!("Close \u{201c}{title}\u{201d}?"), Some(&detail), buttons, cx);
        cx.spawn_in(window, async move |this, cx| {
            let choice = answer.await.ok();
            this.update_in(cx, |this, window, cx| {
                let close = if merged { choice == Some(1) } else { choice == Some(0) };
                if merged && choice == Some(0) {
                    work.update(cx, |work, cx| work.start_finish(window, cx));
                } else if close {
                    if let Some(index) = this.tabs.iter().position(|t| t.nav == Nav::Session(id)) {
                        this.remove_tab(index, cx);
                    }
                }
            })
            .ok();
        })
        .detach();
    }

    /// New Window: another window, which opens a folder of its own (Open
    /// Recent); it opens again after a relaunch until it's closed.
    fn new_window(&mut self, cx: &mut Context<Self>) {
        let open: Vec<usize> = cx.windows().into_iter().filter_map(|h| h.downcast::<Workspace>()).filter_map(|h| h.read(cx).ok().map(|w| w.slot)).chain(std::iter::once(self.slot)).collect();
        let slot = open.iter().chain(crate::state::extra_slots().iter()).max().copied().unwrap_or(0) + 1;
        let saved = SavedState { org: self.org.clone(), ..SavedState::default() };
        let options = window_options(cx);
        let opened = cx.open_window(options, move |window, cx| cx.new(|cx| Workspace::new(saved, slot, window, cx)));
        // A new window opens a folder of its own, as Zed's does.
        if let Ok(handle) = opened {
            handle.update(cx, |workspace, window, cx| workspace.open_switcher(Pick::Folder, window, cx)).ok();
        }
    }

    /// Opens the windows besides the first that were open when it quit.
    pub fn reopen_windows(cx: &mut App) {
        for slot in crate::state::extra_slots() {
            let saved = SavedState::load_slot(slot);
            let options = window_options(cx);
            let _ = cx.open_window(options, move |window, cx| cx.new(|cx| Workspace::new(saved, slot, window, cx)));
        }
    }

    /// Quitting with sessions running asks first, as Gannin's quit guard does.
    /// Whether the window can close now: at once when nothing's running in
    /// it, else after asking, closing it if the person says so.
    /// `this` is marked closed before its state goes, when it closes after
    /// asking; when it can close at once the caller marks it.
    fn confirm_close(running: Vec<Entity<SessionPage>>, slot: usize, this: gpui::WeakEntity<Self>, window: &mut Window, cx: &mut App) -> bool {
        // The last window's state stays: closing it quits, and it should
        // come back at the next launch, as quitting brings every window back.
        let own = window.window_handle();
        let others = cx.windows().into_iter().any(|h| h != own && h.downcast::<Workspace>().is_some());
        let forget = move || {
            if others {
                remove_slot(slot);
            }
        };
        if running.is_empty() {
            forget();
            return true;
        }
        let message = match running.len() {
            1 => "Close this window and end the session that's running in it?".to_string(),
            n => format!("Close this window and end the {n} sessions running in it?"),
        };
        let detail = Self::ending_detail(&running, cx);
        let answer = window.prompt(gpui::PromptLevel::Warning, &message, Some(&detail), &["Close Window", "Cancel"], cx);
        window
            .spawn(cx, async move |cx| {
                if answer.await == Ok(0) {
                    this.update(cx, |workspace, _| workspace.closed = true).ok();
                    forget();
                    cx.update(|window, _| window.remove_window()).ok();
                }
            })
            .detach();
        false
    }

    /// Close Window: as the window's close button, asking first while
    /// sessions run in it.
    pub fn close_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if Self::confirm_close(self.running(cx), self.slot, cx.entity().downgrade(), window, cx) {
            self.closed = true;
            window.remove_window();
        }
    }

    pub fn quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Every window's sessions end with the app.
        let mut running = self.running(cx);
        let own = window.window_handle();
        for handle in cx.windows() {
            if handle == own {
                continue;
            }
            if let Some(other) = handle.downcast::<Workspace>() {
                if let Ok(workspace) = other.read(cx) {
                    running.extend(workspace.running(cx));
                }
            }
        }
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
            // Its mirror stops with it, if it ran on a server.
            if let Some(launch) = self.sessions.iter().find(|s| s.read(cx).id == id).and_then(|s| s.read(cx).launch.clone()) {
                crate::servers::unwatch(&launch.id);
            }
            self.sessions.retain(|s| s.read(cx).id != id);
            self.sync_reviewing(cx);
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
        let is_issue = matches!(item, DrawerItem::Issue(_));
        let on_github = !matches!(item, DrawerItem::Doc(_));
        self.drawers.push(Drawer { seq, item, text: None });
        // What's cached shows at once, off the main thread; then, signed in,
        // the item is fetched from GitHub and the drawer (and for an issue,
        // the list) shows it as it is now.
        let org = self.org.clone();
        let live = on_github && self.viewer.is_some() && !crate::github::should_hold_off();
        cx.spawn(async move |this, cx| {
            let cached_id = id.clone();
            let cached_org = org.clone().unwrap_or_default();
            let text = cx.background_executor().spawn(async move { detail::load_text(&cached_org, &cached_id).map(Arc::new) }).await;
            let shown = this
                .update(cx, |this, cx| {
                    let Some(drawer) = this.drawers.iter_mut().find(|d| d.seq == seq) else { return false };
                    drawer.text = Some(text);
                    cx.notify();
                    true
                })
                .unwrap_or(false);
            let Some(org) = org.filter(|_| live && shown) else { return };
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let token = auth::token()?;
                    let text = crate::sync::refresh_item(&token, &org, &id).ok()?;
                    let issue = if is_issue { crate::issues::load_one(&org, &id) } else { None };
                    Some((text, issue))
                })
                .await;
            let Some((text, issue)) = fetched else { return };
            this.update(cx, |this, cx| {
                if let Some(drawer) = this.drawers.iter_mut().find(|d| d.seq == seq) {
                    if let Some(text) = text {
                        drawer.text = Some(Some(Arc::new(text)));
                    }
                    if let (Some(fresh), DrawerItem::Issue(item)) = (issue.clone(), &mut drawer.item) {
                        item.issue = fresh;
                    }
                }
                if issue.is_some() {
                    this.issues.update(cx, |page, cx| page.reload(cx));
                }
                cx.notify();
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
                let parent = issue.clone();
                actions.push(
                    action("new-sub-issue", "New Sub-issue".into(), "Create an issue under this one, drafted with Claude".into())
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.open_new_issue(Some(parent.clone()), window, cx)))
                        .into_any_element(),
                );
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

    /// The window's projects: with a folder open, its harnesses that are
    /// the org's (named as the org's settings name them, else by their
    /// project file or folder); without one, every project of the org.
    fn folder_projects(&self, known: Vec<Project>) -> Vec<Project> {
        let (Some(folder), Some(org)) = (&self.folder, &self.org) else { return known };
        folder
            .harnesses_of(org)
            .into_iter()
            .map(|h| {
                let id = h.repo_id(org);
                known.iter().find(|p| p.id.eq_ignore_ascii_case(&id)).cloned().unwrap_or_else(|| Project {
                    name: h.name.clone().unwrap_or_else(|| h.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| id.clone())),
                    repos: h.repos.clone(),
                    id,
                })
            })
            .collect()
    }

    /// A new session, where the window's folder is: its harness's checkout
    /// there, and its server.
    fn new_launch(&self, flow: crate::launch::Flow, title: String, org: &str, harness: &str, branch: String, subject: Option<crate::launch::Subject>) -> crate::launch::Launch {
        let mut launch = crate::launch::Launch::new(flow, title, org, harness, branch, subject);
        if let Some(folder) = &self.folder {
            if let Some(found) = folder.harnesses.iter().find(|h| h.repo_id(org).eq_ignore_ascii_case(harness)) {
                launch.harness_path = found.path.clone();
            }
            launch.server = folder.location.server.clone();
        }
        launch
    }

    /// Opens a folder in this window, as Zed opens a project: reads what's
    /// in it (off the main thread, over ssh for a server's), takes its org
    /// and its harnesses as the projects, and offers to set up a harness
    /// when there's none. `asked`: the person picked it, so a failure says so.
    fn open_folder(&mut self, location: crate::folders::Location, asked: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.switcher = None;
        self.opening = Some(location.place());
        cx.notify();
        let reading = location.clone();
        cx.spawn_in(window, async move |this, cx| {
            let opened = cx.background_executor().spawn(async move { crate::folders::inspect(&reading) }).await;
            this.update_in(cx, |this, window, cx| {
                this.opening = None;
                match opened {
                    Ok(opened) => this.opened(opened, window, cx),
                    Err(error) => {
                        if asked {
                            let _ = window.prompt(gpui::PromptLevel::Warning, &format!("Couldn't open {}", location.name()), Some(&error), &["OK"], cx);
                        }
                        cx.notify();
                    }
                }
            })
            .ok();
        })
        .detach();
    }

    fn opened(&mut self, opened: crate::folders::Opened, window: &mut Window, cx: &mut Context<Self>) {
        let org = opened.org(&self.orgs);
        crate::folders::remember(&opened, org.as_deref());
        if let Some(server) = opened.location.server.clone().filter(|s| crate::servers::last_check(s).is_none()) {
            self.check_server(server, cx);
        }
        self.saved_folder = Some(opened.location.clone());
        let none = opened.harnesses.is_empty();
        self.folder = Some(opened.clone());
        match org.clone() {
            Some(org) if self.org.as_deref() != Some(org.as_str()) => self.choose_org(org, window, cx),
            _ => self.load_settings(cx),
        }
        if none {
            self.offer_harness(opened, org, window, cx);
        }
        cx.notify();
    }

    /// A folder with no harness: asks whose it is when that's not clear,
    /// then offers Gannin's starter harness, set up as a local git repo.
    fn offer_harness(&mut self, opened: crate::folders::Opened, org: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let orgs = self.orgs.clone();
        let target = crate::folders::new_harness_path(&opened);
        let place = crate::folders::Location { path: target.clone(), server: opened.location.server.clone() }.place();
        let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "harness".into());
        cx.spawn_in(window, async move |this, cx| {
            let org = match org {
                Some(org) => org,
                None if orgs.len() == 1 => orgs[0].clone(),
                None => {
                    let mut buttons: Vec<&str> = orgs.iter().take(6).map(String::as_str).collect();
                    buttons.push("Cancel");
                    let Ok(answer) = this.update_in(cx, |_, window, cx| {
                        window.prompt(gpui::PromptLevel::Info, "Which org is this folder's harness for?", Some("There's no harness here yet, and nothing in the folder says whose it is."), &buttons, cx)
                    }) else {
                        return;
                    };
                    match answer.await {
                        Ok(i) if i < orgs.len().min(6) => orgs[i].clone(),
                        _ => return,
                    }
                }
            };
            let detail = format!(
                "There's no harness in {}. Set one up at {place}: the starter files Gannin's Set Up Harness makes (CLAUDE.md, plans, requirements, decisions, findings, skills, prompts and Gannin's settings), committed to a new git repo.\n\nNothing goes to GitHub. Create {org}/{name} there and push when you're ready.",
                opened.location.place()
            );
            let Ok(answer) = this.update_in(cx, |_, window, cx| window.prompt(gpui::PromptLevel::Info, "Set up a harness here?", Some(&detail), &["Set Up Harness", "Not Now"], cx)) else {
                return;
            };
            if answer.await != Ok(0) {
                return;
            }
            let (folder, wanted) = (opened.clone(), org.clone());
            let made = cx.background_executor().spawn(async move { crate::folders::set_up_harness(&folder, &wanted) }).await;
            this.update_in(cx, |this, window, cx| match made {
                Ok(_) => this.open_folder(opened.location.clone(), true, window, cx),
                Err(error) => {
                    let _ = window.prompt(gpui::PromptLevel::Warning, "Couldn't set up the harness", Some(&error), &["OK"], cx);
                }
            })
            .ok();
        })
        .detach();
    }

    /// Open Folder: the system's folder picker, for a folder on this Mac.
    fn pick_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.switcher = None;
        let paths = cx.prompt_for_paths(gpui::PathPromptOptions { files: false, directories: true, multiple: false, prompt: Some("Open".into()) });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            let Some(path) = paths.into_iter().next() else { return };
            this.update_in(cx, |this, window, cx| this.open_folder(crate::folders::Location::here(path), true, window, cx)).ok();
        })
        .detach();
        cx.notify();
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
                Page::SchedulePreview(page) => page.update(cx, |page, cx| page.set_org(Some(org.clone()), cx)),
                Page::AgentMetrics(page) => page.update(cx, |page, cx| page.set_org(Some(org.clone()), cx)),
                _ => {}
            }
        }
        self.load_settings(cx);
        window.focus(&self.focus, cx);
        cx.notify();
    }

    fn open_switcher(&mut self, pick: Pick, window: &mut Window, cx: &mut Context<Self>) {
        let current = match pick {
            Pick::Folder => self.folder.as_ref().map(|f| f.location.key()),
            Pick::Project => self.project.clone(),
        };
        let highlighted = self.switcher_items(pick, "").iter().position(|(_, key)| Some(key) == current.as_ref()).unwrap_or(0);
        self.switcher = Some(Switcher { pick, query: String::new(), highlighted, server: None });
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
            Pick::Folder => crate::folders::recent().into_iter().map(|r| (r.location.name(), r.location.key())).collect(),
            Pick::Project => self.projects.iter().map(|p| (p.name.clone(), p.id.clone())).collect(),
        };
        all.into_iter().filter(|(label, _)| label.to_lowercase().contains(&query)).collect()
    }

    fn choose(&mut self, pick: Pick, key: String, window: &mut Window, cx: &mut Context<Self>) {
        match pick {
            Pick::Folder => {
                if let Some(recent) = crate::folders::recent().into_iter().find(|r| r.location.key() == key) {
                    self.open_folder(recent.location, true, window, cx);
                }
            }
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
            // Typing a path on a server: Escape goes back to the list.
            "escape" if switcher.server.is_some() => {
                cx.stop_propagation();
                if let Some(switcher) = self.switcher.as_mut() {
                    switcher.server = None;
                    switcher.query.clear();
                    switcher.highlighted = 0;
                }
                cx.notify();
                return;
            }
            "enter" if switcher.server.is_some() => {
                cx.stop_propagation();
                let path = switcher.query.trim().to_string();
                if let (Some(server), false) = (switcher.server.clone(), path.is_empty()) {
                    self.open_folder(crate::folders::Location { path: PathBuf::from(path), server: Some(server) }, true, window, cx);
                }
                return;
            }
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
        // The folder open, as Zed names a window's project; its org beside
        // it when the name doesn't say. A window from before folders shows
        // its org until its folder's read.
        let label = match (&self.opening, &self.folder, &self.org) {
            (Some(place), _, _) => format!("Opening {place}"),
            (None, Some(folder), _) => folder.location.name(),
            (None, None, Some(org)) => org.clone(),
            (None, None, None) => "Open a Folder".into(),
        };
        let org_beside = self.folder.as_ref().zip(self.org.as_ref()).filter(|(f, org)| !f.location.name().eq_ignore_ascii_case(org)).map(|(_, org)| org.clone());
        let server = self.folder.as_ref().and_then(|f| f.location.server.clone());
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
            // A window on a server has its host first, as Zed's.
            .when_some(server, |d, server| d.child(self.host_button(&server, theme, cx)))
            .child(self.switcher_button(Pick::Folder, label, theme, cx))
            .when_some(org_beside, |d, org| d.child(div().text_sm().text_color(theme.tertiary).child(org)))
            // Open Remote Folder from a window on this Mac shows the popover here.
            .when(self.folder.as_ref().is_none_or(|f| f.location.server.is_none()), |d| d.when_some(self.remotes_popover(), |d, popover| d.child(popover)))
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

    /// The server a window's folder is on, as Zed's remote project button:
    /// its icon with the last check's dot, and its name. It opens Remotes.
    fn host_button(&self, server: &crate::servers::Server, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (_, tint) = crate::remotes::status(crate::servers::last_check(server).as_ref(), self.checking_servers.contains(&server.key()), theme);
        let open = self.remotes.is_some();
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .id("host-button")
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1p5()
                    .cursor_pointer()
                    .text_sm()
                    .when(open, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        cx.stop_propagation();
                        this.toggle_remotes(window, cx);
                    }))
                    .child(
                        div()
                            .relative()
                            .flex_none()
                            .child(gpui::svg().path("icons/server.svg").size(px(14.)).text_color(theme.fg))
                            .child(div().absolute().right(px(-2.)).bottom(px(-1.)).size(px(6.)).rounded_full().border_1().border_color(theme.sidebar).bg(tint)),
                    )
                    .child(div().max_w(px(140.)).truncate().child(server.name())),
            )
            .when_some(self.remotes_popover(), |d, popover| d.child(popover))
    }

    fn remotes_popover(&self) -> Option<impl IntoElement> {
        let remotes = self.remotes.clone()?;
        Some(deferred(anchored().snap_to_window_with_margin(px(8.)).child(remotes)).with_priority(2))
    }

    fn toggle_remotes(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.remotes.is_some() {
            return self.close_remotes(window, cx);
        }
        self.switcher = None;
        let remotes = cx.new(|cx| crate::remotes::Remotes::new(window, cx));
        self._remotes_subscription = Some(cx.subscribe_in(&remotes, window, |this, _, event: &crate::remotes::RemotesEvent, window, cx| match event {
            crate::remotes::RemotesEvent::Dismiss => this.close_remotes(window, cx),
            crate::remotes::RemotesEvent::Open(location) => {
                this.close_remotes(window, cx);
                this.open_folder(location.clone(), true, window, cx);
            }
            crate::remotes::RemotesEvent::OpenOn(server) => {
                this.close_remotes(window, cx);
                this.open_switcher(Pick::Folder, window, cx);
                if let Some(switcher) = this.switcher.as_mut() {
                    switcher.server = Some(server.clone());
                    switcher.query = "~/".into();
                    switcher.highlighted = 0;
                }
            }
        }));
        window.focus(&remotes.read(cx).focus_handle(), cx);
        self.remotes = Some(remotes);
        cx.notify();
    }

    fn close_remotes(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.remotes = None;
        self._remotes_subscription = None;
        window.focus(&self.focus, cx);
        cx.notify();
    }

    /// Checks a server off the main thread, for the host button's dot.
    fn check_server(&mut self, server: crate::servers::Server, cx: &mut Context<Self>) {
        if !self.checking_servers.insert(server.key()) {
            return;
        }
        let key = server.key();
        cx.spawn(async move |this, cx| {
            cx.background_executor().spawn(async move { crate::servers::check(&server) }).await;
            this.update(cx, |this, cx| {
                this.checking_servers.remove(&key);
                cx.notify();
            })
            .ok();
        })
        .detach();
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
                        Pick::Folder => "folder-button",
                        Pick::Project => "project-button",
                    })
                    .px_2()
                    .py_0p5()
                    .rounded_md()
                    .cursor_pointer()
                    .map(|d| {
                        if chip {
                            d.text_color(theme.selected).when(open, |d| d.bg(theme.row_selected))
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
            // Tabs down a column on the left, or across the top (View › Toggle Tabs on Left).
            .child(toggle(
                "toggle-tabs-left",
                if self.tabs_on_left { "icons/threads_sidebar_left_open.svg" } else { "icons/threads_sidebar_left_closed.svg" },
                "Tabs on Left",
                self.tabs_on_left,
                cx,
                |this, _| this.tabs_on_left = !this.tabs_on_left,
            ))
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
                                        .child("Not loaded yet")
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
        // The tab New Issue shows over says so.
        if self.new_issue.as_ref().is_some_and(|s| s.showing && s.tab == tab.id) {
            return "New Issue".into();
        }
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
            .child(self.tab_search_box(theme, cx))
            .child(self.tabs(false, theme, cx))
            .child(self.pause_controls(theme, cx))
            .child(self.new_menu(theme, cx))
    }

    /// Pause All stops every session that's working, as Esc in each would;
    /// Resume All tells just those to carry on. Ended ones, and ones you've
    /// since spoken to (working again), are left alone.
    fn pause_all(&mut self, cx: &mut Context<Self>) {
        for session in self.sessions.clone() {
            if session.read(cx).state == State::Working {
                let id = session.read(cx).id;
                session.update(cx, |s, cx| s.interrupt(cx));
                self.paused_sessions.insert(id);
            }
        }
        cx.notify();
    }

    fn resume_all(&mut self, cx: &mut Context<Self>) {
        let paused = std::mem::take(&mut self.paused_sessions);
        for session in self.sessions.clone() {
            let page = session.read(cx);
            if paused.contains(&page.id) && !matches!(page.state, State::Ended | State::Working) {
                session.update(cx, |s, cx| s.tell(RESUME, cx));
            }
        }
        cx.notify();
    }

    /// Pause All and Resume All, beside the "+": each shows only when it
    /// would do something.
    fn pause_controls(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let working = self.sessions.iter().filter(|s| s.read(cx).state == State::Working).count();
        let paused = self.paused_sessions.iter().filter(|id| self.session(**id, cx).is_some_and(|s| s.read(cx).state != State::Ended)).count();
        let button = |id: &'static str, label: String, tip: String| {
            div()
                .id(id)
                .flex_none()
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_sm()
                .cursor_pointer()
                .text_color(theme.secondary)
                .hover(|s| s.bg(theme.row_selected).text_color(theme.fg))
                .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
                .child(label)
        };
        div()
            .flex_none()
            .h_full()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .when(working > 0 || paused > 0, |d| d.px_1().border_l_1().border_color(theme.border))
            .when(working > 0, |d| {
                d.child(button("pause-all", format!("Pause All ({working})"), "Stop every working session, as Esc in each".into()).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    this.pause_all(cx);
                })))
            })
            .when(paused > 0, |d| {
                d.child(button("resume-all", format!("Resume All ({paused})"), "Tell the sessions Pause All stopped to carry on".into()).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    this.resume_all(cx);
                })))
            })
    }

    /// The tabs in a column on the left (View › Toggle Tabs on Left): the
    /// bar's filter, search and "+" across its top, the tabs listed below,
    /// each group's heading a row of its own.
    fn tab_column(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .w(px(240.))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .bg(theme.sidebar)
            .border_r_1()
            .border_color(theme.border)
            .child(
                div()
                    .h(px(32.))
                    .flex_none()
                    .flex()
                    .flex_row()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(self.tab_filter_menu(theme, cx))
                    .child(div().flex_1().min_w_0().h_full().child(self.tab_search_box(theme, cx)))
                    .child(self.pause_controls(theme, cx))
                    .child(self.new_menu(theme, cx)),
            )
            .child(self.tabs(true, theme, cx))
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
                                .child(item("new-menu-issue", "New Issue", None, |this, window, cx| this.open_new_issue(None, window, cx)))
                                .child(div().my_1().h(px(1.)).bg(theme.border))
                                .child(item("new-menu-review", "Review a Pull Request", None, |this, window, cx| this.open_pr_picker(window, cx)))
                                .child(div().my_1().h(px(1.)).bg(theme.border))
                                .child(item("new-menu-window", "New Window", Some("⇧⌘N"), |this, _, cx| this.new_window(cx))),
                        ),
                    )
                    .with_priority(2),
                )
            })
    }

    /// The tabs showing, across the bar or (`vertical`) down the column.
    fn tabs(&self, vertical: bool, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        // The tabs showing, in order: those of the kind picked, grouped by
        // kind with its icon between groups when asked.
        let mut order: Vec<usize> = (0..self.tabs.len()).filter(|&i| self.tab_shows(&self.tabs[i], cx)).collect();
        if self.group_tabs {
            order.sort_by_key(|&i| self.tab_kind(&self.tabs[i], cx) as u8);
        }
        let mut elements: Vec<AnyElement> = Vec::new();
        let mut last: Option<TabKind> = None;
        for index in order {
            let kind = self.tab_kind(&self.tabs[index], cx);
            let grouped = self.group_tabs && self.tab_filter.is_none() && self.tab_query(cx).is_empty();
            let collapsed = grouped && self.collapsed_kinds.contains(&kind);
            if grouped && last != Some(kind) {
                // The group's heading folds its tabs away, or back.
                let count = self.tabs.iter().filter(|t| self.tab_kind(t, cx) == kind).count();
                let needs = collapsed && self.tabs.iter().any(|t| self.tab_kind(t, cx) == kind && self.tab_needs_you(t, cx));
                elements.push(
                    div()
                        .id(SharedString::from(format!("tab-group-{}", kind.title())))
                        .flex_none()
                        .map(|d| if vertical { d.w_full().h(px(26.)).border_b_1() } else { d.h_full().border_r_1() })
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_1()
                        .px_2()
                        .border_color(theme.border)
                        .bg(theme.tile)
                        .text_xs()
                        .text_color(theme.tertiary)
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.row_selected))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            if !this.collapsed_kinds.remove(&kind) {
                                this.collapsed_kinds.insert(kind);
                            }
                            cx.notify();
                        }))
                        .child(div().child(if collapsed { "▸" } else { "▾" }))
                        .child(gpui::svg().path(kind.icon()).size(px(12.)).text_color(theme.tertiary))
                        .child(kind.title())
                        .when(collapsed, |d| d.child(div().text_color(theme.secondary).child(count.to_string())))
                        .when(needs, |d| d.child(div().size(px(7.)).rounded_full().bg(gpui::rgb(0xFF9F0A))))
                        .into_any_element(),
                );
            }
            last = Some(kind);
            // A folded group still shows the tab that's open.
            if !collapsed || index == self.active {
                elements.push(self.tab_element(index, vertical, theme, cx).into_any_element());
            }
        }
        if vertical {
            div().id("tabs").flex_1().min_h_0().w_full().flex().flex_col().overflow_y_scroll().children(elements)
        } else {
            div().id("tabs").flex_1().min_w_0().h_full().flex().flex_row().overflow_x_scroll().children(elements)
        }
    }

    /// Next or previous among the tabs showing, in the order they show.
    fn step_tab(&mut self, by: i32, window: &mut Window, cx: &mut Context<Self>) {
        let mut order: Vec<usize> = (0..self.tabs.len()).filter(|&i| self.tab_shows(&self.tabs[i], cx)).collect();
        if self.group_tabs {
            order.sort_by_key(|&i| self.tab_kind(&self.tabs[i], cx) as u8);
            // Tabs in a folded group are skipped, but for the one open.
            if self.tab_filter.is_none() {
                order.retain(|&i| i == self.active || !self.collapsed_kinds.contains(&self.tab_kind(&self.tabs[i], cx)));
            }
        }
        if order.is_empty() {
            return;
        }
        let at = order.iter().position(|&i| i == self.active).unwrap_or(0) as i32;
        let next = (at + by).rem_euclid(order.len() as i32) as usize;
        self.activate(order[next], window, cx);
    }

    fn tab_element(&self, index: usize, vertical: bool, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
                let tab = &self.tabs[index];
                let (icon, tint) = (self.tab_icon(tab, cx), self.tab_tint(tab, theme, cx));
                // Filtered to one kind, the tabs need no icon to tell them
                // apart; a session's state still colours its name.
                let filtered = self.tab_filter.is_some();
                let (id, page) = (tab.id, tab.page.clone());
                let session_tint = matches!(tab.nav, Nav::Session(_)).then_some(tint);
                let active = index == self.active;
                let label = self.tab_name(tab, cx);
                let elsewhere = self.runs_elsewhere(tab, cx);
                let landing = theme.row_selected;
                div()
                    .id(("tab", index))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .pl_3()
                    .pr_2()
                    // A row of the column, or a tab across the bar.
                    .map(|d| if vertical { d.flex_none().w_full().h(px(30.)).border_b_1() } else { d.h_full().border_r_1() })
                    .border_color(theme.border)
                    .cursor_pointer()
                    .text_color(match session_tint.filter(|_| filtered) {
                        Some(tint) => tint,
                        None if active => theme.fg,
                        None => theme.secondary,
                    })
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
                    .when(!filtered, |d| d.child(gpui::svg().path(icon).size(px(14.)).flex_none().text_color(tint)))
                    .map(|d| match &self.renaming {
                        Some((renamed, field)) if *renamed == id => d.child(
                            div()
                                .id(("rename-tab", index))
                                .capture_key_down(cx.listener(Self::rename_key))
                                // Clicks in the field place the cursor, not
                                // switch or drag the tab.
                                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                                .on_click(|_, _, cx| cx.stop_propagation())
                                .map(|d| if vertical { d.flex_1().min_w_0() } else { d.w(px(180.)) })
                                .px_1()
                                .rounded_sm()
                                .border_1()
                                .border_color(theme.selected)
                                .bg(theme.bg)
                                .child(field.clone()),
                        ),
                        // Down the column the name takes the width, the close at the end.
                        _ => d.child(div().map(|d| if vertical { d.flex_1().min_w_0() } else { d.max_w(px(220.)) }).truncate().child(label.clone())),
                    })
                    // A session that runs somewhere other than the window's
                    // folder (one started before it, or in another window)
                    // says where.
                    .when_some(elsewhere, |d, (icon, place)| {
                        d.child(div().flex_none().flex().flex_row().items_center().gap_1().text_xs().text_color(theme.tertiary).child(gpui::svg().path(icon).size(px(11.)).text_color(theme.tertiary)).child(place))
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

    fn tab_status_of(&self, tab: &Tab, cx: &App) -> TabStatus {
        match tab.nav {
            Nav::Session(id) if self.session(id, cx).is_some_and(|p| p.read(cx).state == State::Ended) => TabStatus::Stopped,
            _ => TabStatus::Active,
        }
    }

    /// The search, without a leading `#`.
    fn tab_query(&self, cx: &App) -> String {
        self.tab_search.read(cx).text(cx).trim().trim_start_matches('#').trim().to_lowercase()
    }

    /// The PRs a session opened, from its hook file, read again when the
    /// copy held is a few seconds old.
    fn session_pr_numbers(&self, launch: &crate::launch::Launch) -> Vec<i64> {
        let mut cache = self.session_prs.borrow_mut();
        if let Some((at, numbers)) = cache.get(&launch.id) {
            if at.elapsed() < std::time::Duration::from_secs(3) {
                return numbers.clone();
            }
        }
        let numbers: Vec<i64> = launch
            .pull_requests()
            .iter()
            .filter_map(|url| url.trim().trim_end_matches('/').rsplit_once("/pull/").and_then(|(_, n)| n.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok()))
            .collect();
        cache.insert(launch.id.clone(), (std::time::Instant::now(), numbers.clone()));
        numbers
    }

    /// Whether a tab answers the search: a number finds the sessions whose
    /// subject (a review's PR, a work session's issue) or opened PRs have
    /// it; words match a tab's name and a session's subject.
    fn tab_matches_search(&self, tab: &Tab, cx: &App) -> bool {
        let query = self.tab_query(cx);
        if query.is_empty() {
            return true;
        }
        let launch = match tab.nav {
            Nav::Session(id) => self.session(id, cx).and_then(|p| p.read(cx).launch.clone()),
            _ => None,
        };
        if let Ok(number) = query.parse::<i64>() {
            let Some(launch) = launch else { return false };
            return launch.subject.as_ref().is_some_and(|s| s.number == number) || self.session_pr_numbers(&launch).contains(&number);
        }
        self.tab_name(tab, cx).to_lowercase().contains(&query)
            || launch.and_then(|l| l.subject).is_some_and(|s| s.title.to_lowercase().contains(&query) || s.repo.to_lowercase().contains(&query))
    }

    /// Whether the tab bar shows a tab, under its kind and status filters
    /// and the search.
    fn tab_shows(&self, tab: &Tab, cx: &App) -> bool {
        self.tab_filter.is_none_or(|k| self.tab_kind(tab, cx) == k) && self.tab_status.is_none_or(|s| self.tab_status_of(tab, cx) == s) && self.tab_matches_search(tab, cx)
    }

    /// The tab bar's search, after its filter menu.
    fn tab_search_box(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let searching = !self.tab_query(cx).is_empty();
        let found = searching.then(|| self.tabs.iter().filter(|t| self.tab_shows(t, cx)).count());
        div()
            .flex_none()
            .h_full()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .px_1()
            .border_r_1()
            .border_color(theme.border)
            .child(
                div()
                    .w(px(if searching { 120. } else { 84. }))
                    .px_1p5()
                    .py_0p5()
                    .rounded_md()
                    .text_xs()
                    .border_1()
                    .border_color(if searching { theme.selected } else { theme.border })
                    .bg(theme.bg)
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        match event.keystroke.key.as_str() {
                            "escape" => {
                                cx.stop_propagation();
                                this.tab_search.update(cx, |e, cx| e.set_text("", window, cx));
                                this.focus_current(window, cx);
                            }
                            // Enter opens the first tab found.
                            "enter" => {
                                cx.stop_propagation();
                                if let Some(first) = (0..this.tabs.len()).find(|&i| this.tab_shows(&this.tabs[i], cx)) {
                                    this.activate(first, window, cx);
                                }
                            }
                            _ => {}
                        }
                    }))
                    .child(self.tab_search.clone()),
            )
            .when_some(found, |d, found| {
                d.child(div().text_xs().text_color(if found == 0 { theme.critical() } else { theme.tertiary }).child(if found == 0 { "None".to_string() } else { found.to_string() }))
                    .child(
                        div()
                            .id("tab-search-clear")
                            .px_1()
                            .rounded_sm()
                            .cursor_pointer()
                            .text_xs()
                            .text_color(theme.secondary)
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                this.tab_search.update(cx, |e, cx| e.set_text("", window, cx));
                                cx.notify();
                            }))
                            .child("×"),
                    )
            })
    }

    /// Where a session tab's session runs, when that isn't where the
    /// window's folder is: its icon and the place's name.
    fn runs_elsewhere(&self, tab: &Tab, cx: &App) -> Option<(&'static str, String)> {
        let Nav::Session(id) = tab.nav else { return None };
        let launch = self.session(id, cx)?.read(cx).launch.as_ref()?;
        let window_server = self.folder.as_ref().and_then(|f| f.location.server.as_ref()).map(|s| s.key());
        if launch.server.as_ref().map(|s| s.key()) == window_server {
            return None;
        }
        Some(match &launch.server {
            Some(server) => ("icons/server.svg", server.name()),
            None => ("icons/screen.svg", "this Mac".into()),
        })
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

    /// A tab's own icon: its page's, or its session's kind.
    fn tab_icon(&self, tab: &Tab, cx: &App) -> &'static str {
        match tab.nav {
            Nav::PullRequests => "icons/pull_request.svg",
            Nav::Issues => "icons/circle.svg",
            Nav::Scorecards => "icons/table.svg",
            Nav::Ci => "icons/play_outlined.svg",
            Nav::Activity => "icons/git_graph.svg",
            Nav::Harness(_) => "icons/book.svg",
            Nav::ReviewPreview => "icons/eye.svg",
            Nav::SchedulePreview => "icons/clock.svg",
            Nav::WorkflowsPreview => "icons/git_graph.svg",
            Nav::Settings => "icons/settings.svg",
            Nav::AgentMetrics => "icons/sparkle.svg",
            Nav::Session(id) => match self.session(id, cx).map(|p| p.read(cx)) {
                Some(page) if page.launch.is_some() => self.tab_kind(tab, cx).icon(),
                Some(page) if page.kind == Kind::Shell => "icons/terminal.svg",
                _ => "icons/sparkle.svg",
            },
            _ => "icons/file.svg",
        }
    }

    /// The icon's colour, in place of a dot: a session's state (working,
    /// needs you, your turn, ended), a review's verdict once it's in and
    /// claude's waiting; a page's is plain.
    fn tab_tint(&self, tab: &Tab, theme: &Theme, cx: &App) -> gpui::Hsla {
        let Nav::Session(id) = tab.nav else { return theme.secondary };
        let Some(page) = self.session(id, cx) else { return theme.secondary };
        let state = page.read(cx).state;
        if matches!(state, State::YourTurn | State::Ended) {
            if let Some(verdict) = page.read(cx).review().and_then(|r| r.read(cx).verdict()) {
                return match verdict.as_str() {
                    "approve" => theme.good(),
                    "request_changes" => theme.critical(),
                    _ => theme.selected,
                };
            }
        }
        state_tint(state, theme)
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
        let hidden_needs = self.tabs.iter().any(|t| !self.tab_shows(t, cx) && self.tab_needs_you(t, cx));
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
        let label = match (self.tab_filter, self.tab_status) {
            (Some(kind), Some(status)) => format!("{} · {}", kind.title(), status.title()),
            (Some(kind), None) => kind.title().to_string(),
            (None, Some(status)) => status.title().to_string(),
            (None, None) => "All".to_string(),
        };
        let narrowed = self.tab_filter.is_some() || self.tab_status.is_some();
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
                    .text_color(if narrowed { theme.selected } else { theme.secondary })
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
                        this.tab_status = None;
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
                // Active or stopped, alongside the kind.
                menu = menu.child(div().my_1().h(px(1.)).bg(theme.border));
                for status in [TabStatus::Active, TabStatus::Stopped] {
                    let count = self.tabs.iter().filter(|t| self.tab_status_of(t, cx) == status).count();
                    let on = self.tab_status == Some(status);
                    menu = menu.child(row(SharedString::from(format!("tab-status-{}", status.title())), None, status.title().into(), Some(count), false, on).on_click(cx.listener(
                        move |this, _: &ClickEvent, window, cx| {
                            this.tab_status = if on { None } else { Some(status) };
                            this.tab_filter_open = false;
                            if let Some(status) = this.tab_status {
                                if this.tabs.get(this.active).is_none_or(|t| this.tab_status_of(t, cx) != status) {
                                    if let Some(first) = (0..this.tabs.len()).find(|&i| this.tab_shows(&this.tabs[i], cx)) {
                                        this.activate(first, window, cx);
                                    }
                                }
                            }
                            cx.notify();
                        },
                    )));
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
                Page::SchedulePreview(page) => page.into_any_element(),
                Page::WorkflowsPreview(page) => page.into_any_element(),
                Page::AgentMetrics(page) => page.into_any_element(),
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
                        .child("Not built yet."),
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
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _: &MouseDownEvent, window, cx| {
                    if this.remotes.is_some() {
                        this.close_remotes(window, cx);
                    } else {
                        this.close_switcher(window, cx);
                    }
                }),
            )
    }

    fn switcher_panel(&self, switcher: &Switcher, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let pick = switcher.pick;
        let matches = self.switcher_items(pick, &switcher.query);
        let current = match pick {
            Pick::Folder => self.folder.as_ref().map(|f| f.location.key()),
            Pick::Project => self.project.clone(),
        };
        let typing_path = switcher.server.as_ref().map(|s| s.name());
        let (prompt, none) = match (pick, &typing_path) {
            (_, Some(server)) => (format!("A folder's path on {server}, such as ~/Code/acme"), String::new()),
            (Pick::Folder, None) => ("Find a recent folder".to_string(), "No recent folder matches".to_string()),
            (Pick::Project, None) => ("Find a project".to_string(), "No project matches".to_string()),
        };
        let matches = if typing_path.is_some() { Vec::new() } else { matches };
        let recents = if pick == Pick::Folder { crate::folders::recent() } else { Vec::new() };
        // Typing a path on a server: what Return does, in place of the list.
        let typing_note = typing_path.as_ref().map(|server| {
            div()
                .mx_1()
                .px_2()
                .py_1p5()
                .text_sm()
                .text_color(theme.secondary)
                .child(format!("Return opens it on {server}; Escape goes back. It's read there, and its sessions run there."))
        });
        // Open Recent's footer, as Zed's: open a folder here or on a server.
        let footer_button = |id: &'static str, label: &'static str, keys: &'static str| {
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .text_sm()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
                .when(!keys.is_empty(), |d| d.child(div().text_xs().text_color(theme.tertiary).child(keys)))
        };
        let footer = (pick == Pick::Folder && typing_path.is_none()).then(|| {
            div()
                .px_2()
                .py_1()
                .flex()
                .flex_row()
                .justify_end()
                .gap_1()
                .border_t_1()
                .border_color(theme.border)
                .child(footer_button("switcher-open-folder", "Open Local Folder", "⌘O").on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.pick_folder(window, cx))))
                .child(footer_button("switcher-open-remote", "Open Remote Folder", "").on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                    this.switcher = None;
                    this.toggle_remotes(window, cx);
                })))
        });
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
            .children(typing_note)
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
                        let row = div()
                            .id(("switcher-item", index))
                            .mx_1()
                            .px_2()
                            .rounded_md()
                            .flex()
                            .flex_row()
                            .cursor_pointer()
                            .when(highlighted, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected))
                            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.choose(pick, chosen.clone(), window, cx)));
                        match pick {
                            // One line, as Zed's Open Recent: this Mac or a
                            // server by its icon, the name, then where it is,
                            // muted; the window's own folder ticked at the end.
                            Pick::Folder => {
                                let recent = recents.iter().find(|r| &r.location.key() == key);
                                let remote = recent.is_some_and(|r| r.location.server.is_some());
                                let place = recent.map_or_else(String::new, |r| {
                                    let path = home_relative(&r.location.path);
                                    match &r.location.server {
                                        Some(server) => format!("{} · {path}", server.name()),
                                        None => path,
                                    }
                                });
                                row.py_1()
                                    .items_center()
                                    .gap_2()
                                    .child(gpui::svg().path(if remote { "icons/server.svg" } else { "icons/screen.svg" }).size(px(14.)).flex_none().text_color(theme.secondary))
                                    .child(div().flex_none().max_w(px(160.)).truncate().child(label.clone()))
                                    .child(div().flex_1().min_w_0().truncate().text_sm().text_color(theme.tertiary).child(place))
                                    .child(div().flex_none().w(px(14.)).text_color(theme.selected).child(if is_current { "✓" } else { "" }))
                            }
                            Pick::Project => {
                                let detail = self.projects.iter().find(|p| &p.id == key).map_or_else(String::new, |p| {
                                    let repos = match p.repos.len() {
                                        0 => "every repo".to_string(),
                                        1 => "1 repo".to_string(),
                                        n => format!("{n} repos"),
                                    };
                                    format!("{repos} • {}", p.id)
                                });
                                row.py_1p5()
                                    .items_start()
                                    .gap_3()
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
                            }
                        }
                    }))
                    .when(matches.is_empty() && typing_path.is_none(), |d| d.child(div().px_3().py_2().text_color(theme.secondary).child(none))),
            )
            .children(footer)
    }
}

/// A path with the home folder as ~, as Zed shows one. A server's path is
/// already as it was typed there.
fn home_relative(path: &std::path::Path) -> String {
    let shown = path.display().to_string();
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && shown.starts_with(&home) => format!("~{}", &shown[home.len()..]),
        _ => shown,
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
        // A promised file or picture dropped on the window goes to New
        // Issue while it shows.
        crate::promise_drop::set_accepting(self.new_issue_showing().is_some());
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
            .when(!self.tabs_on_left, |d| d.child(self.tab_bar(&theme, cx)))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .child(self.page(&theme, cx))
                    .when(!self.drawers.is_empty(), |d| d.child(self.drawer_stack(&theme, cx)))
                    // New Issue covers the page and its drawers, which stay
                    // as they were for Back.
                    .when_some(self.new_issue_showing(), |d, form| d.child(div().absolute().top_0().left_0().right_0().bottom_0().occlude().child(form))),
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
            .on_action(cx.listener(|this, _: &Refresh, _, cx| this.refresh_quietly(cx)))
            .on_action(cx.listener(|this, _: &ToggleTabsOnLeft, _, cx| {
                this.tabs_on_left = !this.tabs_on_left;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &ToggleSync, _, cx| {
                this.sync.open = !this.sync.open;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &NewAsk, window, cx| this.open_form(crate::launch::Flow::Ask, None, window, cx)))
            .on_action(cx.listener(|this, _: &NewQuickChange, window, cx| this.open_form(crate::launch::Flow::QuickChange, None, window, cx)))
            .on_action(cx.listener(|this, _: &NewPlan, window, cx| this.open_form(crate::launch::Flow::Plan, None, window, cx)))
            .on_action(cx.listener(|this, _: &CloseTab, window, cx| this.close_tab(this.active, window, cx)))
            .on_action(cx.listener(|this, _: &NewWindow, _, cx| this.new_window(cx)))
            .on_action(cx.listener(|this, _: &NextTab, window, cx| this.step_tab(1, window, cx)))
            .on_action(cx.listener(|this, _: &PreviousTab, window, cx| this.step_tab(-1, window, cx)))
            .on_action(cx.listener(|this, _: &OpenSwitcher, window, cx| this.open_switcher(Pick::Folder, window, cx)))
            .on_action(cx.listener(|this, _: &OpenFolder, window, cx| this.pick_folder(window, cx)))
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
                    .when(self.tabs_on_left, |d| d.child(self.tab_column(&theme, cx)))
                    .child(center)
                    .when(self.inspector_open, |d| d.child(self.inspector(&theme, cx)))
                    .when(self.sync.open, |d| d.child(self.sync_panel(&theme, cx)))
                    .when_some(self.marra_dock.clone(), |d, marra| d.child(div().flex_none().w(px(400.)).h_full().border_l_1().border_color(theme.border).child(marra))),
            )
            .child(self.status_bar(&theme, cx))
            .when(self.switcher.is_some() || self.remotes.is_some(), |d| d.child(self.switcher_backdrop(cx)))
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
            .when_some(self.schedule_sheet.as_ref().map(|(sheet, _)| sheet.clone()), |d, sheet| {
                d.child(div().id("schedule-sheet-scrim").absolute().top_0().left_0().right_0().bottom_0().occlude().bg(gpui::black().opacity(0.35)).flex().justify_center().pt(px(50.)).child(sheet))
            })
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
