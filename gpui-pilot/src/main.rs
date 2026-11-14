//! Gannin's Actions page on GPUI: a pilot to judge whether the app's
//! charts, tables and feel survive a move off SwiftUI. Read-only: it opens
//! the Swift app's Actions cache and never calls GitHub.
//!
//! cargo run --release -- [--org NAME] [--days 7|30|90]

mod avatars;
mod charts;
mod data;
mod detail;
mod format;
mod issues;
mod markdown;
mod metrics;
mod page;
mod projects;
mod shell;
mod state;

use gpui::{
    actions, point, px, size, App, AppContext, Application, Bounds, KeyBinding, Menu, MenuItem, TitlebarOptions,
    WindowBounds, WindowOptions,
};
use shell::{CloseTab, OpenSwitcher, ToggleDock, ToggleInspector, ToggleSidebar, Workspace};

actions!(pilot, [Quit]);

fn main() {
    let mut org = None;
    let mut days: Option<i64> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--org" => org = args.next(),
            "--days" => days = args.next().and_then(|d| d.parse().ok()),
            _ => eprintln!("Ignoring {arg}; usage: gannin-gpui-pilot [--org NAME] [--days N]"),
        }
    }

    Application::new().run(move |cx: &mut App| {
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.bind_keys(shell::key_bindings());
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.set_menus(vec![
            Menu { name: "Gannin GPUI Pilot".into(), items: vec![MenuItem::action("Quit", Quit)] },
            Menu {
                name: "File".into(),
                items: vec![MenuItem::action("Switch Org", OpenSwitcher), MenuItem::separator(), MenuItem::action("Close Tab", CloseTab)],
            },
            Menu {
                name: "View".into(),
                items: vec![
                    MenuItem::action("Toggle Sidebar", ToggleSidebar),
                    MenuItem::action("Toggle Inspector", ToggleInspector),
                    MenuItem::action("Toggle Claude Code", ToggleDock),
                ],
            },
        ]);

        let bounds = Bounds::centered(None, size(px(1440.), px(940.)), cx);
        cx.open_window(
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
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
    });
}
