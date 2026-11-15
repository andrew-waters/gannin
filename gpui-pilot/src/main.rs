//! Gannin on GPUI: a pilot to judge whether the app's pages, sessions and
//! feel survive a move off SwiftUI. It reads Gannin's caches, never writes
//! them, and never calls GitHub; its sessions run claude or a shell.
//!
//! cargo run --release -- [--org NAME] [--days 7|30|90]

mod auth;
mod activity;
mod avatars;
mod cache;
mod changes;
mod charts;
mod data;
mod detail;
mod format;
mod explain;
mod github;
mod harness;
mod history;
mod issues;
mod launch;
mod launch_form;
mod markdown;
mod metrics;
mod new_issue;
mod page;
mod planning_panel;
mod projects;
mod review;
mod review_panel;
mod review_preview;
mod review_record;
mod schedule;
mod schedule_page;
mod schedule_sheet;
mod work_flow;
mod work_live;
mod work_panel;
mod workflows;
mod workflows_page;
mod scorecard;
mod pr_picker;
mod prs;
mod session;
mod shell;
mod state;
mod sync;
mod work;
mod zed;

use gpui::{
    actions, App, AppContext, KeyBinding, Menu, MenuItem,
};
use shell::{CloseTab, NewAsk, NewWindow, Refresh, ToggleSync, NewClaudeSession, NewPlan, NewQuickChange, NewTerminal, OpenSwitcher, ToggleInspector, ToggleSidebar, Workspace};

actions!(pilot, [Quit]);

fn main() {
    let mut org = None;
    let mut days: Option<i64> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--org" => org = args.next(),
            "--days" => days = args.next().and_then(|d| d.parse().ok()),
            // Writes a Work on This launch against the harness folder given
            // and prints its start script's path: for checking the launch
            // with a stand-in claude, without starting Claude Code.
            "--dry-launch" => {
                let harness = std::path::PathBuf::from(args.next().unwrap_or_default());
                let subject = launch::Subject { id: "I_dry".into(), repo: "acme/api".into(), number: 12, title: "Fix the thing's \"edge\"".into(), url: "https://github.com/acme/api/issues/12".into() };
                let branch = launch::issue_branch(12, &subject.title);
                let mut dry = launch::Launch::new(launch::Flow::Work, "#12 Fix the thing".into(), "acme", "acme/harness", branch.clone(), Some(subject));
                dry.harness_path = harness;
                let prompt = launch::opening_prompt("acme/api#12", "Fix the thing's \"edge\"", &branch);
                let brief = format!("# acme/api#12: Fix\n\n{}", launch::working_here("acme/harness", &dry.harness_path, &branch, Some("acme/api#12"), "acme/api", false));
                dry.prepare(&brief, &prompt, false, false).expect("prepare");
                println!("{}", dry.dir().join("start.sh").display());
                return;
            }
            // Reads a review session's result from claude's transcript.
            "--review-result" => {
                let id = args.next().unwrap_or_default();
                match review::read_result(&id) {
                    Some(result) => println!(
                        "verdict {:?}, effort {:?}, {} findings, {} areas; headline {:?}",
                        result.verdict,
                        result.effort,
                        result.findings.len(),
                        result.walkthrough.len(),
                        result.headline
                    ),
                    None => println!("no result"),
                }
                return;
            }
            // Counts the work log's events for the last two weeks.
            // Lists the worktrees in a Work on This session's folder and
            // what's changed in each, as its panel reads them.
            // Runs a workflow's local review round on a worktree, as a held
            // push would: `--local-round <worktree> <workflow.json>`.
            "--local-round" => {
                let worktree = std::path::PathBuf::from(args.next().unwrap_or_default());
                let workflow: workflows::Workflow = serde_json::from_slice(&std::fs::read(args.next().unwrap_or_default()).expect("the workflow file")).expect("a workflow");
                let (results, clear) = work_flow::local_round(&worktree, &workflow, &[], 1, &[]);
                for r in &results {
                    println!("{} [{}] {}: {}", r.label, r.provider, r.status, r.summary.lines().next().unwrap_or(""));
                    for f in &r.findings {
                        println!("  - [{}] {}:{} {}", f.severity, f.path, f.line.unwrap_or(0), f.comment);
                    }
                }
                println!("\nclear: {clear}\n\n{}", work_flow::round_message(1, "0123456789abcdef", &results, clear));
                return;
            }
            // Reads a saved layout file and says which tabs it would open.
            "--state-check" => {
                let path = args.next().unwrap_or_default();
                let bytes = std::fs::read(&path).expect("the file");
                match serde_json::from_slice::<state::SavedState>(&bytes) {
                    Ok(state) => println!("views: {:?}", state.views.iter().map(|v| (format!("{:?}", v.nav), v.name.clone())).collect::<Vec<_>>()),
                    Err(e) => println!("unreadable: {e}"),
                }
                return;
            }
            // Lists an issue's open sub-issues in GitHub's order (read only).
            "--sub-issues" => {
                let token = auth::token().expect("sign in first");
                match schedule::sub_issues_in_order(&token, &args.next().unwrap_or_default()) {
                    Ok(subs) => subs.iter().for_each(|s| println!("{}#{} {}", s.repo, s.number, s.title)),
                    Err(e) => println!("couldn't: {e}"),
                }
                return;
            }
            // Scouts an issue as scheduling does: `--scout <harness> <owner/repo> <number>`.
            "--scout" => {
                let harness = std::path::PathBuf::from(args.next().unwrap_or_default());
                let repo = args.next().unwrap_or_default();
                let number: i64 = args.next().and_then(|n| n.parse().ok()).unwrap_or(0);
                let issue = schedule::IssueRef { id: String::new(), url: format!("https://github.com/{repo}/issues/{number}"), repo, number, title: String::new() };
                let r = schedule::scout(&harness, &issue);
                println!("state: {} {}", r.state, r.error.unwrap_or_default());
                println!("notes: {}", r.notes.lines().take(6).collect::<Vec<_>>().join("\n       "));
                for d in &r.decisions {
                    println!("decision: {} [{}] recommended {:?}", d.question, d.options.iter().map(|o| o.0.clone()).collect::<Vec<_>>().join(" | "), d.recommended);
                }
                for b in &r.blockers {
                    println!("blocker: {b}");
                }
                return;
            }
            "--work-changes" => {
                let folder = std::path::PathBuf::from(args.next().unwrap_or_default());
                for w in work_live::worktrees(&folder) {
                    println!("{} (base {}, unpushed {:?}): {} on the branch, {} uncommitted", w.name, w.base, w.unpushed, w.files.len(), w.uncommitted.len());
                    for f in w.files.iter().take(8) {
                        println!("  {} {} +{} -{}", f.status, f.path, f.additions, f.deletions);
                    }
                    if let Some(f) = w.files.first() {
                        let diff = work_live::diff(std::path::Path::new(&w.path), &f.path, false);
                        println!("  diff of {}: {} lines, first {:?}", f.path, diff.len(), diff.first());
                    }
                }
                return;
            }
            "--activity" => {
                activity::print_summary(&args.next().unwrap_or_default());
                return;
            }
            // Prints the scorecard metrics for recent weeks.
            "--scorecard" => {
                scorecard::print_weeks(&args.next().unwrap_or_default(), 6);
                return;
            }
            // Runs Your Work's live query and lists what it found.
            "--work" => {
                let token = auth::token().expect("sign in first");
                let viewer = auth::saved_viewer().map(|v| v.login);
                match work::load_live(&token, viewer) {
                    Ok(work) => {
                        for pr in &work.reviews {
                            println!("review: {}#{} {}", pr.repo, pr.number, pr.title);
                        }
                        for pr in &work.mine {
                            println!("mine: {}#{} {} [{}]", pr.repo, pr.number, pr.title, pr.standing());
                        }
                        for issue in work.issues.iter().flatten() {
                            println!("issue: {}#{} {}", issue.repo, issue.number, issue.title);
                        }
                    }
                    Err(error) => println!("failed: {error}"),
                }
                return;
            }
            // Syncs one org into the pilot's caches without a window, and
            // reports what it fetched: for trying the sync from a shell.
            "--sync" => {
                let org = args.next().unwrap_or_default();
                let token = auth::token().expect("sign in first");
                let viewer = auth::saved_viewer().map(|v| v.login);
                let started = std::time::Instant::now();
                match sync::sync_org(&token, &org, viewer.as_deref(), false, Default::default(), &Default::default()) {
                    Ok(report) => println!("{org}: {report:?} in {:?}; budget {:?}", started.elapsed(), github::rate_limit()),
                    Err(error) => println!("{org}: failed: {error}"),
                }
                return;
            }
            _ => eprintln!("Ignoring {arg}; usage: gannin-gpui-pilot [--org NAME] [--days N]"),
        }
    }

    gpui_platform::application().with_assets(assets::Assets).run(move |cx: &mut App| {
        zed::init(cx);
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.bind_keys(shell::key_bindings());
        cx.set_menus(vec![
            Menu { name: "Gannin".into(), items: vec![MenuItem::action("Quit", Quit)], disabled: false },
            Menu {
                name: "File".into(),
                items: vec![
                    MenuItem::action("New Claude Code Session", NewClaudeSession),
                    MenuItem::action("New Terminal", NewTerminal),
                    MenuItem::action("New Ask", NewAsk),
                    MenuItem::action("New Quick Change", NewQuickChange),
                    MenuItem::action("New Plan", NewPlan),
                    MenuItem::separator(),
                    MenuItem::action("New Window", NewWindow),
                    MenuItem::separator(),
                    MenuItem::action("Switch Org", OpenSwitcher),
                    MenuItem::separator(),
                    MenuItem::action("Close Tab", CloseTab),
                ],
                disabled: false,
            },
            Menu {
                name: "View".into(),
                items: vec![
                    MenuItem::action("Toggle Sidebar", ToggleSidebar),
                    MenuItem::action("Toggle Your Work", ToggleInspector),
                    MenuItem::action("Toggle Sync", ToggleSync),
                    MenuItem::separator(),
                    MenuItem::action("Refresh", Refresh),
                ],
                disabled: false,
            },
        ]);

        let workspace = cx.open_window(
            shell::window_options(cx),
            |window, cx| {
                // Where it was left, unless the command line says otherwise.
                let mut saved = state::SavedState::load();
                if org.is_some() {
                    saved.org = org;
                }
                if let Some(days) = days {
                    saved.ci.days = days;
                }
                cx.new(|cx| Workspace::new(saved, 0, window, cx))
            },
        )
        .expect("open the window");
        // The other windows that were open come back too.
        Workspace::reopen_windows(cx);
        let _ = workspace;
        // Quit asks first while sessions run, in any window.
        cx.on_action(move |_: &Quit, cx| {
            let window = cx.active_window().and_then(|w| w.downcast::<Workspace>()).or_else(|| cx.windows().into_iter().find_map(|w| w.downcast::<Workspace>()));
            match window {
                Some(window) => {
                    if window.update(cx, |workspace, window, cx| workspace.quit(window, cx)).is_err() {
                        cx.quit();
                    }
                }
                None => cx.quit(),
            }
        });
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
    });
}
