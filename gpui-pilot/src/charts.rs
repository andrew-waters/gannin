//! Charts drawn by hand, since GPUI has no chart library: bars are divs,
//! lines are painted on a canvas, and hover comes from a row of transparent
//! columns over the plot. The palette is `ChartPalette` from the Swift app.

use crate::format::compact_duration;
use crate::metrics::{Histogram, HISTOGRAM_LABELS};
use crate::page::{ActionsPage, ChartKey};
use gpui::{
    canvas, div, fill, point, prelude::*, px, relative, rgb, size, AnyElement, Bounds, Context, Hsla, PathBuilder, Pixels,
    Point, Window,
};

#[derive(Clone, Copy)]
pub struct Theme {
    pub dark: bool,
    pub bg: Hsla,
    pub fg: Hsla,
    pub secondary: Hsla,
    pub tertiary: Hsla,
    pub grid: Hsla,
    pub tile: Hsla,
    pub border: Hsla,
    pub selected: Hsla,
    pub on_selected: Hsla,
    /// The sidebar and title bar.
    pub sidebar: Hsla,
    pub popover: Hsla,
    /// A selected sidebar row or tab.
    pub row_selected: Hsla,
}

fn hex(value: u32) -> Hsla {
    rgb(value).into()
}

impl Theme {
    pub fn new(dark: bool) -> Self {
        if dark {
            Self {
                dark,
                bg: hex(0x1E1E1E),
                fg: hex(0xE5E5E7),
                secondary: hex(0x98989D),
                tertiary: hex(0x6C6C70),
                grid: hex(0x343436),
                tile: hex(0x2A2A2C),
                border: hex(0x3A3A3C),
                selected: hex(0x3987E5),
                on_selected: hex(0xFFFFFF),
                sidebar: hex(0x252527),
                popover: hex(0x2C2C2E),
                row_selected: hex(0x3A3A3D),
            }
        } else {
            Self {
                dark,
                bg: hex(0xFFFFFF),
                fg: hex(0x1D1D1F),
                secondary: hex(0x6E6E73),
                tertiary: hex(0xA1A1A6),
                grid: hex(0xE8E8ED),
                tile: hex(0xF5F5F7),
                border: hex(0xD2D2D7),
                selected: hex(0x2A78D6),
                on_selected: hex(0xFFFFFF),
                sidebar: hex(0xF0F0F2),
                popover: hex(0xFFFFFF),
                row_selected: hex(0xDCDCE1),
            }
        }
    }

    pub fn for_window(window: &Window) -> Self {
        Self::new(matches!(window.appearance(), gpui::WindowAppearance::Dark | gpui::WindowAppearance::VibrantDark))
    }

    fn pick(&self, light: u32, dark: u32) -> Hsla {
        hex(if self.dark { dark } else { light })
    }

    pub fn blue(&self) -> Hsla {
        self.pick(0x2A78D6, 0x3987E5)
    }
    pub fn orange(&self) -> Hsla {
        self.pick(0xEB6834, 0xD95926)
    }
    /// A starred row's star, wash and edge.
    pub fn star(&self) -> Hsla {
        self.pick(0xEDA100, 0xC98500)
    }
    pub fn neutral(&self) -> Hsla {
        self.pick(0xB9B8B2, 0x5A5955)
    }
    pub fn good(&self) -> Hsla {
        hex(0x0CA30C)
    }
    pub fn critical(&self) -> Hsla {
        hex(0xD03B3B)
    }

    /// Categorical slots 1-8 in the palette's fixed order.
    pub fn slot(&self, slot: usize) -> Hsla {
        const LIGHT: [u32; 8] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4, 0x008300, 0x4A3AA7, 0xE34948];
        const DARK: [u32; 8] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767];
        match (LIGHT.get(slot), DARK.get(slot)) {
            (Some(light), Some(dark)) => self.pick(*light, *dark),
            _ => self.neutral(),
        }
    }
}

/// What the value axis measures, for its ticks and labels.
#[derive(Clone, Copy)]
pub enum Scale {
    Count,
    Duration,
}

impl Scale {
    /// About four round ticks from zero to at least `max`; the last is the top.
    fn ticks(self, max: f64) -> Vec<f64> {
        let max = max.max(1.0);
        let step = match self {
            Scale::Count => {
                let raw = max / 4.0;
                let magnitude = 10f64.powf(raw.log10().floor());
                [1.0, 2.0, 5.0, 10.0].iter().map(|m| m * magnitude).find(|s| *s >= raw).unwrap_or(raw).max(1.0)
            }
            Scale::Duration => {
                const STEPS: [f64; 17] = [
                    1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0, 900.0, 1800.0, 3600.0, 7200.0, 18000.0,
                    36000.0, 86400.0,
                ];
                STEPS.iter().copied().find(|s| max / s <= 4.0).unwrap_or_else(|| (max / 4.0 / 86400.0).ceil() * 86400.0)
            }
        };
        let count = (max / step).ceil() as usize;
        (0..=count).map(|i| i as f64 * step).collect()
    }

    fn label(self, value: f64) -> String {
        match self {
            Scale::Count => format!("{}", value as i64),
            Scale::Duration => compact_duration(value),
        }
    }
}

const AXIS_WIDTH: f32 = 52.0;

/// The value axis, grid and period labels around a plot body.
fn frame(scale: Scale, ticks: &[f64], height: f32, x_labels: Vec<String>, theme: &Theme, body: AnyElement) -> impl IntoElement {
    let top = ticks.last().copied().unwrap_or(1.0).max(f64::MIN_POSITIVE);
    let y = move |value: f64| height - (value / top) as f32 * height;
    let every = x_labels.len().div_ceil(8).max(1);
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .flex()
                .flex_row()
                .child(div().relative().w(px(AXIS_WIDTH)).h(px(height)).flex_none().children(ticks.iter().map(|tick| {
                    div()
                        .absolute()
                        .right(px(8.))
                        .top(px(y(*tick) - 7.))
                        .text_xs()
                        .text_color(theme.secondary)
                        .child(scale.label(*tick))
                })))
                .child(
                    div()
                        .relative()
                        .flex_1()
                        .h(px(height))
                        .children(ticks.iter().map(|tick| {
                            div().absolute().left_0().right_0().top(px(y(*tick))).h(px(1.)).bg(theme.grid)
                        }))
                        .child(div().absolute().top_0().left_0().right_0().bottom_0().child(body)),
                ),
        )
        .child(
            div().flex().flex_row().child(div().w(px(AXIS_WIDTH)).flex_none()).child(
                div().flex_1().flex().flex_row().children(x_labels.into_iter().enumerate().map(|(i, label)| {
                    div()
                        .flex_1()
                        .whitespace_nowrap()
                        .text_xs()
                        .text_color(theme.secondary)
                        .when(i % every == 0, |d| d.child(label))
                })),
            ),
        )
}

pub fn legend(entries: Vec<(String, Hsla)>, theme: &Theme) -> impl IntoElement {
    div().flex().flex_row().flex_wrap().gap_x_4().gap_y_1().pl(px(AXIS_WIDTH)).children(entries.into_iter().map(|(name, color)| {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_1p5()
            .text_xs()
            .text_color(theme.secondary)
            .child(div().w(px(8.)).h(px(8.)).rounded_full().bg(color))
            .child(name)
    }))
}

/// Stacked bars, a column per period; `columns` hold (value, colour) from
/// the bottom of the stack up.
pub fn stacked_bars(
    key: ChartKey,
    columns: Vec<Vec<(f64, Hsla)>>,
    x_labels: Vec<String>,
    scale: Scale,
    height: f32,
    hovered: Option<usize>,
    theme: &Theme,
    cx: &mut Context<ActionsPage>,
) -> impl IntoElement {
    let max = columns.iter().map(|segments| segments.iter().map(|(v, _)| v).sum::<f64>()).fold(0.0, f64::max);
    let ticks = scale.ticks(max);
    let top = *ticks.last().unwrap();
    let body = div()
        .size_full()
        .flex()
        .flex_row()
        .children(columns.into_iter().enumerate().map(|(i, segments)| {
            let dimmed = hovered.is_some_and(|h| h != i);
            div()
                .id((key.id(), i))
                .flex_1()
                .h_full()
                .flex()
                .flex_col()
                .justify_end()
                .items_center()
                .on_hover(cx.listener(move |page, hovered: &bool, _, cx| page.set_hover(key, i, *hovered, cx)))
                .child(
                    div()
                        .w(relative(0.7))
                        .max_w(px(28.))
                        .flex()
                        .flex_col()
                        .opacity(if dimmed { 0.4 } else { 1.0 })
                        .children(segments.into_iter().rev().filter(|(v, _)| *v > 0.0).map(|(value, color)| {
                            div().w_full().h(px((value / top) as f32 * height)).bg(color)
                        })),
                )
        }))
        .into_any_element();
    frame(scale, &ticks, height, x_labels, theme, body)
}

/// Lines over the periods, with gaps where there's no value; dots on every
/// point when `dots`, otherwise only on the hovered period.
pub fn lines(
    key: ChartKey,
    series: Vec<(Vec<Option<f64>>, Hsla)>,
    x_labels: Vec<String>,
    height: f32,
    hovered: Option<usize>,
    dots: bool,
    theme: &Theme,
    cx: &mut Context<ActionsPage>,
) -> impl IntoElement {
    let count = x_labels.len();
    let max = series.iter().flat_map(|(values, _)| values.iter().flatten()).copied().fold(0.0, f64::max) * 1.15;
    let ticks = Scale::Duration.ticks(max);
    let top = *ticks.last().unwrap();
    let rule = theme.secondary;
    let plot = canvas(
        |_, _, _| (),
        move |bounds, _, window, _| paint_lines(bounds, &series, count, top, hovered, dots, rule, window),
    )
    .size_full();
    let body = div()
        .size_full()
        .relative()
        .child(plot)
        .child(
            div()
                .absolute()
                .top_0()
                .left_0()
                .right_0()
                .bottom_0()
                .flex()
                .flex_row()
                .children((0..count).map(|i| div().id((key.id(), i)).flex_1().h_full().on_hover(cx.listener(move |page, hovered: &bool, _, cx| page.set_hover(key, i, *hovered, cx))))),
        )
        .into_any_element();
    frame(Scale::Duration, &ticks, height, x_labels, theme, body)
}

#[allow(clippy::too_many_arguments)]
fn paint_lines(
    bounds: Bounds<Pixels>,
    series: &[(Vec<Option<f64>>, Hsla)],
    count: usize,
    top: f64,
    hovered: Option<usize>,
    dots: bool,
    rule: Hsla,
    window: &mut Window,
) {
    if count == 0 {
        return;
    }
    let (x0, y0) = (f32::from(bounds.origin.x), f32::from(bounds.origin.y));
    let (width, height) = (f32::from(bounds.size.width), f32::from(bounds.size.height));
    let x = |i: usize| x0 + (i as f32 + 0.5) * width / count as f32;
    let at = |i: usize, value: f64| point(px(x(i)), px(y0 + height - (value / top) as f32 * height));

    if let Some(i) = hovered {
        window.paint_quad(fill(Bounds::new(point(px(x(i)), px(y0)), size(px(1.), px(height))), rule));
    }
    for (values, color) in series {
        let mut run: Vec<Point<Pixels>> = Vec::new();
        for (i, value) in values.iter().enumerate() {
            match value {
                Some(value) => run.push(at(i, *value)),
                None => stroke(std::mem::take(&mut run), *color, window),
            }
        }
        stroke(run, *color, window);
        for (i, value) in values.iter().enumerate() {
            let Some(value) = value else { continue };
            let radius = if hovered == Some(i) { 4.5 } else if dots { 3.0 } else { continue };
            let center = at(i, *value);
            let corner = point(center.x - px(radius), center.y - px(radius));
            window.paint_quad(fill(Bounds::new(corner, size(px(radius * 2.), px(radius * 2.))), *color).corner_radii(px(radius)));
        }
    }
}

fn stroke(points: Vec<Point<Pixels>>, color: Hsla, window: &mut Window) {
    if points.len() < 2 {
        return;
    }
    let mut path = PathBuilder::stroke(px(2.));
    path.move_to(points[0]);
    for p in &points[1..] {
        path.line_to(*p);
    }
    if let Ok(path) = path.build() {
        window.paint_path(path, color);
    }
}

/// A value per week as small bars, oldest first (`SparkBars`).
pub fn spark_bars(values: &[f64], theme: &Theme) -> impl IntoElement {
    let top = values.iter().copied().fold(0.0001, f64::max);
    div().flex().flex_row().items_end().gap_0p5().h(px(22.)).children(values.iter().map(|value| {
        let (height, color) = if *value == 0.0 { (1.0, theme.grid) } else { ((22.0 * value / top).max(2.0) as f32, theme.blue()) };
        div().w(px(7.)).h(px(height)).rounded_sm().bg(color)
    }))
}

/// Durations in six buckets as small bars (`HistogramCell`).
pub fn histogram_cell(histogram: &Histogram, theme: &Theme) -> impl IntoElement {
    let top = histogram.counts.iter().copied().max().unwrap_or(1).max(1) as f32;
    div().flex().flex_row().items_end().gap_0p5().h(px(22.)).children(histogram.counts.iter().zip(HISTOGRAM_LABELS).map(|(count, _)| {
        let (height, color) =
            if *count == 0 { (1.0, theme.grid) } else { ((22.0 * *count as f32 / top).max(2.0), theme.blue()) };
        div().w(px(12.)).h(px(height)).rounded_sm().bg(color)
    }))
}

/// A ring that fills clockwise from the top as `done` of `total` complete:
/// the track in the grid colour, the done part in blue, all green once
/// everything's done.
pub fn progress_ring(done: i64, total: i64, diameter: f32, theme: &Theme) -> impl IntoElement {
    let fraction = if total > 0 { (done as f32 / total as f32).clamp(0., 1.) } else { 0. };
    let (track, fill_color) = (theme.grid, if fraction >= 1. { theme.good() } else { theme.blue() });
    canvas(
        |_, _, _| (),
        move |bounds, _, window, _| {
            let width = (diameter * 0.18).max(2.);
            let radius = diameter / 2. - width / 2.;
            let center = bounds.center();
            let arc = |from: f32, to: f32| {
                let steps = ((to - from) * 64.).ceil().max(1.) as usize;
                let mut path = PathBuilder::stroke(px(width));
                for i in 0..=steps {
                    let turn = from + (to - from) * i as f32 / steps as f32;
                    let angle = turn * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
                    let p = point(center.x + px(radius * angle.cos()), center.y + px(radius * angle.sin()));
                    if i == 0 {
                        path.move_to(p);
                    } else {
                        path.line_to(p);
                    }
                }
                path.build().ok()
            };
            if let Some(path) = arc(0., 1.) {
                window.paint_path(path, track);
            }
            if fraction > 0. {
                if let Some(path) = arc(0., fraction) {
                    window.paint_path(path, fill_color);
                }
            }
        },
    )
    .size(px(diameter))
    .flex_none()
}
