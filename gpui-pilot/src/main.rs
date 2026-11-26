//! Gannin on GPUI: a pilot to judge whether the app's pages, sessions and
//! feel survive a move off SwiftUI. It reads Gannin's caches, never writes
//! them, and never calls GitHub; its sessions run claude or a shell.
//!
//! cargo run --release -- [--org NAME] [--days 7|30|90]

mod actions;
mod assistant_preview;
mod auth;
mod activity;
mod agent_metrics;
mod avatars;
mod cache;
mod changes;
mod charts;
mod check_detail;
mod data;
mod detail;
mod folders;
mod format;
mod explain;
mod github;
mod harness;
mod harness_doc;
mod harness_git;
mod history;
mod icons;
mod issue_parts;
mod issues;
mod launch;
mod launch_form;
mod links;
mod markdown;
mod markdown_lang;
mod marra;
mod marra_api;
mod marra_mcp;
mod marra_model;
mod marra_view;
mod metrics;
mod new_issue;
mod note_editor;
mod notes;
mod page;
mod planning;
mod planning_agree;
mod planning_docs;
mod planning_panel;
mod planning_preview;
mod planning_security;
mod paths;
mod projects;
#[cfg(target_os = "macos")]
mod promise_drop;
/// File promises are a macOS drag; elsewhere GPUI's own file drops are all.
#[cfg(not(target_os = "macos"))]
mod promise_drop {
    pub fn install() {}
    pub fn set_accepting(_on: bool) {}
    pub fn take() -> Vec<std::path::PathBuf> {
        Vec::new()
    }
}
mod review;
mod review_panel;
mod review_preview;
mod review_record;
mod risk;
mod schedule;
mod schedule_page;
mod schedule_sheet;
mod work_flow;
mod work_live;
mod work_panel;
mod workflows;
mod workflows_page;
mod releases;
mod scorecard;
mod settings_page;
mod pr_diff;
mod pr_picker;
mod prs;
mod pr_deps;
mod pull_page;
mod servers;
mod remotes;
mod session;
mod session_move;
mod shell;
mod shortcuts;
mod stars;
mod state;
mod sync;
mod todo_editor;
mod todos;
mod work;
mod zed;

use gpui::{
    actions, App, AppContext, KeyBinding, Menu, MenuItem,
};
use shell::{CloseTab, NewAsk, NewWindow, Refresh, ToggleSync, ToggleTabsOnLeft, NewClaudeSession, NewPlan, NewQuickChange, NewTerminal, OpenFolder, OpenSwitcher, ToggleHarness, ToggleSidebar, Workspace};

actions!(pilot, [Quit, CloseWindow, Minimize, Zoom, ToggleFullScreen, Hide, HideOthers, ShowAll]);

/// The standard window and app shortcuts. Minimise and Hide are bound on a
/// Mac only: elsewhere the system has its own, and Control-M and Control-H
/// are Return and Backspace in a terminal.
fn window_key_bindings() -> Vec<KeyBinding> {
    let mut bindings = vec![
        KeyBinding::new(zed::keys("secondary-q"), Quit, None),
        KeyBinding::new(zed::keys("secondary-shift-w"), CloseWindow, None),
    ];
    if cfg!(target_os = "macos") {
        bindings.extend([
            KeyBinding::new("cmd-m", Minimize, None),
            KeyBinding::new("ctrl-cmd-f", ToggleFullScreen, None),
            KeyBinding::new("cmd-h", Hide, None),
            KeyBinding::new("alt-cmd-h", HideOthers, None),
        ]);
    } else {
        bindings.push(KeyBinding::new("f11", ToggleFullScreen, None));
    }
    bindings
}

/// The window actions, on whichever window is active (a Gannin window or
/// Marra's). Close Window asks first in a Gannin window with sessions
/// running, as its close button does.
fn handle_window_actions(cx: &mut App) {
    // Deferred: a shortcut's action arrives inside the active window's own
    // update, and that window is lent out until it returns, so updating it
    // now fails without a word.
    fn on_active(cx: &mut App, f: impl FnOnce(&mut gpui::Window, &mut App) + 'static) {
        cx.defer(move |cx| {
            if let Some(handle) = cx.active_window() {
                let _ = handle.update(cx, |_, window, cx| f(window, cx));
            }
        });
    }
    cx.on_action(|_: &CloseWindow, cx| {
        cx.defer(|cx| {
            let Some(handle) = cx.active_window() else { return };
            match handle.downcast::<Workspace>() {
                Some(workspace) => {
                    let _ = workspace.update(cx, |workspace, window, cx| workspace.close_window(window, cx));
                }
                None => {
                    let _ = handle.update(cx, |_, window, _| window.remove_window());
                }
            }
        });
    });
    cx.on_action(|_: &Minimize, cx| on_active(cx, |window, _| window.minimize_window()));
    cx.on_action(|_: &Zoom, cx| on_active(cx, |window, _| window.zoom_window()));
    cx.on_action(|_: &ToggleFullScreen, cx| on_active(cx, |window, _| window.toggle_fullscreen()));
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
}

/// The app menu's items: Hide and friends on a Mac, then Quit.
fn app_menu_items() -> Vec<MenuItem> {
    let mut items = vec![MenuItem::action("Settings", shell::OpenSettings), MenuItem::separator()];
    if cfg!(target_os = "macos") {
        items.extend([MenuItem::action("Hide Gannin", Hide), MenuItem::action("Hide Others", HideOthers), MenuItem::action("Show All", ShowAll), MenuItem::separator()]);
    }
    items.push(MenuItem::action("Quit", Quit));
    items
}

fn window_menu() -> Menu {
    Menu {
        name: "Window".into(),
        items: vec![
            MenuItem::action("Minimize", Minimize),
            MenuItem::action("Zoom", Zoom),
            MenuItem::action("Toggle Full Screen", ToggleFullScreen),
            MenuItem::separator(),
            MenuItem::action("Close Window", CloseWindow),
        ],
        disabled: false,
    }
}

fn main() {
    // Launched from inside a Claude Code session (a relaunch from one of
    // our own), Gannin inherits its markers, and every session it starts
    // would too: Claude Code then takes each for a child session and saves
    // no transcript, so nothing resumes after the next relaunch. Clear them
    // before any thread or child process exists.
    for (key, _) in std::env::vars_os() {
        let Some(key) = key.to_str().map(str::to_string) else { continue };
        if key == "CLAUDECODE" || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" || key.starts_with("CLAUDE_CODE_") {
            std::env::remove_var(&key);
        }
    }
    let mut org = None;
    let mut days: Option<i64> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            // The assistant's mock-up alone, in its own window and process:
            // no workspace, no saved state, nothing a running Gannin uses.
            "--assistant-preview" => {
                gpui_platform::application().with_assets(icons::Assets).run(|cx: &mut App| {
                    zed::init(cx);
                    cx.bind_keys(window_key_bindings());
                    cx.on_action(|_: &Quit, cx| cx.quit());
                    handle_window_actions(cx);
                    cx.set_menus(vec![Menu { name: "Marra".into(), items: app_menu_items(), disabled: false }, window_menu()]);
                    let options = gpui::WindowOptions {
                        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(None, gpui::size(gpui::px(460.), gpui::px(860.)), cx))),
                        titlebar: Some(gpui::TitlebarOptions { title: Some("Marra".into()), appears_transparent: true, traffic_light_position: Some(gpui::point(gpui::px(14.), gpui::px(13.))) }),
                        app_id: Some(crate::shell::APP_ID.into()),
                        ..Default::default()
                    };
                    cx.open_window(options, |window, cx| cx.new(|cx| assistant_preview::AssistantPreview::new(window, cx))).expect("open the preview");
                    cx.activate(true);
                });
                return;
            }
            // Planning with a made-up plan, in its own window and process:
            // no Claude Code, no GitHub, nothing a running Gannin uses.
            "--planning-preview" => {
                gpui_platform::application().with_assets(icons::Assets).run(|cx: &mut App| {
                    zed::init(cx);
                    cx.bind_keys(window_key_bindings());
                    cx.on_action(|_: &Quit, cx| cx.quit());
                    handle_window_actions(cx);
                    cx.set_menus(vec![Menu { name: "Planning Preview".into(), items: app_menu_items(), disabled: false }, window_menu()]);
                    let options = gpui::WindowOptions {
                        window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(None, gpui::size(gpui::px(760.), gpui::px(900.)), cx))),
                        titlebar: Some(gpui::TitlebarOptions { title: Some("Planning Preview".into()), appears_transparent: false, traffic_light_position: None }),
                        app_id: Some(crate::shell::APP_ID.into()),
                        ..Default::default()
                    };
                    cx.open_window(options, |window, cx| cx.new(|cx| planning_panel::PlanningPanel::preview(window, cx))).expect("open the preview");
                    cx.on_window_closed(|cx, _| cx.quit()).detach();
                    cx.activate(true);
                });
                return;
            }
            // Marra's engine and Gannin's MCP server against a real claude,
            // without a window: `--marra-check [model] [prompt]`. Tool calls
            // get canned answers; permission requests are allowed.
            // The phone API on this Mac: pairs, calls, and is refused without
            // a token, then puts the paired devices back as they were.
            "--marra-api-check" => {
                marra_api_check();
                return;
            }
            "--marra-check" => {
                marra_check(args.next(), args.next());
                return;
            }
            "--beside" => state::set_beside(),
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
            // What a window would make of a folder: its org and harnesses.
            "--open-folder" => {
                let location = folders::Location::here(std::path::PathBuf::from(args.next().unwrap_or_default()));
                match folders::inspect(&location) {
                    Ok(opened) => {
                        let org = opened.org(&data::orgs());
                        println!("{} org {:?}, empty {}", opened.location.place(), org, opened.empty);
                        for h in &opened.harnesses {
                            println!("  harness {} {:?} name {:?}, {} repos", h.path.display(), h.repo, h.name, h.repos.len());
                        }
                        println!("  {} other repos", opened.repos.len());
                    }
                    Err(error) => println!("{error}"),
                }
                return;
            }
            // Sets up the starter harness in a folder: `--set-up-harness <dir> <org>`.
            "--set-up-harness" => {
                let location = folders::Location::here(std::path::PathBuf::from(args.next().unwrap_or_default()));
                let org = args.next().unwrap_or_default();
                match folders::inspect(&location).and_then(|opened| folders::set_up_harness(&opened, &org)) {
                    Ok(path) => println!("set up {}", path.display()),
                    Err(error) => println!("{error}"),
                }
                return;
            }
            // Moves what's in Application Support to the harness and
            // ~/.gannin, as the window does on opening.
            "--migrate" => {
                paths::migrate();
                return;
            }
            // What the org's harnesses hold, read with git: projects,
            // documents by kind and review records.
            "--harness" => {
                let org = args.next().unwrap_or_default();
                for snapshot in harness_git::snapshots(&org) {
                    let reviews = snapshot.under(".gannin/reviews/").count();
                    println!("{} at {} on {}: {} files, {} review records", snapshot.repo, &snapshot.commit[..8.min(snapshot.commit.len())], snapshot.branch, snapshot.files.len(), reviews);
                }
                for project in projects::load(&org).projects {
                    println!("project {} ({}), {} repos", project.name, project.id, project.repos.len());
                }
                let docs = harness::load(&org);
                let counts = harness::counts(&docs);
                for kind in harness::HarnessKind::ALL {
                    println!("{}: {} ({} standard)", kind.title(), counts.get(&kind).copied().unwrap_or(0), docs.iter().filter(|d| d.kind == kind && d.standard).count());
                }
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
                let (results, clear) = work_flow::local_round(&worktree, &workflow, &[], 1, &[], None);
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
                let r = schedule::scout(&harness, &issue, None);
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
                match work::load_live(&token) {
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

    paths::migrate();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx: &mut App| {
        zed::init(cx);
        cx.bind_keys(window_key_bindings());
        cx.bind_keys(shell::key_bindings());
        handle_window_actions(cx);
        // Marra: ⌘J while Gannin is active brings it forward.
        cx.bind_keys([KeyBinding::new(crate::zed::keys("secondary-j"), marra_view::ToggleMarra, None)]);
        // Deferred: the action arrives inside the active window's update, and
        // that window (Marra's own, or the one it docks in) is lent out until then.
        cx.on_action(|_: &marra_view::ToggleMarra, cx| cx.defer(marra_view::toggle));
        cx.set_menus(vec![
            Menu { name: "Gannin".into(), items: app_menu_items(), disabled: false },
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
                    MenuItem::action("Open Folder", OpenFolder),
                    MenuItem::action("Open Recent", OpenSwitcher),
                    MenuItem::separator(),
                    MenuItem::action("Close Tab", CloseTab),
                ],
                disabled: false,
            },
            Menu {
                name: "View".into(),
                items: vec![
                    MenuItem::action("Toggle Sidebar", ToggleSidebar),
                    MenuItem::action("Toggle Harness", ToggleHarness),
                    MenuItem::action("Toggle Tabs on Left", ToggleTabsOnLeft),
                    MenuItem::action("Toggle Sync", ToggleSync),
                    MenuItem::separator(),
                    MenuItem::action("Marra", marra_view::ToggleMarra),
                    MenuItem::separator(),
                    MenuItem::action("Refresh", Refresh),
                ],
                disabled: false,
            },
            window_menu(),
        ]);

        // The first window, when it was open at quit or nothing else was:
        // closed, it stays closed while other windows come back.
        let first = state::beside() || state::has_slot(0) || state::extra_slots().is_empty();
        // Where it was left, unless the command line says otherwise.
        let first_saved = state::SavedState::load();
        let workspace = first.then(|| cx.open_window(
            shell::window_options_for(first_saved.window, cx),
            |window, cx| {
                let mut saved = first_saved;
                if org.is_some() {
                    saved.org = org;
                }
                if let Some(days) = days {
                    saved.ci.days = days;
                }
                cx.new(|cx| Workspace::new(saved, 0, window, cx))
            },
        )
        .expect("open the window"));
        // The other windows that were open come back too; not in a test
        // copy, which is one window.
        if !state::beside() {
            Workspace::reopen_windows(cx);
            // Marra watches from the start, so what needs you notifies before
            // its window is first opened; claude itself waits for a message.
            marra_model::Marra::get(cx);
        }
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

/// See `--marra-check`.
fn marra_check(model: Option<String>, prompt: Option<String>) {
    let Some((port, token, calls)) = marra_mcp::serve() else { return println!("couldn't listen") };
    let folder = std::env::temp_dir().join("gannin-marra-check");
    let profile = marra::Profile { cwd: folder, system: marra::system_prompt(), session: None, model, extra: Vec::new(), server: None };
    let mut engine = marra::Engine::new(profile);
    engine.mcp = Some((port, token));
    let prompt = prompt.unwrap_or_else(|| "Use the gannin list_sessions tool, then tell me in one sentence what it said.".into());
    if let Err(e) = engine.send(&prompt) {
        return println!("send failed: {e}");
    }
    let started = std::time::Instant::now();
    while started.elapsed() < std::time::Duration::from_secs(180) {
        for call in calls.try_iter() {
            println!("TOOL CALL {} {}", call.tool, call.args);
            let _ = call.reply.send(Ok("- id 1:1: \"Review acme/api#12\" (review), needs you since 10:02, review ready to post (approve, 2 findings)".into()));
        }
        for event in engine.drain() {
            match &event {
                marra::Event::Delta(_) => {}
                marra::Event::Ask { request, tool, input } => {
                    println!("ASK {tool} {input}");
                    let _ = engine.answer(request, true, input);
                }
                marra::Event::Done { .. } | marra::Event::Exited(_) => {
                    println!("{event:?}");
                    engine.stop();
                    if let Some(id) = &engine.profile.session {
                        let _ = std::fs::remove_file(marra::dir().join(format!("mcp-{id}.json")));
                    }
                    return;
                }
                other => println!("{other:?}"),
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    println!("timed out");
}

/// See `--marra-api-check`.
fn marra_api_check() {
    let before = std::fs::read(marra::dir().join("devices.json")).ok();
    let mut api = match marra_api::Api::start() {
        Ok(api) => api,
        Err(e) => return println!("{e}"),
    };
    let code = api.new_code();
    let calls = std::mem::replace(&mut api.calls, std::sync::mpsc::channel().1);
    std::thread::spawn(move || {
        for call in calls.iter() {
            let _ = call.reply.send((200, serde_json::json!({ "echo": format!("{} {}", call.method, call.path) })));
        }
    });
    let curl = |args: &[&str]| -> String {
        let out = std::process::Command::new("/usr/bin/curl").args(["-s", "-w", " %{http_code}"]).args(args).output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
        out
    };
    let base = format!("http://127.0.0.1:{}/v1", marra_api::PORT);
    println!("no token: {}", curl(&[&format!("{base}/needs")]));
    println!("wrong code: {}", curl(&["-X", "POST", "-d", "{\"code\":\"000000x\"}", &format!("{base}/pair")]));
    let paired = curl(&["-X", "POST", "-d", &format!("{{\"code\":\"{code}\",\"name\":\"check\"}}"), &format!("{base}/pair")]);
    println!("pair: {paired}");
    let token = serde_json::from_str::<serde_json::Value>(paired.rsplit_once(' ').map(|(b, _)| b).unwrap_or_default()).ok().and_then(|v| v["token"].as_str().map(str::to_string)).unwrap_or_default();
    let auth = format!("Authorization: Bearer {token}");
    println!("needs: {}", curl(&["-H", &auth, &format!("{base}/needs")]));
    println!("code reused: {}", curl(&["-X", "POST", "-d", &format!("{{\"code\":\"{code}\"}}"), &format!("{base}/pair")]));
    println!("events: {}", curl(&["-m", "1", "-H", &auth, &format!("{base}/events")]));
    match before {
        Some(bytes) => {
            let _ = std::fs::write(marra::dir().join("devices.json"), bytes);
        }
        None => {
            let _ = std::fs::remove_file(marra::dir().join("devices.json"));
        }
    }
}

