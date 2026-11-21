//! Markdown for issue descriptions and comments, as `MarkdownText` draws it
//! in the Swift app. GPUI has no renderer of its own (Zed's is GPL), so this
//! walks pulldown-cmark's events into blocks: paragraphs, headings, lists,
//! quotes, code, rules and tables as a grid. Bold, italic, inline code
//! and links are styled runs; links open in the browser. Images show as a
//! link to the image, since there's no HTTP client to load them.

use crate::charts::Theme;
use gpui::{
    div, prelude::*, px, AnyElement, FontStyle, FontWeight, HighlightStyle, InteractiveText, SharedString, StyledText,
    UnderlineStyle,
};
use pulldown_cmark::{Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use std::ops::Range;

/// The text of one block, with its styled runs and links.
#[derive(Default)]
struct Inline {
    text: String,
    highlights: Vec<(Range<usize>, HighlightStyle)>,
    links: Vec<(Range<usize>, String)>,
}

#[derive(Clone, Copy)]
enum BlockKind {
    Paragraph,
    Heading(HeadingLevel),
    Item,
    TableRow,
}

struct Renderer<'a> {
    id: String,
    theme: &'a Theme,
    blocks: Vec<AnyElement>,
    current: Option<(Inline, BlockKind)>,
    bold: usize,
    italic: usize,
    strike: usize,
    link: Option<String>,
    /// Each open list: the next number for an ordered one.
    lists: Vec<Option<u64>>,
    quote: usize,
    code: Option<String>,
    counter: usize,
    /// A table being read: its rows so far (whether the header, and each
    /// cell drawn), and the row being read.
    table: Option<Vec<(bool, Vec<AnyElement>)>>,
    row: Vec<AnyElement>,
}

impl<'a> Renderer<'a> {
    fn begin(&mut self, kind: BlockKind) {
        self.flush();
        self.current = Some((Inline::default(), kind));
    }

    fn inline(&mut self) -> &mut Inline {
        if self.current.is_none() {
            self.current = Some((Inline::default(), BlockKind::Paragraph));
        }
        &mut self.current.as_mut().unwrap().0
    }

    fn push(&mut self, text: &str, code: bool) {
        let style = HighlightStyle {
            font_weight: (self.bold > 0).then_some(FontWeight::BOLD),
            font_style: (self.italic > 0).then_some(FontStyle::Italic),
            background_color: code.then_some(self.theme.tile),
            color: self.link.is_some().then_some(self.theme.selected),
            underline: self.link.is_some().then_some(UnderlineStyle { thickness: px(1.), color: None, wavy: false }),
            strikethrough: (self.strike > 0).then_some(gpui::StrikethroughStyle { thickness: px(1.), color: None }),
            ..Default::default()
        };
        let link = self.link.clone();
        let inline = self.inline();
        let start = inline.text.len();
        inline.text.push_str(text);
        let range = start..inline.text.len();
        if range.is_empty() {
            return;
        }
        if style != HighlightStyle::default() {
            inline.highlights.push((range.clone(), style));
        }
        if let Some(url) = link {
            inline.links.push((range, url));
        }
    }

    /// Ends the block being written, drawing it.
    fn flush(&mut self) {
        let Some((inline, kind)) = self.current.take() else { return };
        if inline.text.trim().is_empty() {
            return;
        }
        let body = self.styled(inline);
        let depth = self.lists.len().saturating_sub(1) as f32;
        let block = div()
            .when(self.quote > 0, |d| d.border_l_2().border_color(self.theme.border).pl_2().text_color(self.theme.secondary))
            .map(|d| match kind {
                BlockKind::Heading(level) => d
                    .pt_1()
                    .font_weight(FontWeight::SEMIBOLD)
                    .map(|d| match level {
                        HeadingLevel::H1 => d.text_lg(),
                        HeadingLevel::H2 => d.text_base(),
                        _ => d,
                    })
                    .child(body),
                BlockKind::Item => d.pl(px(depth * 16.)).child(body),
                BlockKind::TableRow => d.text_xs().child(body),
                BlockKind::Paragraph => d.child(body),
            });
        self.blocks.push(block.into_any_element());
    }

    /// A block's text with its styled runs, its links clickable.
    fn styled(&mut self, inline: Inline) -> AnyElement {
        self.counter += 1;
        let text = StyledText::new(inline.text.trim_end().to_string()).with_highlights(
            inline.highlights.into_iter().filter(|(r, _)| r.end <= inline.text.trim_end().len()),
        );
        if inline.links.is_empty() {
            text.into_any_element()
        } else {
            let (ranges, urls): (Vec<_>, Vec<_>) = inline.links.into_iter().unzip();
            InteractiveText::new(SharedString::from(format!("{}-{}", self.id, self.counter)), text)
                .on_click(ranges, move |index, _, cx| cx.open_url(&urls[index]))
                .into_any_element()
        }
    }

    /// A table read: a grid with lines between, its header row bold on a tint.
    fn draw_table(&mut self, rows: Vec<(bool, Vec<AnyElement>)>) {
        let theme = self.theme;
        let grid = div().flex().flex_col().rounded_md().border_1().border_color(theme.border).overflow_hidden().text_xs().children(rows.into_iter().enumerate().map(|(r, (head, cells))| {
            div()
                .flex()
                .flex_row()
                .when(r > 0, |d| d.border_t_1().border_color(theme.border))
                .when(head, |d| d.bg(theme.tile).font_weight(FontWeight::SEMIBOLD))
                .children(cells.into_iter().enumerate().map(|(c, cell)| div().flex_1().min_w_0().px_2().py_1().when(c > 0, |d| d.border_l_1().border_color(theme.border)).child(cell)))
        }));
        self.blocks.push(grid.into_any_element());
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => match tag {
                Tag::Paragraph => {
                    // A loose list item's paragraph continues the item.
                    if !matches!(self.current, Some((_, BlockKind::Item))) {
                        self.begin(BlockKind::Paragraph);
                    }
                }
                Tag::Heading { level, .. } => self.begin(BlockKind::Heading(level)),
                Tag::BlockQuote(_) => {
                    self.flush();
                    self.quote += 1;
                }
                Tag::CodeBlock(_) => {
                    self.flush();
                    self.code = Some(String::new());
                }
                Tag::List(start) => {
                    self.flush();
                    self.lists.push(start);
                }
                Tag::Item => {
                    self.begin(BlockKind::Item);
                    let marker = match self.lists.last_mut() {
                        Some(Some(n)) => {
                            let marker = format!("{n}. ");
                            *n += 1;
                            marker
                        }
                        _ => "• ".to_string(),
                    };
                    self.push(&marker, false);
                }
                Tag::Emphasis => self.italic += 1,
                Tag::Strong => self.bold += 1,
                Tag::Strikethrough => self.strike += 1,
                Tag::Link { dest_url, .. } => self.link = Some(dest_url.to_string()),
                Tag::Image { dest_url, .. } => {
                    self.link = Some(dest_url.to_string());
                    self.push("[image: ", false);
                }
                Tag::Table(_) => {
                    self.flush();
                    self.table = Some(Vec::new());
                }
                Tag::TableHead | Tag::TableRow => self.row.clear(),
                Tag::TableCell => self.current = Some((Inline::default(), BlockKind::TableRow)),
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph => {
                    if !matches!(self.current, Some((_, BlockKind::Item))) {
                        self.flush();
                    }
                }
                TagEnd::Heading(_) | TagEnd::Item => self.flush(),
                TagEnd::TableCell => {
                    let inline = self.current.take().map(|(inline, _)| inline).unwrap_or_default();
                    let cell = self.styled(inline);
                    self.row.push(cell);
                }
                TagEnd::TableHead | TagEnd::TableRow => {
                    let row = std::mem::take(&mut self.row);
                    if let Some(table) = self.table.as_mut() {
                        table.push((matches!(tag, TagEnd::TableHead), row));
                    }
                }
                TagEnd::Table => {
                    if let Some(rows) = self.table.take() {
                        self.draw_table(rows);
                    }
                }
                TagEnd::BlockQuote(_) => {
                    self.flush();
                    self.quote = self.quote.saturating_sub(1);
                }
                TagEnd::CodeBlock => {
                    let code = self.code.take().unwrap_or_default();
                    self.blocks.push(
                        div()
                            .p_2()
                            .rounded_md()
                            .bg(self.theme.tile)
                            .font_family(crate::zed::MONO)
                            .text_xs()
                            .child(code.trim_end().to_string())
                            .into_any_element(),
                    );
                }
                TagEnd::List(_) => {
                    self.flush();
                    self.lists.pop();
                }
                TagEnd::Emphasis => self.italic = self.italic.saturating_sub(1),
                TagEnd::Strong => self.bold = self.bold.saturating_sub(1),
                TagEnd::Strikethrough => self.strike = self.strike.saturating_sub(1),
                TagEnd::Link => self.link = None,
                TagEnd::Image => {
                    self.push("]", false);
                    self.link = None;
                }
                _ => {}
            },
            Event::Text(text) => match self.code.as_mut() {
                Some(code) => code.push_str(&text),
                None => self.push(&text, false),
            },
            Event::Code(text) => self.push(&text, true),
            Event::SoftBreak => self.push(" ", false),
            Event::HardBreak => self.push("\n", false),
            Event::Rule => {
                self.flush();
                self.blocks.push(div().my_1().h(px(1.)).bg(self.theme.border).into_any_element());
            }
            Event::TaskListMarker(done) => self.push(if done { "☑ " } else { "☐ " }, false),
            Event::Html(html) | Event::InlineHtml(html) => self.html(&html),
            _ => {}
        }
    }

    /// GitHub's HTML: images become links to them, line breaks break, and
    /// the rest of the tags are dropped.
    fn html(&mut self, html: &str) {
        let lower = html.to_lowercase();
        if lower.contains("<img") {
            if let Some(src) = attribute(html, "src") {
                let alt = attribute(html, "alt").filter(|a| !a.is_empty()).unwrap_or_else(|| "image".into());
                self.link = Some(src);
                self.push(&format!("[{alt}]"), false);
                self.link = None;
            }
        } else if lower.starts_with("<br") {
            self.push("\n", false);
        }
    }
}

fn attribute(html: &str, name: &str) -> Option<String> {
    let start = html.find(&format!("{name}=\""))? + name.len() + 2;
    let end = html[start..].find('"')? + start;
    Some(html[start..end].to_string())
}

/// `source` as blocks, top to bottom. `id` keeps link ids apart when
/// several are drawn at once.
pub fn markdown(id: &str, source: &str, theme: &Theme) -> AnyElement {
    let mut renderer = Renderer {
        id: id.to_string(),
        theme,
        blocks: Vec::new(),
        current: None,
        bold: 0,
        italic: 0,
        strike: 0,
        link: None,
        lists: Vec::new(),
        quote: 0,
        code: None,
        counter: 0,
        table: None,
        row: Vec::new(),
    };
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(source, options) {
        renderer.event(event);
    }
    renderer.flush();
    div().flex().flex_col().gap_2().children(renderer.blocks).into_any_element()
}

/// A piece of GitHub-flavoured text the plain renderer doesn't draw:
/// a callout (`> [!TIP]` and its quoted lines) or a folded section
/// (`<details><summary>`), each holding more of the same.
pub enum Segment {
    Text(String),
    Callout { kind: String, body: Vec<Segment> },
    Details { summary: String, body: Vec<Segment> },
}

/// Splits `source` into plain Markdown and the callouts and folded
/// sections GitHub draws as boxes, nested either way round.
pub fn github_segments(source: &str) -> Vec<Segment> {
    let lines: Vec<&str> = source.lines().collect();
    let mut out = Vec::new();
    let mut text: Vec<&str> = Vec::new();
    let flush = |text: &mut Vec<&str>, out: &mut Vec<Segment>| {
        let joined = text.join("\n");
        if !joined.trim().is_empty() {
            out.push(Segment::Text(joined));
        }
        text.clear();
    };
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();
        // A callout: its first quoted line names the kind.
        if let Some(rest) = trimmed.strip_prefix('>').map(str::trim_start).and_then(|r| r.strip_prefix("[!")) {
            if let Some((kind, after)) = rest.split_once(']') {
                flush(&mut text, &mut out);
                let mut inner: Vec<String> = Vec::new();
                if !after.trim().is_empty() {
                    inner.push(after.trim().to_string());
                }
                i += 1;
                while i < lines.len() && lines[i].trim_start().starts_with('>') {
                    let quoted = lines[i].trim_start().strip_prefix('>').unwrap_or("");
                    inner.push(quoted.strip_prefix(' ').unwrap_or(quoted).to_string());
                    i += 1;
                }
                out.push(Segment::Callout { kind: kind.trim().to_uppercase(), body: github_segments(&inner.join("\n")) });
                continue;
            }
        }
        // A folded section, to its matching close.
        if trimmed.starts_with("<details") {
            flush(&mut text, &mut out);
            let mut depth = 0;
            let mut inner: Vec<&str> = Vec::new();
            while i < lines.len() {
                let l = lines[i];
                depth += l.matches("<details").count() as i32;
                depth -= l.matches("</details>").count() as i32;
                inner.push(l);
                i += 1;
                if depth <= 0 {
                    break;
                }
            }
            let joined = inner.join("\n");
            let open_end = joined.find('>').map(|n| n + 1).unwrap_or(0);
            let close = joined.rfind("</details>").unwrap_or(joined.len());
            let mut body = joined[open_end..close.max(open_end)].to_string();
            let mut summary = "Details".to_string();
            if let (Some(s), Some(e)) = (body.find("<summary>"), body.find("</summary>")) {
                if e > s {
                    summary = body[s + "<summary>".len()..e].trim().to_string();
                    body = format!("{}{}", &body[..s], &body[e + "</summary>".len()..]);
                }
            }
            out.push(Segment::Details { summary, body: github_segments(&body) });
            continue;
        }
        text.push(line);
        i += 1;
    }
    flush(&mut text, &mut out);
    out
}

/// GitHub-flavoured text as GitHub shows it, for any view: plain Markdown,
/// callouts as tinted boxes with their kind, folded sections closed until
/// their summary is clicked. `open` holds the folded sections opened, by
/// key (from `id`); `toggle` opens or closes one on the view.
pub fn github<V: 'static>(id: &str, source: &str, theme: &Theme, open: &std::collections::HashSet<String>, toggle: fn(&mut V, String), cx: &mut gpui::Context<V>) -> AnyElement {
    div().flex().flex_col().gap_2().children(github_view(id, &github_segments(source), theme, open, toggle, cx)).into_any_element()
}

/// `github`'s pieces, from segments already split.
pub fn github_view<V: 'static>(id: &str, segments: &[Segment], theme: &Theme, open: &std::collections::HashSet<String>, toggle: fn(&mut V, String), cx: &mut gpui::Context<V>) -> Vec<AnyElement> {
    segments
        .iter()
        .enumerate()
        .map(|(i, segment)| {
            let key = format!("{id}-{i}");
            match segment {
                Segment::Text(text) => markdown(&key, text, theme),
                Segment::Callout { kind, body } => {
                    let (label, tint) = match kind.as_str() {
                        "TIP" => ("Tip", theme.good()),
                        "IMPORTANT" => ("Important", theme.slot(5)),
                        "WARNING" => ("Warning", theme.orange()),
                        "CAUTION" => ("Caution", theme.critical()),
                        _ => ("Note", theme.blue()),
                    };
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .pl_3()
                        .py_1()
                        .border_l_2()
                        .border_color(tint)
                        .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(label))
                        .children(github_view(&key, body, theme, open, toggle, cx))
                        .into_any_element()
                }
                Segment::Details { summary, body } => {
                    let shown = open.contains(&key);
                    let flip = key.clone();
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(
                            div()
                                .id(SharedString::from(format!("details-{key}")))
                                .flex()
                                .flex_row()
                                .gap_1p5()
                                .text_sm()
                                .text_color(theme.secondary)
                                .cursor_pointer()
                                .hover(|s| s.text_color(theme.fg))
                                .on_click(cx.listener(move |this, _: &gpui::ClickEvent, _, cx| {
                                    toggle(this, flip.clone());
                                    cx.notify();
                                }))
                                .child(div().flex_none().w(px(10.)).child(if shown { "▾" } else { "▸" }))
                                .child(summary.clone()),
                        )
                        .when(shown, |d| d.child(div().pl_4().flex().flex_col().gap_2().children(github_view(&key, body, theme, open, toggle, cx))))
                        .into_any_element()
                }
            }
        })
        .collect()
}
