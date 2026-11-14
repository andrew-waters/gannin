//! Markdown for issue descriptions and comments, as `MarkdownText` draws it
//! in the Swift app. GPUI has no renderer of its own (Zed's is GPL), so this
//! walks pulldown-cmark's events into blocks: paragraphs, headings, lists,
//! quotes, code, rules and tables as plain rows. Bold, italic, inline code
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
        self.counter += 1;
        let text = StyledText::new(inline.text.trim_end().to_string()).with_highlights(
            inline.highlights.into_iter().filter(|(r, _)| r.end <= inline.text.trim_end().len()),
        );
        let body: AnyElement = if inline.links.is_empty() {
            text.into_any_element()
        } else {
            let (ranges, urls): (Vec<_>, Vec<_>) = inline.links.into_iter().unzip();
            InteractiveText::new(SharedString::from(format!("{}-{}", self.id, self.counter)), text)
                .on_click(ranges, move |index, _, cx| cx.open_url(&urls[index]))
                .into_any_element()
        };
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
                Tag::TableHead | Tag::TableRow => self.begin(BlockKind::TableRow),
                Tag::TableCell => {
                    let started = matches!(&self.current, Some((inline, _)) if !inline.text.is_empty());
                    if started {
                        self.push("  |  ", false);
                    }
                }
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph => {
                    if !matches!(self.current, Some((_, BlockKind::Item))) {
                        self.flush();
                    }
                }
                TagEnd::Heading(_) | TagEnd::Item | TagEnd::TableHead | TagEnd::TableRow => self.flush(),
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
                            .font_family("Menlo")
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
    };
    let options = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(source, options) {
        renderer.event(event);
    }
    renderer.flush();
    div().flex().flex_col().gap_2().children(renderer.blocks).into_any_element()
}
