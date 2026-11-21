//! Settings, after Gannin's: for now only Projects, as Settings › Projects
//! has it, cut down to what a project is: the org's projects (each a
//! harness), which is home, and each one's name and repos.
//!
//! - Which harnesses are projects, and which is home, is this Mac's own
//!   (the org's settings in `~/.gannin/orgs/`). Making one home copies
//!   nothing: the org-wide files are read from its harness from then on.
//! - A project's name and repos are `.gannin/project.json` in its harness,
//!   so everyone who has it as a project gets the same. Edits stay here
//!   until Save to Harness, which asks first, then commits the file to the
//!   harness's default branch (or a pull request where it needs one),
//!   keeping the file's other keys.
//!
//! Boards, the harness's branch and prompts aren't here yet.

use crate::charts::Theme;
use crate::issues::Tooltip;
use crate::projects::Project;
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, Focusable, FontWeight, SharedString, Subscription, Window};
use serde_json::json;
use std::collections::HashMap;
use std::sync::Mutex;

/// The org's projects changed: the workspace reads them again.
pub struct ProjectsChanged;

impl EventEmitter<ProjectsChanged> for SettingsPage {}

#[derive(Clone, Copy, PartialEq)]
enum Picking {
    /// A repo to make a project's harness.
    Project,
    /// A repo to add to the selected project.
    Repo,
}

pub struct SettingsPage {
    org: Option<String>,
    /// Home first.
    projects: Vec<Project>,
    loading: bool,
    /// The project being edited, by its harness's repo.
    selected: Option<String>,
    name: Entity<editor::Editor>,
    /// The selected project's repos as edited here.
    repos: Vec<String>,
    picking: Option<Picking>,
    search: Entity<editor::Editor>,
    /// Every repo the account owns, once fetched.
    account_repos: Option<Vec<String>>,
    saving: bool,
    checking: bool,
    /// What happened last, and whether it went wrong.
    note: Option<(String, bool)>,
    generation: u64,
    _subscriptions: Vec<Subscription>,
}

/// The account's repos, by org, fetched once a run.
static REPOS: Mutex<Option<HashMap<String, Vec<String>>>> = Mutex::new(None);

/// Every non-archived repo the account owns, by name. Off the main thread.
fn account_repos(org: &str) -> Result<Vec<String>, String> {
    if let Some(held) = REPOS.lock().ok().and_then(|r| r.as_ref().and_then(|m| m.get(org).cloned())) {
        return Ok(held);
    }
    let token = crate::auth::token().ok_or("Sign in to list the repositories.")?;
    let query = "query($login: String!, $cursor: String) { repositoryOwner(login: $login) { repositories(first: 100, after: $cursor, isArchived: false, ownerAffiliations: [OWNER], orderBy: { field: NAME, direction: ASC }) { pageInfo { hasNextPage endCursor } nodes { nameWithOwner } } } }";
    let mut repos = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let data = crate::github::graphql(&token, query, json!({ "login": org, "cursor": cursor })).map_err(|e| e.to_string())?;
        let connection = &data["repositoryOwner"]["repositories"];
        repos.extend(connection["nodes"].as_array().into_iter().flatten().filter_map(|n| n["nameWithOwner"].as_str().map(str::to_string)));
        match (connection["pageInfo"]["hasNextPage"].as_bool(), connection["pageInfo"]["endCursor"].as_str()) {
            (Some(true), Some(next)) if repos.len() < 5000 => cursor = Some(next.to_string()),
            _ => break,
        }
    }
    if let Ok(mut held) = REPOS.lock() {
        held.get_or_insert_with(HashMap::new).insert(org.to_string(), repos.clone());
    }
    Ok(repos)
}

/// `owner/name` typed in the picker, when it reads as one.
fn typed_repo(text: &str) -> Option<String> {
    let text = text.trim().trim_start_matches("https://github.com/").trim_end_matches('/').trim_end_matches(".git");
    let (owner, name) = text.split_once('/')?;
    let ok = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    (ok(owner) && ok(name)).then(|| format!("{owner}/{name}"))
}

fn short(repo: &str) -> &str {
    repo.rsplit('/').next().unwrap_or(repo)
}

impl SettingsPage {
    pub fn new(org: Option<String>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let name = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Name", window, cx);
            editor
        });
        let search = cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Search repositories, or type owner/name", window, cx);
            editor
        });
        let notify = |_: &mut Self, _: Entity<editor::Editor>, event: &editor::EditorEvent, cx: &mut Context<Self>| {
            if matches!(event, editor::EditorEvent::BufferEdited) {
                cx.notify();
            }
        };
        let subscriptions = vec![cx.subscribe(&name, notify), cx.subscribe(&search, notify), cx.observe_window_appearance(window, |_, _, cx| cx.notify())];
        let mut page = Self {
            org,
            projects: Vec::new(),
            loading: true,
            selected: None,
            name,
            repos: Vec::new(),
            picking: None,
            search,
            account_repos: None,
            saving: false,
            checking: false,
            note: None,
            generation: 0,
            _subscriptions: subscriptions,
        };
        page.load(window, cx);
        page
    }

    pub fn set_org(&mut self, org: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        if org != self.org {
            self.org = org;
            self.selected = None;
            self.account_repos = None;
            self.picking = None;
            self.note = None;
            self.load(window, cx);
        }
    }

    /// Reads the org's projects off the main thread (it runs git).
    fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else {
            self.loading = false;
            return;
        };
        self.generation += 1;
        let generation = self.generation;
        self.loading = true;
        cx.notify();
        let window_handle = window.window_handle();
        cx.spawn(async move |this, cx| {
            let projects = cx.background_executor().spawn(async move { crate::projects::load(&org).projects }).await;
            let _ = cx.update_window(window_handle, |_, window, cx| {
                let _ = this.update(cx, |page, cx| {
                    if page.generation != generation {
                        return;
                    }
                    page.loading = false;
                    page.projects = projects;
                    let keep = page.selected.clone().filter(|id| page.projects.iter().any(|p| &p.id == id));
                    // An edit under way survives a reload of the same project.
                    if keep.is_none() || !page.changed(cx) {
                        let id = keep.or_else(|| page.projects.first().map(|p| p.id.clone()));
                        page.select(id, window, cx);
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn project(&self) -> Option<&Project> {
        self.projects.iter().find(|p| Some(&p.id) == self.selected.as_ref())
    }

    fn select(&mut self, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = id;
        self.picking = None;
        let (name, repos) = self.project().map(|p| (p.name.clone(), p.repos.clone())).unwrap_or_default();
        self.repos = repos;
        self.name.update(cx, |editor, cx| editor.set_text(name, window, cx));
        cx.notify();
    }

    fn typed_name(&self, cx: &Context<Self>) -> String {
        self.name.read(cx).text(cx).trim().to_string()
    }

    /// Whether the name or repos differ from the harness's file.
    fn changed(&self, cx: &Context<Self>) -> bool {
        self.project().is_some_and(|p| p.name != self.typed_name(cx) || p.repos != self.repos)
    }

    fn open_picker(&mut self, picking: Picking, window: &mut Window, cx: &mut Context<Self>) {
        self.picking = if self.picking == Some(picking) { None } else { Some(picking) };
        self.search.update(cx, |editor, cx| editor.set_text("", window, cx));
        if self.picking.is_some() {
            window.focus(&self.search.focus_handle(cx), cx);
        }
        if self.account_repos.is_none() {
            if let Some(org) = self.org.clone() {
                cx.spawn(async move |this, cx| {
                    let listed = cx.background_executor().spawn(async move { account_repos(&org) }).await;
                    let _ = this.update(cx, |page, cx| {
                        match listed {
                            Ok(repos) => page.account_repos = Some(repos),
                            Err(error) => page.note = Some((error, true)),
                        }
                        cx.notify();
                    });
                })
                .detach();
            }
        }
        cx.notify();
    }

    /// A repo picked: added at once when the account lists it; one typed
    /// is checked with GitHub first, so only one that exists and this token
    /// can read is added.
    fn pick(&mut self, repo: String, listed: bool, window: &mut Window, cx: &mut Context<Self>) {
        let Some(picking) = self.picking else { return };
        if listed {
            self.add(picking, repo, window, cx);
            return;
        }
        self.checking = true;
        self.note = None;
        cx.notify();
        let window_handle = window.window_handle();
        cx.spawn(async move |this, cx| {
            let found = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to GitHub first.".to_string())?;
                    match crate::github::rest_get(&token, &format!("repos/{repo}")) {
                        Ok(value) => value["full_name"].as_str().map(str::to_string).ok_or(format!("GitHub couldn't find {repo}.")),
                        Err((404, _)) => Err(format!("GitHub couldn't find {repo}, or this token can't read it.")),
                        Err((_, message)) => Err(message),
                    }
                })
                .await;
            let _ = cx.update_window(window_handle, |_, window, cx| {
                let _ = this.update(cx, |page, cx| {
                    page.checking = false;
                    match found {
                        Ok(repo) => page.add(picking, repo, window, cx),
                        Err(error) => page.note = Some((error, true)),
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn add(&mut self, picking: Picking, repo: String, window: &mut Window, cx: &mut Context<Self>) {
        self.picking = None;
        match picking {
            Picking::Repo => {
                if !self.repos.iter().any(|r| r.eq_ignore_ascii_case(&repo)) {
                    self.repos.push(repo);
                }
            }
            Picking::Project => {
                let Some(org) = self.org.clone() else { return };
                crate::projects::add_harness(&org, &repo);
                self.selected = Some(repo.clone());
                self.note = Some((format!("Added {repo} as a project."), false));
                self.changed_projects(window, cx);
            }
        }
        cx.notify();
    }

    /// Settings on this Mac changed: read the projects again, here and in
    /// the workspace.
    fn changed_projects(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        cx.emit(ProjectsChanged);
        self.load(window, cx);
    }

    fn remove(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        let is_home = self.projects.first().is_some_and(|p| p.id == id);
        let next = self.projects.get(1).map(|p| p.name.clone());
        let detail = match (is_home, next) {
            (true, Some(next)) => format!("{id} and everything in it are untouched. It's home, so {next} becomes home, and the org's data is read from its harness from then on."),
            _ => format!("{id} and everything in it are untouched; the pilot stops reading it."),
        };
        let name = self.projects.iter().find(|p| p.id == id).map(|p| p.name.clone()).unwrap_or_else(|| id.clone());
        let answer = window.prompt(gpui::PromptLevel::Warning, &format!("Remove {name}?"), Some(&detail), &["Remove Project", "Cancel"], cx);
        let window_handle = window.window_handle();
        cx.spawn(async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            crate::projects::remove_harness(&org, &id);
            let _ = cx.update_window(window_handle, |_, window, cx| {
                let _ = this.update(cx, |page, cx| {
                    if page.selected.as_deref() == Some(id.as_str()) {
                        page.selected = None;
                    }
                    page.note = Some((format!("Removed {name}."), false));
                    page.changed_projects(window, cx);
                });
            });
        })
        .detach();
    }

    fn make_home(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(org) = self.org.clone() else { return };
        let home = self.projects.first().map(|p| p.id.clone()).unwrap_or_default();
        let detail = format!("People's dates, leave, the working week, exclusions and views are read from home's harness. Nothing is copied: what {home} keeps stays there, and {id}'s own copy, if it has one, is read instead.");
        let answer = window.prompt(gpui::PromptLevel::Info, "Make it home?", Some(&detail), &["Make Home", "Cancel"], cx);
        let window_handle = window.window_handle();
        cx.spawn(async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            crate::projects::make_home(&org, &id);
            let _ = cx.update_window(window_handle, |_, window, cx| {
                let _ = this.update(cx, |page, cx| page.changed_projects(window, cx));
            });
        })
        .detach();
    }

    /// Commits the project's name and repos to its harness, asked first.
    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(org), Some(project)) = (self.org.clone(), self.project().cloned()) else { return };
        let name = self.typed_name(cx);
        if name.is_empty() {
            self.note = Some(("A project needs a name.".into(), true));
            cx.notify();
            return;
        }
        let repos = self.repos.clone();
        let harness = project.id.clone();
        let listed = if repos.is_empty() { "every repo".to_string() } else { repos.iter().map(|r| short(r)).collect::<Vec<_>>().join(", ") };
        let detail = format!("Commits .gannin/project.json to {harness}: {name}, {listed}. Everyone who has {harness} as a project gets the same, and git keeps the history.");
        let answer = window.prompt(gpui::PromptLevel::Info, "Save to the harness?", Some(&detail), &["Commit", "Cancel"], cx);
        let headline = format!("Update project {name}");
        let window_handle = window.window_handle();
        cx.spawn(async move |this, cx| {
            if answer.await.ok() != Some(0) {
                return;
            }
            let _ = this.update(cx, |page, cx| {
                page.saving = true;
                page.note = None;
                cx.notify();
            });
            let committed = cx
                .background_executor()
                .spawn({
                    let (harness, name, repos) = (harness.clone(), name.clone(), repos.clone());
                    async move {
                        let token = crate::auth::token().ok_or("Sign in to GitHub first.")?;
                        let result = crate::review_record::commit_file(&token, &harness, ".gannin/project.json", &headline, &|existing| Some(crate::projects::project_file(existing, &name, &repos)));
                        crate::harness_git::refetch(&org, &harness);
                        result
                    }
                })
                .await;
            let _ = cx.update_window(window_handle, |_, window, cx| {
                let _ = this.update(cx, |page, cx| {
                    page.saving = false;
                    match committed {
                        Ok(Some(pull)) => page.note = Some((format!("{harness} needs changes reviewed, so it's in a pull request: {pull}"), false)),
                        Ok(None) => page.note = Some((format!("Saved to {harness}."), false)),
                        Err(error) => page.note = Some((format!("Couldn't save: {error}"), true)),
                    }
                    // Taken as saved, so a reload before the harness is read again keeps it.
                    if let Some(p) = page.projects.iter_mut().find(|p| p.id == harness) {
                        p.name = name.clone();
                        p.repos = repos.clone();
                    }
                    page.changed_projects(window, cx);
                });
            });
        })
        .detach();
    }

    fn revert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let id = self.selected.clone();
        self.select(id, window, cx);
    }

    // MARK: Pieces

    fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, primary: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .flex_none()
            .px_2p5()
            .py_0p5()
            .rounded_md()
            .border_1()
            .text_sm()
            .cursor_pointer()
            .map(|d| if primary { d.bg(theme.selected).border_color(theme.selected).text_color(theme.on_selected) } else { d.border_color(theme.border).hover(|s| s.bg(theme.row_selected)) })
            .child(label.into())
    }

    fn badge(label: &'static str, color: gpui::Hsla) -> impl IntoElement {
        div().flex_none().px_1p5().rounded_full().text_xs().bg(color.opacity(0.15)).text_color(color).child(label)
    }

    fn field(editor: &Entity<editor::Editor>, width: f32, theme: &Theme) -> impl IntoElement {
        div().w(px(width)).px_2().py_1().rounded_md().bg(theme.tile).border_1().border_color(theme.border).child(editor.clone())
    }

    fn outside(&self, repo: &str) -> bool {
        self.org.as_deref().is_some_and(|org| !repo.split('/').next().unwrap_or("").eq_ignore_ascii_case(org))
    }

    /// The repo picker: the account's repos not taken, filtered by what's
    /// typed, and the typed `owner/name` when it isn't listed.
    fn picker(&self, picking: Picking, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let query = self.search.read(cx).text(cx).trim().to_lowercase();
        let taken: Vec<String> = match picking {
            Picking::Project => self.projects.iter().map(|p| p.id.to_lowercase()).collect(),
            Picking::Repo => self.repos.iter().map(|r| r.to_lowercase()).collect(),
        };
        let all = self.account_repos.clone();
        let matches: Vec<String> = all.iter().flatten().filter(|r| !taken.contains(&r.to_lowercase()) && (query.is_empty() || r.to_lowercase().contains(&query))).take(60).cloned().collect();
        let typed = typed_repo(&query).filter(|t| !taken.contains(t) && !all.iter().flatten().any(|r| r.eq_ignore_ascii_case(t)));
        let row = |id: String, label: String, detail: Option<&'static str>, repo: String, listed: bool, cx: &mut Context<Self>| {
            div()
                .id(SharedString::from(id))
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .px_2()
                .py_1()
                .rounded_sm()
                .text_sm()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| page.pick(repo.clone(), listed, window, cx)))
                .child(div().flex_1().min_w_0().truncate().child(label))
                .when_some(detail, |d, detail| d.child(div().flex_none().text_xs().text_color(theme.secondary).child(detail)))
        };
        div()
            .flex()
            .flex_col()
            .gap_1()
            .p_2()
            .w(px(420.))
            .rounded_md()
            .border_1()
            .border_color(theme.border)
            .bg(theme.popover)
            .child(Self::field(&self.search, 402., theme))
            .child(
                div()
                    .id("picker-list")
                    .max_h(px(260.))
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .when_some(typed, |d, typed| {
                        let detail = if picking == Picking::Repo && self.outside(&typed) { Some("Outside, checked with GitHub") } else { Some("Checked with GitHub") };
                        d.child(row(format!("typed-{typed}"), format!("Add {typed}"), detail, typed.clone(), false, cx))
                    })
                    .children(matches.into_iter().map(|repo| row(format!("pick-{repo}"), repo.clone(), None, repo, true, cx)))
                    .when(all.is_none(), |d| d.child(div().px_2().py_1().text_sm().text_color(theme.secondary).child("Listing the repositories")))
                    .when(self.checking, |d| d.child(div().px_2().py_1().text_sm().text_color(theme.secondary).child("Checking with GitHub"))),
            )
    }

    fn projects_list(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let home = self.projects.first().map(|p| p.id.clone());
        div()
            .flex()
            .flex_col()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .overflow_hidden()
            .children(self.projects.iter().enumerate().map(|(i, project)| {
                let selected = self.selected.as_deref() == Some(project.id.as_str());
                let is_home = home.as_deref() == Some(project.id.as_str());
                let repos = if project.repos.is_empty() { "every repo".to_string() } else if project.repos.len() == 1 { "1 repo".into() } else { format!("{} repos", project.repos.len()) };
                let (select, home_id, remove) = (project.id.clone(), project.id.clone(), project.id.clone());
                div()
                    .id(("project", i))
                    .group(SharedString::from(format!("project-{i}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_3()
                    .py_2()
                    .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(theme.row_selected))
                    .hover(|s| s.bg(theme.row_selected))
                    .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| page.select(Some(select.clone()), window, cx)))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .child(div().text_sm().font_weight(if selected { FontWeight::SEMIBOLD } else { FontWeight::NORMAL }).child(project.name.clone()))
                                    .when(is_home, |d| d.child(Self::badge("Home", theme.selected))),
                            )
                            .child(div().text_xs().text_color(theme.secondary).truncate().child(format!("{}, {repos}", project.id))),
                    )
                    .when(!is_home, |d| {
                        d.child(
                            div()
                                .id(("make-home", i))
                                .invisible()
                                .group_hover(SharedString::from(format!("project-{i}")), |s| s.visible())
                                .text_xs()
                                .text_color(theme.blue())
                                .cursor_pointer()
                                .tooltip(|_, cx| cx.new(|_| Tooltip("Read the org's data from this project's harness".into())).into())
                                .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| {
                                    cx.stop_propagation();
                                    page.make_home(home_id.clone(), window, cx);
                                }))
                                .child("Make Home"),
                        )
                    })
                    .child(
                        div()
                            .id(("remove-project", i))
                            .px_1()
                            .rounded_sm()
                            .text_color(theme.tertiary)
                            .hover(|s| s.bg(theme.border))
                            .tooltip(|_, cx| cx.new(|_| Tooltip("Remove this project; its harness is untouched".into())).into())
                            .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| {
                                cx.stop_propagation();
                                page.remove(remove.clone(), window, cx);
                            }))
                            .child("×"),
                    )
            }))
    }

    fn details(&self, project: &Project, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let changed = self.changed(cx);
        let label = |text: &str| div().w(px(110.)).flex_none().pt_1().text_sm().text_color(theme.secondary).child(text.to_string());
        div()
            .flex()
            .flex_col()
            .gap_3()
            .p_4()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .child(div().text_base().font_weight(FontWeight::SEMIBOLD).child(project.name.clone()))
            .child(div().flex().flex_row().child(label("Name")).child(Self::field(&self.name, 280., theme)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .child(label("Repositories"))
                    .child(
                        div()
                            .flex_1()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .flex_wrap()
                                    .items_center()
                                    .gap_1p5()
                                    .when(self.repos.is_empty(), |d| d.child(div().text_sm().text_color(theme.orange()).child("None yet: every repo")))
                                    .children(self.repos.iter().enumerate().map(|(i, repo)| {
                                        let outside = self.outside(repo);
                                        let gone = repo.clone();
                                        div()
                                            .flex()
                                            .flex_row()
                                            .items_center()
                                            .gap_1()
                                            .pl_2()
                                            .pr_1()
                                            .py_0p5()
                                            .rounded_full()
                                            .bg(theme.tile)
                                            .border_1()
                                            .border_color(theme.border)
                                            .text_sm()
                                            .child(if outside { repo.clone() } else { short(repo).to_string() })
                                            .when(outside, |d| d.child(Self::badge("Outside", theme.orange())))
                                            .child(
                                                div()
                                                    .id(("remove-repo", i))
                                                    .px_1()
                                                    .rounded_full()
                                                    .text_color(theme.tertiary)
                                                    .cursor_pointer()
                                                    .hover(|s| s.bg(theme.row_selected))
                                                    .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                                                        page.repos.retain(|r| r != &gone);
                                                        cx.notify();
                                                    }))
                                                    .child("×"),
                                            )
                                    }))
                                    .child(Self::button("add-repo", "Add Repository", false, theme).on_click(cx.listener(|page, _: &ClickEvent, window, cx| page.open_picker(Picking::Repo, window, cx)))),
                            )
                            .when(self.picking == Some(Picking::Repo), |d| d.child(self.picker(Picking::Repo, theme, cx)))
                            .child(div().text_xs().text_color(theme.secondary).child("Every other repo is left out of this project's pages. With none, it covers every repo the account owns.")),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .pt_1()
                    .child(div().flex_1().text_xs().text_color(theme.secondary).child(format!("Saved in {} as .gannin/project.json, so anyone who adds it as a project gets the same.", project.id)))
                    .when(changed, |d| d.child(Self::button("revert", "Revert", false, theme).on_click(cx.listener(|page, _: &ClickEvent, window, cx| page.revert(window, cx)))))
                    .child(
                        Self::button("save", if self.saving { "Saving" } else { "Save to Harness" }, changed, theme)
                            .when(!changed || self.saving, |d| d.opacity(0.5))
                            .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| {
                                if changed && !page.saving {
                                    page.save(window, cx);
                                }
                            })),
                    ),
            )
    }
}

impl Render for SettingsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let body = if self.org.is_none() {
            div().text_sm().text_color(theme.secondary).child("Open a folder to choose an org.").into_any_element()
        } else {
            let selected = self.project().cloned();
            div()
                .flex()
                .flex_col()
                .gap_3()
                .max_w(px(760.))
                .child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child("Projects"))
                .child(div().text_sm().text_color(theme.secondary).child(
                    "A project is a harness and the code repos it's for. Its name and repos are kept in its harness; which harnesses are projects, and which is home, is this Mac's own. Home's harness also keeps the org's data: people's dates and time off, the working week, repos and people left out.",
                ))
                .when(self.loading && self.projects.is_empty(), |d| d.child(div().text_sm().text_color(theme.secondary).child("Reading the harnesses")))
                .when(!self.projects.is_empty(), |d| d.child(self.projects_list(&theme, cx)))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(Self::button("add-project", "Add Project", false, &theme).tooltip(|_, cx| cx.new(|_| Tooltip("Make one of the account's repos, or one typed as owner/name, a project's harness".into())).into()).on_click(cx.listener(|page, _: &ClickEvent, window, cx| page.open_picker(Picking::Project, window, cx))))
                        .when(self.picking == Some(Picking::Project), |d| d.child(self.picker(Picking::Project, &theme, cx))),
                )
                .when_some(self.note.clone(), |d, (note, error)| d.child(div().text_sm().text_color(if error { theme.critical() } else { theme.secondary }).child(note)))
                .when_some(selected, |d, project| d.child(self.details(&project, &theme, cx)))
                .into_any_element()
        };
        div()
            .id("settings")
            .size_full()
            .overflow_y_scroll()
            .bg(theme.bg)
            .text_color(theme.fg)
            .p_6()
            .child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_repos_read_from_names_and_addresses() {
        assert_eq!(typed_repo("andrew-waters/gannin").as_deref(), Some("andrew-waters/gannin"));
        assert_eq!(typed_repo("https://github.com/ctrl-hub/clients.git").as_deref(), Some("ctrl-hub/clients"));
        assert_eq!(typed_repo("gannin"), None);
        assert_eq!(typed_repo("a/b c"), None);
    }
}
