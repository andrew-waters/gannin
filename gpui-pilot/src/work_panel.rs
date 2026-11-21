//! A Work on This session, laid out as Gannin's session tab: the terminal
//! (always showing) with a message bar under it, and a side panel on the
//! right switching between the issue, the changes, the pull requests and
//! the activity. Claude's permission prompts and questions float over the
//! bottom of the terminal as a card; Resume floats over it once claude has
//! exited.
//!
//! It draws from `WorkData`, which a live session fills from its worktrees,
//! its PRs and claude's transcript, and the Work Preview fills with made-up
//! data in each state. Nothing here writes anywhere yet: the preview's
//! buttons only change what shows.

use crate::charts::Theme;
use crate::markdown::markdown;
use gpui::{div, prelude::*, px, AnyView, ClickEvent, Context, Entity, FontWeight, Hsla, KeyDownEvent, SharedString, Window};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum WorkState {
    Starting,
    Working,
    NeedsYou,
    YourTurn,
    Exited,
}

impl WorkState {
    pub fn label(self) -> &'static str {
        match self {
            WorkState::Starting => "Starting",
            WorkState::Working => "Working",
            WorkState::NeedsYou => "Needs you",
            WorkState::YourTurn => "Your turn",
            WorkState::Exited => "Claude exited",
        }
    }

    fn running(self) -> bool {
        !matches!(self, WorkState::Exited)
    }

    pub fn tint(self, theme: &Theme) -> Hsla {
        match self {
            WorkState::Starting | WorkState::Working => theme.blue(),
            WorkState::NeedsYou => gpui::rgb(0xFF9F0A).into(),
            WorkState::YourTurn => theme.good(),
            WorkState::Exited => theme.secondary.opacity(0.5),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ChangedFile {
    /// A, M or D.
    pub status: char,
    pub path: String,
    pub additions: i64,
    pub deletions: i64,
    pub staged: bool,
    /// Its diff, as unified diff lines.
    pub diff: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct Worktree {
    pub name: String,
    /// Where it is, to read a file's diff.
    pub path: String,
    /// Commits not pushed; None when it's never been pushed.
    pub unpushed: Option<usize>,
    pub base: String,
    /// Everything since it left the default branch.
    pub files: Vec<ChangedFile>,
    /// What isn't committed yet.
    pub uncommitted: Vec<ChangedFile>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PrState {
    Open,
    Draft,
    Merged,
    Closed,
}

#[derive(Clone, Debug)]
pub struct Feedback {
    pub author: String,
    pub location: Option<String>,
    pub verdict: Option<String>,
    pub body: String,
    pub sent: bool,
}

#[derive(Clone, Debug)]
pub struct WorkPr {
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub state: PrState,
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED.
    pub review: Option<String>,
    pub conflicts: bool,
    pub failed: Vec<String>,
    pub pending: Vec<String>,
    pub passed: usize,
    pub failures_sent: bool,
    pub feedback: Vec<Feedback>,
}

/// What claude is asking, over the terminal.
#[derive(Clone, Debug)]
pub enum Ask {
    /// A permission prompt: the tool, what it'd do, and the terminal's
    /// middle choices.
    Permission { tool: String, text: String, choices: Vec<String> },
    /// Questions, each with its options (label, description, recommended).
    Questions(Vec<Question>),
}

#[derive(Clone, Debug)]
pub struct Question {
    pub header: String,
    pub question: String,
    pub multi: bool,
    pub options: Vec<(String, String, bool)>,
}

#[derive(Clone, Debug)]
pub struct WorkData {
    pub reference: String,
    pub title: String,
    pub issue_url: String,
    pub issue_body: String,
    pub state: WorkState,
    pub branch: String,
    pub folder: String,
    pub worktrees: Vec<Worktree>,
    pub prs: Vec<WorkPr>,
    pub ask: Option<Ask>,
    pub activity: Vec<(String, String)>,
    pub model: String,
    /// What it's cost, when known.
    pub cost: Option<f64>,
    pub context: f32,
    pub last_check: Option<bool>,
    /// Days since anything happened, for Stale.
    pub idle_days: i64,
    /// The workflow the work runs through, and how far it's got.
    pub workflow: Option<WorkflowRun>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StageStatus {
    Waiting,
    Running,
    /// A local review gate holding the push.
    Holding,
    Done,
    Failed,
}

/// A local review finding, and what the session did with it.
#[derive(Clone, Debug)]
pub struct LocalFinding {
    pub severity: String,
    pub path: String,
    pub text: String,
    /// "Fixed in a1b2c3d", "Answered: ...", or none yet.
    pub outcome: Option<String>,
}

#[derive(Clone, Debug)]
pub struct StepRun {
    pub name: String,
    /// Claude Code, Junie, or Command.
    pub provider: String,
    pub status: StageStatus,
    pub summary: String,
    pub findings: Vec<LocalFinding>,
}

#[derive(Clone, Debug)]
pub struct StageRun {
    /// Prepare, Session, Local review, On the PR, Done.
    pub title: String,
    pub status: StageStatus,
    /// A few words for the strip: "Round 2 · 1 blocker".
    pub note: String,
    pub steps: Vec<StepRun>,
}

#[derive(Clone, Debug)]
pub struct WorkflowRun {
    pub name: String,
    pub stages: Vec<StageRun>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Pane {
    Issue,
    Changes,
    Activity,
    Workflow,
}

/// Asks the workspace to act on the session: start it again where it left
/// off, or take it out of the pilot (after Finish, or Forget).
pub enum WorkEvent {
    Resume,
    Forget,
    /// Move to Server: a stopped session on this Mac, to resume on the
    /// window's server.
    MoveToServer,
}

impl gpui::EventEmitter<WorkEvent> for WorkPanel {}
impl gpui::EventEmitter<crate::harness::OpenDoc> for WorkPanel {}

/// A live session's launch and terminal, for its data and to send to it.
struct Live {
    launch: crate::launch::Launch,
    terminal: Entity<terminal::Terminal>,
}

pub struct WorkPanel {
    data: WorkData,
    terminal: Option<AnyView>,
    live: Option<Live>,
    /// Diffs read for a live session, by worktree, path and mode.
    diffs: std::collections::HashMap<(String, String, bool), Vec<String>>,
    _poll: Option<gpui::Task<()>>,
    /// The workflow the live session runs through, and its local review:
    /// whether a round is going, the request last taken up, and a message
    /// waiting for claude's turn to end.
    flow: Option<crate::workflows::Workflow>,
    round_running: bool,
    handled_request: Option<std::time::SystemTime>,
    pending_message: Option<String>,
    pane: Pane,
    /// The workflow stage whose detail shows.
    stage: usize,
    panel_open: bool,
    /// Branch (everything since the default branch) or Uncommitted.
    uncommitted: bool,
    file: Option<String>,
    composer: Entity<editor::Editor>,
    /// The team's prompt shortcuts beside the composer.
    shortcuts: Entity<crate::shortcuts::ShortcutBar>,
    /// The question card, put away to answer in the terminal.
    ask_away: bool,
    /// Options picked per question.
    picked: Vec<Vec<usize>>,
    /// Feedback ticked to send, by PR and index.
    ticked: Vec<(i64, usize)>,
    auto_feedback: bool,
    /// The pull request list's filters: a state, a repo, and grouping by repo.
    pr_state: Option<PrState>,
    pr_repo: Option<String>,
    pr_by_repo: bool,
    /// The repo menu open; merged and closed PRs shown (folded under the
    /// open ones otherwise); comments opened to their full text.
    repo_menu: bool,
    ended_open: bool,
    expanded: std::collections::HashSet<(i64, usize)>,
    /// Feedback passed to claude already (failing checks and comments, by
    /// key), and what's waiting for its turn to end.
    feedback_sent: std::collections::HashSet<String>,
    feedback_queue: Vec<String>,
    /// No record of what was sent yet (a session from before this): the
    /// first look takes what's there as known, and sends nothing.
    feedback_seeding: bool,
    /// The harness documents about or mentioning the issue or its PRs, once
    /// looked for: Gannin's "Plans and requirements", with their progress.
    plans: Option<Vec<(crate::harness::Doc, bool)>>,
}

/// A comment's gist for its row: the first line of words, with HTML
/// comments and tags, Markdown markers and checkboxes taken out (bots'
/// review bodies are mostly markup). The whole of it still goes to claude.
impl gpui::EventEmitter<crate::pull_page::OpenPull> for WorkPanel {}

/// The ticked key for a PR's failing checks (comments are ticked by index).
const FAILURES: usize = usize::MAX;

fn summary_line(body: &str) -> String {
    let mut text = body.to_string();
    while let Some(start) = text.find("<!--") {
        match text[start..].find("-->") {
            Some(end) => text.replace_range(start..start + end + 3, ""),
            None => text.truncate(start),
        }
    }
    let mut plain = String::new();
    let mut in_tag = false;
    for c in text.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => plain.push(c),
            _ => {}
        }
    }
    plain
        .lines()
        .map(|l| l.trim().trim_start_matches(['#', '>', '-', '*']).trim().trim_start_matches("[ ]").trim_start_matches("[x]").trim().replace("**", "").replace('`', ""))
        .find(|l| !l.is_empty() && l.chars().any(|c| c.is_alphanumeric()))
        .unwrap_or_else(|| "A comment".into())
}

impl WorkPanel {
    pub fn new(data: WorkData, terminal: Option<AnyView>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let composer = cx.new(|cx| {
            let mut editor = editor::Editor::auto_height(1, 5, window, cx);
            editor.set_placeholder_text("Tell claude something", window, cx);
            editor
        });
        let shortcuts = cx.new(|_| crate::shortcuts::ShortcutBar::new());
        cx.subscribe(&shortcuts, |this, _, event: &crate::shortcuts::SendShortcut, cx| this.send(event.0.clone(), false, cx)).detach();
        let file = data.worktrees.iter().flat_map(|w| w.files.first()).next().map(|f| f.path.clone());
        let picked = match &data.ask {
            Some(Ask::Questions(qs)) => vec![Vec::new(); qs.len()],
            _ => Vec::new(),
        };
        Self {
            data,
            terminal,
            live: None,
            diffs: Default::default(),
            _poll: None,
            flow: None,
            round_running: false,
            handled_request: None,
            pending_message: None,
            pane: Pane::Issue,
            stage: 0,
            panel_open: true,
            uncommitted: false,
            file,
            composer,
            shortcuts,
            ask_away: false,
            picked,
            ticked: Vec::new(),
            auto_feedback: true,
            pr_state: None,
            pr_repo: None,
            pr_by_repo: false,
            repo_menu: false,
            ended_open: false,
            expanded: Default::default(),
            feedback_sent: Default::default(),
            feedback_queue: Vec::new(),
            feedback_seeding: false,
            plans: None,
        }
    }

    /// A live Work on This session: its terminal, and its data read every
    /// few seconds (its pull requests every minute) off the main thread.
    pub fn live(launch: crate::launch::Launch, terminal: Entity<terminal::Terminal>, view: AnyView, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let subject = launch.subject.clone();
        let data = WorkData {
            reference: subject.as_ref().map(|s| format!("{}#{}", s.repo, s.number)).unwrap_or_default(),
            title: subject.as_ref().map(|s| s.title.clone()).unwrap_or_else(|| launch.title.clone()),
            issue_url: subject.as_ref().map(|s| s.url.clone()).unwrap_or_default(),
            issue_body: subject.as_ref().and_then(|s| crate::detail::load_text(&launch.org, &s.id)).map(|t| t.body).unwrap_or_default(),
            state: WorkState::Starting,
            branch: launch.branch.clone(),
            folder: launch.folder().to_string_lossy().to_string(),
            worktrees: Vec::new(),
            prs: Vec::new(),
            ask: None,
            activity: Vec::new(),
            model: String::new(),
            cost: None,
            context: 0.,
            last_check: None,
            idle_days: 0,
            workflow: None,
        };
        let mut panel = Self::new(data, Some(view), window, cx);
        let (folder, claude_id, dir) = (launch.folder(), launch.claude_id(), launch.dir());
        panel.flow = crate::work_flow::read_workflow(&launch.dir());
        // New feedback goes to claude unless it's been turned off for this
        // session; an unattended one always has it.
        panel.auto_feedback = launch.unattended.is_some() || !launch.dir().join("auto-feedback-off").exists();
        let record = std::fs::read(launch.dir().join("feedback-sent.json")).ok().and_then(|b| serde_json::from_slice(&b).ok());
        // A session opened before feedback went by itself, with PRs already:
        // what's on them now isn't new.
        panel.feedback_seeding = record.is_none() && !launch.pull_requests().is_empty();
        panel.feedback_sent = record.unwrap_or_default();
        panel.shortcuts.update(cx, |bar, cx| bar.set_place(&launch.org, &launch.harness_repo, cx));
        panel.live = Some(Live { launch, terminal });
        panel._poll = Some(cx.spawn(async move |this, cx| {
            let mut tick = 0u32;
            loop {
                let (folder, id) = (folder.clone(), claude_id.clone());
                let local = cx.background_executor().spawn(async move { (crate::work_live::worktrees(&folder), crate::work_live::transcript(&id)) }).await;
                let urls = this.update(cx, |this, _| this.live.as_ref().map(|l| l.launch.pull_requests()).unwrap_or_default()).ok();
                let prs = match urls {
                    Some(urls) if !urls.is_empty() && tick % 20 == 0 => Some(
                        cx.background_executor()
                            .spawn(async move {
                                let token = crate::auth::token()?;
                                let viewer = crate::auth::saved_viewer().map(|v| v.login).unwrap_or_default();
                                Some(crate::work_live::pull_requests(&token, &urls, &viewer))
                            })
                            .await,
                    ),
                    _ => None,
                };
                // The plans linked to the issue and its PRs, every minute, as
                // claude may commit or tick one off while it works.
                let items = if tick % 20 == 0 { this.update(cx, |this, _| this.plan_items()).ok() } else { None };
                let plans = match items {
                    Some((org, items)) if !items.is_empty() => Some(cx.background_executor().spawn(async move { crate::harness::linked(&crate::harness::load(&org), &items) }).await),
                    _ => None,
                };
                let dir = dir.clone();
                let alive = this
                    .update(cx, |this, cx| {
                        let (worktrees, transcript) = local;
                        this.data.worktrees = worktrees;
                        this.data.activity = transcript.activity;
                        this.data.model = transcript.model;
                        this.data.context = transcript.context;
                        if let Some(Some(prs)) = prs {
                            // Keep what's been sent, by PR.
                            let sent: Vec<(i64, bool)> = this.data.prs.iter().map(|p| (p.number, p.failures_sent)).collect();
                            this.data.prs = prs;
                            for pr in &mut this.data.prs {
                                pr.failures_sent = sent.iter().any(|(n, s)| *n == pr.number && *s);
                            }
                            this.collect_feedback(&dir);
                        }
                        if let Some(plans) = plans {
                            this.plans = Some(plans);
                        }
                        this.refresh_state(&dir, cx);
                        this.step_workflow(&dir, cx);
                        this.deliver_feedback(cx);
                        cx.notify();
                    })
                    .is_ok();
                if !alive {
                    return;
                }
                tick += 1;
                cx.background_executor().timer(std::time::Duration::from_secs(3)).await;
            }
        }));
        panel
    }

    /// The workflow's local review: takes up a held push (a round on its
    /// worktree and commit), sends a round's findings once claude's turn has
    /// ended, and redraws the strip.
    fn step_workflow(&mut self, dir: &std::path::Path, cx: &mut Context<Self>) {
        let Some(flow) = self.flow.clone() else { return };
        if !self.round_running {
            if let Some((worktree, sha, at)) = crate::work_flow::pending_request(dir) {
                if self.handled_request != Some(at) {
                    self.handled_request = Some(at);
                    self.start_round(dir.to_path_buf(), worktree, sha, flow.clone(), cx);
                }
            }
        }
        if self.data.state != WorkState::Working {
            if let Some(message) = self.pending_message.take() {
                self.send(message, false, cx);
            }
        }
        self.data.workflow = Some(self.live_strip(&flow, dir));
    }

    fn start_round(&mut self, dir: std::path::PathBuf, worktree: std::path::PathBuf, sha: String, flow: crate::workflows::Workflow, cx: &mut Context<Self>) {
        use crate::work_flow::{read_run, write_run};
        let mut run = read_run(&dir).unwrap_or_default();
        // A new series after the last one cleared; else the next round.
        let earlier: Vec<crate::work_flow::Finding> = if run.local.status == "clear" { Vec::new() } else { run.local.steps.iter().flat_map(|s| s.findings.clone()).collect() };
        run.local.round = if run.local.status == "clear" || run.local.round == 0 { 1 } else { run.local.round + 1 };
        run.local.status = "running".into();
        run.local.sha = sha.clone();
        run.local.overridden = false;
        write_run(&dir, &run);
        self.round_running = true;
        let round = run.local.round;
        // A session on a server has its worktree there: the round runs there.
        let server = self.live.as_ref().and_then(|l| l.launch.server.clone());
        cx.spawn(async move |this, cx| {
            let (results, clear) = cx
                .background_executor()
                .spawn({
                    let (worktree, flow, server) = (worktree.clone(), flow.clone(), server.clone());
                    async move {
                        let harness = worktree.ancestors().find(|p| p.join(".gannin").is_dir() || p.join("specialists").is_dir()).map(|p| p.to_path_buf());
                        let specialists = harness.map(|h| crate::workflows::specialists(&h)).unwrap_or_default();
                        crate::work_flow::local_round(&worktree, &flow, &specialists, round, &earlier, server.as_ref())
                    }
                })
                .await;
            this.update(cx, |this, cx| {
                let mut run = read_run(&dir).unwrap_or_default();
                run.local.steps = results.clone();
                run.local.status = if clear { "clear".into() } else { "holding".into() };
                write_run(&dir, &run);
                if clear {
                    let server = this.live.as_ref().and_then(|l| l.launch.server.clone());
                    crate::work_flow::clear(&dir, &sha, server.as_ref());
                }
                this.pending_message = Some(crate::work_flow::round_message(round, &sha, &results, clear));
                this.round_running = false;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The strip for a live session, from its workflow and where it's got.
    fn live_strip(&self, flow: &crate::workflows::Workflow, dir: &std::path::Path) -> WorkflowRun {
        use crate::workflows::When;
        let run = crate::work_flow::read_run(dir).unwrap_or_default();
        let mut stages = Vec::new();
        let prepare = flow.steps_when(When::Prepare);
        if !prepare.is_empty() {
            let status = match run.prepare.as_str() {
                "done" => StageStatus::Done,
                "running" => StageStatus::Running,
                _ => StageStatus::Waiting,
            };
            stages.push(StageRun {
                title: "Prepare".into(),
                status,
                note: String::new(),
                steps: prepare.iter().map(|s| StepRun { name: s.label(&[]), provider: "Claude Code".into(), status, summary: if status == StageStatus::Done { "Its notes are in the session's brief.".into() } else { String::new() }, findings: vec![] }).collect(),
            });
        }
        let merged = !self.data.prs.is_empty() && self.data.prs.iter().all(|p| p.state == PrState::Merged);
        let session = if merged { StageStatus::Done } else if self.data.state == WorkState::Starting { StageStatus::Waiting } else { StageStatus::Running };
        stages.push(StageRun { title: "Session".into(), status: session, note: self.data.state.label().into(), steps: vec![StepRun { name: "Session".into(), provider: "Claude Code".into(), status: session, summary: "The terminal on the left.".into(), findings: vec![] }] });
        let local = flow.steps_when(When::Local);
        if !local.is_empty() {
            let status = match run.local.status.as_str() {
                "running" => StageStatus::Running,
                "holding" => StageStatus::Holding,
                "clear" => StageStatus::Done,
                _ => StageStatus::Waiting,
            };
            let blocking = run.local.steps.iter().flat_map(|s| s.findings.iter()).filter(|f| matches!(f.severity.as_str(), "blocker" | "major")).count();
            let failed = run.local.steps.iter().filter(|s| s.provider == "Command" && s.status == "failed").count();
            let note = match status {
                StageStatus::Running => format!("Round {}", run.local.round),
                StageStatus::Holding => {
                    let mut parts = vec![format!("Round {}", run.local.round)];
                    if blocking > 0 {
                        parts.push(format!("{blocking} to fix"));
                    }
                    if failed > 0 {
                        parts.push(format!("{failed} failing"));
                    }
                    parts.join(" · ")
                }
                StageStatus::Done if run.local.overridden => "Pushed anyway".into(),
                StageStatus::Done => "Clear".into(),
                _ => String::new(),
            };
            let steps = if run.local.steps.is_empty() {
                local.iter().map(|s| StepRun { name: s.label(&[]), provider: if s.command.is_some() { "Command".into() } else { "Claude Code".into() }, status: StageStatus::Waiting, summary: "Runs when the session first pushes.".into(), findings: vec![] }).collect()
            } else {
                run.local
                    .steps
                    .iter()
                    .map(|r| StepRun {
                        name: r.label.clone(),
                        provider: r.provider.clone(),
                        status: match r.status.as_str() {
                            "failed" => StageStatus::Failed,
                            "holding" => StageStatus::Holding,
                            _ => StageStatus::Done,
                        },
                        summary: r.summary.clone(),
                        findings: r.findings.iter().map(|f| LocalFinding { severity: f.severity.clone(), path: format!("{}{}", f.path, f.line.map(|l| format!(":{l}")).unwrap_or_default()), text: f.comment.clone(), outcome: None }).collect(),
                    })
                    .collect()
            };
            stages.push(StageRun { title: "Local review".into(), status, note, steps });
        }
        let failing = self.data.prs.iter().any(|p| p.state == PrState::Open && !p.failed.is_empty());
        let open_feedback = self.data.prs.iter().filter(|p| p.state == PrState::Open).map(|p| p.feedback.iter().filter(|f| !f.sent).count()).sum::<usize>();
        let pr = if self.data.prs.is_empty() {
            StageStatus::Waiting
        } else if merged {
            StageStatus::Done
        } else if failing {
            StageStatus::Failed
        } else {
            StageStatus::Running
        };
        stages.push(StageRun {
            title: "On the PR".into(),
            status: pr,
            note: if failing { "Checks failing".into() } else if open_feedback > 0 { format!("{open_feedback} comments") } else { String::new() },
            steps: self
                .data
                .prs
                .iter()
                .map(|p| StepRun {
                    name: format!("{}#{}", p.repo.rsplit('/').next().unwrap_or(&p.repo), p.number),
                    provider: "Pull request".into(),
                    status: if p.state == PrState::Merged { StageStatus::Done } else if !p.failed.is_empty() { StageStatus::Failed } else { StageStatus::Running },
                    summary: format!("{} passed, {} failed, {} running; {} comments.", p.passed, p.failed.len(), p.pending.len(), p.feedback.len()),
                    findings: vec![],
                })
                .collect(),
        });
        let done = merged || (!self.data.prs.is_empty() && !failing && open_feedback == 0 && self.data.prs.iter().all(|p| p.pending.is_empty()));
        stages.push(StageRun { title: "Done".into(), status: if done { StageStatus::Done } else { StageStatus::Waiting }, note: String::new(), steps: vec![] });
        WorkflowRun { name: flow.name.clone(), stages }
    }

    /// Push Anyway: lets the held commit through, and tells claude.
    fn push_anyway(&mut self, cx: &mut Context<Self>) {
        let Some(live) = &self.live else { return };
        let dir = live.launch.dir();
        let Some(mut run) = crate::work_flow::read_run(&dir) else { return };
        crate::work_flow::clear(&dir, &run.local.sha, live.launch.server.as_ref());
        run.local.status = "clear".into();
        run.local.overridden = true;
        crate::work_flow::write_run(&dir, &run);
        let short: String = run.local.sha.chars().take(7).collect();
        self.send(format!("Gannin's local review was overridden for {short}: push it now. Its findings still stand, so deal with them in a later commit."), false, cx);
        cx.notify();
    }

    /// New feedback on the session's open PRs since it was last passed on:
    /// checks that fail (one that passes again can fail anew) and others'
    /// comments and review threads. Queued for claude's turn to end.
    fn collect_feedback(&mut self, dir: &std::path::Path) {
        if !self.auto_feedback {
            return;
        }
        let mut lines: Vec<String> = Vec::new();
        let mut failing_now = std::collections::HashSet::new();
        for pr in self.data.prs.iter().filter(|p| p.state == PrState::Open) {
            let at = format!("{}#{}", pr.repo, pr.number);
            let mut failures = Vec::new();
            for check in &pr.failed {
                let key = format!("check:{at}:{check}");
                failing_now.insert(key.clone());
                if self.feedback_sent.insert(key) {
                    failures.push(check.clone());
                }
            }
            let mut comments = Vec::new();
            for f in &pr.feedback {
                let digest = f.body.chars().filter(|c| c.is_alphanumeric()).take(80).collect::<String>();
                let key = format!("comment:{at}:{}:{}:{digest}", f.author, f.location.clone().unwrap_or_default());
                if self.feedback_sent.insert(key) {
                    let body: String = f.body.chars().take(800).collect();
                    comments.push(format!("- @{}{}: {}", f.author, f.location.as_ref().map(|l| format!(" on {l}")).unwrap_or_default(), body.trim()));
                }
            }
            if failures.is_empty() && comments.is_empty() {
                continue;
            }
            let mut text = format!("New feedback on {at}:");
            if !failures.is_empty() {
                text.push_str(&format!(
                    "\n\nChecks failing: {}. Look at why (gh pr checks {} --repo {}, and gh run view --log-failed for a run), fix them and push.",
                    failures.join(", "),
                    pr.number,
                    pr.repo
                ));
            }
            if !comments.is_empty() {
                text.push_str(&format!("\n\nComments:\n{}", comments.join("\n")));
            }
            lines.push(text);
        }
        // A check that passes again can fail anew.
        self.feedback_sent.retain(|k| !k.starts_with("check:") || failing_now.contains(k));
        if std::mem::take(&mut self.feedback_seeding) {
            lines.clear();
        }
        if !lines.is_empty() {
            lines.push("Fix what you agree with and say why not for the rest, commit and push, then reply briefly on each review thread you've dealt with.".into());
            self.feedback_queue.push(lines.join("\n\n"));
        }
        let _ = std::fs::write(dir.join("feedback-sent.json"), serde_json::to_vec(&self.feedback_sent).unwrap_or_default());
    }

    /// Passes queued feedback to claude once its turn has ended, never
    /// mid-work or while it's asking something.
    fn deliver_feedback(&mut self, cx: &mut Context<Self>) {
        if self.feedback_queue.is_empty() || self.data.state != WorkState::YourTurn {
            return;
        }
        let text = self.feedback_queue.join("\n\n");
        self.feedback_queue.clear();
        self.send(text, false, cx);
    }

    /// Where claude is, from the hooks' state file, and what it's asking.
    fn refresh_state(&mut self, dir: &std::path::Path, cx: &mut Context<Self>) {
        let Some(live) = &self.live else { return };
        let state = match live.launch.state().as_deref() {
            Some("working") => WorkState::Working,
            Some("needs-you") => WorkState::NeedsYou,
            Some("idle") => WorkState::YourTurn,
            Some("exited") | Some("stopped") => WorkState::Exited,
            _ => WorkState::Starting,
        };
        let asking = if state == WorkState::NeedsYou {
            let screen = live.terminal.read(cx).get_content();
            Some(crate::work_live::ask(dir, &screen))
        } else {
            None
        };
        // A new question starts with nothing picked, the card showing.
        let fresh = match (&self.data.ask, &asking) {
            (Some(Ask::Questions(a)), Some(Ask::Questions(b))) => a.len() != b.len() || a.iter().zip(b).any(|(x, y)| x.question != y.question),
            (None, Some(_)) => true,
            _ => false,
        };
        if fresh {
            self.ask_away = false;
            self.picked = match &asking {
                Some(Ask::Questions(qs)) => vec![Vec::new(); qs.len()],
                _ => Vec::new(),
            };
        }
        self.data.state = state;
        self.data.ask = asking;
    }

    /// Types into claude's terminal: text as one message, then Return.
    fn send(&mut self, text: String, escape_first: bool, cx: &mut Context<Self>) {
        let Some(live) = &self.live else { return };
        let terminal = live.terminal.clone();
        cx.spawn(async move |_, cx| {
            if escape_first {
                terminal.update(cx, |t, _| t.input(b"\x1b[27u".to_vec()));
                cx.background_executor().timer(std::time::Duration::from_millis(400)).await;
            }
            terminal.update(cx, |t, _| t.paste(&text));
            cx.background_executor().timer(std::time::Duration::from_millis(150)).await;
            terminal.update(cx, |t, _| t.input(b"\r".to_vec()));
        })
        .detach();
    }

    /// Keys to the terminal: a choice's digit, Return, or Esc. Claude Code
    /// turns on the kitty keyboard protocol, so Esc goes as `CSI 27 u`: a
    /// bare escape byte is ignored.
    fn keys(&self, bytes: &[u8], cx: &mut Context<Self>) {
        if let Some(live) = &self.live {
            let bytes = bytes.to_vec();
            live.terminal.update(cx, |t, _| t.input(bytes));
        }
    }

    fn send_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.composer.read(cx).text(cx).trim().to_string();
        if text.is_empty() {
            return;
        }
        self.composer.update(cx, |e, cx| e.set_text("", window, cx));
        self.send(text, false, cx);
    }

    /// The questions' answers as one message, after Esc closes claude's own
    /// picker, as Gannin answers them.
    fn send_answers(&mut self, cx: &mut Context<Self>) {
        let Some(Ask::Questions(questions)) = self.data.ask.clone() else { return };
        let lines: Vec<String> = questions
            .iter()
            .enumerate()
            .map(|(i, q)| {
                let picked: Vec<String> = self.picked.get(i).into_iter().flatten().filter_map(|&o| q.options.get(o).map(|(l, _, _)| l.clone())).collect();
                format!("- {}: {}", q.question, if picked.is_empty() { "your call".to_string() } else { picked.join(", ") })
            })
            .collect();
        self.send(format!("My answers:\n{}", lines.join("\n")), true, cx);
    }

    fn send_failures(&mut self, number: i64, cx: &mut Context<Self>) {
        let Some(pr) = self.data.prs.iter_mut().find(|p| p.number == number) else { return };
        pr.failures_sent = true;
        let text = format!(
            "The checks failing on {}#{}: {}. Look at why they fail (gh pr checks {} --repo {}), fix them, and push.",
            pr.repo,
            pr.number,
            pr.failed.join(", "),
            pr.number,
            pr.repo
        );
        self.send(text, false, cx);
    }

    fn send_feedback(&mut self, number: i64, cx: &mut Context<Self>) {
        let ticked: Vec<usize> = self.ticked.iter().filter(|(n, _)| *n == number).map(|(_, i)| *i).collect();
        let Some(pr) = self.data.prs.iter_mut().find(|p| p.number == number) else { return };
        let mut items: Vec<String> = Vec::new();
        for (i, f) in pr.feedback.iter_mut().enumerate().filter(|(i, _)| ticked.contains(i)) {
            let _ = i;
            f.sent = true;
            items.push(format!("- @{}{}: {}", f.author, f.location.as_ref().map(|l| format!(" on {l}")).unwrap_or_default(), f.body));
        }
        let text = format!("Feedback on {}#{} to deal with:\n{}", pr.repo, pr.number, items.join("\n"));
        self.ticked.retain(|(n, _)| *n != number);
        self.send(text, false, cx);
    }

    /// Stop Claude: ends claude (Ctrl-C twice), keeping the shell and the
    /// worktree, to resume later.
    fn stop_claude(&mut self, cx: &mut Context<Self>) {
        let Some(live) = &self.live else { return };
        let terminal = live.terminal.clone();
        cx.spawn(async move |_, cx| {
            terminal.update(cx, |t, _| t.input(b"\x1b[99;5u".to_vec()));
            cx.background_executor().timer(std::time::Duration::from_millis(300)).await;
            terminal.update(cx, |t, _| t.input(b"\x1b[99;5u".to_vec()));
        })
        .detach();
    }

    /// Forget, after asking: the session leaves the pilot; its files stay.
    fn forget(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let folder = self.data.folder.clone();
        let answer = window.prompt(
            gpui::PromptLevel::Warning,
            "Forget this session?",
            Some(&format!("Claude is ended and Gannin forgets the session. Its folder and worktrees stay at {folder} for you to remove with git worktree remove.")),
            &["Forget Session", "Cancel"],
            cx,
        );
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(0) {
                this.update(cx, |_, cx| cx.emit(WorkEvent::Forget)).ok();
            }
        })
        .detach();
    }

    /// Finish, after asking: the worktrees are removed (with anything not
    /// pushed in them) and the session leaves the pilot.
    fn finish(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let folder = self.data.folder.clone();
        let worktrees: Vec<String> = self.data.worktrees.iter().map(|w| w.path.clone()).collect();
        let answer = window.prompt(
            gpui::PromptLevel::Warning,
            "Finish this session?",
            Some(&format!("Claude is ended, the worktrees in {folder} are removed with anything not pushed in them, and Gannin forgets the session.")),
            &["Finish and Remove Worktrees", "Cancel"],
            cx,
        );
        cx.spawn(async move |this, cx| {
            if answer.await != Ok(0) {
                return;
            }
            cx.background_executor()
                .spawn(async move {
                    for path in &worktrees {
                        let _ = std::process::Command::new("git").args(["-C", path, "worktree", "remove", "--force", path]).output();
                    }
                    let _ = std::fs::remove_dir_all(&folder);
                })
                .await;
            this.update(cx, |_, cx| cx.emit(WorkEvent::Forget)).ok();
        })
        .detach();
    }

    /// Reads a file's diff for a live session, off the main thread.
    fn load_diff(&mut self, worktree: String, path: String, cx: &mut Context<Self>) {
        if self.live.is_none() {
            return;
        }
        let uncommitted = self.uncommitted;
        cx.spawn(async move |this, cx| {
            let (wt, p) = (worktree.clone(), path.clone());
            let lines = cx.background_executor().spawn(async move { crate::work_live::diff(std::path::Path::new(&wt), &p, uncommitted) }).await;
            this.update(cx, |this, cx| {
                this.diffs.insert((worktree, path, uncommitted), lines);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// What closing the tab would leave: files not committed and commits
    /// not pushed, per worktree, and whether every PR is merged.
    pub fn closing(&self) -> (Vec<String>, bool) {
        let notes = self
            .data
            .worktrees
            .iter()
            .filter_map(|w| {
                let mut parts = Vec::new();
                if !w.uncommitted.is_empty() {
                    parts.push(format!("{} not committed", if w.uncommitted.len() == 1 { "1 file".to_string() } else { format!("{} files", w.uncommitted.len()) }));
                }
                match w.unpushed {
                    Some(0) => {}
                    Some(n) => parts.push(format!("{n} commit{} not pushed", if n == 1 { "" } else { "s" })),
                    None if !w.files.is_empty() => parts.push("never pushed".into()),
                    None => {}
                }
                (!parts.is_empty()).then(|| format!("{}: {}", w.name, parts.join(", ")))
            })
            .collect();
        let merged = !self.data.prs.is_empty() && self.data.prs.iter().all(|p| p.state == PrState::Merged);
        (notes, merged)
    }

    /// Finish from outside (the close prompt).
    pub fn start_finish(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.finish(window, cx);
    }

    fn stage_tint(status: StageStatus, theme: &Theme) -> Hsla {
        match status {
            StageStatus::Waiting => theme.tertiary,
            StageStatus::Running => theme.blue(),
            StageStatus::Holding => theme.orange(),
            StageStatus::Done => theme.good(),
            StageStatus::Failed => theme.critical(),
        }
    }

    fn stage_mark(status: StageStatus) -> &'static str {
        match status {
            StageStatus::Waiting => "○",
            StageStatus::Running => "●",
            StageStatus::Holding => "◆",
            StageStatus::Done => "✓",
            StageStatus::Failed => "✕",
        }
    }

    /// The workflow across the top: each stage, how it's going, and a few
    /// words; one opens its detail in the side panel.
    fn workflow_strip(&self, run: &WorkflowRun, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .gap_1()
            .px_3()
            .py_1p5()
            .border_b_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(div().flex_none().pr_2().text_xs().text_color(theme.secondary).child(run.name.clone()))
            .children(run.stages.iter().enumerate().map(|(i, stage)| {
                let tint = Self::stage_tint(stage.status, theme);
                let on = self.pane == Pane::Workflow && self.stage == i;
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1()
                    .when(i > 0, |d| d.child(div().text_color(theme.tertiary).child("›")))
                    .child(
                        div()
                            .id(SharedString::from(format!("stage-{i}")))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_1p5()
                            .px_2()
                            .py_0p5()
                            .rounded_md()
                            .text_sm()
                            .cursor_pointer()
                            .when(on, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected.opacity(0.6)))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.pane = Pane::Workflow;
                                this.stage = i;
                                this.panel_open = true;
                                cx.notify();
                            }))
                            .child(div().text_color(tint).child(Self::stage_mark(stage.status)))
                            .child(div().when(stage.status == StageStatus::Waiting, |d| d.text_color(theme.secondary)).child(stage.title.clone()))
                            .when(!stage.note.is_empty(), |d| d.child(div().text_xs().text_color(tint).child(stage.note.clone()))),
                    )
            }))
    }

    /// A stage's detail: each step, what it said, and for a local review
    /// its findings and what the session did with each.
    fn workflow_pane(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(run) = &self.data.workflow else { return div().into_any_element() };
        let Some(stage) = run.stages.get(self.stage) else { return div().into_any_element() };
        let caption = match stage.title.as_str() {
            "Prepare" => "Ran once before the session started; what they wrote is in its brief.",
            "Session" => "The Claude Code session you can talk to, in the terminal.",
            "Local review" => "Checks the work in the worktree before it leaves this Mac. Pushing and opening the PR wait until blockers and majors are fixed or answered, and every command passes.",
            "On the PR" => "Reviewers on the open pull request, and the bots' comments for the session to deal with.",
            _ => "Done when the PR is open, its checks pass and the bots' comments are dealt with.",
        };
        let holding = stage.status == StageStatus::Holding;
        div()
            .flex()
            .flex_col()
            .gap_4()
            .p_4()
            .child(
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
                            .child(div().text_color(Self::stage_tint(stage.status, theme)).child(Self::stage_mark(stage.status)))
                            .child(div().font_weight(FontWeight::SEMIBOLD).child(stage.title.clone()))
                            .when(!stage.note.is_empty(), |d| d.child(div().text_sm().text_color(Self::stage_tint(stage.status, theme)).child(stage.note.clone()))),
                    )
                    .child(div().text_sm().text_color(theme.secondary).child(caption)),
            )
            .when(holding, |d| {
                d.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .p_2()
                        .rounded_md()
                        .bg(theme.orange().opacity(0.1))
                        .child(div().flex_1().min_w_0().text_sm().child("Pushing waits for this review."))
                        .child(Self::button("push-anyway", "Push Anyway", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                            // The gate lets this commit through; the review's
                            // findings stay for the session.
                            if this.live.is_some() {
                                return this.push_anyway(cx);
                            }
                            let stage = this.stage;
                            if let Some(s) = this.data.workflow.as_mut().and_then(|w| w.stages.get_mut(stage)) {
                                s.status = StageStatus::Done;
                                s.note = "Pushed anyway".into();
                            }
                            cx.notify();
                        }))),
                )
            })
            .when(stage.steps.is_empty(), |d| d.child(div().text_sm().text_color(theme.secondary).child("No steps in this stage.")))
            .children(stage.steps.iter().enumerate().map(|(si, step)| {
                let tint = Self::stage_tint(step.status, theme);
                div()
                    .flex()
                    .flex_col()
                    .gap_1p5()
                    .p(px(10.))
                    .rounded_lg()
                    .bg(theme.bg)
                    .border_1()
                    .border_color(theme.border)
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .child(div().text_color(tint).child(Self::stage_mark(step.status)))
                            .child(div().flex_1().font_weight(FontWeight::MEDIUM).child(step.name.clone()))
                            .child(div().text_xs().text_color(theme.secondary).child(step.provider.clone())),
                    )
                    .when(!step.summary.is_empty(), |d| {
                        d.child(div().text_sm().text_color(if step.provider == "Command" { theme.fg } else { theme.secondary }).when(step.provider == "Command", |d| d.font_family("SF Mono").text_xs()).child(step.summary.clone()))
                    })
                    .children(step.findings.iter().enumerate().map(move |(fi, f)| {
                        let sev = match f.severity.as_str() {
                            "blocker" => theme.critical(),
                            "major" => theme.orange(),
                            "minor" => gpui::rgb(0xEDA100).into(),
                            _ => theme.secondary,
                        };
                        div()
                            .id(SharedString::from(format!("lf-{si}-{fi}")))
                            .flex()
                            .flex_row()
                            .gap_2()
                            .child(div().w(px(3.)).flex_none().rounded_full().bg(sev))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .flex()
                                    .flex_col()
                                    .gap_0p5()
                                    .child(
                                        div()
                                            .flex()
                                            .flex_row()
                                            .gap_2()
                                            .text_xs()
                                            .child(div().px_1p5().rounded_full().bg(sev.opacity(0.2)).child(f.severity.clone()))
                                            .child(div().truncate().font_family("SF Mono").text_color(theme.selected).child(f.path.clone())),
                                    )
                                    .child(div().text_sm().child(f.text.clone()))
                                    .when_some(f.outcome.clone(), |d, o| {
                                        let fixed = o.starts_with("Fixed");
                                        d.child(div().text_xs().text_color(if fixed { theme.good() } else { theme.secondary }).child(o))
                                    }),
                            )
                    }))
            }))
            .into_any_element()
    }

    fn button(id: impl Into<SharedString>, label: impl Into<SharedString>, prominent: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .flex_none()
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_sm()
            .map(|d| if prominent { d.bg(theme.selected).text_color(theme.on_selected) } else { d.border_1().border_color(theme.border) })
            .when(enabled, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)))
            .when(!enabled, |d| d.opacity(0.4))
            .child(label.into())
    }

    fn dot(color: Hsla, size: f32) -> gpui::Div {
        div().flex_none().size(px(size)).rounded_full().bg(color)
    }

    /// A group in the sidebar, in a well: the page's background in a
    /// rounded, bordered box on the sidebar's tint, as the Done box is.
    fn section(title: &str, theme: &Theme) -> gpui::Div {
        div().flex().flex_col().gap_1p5().p_3().rounded_lg().bg(theme.bg).border_1().border_color(theme.border).child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(title.to_uppercase()))
    }

    fn fact(label: &str, value: impl IntoElement, theme: &Theme) -> gpui::Div {
        div().flex().flex_row().gap_3().text_sm().child(div().w(px(90.)).flex_none().text_color(theme.secondary).child(label.to_string())).child(div().flex_1().min_w_0().child(value))
    }

    /// The org whose harnesses to look in, and the issue and PRs a plan
    /// may be linked to.
    fn plan_items(&self) -> (String, Vec<(String, i64)>) {
        let Some(live) = &self.live else { return (String::new(), Vec::new()) };
        let mut items: Vec<(String, i64)> = live.launch.subject.iter().map(|s| (s.repo.clone(), s.number)).collect();
        items.extend(self.data.prs.iter().map(|p| (p.repo.clone(), p.number)));
        (live.launch.org.clone(), items)
    }

    /// "Plans and requirements": shown even when there are none yet, as
    /// claude may be writing the plan.
    fn plans_section(&self, theme: &Theme, cx: &mut Context<Self>) -> gpui::Div {
        let title = match &self.plans {
            Some(plans) if !plans.is_empty() => format!("Plans and requirements · {}", plans.len()),
            _ => "Plans and requirements".into(),
        };
        let section = Self::section(&title, theme);
        match &self.plans {
            None => section.child(div().text_sm().text_color(theme.secondary).child("Looking in the harness")),
            Some(plans) if plans.is_empty() => section.child(
                div().text_sm().text_color(theme.secondary).child("None in the harness yet. A plan claude commits there shows here once the harness is fetched again."),
            ),
            Some(plans) => section.children(crate::harness::plan_rows("work-plan", plans, theme, cx)),
        }
    }

    fn file_count(&self) -> usize {
        self.data.worktrees.iter().map(|w| w.files.len()).sum()
    }

    fn failed_count(&self) -> usize {
        self.data.prs.iter().filter(|p| p.state == PrState::Open).map(|p| p.failed.len()).sum()
    }

    // MARK: Terminal column

    fn terminal_column(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let state = self.data.state;
        let terminal = match &self.terminal {
            Some(view) => div().size_full().child(view.clone()).into_any_element(),
            None => div()
                .size_full()
                .p_3()
                .font_family("SF Mono")
                .text_xs()
                .text_color(theme.secondary)
                .flex()
                .flex_col()
                .gap_1()
                .children(self.mock_terminal_lines().into_iter().map(|l| div().child(l)))
                .into_any_element(),
        };
        div()
            .flex_1()
            .min_w(px(480.))
            .h_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .child(terminal)
                    .when(!state.running(), |d| {
                        d.child(div().absolute().top(px(12.)).right(px(12.)).child(Self::button("work-resume", "Resume", true, true, theme).on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(WorkEvent::Resume)))))
                    })
                    .when_some(self.data.ask.clone().filter(|_| state == WorkState::NeedsYou), |d, ask| {
                        if self.ask_away {
                            d.child(
                                div().absolute().bottom(px(12.)).right(px(12.)).child(
                                    div()
                                        .id("ask-back")
                                        .px_3()
                                        .py_1()
                                        .rounded_md()
                                        .bg(gpui::rgb(0xFF9F0A))
                                        .text_color(gpui::white())
                                        .cursor_pointer()
                                        .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                            this.ask_away = false;
                                            cx.notify();
                                        }))
                                        .child("Claude is asking"),
                                ),
                            )
                        } else {
                            // It takes the terminal's whole area, to read and answer.
                            d.child(div().absolute().top_0().bottom_0().left_0().right_0().p_3().bg(theme.bg.opacity(0.6)).child(self.ask_card(&ask, theme, cx)))
                        }
                    }),
            )
            .child(self.composer_bar(theme, cx))
    }

    fn mock_terminal_lines(&self) -> Vec<String> {
        match self.data.state {
            WorkState::Starting => vec!["Cloning acme/api into projects/api".into(), "Making the worktree issue-412-retry-webhooks".into(), "Starting claude".into()],
            WorkState::Exited => vec!["> The PR is open and its checks pass.".into(), "".into(), "Claude Code has exited. This shell is in the harness; run claude --resume to go on.".into()],
            _ => vec![
                "> Work on acme/api#412: Retry failed webhooks with backoff".into(),
                "".into(),
                "⏺ Reading the issue and the webhook sender.".into(),
                "⏺ Read(src/webhooks/sender.rs)".into(),
                "⏺ Update(src/webhooks/sender.rs)".into(),
                "  ⎿  Added 38 lines, removed 6 lines".into(),
                "⏺ Bash(cargo test webhooks)".into(),
                "  ⎿  test result: ok. 14 passed".into(),
                "".into(),
                "(Claude's terminal shows here in a real session.)".into(),
            ],
        }
    }

    fn composer_bar(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let state = self.data.state;
        let running = state.running();
        self.shortcuts.update(cx, |bar, cx| bar.set_enabled(running && self.live.is_some(), cx));
        let gauge_tint = if self.data.context > 0.85 {
            theme.critical()
        } else if self.data.context > 0.7 {
            theme.orange()
        } else {
            theme.secondary
        };
        div()
            .flex_none()
            .flex()
            .flex_row()
            .items_end()
            .gap_2()
            .px(px(10.))
            .py(px(7.))
            .border_t_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.bg)
                    .when(!running, |d| d.opacity(0.5))
                    .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "enter" && !event.keystroke.modifiers.shift {
                            cx.stop_propagation();
                            this.send_composer(window, cx);
                        }
                    }))
                    .child(self.composer.clone()),
            )
            .child(self.shortcuts.clone())
            .child(Self::button("work-send", "Send", false, running, theme).when(running, |b| b.on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.send_composer(window, cx)))))
            .child(Self::button("work-stop", "Stop", false, state == WorkState::Working, theme).when(state == WorkState::Working, |b| {
                // Esc stops claude mid-turn, to say something else.
                b.on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.keys(b"\x1b[27u", cx)))
            }))
            .when_some(self.data.last_check, |d, passed| {
                d.child(div().flex_none().text_xs().text_color(if passed { theme.good() } else { theme.critical() }).child(if passed { "Passed" } else { "Failed" }))
            })
            .child(div().flex_none().text_xs().text_color(gauge_tint).child(format!("{}%", (self.data.context * 100.).round())))
            .child(Self::button("work-panel-toggle", if self.panel_open { "Hide Panel" } else { "Show Panel" }, false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.panel_open = !this.panel_open;
                cx.notify();
            })))
    }

    fn ask_card(&self, ask: &Ask, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let orange: Hsla = gpui::rgb(0xFF9F0A).into();
        let card = div()
            .id("ask-card")
            .size_full()
            .overflow_y_scroll()
            .p_5()
            .flex()
            .flex_col()
            .gap_3()
            .rounded(px(12.))
            .bg(theme.popover)
            .border(px(1.5))
            .border_color(orange)
            .shadow_lg();
        let away = div()
            .id("ask-away")
            .px_1p5()
            .rounded_md()
            .cursor_pointer()
            .text_color(theme.secondary)
            .hover(|s| s.bg(theme.row_selected))
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.ask_away = true;
                cx.notify();
            }))
            .child("Answer in Terminal");
        match ask {
            Ask::Permission { tool, text, choices } => {
                let title = match tool.as_str() {
                    "Bash" => "Claude wants to run a command".to_string(),
                    "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => "Claude wants to change a file".to_string(),
                    "WebFetch" | "WebSearch" => "Claude wants to go online".to_string(),
                    "ExitPlanMode" => "Claude wants to leave planning and start making changes".to_string(),
                    "" => "Claude needs your permission".to_string(),
                    other => format!("Claude wants to use {other}"),
                };
                card.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(Self::dot(orange, 10.))
                        .child(div().flex_1().min_w_0().text_lg().font_weight(FontWeight::SEMIBOLD).child(title))
                        .child(away),
                )
                .child(div().p_2().rounded_md().bg(theme.bg).font_family("SF Mono").text_sm().child(text.clone()))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .justify_end()
                        .gap_2()
                        // The terminal's own choices, each picked by its digit;
                        // without them, Allow (Return) and Deny (Esc).
                        .child(Self::button("perm-deny", "Deny", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.keys(b"\x1b[27u", cx))))
                        .map(|row| {
                            if choices.is_empty() {
                                row.child(Self::button("perm-allow", "Allow", true, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.keys(b"\r", cx))))
                            } else {
                                row.children(choices.iter().enumerate().rev().map(|(i, c)| {
                                    let digit = c.chars().next().filter(|d| d.is_ascii_digit()).unwrap_or('1');
                                    let label = c.split_once(". ").map(|(_, l)| l.to_string()).unwrap_or_else(|| c.clone());
                                    Self::button(format!("perm-choice-{i}"), label, i == 0, true, theme)
                                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.keys(digit.to_string().as_bytes(), cx)))
                                }))
                            }
                        }),
                )
            }
            Ask::Questions(questions) => {
                let answered = self.picked.iter().filter(|p| !p.is_empty()).count();
                let title = if questions.len() == 1 { "Claude is asking".to_string() } else { format!("Claude has {} questions", questions.len()) };
                card.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(Self::dot(orange, 10.))
                        .child(div().flex_1().min_w_0().text_lg().font_weight(FontWeight::SEMIBOLD).child(title))
                        .child(away),
                )
                .children(questions.iter().enumerate().map(|(qi, q)| {
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(div().px_1p5().rounded_full().text_xs().bg(orange.opacity(0.2)).child(q.header.clone()))
                                .child(div().font_weight(FontWeight::SEMIBOLD).child(q.question.clone()))
                                .when(q.multi, |d| d.child(div().text_xs().text_color(theme.secondary).child("Pick any"))),
                        )
                        .child(div().flex().flex_row().flex_wrap().gap_2().children(q.options.iter().enumerate().map(|(oi, (label, desc, recommended))| {
                            let on = self.picked.get(qi).is_some_and(|p| p.contains(&oi));
                            let multi = q.multi;
                            div()
                                .id(SharedString::from(format!("opt-{qi}-{oi}")))
                                .w(px(240.))
                                .p_2()
                                .rounded_lg()
                                .cursor_pointer()
                                .bg(if on { theme.selected.opacity(0.15) } else { theme.tile })
                                .border_1()
                                .border_color(if on { theme.selected } else { theme.border })
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    if let Some(p) = this.picked.get_mut(qi) {
                                        if multi {
                                            if let Some(at) = p.iter().position(|&o| o == oi) {
                                                p.remove(at);
                                            } else {
                                                p.push(oi);
                                            }
                                        } else {
                                            *p = vec![oi];
                                        }
                                    }
                                    cx.notify();
                                }))
                                .child(
                                    div()
                                        .flex()
                                        .flex_row()
                                        .items_center()
                                        .gap_1p5()
                                        .child(div().text_color(if on { theme.selected } else { theme.secondary }).child(if on { "◉" } else { "○" }))
                                        .child(div().font_weight(FontWeight::SEMIBOLD).child(label.clone()))
                                        .when(*recommended, |d| d.child(div().text_xs().text_color(theme.selected).child("Recommended"))),
                                )
                                .child(div().text_sm().text_color(theme.secondary).child(desc.clone()))
                        })))
                }))
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(div().flex_1().min_w_0().text_sm().text_color(theme.secondary).child(if answered == questions.len() {
                            "Ready to send.".to_string()
                        } else {
                            format!("{answered} of {} answered. Any left go as \"your call\".", questions.len())
                        }))
                        .child(Self::button("q-dismiss", "Dismiss", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.keys(b"\x1b[27u", cx))))
                        .child(Self::button("q-send", "Send Answers", true, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.send_answers(cx)))),
                )
            }
        }
    }

    // MARK: Side panel

    fn side_panel(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let files = self.file_count();
        let prs = self.data.prs.len();
        let failed = self.failed_count();
        let tab = |id: &'static str, label: String, pane: Pane, cx: &mut Context<Self>| {
            let on = self.pane == pane;
            div()
                .id(id)
                .flex_1()
                .py_0p5()
                .flex()
                .justify_center()
                .rounded_md()
                .text_sm()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.bg))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.pane = pane;
                    cx.notify();
                }))
                .child(label)
        };
        let body = match self.pane {
            Pane::Issue => self.issue_pane(theme, cx).into_any_element(),
            Pane::Changes => self.changes_pane(theme, cx).into_any_element(),
            Pane::Activity => self.activity_pane(theme).into_any_element(),
            Pane::Workflow => self.workflow_pane(theme, cx).into_any_element(),
        };
        div()
            .w(px(440.))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(
                div()
                    .flex_none()
                    .p_2()
                    .child(
                        div()
                            .p_0p5()
                            .flex()
                            .flex_row()
                            .gap_0p5()
                            .rounded_md()
                            .bg(theme.grid)
                            .child(tab(
                                "pane-issue",
                                match (prs, failed) {
                                    (0, _) => "Issue".into(),
                                    (n, 0) => format!("Issue · {}", if n == 1 { "1 PR".to_string() } else { format!("{n} PRs") }),
                                    (n, f) => format!("Issue · {} ✕{f}", if n == 1 { "1 PR".to_string() } else { format!("{n} PRs") }),
                                },
                                Pane::Issue,
                                cx,
                            ))
                            .child(tab("pane-changes", if files > 0 { format!("Changes {files}") } else { "Changes".into() }, Pane::Changes, cx))
                            .child(tab("pane-activity", "Activity".into(), Pane::Activity, cx))
                            .when(self.data.workflow.is_some(), |d| d.child(tab("pane-workflow", "Workflow".into(), Pane::Workflow, cx))),
                    ),
            )
            .child(div().id("work-pane").flex_1().min_h_0().overflow_y_scroll().child(body))
    }

    fn issue_pane(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let d = &self.data;
        let state = d.state;
        let all_merged = !d.prs.is_empty() && d.prs.iter().all(|p| p.state == PrState::Merged);
        let stale = !state.running() && d.idle_days > 3;
        div()
            .flex()
            .flex_col()
            .gap_3()
            .p_3()
            .when(all_merged || stale, |el| {
                // A neutral box with an edge in its colour: green when done.
                let edge = if all_merged { theme.good() } else { theme.secondary };
                el.child(
                    div()
                        .flex()
                        .flex_row()
                        .rounded_lg()
                        .overflow_hidden()
                        .bg(theme.bg)
                        .border_1()
                        .border_color(theme.border)
                        .child(div().w(px(3.)).flex_none().bg(edge))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .p_3()
                                .flex()
                                .flex_col()
                                .gap_2()
                                .child(div().font_weight(FontWeight::SEMIBOLD).text_color(edge).child(if all_merged { "Done" } else { "Stale" }))
                                .child(div().text_sm().text_color(theme.secondary).child(if all_merged {
                                    "Every pull request from this session is merged, so its worktrees can go."
                                } else {
                                    "Nothing's happened in this session for over three days. Finish it to remove its worktrees, or leave it be."
                                }))
                                .child(div().flex().flex_row().child(Self::button("work-finish", "Finish and Remove Worktrees", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.finish(window, cx))))),
                        ),
                )
            })
            // The plans first: how far the work has got against them.
            .when(self.live.is_some() && !d.reference.is_empty(), |el| el.child(self.plans_section(theme, cx)))
            // Then the pull requests: where the work stands.
            .when(!d.prs.is_empty(), |el| el.child(Self::section(&format!("Pull requests · {}", d.prs.len()), theme).child(self.pr_filters(theme, cx)).child(self.pr_cards(theme, cx))))
            .child(
                Self::section("Issue", theme)
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(d.title.clone()))
                    .child({
                        let url = d.issue_url.clone();
                        div()
                            .id("work-issue-link")
                            .text_sm()
                            .text_color(theme.selected)
                            .cursor_pointer()
                            .hover(|s| s.opacity(0.8))
                            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                            .child(d.reference.clone())
                    })
                    .child(markdown("work-issue-body", &d.issue_body, theme)),
            )
            .child(
                Self::section("Claude Code", theme)
                    .child(Self::fact("State", div().flex().flex_row().items_center().gap_1p5().child(Self::dot(state.tint(theme), 8.)).child(state.label()), theme))
                    .child(Self::fact("Branch", div().font_family("SF Mono").text_xs().truncate().child(d.branch.clone()), theme))
                    .child(Self::fact("Worktree", div().text_xs().truncate().child(d.folder.clone()), theme))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .pt_1()
                            .child(Self::button("work-finder", if cfg!(target_os = "macos") { "Show in Finder" } else { "Show in Files" }, false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                cx.open_with_system(std::path::Path::new(&this.data.folder));
                            })))
                            .child(Self::button("work-stop-resume", if state.running() { "Stop Claude" } else { "Resume" }, false, true, theme).on_click(cx.listener(
                                move |this, _: &ClickEvent, _, cx| {
                                    if state.running() {
                                        this.stop_claude(cx)
                                    } else {
                                        cx.emit(WorkEvent::Resume)
                                    }
                                },
                            )))
                            .when(!state.running() && self.live.as_ref().is_some_and(|l| l.launch.server.is_none()), |d| {
                                d.child(Self::button("work-move", "Move to Server", false, true, theme).on_click(cx.listener(|_, _: &ClickEvent, _, cx| cx.emit(WorkEvent::MoveToServer))))
                            })
                            .child(Self::button("work-forget", "Forget", false, true, theme).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.forget(window, cx)))),
                    )
                    .child(div().text_xs().text_color(theme.secondary).child(if state.running() {
                        "Stop Claude ends it and keeps the worktree, to resume later. Forget ends claude and takes the session out of Gannin; its files stay."
                    } else {
                        "Resume starts claude again where the conversation left off. Move to Server takes it, its worktrees and the conversation to the window's server, to resume there. Forget takes the session out of Gannin; its files stay."
                    })),
            )
    }

    fn changes_pane(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let d = &self.data;
        if d.worktrees.is_empty() {
            return div()
                .p_6()
                .flex()
                .flex_col()
                .items_center()
                .gap_2()
                .child(div().font_weight(FontWeight::MEDIUM).child("No worktrees yet"))
                .child(div().text_sm().text_center().text_color(theme.secondary).child("Claude adds a worktree for each repo the issue touches, and what it changes shows here as it works."))
                .into_any_element();
        }
        let uncommitted = self.uncommitted;
        let mode = |id: &'static str, label: &'static str, value: bool, cx: &mut Context<Self>| {
            let on = uncommitted == value;
            div()
                .id(id)
                .px_2()
                .py_0p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.bg))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.uncommitted = value;
                    cx.notify();
                }))
                .child(label)
        };
        let selected = self.file.clone();
        let list = |w: &Worktree| if uncommitted { w.uncommitted.clone() } else { w.files.clone() };
        let diff = d.worktrees.iter().find_map(|w| list(w).into_iter().find(|f| Some(&f.path) == selected.as_ref()).map(|f| (w.path.clone(), f))).map(|(wt, mut f)| {
            if f.diff.is_empty() {
                f.diff = self.diffs.get(&(wt, f.path.clone(), uncommitted)).cloned().unwrap_or_default();
            }
            f
        });
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .px_3()
                    .pt_2()
                    .child(div().p_0p5().flex().flex_row().gap_0p5().rounded_md().bg(theme.grid).child(mode("mode-branch", "Branch", false, cx)).child(mode("mode-uncommitted", "Uncommitted", true, cx))),
            )
            .children(d.worktrees.iter().map(|w| {
                let files: Vec<ChangedFile> = list(w);
                let wt = w.path.clone();
                let pushed = match w.unpushed {
                    Some(0) => ("Pushed".to_string(), theme.secondary),
                    Some(n) => (format!("{n} not pushed"), theme.orange()),
                    None => ("Not pushed yet".to_string(), theme.orange()),
                };
                div()
                    .flex()
                    .flex_col()
                    .px_2()
                    .pt_3()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px_1()
                            .pb_1()
                            .child(div().flex_1().min_w_0().truncate().text_sm().font_weight(FontWeight::SEMIBOLD).child(w.name.clone()))
                            .child(div().text_xs().text_color(pushed.1).child(pushed.0))
                            .when(!uncommitted, |d| d.child(div().text_xs().text_color(theme.tertiary).child(format!("against {}", w.base)))),
                    )
                    .when(files.is_empty(), |d| d.child(div().px_1().text_sm().text_color(theme.secondary).child("No changes")))
                    .children(files.into_iter().map(|f| {
                        let on = selected.as_ref() == Some(&f.path);
                        let path = f.path.clone();
                        let wt = wt.clone();
                        let (name, folder) = f.path.rsplit_once('/').map(|(a, b)| (b.to_string(), a.to_string())).unwrap_or((f.path.clone(), String::new()));
                        let tint = match f.status {
                            'A' => theme.good(),
                            'D' => theme.critical(),
                            _ => theme.orange(),
                        };
                        div()
                            .id(SharedString::from(format!("file-{}", f.path)))
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap_2()
                            .px_1()
                            .py_0p5()
                            .rounded_md()
                            .text_sm()
                            .cursor_pointer()
                            .when(on, |d| d.bg(theme.row_selected))
                            .hover(|s| s.bg(theme.row_selected.opacity(0.5)))
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.file = Some(path.clone());
                                this.load_diff(wt.clone(), path.clone(), cx);
                                cx.notify();
                            }))
                            .child(div().w(px(12.)).flex_none().font_family("SF Mono").text_xs().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(f.status.to_string()))
                            .child(div().flex_none().child(name))
                            .child(div().flex_1().min_w_0().truncate().text_xs().text_color(theme.secondary).child(folder))
                            .when(uncommitted && f.staged, |d| d.child(div().text_xs().text_color(theme.good()).child("staged")))
                            .child(div().flex_none().text_xs().text_color(theme.good()).child(format!("+{}", f.additions)))
                            .child(div().flex_none().text_xs().text_color(theme.critical()).child(format!("-{}", f.deletions)))
                    }))
            }))
            .when_some(diff, |el, f| {
                el.child(
                    div()
                        .mt_3()
                        .border_t_1()
                        .border_color(theme.border)
                        .child(div().px_3().py_1p5().font_family("SF Mono").text_xs().border_b_1().border_color(theme.border).child(f.path.clone()))
                        .children(f.diff.iter().map(|line| {
                            let (bg, fg) = match line.chars().next() {
                                Some('+') => (theme.good().opacity(0.14), theme.fg),
                                Some('-') => (theme.critical().opacity(0.14), theme.fg),
                                Some('@') => (theme.tile, theme.secondary),
                                _ => (gpui::transparent_black(), theme.fg),
                            };
                            div().px_3().bg(bg).text_color(fg).font_family("SF Mono").text_xs().child(line.clone())
                        })),
                )
            })
            .into_any_element()
    }

    /// The session's pull requests, one compact card each: state and
    /// title on a line; review, checks and conflicts on the next; then
    /// what's failing and the feedback to send, when there is any.
    /// Above the pull requests: their states, with counts, to show one;
    /// their repos, when there's more than one; and grouping by repo.
    fn pr_filters(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let prs = &self.data.prs;
        let chip = |id: SharedString, label: String, on: bool| {
            div()
                .id(id)
                .px_1p5()
                .rounded_md()
                .text_xs()
                .cursor_pointer()
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.bg(theme.row_selected))
                .hover(|s| s.bg(theme.row_selected))
                .child(label)
        };
        let mut states = vec![chip("pr-state-all".into(), format!("All {}", prs.len()), self.pr_state.is_none())
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                this.pr_state = None;
                cx.notify();
            }))
            .into_any_element()];
        for (state, label) in [(PrState::Open, "Open"), (PrState::Draft, "Draft"), (PrState::Merged, "Merged"), (PrState::Closed, "Closed")] {
            let n = prs.iter().filter(|p| p.state == state).count();
            if n == 0 {
                continue;
            }
            let on = self.pr_state == Some(state);
            states.push(
                chip(SharedString::from(format!("pr-state-{label}")), format!("{label} {n}"), on)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.pr_state = if on { None } else { Some(state) };
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }
        let mut repos: Vec<String> = prs.iter().map(|p| p.repo.clone()).collect();
        repos.sort();
        repos.dedup();
        // The repos as one menu at the right: which to show, and grouping.
        let short = |repo: &str| repo.rsplit('/').next().unwrap_or(repo).to_string();
        let open_menu = self.repo_menu;
        let by_repo = self.pr_by_repo;
        let menu_label = match &self.pr_repo {
            Some(repo) => format!("{} ▾", short(repo)),
            None => "All repos ▾".to_string(),
        };
        let item = |id: SharedString, label: String, on: bool| {
            div()
                .id(id)
                .flex()
                .flex_row()
                .gap_2()
                .px_2()
                .py_0p5()
                .rounded_sm()
                .text_xs()
                .cursor_pointer()
                .hover(|s| s.bg(theme.row_selected))
                .child(div().w(px(10.)).child(if on { "✓" } else { "" }))
                .child(label)
        };
        div()
            .relative()
            .flex()
            .flex_row()
            .items_center()
            .gap_0p5()
            .children(states)
            .child(div().flex_1())
            .when(repos.len() > 1, |d| {
                d.child(chip("pr-repo-menu".into(), menu_label, open_menu || self.pr_repo.is_some()).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.repo_menu = !open_menu;
                    cx.notify();
                })))
                .when(open_menu, |d| {
                    d.child(
                        div()
                            .absolute()
                            .top(px(22.))
                            .right_0()
                            .min_w(px(170.))
                            .flex()
                            .flex_col()
                            .p_1()
                            .rounded_md()
                            .border_1()
                            .border_color(theme.border)
                            .bg(theme.popover)
                            .shadow_md()
                            .occlude()
                            .child(item("pr-repo-any".into(), format!("All repos {}", prs.len()), self.pr_repo.is_none()).on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                                this.pr_repo = None;
                                this.repo_menu = false;
                                cx.notify();
                            })))
                            .children(repos.iter().map(|repo| {
                                let n = prs.iter().filter(|p| &p.repo == repo).count();
                                let picked = repo.clone();
                                item(SharedString::from(format!("pr-repo-{repo}")), format!("{} {n}", short(repo)), self.pr_repo.as_ref() == Some(repo)).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    this.pr_repo = Some(picked.clone());
                                    this.repo_menu = false;
                                    cx.notify();
                                }))
                            }))
                            .child(div().my_1().h(px(1.)).bg(theme.border))
                            .child(item("pr-by-repo".into(), "Group by repo".into(), by_repo).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                this.pr_by_repo = !by_repo;
                                this.repo_menu = false;
                                cx.notify();
                            }))),
                    )
                })
            })
    }

    /// Sends what's ticked under a PR: its failing checks (when that line's
    /// ticked) and the comments ticked, each as claude's message for it.
    fn send_ticked(&mut self, number: i64, cx: &mut Context<Self>) {
        let failures = self.ticked.contains(&(number, FAILURES));
        let comments = self.ticked.iter().any(|(n, i)| *n == number && *i != FAILURES);
        if failures {
            self.send_failures(number, cx);
        }
        if comments {
            self.send_feedback(number, cx);
        }
        self.ticked.retain(|(n, _)| *n != number);
        cx.notify();
    }

    /// The session's PRs, a line each: the status as the Pull Requests
    /// table's pill, repo and number, title, and its checks as one mark.
    /// Open ones first; merged and closed folded beneath unless picked.
    /// Under an open one, what needs acting on, a line each with a box to
    /// tick (its failing checks, each comment), and one Send for them.
    fn pr_cards(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let d = &self.data;
        let running = d.state.running();
        let auto = self.auto_feedback;
        let any_open = d.prs.iter().any(|p| p.state == PrState::Open);
        let shown: Vec<&WorkPr> = d.prs.iter().filter(|p| self.pr_state.is_none_or(|s| p.state == s) && self.pr_repo.as_ref().is_none_or(|r| &p.repo == r)).collect();
        let ended = |p: &WorkPr| matches!(p.state, PrState::Merged | PrState::Closed);
        // With no state picked, the ended ones fold under the rest.
        let folding = self.pr_state.is_none();
        let mut active: Vec<&WorkPr> = shown.iter().copied().filter(|p| !folding || !ended(p)).collect();
        let mut done: Vec<&WorkPr> = if folding { shown.iter().copied().filter(|p| ended(p)).collect() } else { Vec::new() };
        if self.pr_by_repo {
            active.sort_by(|a, b| a.repo.cmp(&b.repo));
            done.sort_by(|a, b| a.repo.cmp(&b.repo));
        }
        let ended_open = self.ended_open;
        let merged_n = done.iter().filter(|p| p.state == PrState::Merged).count();
        let fold_label = match (merged_n, done.len() - merged_n) {
            (m, 0) => format!("{m} merged"),
            (0, c) => format!("{c} closed"),
            (m, c) => format!("{m} merged, {c} closed"),
        };
        let mut list: Vec<gpui::AnyElement> = Vec::new();
        let mut last_repo: Option<String> = None;
        let rows = |prs: Vec<&WorkPr>, list: &mut Vec<gpui::AnyElement>, last_repo: &mut Option<String>, cx: &mut Context<Self>| {
            for pr in prs {
                if self.pr_by_repo && last_repo.as_deref() != Some(pr.repo.as_str()) {
                    *last_repo = Some(pr.repo.clone());
                    list.push(div().pt_1().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(pr.repo.rsplit('/').next().unwrap_or(&pr.repo).to_string()).into_any_element());
                }
                list.push(self.pr_line(pr, running, theme, cx));
            }
        };
        rows(active, &mut list, &mut last_repo, cx);
        if !done.is_empty() {
            list.push(
                div()
                    .id("pr-ended-fold")
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_1p5()
                    .pt_1()
                    .text_xs()
                    .text_color(theme.secondary)
                    .cursor_pointer()
                    .hover(|s| s.text_color(theme.fg))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.ended_open = !ended_open;
                        cx.notify();
                    }))
                    .child(div().w(px(10.)).child(if ended_open { "▾" } else { "▸" }))
                    .child(fold_label)
                    .into_any_element(),
            );
            if ended_open {
                last_repo = None;
                rows(done, &mut list, &mut last_repo, cx);
            }
        }
        div()
            .flex()
            .flex_col()
            .gap_0p5()
            .when(shown.is_empty(), |d| d.child(div().text_sm().text_color(theme.secondary).child("None with these filters.")))
            .children(list)
            .when(any_open, |d| {
                d.child(
                    div()
                        .id("auto-feedback")
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .pt_2()
                        .text_xs()
                        .text_color(theme.secondary)
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.auto_feedback = !auto;
                            // Kept with the session, so a relaunch keeps it.
                            if let Some(live) = &this.live {
                                let off = live.launch.dir().join("auto-feedback-off");
                                let _ = if auto { std::fs::write(off, "") } else { std::fs::remove_file(off) };
                            }
                            cx.notify();
                        }))
                        .child(div().size(px(13.)).rounded(px(3.)).border_1().border_color(if auto { theme.selected } else { theme.secondary }).when(auto, |d| d.bg(theme.selected)).flex().items_center().justify_center().text_color(theme.on_selected).child(if auto { "✓" } else { "" }))
                        .child("Send new feedback to Claude"),
                )
            })
    }

    /// One PR's line, and under it (open) what needs acting on.
    fn pr_line(&self, pr: &WorkPr, running: bool, theme: &Theme, cx: &mut Context<Self>) -> gpui::AnyElement {
        let number = pr.number;
        let open = pr.state == PrState::Open;
        // The status as the Pull Requests table words and colours it.
        let (label, tint): (&str, Hsla) = match pr.state {
            PrState::Merged => ("Merged", theme.slot(6)),
            PrState::Closed => ("Closed", theme.critical()),
            PrState::Draft => ("Draft", theme.secondary),
            PrState::Open => match pr.review.as_deref() {
                Some("APPROVED") => ("Approved", theme.good()),
                Some("CHANGES_REQUESTED") => ("Changes requested", theme.orange()),
                Some(_) => ("In review", theme.blue()),
                None => ("Open", theme.good()),
            },
        };
        let pill = div().flex_none().px_1p5().rounded_sm().text_xs().border_1().border_color(tint).text_color(tint).child(label);
        // The checks as one mark: failing first, then running, then passed.
        let checks = if !pr.failed.is_empty() {
            Some(("✕", pr.failed.len(), theme.critical()))
        } else if !pr.pending.is_empty() {
            Some(("◷", pr.pending.len(), theme.orange()))
        } else if pr.passed > 0 {
            Some(("✓", pr.passed, theme.good()))
        } else {
            None
        };
        let name = pr.repo.rsplit('/').next().unwrap_or(&pr.repo).to_string();
        // It opens in its drawer, as a PR does everywhere else; the drawer
        // has Open PR and Open on GitHub.
        let opened = crate::prs::PrItem::stub("", &pr.repo, number, &pr.title, &format!("https://github.com/{}/pull/{number}", pr.repo));
        let head = div()
            .id(("work-pr-open", number as usize))
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .py_0p5()
            .text_sm()
            .cursor_pointer()
            .hover(|s| s.opacity(0.8))
            .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(crate::pull_page::OpenPull(opened.clone()))))
            .child(pill)
            .child(div().flex_none().text_color(theme.secondary).child(if self.pr_by_repo { format!("#{number}") } else { format!("{name}#{number}") }))
            .child(div().flex_1().min_w_0().truncate().child(pr.title.clone()))
            .when(open && pr.conflicts, |d| d.child(div().flex_none().text_xs().text_color(theme.critical()).child("Conflicts")))
            .when_some(checks, |d, (mark, n, tint)| d.child(div().flex_none().flex().flex_row().gap_0p5().text_xs().text_color(tint).child(mark).child(n.to_string())));
        // What to act on: the failing checks as one line, then each comment.
        let mut items: Vec<gpui::AnyElement> = Vec::new();
        let ticked_n = self.ticked.iter().filter(|(n, _)| *n == number).count();
        let tick_box = |on: bool| div().flex_none().size(px(13.)).rounded(px(3.)).border_1().border_color(if on { theme.selected } else { theme.secondary }).when(on, |d| d.bg(theme.selected)).flex().items_center().justify_center().text_xs().text_color(theme.on_selected).child(if on { "✓" } else { "" });
        let toggle_tick = move |key: usize| {
            move |this: &mut Self, _: &ClickEvent, _: &mut Window, cx: &mut Context<Self>| {
                if let Some(at) = this.ticked.iter().position(|t| *t == (number, key)) {
                    this.ticked.remove(at);
                } else {
                    this.ticked.push((number, key));
                }
                cx.notify();
            }
        };
        if open && !pr.failed.is_empty() {
            let on = self.ticked.contains(&(number, FAILURES));
            items.push(
                div()
                    .id(SharedString::from(format!("fail-{number}")))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_xs()
                    .cursor_pointer()
                    .on_click(cx.listener(toggle_tick(FAILURES)))
                    .child(tick_box(on))
                    .child(div().flex_none().text_color(theme.critical()).child("✕"))
                    .child(div().flex_1().min_w_0().truncate().text_color(if pr.failures_sent { theme.secondary } else { theme.fg }).child(format!("Failing: {}", pr.failed.join(", "))))
                    .when(pr.failures_sent, |d| d.child(div().flex_none().text_color(theme.tertiary).child("Sent")))
                    .into_any_element(),
            );
        }
        if open {
            for (i, f) in pr.feedback.iter().enumerate() {
                let on = self.ticked.contains(&(number, i));
                let full = self.expanded.contains(&(number, i));
                let file = f.location.as_deref().map(|l| l.rsplit('/').next().unwrap_or(l).to_string());
                let lead = match &file {
                    Some(file) => format!("@{} {file}: ", f.author),
                    None => format!("@{}: ", f.author),
                };
                items.push(
                    div()
                        .flex()
                        .flex_row()
                        .items_start()
                        .gap_2()
                        .text_xs()
                        .child(div().id(SharedString::from(format!("fb-tick-{number}-{i}"))).mt_0p5().cursor_pointer().on_click(cx.listener(toggle_tick(i))).child(tick_box(on)))
                        .child(gpui::svg().path("icons/chat.svg").mt_0p5().size(px(12.)).flex_none().text_color(theme.secondary))
                        .child(
                            // A click opens it to its full text, and closes it.
                            div()
                                .id(SharedString::from(format!("fb-{number}-{i}")))
                                .flex_1()
                                .min_w_0()
                                .cursor_pointer()
                                .text_color(if f.sent { theme.secondary } else { theme.fg })
                                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                                    if !this.expanded.remove(&(number, i)) {
                                        this.expanded.insert((number, i));
                                    }
                                    cx.notify();
                                }))
                                .map(|d| {
                                    if full {
                                        d.child(div().font_weight(FontWeight::MEDIUM).child(format!("{lead}{}", f.verdict.clone().unwrap_or_default())))
                                            .when_some(f.location.clone(), |d, l| d.child(div().font_family("SF Mono").text_color(theme.secondary).child(l)))
                                            .child(div().pt_0p5().child(f.body.clone()))
                                    } else {
                                        d.truncate().child(format!("{lead}{}", summary_line(&f.body)))
                                    }
                                }),
                        )
                        .when(f.sent, |d| d.child(div().flex_none().text_color(theme.tertiary).child("Sent")))
                        .into_any_element(),
                );
            }
        }
        let has_items = !items.is_empty();
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(head)
            .when(has_items, |d| {
                d.child(
                    div()
                        .ml(px(10.))
                        .pl_3()
                        .pb_1()
                        .border_l_1()
                        .border_color(theme.border)
                        .flex()
                        .flex_col()
                        .gap_1()
                        .children(items)
                        .child(div().flex().flex_row().justify_end().child(
                            Self::button(
                                format!("send-ticked-{number}"),
                                if ticked_n == 0 { "Send to Claude".to_string() } else { format!("Send {ticked_n} to Claude") },
                                ticked_n > 0,
                                running && ticked_n > 0,
                                theme,
                            )
                            .text_xs()
                            .when(running && ticked_n > 0, |b| b.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.send_ticked(number, cx)))),
                        )),
                )
            })
            .into_any_element()
    }

    fn activity_pane(&self, theme: &Theme) -> impl IntoElement {
        let d = &self.data;
        div()
            .flex()
            .flex_col()
            .gap_3()
            .p_3()
            .child(
                Self::section("Claude Code", theme)
                    .child(Self::fact("Model", d.model.clone(), theme))
                    .when_some(d.cost, |el, cost| el.child(Self::fact("Cost", format!("${cost:.2}"), theme)))
                    .child(Self::fact("Context", format!("{}%", (d.context * 100.).round()), theme))
                    .child(Self::fact("Last check", match d.last_check {
                        Some(true) => "Passed",
                        Some(false) => "Failed",
                        None => "None yet",
                    }, theme)),
            )
            .child(Self::section("Activity", theme).map(|el| {
                if d.activity.is_empty() {
                    el.child(div().text_sm().text_color(theme.secondary).child(if d.state.running() {
                        "Claude's activity shows here as it works."
                    } else {
                        "Start the session to see what claude has been doing."
                    }))
                } else {
                    el.children(d.activity.iter().map(|(at, what)| {
                        div().flex().flex_row().gap_3().text_sm().child(div().w(px(44.)).flex_none().text_color(theme.tertiary).child(at.clone())).child(div().flex_1().min_w_0().child(what.clone()))
                    }))
                }
            }))
    }
}

impl Render for WorkPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .when_some(self.data.workflow.clone(), |d, run| d.child(self.workflow_strip(&run, &theme, cx)))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_row()
                    .child(self.terminal_column(&theme, cx))
                    .when(self.panel_open, |d| d.child(self.side_panel(&theme, cx))),
            )
    }
}
