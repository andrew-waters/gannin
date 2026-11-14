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
mod page;
mod planning_panel;
mod projects;
mod review;
mod review_panel;
mod review_preview;
mod review_record;
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
    actions, point, px, size, App, AppContext, Bounds, KeyBinding, Menu, MenuItem, TitlebarOptions,
    WindowBounds, WindowOptions,
};
use shell::{CloseTab, NewAsk, Refresh, ToggleSync, NewClaudeSession, NewPlan, NewQuickChange, NewTerminal, OpenSwitcher, ToggleInspector, ToggleSidebar, Workspace};

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
                dry.prepare(&brief, &prompt, false).expect("prepare");
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
                let token = auth::token().expect("sign in to the pilot first");
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
                let token = auth::token().expect("sign in to the pilot first");
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
            Menu { name: "Gannin GPUI Pilot".into(), items: vec![MenuItem::action("Quit", Quit)], disabled: false },
            Menu {
                name: "File".into(),
                items: vec![
                    MenuItem::action("New Claude Code Session", NewClaudeSession),
                    MenuItem::action("New Terminal", NewTerminal),
                    MenuItem::action("New Ask", NewAsk),
                    MenuItem::action("New Quick Change", NewQuickChange),
                    MenuItem::action("New Plan", NewPlan),
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

        let bounds = Bounds::centered(None, size(px(1440.), px(940.)), cx);
        let workspace = cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                // The app draws its own title bar, with the traffic lights over it.
                titlebar: Some(TitlebarOptions {
                    title: Some("Gannin".into()),
                    appears_transparent: true,
                    traffic_light_position: Some(point(px(14.), px(12.))),
                }),
                ..Default::default()
            },
            |window, cx| {
                // Where it was left, unless the command line says otherwise.
                let mut saved = state::SavedState::load();
                if org.is_some() {
                    saved.org = org;
                }
                if let Some(days) = days {
                    saved.ci.days = days;
                }
                cx.new(|cx| Workspace::new(saved, window, cx))
            },
        )
        .expect("open the window");
        // Quit asks first while sessions run.
        cx.on_action(move |_: &Quit, cx| {
            if workspace.update(cx, |workspace, window, cx| workspace.quit(window, cx)).is_err() {
                cx.quit();
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
