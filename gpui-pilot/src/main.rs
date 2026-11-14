//! Gannin on GPUI: a pilot to judge whether the app's pages, sessions and
//! feel survive a move off SwiftUI. It reads Gannin's caches, never writes
//! them, and never calls GitHub; its sessions run claude or a shell.
//!
//! cargo run --release -- [--org NAME] [--days 7|30|90]

mod auth;
mod avatars;
mod cache;
mod changes;
mod charts;
mod data;
mod detail;
mod format;
mod github;
mod issues;
mod markdown;
mod metrics;
mod page;
mod projects;
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
use shell::{CloseTab, NewClaudeSession, NewTerminal, OpenSwitcher, ToggleInspector, ToggleSidebar, Workspace};

actions!(pilot, [Quit]);

fn main() {
    let mut org = None;
    let mut days: Option<i64> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--org" => org = args.next(),
            "--days" => days = args.next().and_then(|d| d.parse().ok()),
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
                match sync::sync_org(&token, &org, viewer.as_deref()) {
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
