//! A review session, laid out as Gannin's review tab: a header with the
//! verdict, how ready it is to merge and the effort; the files in the
//! walkthrough's areas down the side, with Overview, findings not on a
//! changed file and learnings above them; the selected one's detail beside
//! it (the Overview leads with the verdict, with the merge risk in a sidebar
//! on its right when there's room); and the conversation with claude (its terminal and a box to tell it
//! something) in a pane along the bottom, shown while claude works.
//!
//! Post Review's sheet shows exactly what would go to GitHub and posts only
//! when the person clicks Post to GitHub.

use crate::charts::Theme;
use crate::launch::Launch;
use crate::markdown::markdown;
use crate::review::{self, Draft, Finding, ReviewResult, Snapshot};
use gpui::{div, prelude::*, px, AnyView, ClickEvent, Context, Entity, Focusable, FontWeight, Hsla, KeyDownEvent, SharedString, Task, Window};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};
use terminal::Terminal;

/// The Post Review sheet, step by step.
pub enum Post {
    Loading,
    Ready { snapshot: Arc<Snapshot>, draft: Arc<Draft>, event: &'static str, body: Entity<editor::Editor> },
    Posting,
    Posted(String),
    Failed(String),
}

/// Where a panel's review comes from: a live session, or the Review
/// Preview's made-up one, which never runs claude or calls GitHub.
enum Source {
    Live { launch: Launch, terminal: Entity<Terminal>, view: AnyView },
    Preview { repo: String, number: i64, url: String, idle: bool, working: bool, snapshot: Arc<Snapshot> },
}

/// A review posted to GitHub: its kind (as GitHub names it), when, and
/// its link. Kept in the session's folder so it's known after a relaunch.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct Posted {
    pub event: String,
    pub at: chrono::DateTime<chrono::Utc>,
    pub url: String,
}

/// Ask the workspace to explain this PR in a session of its own.
pub struct ExplainPr(pub crate::launch::Subject, pub Vec<review::Area>);

impl gpui::EventEmitter<ExplainPr> for ReviewPanel {}
impl gpui::EventEmitter<crate::harness::OpenDoc> for ReviewPanel {}

/// "Approved", "Changes requested" or "Commented", from GitHub's event or
/// review state.
fn posted_label(event: &str) -> &'static str {
    match event {
        "APPROVE" | "APPROVED" => "Approved",
        "REQUEST_CHANGES" | "CHANGES_REQUESTED" => "Changes requested",
        "COMMENT" | "COMMENTED" => "Commented",
        _ => "Posted",
    }
}

/// "just now", "5 minutes ago", "3 hours ago", else the date.
fn ago(at: chrono::DateTime<chrono::Utc>) -> String {
    let seconds = (chrono::Utc::now() - at).num_seconds().max(0);
    match seconds {
        0..60 => "just now".into(),
        60..3600 => plural((seconds / 60) as usize, "minute ago", "minutes ago"),
        3600..86400 => plural((seconds / 3600) as usize, "hour ago", "hours ago"),
        _ => at.with_timezone(&chrono::Local).format("%-d %b").to_string(),
    }
}

/// What the detail column shows.
#[derive(Clone, PartialEq)]
enum Selected {
    Overview,
    /// Findings on files the walkthrough doesn't list.
    General,
    Learnings,
    File(String),
    /// The PR page's parts, with `pull` set.
    Timeline,
    Commits,
    Checks,
}

/// The PR page laid into the panel, each part its own `PullPage`: the
/// merged PR and review sketch in Review Preview.
pub struct PullParts {
    description: Entity<crate::pull_page::PullPage>,
    timeline: Entity<crate::pull_page::PullPage>,
    commits: Entity<crate::pull_page::PullPage>,
    checks: Entity<crate::pull_page::PullPage>,
    sidebar: Entity<crate::pull_page::PullPage>,
}

impl PullParts {
    /// A made-up pull request's parts.
    pub fn preview(repo: &str, number: i64, title: &str, cx: &mut gpui::App) -> Self {
        use crate::pull_page::{Part, PullPage};
        let mut part = |p: Part| cx.new(|_| PullPage::preview(repo, number, title, p));
        Self {
            description: part(Part::Description),
            timeline: part(Part::Timeline),
            commits: part(Part::Commits),
            checks: part(Part::Checks),
            sidebar: part(Part::Sidebar),
        }
    }
}

/// How long claude's input takes to be ready after its SessionStart hook.
const SETTLE: Duration = Duration::from_millis(1500);
/// How long Review Again waits for claude to show it took the prompt.
const AGAIN_PATIENCE: Duration = Duration::from_secs(60);

pub struct ReviewPanel {
    /// The panel's own focus, so the window's shortcuts work with the
    /// terminal hidden.
    pub focus: gpui::FocusHandle,
    source: Source,
    result: Option<ReviewResult>,
    dismissed: HashSet<String>,
    /// A finding's text as the person rewrote it, by the finding's key.
    edits: HashMap<String, String>,
    /// The finding being edited, and its editor.
    editing: Option<(String, Entity<editor::Editor>)>,
    selected: Selected,
    /// The Conversation pane, once the person has toggled it; until then it
    /// follows claude (shown while it works or before a result).
    conversation: Option<bool>,
    /// What claude is doing now, from its transcript.
    activity: Option<String>,
    /// The Conversation pane's height, and while its edge is dragged, where
    /// the drag began (the pointer's y and the height then).
    conversation_height: f32,
    resizing: Option<(f32, f32)>,
    composer: Entity<editor::Editor>,
    /// The team's prompt shortcuts beside the composer.
    shortcuts: Entity<crate::shortcuts::ShortcutBar>,
    post: Option<Post>,
    posted: Option<Posted>,
    /// The last Check for Changes: when, and what it found or why it failed.
    checked: Option<(chrono::DateTime<chrono::Utc>, Result<review::Changes, String>)>,
    checking: bool,
    /// Something to say about the review's record in the harness (a pull
    /// request left open, or a failure).
    record_note: Option<String>,
    /// What resolving the threads claude says are dealt with did.
    resolve_note: Option<String>,
    /// The hooks' state file as last read, to redraw when it changes.
    seen_state: Option<String>,
    /// When claude was first seen past starting (its SessionStart hook ran),
    /// for `ready`; and when the panel opened, for its fallback.
    started_at: Option<Instant>,
    /// When Review Again was pressed, until claude's state shows it took
    /// it: the hooks take a few seconds to say so, and till then the button
    /// would stay live and the banner wouldn't show.
    again_sent: Option<Instant>,
    opened_at: Instant,
    /// The team's sensitive paths for this PR's repo, read once.
    sensitive: Vec<crate::risk::Sensitive>,
    /// The harness documents about or mentioning the PR or the issues it
    /// closes, with their progress: empty until found, or when none.
    plans: Vec<(crate::harness::Doc, bool)>,
    /// Who opened the PR, once read; shown beside its number.
    author: Option<review::Author>,
    /// Record it in the harness when posting (the app-wide setting).
    record_with_post: bool,
    /// The detail area's width as last laid out: wide enough, the Overview
    /// puts the merge risk in a sidebar on its right.
    detail_width: std::rc::Rc<std::cell::Cell<f32>>,
    /// Whether the risk sidebar shows how the grade was reached, and the
    /// acceptance criteria that need nothing doing.
    show_grading: bool,
    show_criteria: bool,
    /// Each changed file's diff from GitHub, made when it's first shown.
    diffs: HashMap<String, Entity<crate::pr_diff::PrDiff>>,
    /// The PR page merged in (the sketch only): its parts in the list, the
    /// Overview and a sidebar.
    pull: Option<PullParts>,
    _poll: Option<Task<()>>,
    /// Redraws the relative times now and then.
    _clock: Task<()>,
}

fn severity_tint(severity: Option<&str>, theme: &Theme) -> Hsla {
    match severity {
        Some("blocker") => theme.critical(),
        Some("major") => theme.orange(),
        Some("minor") => gpui::rgb(0xEDA100).into(),
        _ => theme.secondary,
    }
}

pub fn risk_tint(level: crate::risk::Level, theme: &Theme) -> Hsla {
    match level {
        crate::risk::Level::Low => theme.good(),
        crate::risk::Level::Medium => theme.orange(),
        crate::risk::Level::High => theme.critical(),
    }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

fn capitalised(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
}

fn file_name(path: &str) -> (&str, &str) {
    match path.rsplit_once('/') {
        Some((folder, name)) => (name, folder),
        None => (path, ""),
    }
}

impl ReviewPanel {
    fn clock(cx: &mut Context<Self>) -> Task<()> {
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_secs(30)).await;
            if this.update(cx, |_, cx| cx.notify()).is_err() {
                return;
            }
        })
    }

    /// The shortcuts beside the composer: from the session's harness, and
    /// sent as if typed.
    fn shortcut_bar(place: Option<(&str, &str)>, window: &mut Window, cx: &mut Context<Self>) -> Entity<crate::shortcuts::ShortcutBar> {
        let bar = cx.new(|cx| {
            let mut bar = crate::shortcuts::ShortcutBar::new();
            if let Some((org, harness)) = place {
                bar.set_place(org, harness, cx);
            }
            bar
        });
        cx.subscribe_in(&bar, window, |this, _, event: &crate::shortcuts::SendShortcut, window, cx| {
            if this.takes_input() {
                this.conversation = Some(true);
                this.tell(event.0.clone(), window, cx);
            }
        })
        .detach();
        bar
    }

    fn composer(window: &mut Window, cx: &mut Context<Self>) -> Entity<editor::Editor> {
        cx.new(|cx| {
            let mut editor = editor::Editor::single_line(window, cx);
            editor.set_placeholder_text("Tell claude something", window, cx);
            editor
        })
    }

    pub fn new(launch: Launch, terminal: Entity<Terminal>, view: AnyView, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let claude_id = launch.claude_id();
        let state_file = launch.dir().join("state");
        let sensitive = launch.subject.as_ref().map(|s| crate::risk::sensitive_paths(&launch.harness_path, &s.repo)).unwrap_or_default();
        // The transcript is read again every few seconds, off the main
        // thread, until a result is there and whenever it may have changed.
        let poll = cx.spawn(async move |this, cx| loop {
            let id = claude_id.clone();
            let file = state_file.clone();
            let (result, activity, state) = cx
                .background_executor()
                .spawn(async move { (review::read_result(&id), review::activity(&id), std::fs::read_to_string(&file).ok()) })
                .await;
            if this
                .update(cx, |this, cx| {
                    if result.is_some() && this.result != result {
                        let first = this.checked.is_none();
                        this.result = result;
                        this.remember_risk(cx);
                        // A check once there's a result, so Review Again knows
                        // whether anything's changed since.
                        if first {
                            this.check_for_changes(cx);
                        }
                        this.auto_post(cx);
                        cx.notify();
                    }
                    // Review Again goes by the hooks' state, which can
                    // change with nothing else in the transcript.
                    if this.seen_state != state {
                        this.seen_state = state;
                        if this.again_sent.is_some() && !this.idle() {
                            this.again_sent = None;
                        }
                        cx.notify();
                    }
                    // Claude's up: its input takes a moment more to be
                    // ready, so the buttons wait that long, then redraw.
                    if this.started_at.is_none() && this.claude_state().is_some_and(|s| s != "starting") {
                        this.started_at = Some(Instant::now());
                        cx.spawn(async move |this, cx| {
                            cx.background_executor().timer(SETTLE).await;
                            this.update(cx, |_, cx| cx.notify()).ok();
                        })
                        .detach();
                    }
                    if this.activity != activity {
                        this.activity = activity;
                        cx.notify();
                    }
                })
                .is_err()
            {
                return;
            }
            let fast = this.read_with(cx, |this, _| !this.takes_input()).unwrap_or(false);
            cx.background_executor().timer(if fast { Duration::from_millis(750) } else { Duration::from_secs(4) }).await;
        });
        let posted = std::fs::read(launch.dir().join("posted.json")).ok().and_then(|b| serde_json::from_slice(&b).ok());
        let decisions: serde_json::Value = std::fs::read(launch.dir().join("decisions.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let dismissed = decisions["dismissed"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
        let edits = decisions["edits"].as_object().map(|m| m.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string()))).collect()).unwrap_or_default();
        // The plans linked to the PR or the issues it closes, once, off the
        // main thread: how far the work it delivers has got.
        if let Some(subject) = launch.subject.clone() {
            let org = launch.org.clone();
            cx.spawn(async move |this, cx| {
                let (author, plans) = cx
                    .background_executor()
                    .spawn(async move {
                        let mut items = vec![(subject.repo.clone(), subject.number)];
                        let mut author = None;
                        if let Some(token) = crate::auth::token() {
                            if let Ok((who, closing)) = review::pr_facts(&token, &subject.repo, subject.number) {
                                author = who;
                                items.extend(closing);
                            }
                        }
                        (author, crate::harness::linked(&crate::harness::load(&org), &items))
                    })
                    .await;
                this.update(cx, |this, cx| {
                    this.author = author;
                    this.plans = plans;
                    cx.notify();
                })
                .ok();
            })
            .detach();
        }
        let shortcuts = Self::shortcut_bar(Some((&launch.org, &launch.harness_repo)), window, cx);
        Self {
            focus: cx.focus_handle(),
            posted,
            checked: None,
            checking: false,
            record_note: None,
            resolve_note: None,
            seen_state: None,
            started_at: None,
            again_sent: None,
            opened_at: Instant::now(),
            plans: Vec::new(),
            author: None,
            record_with_post: crate::review_record::recording(),
            detail_width: Default::default(),
            show_grading: false,
            show_criteria: false,
            diffs: HashMap::new(),
            pull: None,
            _clock: Self::clock(cx),
            source: Source::Live { launch, terminal, view },
            sensitive,
            result: None,
            dismissed,
            edits,
            editing: None,
            selected: Selected::Overview,
            conversation: None,
            activity: None,
            conversation_height: 260.,
            resizing: None,
            composer: Self::composer(window, cx),
            shortcuts,
            post: None,
            _poll: Some(poll),
        }
    }

    /// A panel showing a made-up review in one state, for the Review
    /// Preview. `idle` is whether claude would be waiting for the person,
    /// `working` whether it's busy.
    #[allow(clippy::too_many_arguments)]
    pub fn preview(
        repo: &str,
        number: i64,
        result: Option<ReviewResult>,
        idle: bool,
        working: bool,
        snapshot: Snapshot,
        post: Option<Post>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let posted = matches!(post, Some(Post::Posted(_))).then(|| Posted { event: "COMMENT".into(), at: chrono::Utc::now(), url: format!("https://github.com/{repo}/pull/{number}") });
        Self {
            focus: cx.focus_handle(),
            posted,
            checked: None,
            checking: false,
            record_note: None,
            resolve_note: None,
            seen_state: None,
            started_at: None,
            again_sent: None,
            opened_at: Instant::now(),
            sensitive: Vec::new(),
            plans: Vec::new(),
            author: None,
            record_with_post: crate::review_record::recording(),
            detail_width: Default::default(),
            show_grading: false,
            show_criteria: false,
            diffs: HashMap::new(),
            pull: None,
            _clock: Self::clock(cx),
            source: Source::Preview { repo: repo.into(), number, url: format!("https://github.com/{repo}/pull/{number}"), idle, working, snapshot: Arc::new(snapshot) },
            result,
            dismissed: HashSet::new(),
            edits: HashMap::new(),
            editing: None,
            selected: Selected::Overview,
            conversation: None,
            activity: None,
            conversation_height: 260.,
            resizing: None,
            composer: Self::composer(window, cx),
            shortcuts: Self::shortcut_bar(None, window, cx),
            post,
            _poll: None,
        }
    }

    /// Merges the PR page in: the sketch in Review Preview.
    pub fn with_pull(mut self, parts: PullParts) -> Self {
        self.pull = Some(parts);
        self
    }

    fn subject(&self) -> (String, i64) {
        match &self.source {
            Source::Live { launch, .. } => launch.subject.as_ref().map(|s| (s.repo.clone(), s.number)).unwrap_or_default(),
            Source::Preview { repo, number, .. } => (repo.clone(), *number),
        }
    }

    fn title(&self) -> Option<String> {
        match &self.source {
            Source::Live { launch, .. } => launch.subject.as_ref().map(|s| s.title.clone()).filter(|t| !t.is_empty()),
            Source::Preview { .. } => Some("Idempotency keys for payments".into()),
        }
    }

    fn url(&self) -> String {
        match &self.source {
            Source::Live { launch, .. } => launch.subject.as_ref().map(|s| s.url.clone()).unwrap_or_default(),
            Source::Preview { url, .. } => url.clone(),
        }
    }

    /// Where claude is: working, needs-you, idle, or ended (None when it
    /// hasn't said).
    fn claude_state(&self) -> Option<String> {
        match &self.source {
            Source::Live { launch, .. } => launch.state(),
            Source::Preview { idle, working, .. } => Some(if *working { "working" } else if *idle { "idle" } else { "exited" }.into()),
        }
    }

    /// The merge risk, with the team's floors applied: None before a
    /// result, or when claude gave none.
    fn risk(&self) -> Option<crate::risk::Risk> {
        let result = self.result.as_ref()?;
        let changed: Vec<String> = result.walkthrough.iter().flat_map(|a| a.files.iter().cloned()).collect();
        Some(result.risk.clone()?.assessed(&changed, &self.sensitive))
    }

    /// Keeps the grade beside the session and for the Pull Requests table.
    fn remember_risk(&self, cx: &mut Context<Self>) {
        let Source::Live { launch, .. } = &self.source else { return };
        let Some(subject) = launch.subject.as_ref() else { return };
        let Some(level) = self.risk().and_then(|r| r.level()) else { return };
        let at = self.result.as_ref().and_then(|r| r.at).unwrap_or_else(chrono::Utc::now);
        if crate::risk::remember(&subject.id, &launch.dir(), level, at) {
            cx.refresh_windows();
        }
    }

    /// Whether claude's terminal takes input: its SessionStart hook has run
    /// (the state's past "starting") and a moment's passed. A session whose
    /// hooks never say (one from before the state was reset on resume) is
    /// taken as ready a while after the panel opened.
    fn takes_input(&self) -> bool {
        if matches!(self.source, Source::Preview { .. }) {
            return true;
        }
        self.started_at.is_some_and(|at| at.elapsed() >= SETTLE) || (self.claude_state().as_deref() == Some("starting") && self.opened_at.elapsed() >= Duration::from_secs(45))
    }

    /// Whether claude is waiting for the person, so Review Again can go.
    fn idle(&self) -> bool {
        self.claude_state().as_deref() == Some("idle")
    }

    /// Review Again was pressed and claude hasn't shown it's started yet.
    /// Given up on after a while, so a prompt claude never took doesn't
    /// leave the button off.
    fn again_pending(&self) -> bool {
        self.again_sent.is_some_and(|at| at.elapsed() < AGAIN_PATIENCE) && self.idle()
    }

    fn working(&self) -> bool {
        !matches!(self.claude_state().as_deref(), Some("idle") | Some("exited") | Some("stopped") | Some("needs-you"))
    }

    fn running(&self) -> bool {
        !matches!(self.claude_state().as_deref(), Some("exited") | Some("stopped"))
    }

    /// The terminal shows only when asked for: the review page says what
    /// claude is doing without it.
    fn shows_conversation(&self) -> bool {
        self.conversation.unwrap_or(false)
    }

    /// The findings as they'd go out: dismissed ones left out, edited ones
    /// with the person's text.
    fn kept(&self) -> Option<ReviewResult> {
        let mut result = self.result.clone()?;
        result.findings = result
            .findings
            .into_iter()
            .filter(|f| !self.dismissed.contains(&f.key()))
            .map(|mut f| {
                if let Some(text) = self.edits.get(&f.key()) {
                    f.comment = text.clone();
                }
                f
            })
            .collect();
        Some(result)
    }

    /// Findings on files the walkthrough doesn't list: those go in the
    /// review's body.
    fn general(&self) -> Vec<Finding> {
        let Some(result) = &self.result else { return Vec::new() };
        result.findings.iter().filter(|f| result.area_of(&f.path).is_none()).cloned().collect()
    }

    /// Sends text to claude as one message.
    fn tell(&mut self, text: String, window: &mut Window, cx: &mut Context<Self>) {
        let Source::Live { terminal, .. } = &self.source else { return };
        let terminal = terminal.clone();
        cx.spawn_in(window, async move |_, cx| {
            terminal.update(cx, |t, _| t.paste(&text));
            cx.background_executor().timer(Duration::from_millis(150)).await;
            terminal.update(cx, |t, _| t.input(b"\r".to_vec()));
        })
        .detach();
        cx.notify();
    }

    /// Sends what was typed, and shows the conversation, where claude's
    /// answer is. Review Again leaves it as it was: the panel shows the
    /// review being redone.
    fn send_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.composer.read(cx).text(cx).trim().to_string();
        if text.is_empty() {
            return;
        }
        if !self.takes_input() {
            return;
        }
        self.composer.update(cx, |editor, cx| editor.set_text("", window, cx));
        self.conversation = Some(true);
        self.tell(text, window, cx);
    }

    /// Whether Post Review is on: a result not posted yet, and no sheet open.
    pub fn can_post(&self) -> bool {
        self.result.is_some() && self.posted_latest().is_none() && self.post.is_none()
    }

    /// Whether Review Again is on: claude idle with a result, and the PR
    /// changed since.
    pub fn can_again(&self) -> bool {
        self.idle() && self.result.is_some() && self.has_changes() && !self.again_pending()
    }

    /// Whether Check for Changes is running.
    pub fn is_checking(&self) -> bool {
        self.checking
    }

    /// Asks claude to review it afresh, as Gannin's Review Again.
    pub fn review_again(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.takes_input() {
            return;
        }
        self.again_sent = Some(Instant::now());
        self.tell(crate::launch::REVIEW_AGAIN.to_string(), window, cx);
        // Redraw when the wait's given up on, in case nothing else does.
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(AGAIN_PATIENCE).await;
            this.update(cx, |_, cx| cx.notify()).ok();
        })
        .detach();
    }

    fn start_edit(&mut self, finding: &Finding, window: &mut Window, cx: &mut Context<Self>) {
        let key = finding.key();
        let text = self.edits.get(&key).cloned().unwrap_or_else(|| finding.comment.clone());
        let editor = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(3, 12, window, cx);
            editor.set_text(text, window, cx);
            editor
        });
        window.focus(&editor.focus_handle(cx), cx);
        self.editing = Some((key, editor));
        cx.notify();
    }

    /// Keeps the edit; the original text clears it.
    fn save_edit(&mut self, original: &str, cx: &mut Context<Self>) {
        let Some((key, editor)) = self.editing.take() else { return };
        let text = editor.read(cx).text(cx).trim().to_string();
        if text.is_empty() || text == original {
            self.edits.remove(&key);
        } else {
            self.edits.insert(key, text);
        }
        self.save_decisions();
        cx.notify();
    }

    /// Keeps the person's dismissals and edits in the session's folder, so
    /// closing the tab loses none of them.
    fn save_decisions(&self) {
        if let Source::Live { launch, .. } = &self.source {
            let decisions = serde_json::json!({ "dismissed": self.dismissed.iter().collect::<Vec<_>>(), "edits": self.edits });
            let _ = std::fs::write(launch.dir().join("decisions.json"), serde_json::to_vec(&decisions).unwrap_or_default());
        }
    }

    /// What closing the tab would leave behind: whether there's a result,
    /// whether it's posted, and how many findings are kept.
    pub fn closing(&self) -> (bool, bool, usize) {
        let kept = self.result.as_ref().map(|r| r.findings.iter().filter(|f| !self.dismissed.contains(&f.key())).count()).unwrap_or(0);
        (self.result.is_some(), self.posted_latest().is_some(), kept)
    }

    /// Claude's verdict, once there's a result.
    pub fn verdict(&self) -> Option<String> {
        self.result.as_ref().and_then(|r| r.verdict.clone())
    }

        /// Post Review, from outside (closing an unposted review).
    pub fn start_post(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_post(window, cx);
    }

    /// Redraws the sheet as its body is edited, so the preview of what
    /// GitHub will show keeps up. Ends with the editor.
    fn watch_body(&mut self, cx: &mut Context<Self>) {
        if let Some(Post::Ready { body, .. }) = &self.post {
            cx.subscribe(body, |_, _, event: &editor::EditorEvent, cx| {
                if matches!(event, editor::EditorEvent::BufferEdited) {
                    cx.notify();
                }
            })
            .detach();
        }
    }

    /// Opens the sheet: the PR, its files and what's been said, fetched now.
    fn open_post(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(result) = self.kept() else { return };
        let none = HashSet::new();
        let risk = self.risk();
        if let Source::Preview { snapshot, .. } = &self.source {
            self.post = Some(Self::ready(&result, &none, snapshot.clone(), risk.as_ref(), window, cx));
            self.watch_body(cx);
            cx.notify();
            return;
        }
        self.post = Some(Post::Loading);
        let (repo, number) = self.subject();
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let fetched = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to post a review.")?;
                    review::snapshot(&token, &repo, number).map_err(|e| format!("Couldn't load the pull request: {e}"))
                })
                .await;
            this.update_in(cx, |this, window, cx| {
                this.post = Some(match fetched {
                    Ok(snapshot) => Self::ready(&result, &HashSet::new(), Arc::new(snapshot), risk.as_ref(), window, cx),
                    Err(error) => Post::Failed(error),
                });
                this.watch_body(cx);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }
    /// The sheet ready to post: the draft from the findings kept, and the
    /// event the verdict suggests.
    pub fn ready(result: &ReviewResult, dismissed: &HashSet<String>, snapshot: Arc<Snapshot>, risk: Option<&crate::risk::Risk>, window: &mut Window, cx: &mut gpui::App) -> Post {
        let draft = review::draft(result, dismissed, &snapshot, risk);
        let event = review::default_event(result, snapshot.is_own());
        let text = draft.body.clone();
        let body = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(4, 14, window, cx);
            editor.set_text(text, window, cx);
            editor
        });
        Post::Ready { snapshot, draft: Arc::new(draft), event, body }
    }

    fn record_posted(&mut self, posted: Posted) {
        if let Source::Live { launch, .. } = &self.source {
            let _ = std::fs::write(launch.dir().join("posted.json"), serde_json::to_vec(&posted).unwrap_or_default());
        }
        self.posted = Some(posted);
    }

    /// The posted review, if it's for the latest result: a newer result
    /// isn't posted yet.
    fn posted_latest(&self) -> Option<&Posted> {
        self.posted.as_ref().filter(|p| self.result.as_ref().and_then(|r| r.at).is_none_or(|at| p.at >= at))
    }

    /// Checks GitHub for what's changed since the review (read only). A
    /// review of the viewer's found there counts as posted.
    pub fn check_for_changes(&mut self, cx: &mut Context<Self>) {
        if self.checking {
            return;
        }
        self.checking = true;
        cx.notify();
        let since = self.result.as_ref().and_then(|r| r.at);
        let (repo, number) = self.subject();
        let preview = matches!(self.source, Source::Preview { .. });
        cx.spawn(async move |this, cx| {
            let found = if preview {
                cx.background_executor().timer(Duration::from_millis(800)).await;
                Ok(review::Changes { state: "OPEN".into(), new_commits: 2, new_comments: 1, mine: None })
            } else {
                cx.background_executor()
                    .spawn(async move {
                        let token = crate::auth::token().ok_or("Sign in to check GitHub.")?;
                        review::check(&token, &repo, number, since)
                    })
                    .await
            };
            this.update(cx, |this, cx| {
                if let Ok(changes) = &found {
                    if let Some((state, at, url)) = &changes.mine {
                        if this.posted.as_ref().is_none_or(|p| p.at < *at) {
                            this.record_posted(Posted { event: state.clone(), at: *at, url: url.clone() });
                        }
                    }
                }
                let ended = matches!(&found, Ok(c) if c.state != "OPEN");
                this.checked = Some((chrono::Utc::now(), found));
                this.checking = false;
                if ended {
                    this.record(None, cx);
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Whether the last check found new commits or comments since the
    /// review, so reviewing again is worth it.
    fn has_changes(&self) -> bool {
        matches!(&self.checked, Some((_, Ok(c))) if c.state == "OPEN" && (c.new_commits > 0 || c.new_comments > 0))
    }

    /// The review as its record needs it (live sessions only).
    fn record_input(&self, posting: Option<(String, chrono::DateTime<chrono::Utc>)>) -> Option<crate::review_record::Input> {
        let Source::Live { launch, .. } = &self.source else { return None };
        let subject = launch.subject.as_ref()?;
        Some(crate::review_record::Input {
            harness: launch.harness_repo.clone(),
            repo: subject.repo.clone(),
            number: subject.number,
            pr_id: subject.id.clone(),
            title: subject.title.clone(),
            started_at: launch.created_at,
            result: self.result.clone(),
            dismissed: self.dismissed.clone(),
            edits: self.edits.clone(),
            posting,
        })
    }

    /// Writes or updates the review's record in the harness, off the main
    /// thread, unless recording is off.
    pub fn record(&mut self, posting: Option<(String, chrono::DateTime<chrono::Utc>)>, cx: &mut Context<Self>) {
        if !crate::review_record::recording() {
            return;
        }
        let Some(input) = self.record_input(posting) else { return };
        let task = cx.background_executor().spawn(async move {
            let token = crate::auth::token().ok_or("Not signed in".to_string())?;
            crate::review_record::record(&token, &input)
        });
        cx.spawn(async move |this, cx| {
            let outcome = task.await;
            this.update(cx, |this, cx| {
                this.record_note = match outcome {
                    Ok(note) => note,
                    Err(error) => Some(format!("Couldn't record the review in the harness: {error}")),
                };
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The record's last update, when the tab closes: it runs on after the
    /// panel's gone.
    pub fn record_on_close(&self, cx: &mut Context<Self>) {
        if !crate::review_record::recording() {
            return;
        }
        if let Some(input) = self.record_input(None) {
            cx.background_executor()
                .spawn(async move {
                    if let Some(token) = crate::auth::token() {
                        let _ = crate::review_record::record(&token, &input);
                    }
                })
                .detach();
        }
    }

    /// A review a review window started posts by itself, once, when its
    /// result is in: the event from the verdict, but an approval only when
    /// the schedule allows it (else a comment); then it's recorded.
    fn auto_post(&mut self, cx: &mut Context<Self>) {
        let Source::Live { launch, .. } = &self.source else { return };
        let dir = launch.dir();
        if !dir.join("auto-post").exists() || dir.join("auto-posted").exists() || self.posted_latest().is_some() {
            return;
        }
        let Some(result) = self.kept() else { return };
        let _ = std::fs::write(dir.join("auto-posted"), "");
        let (repo, number) = self.subject();
        let approve = crate::schedule::Schedule::load().settings.approve_by_itself;
        // An approval goes by itself only at low merge risk, with no
        // acceptance criterion missing.
        let risk = self.risk();
        let level = risk.as_ref().and_then(|r| r.level());
        cx.spawn(async move |this, cx| {
            let posted = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Not signed in")?;
                    let snapshot = review::snapshot(&token, &repo, number).map_err(|e| e.to_string())?;
                    let draft = review::draft(&result, &HashSet::new(), &snapshot, risk.as_ref());
                    let mut event = review::default_event(&result, snapshot.is_own());
                    let mut held = None;
                    if event == "APPROVE" && !approve {
                        event = "COMMENT";
                    } else if event == "APPROVE" && level != Some(crate::risk::Level::Low) {
                        event = "COMMENT";
                        held = Some(match level {
                            Some(level) => format!("Posted as a comment, not an approval: merge risk is {}.", level.title()),
                            None => "Posted as a comment, not an approval: the merge risk wasn't graded.".to_string(),
                        });
                    } else if event == "APPROVE" && risk.as_ref().is_some_and(|r| r.criteria_missing()) {
                        // Low risk says merging is safe, not that the work
                        // is done: an unmet criterion is a person's call.
                        event = "COMMENT";
                        held = Some("Posted as a comment, not an approval: an acceptance criterion isn't met.".to_string());
                    }
                    let url = review::post(&token, &repo, number, event, &draft, &snapshot).map_err(|e| e.to_string())?;
                    let resolved = review::resolve_threads(&token, &snapshot, &result.resolved);
                    let note = [held, resolved].into_iter().flatten().collect::<Vec<_>>().join(" ");
                    Ok::<_, String>((event, url, (!note.is_empty()).then_some(note)))
                })
                .await;
            this.update(cx, |this, cx| {
                match posted {
                    Ok((event, url, resolved)) => {
                        this.resolve_note = resolved;
                        let at = chrono::Utc::now();
                        this.record_posted(Posted { event: event.to_string(), at, url });
                        this.record(Some((event.to_string(), at)), cx);
                    }
                    Err(error) => this.record_note = Some(format!("Couldn't post by itself: {error}")),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// What the last check found, for beside its button.
    fn check_text(&self) -> Option<String> {
        if self.checking {
            return Some("Checking".into());
        }
        let (at, found) = self.checked.as_ref()?;
        Some(match found {
            Ok(changes) => format!("{}, checked {}", changes.summary(), ago(*at)),
            Err(_) => format!("Couldn't check GitHub, tried {}", ago(*at)),
        })
    }

    fn explain(&mut self, cx: &mut Context<Self>) {
        if let Source::Live { launch, .. } = &self.source {
            if let Some(subject) = launch.subject.clone() {
                let walkthrough = self.result.as_ref().map(|r| r.walkthrough.clone()).unwrap_or_default();
                cx.emit(ExplainPr(subject, walkthrough));
            }
        }
    }

    /// Sends it: only from the person's click on Post to GitHub. A preview
    /// only pretends, after a moment.
    fn confirm_post(&mut self, cx: &mut Context<Self>) {
        let Some(Post::Ready { snapshot, draft, event, body }) = self.post.take() else { return };
        let text = body.read(cx).text(cx);
        let draft = Draft { body: text, comments: draft.comments.clone(), left_out: draft.left_out.clone() };
        let (repo, number) = self.subject();
        let resolved = self.result.as_ref().map(|r| r.resolved.clone()).unwrap_or_default();
        self.post = Some(Post::Posting);
        cx.notify();
        if matches!(self.source, Source::Preview { .. }) {
            let url = format!("{}#pullrequestreview-0", self.url());
            cx.spawn(async move |this, cx| {
                cx.background_executor().timer(Duration::from_millis(1200)).await;
                this.update(cx, |this, cx| {
                    this.posted = Some(Posted { event: event.to_string(), at: chrono::Utc::now(), url: url.clone() });
                    this.post = Some(Post::Posted(url));
                    cx.notify();
                })
                .ok();
            })
            .detach();
            return;
        }
        cx.spawn(async move |this, cx| {
            let posted = cx
                .background_executor()
                .spawn(async move {
                    let token = crate::auth::token().ok_or("Sign in to post a review.")?;
                    let url = review::post(&token, &repo, number, event, &draft, &snapshot)?;
                    Ok::<_, String>((url, review::resolve_threads(&token, &snapshot, &resolved)))
                })
                .await;
            this.update(cx, |this, cx| {
                this.post = Some(match posted {
                    Ok((url, resolved)) => {
                        this.resolve_note = resolved;
                        let at = chrono::Utc::now();
                        this.record_posted(Posted { event: event.to_string(), at, url: url.clone() });
                        if this.record_with_post {
                            this.record(Some((event.to_string(), at)), cx);
                        }
                        Post::Posted(url)
                    }
                    Err(error) => Post::Failed(error.to_string()),
                });
                cx.notify();
            })
            .ok();
        })
        .detach();
    }


    // MARK: Pieces

    /// How ready it is to merge, from the findings still kept: the sentence
    /// and its colour, as Gannin's readiness line.
    fn readiness(&self, theme: &Theme) -> (String, Hsla) {
        let Some(result) = &self.result else {
            return ("Ready once the reviewer has finished".into(), theme.blue());
        };
        let kept: Vec<&Finding> = result.findings.iter().filter(|f| !self.dismissed.contains(&f.key())).collect();
        let count = |s: &str| kept.iter().filter(|f| f.severity.as_deref() == Some(s)).count();
        let (blockers, majors) = (count("blocker"), count("major"));
        let minor = kept.len() - blockers - majors;
        if blockers > 0 {
            (format!("Can't merge: {}", plural(blockers, "blocker", "blockers")), theme.critical())
        } else if majors > 0 {
            (format!("Not ready: {} to fix", plural(majors, "major point", "major points")), theme.orange())
        } else if self.working() {
            ("Ready once the reviewer has finished".into(), theme.blue())
        } else if minor > 0 {
            (format!("Ready to merge, with {}", plural(minor, "minor point", "minor points")), theme.good())
        } else {
            ("Ready to merge".into(), theme.good())
        }
    }

    /// Where the review stands, led by the verdict: the verdict as a
    /// coloured word (or where claude is, before there's one), the findings
    /// still kept by severity, and the effort. Claude's state is the
    /// header's dot.
    fn standing(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (status, status_tint) = self.status(theme);
        let (lead, lead_tint) = match self.result.as_ref().map(|r| r.verdict.as_deref()) {
            Some(Some("approve")) => ("Approve".to_string(), theme.good()),
            Some(Some("request_changes")) => ("Request changes".to_string(), theme.critical()),
            Some(_) => ("Comment".to_string(), theme.secondary),
            None => (if status.is_empty() { "Reviewing".to_string() } else { status }, status_tint),
        };
        let (ready, ready_tint) = self.readiness(theme);
        let counts: Vec<(usize, &str, Hsla)> = self
            .result
            .as_ref()
            .map(|r| {
                ["blocker", "major", "minor", "nit"]
                    .into_iter()
                    .map(|sev| {
                        let n = r.findings.iter().filter(|f| !self.dismissed.contains(&f.key()) && f.severity.as_deref().unwrap_or("minor") == sev).count();
                        (n, sev, severity_tint(Some(sev), theme))
                    })
                    .filter(|(n, _, _)| *n > 0)
                    .collect()
            })
            .unwrap_or_default();
        let has_result = self.result.is_some();
        let risk_level = self.risk().and_then(|r| r.level());
        Self::well(theme)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().text_base().font_weight(FontWeight::SEMIBOLD).text_color(lead_tint).child(lead))
                    .when(self.working(), |d| d.child(Self::spinner("standing-spinner", 13., theme))),
            )
            .map(|d| {
                if counts.is_empty() {
                    d.child(div().text_sm().text_color(if has_result { ready_tint } else { theme.secondary }).child(if has_result { ready } else { "Findings show here when it's done".into() }))
                } else {
                    d.child(div().flex().flex_row().flex_wrap().gap_x_3().gap_y_0p5().text_sm().children(counts.into_iter().map(|(n, sev, tint)| {
                        div().flex().flex_row().items_center().gap_1().child(div().size(px(7.)).rounded_full().bg(tint)).child(format!("{n} {sev}"))
                    })))
                }
            })
            .when_some(risk_level, |d, level| {
                d.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .text_sm()
                        .child(div().text_color(theme.secondary).child("Merge risk"))
                        .child(Self::risk_meter(level, 18., theme))
                        .child(div().font_weight(FontWeight::MEDIUM).text_color(risk_tint(level, theme)).child(level.title())),
                )
            })
            .when_some(self.result.as_ref().and_then(|r| r.effort), |d, e| {
                d.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .text_sm()
                        .text_color(theme.secondary)
                        .child("Effort")
                        .child(Self::effort_pips(e, theme))
                        .child(format!("{e}/5")),
                )
            })
            .when_some(self.record_note.clone(), |d, note| d.child(div().text_xs().text_color(theme.orange()).child(note)))
            .when_some(self.resolve_note.clone(), |d, note| d.child(div().text_xs().text_color(theme.secondary).child(note)))
            // What Check for Changes last found.
            .when_some(self.check_text(), |d, text| d.child(div().text_sm().text_color(if self.has_changes() { theme.selected } else { theme.secondary }).child(text)))
            // What was posted and when, a link to it.
            .when_some(self.posted_latest().cloned(), |d, posted| {
                let url = posted.url.clone();
                let tint = match posted_label(&posted.event) {
                    "Approved" => theme.good(),
                    "Changes requested" => theme.orange(),
                    _ => theme.selected,
                };
                d.child(
                    div()
                        .id("review-posted")
                        .text_sm()
                        .text_color(tint)
                        .cursor_pointer()
                        .hover(|s| s.opacity(0.8))
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .child(format!("{} {}", posted_label(&posted.event), ago(posted.at))),
                )
            })
    }

    /// The plans the PR delivers on, with how far each has got, in a well
    /// at the top of the sidebar: nothing when there are none.
    fn plans_well(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        if self.plans.is_empty() {
            return None;
        }
        let rows = crate::harness::plan_rows("review-plan", &self.plans, theme, cx);
        Some(
            Self::well(theme)
                .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child("PLANS AND REQUIREMENTS"))
                .children(rows)
                .into_any_element(),
        )
    }

    /// A group in the sidebar, as the work sidebar's: the page's background
    /// in a rounded, bordered box on the sidebar's tint.
    fn well(theme: &Theme) -> gpui::Div {
        div().flex().flex_col().gap_1().p_2p5().mb_2().rounded_lg().bg(theme.bg).border_1().border_color(theme.border)
    }

    fn effort_pips(effort: i64, theme: &Theme) -> impl IntoElement {
        div().flex().flex_row().gap(px(2.)).children((1..=5).map(|i| div().w(px(6.)).h(px(10.)).rounded(px(1.5)).bg(if i <= effort { theme.selected } else { theme.secondary.opacity(0.25) })))
    }

    fn effort_meter(effort: i64, theme: &Theme) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_1p5()
            .child(div().text_xs().text_color(theme.secondary).child("Effort"))
            .child(div().flex().flex_row().gap(px(2.)).children((1..=5).map(|i| {
                div().w(px(8.)).h(px(10.)).rounded(px(1.5)).bg(if i <= effort { theme.selected } else { theme.secondary.opacity(0.25) })
            })))
    }

    /// Where claude is, for the header.
    fn status(&self, theme: &Theme) -> (String, Hsla) {
        match self.claude_state().as_deref() {
            Some("exited") | Some("stopped") => ("Not running".into(), theme.secondary),
            Some("needs-you") => ("Needs you".into(), theme.orange()),
            Some("starting") if self.result.is_some() => ("Starting Claude Code".into(), theme.secondary),
            _ if self.working() => (if self.result.is_some() { "Reviewing again".into() } else { "Reading the PR".into() }, theme.secondary),
            _ if self.result.is_some() => ("Review ready".into(), theme.good()),
            _ => (String::new(), theme.secondary),
        }
    }

    /// One row: where claude is, the PR, the verdict, how ready it is and
    /// the effort, then the buttons; while posting, the buttons give way to
    /// the post's own controls.
    fn header(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (repo, number) = self.subject();
        let url = self.url();
        let link = url.clone();
        let (_, status_tint) = self.status(theme);
        let shown = self.shows_conversation();
        let title = self.title().unwrap_or_else(|| format!("{repo}#{number}"));
        let live = matches!(self.source, Source::Live { .. });
        let dot = if self.working() { theme.good() } else if status_tint == theme.orange() { theme.orange() } else if self.running() { theme.selected } else { theme.tertiary };
        let controls = match &self.post {
            Some(post) => self.post_controls(post, theme, cx).into_any_element(),
            None => div()
                .flex_none()
                .flex()
                .flex_row()
                .gap_2()
                .when(self.running(), |d| {
                    d.child(Self::button("review-conversation", "Terminal", false, true, theme).when(shown, |b| b.bg(theme.row_selected)).on_click(cx.listener(
                        move |this, _: &ClickEvent, _, cx| {
                            this.conversation = Some(!shown);
                            cx.notify();
                        },
                    )))
                })
                .child(Self::button("review-github", "Open on GitHub", false, true, theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))))
                .child(Self::button("review-explain", "Explain", false, live, theme).when(live, |d| d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.explain(cx)))))
                .child(Self::button("review-check", "Check for Changes", false, !self.checking, theme).when(!self.checking, |d| {
                    d.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.check_for_changes(cx)))
                }))
                // Merged with the PR page, these sit under the status in the
                // right-hand column instead.
                .when(self.pull.is_none(), |d| d.child(self.again_button(theme, cx)).child(self.post_button(theme, cx)))
                .into_any_element(),
        };
        div()
            .flex_none()
            .h(px(44.))
            .flex()
            .flex_row()
            .items_center()
            .gap_3()
            .px_4()
            .bg(theme.sidebar)
            .border_b_1()
            .border_color(theme.border)
            .child(div().flex_none().size(px(7.)).rounded_full().bg(dot))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .id("review-title")
                            .flex_shrink(1.)
                            .min_w(px(80.))
                            .truncate()
                            .font_weight(FontWeight::SEMIBOLD)
                            .cursor_pointer()
                            .hover(|s| s.text_color(theme.selected))
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&link)))
                            .child(title),
                    )
                    .child(div().flex_none().text_sm().text_color(theme.secondary).child(format!("{repo}#{number}")))
                    .when_some(self.pull.as_ref().map(|p| p.sidebar.read(cx).state_pill(theme)), |d, (state, tint)| {
                        d.child(div().flex_none().px_2().rounded_full().text_xs().bg(tint).text_color(theme.on_selected).font_weight(FontWeight::MEDIUM).child(state))
                    })
                    // Who opened it: their avatar and name, the login in its tooltip.
                    .when_some(self.author.clone(), |d, author| {
                        let shown = author.name.clone().unwrap_or_else(|| author.login.clone());
                        let tip = match &author.name {
                            Some(name) => format!("Opened by {name} ({})", author.login),
                            None => format!("Opened by {}", author.login),
                        };
                        d.child(
                            div()
                                .id("review-author")
                                .flex_shrink(1.)
                                .min_w_0()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_1p5()
                                .text_sm()
                                .text_color(theme.secondary)
                                .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
                                .child(crate::avatars::avatar(&author.login, author.avatar.as_deref(), 18., theme, cx))
                                .child(div().min_w_0().truncate().child(shown)),
                        )
                    }),
            )
            .child(controls)
    }

    /// Review Again, or a busy one while Claude Code is still starting (its
    /// terminal won't take the prompt yet).
    fn again_button(&self, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let live = matches!(self.source, Source::Live { .. });
        if live && ((self.running() && !self.takes_input()) || self.again_pending()) {
            return Self::busy_button("review-again", "Review Again", theme).into_any_element();
        }
        let can_again = self.can_again();
        Self::button("review-again", "Review Again", false, can_again, theme)
            .when(can_again, |d| d.on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.review_again(window, cx))))
            .into_any_element()
    }

    /// Post Review, enabled for a result not posted yet.
    fn post_button(&self, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let can_post = self.result.is_some() && self.posted_latest().is_none();
        Self::button("review-post", "Post Review", true, can_post, theme)
            .when(can_post, |d| d.on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.open_post(window, cx))))
            .into_any_element()
    }

    /// Merged with the PR page: where the review stands, one fact a row
    /// (your review, blockers, checks, merge risk, effort), with Review
    /// Again and Post Review under it. Heads the right-hand column.
    fn status_column(&self, parts: &PullParts, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let failing = parts.sidebar.read(cx).counts().2;
        let blockers = self.result.as_ref().map(|r| r.findings.iter().filter(|f| f.rank() == 0 && !self.dismissed.contains(&f.key())).count());
        // The marks are neutral: the values carry the colour.
        let icon = |path: &'static str| gpui::svg().path(path).size(px(14.)).flex_none().text_color(theme.secondary).into_any_element();
        // A row: a fixed slot for its mark, a label, the value, and a meter
        // at the right-hand end.
        let row = |mark: Option<gpui::AnyElement>, label: &str, value: gpui::AnyElement, meter: Option<gpui::AnyElement>| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .text_sm()
                .child(div().w(px(20.)).flex_none().flex().justify_center().children(mark))
                .child(div().w(px(84.)).flex_none().text_color(theme.secondary).child(label.to_string()))
                .child(div().flex_1().min_w_0().child(value))
                .children(meter)
                .into_any_element()
        };
        // Merge risk's bars, wider: one segment a step, lit ones in `lit`'s colour.
        let meter = |steps: i64, lit: &dyn Fn(i64) -> Option<Hsla>| {
            div()
                .flex_none()
                .flex()
                .flex_row()
                .gap(px(3.))
                .children((1..=steps).map(|i| div().w(px(14.)).h(px(5.)).rounded(px(1.5)).bg(lit(i).unwrap_or(theme.secondary.opacity(0.25)))))
                .into_any_element()
        };
        let text = |s: String, tint: Hsla| div().truncate().text_color(tint).child(s).into_any_element();
        let (review, review_tint) = match (self.verdict_word(theme), self.working()) {
            (Some((word, tint)), _) => (word.to_string(), tint),
            (None, true) => ("Reviewing".into(), theme.secondary),
            (None, false) => ("Not reviewed yet".into(), theme.secondary),
        };
        let review_mark = if self.working() { Self::spinner("status-spinner", 14., theme).into_any_element() } else { icon("icons/user_check.svg") };
        let mut rows: Vec<gpui::AnyElement> = vec![row(Some(review_mark), "Your review", text(review, review_tint), None)];
        if let Some(n) = blockers {
            rows.push(row(Some(icon("icons/x_circle_filled.svg")), "Blockers", if n > 0 { text(n.to_string(), theme.critical()) } else { text("None".into(), theme.secondary) }, None));
        }
        let (checks, checks_tint) = if failing > 0 { (format!("{failing} failing"), theme.critical()) } else { ("Passing".into(), theme.secondary) };
        rows.push(row(Some(icon(if failing > 0 { "icons/warning.svg" } else { "icons/check.svg" })), "Checks", text(checks, checks_tint), None));
        if let Some(level) = self.risk().and_then(|r| r.level()) {
            use crate::risk::Level;
            let at = match level {
                Level::Low => 1,
                Level::Medium => 2,
                Level::High => 3,
            };
            let tint = risk_tint(level, theme);
            rows.push(row(None, "Merge risk", text(level.title().to_string(), tint), Some(meter(3, &|i| (i == at).then_some(tint)))));
        }
        if let Some(e) = self.result.as_ref().and_then(|r| r.effort) {
            rows.push(row(None, "Effort", text(format!("{e}/5"), theme.secondary), Some(meter(5, &|i| (i <= e).then_some(theme.fg.opacity(0.7))))));
        }
        div()
            .flex()
            .flex_col()
            .gap_2()
            .children(rows)
            // What was posted, and what Check for Changes last found.
            .when_some(self.posted_latest().cloned(), |d, posted| {
                let url = posted.url.clone();
                d.child(
                    div()
                        .id("status-posted")
                        .pl(px(36.))
                        .text_xs()
                        .text_color(theme.selected)
                        .cursor_pointer()
                        .hover(|s| s.opacity(0.8))
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .child(format!("{} {}", posted_label(&posted.event), ago(posted.at))),
                )
            })
            .when_some(self.check_text(), |d, t| d.child(div().pl(px(36.)).text_xs().text_color(if self.has_changes() { theme.selected } else { theme.secondary }).child(t)))
            .child(div().pt_2().flex().flex_row().gap_2().child(self.again_button(theme, cx)).child(self.post_button(theme, cx)))
            .pb_5()
            .border_b_1()
            .border_color(theme.border)
            .into_any_element()
    }

    /// A row in the file list.
    fn list_row(&self, id: SharedString, selected: Selected, label: String, detail: Option<String>, badge: Option<(usize, Hsla)>, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let on = self.selected == selected;
        div()
            .id(id)
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_2()
            .py_1()
            .rounded_md()
            .cursor_pointer()
            .when(on, |d| d.bg(theme.row_selected))
            .when(!on, |d| d.hover(|s| s.bg(theme.row_selected.opacity(0.5))))
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.selected = selected.clone();
                cx.notify();
            }))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(div().truncate().child(label))
                    .when_some(detail.filter(|d| !d.is_empty()), |d, folder| d.child(div().truncate().text_xs().text_color(theme.secondary).child(folder))),
            )
            .when_some(badge, |d, (count, tint)| {
                d.child(div().flex_none().px_1p5().rounded_full().text_xs().font_weight(FontWeight::SEMIBOLD).bg(tint.opacity(0.25)).child(count.to_string()))
            })
    }

    fn area_number(n: usize, theme: &Theme) -> impl IntoElement {
        div()
            .flex_none()
            .size(px(20.))
            .rounded_full()
            .flex()
            .items_center()
            .justify_center()
            .bg(theme.selected.opacity(0.18))
            .text_xs()
            .font_weight(FontWeight::BOLD)
            .text_color(theme.selected)
            .child(n.to_string())
    }

    /// The findings still kept on a file, and the worst one's colour.
    fn badge(&self, path: &str, theme: &Theme) -> Option<(usize, Hsla)> {
        let result = self.result.as_ref()?;
        let kept: Vec<&Finding> = result.findings.iter().filter(|f| f.path == path && !self.dismissed.contains(&f.key())).collect();
        let worst = kept.iter().min_by_key(|f| f.rank())?;
        Some((kept.len(), self.badge_tint(worst.severity.as_deref(), theme)))
    }

    /// A count's colour by its worst finding; merged with the PR page,
    /// only a blocker's is coloured.
    fn badge_tint(&self, severity: Option<&str>, theme: &Theme) -> Hsla {
        if self.pull.is_some() && severity != Some("blocker") {
            theme.secondary
        } else {
            severity_tint(severity, theme)
        }
    }

    fn file_list(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let mut rows: Vec<gpui::AnyElement> = Vec::new();
        // Where the review stands, above everything, as icons with the
        // words in their tooltips: claude's state, the verdict, the findings
        // still kept by severity (how ready it is to merge), and the effort.
        if let Some(plans) = self.plans_well(theme, cx) {
            rows.push(plans);
        }
        // Merged, the Overview's status line says all this.
        if self.pull.is_none() {
            rows.push(self.standing(theme, cx).into_any_element());
        }
        rows.push(self.list_row("row-overview".into(), Selected::Overview, "Overview".into(), None, None, theme, cx).into_any_element());
        // The PR page's own parts, under the Overview.
        let pull_files = self.pull.as_ref().map(|p| {
            let (commits, checks, failing) = p.sidebar.read(cx).counts();
            let paths = p.sidebar.read(cx).file_paths();
            (commits, checks, failing, paths)
        });
        if let Some((commits, checks, failing, _)) = &pull_files {
            let checks_badge = if *failing > 0 { (*failing, theme.critical()) } else { (*checks, theme.secondary) };
            rows.push(self.list_row("row-timeline".into(), Selected::Timeline, "Timeline".into(), None, None, theme, cx).into_any_element());
            rows.push(self.list_row("row-commits".into(), Selected::Commits, "Commits".into(), None, Some((*commits, theme.secondary)), theme, cx).into_any_element());
            rows.push(
                self.list_row("row-checks".into(), Selected::Checks, "Checks".into(), None, Some(checks_badge), theme, cx)
                    .into_any_element(),
            );
        }
        let general = self.general();
        if !general.is_empty() {
            let kept = general.iter().filter(|f| !self.dismissed.contains(&f.key())).count();
            let worst = general.iter().min_by_key(|f| f.rank()).map(|f| self.badge_tint(f.severity.as_deref(), theme)).unwrap_or(theme.secondary);
            rows.push(
                self.list_row("row-general".into(), Selected::General, format!("{} not on a changed file", general.len()), None, (kept > 0).then_some((kept, worst)), theme, cx)
                    .into_any_element(),
            );
        }
        if let Some(result) = &self.result {
            let learnings = result.applied.len() + result.learnings.len();
            if learnings > 0 {
                rows.push(self.list_row("row-learnings".into(), Selected::Learnings, plural(learnings, "learning", "learnings"), None, None, theme, cx).into_any_element());
            }
            for (i, area) in result.walkthrough.iter().enumerate() {
                rows.push(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .mt_3()
                        .mb_1()
                        .px_2()
                        .child(Self::area_number(i + 1, theme))
                        .child(div().flex_1().truncate().text_sm().font_weight(FontWeight::SEMIBOLD).child(area.title.clone()))
                        .into_any_element(),
                );
                for path in &area.files {
                    let (name, folder) = file_name(path);
                    rows.push(
                        self.list_row(
                            SharedString::from(format!("row-file-{path}")),
                            Selected::File(path.clone()),
                            name.to_string(),
                            Some(folder.to_string()),
                            self.badge(path, theme),
                            theme,
                            cx,
                        )
                        .into_any_element(),
                    );
                }
            }
        }
        // Not reviewed yet: the PR's files, flat, as the walkthrough has
        // none to group them by.
        if let (None, Some((_, _, _, paths))) = (&self.result, pull_files) {
            rows.push(div().mt_3().mb_1().px_2().text_sm().font_weight(FontWeight::SEMIBOLD).child(format!("Files {}", paths.len())).into_any_element());
            for path in paths {
                let (name, folder) = file_name(&path);
                let (name, folder) = (name.to_string(), folder.to_string());
                rows.push(self.list_row(SharedString::from(format!("row-file-{path}")), Selected::File(path.clone()), name, Some(folder), None, theme, cx).into_any_element());
            }
        }
        div()
            .id("review-files")
            .w(px(280.))
            .flex_none()
            .h_full()
            .overflow_y_scroll()
            .p_2()
            .border_r_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .children(rows)
    }

    fn finding_card(&self, finding: &Finding, show_location: bool, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let key = finding.key();
        let dismissed = self.dismissed.contains(&key);
        let tint = severity_tint(finding.severity.as_deref(), theme);
        let editing = self.editing.as_ref().filter(|(k, _)| *k == key).map(|(_, e)| e.clone());
        let text = self.edits.get(&key).cloned().unwrap_or_else(|| finding.comment.clone());
        let edited = self.edits.contains_key(&key);
        let id = SharedString::from(key.clone());
        let action = |suffix: &str, label: &'static str| {
            div()
                .id(SharedString::from(format!("{id}-{suffix}")))
                .px_1p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(theme.secondary)
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
        };
        let (toggle_key, edit_finding, original) = (key.clone(), finding.clone(), finding.comment.clone());
        div()
            .flex()
            .flex_row()
            .rounded_lg()
            .overflow_hidden()
            .border_1()
            .border_color(if dismissed { theme.border } else { tint.opacity(0.7) })
            .bg(if dismissed { theme.tile.opacity(0.5) } else { theme.tile })
            .when(!dismissed, |d| d.child(div().w(px(4.)).flex_none().bg(tint)))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .p(px(10.))
                    .flex()
                    .flex_col()
                    .gap_1p5()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(div().px_1p5().rounded_full().text_xs().bg(tint.opacity(0.25)).child(capitalised(finding.severity.as_deref().unwrap_or("note"))))
                            .when_some(finding.category.clone(), |d, c| d.child(div().px_1p5().rounded_sm().text_xs().bg(theme.grid).child(capitalised(&c))))
                            .when(edited, |d| d.child(div().text_xs().text_color(theme.secondary).child("Edited")))
                            .child(div().flex_1().min_w_0().truncate().text_xs().text_color(theme.selected).when(show_location, |d| {
                                d.child(match finding.line {
                                    Some(line) => format!("{}:{line}", finding.path),
                                    None => finding.path.clone(),
                                })
                            }))
                            .when(!dismissed && editing.is_none(), |d| {
                                d.child(action("edit", "Edit").on_click(cx.listener(move |this, _: &ClickEvent, window, cx| this.start_edit(&edit_finding, window, cx))))
                            })
                            .when(editing.is_none(), |d| {
                                d.child(action("toggle", if dismissed { "Restore" } else { "Dismiss" }).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    if !this.dismissed.remove(&toggle_key) {
                                        this.dismissed.insert(toggle_key.clone());
                                    }
                                    this.save_decisions();
                                    cx.notify();
                                })))
                            }),
                    )
                    .map(|d| match editing {
                        Some(editor) => d
                            .child(div().p_2().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(editor))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .justify_end()
                                    .gap_2()
                                    .child(Self::button("edit-cancel", "Cancel", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                        this.editing = None;
                                        cx.notify();
                                    })))
                                    .child(Self::button("edit-save", "Save", true, true, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.save_edit(&original, cx)))),
                            ),
                        None if dismissed => d.child(div().text_sm().text_color(theme.secondary).line_through().child(text)),
                        None => d
                            .child(markdown(&format!("finding-{id}"), &text, theme))
                            .when_some(finding.suggestion.clone(), |d, s| {
                                d.child(div().p_2().rounded_md().bg(theme.good().opacity(0.12)).font_family(crate::zed::MONO).text_xs().child(s))
                            }),
                    }),
            )
    }

    fn spinner(id: &'static str, size: f32, theme: &Theme) -> impl IntoElement {
        use gpui::{Animation, AnimationExt, Transformation};
        gpui::svg()
            .path("icons/arrow_circle.svg")
            .size(px(size))
            .flex_none()
            .text_color(theme.secondary)
            .with_animation(id, Animation::new(Duration::from_millis(1200)).repeat(), |svg, delta| svg.with_transformation(Transformation::rotate(gpui::percentage(delta))))
    }

    /// Before there's a result: a spinner and what claude is doing, or that
    /// it's waiting on the person, with the terminal a click away.
    fn waiting(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (status, status_tint) = self.status(theme);
        let needs_you = self.claude_state().as_deref() == Some("needs-you");
        let shown = self.shows_conversation();
        div()
            .size_full()
            .min_h(px(320.))
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap_3()
            .when(self.working(), |d| d.child(Self::spinner("review-waiting", 28., theme)))
            .child(div().text_lg().font_weight(FontWeight::MEDIUM).text_color(if needs_you { status_tint } else { theme.fg }).child(if status.is_empty() { "Reviewing".to_string() } else { status }))
            .child(div().max_w(px(520.)).text_center().text_sm().text_color(theme.secondary).child(match (&self.activity, needs_you) {
                (_, true) => "Claude is asking something in its terminal.".to_string(),
                (Some(activity), _) => activity.clone(),
                (None, _) => "The summary, walkthrough and findings show here once it's done.".to_string(),
            }))
            .when(needs_you || !shown, |d| {
                d.child(Self::button("waiting-terminal", if needs_you { "Answer in Terminal" } else { "Show Terminal" }, needs_you, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    this.conversation = Some(true);
                    cx.notify();
                })))
            })
    }

    /// While claude reviews again with the last result still showing: a
    /// spinner and what it's doing, as the first review's waiting page, so
    /// it's clear without the terminal open. Needs-you says so instead.
    fn again_strip(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<impl IntoElement> {
        if self.result.is_none() {
            return None;
        }
        let needs_you = self.claude_state().as_deref() == Some("needs-you");
        let pending = self.again_pending();
        // A resumed session starting up isn't reviewing again: the header says it's starting.
        if !pending && ((!self.working() && !needs_you) || self.claude_state().as_deref() == Some("starting")) {
            return None;
        }
        let shown = self.shows_conversation();
        // Just pressed: what it's looking at, from the last check, until
        // claude's own activity takes over.
        let changes = match &self.checked {
            Some((_, Ok(changes))) => format!("Since the last review: {}. ", changes.summary().to_lowercase()),
            _ => String::new(),
        };
        let text = match (&self.activity, needs_you) {
            (_, true) => "Claude is asking something in its terminal.".to_string(),
            _ if pending => format!("{changes}Sent to Claude; it's starting on it."),
            (Some(activity), _) => activity.clone(),
            (None, _) => "The new result replaces this one once it's done.".to_string(),
        };
        Some(
            div()
                .flex_none()
                .flex()
                .flex_row()
                .items_center()
                .gap_3()
                .px_4()
                .py_2()
                .bg(theme.sidebar)
                .border_b_1()
                .border_color(theme.border)
                .when(!needs_you, |d| d.child(Self::spinner("review-again-spinner", 16., theme)))
                .child(div().flex_none().text_sm().font_weight(FontWeight::MEDIUM).text_color(if needs_you { theme.orange() } else { theme.fg }).child(if needs_you { "Needs you" } else { "Reviewing again" }))
                .child(div().flex_1().min_w_0().truncate().text_sm().text_color(theme.secondary).child(text))
                .when(needs_you || !shown, |d| {
                    d.child(Self::button("again-terminal", if needs_you { "Answer in Terminal" } else { "Show Terminal" }, needs_you, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.conversation = Some(true);
                        cx.notify();
                    })))
                }),
        )
    }

    /// Low, medium and high as three bars, the grade's lit.
    fn risk_meter(level: crate::risk::Level, segment: f32, theme: &Theme) -> impl IntoElement {
        use crate::risk::Level;
        div().flex().flex_row().gap(px(2.)).children([Level::Low, Level::Medium, Level::High].into_iter().map(move |l| {
            div().w(px(segment)).h(px(4.)).rounded(px(1.)).bg(if l == level { risk_tint(level, theme) } else { theme.secondary.opacity(0.25) })
        }))
    }

    /// The verdict as a word and its colour, once there's a result.
    fn verdict_word(&self, theme: &Theme) -> Option<(&'static str, Hsla)> {
        Some(match self.result.as_ref()?.verdict.as_deref() {
            Some("approve") => ("Approve", theme.good()),
            Some("request_changes") => ("Request changes", theme.critical()),
            _ => ("Comment", theme.secondary),
        })
    }

    /// A heading that opens and closes what's under it.
    fn disclosure(id: &'static str, title: String, open: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .flex()
            .flex_row()
            .items_center()
            .gap_1p5()
            .text_sm()
            .text_color(theme.secondary)
            .cursor_pointer()
            .hover(|s| s.text_color(theme.fg))
            .child(div().flex_none().w(px(10.)).child(if open { "▾" } else { "▸" }))
            .child(title)
    }

    /// A small caps caption over a group in the risk panel.
    fn caption(text: &str, theme: &Theme) -> impl IntoElement {
        div().text_xs().text_color(theme.tertiary).child(text.to_uppercase())
    }

    /// One acceptance criterion: its status, what it asks, the evidence
    /// and the issue it's from.
    fn criterion_row(c: &crate::risk::Criterion, theme: &Theme) -> gpui::AnyElement {
        let (label, tint) = match c.status.as_str() {
            "met" => ("Met", theme.good()),
            "partial" => ("Partly", theme.orange()),
            "missing" => ("Missing", theme.critical()),
            // Another PR's, or checked by people after merge.
            "later" => ("Later", theme.tertiary),
            _ => ("Can't tell", theme.secondary),
        };
        div()
            .flex()
            .flex_col()
            .gap_0p5()
            .text_sm()
            .child(div().flex().flex_row().gap_2().child(div().flex_none().font_weight(FontWeight::MEDIUM).text_color(tint).child(label)).child(div().flex_1().min_w_0().child(c.criterion.clone())))
            .when_some(c.evidence.clone(), |d, e| d.child(div().text_color(theme.secondary).child(e)))
            .when_some(c.issue.clone(), |d, i| d.child(div().text_xs().text_color(theme.tertiary).child(i)))
            .into_any_element()
    }

    /// The merge risk, actionable first: the grade and the one thing to
    /// look at, then what to do before merging (criteria not met, what
    /// would raise confidence, sensitive paths touched). How the grade was
    /// reached and the criteria needing nothing are a click away.
    /// `quiet` (the merged Overview, which states the grade in its status
    /// line) leaves out the big grade and its meter, keeping the next step.
    fn risk_panel(&self, risk: &crate::risk::Risk, quiet: bool, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        use crate::risk::{Group, Level};
        let level = risk.level();
        let tint = level.map(|l| risk_tint(l, theme)).unwrap_or(theme.secondary);
        let grade = div()
            .flex()
            .flex_col()
            .gap_1()
            .child(Self::caption("Merge risk", theme))
            .child(div().text_3xl().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(level.map(Level::title).unwrap_or("ungraded")))
            .when_some(level, |d, level| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(Self::risk_meter(level, 60., theme))
                        .child(div().flex().flex_row().gap(px(2.)).text_xs().children([Level::Low, Level::Medium, Level::High].into_iter().map(move |l| {
                            div().w(px(60.)).text_color(if l == level { tint } else { theme.tertiary }).child(l.title())
                        }))),
                )
            })
            .child(div().pt_1().font_weight(FontWeight::MEDIUM).child(risk.next_step()));

        let unmet: Vec<gpui::AnyElement> = risk.criteria.iter().filter(|c| c.status == "missing" || c.status == "partial").map(|c| Self::criterion_row(c, theme)).collect();
        let rest: Vec<&crate::risk::Criterion> = risk.criteria.iter().filter(|c| c.status != "missing" && c.status != "partial").collect();
        let gaps: Vec<gpui::AnyElement> = risk
            .gaps
            .iter()
            .enumerate()
            .map(|(i, g)| {
                div()
                    .flex()
                    .flex_row()
                    .gap_2()
                    .text_sm()
                    .child(div().flex_none().pt(px(5.)).child(div().size(px(6.)).rounded_full().border_1().border_color(theme.selected)))
                    .child(div().flex_1().min_w_0().child(markdown(&format!("risk-gap-{i}"), g, theme)))
                    .into_any_element()
            })
            .collect();
        let sensitive: Vec<gpui::AnyElement> = risk
            .sensitive
            .iter()
            .map(|(path, why)| {
                div()
                    .flex()
                    .flex_col()
                    .text_sm()
                    .child(div().font_family(crate::zed::MONO).text_xs().text_color(theme.orange()).child(path.clone()))
                    .when_some(why.clone(), |d, why| d.child(div().text_color(theme.secondary).child(why)))
                    .into_any_element()
            })
            .collect();
        let group = |caption: &str, items: Vec<gpui::AnyElement>| div().flex().flex_col().gap_2().child(Self::caption(caption, theme)).children(items);
        let actionable = !(unmet.is_empty() && gaps.is_empty() && sensitive.is_empty());

        // How it was graded: exposure (what it touches) above confidence
        // (whether we can tell it works), each signal with its mark.
        let signal_row = |signal: &crate::risk::Signal| {
            let (mark, mark_tint) = match signal.score() {
                Some(1) => ("✓", theme.good()),
                Some(2) => ("~", theme.orange()),
                Some(_) => ("!", theme.critical()),
                None => ("·", theme.tertiary),
            };
            div()
                .flex()
                .flex_row()
                .gap_2()
                .text_sm()
                .child(div().flex_none().w(px(12.)).font_weight(FontWeight::SEMIBOLD).text_color(mark_tint).child(mark))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(div().flex().flex_row().gap_2().child(div().flex_1().font_weight(FontWeight::MEDIUM).child(signal.title)).child(div().flex_none().text_color(theme.secondary).child(signal.verdict.clone().unwrap_or_else(|| "unknown".into()))))
                        .when_some(signal.reason.clone(), |d, r| d.child(div().text_color(theme.secondary).child(r)))
                        .when_some(signal.raised.clone(), |d, r| d.child(div().text_color(theme.orange()).child(format!("Raised: {r}")))),
                )
                .into_any_element()
        };
        let grading: Vec<gpui::AnyElement> = [Group::Exposure, Group::Confidence]
            .into_iter()
            .map(|g| {
                let word = risk.group_score(g).map(|s| g.word(s)).unwrap_or("unknown");
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(div().flex().flex_row().gap_2().text_xs().child(div().text_color(theme.tertiary).child(g.title().to_uppercase())).child(div().text_color(theme.secondary).child(word)))
                    .children(risk.signals.iter().filter(|s| s.group() == g).map(signal_row))
                    .into_any_element()
            })
            .collect();
        let (show_grading, show_criteria) = (self.show_grading, self.show_criteria);

        div()
            .flex()
            .flex_col()
            .gap_5()
            .map(|d| if quiet { d } else { d.child(grade) })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .map(|d| {
                        if quiet {
                            d.child(Self::section_heading("Before merging")).child(div().text_color(theme.secondary).child(risk.next_step()))
                        } else {
                            d.child(div().text_sm().font_weight(FontWeight::SEMIBOLD).child("Before merging"))
                        }
                    })
                    .when(!actionable, |d| d.child(div().text_sm().text_color(theme.secondary).child("Nothing beyond the findings.")))
                    .when(!unmet.is_empty(), |d| d.child(group("Acceptance criteria not met", unmet)))
                    .when(!gaps.is_empty(), |d| d.child(group("Would raise confidence", gaps)))
                    .when(!sensitive.is_empty(), |d| d.child(group("Sensitive paths it touches", sensitive))),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(Self::disclosure("risk-grading", "How it's graded".into(), show_grading, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                        this.show_grading = !this.show_grading;
                        cx.notify();
                    })))
                    .when(show_grading, |d| d.children(grading))
                    .when(!rest.is_empty(), |d| {
                        d.child(Self::disclosure("risk-criteria", format!("Other acceptance criteria ({})", rest.len()), show_criteria, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            this.show_criteria = !this.show_criteria;
                            cx.notify();
                        })))
                        .when(show_criteria, |d| d.children(rest.iter().map(|c| Self::criterion_row(c, theme))))
                    }),
            )
            .into_any_element()
    }

    fn section_heading(text: &str) -> impl IntoElement {
        div().text_base().font_weight(FontWeight::SEMIBOLD).child(text.to_string())
    }

    /// The review, most decisive first: the verdict and how ready it is,
    /// why (headline and summary), what happens at run time, what needs
    /// attention, then the walkthrough. `wide` puts the merge risk in the
    /// sidebar beside it; otherwise it follows the summary.
    fn overview(&self, wide: bool, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (ready, ready_tint) = self.readiness(theme);
        let Some(result) = self.result.clone() else {
            return self.waiting(theme, cx).into_any_element();
        };
        let risk = self.risk();
        let risk_level = risk.as_ref().and_then(|r| r.level());
        let inline_risk = (!wide).then(|| risk.as_ref().map(|r| div().p_4().rounded_lg().border_1().border_color(theme.border).bg(theme.sidebar).child(self.risk_panel(r, false, theme, cx)))).flatten();
        let (verdict, verdict_tint) = self.verdict_word(theme).unwrap_or(("Comment", theme.secondary));
        // Needs attention: the findings still kept, by how much they hold
        // up the merge.
        let mut kept: Vec<Finding> = result.findings.iter().filter(|f| !self.dismissed.contains(&f.key())).cloned().collect();
        kept.sort_by_key(|f| f.rank());
        let tiers: Vec<(&str, Hsla, Vec<Finding>)> = vec![
            ("Blocking the merge", theme.critical(), kept.iter().filter(|f| f.rank() == 0).cloned().collect()),
            ("Fix before merging", theme.orange(), kept.iter().filter(|f| f.rank() == 1).cloned().collect()),
            ("Not blocking", theme.secondary, kept.iter().filter(|f| f.rank() >= 2).cloned().collect()),
        ];
        let attention = tiers.into_iter().filter(|t| !t.2.is_empty()).map(|(label, tint, findings)| {
            div()
                .flex()
                .flex_col()
                .gap_1()
                .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(label))
                .child(div().flex().flex_col().rounded_lg().bg(theme.tile).children(findings.into_iter().enumerate().map(|(i, f)| {
                    let target = if result.area_of(&f.path).is_some() { Selected::File(f.path.clone()) } else { Selected::General };
                    let first = f.comment.split(". ").next().unwrap_or(&f.comment).to_string();
                    div()
                        .id(SharedString::from(format!("attention-{}", f.key())))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .px(px(10.))
                        .py(px(7.))
                        .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.row_selected.opacity(0.5)))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.selected = target.clone();
                            cx.notify();
                        }))
                        .child(div().flex_none().size(px(6.)).rounded_full().bg(severity_tint(f.severity.as_deref(), theme)))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(div().truncate().child(first))
                                .child(div().truncate().text_xs().text_color(theme.secondary).child(match f.line {
                                    Some(line) => format!("{}:{line}", f.path),
                                    None => f.path.clone(),
                                })),
                        )
                        .when_some(f.category.clone(), |d, c| d.child(div().flex_none().px_1p5().rounded_sm().text_xs().bg(theme.grid).child(capitalised(&c))))
                        .child(div().flex_none().text_color(theme.tertiary).child("›"))
                })))
        });
        let has_attention = !kept.is_empty();
        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .max_w(px(860.))
            // The verdict, then how ready it is, the merge risk and effort.
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1p5()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_baseline()
                            .gap_2()
                            .text_2xl()
                            .child(div().text_color(theme.secondary).child("Verdict:"))
                            .child(div().font_weight(FontWeight::SEMIBOLD).text_color(verdict_tint).child(verdict)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .items_center()
                            .gap_x_4()
                            .gap_y_1()
                            .child(div().font_weight(FontWeight::MEDIUM).text_color(ready_tint).child(ready))
                            .when_some(risk_level, |d, level| {
                                d.child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap_1p5()
                                        .text_sm()
                                        .child(div().text_color(theme.secondary).child("Merge risk"))
                                        .child(Self::risk_meter(level, 14., theme))
                                        .child(div().font_weight(FontWeight::MEDIUM).text_color(risk_tint(level, theme)).child(level.title())),
                                )
                            })
                            .when_some(result.effort, |d, e| d.child(Self::effort_meter(e, theme))),
                    ),
            )
            // Why: the headline and the summary.
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .when_some(result.headline.clone(), |d, h| d.child(div().text_lg().font_weight(FontWeight::SEMIBOLD).child(h)))
                    .child(markdown("review-summary", &result.summary, theme)),
            )
            .children(inline_risk)
            .children(Self::flow_section(&result, theme))
            .when(has_attention, |d| d.child(div().flex().flex_col().gap_3().child(Self::section_heading("Needs attention")).children(attention)))
            .children(self.walkthrough_section(&result, theme, cx))
            .into_any_element()
    }

    /// The summary without its lists by severity: those are the findings,
    /// which Needs attention lists already. A lead-in left hanging ("A few
    /// things to look at:") goes with them.
    fn prose_only(summary: &str) -> String {
        let mut kept = Vec::new();
        for line in summary.lines() {
            let t = line.trim();
            if t.starts_with("**") && ["blocker", "major", "minor", "nit"].contains(&t.trim_matches('*').trim_end_matches(':').to_lowercase().as_str()) {
                break;
            }
            kept.push(line);
        }
        let mut text = kept.join("\n").trim_end().to_string();
        if text.ends_with(':') {
            if let Some(i) = text.rfind(['.', '\n']) {
                text.truncate(i + 1);
            }
        }
        text.trim_end().to_string()
    }

    /// The Overview with the PR page merged in. One status line; one Needs
    /// attention, grouped by who has to act, blockers first; then the
    /// review's prose, what to do before merging, the walkthrough and the
    /// description. Colour is kept for what blocks the merge.
    fn merged_overview(&self, parts: &PullParts, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        enum Action {
            Select(Selected),
            Url(String),
            Nothing,
        }
        struct Row {
            blocking: bool,
            text: String,
            detail: Option<String>,
            aside: Option<String>,
            action: Action,
        }
        let (facts, open) = {
            let pull = parts.sidebar.read(cx);
            (pull.standing_facts(theme), pull.open_items())
        };
        let (whose, _threads, _failing, _approvals) = facts.unwrap_or_default();
        let result = self.result.clone();
        let mut kept: Vec<Finding> = result.iter().flat_map(|r| r.findings.iter()).filter(|f| !self.dismissed.contains(&f.key())).cloned().collect();
        kept.sort_by_key(|f| f.rank());

        // Whose move it is; the review's own standing is in the right-hand
        // column (`status_column`).
        let status = div().text_xl().font_weight(FontWeight::SEMIBOLD).child(if whose.is_empty() { "Loading the pull request".to_string() } else { whose });

        // Needs attention: the review's findings are the reviewer's until
        // posted; GitHub's items go to whoever's move it is.
        let mut groups: Vec<(String, Vec<Row>)> = Vec::new();
        if !kept.is_empty() {
            let title = if self.posted_latest().is_some() { "In your posted review" } else { "In your review, to post" };
            let rows = kept
                .iter()
                .map(|f| Row {
                    blocking: f.rank() == 0,
                    text: f.comment.split(". ").next().unwrap_or(&f.comment).to_string(),
                    detail: Some(match f.line {
                        Some(line) => format!("{}:{line}", f.path),
                        None => f.path.clone(),
                    }),
                    aside: f.severity.as_deref().map(capitalised),
                    action: Action::Select(if result.as_ref().is_some_and(|r| r.area_of(&f.path).is_some()) { Selected::File(f.path.clone()) } else { Selected::General }),
                })
                .collect();
            groups.push((title.into(), rows));
        }
        for item in open {
            let title = format!("On {}", item.owner);
            let row = Row {
                blocking: item.kind == crate::pull_page::AttentionKind::Failing,
                text: item.text,
                detail: item.detail,
                aside: item.since.map(ago),
                action: item.url.map_or(Action::Nothing, Action::Url),
            };
            match groups.iter_mut().find(|(t, _)| *t == title) {
                Some((_, rows)) => rows.push(row),
                None => groups.push((title, vec![row])),
            }
        }
        // Blockers first, wherever they are; the order otherwise kept.
        groups.sort_by_key(|(_, rows)| !rows.iter().any(|r| r.blocking));
        for (_, rows) in groups.iter_mut() {
            rows.sort_by_key(|r| !r.blocking);
        }
        let attention: Vec<gpui::AnyElement> = groups
            .into_iter()
            .enumerate()
            .map(|(g, (title, rows))| {
                let count = rows.len();
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(div().flex().flex_row().gap_1p5().text_sm().child(div().font_weight(FontWeight::MEDIUM).text_color(theme.secondary).child(title)).child(div().text_color(theme.tertiary).child(count.to_string())))
                    .child(div().flex().flex_col().rounded_lg().border_1().border_color(theme.border).children(rows.into_iter().enumerate().map(|(i, row)| {
                        div()
                            .id(SharedString::from(format!("merged-attention-{g}-{i}")))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px(px(10.))
                            .py(px(7.))
                            .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                            .map(|d| match row.action {
                                Action::Select(target) => d.cursor_pointer().hover(|s| s.bg(theme.row_selected.opacity(0.5))).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    this.selected = target.clone();
                                    cx.notify();
                                })),
                                Action::Url(url) => d.cursor_pointer().hover(|s| s.bg(theme.row_selected.opacity(0.5))).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))),
                                Action::Nothing => d,
                            })
                            // A slot for the mark, so the text lines up
                            // whether or not the row blocks.
                            .child(div().flex_none().size(px(6.)).rounded_full().when(row.blocking, |d| d.bg(theme.critical())))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .child(div().truncate().text_sm().child(row.text))
                                    .when_some(row.detail, |d, detail| d.child(div().truncate().text_xs().text_color(theme.secondary).child(detail))),
                            )
                            .when_some(row.aside, |d, aside| d.child(div().flex_none().text_xs().text_color(theme.tertiary).child(aside)))
                    })))
                    .into_any_element()
            })
            .collect();

        let prose = match &result {
            Some(r) => div()
                .flex()
                .flex_col()
                .gap_2()
                .when_some(r.headline.clone(), |d, h| d.child(div().text_base().font_weight(FontWeight::SEMIBOLD).child(h)))
                .child(markdown("review-summary", &Self::prose_only(&r.summary), theme))
                .into_any_element(),
            None => self.waiting(theme, cx).into_any_element(),
        };
        let before = result.as_ref().and_then(|_| self.risk()).map(|risk| self.risk_panel(&risk, true, theme, cx));
        let (flow, walkthrough) = match &result {
            Some(r) => (Self::flow_section(r, theme), self.walkthrough_section(r, theme, cx)),
            None => (None, None),
        };
        div()
            .flex()
            .flex_col()
            .gap(px(28.))
            .child(status)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(Self::section_heading("Needs attention"))
                    .when(attention.is_empty(), |d| d.child(div().text_sm().text_color(theme.secondary).child("Nothing open.")))
                    .children(attention),
            )
            .child(prose)
            .children(before)
            .children(flow)
            .children(walkthrough)
            .child(div().flex().flex_col().gap_2().child(Self::section_heading("Description")).child(parts.description.clone()))
            .into_any_element()
    }

    /// What happens at run time, so a reviewer knows the shape of the
    /// change before reading it.
    fn flow_section(result: &ReviewResult, theme: &Theme) -> Option<gpui::AnyElement> {
        if result.flow.is_empty() {
            return None;
        }
        Some(
            div().child(
                div().flex().flex_col().gap_1p5().child(Self::section_heading("What happens")).children(result.flow.iter().enumerate().map(|(i, step)| {
                    div()
                        .flex()
                        .flex_row()
                        .gap_1()
                        .child(div().w(px(22.)).flex_none().text_color(theme.secondary).child(format!("{}.", i + 1)))
                        .child(div().flex_1().child(step.clone()))
                })),
            )
            .into_any_element(),
        )
    }

    /// The walkthrough as prose: its files are the list on the left, in
    /// the same order, so they aren't repeated here.
    fn walkthrough_section(&self, result: &ReviewResult, theme: &Theme, cx: &mut Context<Self>) -> Option<gpui::AnyElement> {
        if result.walkthrough.is_empty() {
            return None;
        }
        let quiet = |text: String| div().text_sm().text_color(theme.secondary).child(text);
        Some(
            div().child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .child(div().flex().flex_col().child(Self::section_heading("Walkthrough")).child(quiet("The change in the order to read it, as the file list on the left.".into())))
                    .children(result.walkthrough.iter().enumerate().map(|(i, area)| {
                        let first = area.files.first().cloned();
                        let count = area.files.len();
                        div()
                            .flex()
                            .flex_row()
                            .gap_3()
                            .child(Self::area_number(i + 1, theme))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(
                                        div()
                                            .flex()
                                            .flex_row()
                                            .items_baseline()
                                            .gap_2()
                                            .child(div().font_weight(FontWeight::SEMIBOLD).child(area.title.clone()))
                                            .when_some(first, |d, path| {
                                                d.child(
                                                    div()
                                                        .id(SharedString::from(format!("area-files-{i}")))
                                                        .flex_none()
                                                        .text_xs()
                                                        .text_color(theme.tertiary)
                                                        .cursor_pointer()
                                                        .hover(|s| s.text_color(theme.selected))
                                                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                                            this.selected = Selected::File(path.clone());
                                                            cx.notify();
                                                        }))
                                                        .child(format!("{} ›", plural(count, "file", "files"))),
                                                )
                                            }),
                                    )
                                    .when_some(area.summary.clone(), |d, s| d.child(div().text_color(theme.secondary).child(s))),
                            )
                    })),
            )
            .into_any_element(),
        )
    }

    fn file_detail(&self, path: &str, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(result) = self.result.clone() else {
            // A file listed from the PR before there's a review.
            return div()
                .flex()
                .flex_col()
                .gap_2()
                .child(div().font_family(crate::zed::MONO).text_sm().child(path.to_string()))
                .child(div().text_sm().text_color(theme.secondary).child("Not reviewed yet: its diff shows here, and a review adds its findings above it."))
                .into_any_element();
        };
        let area = result.area_of(path).map(|i| (i, result.walkthrough[i].clone()));
        let mut findings: Vec<Finding> = result.findings.iter().filter(|f| f.path == path).cloned().collect();
        findings.sort_by_key(|f| (f.line.unwrap_or(0), f.rank()));
        let applied: Vec<review::Applied> = result.applied.iter().filter(|a| a.path.as_deref() == Some(path)).cloned().collect();
        div()
            .flex()
            .flex_col()
            .gap_3()
            .max_w(px(860.))
            .child(div().font_family(crate::zed::MONO).text_sm().child(path.to_string()))
            .when_some(area, |d, (i, area)| {
                d.child(
                    div()
                        .flex()
                        .flex_row()
                        .gap_2()
                        .child(Self::area_number(i + 1, theme))
                        .child(div().flex_1().flex().flex_col().child(div().font_weight(FontWeight::MEDIUM).child(area.title)).when_some(area.summary, |d, s| d.child(div().text_sm().text_color(theme.secondary).child(s)))),
                )
            })
            .children(applied.iter().map(|a| Self::applied_card(a, theme)))
            .when(findings.is_empty(), |d| d.child(div().text_sm().text_color(theme.secondary).child("No findings on this file.")))
            .children(findings.iter().map(|f| self.finding_card(f, true, theme, cx)))
            .into_any_element()
    }

    fn applied_card(applied: &review::Applied, theme: &Theme) -> impl IntoElement {
        let yellow: Hsla = gpui::rgb(0xEDA100).into();
        div()
            .flex()
            .flex_col()
            .gap_1()
            .p(px(10.))
            .rounded_lg()
            .bg(yellow.opacity(0.1))
            .child(div().font_weight(FontWeight::MEDIUM).child(format!("Applied: {}", applied.learning)))
            .when_some(applied.path.clone(), |d, path| {
                d.child(div().font_family(crate::zed::MONO).text_xs().text_color(theme.secondary).child(match applied.line {
                    Some(line) => format!("{path}:{line}"),
                    None => path,
                }))
            })
            .child(div().text_sm().child(applied.note.clone()))
            .when_some(applied.concern.clone(), |d, c| d.child(div().text_sm().text_color(theme.orange()).child(format!("Concern: {c}"))))
    }

    fn learnings_detail(&self, theme: &Theme) -> impl IntoElement {
        let Some(result) = &self.result else { return div().into_any_element() };
        let yellow: Hsla = gpui::rgb(0xEDA100).into();
        let caption = |text: &str| div().text_sm().text_color(theme.secondary).child(text.to_string());
        div()
            .flex()
            .flex_col()
            .gap(px(14.))
            .max_w(px(860.))
            .when(!result.applied.is_empty(), |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(Self::section_heading("Applied by the reviewer"))
                        .child(caption("The team's learnings that shaped this review, and how."))
                        .children(result.applied.iter().map(|a| Self::applied_card(a, theme))),
                )
            })
            .when(!result.learnings.is_empty(), |d| {
                d.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(Self::section_heading("Suggested by the reviewer"))
                        .child(caption("Why code is the way it is, as people said in this PR, for later reviews to know."))
                        .children(result.learnings.iter().map(|l| {
                            let lines = match (l.line, l.end_line) {
                                (Some(a), Some(b)) => format!("{}:{a}-{b}", l.path),
                                (Some(a), None) => format!("{}:{a}", l.path),
                                _ => l.path.clone(),
                            };
                            div()
                                .flex()
                                .flex_col()
                                .gap_1()
                                .p(px(10.))
                                .rounded_lg()
                                .bg(yellow.opacity(0.08))
                                .child(div().font_weight(FontWeight::MEDIUM).child(l.rule.clone()))
                                .when_some(l.reason.clone(), |d, r| d.child(div().text_sm().child(r)))
                                .child(div().font_family(crate::zed::MONO).text_xs().text_color(theme.secondary).child(lines))
                                .when_some(l.author.clone(), |d, a| d.child(div().text_xs().text_color(theme.secondary).child(format!("From @{a}"))))
                        })),
                )
            })
            .into_any_element()
    }

    fn general_detail(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let mut general = self.general();
        general.sort_by_key(|f| f.rank());
        div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .max_w(px(860.))
            .child(div().text_sm().text_color(theme.secondary).child("These go in the review's body, as GitHub only takes comments on lines the diff shows."))
            .children(general.iter().map(|f| self.finding_card(f, true, theme, cx)))
    }

    /// The conversation with claude: its terminal and a box to tell it
    /// something. A preview has no claude, so says so.
    fn conversation_pane(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let ready = self.takes_input();
        self.shortcuts.update(cx, |bar, cx| bar.set_enabled(ready, cx));
        let live = match &self.source {
            Source::Live { view, .. } => Some(view.clone()),
            Source::Preview { .. } => None,
        };
        div()
            .relative()
            .flex_none()
            .h(px(self.conversation_height))
            .flex()
            .flex_col()
            .border_t_1()
            .border_color(theme.border)
            // The top edge drags to resize it.
            .child(
                div()
                    .id("conversation-resize")
                    .absolute()
                    .top(px(-3.))
                    .left_0()
                    .right_0()
                    .h(px(6.))
                    .cursor_row_resize()
                    .on_mouse_down(
                        gpui::MouseButton::Left,
                        cx.listener(|this, event: &gpui::MouseDownEvent, _, cx| {
                            this.resizing = Some((f32::from(event.position.y), this.conversation_height));
                            cx.stop_propagation();
                        }),
                    ),
            )
            .map(|d| match live {
                Some(view) => d.child(div().flex_1().min_h_0().child(view)),
                None => d.child(
                    div()
                        .flex_1()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_sm()
                        .text_color(theme.secondary)
                        .child("Claude's terminal shows here in a real review."),
                ),
            })
            .child(
                div()
                    .flex_none()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(theme.border)
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .px_2()
                            .py_1()
                            .rounded_md()
                            .border_1()
                            .border_color(theme.border)
                            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                                if event.keystroke.key == "enter" {
                                    cx.stop_propagation();
                                    this.send_composer(window, cx);
                                }
                            }))
                            .map(|d| {
                                if self.takes_input() {
                                    d.child(self.composer.clone())
                                } else {
                                    d.flex().flex_row().items_center().gap_2().text_sm().text_color(theme.secondary).child(Self::spinner("composer-starting", 12., theme)).child("Claude Code is starting")
                                }
                            }),
                    )
                    .child(self.shortcuts.clone()),
            )
    }

    /// A button that can't go yet, with a spinner, while Claude Code starts.
    fn busy_button(id: &'static str, label: &str, theme: &Theme) -> impl IntoElement {
        div()
            .id(id)
            .px_2()
            .py_0p5()
            .rounded_md()
            .border_1()
            .border_color(theme.border)
            .flex()
            .flex_row()
            .items_center()
            .gap_1p5()
            .text_color(theme.secondary)
            .child(Self::spinner("starting-spinner", 12., theme))
            .child(label.to_string())
    }

    fn button(id: &'static str, label: &str, prominent: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .px_2()
            .py_0p5()
            .rounded_md()
            .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
            .when(enabled, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)))
            .when(!enabled, |d| d.opacity(0.4))
            .child(label.to_string())
    }

    /// Posting, in the header: the kind of review and what goes, or where
    /// the post is. Nothing goes to GitHub until Post to GitHub is clicked.
    fn post_controls(&self, post: &Post, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let close = |id: &'static str, label: &'static str, cx: &mut Context<Self>| {
            Self::button(id, label, false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.post = None;
                cx.notify();
            }))
        };
        let quiet = |text: String| div().flex_shrink(1.).min_w_0().truncate().text_sm().text_color(theme.secondary).child(text);
        let row = div().flex_none().max_w(px(640.)).flex().flex_row().items_center().gap_2();
        match post {
            Post::Loading => row.child(quiet("Loading the pull request".into())).child(close("post-cancel", "Cancel", cx)),
            Post::Posting => row.child(quiet("Posting to GitHub".into())),
            Post::Posted(url) => {
                let url = url.clone();
                row.child(div().text_sm().text_color(theme.good()).child("Posted to GitHub"))
                    .child(Self::button("posted-open", "Open It", false, true, theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))))
                    .child(close("post-done", "Done", cx))
            }
            Post::Failed(error) => row
                .child(div().flex_shrink(1.).min_w_0().truncate().text_sm().text_color(theme.critical()).child(error.clone()))
                .child(close("post-close", "Close", cx)),
            Post::Ready { snapshot, draft, event, .. } => {
                let own = snapshot.is_own();
                let event_now = *event;
                let choice = |id: &'static str, label: &'static str, value: &'static str, cx: &mut Context<Self>| {
                    let on = event_now == value;
                    div()
                        .id(id)
                        .px_2()
                        .py_0p5()
                        .rounded_md()
                        .cursor_pointer()
                        .text_color(if on { theme.fg } else { theme.secondary })
                        .when(on, |d| d.bg(theme.bg))
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            if let Some(Post::Ready { event, .. }) = this.post.as_mut() {
                                *event = value;
                            }
                            cx.notify();
                        }))
                        .child(label)
                };
                let mut events = div().flex_none().p_0p5().flex().flex_row().gap_0p5().rounded_md().bg(theme.grid).text_sm().child(choice("event-comment", "Comment", "COMMENT", cx));
                if !own {
                    events = events.child(choice("event-approve", "Approve", "APPROVE", cx)).child(choice("event-changes", "Request Changes", "REQUEST_CHANGES", cx));
                }
                let inline = draft.comments.len();
                let recording = self.record_with_post;
                row.child(events)
                    .child(quiet(if own { "Your own PR: only a comment".into() } else { plural(inline, "inline comment", "inline comments") }))
                    .child(
                        div()
                            .id("post-record")
                            .flex_none()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_1p5()
                            .text_sm()
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.record_with_post = !recording;
                                crate::review_record::set_recording(!recording);
                                cx.notify();
                            }))
                            .child(
                                div()
                                    .size(px(14.))
                                    .rounded(px(3.))
                                    .border_1()
                                    .border_color(if recording { theme.selected } else { theme.secondary })
                                    .when(recording, |d| d.bg(theme.selected))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .text_xs()
                                    .text_color(theme.on_selected)
                                    .child(if recording { "✓" } else { "" }),
                            )
                            .child("Record in harness"),
                    )
                    .child(close("post-cancel", "Cancel", cx))
                    .child(Self::button("post-confirm", "Post to GitHub", true, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.confirm_post(cx))))
            }
        }
    }

    /// The draft being posted, in the detail column: the body to edit, the
    /// inline comments and the findings left out.
    fn post_draft(&self, post: &Post, theme: &Theme, cx: &gpui::App) -> Option<impl IntoElement> {
        let Post::Ready { snapshot, draft, body, .. } = post else { return None };
        let text = body.read(cx).text(cx);
        let quiet = |text: String| div().text_sm().text_color(theme.secondary).child(text);
        let general = draft.body.lines().filter(|l| l.starts_with("- `")).count();
        Some(
            div()
                .flex()
                .flex_col()
                .gap(px(18.))
                .max_w(px(860.))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(Self::section_heading("Review to post"))
                        .child(quiet(if snapshot.is_own() {
                            "It's your own pull request, so GitHub only takes a comment.".into()
                        } else {
                            "Pick the kind of review in the header, check the text, then Post to GitHub.".into()
                        })),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child("Body"))
                        .child(div().p_2().rounded_md().border_1().border_color(theme.border).bg(theme.bg).child(body.clone()))
                        // What GitHub will show for the body above, as it's edited.
                        .child(div().pt_2().font_weight(FontWeight::SEMIBOLD).child("On GitHub"))
                        .child(
                            div()
                                .p_3()
                                .rounded_md()
                                .border_1()
                                .border_color(theme.border)
                                .bg(theme.tile)
                                .text_sm()
                                .child(if text.trim().is_empty() { div().text_color(theme.secondary).child("(no body)").into_any_element() } else { crate::markdown::markdown("post-preview", &text, theme) }),
                        )
                        .when(general > 0, |d| {
                            d.child(quiet(format!(
                                "{} {} on a line the diff shows, so {} in the body.",
                                plural(general, "finding", "findings"),
                                if general == 1 { "isn't" } else { "aren't" },
                                if general == 1 { "it's" } else { "they're" }
                            )))
                        }),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(div().font_weight(FontWeight::SEMIBOLD).child(capitalised(&plural(draft.comments.len(), "inline comment", "inline comments"))))
                        .children(draft.comments.iter().map(|(path, line, body)| {
                            div()
                                .flex()
                                .flex_col()
                                .gap_0p5()
                                .p_2()
                                .rounded_md()
                                .bg(theme.tile)
                                .child(div().font_family(crate::zed::MONO).text_xs().text_color(theme.selected).child(format!("{path}:{line}")))
                                .child(div().text_sm().child(crate::markdown::markdown(&format!("post-inline-{path}-{line}"), body, theme)))
                        })),
                )
                .when(!draft.left_out.is_empty(), |d| {
                    d.child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(div().font_weight(FontWeight::SEMIBOLD).child(capitalised(&format!("{} left out", plural(draft.left_out.len(), "finding", "findings")))))
                            .children(draft.left_out.iter().map(|f| div().text_sm().text_color(theme.secondary).child(format!("{}:{}: {}", f.path, f.line.unwrap_or(0), f.comment))))
                            .child(quiet("A comment near its line, or an earlier review, already says much the same, so it isn't posted again.".into())),
                    )
                }),
        )
    }
}


impl Render for ReviewPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let draft = self.post.as_ref().and_then(|post| self.post_draft(post, &theme, cx)).map(|d| d.into_any_element());
        // A file's diff, read from GitHub the first time it's picked.
        let diff = match (&self.selected, &self.source, draft.is_some()) {
            (Selected::File(path), Source::Live { .. }, false) => {
                if !self.diffs.contains_key(path) {
                    let (repo, number) = self.subject();
                    let (file, key) = (path.clone(), path.clone());
                    let view = cx.new(|cx| crate::pr_diff::PrDiff::new(repo, number, file, window, cx));
                    self.diffs.insert(key, view);
                }
                self.diffs.get(path).cloned()
            }
            _ => None,
        };
        // Room for the Overview beside a risk sidebar, from the width the
        // detail area had when last laid out.
        let wide = self.detail_width.get() >= 980.;
        let risk_side = (self.pull.is_none() && wide && draft.is_none() && self.selected == Selected::Overview).then(|| self.risk()).flatten().map(|risk| self.risk_panel(&risk, false, &theme, cx));
        // The PR page's sidebar (reviewers, labels, linked issues) beside
        // everything but a file, whose diff wants the width.
        let pull_side = self.pull.as_ref().filter(|_| draft.is_none() && !matches!(self.selected, Selected::File(_))).map(|p| p.sidebar.clone());
        // Merged: the review's standing and its buttons head that column,
        // on every page.
        let status_side = self.pull.as_ref().filter(|_| draft.is_none()).map(|p| self.status_column(p, &theme, cx));
        let pull_part = |pick: fn(&PullParts) -> &Entity<crate::pull_page::PullPage>| self.pull.as_ref().map(|p| pick(p).clone().into_any_element()).unwrap_or_else(|| div().into_any_element());
        let detail = match self.selected.clone() {
            _ if draft.is_some() => draft.unwrap(),
            // Merged: where the PR stands and what's open on GitHub, then
            // the review, then the description.
            Selected::Overview if self.pull.is_some() => {
                let parts = self.pull.as_ref().unwrap();
                div().max_w(px(860.)).child(self.merged_overview(parts, &theme, cx)).into_any_element()
            }
            Selected::Overview => self.overview(wide, &theme, cx).into_any_element(),
            Selected::Timeline => div().max_w(px(860.)).child(pull_part(|p| &p.timeline)).into_any_element(),
            Selected::Commits => div().max_w(px(860.)).child(pull_part(|p| &p.commits)).into_any_element(),
            Selected::Checks => div().max_w(px(860.)).child(pull_part(|p| &p.checks)).into_any_element(),
            Selected::General => self.general_detail(&theme, cx).into_any_element(),
            Selected::Learnings => self.learnings_detail(&theme).into_any_element(),
            Selected::File(path) => self.file_detail(&path, &theme, cx).into_any_element(),
        };
        div()
            .relative()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .track_focus(&self.focus)
            .on_mouse_move(cx.listener(|this, event: &gpui::MouseMoveEvent, window, cx| {
                let Some((start, height)) = this.resizing else { return };
                if event.pressed_button != Some(gpui::MouseButton::Left) {
                    this.resizing = None;
                    return;
                }
                let most = (f32::from(window.viewport_size().height) - 220.).max(140.);
                this.conversation_height = (height + start - f32::from(event.position.y)).clamp(120., most);
                cx.notify();
            }))
            .on_mouse_up(
                gpui::MouseButton::Left,
                cx.listener(|this, _: &gpui::MouseUpEvent, _, _| this.resizing = None),
            )
            .child(self.header(&theme, cx))
            .when_some(self.again_strip(&theme, cx), |d, strip| d.child(strip))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_row()
                    .child(self.file_list(&theme, cx))
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .min_w_0()
                            .h_full()
                            .flex()
                            .flex_row()
                            .child({
                                // Measures the detail area, so the Overview
                                // knows whether its risk sidebar fits.
                                let width = self.detail_width.clone();
                                gpui::canvas(
                                    move |bounds, window, _| {
                                        let now = f32::from(bounds.size.width);
                                        if (now - width.get()).abs() > 1. {
                                            width.set(now);
                                            window.refresh();
                                        }
                                    },
                                    |_, _, _, _| {},
                                )
                                .absolute()
                                .top_0()
                                .left_0()
                                .w_full()
                                .h(px(0.))
                            })
                            .map(|d| match diff {
                                // A file: its findings above, its diff filling the rest.
                                Some(diff) => d.child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .h_full()
                                        .flex()
                                        .flex_col()
                                        .child(div().id("review-detail").flex_none().max_h(gpui::relative(0.45)).overflow_y_scroll().p_5().child(detail))
                                        .child(div().flex_1().min_h_0().border_t_1().border_color(theme.border).child(diff)),
                                ),
                                None => d.child(div().id("review-detail").flex_1().min_w_0().h_full().overflow_y_scroll().p_5().child(detail)),
                            })
                            .when(risk_side.is_some() || pull_side.is_some() || status_side.is_some(), |d| {
                                d.child(
                                    div()
                                        .id("review-risk")
                                        .flex_none()
                                        .w(px(340.))
                                        .h_full()
                                        .overflow_y_scroll()
                                        .p_5()
                                        .border_l_1()
                                        .border_color(theme.border)
                                        .bg(theme.sidebar)
                                        .child(div().flex().flex_col().gap_6().children(status_side).children(risk_side).children(pull_side)),
                                )
                            }),
                    ),
            )
            .when(self.shows_conversation(), |d| d.child(self.conversation_pane(&theme, cx)))
    }
}
