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
use crate::prs::{OpenPr, PrItem, PrState, PrsPage, PrsSaved};
use crate::state::{CiSaved, SavedState, SavedTab};
use crate::work::{self, Pr, Work};
use gpui::{
    actions, anchored, Focusable, black, deferred, div, ease_out_quint, prelude::*, px, relative, Animation, AnimationExt, AnyElement, ClickEvent, Context, App, Entity, FocusHandle, FontWeight, KeyBinding,
    KeyDownEvent, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, SharedString, Subscription, Window,
    WindowAppearance,
};
use std::collections::HashSet;

actions!(shell, [ToggleSidebar, ToggleInspector, NewClaudeSession, NewTerminal, CloseTab, OpenSwitcher]);

pub fn key_bindings() -> Vec<KeyBinding> {
    vec![
        KeyBinding::new("ctrl-cmd-s", ToggleSidebar, None),
        KeyBinding::new("cmd-alt-i", ToggleInspector, None),
        KeyBinding::new("cmd-t", NewClaudeSession, None),
        KeyBinding::new("ctrl-`", NewTerminal, None),
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
    /// A session's tab, by the pilot's own number for it. Not restored at
    /// launch: its terminal ended with the last run.
    Session(u32),
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
                // Item(Scorecards),
                // Item(PrFlow),
                // Item(IssueFlow),
                // Item(Releases),
                // Item(Investments),
                // Item(RdTime),
                Item(Ci),
            ],
        },
        // Section { id: "team", title: Some("Team"), rows: vec![Group(Everyone, vec![]), Item(Activity), Item(TimeOff)] },
        // Section {
        //     id: "rituals",
        //     title: Some("Rituals"),
        //     rows: vec![Item(Standup), Item(Recap), Item(Prioritisation), Item(Planning), Item(Refine), Item(Hygiene)],
        // },
        // Section { id: "harness", title: Some("Harness"), rows: vec![Item(Onboarding), Item(HarnessWorkflows)] },
        // Section {
        //     id: "agents",
        //     title: Some("Agents"),
        //     rows: vec![Item(AgentMetrics), Item(WaitingOnYou), Item(Routines), Item(Queue)],
        // },
    ]
}

#[derive(Clone, Copy)]
enum Edge {
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
            // Sessions aren't kept, so the index counts the tabs that are.
            active: self.tabs.iter().take(self.active).filter(|tab| !matches!(tab.nav, Nav::Session(_))).count(),
            sidebar_open: self.sidebar_open,
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
        let active = saved.active;
        let mut workspace = Self::build(saved, window, cx);
        for view in &views {
            let tab = workspace.make_tab(view.nav, Some(view), window, cx);
            workspace.tabs.push(tab);
        }
        workspace.active = active.min(workspace.tabs.len().saturating_sub(1));
        workspace.load_viewer(cx);
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
                Page::None => {}
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
            inspector_open: saved.inspector_open,
            sidebar_width: saved.sidebar_width,
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
            _ => Page::None,
        };
        let subscriptions = Self::watch(&page, cx);
        self._subscriptions.extend(subscriptions);
        let focus = self.focus_repos();
        match &page {
            Page::Issues(p) => p.update(cx, |p, cx| p.set_focus(focus, cx)),
            Page::Prs(p) => p.update(cx, |p, cx| p.set_focus(focus, cx)),
            Page::Ci(p) => p.update(cx, |p, cx| p.set_focus(focus, cx)),
            Page::None => {}
        }
        self.next_tab += 1;
        Tab { id: self.next_tab, nav, name: saved.and_then(|s| s.name.clone()), page }
    }

    /// Opens drawers, the inspector and saving from a page's events.
    fn watch(page: &Page, cx: &mut Context<Self>) -> Vec<Subscription> {
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
            Page::None => Vec::new(),
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
            let Ok(task) = cx.update(|window, cx| session::spawn_terminal(kind, folder.clone(), window, cx)) else { return };
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
                let page = cx.new(|cx| SessionPage::new(id, kind, folder, builder, window, cx));
                this._subscriptions.push(cx.subscribe(&page, |_, _, _: &Changed, cx| cx.notify()));
                this.sessions.push(page);
                this.drawers.clear();
                this.next_tab += 1;
                let tab = Tab { id: this.next_tab, nav: Nav::Session(id), name: None, page: Page::None };
                this.tabs.push(tab);
                this.activate(this.tabs.len() - 1, window, cx);
            })
            .ok();
        })
        .detach();
    }

    /// The org's PR cache, read off the main thread.
    fn load_work(&mut self, org: String, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            let loaded = org.clone();
            let login = this.update(cx, |this, _| this.viewer.as_ref().map(|v| v.login.clone())).ok().flatten();
            let work = cx.background_executor().spawn(async move { work::load(&loaded, login) }).await;
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
                        let kind = match drawer.item {
                            DrawerItem::Issue(_) => "Issue",
                            DrawerItem::Pull(_) => "Pull Request",
                        };
                        if count > 1 {
                            format!("{kind} · {} of {count}", self.drawers.iter().position(|d| d.seq == drawer.seq).unwrap_or(0) + 1)
                        } else {
                            kind.into()
                        }
                    }),
            )
            .child(button("close-drawer", "×").on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.pop_drawer(cx))))
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
                Page::None => {}
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
            Edge::Sidebar => handle.top_0().bottom_0().right(px(-3.)).w(px(6.)).cursor_col_resize(),
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

    // MARK: Status bar

    /// Along the foot of the window, as Zed's: panel toggles at each end
    /// and the page's own status between them.
    fn status_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let toggle = |id: &'static str, icon: &'static str, tip: &'static str, on: bool, cx: &mut Context<Self>, action: fn(&mut Self)| {
            div()
                .id(id)
                .p_1()
                .rounded_md()
                .cursor_pointer()
                .when(on, |d| d.bg(theme.row_selected))
                .hover(|s| s.bg(theme.row_selected))
                .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.to_string())).into())
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    action(this);
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
            .child(toggle(
                "toggle-sidebar",
                if self.sidebar_open { "icons/threads_sidebar_left_open.svg" } else { "icons/threads_sidebar_left_closed.svg" },
                "Sidebar  ⌃⌘S",
                self.sidebar_open,
                cx,
                |this| this.sidebar_open = !this.sidebar_open,
            ))
            .child(div().flex_1())
            .child(toggle(
                "toggle-inspector",
                if self.inspector_open { "icons/threads_sidebar_right_open.svg" } else { "icons/threads_sidebar_right_closed.svg" },
                "Your Work  ⌥⌘I",
                self.inspector_open,
                cx,
                |this| this.inspector_open = !this.inspector_open,
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
            .id("tabs")
            .h(px(32.))
            .flex_none()
            .flex()
            .flex_row()
            .overflow_x_scroll()
            .bg(theme.sidebar)
            .border_b_1()
            .border_color(theme.border)
            .children(self.tabs.iter().enumerate().map(|(index, tab)| {
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
            }))
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
            Some("Changes requested") => orange,
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
        if !assigned.is_empty() {
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

        let button = |id: &'static str, label: &'static str| {
            div()
                .id(id)
                .flex_1()
                .py_1()
                .flex()
                .justify_center()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
        };
        let summary = match &self.work.login {
            Some(login) => format!(
                "{} · {}",
                login,
                match count {
                    0 => "nothing waiting".to_string(),
                    1 => "1 thing waiting".to_string(),
                    n => format!("{n} things waiting"),
                }
            ),
            None => "Not signed in to Gannin: only sessions show".to_string(),
        };
        div()
            .flex()
            .flex_col()
            .child(div().text_xs().text_color(theme.secondary).child(summary))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .pt_2()
                    .child(button("new-claude", "New Claude Code").on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.new_session(Kind::Claude, window, cx)
                    })))
                    .child(button("new-terminal", "New Terminal").on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.new_session(Kind::Shell, window, cx)
                    }))),
            )
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
            .on_action(cx.listener(|this, _: &CloseTab, window, cx| this.close_tab(this.active, window, cx)))
            .on_action(cx.listener(|this, _: &OpenSwitcher, window, cx| this.open_switcher(Pick::Org, window, cx)))
            // Escape closes the top drawer; the switcher takes it first when open.
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" && this.sign_in.is_some() {
                    this.cancel_sign_in(cx);
                    cx.stop_propagation();
                } else if event.keystroke.key == "escape" && this.account_open {
                    this.account_open = false;
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
                    .child(center)
                    .when(self.inspector_open, |d| d.child(self.inspector(&theme, cx))),
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
    }
}
