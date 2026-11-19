//! A pull request as a page of its own (the PR drawer's Open in Page), laid
//! out as GitHub's PR overview so it can stand in for it: the title, state,
//! branches and size, then Overview, Commits, Checks and Files changed. The
//! Overview leads with what the harness knows (the merge risk Gannin's
//! review reached, the sessions about it, the plans it delivers on, and
//! Review and Explain), then the description and one timeline of comments,
//! reviews with their threads, commits and events; the sidebar has the
//! activity, reviewers, assignees, labels, milestone, linked issues and
//! participants.
//!
//! Read only: it's fetched in one GraphQL query when it opens and on
//! Refresh, and nothing here writes to GitHub.

use crate::charts::Theme;
use crate::format::relative_date;
use crate::issues::{pill, related_chip, Related, ShowSession};
use crate::markdown::markdown;
use crate::prs::PrItem;
use chrono::{DateTime, Utc};
use gpui::{div, prelude::*, px, AnyElement, ClickEvent, Context, EventEmitter, FontWeight, Hsla, SharedString, Task, Window};
use serde_json::{json, Value};

/// Review with Claude (or Open Review) and Explain, which the workspace
/// starts as from the drawer.
pub enum PullAction {
    Review(PrItem),
    Explain(PrItem),
}

/// A linked issue was clicked: its drawer, or GitHub when it isn't stored.
pub struct OpenLinked {
    pub id: String,
    pub url: String,
}

impl EventEmitter<PullAction> for PullPage {}
impl EventEmitter<OpenLinked> for PullPage {}
impl EventEmitter<ShowSession> for PullPage {}
impl EventEmitter<crate::harness::OpenDoc> for PullPage {}

#[derive(Clone, Copy, PartialEq)]
enum Section {
    Overview,
    Commits,
    Checks,
    Files,
}

#[derive(Clone)]
struct Person {
    login: String,
    avatar: Option<String>,
}

struct Reviewer {
    person: Person,
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, or REQUESTED for
    /// one asked who hasn't reviewed.
    state: String,
}

struct Linked {
    id: String,
    number: i64,
    title: String,
    url: String,
    open: bool,
    repo: String,
}

struct CommitRow {
    short: String,
    headline: String,
    at: Option<DateTime<Utc>>,
    url: String,
    author: String,
}

struct FileRow {
    path: String,
    additions: i64,
    deletions: i64,
    change: String,
}

struct CheckRow {
    name: String,
    /// success, failure, pending, skipped or neutral.
    outcome: &'static str,
    url: Option<String>,
}

struct Thread {
    review: Option<String>,
    path: String,
    line: Option<i64>,
    resolved: bool,
    comments: Vec<(String, String)>,
}

enum Event {
    Comment { author: Person, body: String, at: Option<DateTime<Utc>>, url: String },
    Review { id: String, author: Person, state: String, body: String, at: Option<DateTime<Utc>>, url: String },
    Commit { short: String, headline: String, at: Option<DateTime<Utc>>, author: String },
    Note { actor: String, text: String, at: Option<DateTime<Utc>> },
}

struct PullData {
    id: String,
    title: String,
    state: String,
    draft: bool,
    body: String,
    author: Person,
    created_at: Option<DateTime<Utc>>,
    merged_at: Option<DateTime<Utc>>,
    closed_at: Option<DateTime<Utc>>,
    merged_by: Option<String>,
    base: String,
    head: String,
    additions: i64,
    deletions: i64,
    labels: Vec<(String, String)>,
    assignees: Vec<Person>,
    milestone: Option<String>,
    reviewers: Vec<Reviewer>,
    linked: Vec<Linked>,
    participants: Vec<Person>,
    commits: Vec<CommitRow>,
    commit_total: usize,
    files: Vec<FileRow>,
    file_total: usize,
    checks: Vec<CheckRow>,
    timeline: Vec<Event>,
    threads: Vec<Thread>,
}

const QUERY: &str = r#"query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) {
  id title state isDraft body createdAt mergedAt closedAt additions deletions baseRefName headRefName
  author { login avatarUrl } mergedBy { login }
  labels(first: 20) { nodes { name color } }
  assignees(first: 10) { nodes { login avatarUrl } }
  milestone { title }
  reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login avatarUrl } ... on Team { name } } } }
  latestReviews(first: 20) { nodes { state author { login avatarUrl } } }
  closingIssuesReferences(first: 10) { nodes { id number title url state repository { nameWithOwner } } }
  participants(first: 30) { nodes { login avatarUrl } }
  commits(last: 100) { totalCount nodes { commit { abbreviatedOid messageHeadline committedDate url author { name user { login } } } } }
  files(first: 100) { totalCount nodes { path additions deletions changeType } }
  checks: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename
    ... on CheckRun { name conclusion status detailsUrl }
    ... on StatusContext { context state targetUrl } } } } } } }
  reviewThreads(first: 100) { nodes { isResolved path line comments(first: 20) { nodes { body author { login } pullRequestReview { id } } } } }
  timelineItems(last: 150, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT, LABELED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, CROSS_REFERENCED_EVENT]) { nodes { __typename
    ... on IssueComment { body createdAt url author { login avatarUrl } }
    ... on PullRequestReview { id body state submittedAt url author { login avatarUrl } }
    ... on PullRequestCommit { commit { abbreviatedOid messageHeadline committedDate author { name user { login } } } }
    ... on MergedEvent { createdAt actor { login } commit { abbreviatedOid } }
    ... on ClosedEvent { createdAt actor { login } }
    ... on ReopenedEvent { createdAt actor { login } }
    ... on ReadyForReviewEvent { createdAt actor { login } }
    ... on ConvertToDraftEvent { createdAt actor { login } }
    ... on ReviewRequestedEvent { createdAt actor { login } requestedReviewer { ... on User { login } ... on Team { name } } }
    ... on LabeledEvent { createdAt actor { login } label { name } }
    ... on HeadRefForcePushedEvent { createdAt actor { login } }
    ... on CrossReferencedEvent { createdAt actor { login } source { ... on Issue { number title repository { nameWithOwner } } ... on PullRequest { number title repository { nameWithOwner } } } }
  } }
} } }"#;

fn text(v: &Value) -> String {
    v.as_str().unwrap_or_default().to_string()
}

fn time(v: &Value) -> Option<DateTime<Utc>> {
    v.as_str()?.parse().ok()
}

fn nodes(v: &Value) -> Vec<Value> {
    v["nodes"].as_array().cloned().unwrap_or_default()
}

fn person(v: &Value) -> Person {
    Person { login: v["login"].as_str().unwrap_or("ghost").to_string(), avatar: v["avatarUrl"].as_str().map(str::to_string) }
}

/// The whole PR, read from GitHub. Blocking: run it off the main thread.
fn fetch(repo: &str, number: i64) -> Result<PullData, String> {
    let token = crate::auth::token().ok_or("Sign in to load the pull request.")?;
    let (owner, name) = repo.split_once('/').ok_or("Not a repository")?;
    let data = crate::github::graphql(&token, QUERY, json!({ "owner": owner, "name": name, "number": number })).map_err(|e| e.to_string())?;
    let pr = &data["repository"]["pullRequest"];
    if pr.is_null() {
        return Err("GitHub didn't return the pull request.".into());
    }
    let mut reviewers: Vec<Reviewer> = nodes(&pr["latestReviews"]).iter().map(|r| Reviewer { person: person(&r["author"]), state: text(&r["state"]) }).collect();
    for request in nodes(&pr["reviewRequests"]) {
        let who = &request["requestedReviewer"];
        let login = who["login"].as_str().or(who["name"].as_str()).unwrap_or("").to_string();
        if !login.is_empty() && !reviewers.iter().any(|r| r.person.login == login) {
            reviewers.push(Reviewer { person: Person { login, avatar: who["avatarUrl"].as_str().map(str::to_string) }, state: "REQUESTED".into() });
        }
    }
    let checks = nodes(&pr["checks"]).first().map(|c| nodes(&c["commit"]["statusCheckRollup"]["contexts"])).unwrap_or_default();
    let checks = checks
        .iter()
        .map(|c| {
            let run = c["__typename"] == "CheckRun";
            let outcome = if run {
                match (c["status"].as_str(), c["conclusion"].as_str()) {
                    (Some("COMPLETED"), Some("SUCCESS")) => "success",
                    (Some("COMPLETED"), Some("SKIPPED")) => "skipped",
                    (Some("COMPLETED"), Some("NEUTRAL")) => "neutral",
                    (Some("COMPLETED"), _) => "failure",
                    _ => "pending",
                }
            } else {
                match c["state"].as_str() {
                    Some("SUCCESS") => "success",
                    Some("PENDING") | Some("EXPECTED") => "pending",
                    _ => "failure",
                }
            };
            CheckRow {
                name: if run { text(&c["name"]) } else { text(&c["context"]) },
                outcome,
                url: c[if run { "detailsUrl" } else { "targetUrl" }].as_str().map(str::to_string),
            }
        })
        .collect();
    let commits_list = nodes(&pr["commits"]);
    let commits = commits_list
        .iter()
        .rev()
        .map(|n| {
            let c = &n["commit"];
            CommitRow {
                short: text(&c["abbreviatedOid"]),
                headline: text(&c["messageHeadline"]),
                at: time(&c["committedDate"]),
                url: text(&c["url"]),
                author: c["author"]["user"]["login"].as_str().or(c["author"]["name"].as_str()).unwrap_or("").to_string(),
            }
        })
        .collect();
    let files = nodes(&pr["files"])
        .iter()
        .map(|f| FileRow { path: text(&f["path"]), additions: f["additions"].as_i64().unwrap_or(0), deletions: f["deletions"].as_i64().unwrap_or(0), change: text(&f["changeType"]) })
        .collect();
    let threads = nodes(&pr["reviewThreads"])
        .iter()
        .map(|t| {
            let comments = nodes(&t["comments"]);
            Thread {
                review: comments.first().and_then(|c| c["pullRequestReview"]["id"].as_str().map(str::to_string)),
                path: text(&t["path"]),
                line: t["line"].as_i64(),
                resolved: t["isResolved"].as_bool().unwrap_or(false),
                comments: comments.iter().map(|c| (c["author"]["login"].as_str().unwrap_or("ghost").to_string(), text(&c["body"]))).collect(),
            }
        })
        .collect();
    let actor = |n: &Value| n["actor"]["login"].as_str().unwrap_or("someone").to_string();
    let timeline = nodes(&pr["timelineItems"])
        .iter()
        .filter_map(|n| {
            let at = time(&n["createdAt"]);
            Some(match n["__typename"].as_str()? {
                "IssueComment" => Event::Comment { author: person(&n["author"]), body: text(&n["body"]), at, url: text(&n["url"]) },
                "PullRequestReview" => Event::Review {
                    id: text(&n["id"]),
                    author: person(&n["author"]),
                    state: text(&n["state"]),
                    body: text(&n["body"]),
                    at: time(&n["submittedAt"]),
                    url: text(&n["url"]),
                },
                "PullRequestCommit" => {
                    let c = &n["commit"];
                    Event::Commit {
                        short: text(&c["abbreviatedOid"]),
                        headline: text(&c["messageHeadline"]),
                        at: time(&c["committedDate"]),
                        author: c["author"]["user"]["login"].as_str().or(c["author"]["name"].as_str()).unwrap_or("").to_string(),
                    }
                }
                "MergedEvent" => Event::Note { actor: actor(n), text: format!("merged commit {}", text(&n["commit"]["abbreviatedOid"])), at },
                "ClosedEvent" => Event::Note { actor: actor(n), text: "closed this".into(), at },
                "ReopenedEvent" => Event::Note { actor: actor(n), text: "reopened this".into(), at },
                "ReadyForReviewEvent" => Event::Note { actor: actor(n), text: "marked this ready for review".into(), at },
                "ConvertToDraftEvent" => Event::Note { actor: actor(n), text: "converted this to a draft".into(), at },
                "ReviewRequestedEvent" => {
                    let who = &n["requestedReviewer"];
                    Event::Note { actor: actor(n), text: format!("asked {} for a review", who["login"].as_str().or(who["name"].as_str()).unwrap_or("someone")), at }
                }
                "LabeledEvent" => Event::Note { actor: actor(n), text: format!("added the {} label", text(&n["label"]["name"])), at },
                "HeadRefForcePushedEvent" => Event::Note { actor: actor(n), text: "force-pushed the branch".into(), at },
                "CrossReferencedEvent" => {
                    let s = &n["source"];
                    Event::Note { actor: actor(n), text: format!("mentioned this in {}#{}: {}", text(&s["repository"]["nameWithOwner"]), s["number"].as_i64().unwrap_or(0), text(&s["title"])), at }
                }
                _ => return None,
            })
        })
        .collect();
    Ok(PullData {
        id: text(&pr["id"]),
        title: text(&pr["title"]),
        state: text(&pr["state"]),
        draft: pr["isDraft"].as_bool().unwrap_or(false),
        body: text(&pr["body"]),
        author: person(&pr["author"]),
        created_at: time(&pr["createdAt"]),
        merged_at: time(&pr["mergedAt"]),
        closed_at: time(&pr["closedAt"]),
        merged_by: pr["mergedBy"]["login"].as_str().map(str::to_string),
        base: text(&pr["baseRefName"]),
        head: text(&pr["headRefName"]),
        additions: pr["additions"].as_i64().unwrap_or(0),
        deletions: pr["deletions"].as_i64().unwrap_or(0),
        labels: nodes(&pr["labels"]).iter().map(|l| (text(&l["name"]), text(&l["color"]))).collect(),
        assignees: nodes(&pr["assignees"]).iter().map(person).collect(),
        milestone: pr["milestone"]["title"].as_str().map(str::to_string),
        reviewers,
        linked: nodes(&pr["closingIssuesReferences"])
            .iter()
            .map(|i| Linked {
                id: text(&i["id"]),
                number: i["number"].as_i64().unwrap_or(0),
                title: text(&i["title"]),
                url: text(&i["url"]),
                open: i["state"] == "OPEN",
                repo: text(&i["repository"]["nameWithOwner"]),
            })
            .collect(),
        participants: nodes(&pr["participants"]).iter().map(person).collect(),
        commits,
        commit_total: pr["commits"]["totalCount"].as_u64().unwrap_or(commits_list.len() as u64) as usize,
        files,
        file_total: pr["files"]["totalCount"].as_u64().unwrap_or(0) as usize,
        checks,
        timeline,
        threads,
    })
}

pub struct PullPage {
    pr: PrItem,
    org: String,
    data: Option<PullData>,
    error: Option<String>,
    loading: bool,
    section: Section,
    /// The plans linked to the PR or the issues it closes, with progress.
    plans: Vec<(crate::harness::Doc, bool)>,
    /// Open sessions about it, from the workspace.
    related: Vec<Related>,
    _fetch: Option<Task<()>>,
}

impl PullPage {
    pub fn new(pr: PrItem, org: String, cx: &mut Context<Self>) -> Self {
        let mut page = Self { pr, org, data: None, error: None, loading: false, section: Section::Overview, plans: Vec::new(), related: Vec::new(), _fetch: None };
        page.refresh(cx);
        page
    }

    pub fn pr_id(&self) -> &str {
        &self.pr.id
    }

    /// Its `related_key`, for the sessions about it.
    pub fn key(&self) -> String {
        crate::issues::related_key(&self.pr.repo, self.pr.number)
    }

    /// "#2529 Admin: organisation created date", for its tab.
    pub fn tab_title(&self) -> String {
        format!("#{} {}", self.pr.number, self.data.as_ref().map(|d| d.title.as_str()).unwrap_or(&self.pr.title))
    }

    pub fn set_related(&mut self, related: Vec<Related>, cx: &mut Context<Self>) {
        if self.related != related {
            self.related = related;
            cx.notify();
        }
    }

    /// Fetches the PR, and the harness's plans for it and the issues it
    /// closes, off the main thread.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.loading = true;
        cx.notify();
        let (repo, number, org) = (self.pr.repo.clone(), self.pr.number, self.org.clone());
        self._fetch = Some(cx.spawn(async move |this, cx| {
            let (fetched, plans) = cx
                .background_executor()
                .spawn(async move {
                    let fetched = fetch(&repo, number);
                    let mut items = vec![(repo.clone(), number)];
                    if let Ok(data) = &fetched {
                        items.extend(data.linked.iter().map(|l| (l.repo.clone(), l.number)));
                    }
                    (fetched, crate::harness::linked(&crate::harness::load(&org), &items))
                })
                .await;
            this.update(cx, |page, cx| {
                page.loading = false;
                match fetched {
                    Ok(data) => {
                        page.data = Some(data);
                        page.error = None;
                    }
                    Err(e) => page.error = Some(e),
                }
                page.plans = plans;
                cx.notify();
            })
            .ok();
        }));
    }

    fn avatar(person: &Person, size: f32, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        crate::avatars::avatar(&person.login, person.avatar.as_deref(), size, theme, cx)
    }

    fn when(at: Option<DateTime<Utc>>) -> String {
        at.map(|t| relative_date(t, Utc::now())).unwrap_or_default()
    }

    fn button(id: &'static str, label: &str, theme: &Theme) -> gpui::Stateful<gpui::Div> {
        div().id(id).flex_none().px_2().py_0p5().rounded_md().border_1().border_color(theme.border).text_sm().cursor_pointer().hover(|s| s.bg(theme.row_selected)).child(label.to_string())
    }

    fn state_tint(&self, theme: &Theme) -> (&'static str, Hsla) {
        let state = self.data.as_ref().map(|d| (d.state.as_str(), d.draft));
        match state {
            Some(("MERGED", _)) => ("Merged", theme.slot(5)),
            Some(("CLOSED", _)) => ("Closed", theme.critical()),
            Some((_, true)) => ("Draft", theme.secondary),
            _ => ("Open", theme.good()),
        }
    }

    // MARK: Header

    fn header(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let (state, tint) = self.state_tint(theme);
        let url = self.pr.url.clone();
        let title = self.data.as_ref().map(|d| d.title.clone()).unwrap_or_else(|| self.pr.title.clone());
        let byline = self.data.as_ref().map(|d| {
            let opened = format!("{} opened {}", d.author.login, Self::when(d.created_at));
            match (d.state.as_str(), &d.merged_by) {
                ("MERGED", Some(by)) => format!("{opened}, {by} merged it {}", Self::when(d.merged_at)),
                ("CLOSED", _) => format!("{opened}, closed {}", Self::when(d.closed_at)),
                _ => opened,
            }
        });
        let section = self.section;
        let tab = |id: &'static str, label: String, s: Section, cx: &mut Context<Self>| {
            let on = section == s;
            div()
                .id(id)
                .px_3()
                .py_1p5()
                .cursor_pointer()
                .border_b_2()
                .border_color(if on { theme.orange() } else { gpui::transparent_black() })
                .text_color(if on { theme.fg } else { theme.secondary })
                .when(on, |d| d.font_weight(FontWeight::SEMIBOLD))
                .hover(|d| d.text_color(theme.fg))
                .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                    page.section = s;
                    cx.notify();
                }))
                .child(label)
        };
        let count = |n: Option<usize>| n.map(|n| format!(" {n}")).unwrap_or_default();
        let (commits, checks, files) = match &self.data {
            Some(d) => (Some(d.commit_total), Some(d.checks.len()), Some(d.file_total)),
            None => (None, None, None),
        };
        div()
            .flex_none()
            .flex()
            .flex_col()
            .gap_2()
            .px_6()
            .pt_4()
            .border_b_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_start()
                    .gap_3()
                    .child(div().flex_1().min_w_0().text_2xl().child(format!("{title} ")).child(div().text_color(theme.tertiary).child(format!("#{}", self.pr.number))))
                    .when(self.loading, |d| d.child(div().pt_2().text_sm().text_color(theme.tertiary).child("Loading")))
                    .child(Self::button("pull-refresh", "Refresh", theme).on_click(cx.listener(|page, _: &ClickEvent, _, cx| page.refresh(cx))))
                    .child(Self::button("pull-github", "Open on GitHub", theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .child(div().px_2().py_0p5().rounded_full().bg(tint).text_color(theme.on_selected).font_weight(FontWeight::MEDIUM).child(state))
                    .when_some(byline, |d, b| d.child(div().text_color(theme.secondary).child(b)))
                    .when_some(self.data.as_ref(), |d, data| {
                        d.child(div().px_1p5().rounded_sm().bg(theme.grid).font_family(crate::zed::MONO).text_xs().child(data.base.clone()))
                            .child(div().text_color(theme.tertiary).child("←"))
                            .child(div().px_1p5().rounded_sm().bg(theme.grid).font_family(crate::zed::MONO).text_xs().child(data.head.clone()))
                            .child(div().text_color(theme.good()).child(format!("+{}", data.additions)))
                            .child(div().text_color(theme.critical()).child(format!("−{}", data.deletions)))
                    }),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_1()
                    .child(tab("pull-overview", "Overview".into(), Section::Overview, cx))
                    .child(tab("pull-commits", format!("Commits{}", count(commits)), Section::Commits, cx))
                    .child(tab("pull-checks", format!("Checks{}", count(checks)), Section::Checks, cx))
                    .child(tab("pull-files", format!("Files changed{}", count(files)), Section::Files, cx)),
            )
    }

    // MARK: Overview

    /// What the harness and Gannin know, above GitHub's own: the merge
    /// risk, the sessions about it, Review and Explain, and the plans.
    fn harness_strip(&self, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let risk = crate::risk::level_for(self.data.as_ref().map_or(self.pr.id.as_str(), |d| d.id.as_str()));
        let gannin_reviews: Vec<(&Person, Option<DateTime<Utc>>)> = self
            .data
            .iter()
            .flat_map(|d| d.timeline.iter())
            .filter_map(|e| match e {
                Event::Review { author, body, at, .. } if body.contains("**Merge risk") => Some((author, *at)),
                _ => None,
            })
            .collect();
        let open = self.data.as_ref().is_none_or(|d| d.state == "OPEN");
        let chips: Vec<AnyElement> = self.related.iter().enumerate().map(|(i, r)| related_chip(format!("pull-related-{i}"), r, theme, cx)).collect();
        let plans = crate::harness::plan_rows("pull-plan", &self.plans, theme, cx);
        let (review, explain) = (self.pr.clone(), self.pr.clone());
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .items_center()
                    .gap_3()
                    .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.tertiary).child("GANNIN"))
                    .map(|d| match risk {
                        Some(level) => d.child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap_1p5()
                                .text_sm()
                                .child(div().text_color(theme.secondary).child("Merge risk"))
                                .child(div().font_weight(FontWeight::MEDIUM).text_color(crate::review_panel::risk_tint(level, theme)).child(level.title())),
                        ),
                        None => d.child(div().text_sm().text_color(theme.tertiary).child("Not reviewed with Gannin")),
                    })
                    .when_some(gannin_reviews.last(), |d, (who, at)| {
                        d.child(div().text_sm().text_color(theme.secondary).child(format!("last reviewed by {} {}", who.login, Self::when(*at))))
                    })
                    .children(chips)
                    .child(div().flex_1())
                    .when(open, |d| {
                        d.child(Self::button("pull-review", "Review with Claude", theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(PullAction::Review(review.clone())))))
                            .child(Self::button("pull-explain", "Explain", theme).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(PullAction::Explain(explain.clone())))))
                    }),
            )
            .when(!plans.is_empty(), |d| d.child(div().text_xs().text_color(theme.tertiary).child("PLANS AND REQUIREMENTS")).children(plans))
    }

    fn card(theme: &Theme) -> gpui::Div {
        div().flex().flex_col().rounded_lg().border_1().border_color(theme.border).overflow_hidden()
    }

    /// A card's head: who, what, and when, the time a link to it on
    /// GitHub when it has one.
    fn card_head(author: &Person, extra: AnyElement, at: Option<DateTime<Utc>>, link: Option<(String, String)>, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_3()
            .py_1p5()
            .bg(theme.tile)
            .border_b_1()
            .border_color(theme.border)
            .text_sm()
            .child(Self::avatar(author, 18., theme, cx))
            .child(div().font_weight(FontWeight::SEMIBOLD).child(author.login.clone()))
            .child(extra)
            .map(|d| match link {
                Some((id, url)) => d.child(
                    div()
                        .id(SharedString::from(id))
                        .text_color(theme.secondary)
                        .cursor_pointer()
                        .hover(|s| s.text_color(theme.selected))
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .child(Self::when(at)),
                ),
                None => d.child(div().text_color(theme.secondary).child(Self::when(at))),
            })
    }

    fn timeline(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let mut out = Vec::new();
        for (i, event) in data.timeline.iter().enumerate() {
            let element = match event {
                Event::Comment { author, body, at, url } => Self::card(theme)
                    .child(Self::card_head(author, div().into_any_element(), *at, Some((format!("pull-comment-link-{i}"), url.clone())), theme, cx))
                    .child(div().p_3().child(markdown(&format!("pull-comment-{i}"), body, theme)))
                    .into_any_element(),
                Event::Review { id, author, state, body, at, url } => {
                    let (word, tint) = match state.as_str() {
                        "APPROVED" => ("approved these changes", theme.good()),
                        "CHANGES_REQUESTED" => ("requested changes", theme.orange()),
                        "DISMISSED" => ("had a review dismissed", theme.secondary),
                        _ => ("reviewed", theme.secondary),
                    };
                    let threads: Vec<&Thread> = data.threads.iter().filter(|t| t.review.as_deref() == Some(id.as_str())).collect();
                    if body.trim().is_empty() && threads.is_empty() {
                        Self::note(theme, &author.login, word, *at, Some(tint)).into_any_element()
                    } else {
                        Self::card(theme)
                            .border_color(tint.opacity(0.5))
                            .child(Self::card_head(author, div().text_color(tint).child(word).into_any_element(), *at, Some((format!("pull-review-link-{i}"), url.clone())), theme, cx))
                            .when(!body.trim().is_empty(), |d| d.child(div().p_3().child(markdown(&format!("pull-review-{i}"), body, theme))))
                            .children(threads.into_iter().enumerate().map(|(t, thread)| Self::thread(thread, &format!("{i}-{t}"), theme)))
                            .into_any_element()
                    }
                }
                Event::Commit { short, headline, at, author } => div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .text_sm()
                    .text_color(theme.secondary)
                    .child(div().flex_none().text_color(theme.tertiary).child("◦"))
                    .child(div().flex_none().text_color(theme.fg).child(author.clone()))
                    .child(div().flex_1().min_w_0().truncate().child(headline.clone()))
                    .child(div().flex_none().font_family(crate::zed::MONO).text_xs().child(short.clone()))
                    .child(div().flex_none().child(Self::when(*at)))
                    .into_any_element(),
                Event::Note { actor, text, at } => Self::note(theme, actor, text, *at, None).into_any_element(),
            };
            out.push(element);
        }
        out
    }

    fn note(theme: &Theme, actor: &str, text: &str, at: Option<DateTime<Utc>>, tint: Option<Hsla>) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap_2()
            .px_3()
            .text_sm()
            .text_color(theme.secondary)
            .child(div().flex_none().size(px(6.)).rounded_full().bg(tint.unwrap_or(theme.tertiary)))
            .child(div().flex_none().text_color(theme.fg).font_weight(FontWeight::MEDIUM).child(actor.to_string()))
            .child(div().flex_1().min_w_0().truncate().child(text.to_string()))
            .child(div().flex_none().child(Self::when(at)))
    }

    /// A review's thread on a line: where, whether it's resolved, and what
    /// was said.
    fn thread(thread: &Thread, key: &str, theme: &Theme) -> impl IntoElement {
        div()
            .mx_3()
            .mb_3()
            .flex()
            .flex_col()
            .gap_1()
            .p_2()
            .rounded_md()
            .border_1()
            .border_color(theme.border)
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .child(div().flex_1().min_w_0().truncate().font_family(crate::zed::MONO).text_xs().child(match thread.line {
                        Some(line) => format!("{} line {line}", thread.path),
                        None => thread.path.clone(),
                    }))
                    .child(if thread.resolved { pill("Resolved", theme.secondary).into_any_element() } else { pill("Open", theme.orange()).into_any_element() }),
            )
            .when(!thread.resolved, |d| {
                d.children(thread.comments.iter().enumerate().map(|(i, (who, body))| {
                    div()
                        .flex()
                        .flex_col()
                        .gap_0p5()
                        .pt_1()
                        .child(div().text_xs().font_weight(FontWeight::SEMIBOLD).child(who.clone()))
                        .child(markdown(&format!("pull-thread-{key}-{i}"), body, theme))
                }))
            })
    }

    fn overview(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let Some(data) = &self.data else {
            return div().p_4().text_color(theme.secondary).child(self.error.clone().unwrap_or_else(|| "Loading the pull request".into())).into_any_element();
        };
        let timeline = self.timeline(data, theme, cx);
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(self.harness_strip(theme, cx))
            .child(
                Self::card(theme)
                    .child(Self::card_head(&data.author, div().child("opened this").into_any_element(), data.created_at, None, theme, cx))
                    .child(div().p_3().child(if data.body.trim().is_empty() {
                        div().text_color(theme.tertiary).child("No description").into_any_element()
                    } else {
                        markdown("pull-body", &data.body, theme)
                    })),
            )
            .children(timeline)
            .into_any_element()
    }

    // MARK: Sidebar

    fn sidebar(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> impl IntoElement {
        let group = |title: &str| div().flex().flex_col().gap_1p5().pb_3().border_b_1().border_color(theme.border).child(div().text_xs().font_weight(FontWeight::SEMIBOLD).text_color(theme.secondary).child(title.to_string()));
        let none = |text: &str| div().text_sm().text_color(theme.tertiary).child(text.to_string());
        let approvals = data.reviewers.iter().filter(|r| r.state == "APPROVED").count();
        let changes = data.reviewers.iter().filter(|r| r.state == "CHANGES_REQUESTED").count();
        let unresolved = data.threads.iter().filter(|t| !t.resolved).count();
        let row = |label: &str, n: usize| div().flex().flex_row().text_sm().child(div().flex_1().child(label.to_string())).child(div().text_color(theme.secondary).child(n.to_string()));
        let mut reviewers = group("Reviewers");
        if data.reviewers.is_empty() {
            reviewers = reviewers.child(none("No reviews"));
        }
        for r in &data.reviewers {
            let (mark, tint) = match r.state.as_str() {
                "APPROVED" => ("✓", theme.good()),
                "CHANGES_REQUESTED" => ("±", theme.orange()),
                "REQUESTED" => ("●", gpui::rgb(0xEDA100).into()),
                _ => ("💬", theme.secondary),
            };
            reviewers = reviewers.child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .child(Self::avatar(&r.person, 18., theme, cx))
                    .child(div().flex_1().min_w_0().truncate().child(r.person.login.clone()))
                    .child(div().text_color(tint).child(mark)),
            );
        }
        let mut assignees = group("Assignees");
        if data.assignees.is_empty() {
            assignees = assignees.child(none("No one"));
        }
        for a in &data.assignees {
            assignees = assignees.child(div().flex().flex_row().items_center().gap_2().text_sm().child(Self::avatar(a, 18., theme, cx)).child(a.login.clone()));
        }
        let labels = group("Labels").child(if data.labels.is_empty() {
            none("None yet").into_any_element()
        } else {
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .gap_1()
                .children(data.labels.iter().map(|(name, color)| {
                    let tint: Hsla = u32::from_str_radix(color, 16).map(|c| gpui::rgb(c).into()).unwrap_or(theme.secondary);
                    div().px_1p5().rounded_full().text_xs().border_1().border_color(tint).text_color(tint).child(name.clone())
                }))
                .into_any_element()
        });
        let milestone = group("Milestone").child(match &data.milestone {
            Some(m) => div().text_sm().child(m.clone()),
            None => none("No milestone"),
        });
        let mut development = group("Development");
        if data.linked.is_empty() {
            development = development.child(none("No linked issues"));
        }
        for (i, l) in data.linked.iter().enumerate() {
            let (id, url) = (l.id.clone(), l.url.clone());
            development = development.child(
                div()
                    .id(("pull-linked", i))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .text_sm()
                    .cursor_pointer()
                    .hover(|s| s.text_color(theme.selected))
                    .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.emit(OpenLinked { id: id.clone(), url: url.clone() })))
                    .child(div().flex_none().size(px(7.)).rounded_full().bg(if l.open { theme.good() } else { theme.slot(5) }))
                    .child(div().flex_1().min_w_0().truncate().child(l.title.clone()))
                    .child(div().flex_none().text_color(theme.secondary).child(format!("#{}", l.number))),
            );
        }
        let mut participants = div().flex().flex_row().flex_wrap().gap_1();
        for p in &data.participants {
            participants = participants.child(Self::avatar(p, 22., theme, cx));
        }
        div()
            .w(px(280.))
            .flex_none()
            .flex()
            .flex_col()
            .gap_3()
            .child(group("Activity").child(row("Approvals", approvals)).child(row("Changes requested", changes)).child(row("Unresolved threads", unresolved)).child(row("Commits", data.commit_total)))
            .child(reviewers)
            .child(assignees)
            .child(labels)
            .child(milestone)
            .child(development)
            .child(group(&format!("{} participants", data.participants.len())).child(participants))
    }

    // MARK: Other sections

    fn commits(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .children(data.commits.iter().enumerate().map(|(i, c)| {
                let url = c.url.clone();
                div()
                    .id(("pull-commit", i))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_3()
                    .py_2()
                    .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.tile))
                    .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                    .child(div().flex_1().min_w_0().flex().flex_col().child(div().truncate().child(c.headline.clone())).child(div().text_xs().text_color(theme.secondary).child(format!("{} committed {}", c.author, Self::when(c.at)))))
                    .child(div().flex_none().font_family(crate::zed::MONO).text_xs().text_color(theme.secondary).child(c.short.clone()))
            }))
            .into_any_element()
    }

    fn checks(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        if data.checks.is_empty() {
            return div().text_color(theme.secondary).child("No checks on the latest commit.").into_any_element();
        }
        let mut checks: Vec<&CheckRow> = data.checks.iter().collect();
        let rank = |o: &str| match o {
            "failure" => 0,
            "pending" => 1,
            "success" => 2,
            _ => 3,
        };
        checks.sort_by_key(|c| rank(c.outcome));
        div()
            .flex()
            .flex_col()
            .rounded_lg()
            .border_1()
            .border_color(theme.border)
            .children(checks.into_iter().enumerate().map(|(i, c)| {
                let tint = match c.outcome {
                    "success" => theme.good(),
                    "failure" => theme.critical(),
                    "pending" => gpui::rgb(0xEDA100).into(),
                    _ => theme.tertiary,
                };
                let url = c.url.clone();
                div()
                    .id(("pull-check", i))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_1p5()
                    .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                    .when_some(url, |d, url| d.cursor_pointer().hover(|s| s.bg(theme.tile)).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))))
                    .child(div().flex_none().size(px(8.)).rounded_full().bg(tint))
                    .child(div().flex_1().min_w_0().truncate().child(c.name.clone()))
                    .child(div().flex_none().text_sm().text_color(tint).child(c.outcome))
            }))
            .into_any_element()
    }

    fn files(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let files_url = format!("{}/files", self.pr.url);
        div()
            .flex()
            .flex_col()
            .gap_2()
            .when(data.file_total > data.files.len(), |d| d.child(div().text_sm().text_color(theme.secondary).child(format!("The first {} of {} files.", data.files.len(), data.file_total))))
            .child(
                div().flex().flex_col().rounded_lg().border_1().border_color(theme.border).children(data.files.iter().enumerate().map(|(i, f)| {
                    let url = files_url.clone();
                    let (word, tint) = match f.change.as_str() {
                        "ADDED" => ("added", theme.good()),
                        "DELETED" => ("deleted", theme.critical()),
                        "RENAMED" => ("renamed", theme.blue()),
                        _ => ("", theme.secondary),
                    };
                    div()
                        .id(("pull-file", i))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap_3()
                        .px_3()
                        .py_1p5()
                        .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                        .cursor_pointer()
                        .hover(|s| s.bg(theme.tile))
                        .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url)))
                        .child(div().flex_1().min_w_0().truncate().font_family(crate::zed::MONO).text_sm().child(f.path.clone()))
                        .when(!word.is_empty(), |d| d.child(div().flex_none().text_xs().text_color(tint).child(word)))
                        .child(div().flex_none().text_sm().text_color(theme.good()).child(format!("+{}", f.additions)))
                        .child(div().flex_none().text_sm().text_color(theme.critical()).child(format!("−{}", f.deletions)))
                })),
            )
            .into_any_element()
    }
}

impl Render for PullPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::for_window(window);
        let body: AnyElement = match (&self.data, self.section) {
            (None, _) | (_, Section::Overview) => {
                let overview = self.overview(&theme, cx);
                let side = self.data.as_ref().map(|d| self.sidebar(d, &theme, cx).into_any_element());
                div().flex().flex_row().flex_wrap().items_start().gap_6().child(div().flex_1().min_w(px(480.)).max_w(px(960.)).child(overview)).children(side).into_any_element()
            }
            (Some(data), Section::Commits) => self.commits(data, &theme, cx),
            (Some(data), Section::Checks) => self.checks(data, &theme, cx),
            (Some(data), Section::Files) => self.files(data, &theme, cx),
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(self.header(&theme, cx))
            .when_some(self.error.clone().filter(|_| self.data.is_some()), |d, e| d.child(div().px_6().py_1().text_sm().text_color(theme.critical()).child(format!("Couldn't refresh: {e}"))))
            .child(div().id(SharedString::from("pull-body-scroll")).flex_1().min_h_0().overflow_y_scroll().px_6().py_4().child(body))
    }
}
