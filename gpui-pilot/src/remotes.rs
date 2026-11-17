//! Remotes: the servers sessions can run on and the folders opened on each,
//! in a popover from the title bar, as Zed's Remote Projects. Servers are
//! added as Zed adds one (Connect SSH Server): the ssh command you'd use, a
//! nickname, and a connection made before it's kept. A server's checklist
//! (what a session needs there) is in its Server Options; its header shows
//! only the dot. The hosts in `~/.ssh/config` are offered to start from.

use crate::charts::Theme;
use crate::folders::Location;
use crate::servers::{self, Check, Server, Servers};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, EventEmitter, FocusHandle, Focusable, FontWeight, Hsla, KeyDownEvent, SharedString, Window};
use std::collections::HashSet;

/// What the popover asks its window to do.
pub enum RemotesEvent {
    /// Type a folder's path on this server, in the folder switcher.
    OpenOn(Server),
    /// Open a folder opened before.
    Open(Location),
    Dismiss,
}

impl EventEmitter<RemotesEvent> for Remotes {}

enum Adding {
    Idle,
    Connecting(String),
    Failed(String),
}

enum View {
    List,
    Connect,
    /// A server's options, by its key.
    Options(String),
}

pub struct Remotes {
    focus: FocusHandle,
    saved: Servers,
    view: View,
    /// Servers being checked now, by key.
    checking: HashSet<String>,
    command: Entity<editor::Editor>,
    nickname: Entity<editor::Editor>,
    adding: Adding,
    hosts: Vec<String>,
}

/// A server's dot: blue checking (or never checked), red unreachable,
/// orange missing something a session needs, green ready.
pub fn status(check: Option<&Check>, checking: bool, theme: &Theme) -> (&'static str, Hsla) {
    match check {
        _ if checking => ("Checking", theme.blue()),
        None => ("Not checked", theme.blue()),
        Some(c) if c.error.is_some() => ("Can't connect", theme.critical()),
        Some(c) if c.ready() => ("Ready", theme.good()),
        Some(_) => ("Missing something", theme.orange()),
    }
}

impl Remotes {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let field = |placeholder: &'static str, window: &mut Window, cx: &mut Context<Self>| {
            cx.new(|cx| {
                let mut editor = editor::Editor::single_line(window, cx);
                editor.set_placeholder_text(placeholder, window, cx);
                editor
            })
        };
        let mut remotes = Self {
            focus: cx.focus_handle(),
            saved: servers::load(),
            view: View::List,
            checking: HashSet::new(),
            command: field("ssh me@devbox -p 22", window, cx),
            nickname: field("Nickname (optional)", window, cx),
            adding: Adding::Idle,
            hosts: servers::config_hosts(),
        };
        // A server never checked in this run is checked now; the rest keep
        // their last check until Check Again.
        for server in remotes.saved.servers.clone() {
            if servers::last_check(&server).is_none() {
                remotes.check(server, cx);
            }
        }
        remotes
    }

    pub fn focus_handle(&self) -> FocusHandle {
        self.focus.clone()
    }

    /// Checks a server again, off the main thread.
    fn check(&mut self, server: Server, cx: &mut Context<Self>) {
        let key = server.key();
        if !self.checking.insert(key.clone()) {
            return;
        }
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor().spawn(async move { servers::check(&server) }).await;
            this.update(cx, |this, cx| {
                this.checking.remove(&key);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Connect: reads the command as Zed does, connects, and keeps the
    /// server only when that worked.
    fn connect(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let command = self.command.read(cx).text(cx);
        let nickname = self.nickname.read(cx).text(cx);
        let server = match Server::parse(&command, &nickname) {
            Ok(server) => server,
            Err(error) => {
                self.adding = Adding::Failed(error);
                return cx.notify();
            }
        };
        if self.saved.servers.iter().any(|s| s.key() == server.key()) {
            self.adding = Adding::Failed(format!("{} is already added.", server.key()));
            return cx.notify();
        }
        self.adding = Adding::Connecting(server.key());
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let probe = server.clone();
            let check = cx.background_executor().spawn(async move { servers::check(&probe) }).await;
            this.update_in(cx, |this, window, cx| {
                match &check.error {
                    Some(error) => this.adding = Adding::Failed(format!("Couldn't connect: {error}. Gannin connects without a password, so the server needs an ssh key or agent sign-in.")),
                    None => {
                        this.saved.servers.push(server);
                        servers::save(&this.saved);
                        this.adding = Adding::Idle;
                        this.view = View::List;
                        for field in [this.command.clone(), this.nickname.clone()] {
                            field.update(cx, |e, cx| e.set_text("", window, cx));
                        }
                        window.focus(&this.focus, cx);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn remove(&mut self, key: &str, cx: &mut Context<Self>) {
        if let Some(server) = self.saved.servers.iter().find(|s| s.key() == key) {
            servers::forget_check(server);
        }
        self.saved.servers.retain(|s| s.key() != key);
        servers::save(&self.saved);
        self.view = View::List;
        cx.notify();
    }

    /// Escape steps back from Connect or Server Options, else closes.
    fn key_down(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        if event.keystroke.key != "escape" {
            return;
        }
        cx.stop_propagation();
        match self.view {
            View::List => cx.emit(RemotesEvent::Dismiss),
            _ => self.back(cx),
        }
    }

    fn back(&mut self, cx: &mut Context<Self>) {
        self.view = View::List;
        self.adding = Adding::Idle;
        cx.notify();
    }

    // MARK: Pieces

    /// A row as Zed's list items: an icon, a label, maybe something at the end.
    fn row(id: impl Into<gpui::ElementId>, icon: &'static str, label: impl Into<SharedString>, indent: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .mx_1()
            .px_2()
            .py_1()
            .when(indent, |d| d.pl_6())
            .rounded_md()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .text_sm()
            .cursor_pointer()
            .hover(|s| s.bg(theme.row_selected))
            .child(gpui::svg().path(icon).size(px(14.)).flex_none().text_color(theme.secondary))
            .child(div().flex_1().min_w_0().truncate().child(label.into()))
    }

    fn heading(back: bool, title: String, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .px_3()
            .py_2()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .border_b_1()
            .border_color(theme.border)
            .when(back, |d| {
                d.child(
                    div()
                        .id("remotes-back")
                        .cursor_pointer()
                        .rounded_sm()
                        .hover(|s| s.bg(theme.row_selected))
                        .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.back(cx)))
                        .child(gpui::svg().path("icons/arrow_left.svg").size(px(14.)).text_color(theme.secondary)),
                )
            })
            .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).child(title))
    }

    fn field(editor: &Entity<editor::Editor>, theme: &Theme) -> impl IntoElement {
        div().w_full().px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).text_sm().child(editor.clone())
    }

    fn list(&self, theme: &Theme, cx: &mut Context<Self>) -> Vec<gpui::AnyElement> {
        let recents = crate::folders::recent();
        let mut rows = vec![Self::row("remotes-connect", "icons/plus.svg", "Connect SSH Server", false, theme)
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                this.view = View::Connect;
                window.focus(&this.command.focus_handle(cx), cx);
                cx.notify();
            }))
            .into_any_element()];
        if self.saved.servers.is_empty() {
            rows.push(
                div()
                    .px_3()
                    .py_1()
                    .text_sm()
                    .text_color(theme.secondary)
                    .child("Run Claude Code sessions on another machine over ssh: a folder opened there runs its window's sessions there.")
                    .into_any_element(),
            );
        }
        for (index, server) in self.saved.servers.iter().enumerate() {
            let key = server.key();
            let check = servers::last_check(server);
            let (state, tint) = status(check.as_ref(), self.checking.contains(&key), theme);
            rows.push(div().mx_3().my_1().h(px(1.)).bg(theme.border).into_any_element());
            // The server: its icon with the dot, its name, its address.
            rows.push(
                div()
                    .mx_1()
                    .px_2()
                    .py_1()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .child(
                        div()
                            .relative()
                            .flex_none()
                            .child(gpui::svg().path("icons/server.svg").size(px(14.)).text_color(theme.fg))
                            .child(div().absolute().right(px(-2.)).bottom(px(-1.)).size(px(6.)).rounded_full().border_1().border_color(theme.popover).bg(tint)),
                    )
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(server.name()))
                    .when(tint != theme.good(), |d| d.child(div().text_xs().text_color(tint).child(state)))
                    .child(div().flex_1())
                    .when(server.nickname.is_some(), |d| d.child(div().text_xs().text_color(theme.tertiary).truncate().child(key.clone())))
                    .into_any_element(),
            );
            let on = server.clone();
            rows.push(
                Self::row(("remotes-open", index), "icons/plus.svg", "Open Folder", true, theme)
                    .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(RemotesEvent::OpenOn(on.clone()))))
                    .into_any_element(),
            );
            for (n, recent) in recents.iter().filter(|r| r.location.server.as_ref().is_some_and(|s| s.key() == key)).enumerate() {
                let location = recent.location.clone();
                let forget = location.key();
                rows.push(
                    Self::row(SharedString::from(format!("remotes-folder-{index}-{n}")), "icons/folder.svg", recent.location.path.display().to_string(), true, theme)
                        .group("remote-folder")
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(RemotesEvent::Open(location.clone()))))
                        .child(
                            div()
                                .id(SharedString::from(format!("remotes-forget-{index}-{n}")))
                                .invisible()
                                .group_hover("remote-folder", |s| s.visible())
                                .rounded_sm()
                                .hover(|s| s.bg(theme.border))
                                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| {
                                    cx.stop_propagation();
                                    crate::folders::forget(&forget);
                                    cx.notify();
                                }))
                                .child(gpui::svg().path("icons/trash.svg").size(px(12.)).text_color(theme.secondary)),
                        )
                        .into_any_element(),
                );
            }
            let options = key.clone();
            rows.push(
                Self::row(("remotes-options", index), "icons/settings.svg", "Server Options", true, theme)
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.view = View::Options(options.clone());
                        cx.notify();
                    }))
                    .into_any_element(),
            );
        }
        rows
    }

    fn connect_view(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let saved_hosts: Vec<&String> = self.saved.servers.iter().map(|s| &s.host).collect();
        let picks: Vec<gpui::AnyElement> = self
            .hosts
            .iter()
            .filter(|h| !saved_hosts.contains(h))
            .map(|host| {
                let host = host.clone();
                div()
                    .id(SharedString::from(format!("pick-{host}")))
                    .px_1p5()
                    .rounded_sm()
                    .text_sm()
                    .cursor_pointer()
                    .text_color(theme.secondary)
                    .hover(|s| s.bg(theme.row_selected).text_color(theme.fg))
                    .child(host.clone())
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        let (command, nickname) = (this.command.clone(), this.nickname.clone());
                        command.update(cx, |e, cx| e.set_text(format!("ssh {host}"), window, cx));
                        nickname.update(cx, |e, cx| e.set_text(host.clone(), window, cx));
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        let connecting = matches!(self.adding, Adding::Connecting(_));
        let note = match &self.adding {
            Adding::Idle => None,
            Adding::Connecting(key) => Some((format!("Connecting to {key} and checking what's there"), theme.secondary)),
            Adding::Failed(error) => Some((error.clone(), theme.critical())),
        };
        div()
            .p_3()
            .flex()
            .flex_col()
            .gap_2()
            .child(Self::field(&self.command, theme))
            .child(Self::field(&self.nickname, theme))
            .when(!picks.is_empty(), |d| d.child(div().flex().flex_row().flex_wrap().items_center().gap_1().child(div().text_sm().text_color(theme.tertiary).child("From ~/.ssh/config:")).children(picks)))
            .child(div().text_xs().text_color(theme.secondary).child("It must connect without a password (an ssh key or agent). Nothing is installed there; Server Options says what's missing."))
            .child(
                div().flex().flex_row().items_center().gap_2().child(div().flex_1().min_w_0().when_some(note, |d, (text, tint)| d.text_sm().text_color(tint).child(text))).child(
                    div()
                        .id("remotes-connect-button")
                        .flex_none()
                        .px_2()
                        .py_0p5()
                        .rounded_md()
                        .text_sm()
                        .bg(theme.selected)
                        .text_color(theme.on_selected)
                        .when(connecting, |d| d.opacity(0.4))
                        .when(!connecting, |d| d.cursor_pointer().hover(|s| s.opacity(0.85)).on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.connect(window, cx))))
                        .child(if connecting { "Connecting" } else { "Connect" }),
                ),
            )
    }

    fn options_view(&self, server: &Server, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let key = server.key();
        let checking = self.checking.contains(&key);
        let check = servers::last_check(server);
        let (state, tint) = status(check.as_ref(), checking, theme);
        let items: Vec<gpui::AnyElement> = match check.filter(|_| !checking) {
            Some(c) => match c.error {
                Some(error) => vec![div().text_sm().text_color(theme.critical()).child(error).into_any_element()],
                None => c
                    .items
                    .into_iter()
                    .map(|item| {
                        let (mark, mark_tint) = if item.ok { ("✓", theme.good()) } else if item.needed { ("✕", theme.critical()) } else { ("·", theme.tertiary) };
                        div()
                            .flex()
                            .flex_row()
                            .gap_2()
                            .text_sm()
                            .child(div().flex_none().w(px(12.)).text_color(mark_tint).child(mark))
                            .child(div().flex_none().w(px(110.)).child(item.label))
                            .child(div().flex_1().min_w_0().truncate().text_color(theme.secondary).child(item.detail))
                            .into_any_element()
                    })
                    .collect(),
            },
            None => Vec::new(),
        };
        let (again, copy, remove) = (server.clone(), key.clone(), key.clone());
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .px_3()
                    .py_2()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(div().flex().flex_row().items_center().gap_2().text_sm().child(div().size(px(7.)).rounded_full().bg(tint)).child(div().text_color(tint).child(state)).child(div().flex_1()).child(div().text_xs().text_color(theme.tertiary).child(key.clone())))
                    .children(items),
            )
            .child(
                div()
                    .py_1()
                    .flex()
                    .flex_col()
                    .child(Self::row("remotes-check", "icons/rotate_cw.svg", "Check Again", false, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.check(again.clone(), cx))))
                    .child(Self::row("remotes-copy", "icons/copy.svg", "Copy Server Address", false, theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.write_to_clipboard(gpui::ClipboardItem::new_string(copy.clone())))))
                    .child(
                        Self::row("remotes-remove", "icons/trash.svg", "Remove Server", false, theme)
                            .text_color(theme.critical())
                            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.remove(&remove, cx))),
                    ),
            )
    }
}

impl Render for Remotes {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let panel = div()
            .id("remotes")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .occlude()
            .mt_1()
            .w(px(400.))
            .max_h(px(520.))
            .flex()
            .flex_col()
            .bg(theme.popover)
            .text_color(theme.fg)
            .border_1()
            .border_color(theme.border)
            .rounded_lg()
            .shadow_lg()
            .overflow_hidden();
        match &self.view {
            View::List => {
                let rows = self.list(&theme, cx);
                panel.child(Self::heading(false, "Remote Folders".into(), &theme, cx)).child(div().id("remotes-list").flex_1().min_h_0().overflow_y_scroll().py_1().children(rows))
            }
            View::Connect => panel.child(Self::heading(true, "Connect SSH Server".into(), &theme, cx)).child(self.connect_view(&theme, cx)),
            View::Options(key) => match self.saved.servers.iter().find(|s| &s.key() == key).cloned() {
                Some(server) => panel.child(Self::heading(true, server.name(), &theme, cx)).child(self.options_view(&server, &theme, cx)),
                None => panel.child(Self::heading(true, "Server Options".into(), &theme, cx)),
            },
        }
    }
}
