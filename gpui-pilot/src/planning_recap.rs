//! The recap: the plan walked through, full window, before the room agrees.
//! The problem, what gets built, its shape, the design, what needs a
//! person's attention, the breakdown, the order it's delivered in, and the
//! choice to agree or go back. It confirms; it captures nothing.
//!
//! Its structure comes from the plan itself (the diagrams, screens, risks,
//! findings and the delivery waves); its words from the `recap` claude
//! writes once the breakdown's approved, else the first lines of each part.

use crate::charts::Theme;
use crate::marra_view::button;
use crate::planning::{Approvals, Stage, State, Status};
use crate::planning_panel::{diagram, rich, PlanningPanel};
use crate::planning_security::Review;
use gpui::{div, prelude::*, px, ClickEvent, FontWeight, SharedString, WeakEntity};
use std::path::Path;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Slide {
    Problem,
    Build,
    Shape,
    Design,
    Attention,
    Breakdown,
    Delivery,
    Ready,
}

impl Slide {
    pub fn title(self) -> &'static str {
        match self {
            Slide::Problem => "The problem",
            Slide::Build => "What we'll build",
            Slide::Shape => "What it looks like",
            Slide::Design => "How it's built",
            Slide::Attention => "Needs attention",
            Slide::Breakdown => "The breakdown",
            Slide::Delivery => "Delivery",
            Slide::Ready => "Ready to agree?",
        }
    }
}

/// The slides this plan has: Shape and Design only when there's something
/// to show.
pub fn slides(state: &State) -> Vec<Slide> {
    let mut out = vec![Slide::Problem, Slide::Build];
    if !state.shape.is_empty() {
        out.push(Slide::Shape);
    }
    if !state.approach.is_empty() || !state.architecture.is_empty() {
        out.push(Slide::Design);
    }
    out.extend([Slide::Attention, Slide::Breakdown, Slide::Delivery, Slide::Ready]);
    out
}

fn label(text: &str, theme: &Theme) -> gpui::Div {
    div().pt_4().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(text.to_uppercase())
}

fn lead(text: String) -> gpui::Div {
    div().text_xl().child(text)
}

fn points(items: &[String], theme: &Theme) -> gpui::Div {
    div().flex().flex_col().gap_1().children(items.iter().map(|i| div().flex().flex_row().gap_2().text_lg().child(div().text_color(theme.selected).child("•")).child(div().flex_1().min_w_0().child(i.clone()))))
}

/// Something needing attention, tagged with where it comes from.
fn flag(tag: &str, text: String, tint: gpui::Hsla, theme: &Theme) -> gpui::Div {
    div()
        .flex()
        .flex_row()
        .gap_3()
        .py_1p5()
        .border_b_1()
        .border_color(theme.border)
        .child(div().w(px(120.)).flex_none().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(tag.to_string()))
        .child(div().flex_1().min_w_0().text_base().child(text))
}

pub struct Context<'a> {
    pub state: &'a State,
    pub review: Option<&'a Review>,
    pub approvals: &'a Approvals,
    /// Where the screens' images are.
    pub folder: &'a Path,
    pub panel: &'a WeakEntity<PlanningPanel>,
}

/// One slide's content.
pub fn slide(slide: Slide, ctx: &Context, theme: &Theme) -> gpui::AnyElement {
    let s = ctx.state;
    let r = &s.recap;
    let col = div().flex().flex_col().gap_1();
    match slide {
        Slide::Problem => col
            .child(lead(if r.problem.is_empty() { s.requirement.problem.clone() } else { r.problem.clone() }))
            .when(!s.outcome.change.is_empty(), |d| d.child(label("What changes, for whom", theme)).child(div().text_lg().child(s.outcome.change.clone())))
            .when(!s.outcome.if_not.is_empty(), |d| d.child(label("If we don't", theme)).child(div().text_lg().child(s.outcome.if_not.clone())))
            .when(!s.outcome.measures.is_empty(), |d| {
                d.child(label("How we'll know", theme)).children(s.outcome.measures.iter().map(|m| {
                    div()
                        .flex()
                        .flex_row()
                        .gap_3()
                        .text_lg()
                        .child(div().w(px(36.)).flex_none().text_color(theme.selected).child(m.id.clone()))
                        .child(div().flex_1().min_w_0().child(if m.target.is_empty() { m.text.clone() } else { format!("{} (target: {})", m.text, m.target) }))
                }))
            })
            .into_any_element(),
        Slide::Build => col
            .child(lead(if r.solution.is_empty() { s.requirement.goal.clone() } else { r.solution.clone() }))
            .when(!s.outcome.smallest.is_empty(), |d| d.child(label("The smallest version that proves it", theme)).child(div().text_lg().child(s.outcome.smallest.clone())))
            .when(!r.highlights.is_empty(), |d| d.child(label("Worth knowing", theme)).child(points(&r.highlights, theme)))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_8()
                    .when(!s.requirement.scope.is_empty(), |d| d.child(div().flex_1().min_w_0().child(label("In scope", theme)).child(points(&s.requirement.scope, theme))))
                    .when(!s.requirement.non_goals.is_empty(), |d| d.child(div().flex_1().min_w_0().child(label("Not doing", theme)).child(points(&s.requirement.non_goals, theme)))),
            )
            .child(div().pt_4().text_sm().text_color(theme.secondary).child(format!("{} acceptance criteria, each covered by an issue or flagged under Needs attention.", s.requirement.acceptance.len())))
            .into_any_element(),
        Slide::Shape => {
            let journey = s.shape.flows.iter().find(|f| !f.kind.eq_ignore_ascii_case("process")).or(s.shape.flows.first());
            col.when_some(journey, |d, f| d.child(label(&format!("{} {}", f.id, f.title), theme)).child(diagram("recap-flow", &format!("{} {}", f.id, f.title), &f.diagram, theme, ctx.panel)))
                .when(s.shape.flows.len() > 1, |d| d.child(div().text_sm().text_color(theme.secondary).child(format!("And {} more flow{}: {}.", s.shape.flows.len() - 1, if s.shape.flows.len() == 2 { "" } else { "s" }, s.shape.flows.iter().filter(|f| Some(*f) != journey).map(|f| f.title.clone()).collect::<Vec<_>>().join(", ")))))
                .when(!s.shape.screens.is_empty(), |d| {
                    d.child(label("Screens", theme)).child(div().flex().flex_row().flex_wrap().gap_3().children(s.shape.screens.iter().map(|sc| {
                        div()
                            .w(px(240.))
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(match sc.image_path() {
                                Some(path) => div()
                                    .h(px(150.))
                                    .relative()
                                    .overflow_hidden()
                                    .rounded_md()
                                    .bg(gpui::white())
                                    .child(gpui::img(ctx.folder.join(path)).absolute().top_0().left_0().right_0().bottom_0().object_fit(gpui::ObjectFit::Contain))
                                    .into_any_element(),
                                None => div().h(px(150.)).p_2().rounded_md().bg(theme.tile).text_xs().overflow_hidden().child(if sc.wireframe.is_empty() { "Not drawn".to_string() } else { sc.wireframe.clone() }).into_any_element(),
                            })
                            .child(div().text_sm().child(format!("{} {}", sc.id, sc.title)))
                    })))
                })
                .into_any_element()
        }
        Slide::Design => {
            let approach: String = s.approach.split("\n\n").filter(|p| !p.trim().starts_with("```")).take(2).collect::<Vec<_>>().join("\n\n");
            col.when(!approach.is_empty(), |d| d.child(div().text_lg().child(rich("recap-approach", &approach, theme, ctx.panel))))
                .children(s.architecture.iter().enumerate().map(|(i, a)| {
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(label(&format!("{}{}", a.path.trim(), if a.new { ", new" } else { "" }), theme))
                        .when(!a.note.is_empty(), |d| d.child(div().text_lg().child(a.note.clone())))
                        .when(!a.diagram.trim().is_empty(), |d| d.child(diagram(&format!("recap-arch-{i}"), &a.path, &a.diagram, theme, ctx.panel)))
                }))
                .when(!s.architecture.is_empty(), |d| d.child(div().text_sm().text_color(theme.secondary).child("New and changed parts are dashed: planned until the work ships.")))
                .into_any_element()
        }
        Slide::Attention => {
            let mut rows: Vec<gpui::AnyElement> = Vec::new();
            for a in &r.attention {
                rows.push(flag("Claude", a.clone(), theme.orange(), theme).into_any_element());
            }
            if let Some(review) = ctx.review.filter(|r| r.done()) {
                for f in &review.findings {
                    let tint = match f.severity.to_lowercase().as_str() {
                        "high" => theme.critical(),
                        "medium" => theme.orange(),
                        _ => theme.secondary,
                    };
                    let answer = s.security.iter().find(|a| a.id.eq_ignore_ascii_case(&f.id)).map(|a| format!(" Answer: {}", a.response.trim())).unwrap_or_else(|| " Not answered.".into());
                    rows.push(flag(&format!("{} {}", f.id, f.severity.to_lowercase()), format!("{}.{answer}", f.title.trim_end_matches('.')), tint, theme).into_any_element());
                }
            }
            for f in s.scouting.iter().filter(|f| f.kind.eq_ignore_ascii_case("risk")) {
                rows.push(flag("Risk in the code", format!("{} ({})", f.note, f.path), theme.orange(), theme).into_any_element());
            }
            for (stage, status) in ctx.approvals.outstanding(s) {
                let text = match status {
                    Status::Recheck => format!("{} changed after the room approved it.", stage.title()),
                    _ => format!("The room hasn't approved {}.", stage.title()),
                };
                rows.push(flag("Not settled", text, theme.orange(), theme).into_any_element());
            }
            let uncovered: Vec<String> = s.uncovered().iter().map(|c| c.id.clone()).collect();
            if !uncovered.is_empty() {
                rows.push(flag("Not covered", format!("No issue satisfies {}.", uncovered.join(", ")), theme.orange(), theme).into_any_element());
            }
            for q in &s.requirement.open_questions {
                rows.push(flag("Open question", q.clone(), theme.secondary, theme).into_any_element());
            }
            for p in &s.outcome.premortem {
                rows.push(flag("If it fails", p.clone(), theme.secondary, theme).into_any_element());
            }
            if rows.is_empty() {
                rows.push(div().text_lg().text_color(theme.secondary).child("Nothing flagged.").into_any_element());
            }
            col.child(div().text_lg().text_color(theme.secondary).pb_2().child("Look at these before agreeing.")).children(rows).into_any_element()
        }
        Slide::Breakdown => {
            let issue_row = |t: &crate::planning::Task| {
                div()
                    .flex()
                    .flex_row()
                    .gap_3()
                    .py_1()
                    .child(div().flex_1().min_w_0().text_lg().child(t.title.clone()))
                    .child(div().flex_none().text_sm().text_color(theme.secondary).child(
                        [Some(t.repo.rsplit('/').next().unwrap_or(&t.repo).to_string()), (!t.estimate.is_empty()).then(|| t.estimate.clone()), (!t.satisfies.is_empty()).then(|| t.satisfies.join(", "))].into_iter().flatten().collect::<Vec<_>>().join("  ·  "),
                    ))
            };
            let mut blocks: Vec<gpui::AnyElement> = Vec::new();
            for epic in s.epics() {
                let under: Vec<&crate::planning::Task> = s.issues().filter(|t| t.parent.trim().eq_ignore_ascii_case(epic.title.trim())).collect();
                blocks.push(
                    div()
                        .flex()
                        .flex_col()
                        .p_3()
                        .rounded_md()
                        .bg(theme.tile)
                        .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child(format!("Epic: {}", epic.title)))
                        .children(under.into_iter().map(issue_row))
                        .into_any_element(),
                );
            }
            let loose: Vec<&crate::planning::Task> = s.issues().filter(|t| !s.epics().any(|e| e.title.trim().eq_ignore_ascii_case(t.parent.trim()))).collect();
            if !loose.is_empty() {
                blocks.push(div().flex().flex_col().children(loose.into_iter().map(issue_row)).into_any_element());
            }
            col.when(!s.size.is_empty(), |d| d.child(lead(format!("{}{}", s.size[..1].to_uppercase(), &s.size[1..])).child(div().text_lg().text_color(theme.secondary).child(s.size_reason.clone()))))
                .child(div().pt_3().flex().flex_col().gap_3().children(blocks))
                .into_any_element()
        }
        Slide::Delivery => {
            let waves = s.waves();
            let chain = s.longest_chain();
            let mut repos: Vec<(String, Vec<String>)> = Vec::new();
            for t in s.issues() {
                let name = t.repo.rsplit('/').next().unwrap_or(&t.repo).to_string();
                match repos.iter_mut().find(|(r, _)| *r == name) {
                    Some((_, sizes)) => sizes.push(t.estimate.clone()),
                    None => repos.push((name, vec![t.estimate.clone()])),
                }
            }
            col.when(!r.delivery.is_empty(), |d| d.child(lead(r.delivery.clone())))
                .child(
                    div().pt_4().flex().flex_row().gap_4().children(waves.iter().enumerate().map(|(i, wave)| {
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(div().text_sm().font_weight(FontWeight::SEMIBOLD).text_color(theme.selected).child(if i == 0 { "Wave 1: can start now".to_string() } else { format!("Wave {}: after wave {}", i + 1, i) }))
                            .children(wave.iter().map(|t| {
                                div()
                                    .p_2()
                                    .rounded_md()
                                    .bg(theme.tile)
                                    .flex()
                                    .flex_col()
                                    .child(div().text_base().child(t.title.clone()))
                                    .child(div().text_xs().text_color(theme.secondary).child(format!("{}{}", t.repo.rsplit('/').next().unwrap_or(&t.repo), if t.estimate.is_empty() { String::new() } else { format!("  ·  {}", t.estimate) })))
                            }))
                    })),
                )
                .when(chain.len() > 1, |d| d.child(label("The longest chain", theme)).child(div().text_lg().child(chain.iter().map(|t| t.title.clone()).collect::<Vec<_>>().join("  ›  "))))
                .when(!repos.is_empty(), |d| {
                    d.child(label("By repository", theme)).child(div().flex().flex_row().flex_wrap().gap_4().children(repos.iter().map(|(repo, sizes)| {
                        let sized: Vec<&String> = sizes.iter().filter(|s| !s.is_empty()).collect();
                        div().text_lg().child(format!("{repo}: {} issue{}{}", sizes.len(), if sizes.len() == 1 { "" } else { "s" }, if sized.is_empty() { String::new() } else { format!(" ({})", sized.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ")) }))
                    })))
                })
                .into_any_element()
        }
        Slide::Ready => {
            let epics = s.epics().count();
            let issues = s.issues().count();
            let panel = ctx.panel.clone();
            let earlier: Vec<Stage> = Stage::ALL.iter().copied().filter(|st| *st != Stage::Agree).collect();
            col.child(lead(format!(
                "Agreeing files {}{} issue{} and commits the plan to the harness.",
                if epics > 0 { format!("{epics} epic{} and ", if epics == 1 { "" } else { "s" }) } else { String::new() },
                issues,
                if issues == 1 { "" } else { "s" }
            )))
            .child(div().text_lg().text_color(theme.secondary).child("Next you'll check exactly what's filed, and who was here, before anything is written."))
            .child(
                div().pt_6().flex().flex_row().flex_wrap().gap_2().child(button("recap-agree", "Agree", true, theme).on_click(move |_, window, cx| {
                    let _ = panel.update(cx, |this, cx| {
                        this.close_recap(cx);
                        this.open_agree(window, cx);
                    });
                })),
            )
            .child(label("Or take it back", theme))
            .child(div().flex().flex_row().flex_wrap().gap_2().children(earlier.into_iter().map(|st| {
                let panel = ctx.panel.clone();
                button(SharedString::from(format!("recap-back-{}", st.key())), format!("Go Back to {}", st.title()), false, theme).on_click(move |_: &ClickEvent, window, cx| {
                    let _ = panel.update(cx, |this, cx| {
                        this.close_recap(cx);
                        this.back(st, window, cx);
                    });
                })
            })))
            .into_any_element()
        }
    }
}
