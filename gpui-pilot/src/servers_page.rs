//! Settings: for now, the servers sessions can run on, added as Zed adds a
//! remote (Connect New Server): the ssh command you'd use, a nickname, and
//! a connection made before it's kept. Each server shows what a session
//! needs there; the hosts in `~/.ssh/config` are offered to start from.

use crate::charts::Theme;
use crate::servers::{self, Check, Server, Servers};
use gpui::{div, prelude::*, px, ClickEvent, Context, Entity, FontWeight, SharedString, Window};
use std::collections::HashMap;

enum Adding {
    Idle,
    Connecting(String),
    Failed(String),
}

pub struct ServersPage {
    saved: Servers,
    /// By server key: its last check, or None while it's checking.
    checks: HashMap<String, Option<Check>>,
    command: Entity<editor::Editor>,
    nickname: Entity<editor::Editor>,
    adding: Adding,
    hosts: Vec<String>,
}

impl ServersPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let field = |placeholder: &'static str, window: &mut Window, cx: &mut Context<Self>| {
            cx.new(|cx| {
                let mut editor = editor::Editor::single_line(window, cx);
                editor.set_placeholder_text(placeholder, window, cx);
                editor
            })
        };
        let mut page = Self {
            saved: servers::load(),
            checks: HashMap::new(),
            command: field("ssh me@devbox -p 22", window, cx),
            nickname: field("Nickname (optional)", window, cx),
            adding: Adding::Idle,
            hosts: servers::config_hosts(),
        };
        for server in page.saved.servers.clone() {
            page.check(server, cx);
        }
        page
    }

    /// Checks a saved server again, off the main thread.
    fn check(&mut self, server: Server, cx: &mut Context<Self>) {
        let key = server.key();
        self.checks.insert(key.clone(), None);
        cx.notify();
        cx.spawn(async move |this, cx| {
            let check = cx.background_executor().spawn(async move { servers::check(&server) }).await;
            this.update(cx, |this, cx| {
                this.checks.insert(key, Some(check));
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
                    Some(error) => this.adding = Adding::Failed(format!("Couldn't connect: {error}. The pilot connects without a password, so the server needs an ssh key or agent sign-in.")),
                    None => {
                        this.checks.insert(server.key(), Some(check));
                        this.saved.servers.push(server);
                        servers::save(&this.saved);
                        this.adding = Adding::Idle;
                        for field in [this.command.clone(), this.nickname.clone()] {
                            field.update(cx, |e, cx| e.set_text("", window, cx));
                        }
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn remove(&mut self, key: &str, cx: &mut Context<Self>) {
        self.saved.servers.retain(|s| s.key() != key);
        if self.saved.run_on.as_deref() == Some(key) {
            self.saved.run_on = None;
        }
        self.checks.remove(key);
        servers::save(&self.saved);
        cx.notify();
    }

    fn run_on(&mut self, key: Option<String>, cx: &mut Context<Self>) {
        self.saved.run_on = key;
        servers::save(&self.saved);
        cx.notify();
    }

    fn button(id: impl Into<SharedString>, label: &str, prominent: bool, enabled: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
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
            .child(label.to_string())
    }

    fn chip(id: impl Into<SharedString>, label: String, on: bool, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div()
            .id(gpui::ElementId::Name(id.into()))
            .px_2()
            .py_0p5()
            .rounded_md()
            .text_sm()
            .cursor_pointer()
            .text_color(if on { theme.fg } else { theme.secondary })
            .when(on, |d| d.bg(theme.row_selected))
            .hover(|s| s.bg(theme.row_selected))
            .child(label)
    }

    fn field(editor: &Entity<editor::Editor>, width: f32, theme: &Theme) -> impl IntoElement {
        div().w(px(width)).px_2().py_1().rounded_md().border_1().border_color(theme.border).bg(theme.bg).text_sm().child(editor.clone())
    }

    /// A server: its name, its checklist, and Check Again and Remove.
    fn server_row(&self, server: &Server, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let key = server.key();
        let check = self.checks.get(&key).cloned();
        let (status, tint) = match &check {
            None | Some(None) => ("Checking".to_string(), theme.secondary),
            Some(Some(c)) if c.error.is_some() => ("Can't connect".to_string(), theme.critical()),
            Some(Some(c)) if c.ready() => ("Ready".to_string(), theme.good()),
            Some(Some(_)) => ("Missing something".to_string(), theme.orange()),
        };
        let items: Vec<gpui::AnyElement> = match check.flatten() {
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
                            .child(div().flex_none().w(px(120.)).child(item.label))
                            .child(div().flex_1().min_w_0().text_color(theme.secondary).child(item.detail))
                            .into_any_element()
                    })
                    .collect(),
            },
            None => Vec::new(),
        };
        let (again, remove) = (server.clone(), key.clone());
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .child(div().size(px(8.)).rounded_full().bg(tint))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(server.name()))
                    .when(server.nickname.is_some(), |d| d.child(div().text_sm().text_color(theme.secondary).child(key.clone())))
                    .child(div().text_sm().text_color(tint).child(status))
                    .child(div().flex_1())
                    .child(Self::button(format!("check-{key}"), "Check Again", false, true, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.check(again.clone(), cx))))
                    .child(Self::button(format!("remove-{key}"), "Remove", false, true, theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.remove(&remove, cx)))),
            )
            .children(items)
    }
}

impl Render for ServersPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let quiet = |text: &str| div().text_sm().text_color(theme.secondary).child(text.to_string());
        let run_on = self.saved.run_on.clone();
        let mut places = vec![Self::chip("run-on-here", "This Mac".into(), run_on.is_none(), &theme).on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.run_on(None, cx))).into_any_element()];
        for server in &self.saved.servers {
            let key = server.key();
            let on = run_on.as_deref() == Some(key.as_str());
            places.push(Self::chip(format!("run-on-{key}"), server.name(), on, &theme).on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.run_on(Some(key.clone()), cx))).into_any_element());
        }
        let rows: Vec<gpui::AnyElement> = self.saved.servers.clone().iter().map(|s| self.server_row(s, &theme, cx).into_any_element()).collect();
        let saved_hosts: Vec<String> = self.saved.servers.iter().map(|s| s.host.clone()).collect();
        let picks: Vec<gpui::AnyElement> = self
            .hosts
            .iter()
            .filter(|h| !saved_hosts.contains(h))
            .map(|host| {
                let host = host.clone();
                Self::chip(format!("pick-{host}"), host.clone(), false, &theme)
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
            .id("settings")
            .size_full()
            .overflow_y_scroll()
            .bg(theme.bg)
            .text_color(theme.fg)
            .child(
                div()
                    .max_w(px(760.))
                    .p_6()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child("Servers"))
                    .child(quiet("Run Claude Code sessions on another machine over ssh. The session's terminal and panels stay here; claude, git and the harness run there. A session keeps the server it started on."))
                    .child(div().flex().flex_col().gap_1().child(div().text_sm().font_weight(FontWeight::MEDIUM).child("Run new sessions on")).child(div().flex().flex_row().flex_wrap().gap_1().children(places)))
                    .children(rows)
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .p_3()
                            .rounded_lg()
                            .bg(theme.tile)
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("Connect New Server"))
                            .child(quiet("The ssh command you'd use to reach it. It must connect without a password (an ssh key or agent). Nothing is installed there: git, Claude Code and gh are yours to set up, and it says what's missing."))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap_2()
                                    .child(Self::field(&self.command, 300., &theme))
                                    .child(Self::field(&self.nickname, 180., &theme))
                                    .child(Self::button("connect", if connecting { "Connecting" } else { "Connect" }, true, !connecting, &theme).when(!connecting, |d| d.on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.connect(window, cx))))),
                            )
                            .when(!picks.is_empty(), |d| d.child(div().flex().flex_row().flex_wrap().items_center().gap_1().child(div().text_sm().text_color(theme.secondary).child("From your ssh config:")).children(picks)))
                            .when_some(note, |d, (text, tint)| d.child(div().text_sm().text_color(tint).child(text))),
                    ),
            )
    }
}
