//! A pull request as a page of its own (the PR drawer's Open in Page). Not
//! GitHub's page again: the Overview answers Gannin's question, where it
//! stands and whose move it is. It leads with that one line and its facts
//! (open threads, checks, approvals, merge risk), then what Needs attention
//! (changes requested, failing checks, open threads, reviewers yet to
//! review), each with who it waits on and since when; then what the harness
//! knows, the description, and the timeline in rounds (a push of commits
//! and what followed), newest first, with those since the viewer last
//! looked marked and open, and bots, review requests and labels folded to
//! one line. Commits, Checks and Files changed are tabs; the sidebar has
//! the reviewers, assignees, labels, milestone, linked issues and
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

/// A linked issue was clicked: its drawer, a stub the drawer fills from
/// GitHub when it isn't stored.
#[derive(Clone)]
pub struct OpenLinked {
    pub id: String,
    pub url: String,
    pub repo: String,
    pub number: i64,
    pub title: String,
    pub open: bool,
}

/// A synced issue that the PR closes or that mentions it, found in the
/// local issue cache (`IssueStore::about_pull`).
#[derive(Clone, PartialEq)]
pub struct LocalIssue {
    pub id: String,
    pub number: i64,
    pub title: String,
    pub url: String,
    pub repo: String,
    pub open: bool,
    /// It's closed by the PR rather than only mentioned.
    pub closes: bool,
}

/// A PR in Related was clicked: its drawer.
pub struct OpenPull(pub PrItem);

impl EventEmitter<PullAction> for PullPage {}
impl EventEmitter<OpenPull> for PullPage {}
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
    /// An app's account (CodeRabbit, Dependabot): its comments fold away.
    bot: bool,
}

struct Reviewer {
    person: Person,
    /// When they reviewed, or were asked to for one who hasn't.
    at: Option<DateTime<Utc>>,
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, or REQUESTED for
    /// one asked who hasn't reviewed.
    state: String,
}

struct Linked {
    /// A pull request rather than an issue.
    pull: bool,
    id: String,
    number: i64,
    title: String,
    url: String,
    open: bool,
    repo: String,
}

struct CommitRow {
    /// The full SHA, to read the commit.
    oid: String,
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
    /// A check run's ID, to read its report and log; none for a status.
    id: Option<i64>,
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
    /// Who started it, who said the last word and when, and its link.
    started_by: String,
    last_by: String,
    last_at: Option<DateTime<Utc>>,
    url: String,
}

enum Event {
    Comment { author: Person, body: String, at: Option<DateTime<Utc>>, url: String },
    Review { id: String, author: Person, state: String, body: String, at: Option<DateTime<Utc>>, url: String },
    Commit { short: String, headline: String, at: Option<DateTime<Utc>>, author: String },
    /// `noise` for what folds away in a round: review requests, labels.
    Note { actor: String, text: String, at: Option<DateTime<Utc>>, noise: bool },
}

impl Event {
    fn at(&self) -> Option<DateTime<Utc>> {
        match self {
            Event::Comment { at, .. } | Event::Review { at, .. } | Event::Commit { at, .. } | Event::Note { at, .. } => *at,
        }
    }

    /// What a round folds into one line: bots, a bare bot command
    /// ("@ctrl-hub-bot run tests"), review requests and labels.
    fn is_noise(&self) -> bool {
        match self {
            Event::Comment { author, body, .. } => {
                let body = body.trim();
                author.bot || (body.starts_with('@') && !body.contains('\n') && body.len() <= 60)
            }
            Event::Review { author, .. } => author.bot,
            Event::Note { noise, .. } => *noise,
            Event::Commit { .. } => false,
        }
    }
}

struct PullData {
    /// Who's signed in, for "since you looked".
    viewer: String,
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
    /// Issues and PRs that mention this one (GitHub's cross-references),
    /// newest first, without those it closes.
    mentions: Vec<Linked>,
    participants: Vec<Person>,
    commits: Vec<CommitRow>,
    commit_total: usize,
    files: Vec<FileRow>,
    file_total: usize,
    checks: Vec<CheckRow>,
    timeline: Vec<Event>,
    threads: Vec<Thread>,
}

const QUERY: &str = r#"query($owner: String!, $name: String!, $number: Int!) { viewer { login } repository(owner: $owner, name: $name) { pullRequest(number: $number) {
  id title state isDraft body createdAt mergedAt closedAt additions deletions baseRefName headRefName
  author { login avatarUrl } mergedBy { login }
  labels(first: 20) { nodes { name color } }
  assignees(first: 10) { nodes { login avatarUrl } }
  milestone { title }
  reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login avatarUrl } ... on Team { name } } } }
  latestReviews(first: 20) { nodes { state submittedAt author { login avatarUrl } } }
  closingIssuesReferences(first: 10) { nodes { id number title url state repository { nameWithOwner } } }
  participants(first: 30) { nodes { login avatarUrl } }
  commits(last: 100) { totalCount nodes { commit { oid abbreviatedOid messageHeadline committedDate url author { name user { login } } } } }
  files(first: 100) { totalCount nodes { path additions deletions changeType } }
  checks: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename
    ... on CheckRun { databaseId name conclusion status detailsUrl }
    ... on StatusContext { context state targetUrl } } } } } } }
  reviewThreads(first: 100) { nodes { isResolved path line comments(first: 20) { nodes { body createdAt url author { login } pullRequestReview { id } } } } }
  timelineItems(last: 150, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT, LABELED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, CROSS_REFERENCED_EVENT]) { nodes { __typename
    ... on IssueComment { body createdAt url author { __typename login avatarUrl } }
    ... on PullRequestReview { id body state submittedAt url author { __typename login avatarUrl } }
    ... on PullRequestCommit { commit { abbreviatedOid messageHeadline committedDate author { name user { login } } } }
    ... on MergedEvent { createdAt actor { login } commit { abbreviatedOid } }
    ... on ClosedEvent { createdAt actor { login } }
    ... on ReopenedEvent { createdAt actor { login } }
    ... on ReadyForReviewEvent { createdAt actor { login } }
    ... on ConvertToDraftEvent { createdAt actor { login } }
    ... on ReviewRequestedEvent { createdAt actor { login } requestedReviewer { ... on User { login } ... on Team { name } } }
    ... on LabeledEvent { createdAt actor { login } label { name } }
    ... on HeadRefForcePushedEvent { createdAt actor { login } }
    ... on CrossReferencedEvent { createdAt actor { login } source { __typename ... on Issue { id number title url state repository { nameWithOwner } } ... on PullRequest { id number title url state repository { nameWithOwner } } } }
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
    let login = v["login"].as_str().unwrap_or("ghost").to_string();
    Person { bot: v["__typename"] == "Bot" || login.ends_with("[bot]"), login, avatar: v["avatarUrl"].as_str().map(str::to_string) }
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
    // When each reviewer was last asked, from the timeline.
    let mut asked: std::collections::HashMap<String, DateTime<Utc>> = std::collections::HashMap::new();
    for n in nodes(&pr["timelineItems"]).iter().filter(|n| n["__typename"] == "ReviewRequestedEvent") {
        let who = &n["requestedReviewer"];
        if let (Some(login), Some(at)) = (who["login"].as_str().or(who["name"].as_str()), time(&n["createdAt"])) {
            asked.insert(login.to_string(), at);
        }
    }
    let mut reviewers: Vec<Reviewer> = nodes(&pr["latestReviews"]).iter().map(|r| Reviewer { person: person(&r["author"]), at: time(&r["submittedAt"]), state: text(&r["state"]) }).collect();
    for request in nodes(&pr["reviewRequests"]) {
        let who = &request["requestedReviewer"];
        let login = who["login"].as_str().or(who["name"].as_str()).unwrap_or("").to_string();
        if !login.is_empty() && !reviewers.iter().any(|r| r.person.login == login) {
            reviewers.push(Reviewer { at: asked.get(&login).copied(), person: Person { login, avatar: who["avatarUrl"].as_str().map(str::to_string), bot: false }, state: "REQUESTED".into() });
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
                id: if run { c["databaseId"].as_i64() } else { None },
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
                oid: text(&c["oid"]),
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
            let login = |c: Option<&Value>| c.and_then(|c| c["author"]["login"].as_str()).unwrap_or("ghost").to_string();
            Thread {
                started_by: login(comments.first()),
                last_by: login(comments.last()),
                last_at: comments.last().and_then(|c| time(&c["createdAt"])),
                url: comments.first().map(|c| text(&c["url"])).unwrap_or_default(),
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
                "MergedEvent" => Event::Note { noise: false, actor: actor(n), text: format!("merged commit {}", text(&n["commit"]["abbreviatedOid"])), at },
                "ClosedEvent" => Event::Note { noise: false, actor: actor(n), text: "closed this".into(), at },
                "ReopenedEvent" => Event::Note { noise: false, actor: actor(n), text: "reopened this".into(), at },
                "ReadyForReviewEvent" => Event::Note { noise: false, actor: actor(n), text: "marked this ready for review".into(), at },
                "ConvertToDraftEvent" => Event::Note { noise: false, actor: actor(n), text: "converted this to a draft".into(), at },
                "ReviewRequestedEvent" => {
                    let who = &n["requestedReviewer"];
                    Event::Note { noise: true, actor: actor(n), text: format!("asked {} for a review", who["login"].as_str().or(who["name"].as_str()).unwrap_or("someone")), at }
                }
                "LabeledEvent" => Event::Note { noise: true, actor: actor(n), text: format!("added the {} label", text(&n["label"]["name"])), at },
                "HeadRefForcePushedEvent" => Event::Note { noise: false, actor: actor(n), text: "force-pushed the branch".into(), at },
                "CrossReferencedEvent" => {
                    let s = &n["source"];
                    Event::Note { noise: false, actor: actor(n), text: format!("mentioned this in {}#{}: {}", text(&s["repository"]["nameWithOwner"]), s["number"].as_i64().unwrap_or(0), text(&s["title"])), at }
                }
                _ => return None,
            })
        })
        .collect();
    let closing: Vec<String> = nodes(&pr["closingIssuesReferences"]).iter().map(|i| text(&i["id"])).collect();
    let mut mentions: Vec<Linked> = Vec::new();
    for n in nodes(&pr["timelineItems"]).iter().rev().filter(|n| n["__typename"] == "CrossReferencedEvent") {
        let s = &n["source"];
        let id = text(&s["id"]);
        if id.is_empty() || id == text(&pr["id"]) || closing.contains(&id) || mentions.iter().any(|m| m.id == id) {
            continue;
        }
        mentions.push(Linked {
            pull: s["__typename"] == "PullRequest",
            id,
            number: s["number"].as_i64().unwrap_or(0),
            title: text(&s["title"]),
            url: text(&s["url"]),
            open: s["state"] == "OPEN",
            repo: text(&s["repository"]["nameWithOwner"]),
        });
    }
    Ok(PullData {
        viewer: text(&data["viewer"]["login"]),
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
                pull: false,
                id: text(&i["id"]),
                number: i["number"].as_i64().unwrap_or(0),
                title: text(&i["title"]),
                url: text(&i["url"]),
                open: i["state"] == "OPEN",
                repo: text(&i["repository"]["nameWithOwner"]),
            })
            .collect(),
        mentions,
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

/// Which piece of the page to draw: the whole page, or one part of it for
/// the review panel to lay out itself (the merged PR and review sketch in
/// Review Preview).
#[derive(Clone, Copy, PartialEq)]
pub enum Part {
    Whole,
    Description,
    Timeline,
    Commits,
    Checks,
    Sidebar,
}

#[derive(Clone, Copy, PartialEq)]
pub enum AttentionKind {
    ChangesRequested,
    /// A failing check: it blocks the merge.
    Failing,
    Thread,
    Unreviewed,
}

/// One thing open on GitHub, whose move it is and since when.
#[derive(Clone)]
pub struct AttentionItem {
    pub kind: AttentionKind,
    pub text: String,
    pub detail: Option<String>,
    pub owner: String,
    pub since: Option<DateTime<Utc>>,
    pub url: Option<String>,
}

/// A made-up pull request for the merged sketch: the same change as the
/// Review Preview's review, with one round of review, the author's reply
/// and a second push.
fn sample(repo: &str, number: i64, title: &str) -> PullData {
    let now = Utc::now();
    let ago = |hours: i64| Some(now - chrono::Duration::hours(hours));
    let url = format!("https://github.com/{repo}/pull/{number}");
    let who = |login: &str| Person { login: login.into(), avatar: None, bot: false };
    let commit = |short: &str, headline: &str, hours: i64| CommitRow { oid: short.into(), short: short.into(), headline: headline.into(), at: ago(hours), url: format!("{url}/commits"), author: "alex".into() };
    let commits = vec![
        commit("a1c3f9e", "Add the idempotency_keys table", 50),
        commit("b7d2e10", "Check the key before charging", 49),
        commit("c4e8a77", "Tests for retries and replays", 48),
        commit("d9f1b02", "One transaction around the check and the insert", 6),
        commit("e2a6c35", "Expire keys after 24 hours", 5),
    ];
    let as_event = |c: &CommitRow| Event::Commit { short: c.short.clone(), headline: c.headline.clone(), at: c.at, author: c.author.clone() };
    let mut timeline: Vec<Event> = commits[..3].iter().map(as_event).collect();
    timeline.push(Event::Note { actor: "alex".into(), text: "asked sam and priya to review".into(), at: ago(48), noise: true });
    timeline.push(Event::Review { id: "r1".into(), author: who("sam"), state: "CHANGES_REQUESTED".into(), body: "The check and the insert can race: see the thread on payments.rs.".into(), at: ago(30), url: url.clone() });
    timeline.push(Event::Comment { author: who("alex"), body: "Good catch. Fixing it with one transaction, and adding expiry while I'm there.".into(), at: ago(28), url: url.clone() });
    timeline.extend(commits[3..].iter().map(as_event));
    timeline.push(Event::Comment { author: Person { login: "ci-bot".into(), avatar: None, bot: true }, body: "Coverage 84% (+1.2%)".into(), at: ago(5), url: url.clone() });
    let thread = |path: &str, line: i64, resolved: bool, comments: &[(&str, &str)], hours: i64| Thread {
        review: Some("r1".into()),
        path: path.into(),
        line: Some(line),
        resolved,
        comments: comments.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect(),
        started_by: comments[0].0.into(),
        last_by: comments[comments.len() - 1].0.into(),
        last_at: ago(hours),
        url: url.clone(),
    };
    let file = |path: &str, additions: i64, deletions: i64, change: &str| FileRow { path: path.into(), additions, deletions, change: change.into() };
    let check = |name: &str, outcome: &'static str| CheckRow { id: None, name: name.into(), outcome, url: Some(format!("{url}/checks")) };
    PullData {
        viewer: "jo".into(),
        id: format!("preview-{number}"),
        title: title.into(),
        state: "OPEN".into(),
        draft: false,
        body: "Retried payment requests can charge a card twice. This adds an `Idempotency-Key` header: the first request with a key is processed and its response kept; a retry with the same key gets that response back.\n\nCloses #198.".into(),
        author: who("alex"),
        created_at: ago(50),
        merged_at: None,
        closed_at: None,
        merged_by: None,
        base: "main".into(),
        head: "alex/idempotency-keys".into(),
        additions: 412,
        deletions: 37,
        labels: vec![("payments".into(), "0e8a16".into()), ("api".into(), "1d76db".into())],
        assignees: vec![who("alex")],
        milestone: Some("Q4 hardening".into()),
        reviewers: vec![
            Reviewer { person: who("sam"), at: ago(30), state: "CHANGES_REQUESTED".into() },
            Reviewer { person: who("priya"), at: ago(48), state: "REQUESTED".into() },
        ],
        mentions: vec![
            Linked { pull: true, id: "preview-pr-221".into(), number: 221, title: "Send the Idempotency-Key from the mobile client".into(), url: "https://github.com/acme/mobile/pull/221".into(), open: true, repo: "acme/mobile".into() },
            Linked { pull: false, id: "preview-issue-203".into(), number: 203, title: "Document retries in the payments API guide".into(), url: format!("https://github.com/{repo}/issues/203"), open: true, repo: repo.into() },
        ],
        linked: vec![Linked { pull: false, id: "preview-issue-198".into(), number: 198, title: "Retried payments can charge twice".into(), url: format!("https://github.com/{repo}/issues/198"), open: true, repo: repo.into() }],
        participants: vec![who("alex"), who("sam"), who("priya")],
        commit_total: commits.len(),
        commits,
        files: vec![
            file("migrations/0042_idempotency_keys.sql", 18, 0, "ADDED"),
            file("migrations/0043_key_expiry.sql", 6, 0, "ADDED"),
            file("src/store/keys.rs", 96, 0, "ADDED"),
            file("src/jobs/sweep_keys.rs", 41, 0, "ADDED"),
            file("src/api/payments.rs", 88, 31, "MODIFIED"),
            file("src/api/errors.rs", 12, 6, "MODIFIED"),
            file("tests/payments_idempotency.rs", 151, 0, "ADDED"),
        ],
        file_total: 7,
        checks: vec![check("build", "success"), check("unit tests", "success"), check("lint", "success"), check("e2e", "failure")],
        timeline,
        threads: vec![
            thread("src/api/payments.rs", 88, true, &[("sam", "The lookup and the insert can race."), ("alex", "Both in one transaction now.")], 6),
            thread("src/api/errors.rs", 57, false, &[("sam", "Say which request the key belonged to.")], 30),
            thread("src/store/keys.rs", 31, false, &[("sam", "Do keys ever expire?"), ("alex", "They do now, after 24 hours. Long enough?")], 5),
        ],
    }
}

pub struct PullPage {
    pr: PrItem,
    org: String,
    part: Part,
    /// Shared with its parts, which draw from the same fetch.
    data: Option<std::rc::Rc<PullData>>,
    error: Option<String>,
    loading: bool,
    section: Section,
    /// The harness's plans and requirements about the PR or anything
    /// related to it (what it closes, what mentions it, the synced issues
    /// about it), with progress; from `docs`.
    plans: Vec<(crate::harness::Doc, bool)>,
    /// The org's harness documents, read when the PR is fetched.
    docs: std::sync::Arc<Vec<crate::harness::Doc>>,
    /// Open sessions about it, from the workspace.
    related: Vec<Related>,
    /// Synced issues it closes or that mention it, from the local cache.
    local: Vec<LocalIssue>,
    /// The body's width as last laid out, for how many columns it takes.
    width: std::rc::Rc<std::cell::Cell<f32>>,
    /// Rounds opened or closed by the person, by index; the rest follow
    /// whether they're the latest or new since the viewer looked.
    rounds_open: std::collections::HashMap<usize, bool>,
    /// Rounds whose folded events (bots, requests, labels) are shown.
    noise_open: std::collections::HashSet<usize>,
    /// The parts a review panel lays out (`part_of`), kept up to date with
    /// this page's fetch, plans and Related.
    parts: Vec<gpui::WeakEntity<PullPage>>,
    /// The page as it shows: the review panel with this PR merged in. Its
    /// events go on from here, as the page's own.
    merged: Option<gpui::Entity<crate::review_panel::ReviewPanel>>,
    /// The commit opened in Commits, by SHA, and the check opened in
    /// Checks, by name: each shown under its list.
    commit_view: Option<(String, gpui::Entity<crate::pr_diff::CommitDiff>)>,
    check_view: Option<(String, gpui::Entity<crate::check_detail::CheckDetail>)>,
    _fetch: Option<Task<()>>,
}

impl PullPage {
    pub fn new(pr: PrItem, org: String, cx: &mut Context<Self>) -> Self {
        let mut page = Self { pr, org, part: Part::Whole, data: None, error: None, loading: false, section: Section::Overview, plans: Vec::new(), docs: Default::default(), related: Vec::new(), local: Vec::new(), width: Default::default(), rounds_open: Default::default(), noise_open: Default::default(), parts: Vec::new(), merged: None, commit_view: None, check_view: None, _fetch: None };
        page.refresh(cx);
        page
    }

    /// One part of a made-up pull request, never fetched: for the merged
    /// sketch in Review Preview.
    pub fn preview(repo: &str, number: i64, title: &str, part: Part) -> Self {
        let pr = PrItem::stub(&format!("preview-{number}"), repo, number, title, &format!("https://github.com/{repo}/pull/{number}"));
        Self {
            pr,
            org: String::new(),
            part,
            data: Some(std::rc::Rc::new(sample(repo, number, title))),
            error: None,
            loading: false,
            section: Section::Overview,
            plans: Vec::new(),
            docs: Default::default(),
            related: Vec::new(),
            local: Vec::new(),
            width: Default::default(),
            rounds_open: Default::default(),
            noise_open: Default::default(),
            parts: Vec::new(),
            merged: None,
            commit_view: None,
            check_view: None,
            _fetch: None,
        }
    }

    /// One part of this page, drawn from its fetch: it never fetches, and
    /// follows this page as it refreshes.
    pub fn part_of(&mut self, part: Part, cx: &mut Context<Self>) -> gpui::Entity<PullPage> {
        let entity = cx.new(|_| Self {
            pr: self.pr.clone(),
            org: self.org.clone(),
            part,
            data: self.data.clone(),
            error: self.error.clone(),
            loading: self.loading,
            section: Section::Overview,
            plans: self.plans.clone(),
            docs: self.docs.clone(),
            related: self.related.clone(),
            local: self.local.clone(),
            width: Default::default(),
            rounds_open: Default::default(),
            noise_open: Default::default(),
            parts: Vec::new(),
            merged: None,
            commit_view: None,
            check_view: None,
            _fetch: None,
        });
        self.parts.push(entity.downgrade());
        entity
    }

    /// Passes this page's state on to its parts.
    fn share(&mut self, cx: &mut Context<Self>) {
        self.parts.retain(|p| p.upgrade().is_some());
        for part in &self.parts {
            let _ = part.update(cx, |p, cx| {
                p.data = self.data.clone();
                p.error = self.error.clone();
                p.loading = self.loading;
                p.plans = self.plans.clone();
                p.docs = self.docs.clone();
                p.related = self.related.clone();
                p.local = self.local.clone();
                cx.notify();
            });
        }
    }

    /// Shows the PR as `panel` (the review panel with it merged in), whose
    /// events (Review with Claude, Explain, Related's links) go on as this
    /// page's.
    pub fn set_merged(&mut self, panel: gpui::Entity<crate::review_panel::ReviewPanel>, cx: &mut Context<Self>) {
        cx.subscribe(&panel, |_, _, e: &PullAction, cx| {
            cx.emit(match e {
                PullAction::Review(pr) => PullAction::Review(pr.clone()),
                PullAction::Explain(pr) => PullAction::Explain(pr.clone()),
            })
        })
        .detach();
        cx.subscribe(&panel, |_, _, e: &OpenLinked, cx| cx.emit(e.clone())).detach();
        cx.subscribe(&panel, |_, _, e: &OpenPull, cx| cx.emit(OpenPull(e.0.clone()))).detach();
        cx.subscribe(&panel, |_, _, e: &ShowSession, cx| cx.emit(ShowSession(e.0))).detach();
        cx.subscribe(&panel, |_, _, e: &crate::harness::OpenDoc, cx| cx.emit(crate::harness::OpenDoc(e.0.clone()))).detach();
        self.merged = Some(panel);
        cx.notify();
    }

    /// Opens a commit's files under the list, or closes it when it's open.
    fn open_commit(&mut self, oid: String, headline: String, url: String, window: &mut Window, cx: &mut Context<Self>) {
        if self.commit_view.as_ref().is_some_and(|(sha, _)| *sha == oid) {
            self.commit_view = None;
        } else {
            let (repo, number, sha) = (self.pr.repo.clone(), self.pr.number, oid.clone());
            let view = cx.new(|cx| crate::pr_diff::CommitDiff::new(repo, number, sha, headline, url, window, cx));
            self.commit_view = Some((oid, view));
        }
        cx.notify();
    }

    /// Opens a check's report and log under the list, or closes it.
    fn open_check(&mut self, name: String, id: i64, url: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        if self.check_view.as_ref().is_some_and(|(n, _)| *n == name) {
            self.check_view = None;
        } else {
            let (repo, label) = (self.pr.repo.clone(), name.clone());
            let view = cx.new(|cx| crate::check_detail::CheckDetail::new(repo, id, label, url, window, cx));
            self.check_view = Some((name, view));
        }
        cx.notify();
    }

    /// A list over what's opened from it: the list alone fills the part;
    /// with something open, it takes the top and that the rest.
    fn list_over(id: &'static str, list: AnyElement, open: Option<AnyElement>, theme: &Theme) -> AnyElement {
        let open_now = open.is_some();
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .id(id)
                    .when(open_now, |d| d.flex_none().max_h(gpui::relative(0.35)))
                    .when(!open_now, |d| d.flex_1())
                    .min_h_0()
                    .overflow_y_scroll()
                    .p_5()
                    .child(div().max_w(px(1100.)).child(list)),
            )
            .when_some(open, |d, view| d.child(div().flex_1().min_h_0().border_t_1().border_color(theme.border).child(view)))
            .into_any_element()
    }

    /// The PR as Review with Claude and Explain take it.
    pub fn pr(&self) -> &PrItem {
        &self.pr
    }

    /// The changed files' paths, for a file list before there's a review.
    pub fn file_paths(&self) -> Vec<String> {
        self.data.as_ref().map(|d| d.files.iter().map(|f| f.path.clone()).collect()).unwrap_or_default()
    }

    /// Commits, checks and failing checks, for the counts in a list.
    pub fn counts(&self) -> (usize, usize, usize) {
        self.data.as_ref().map_or((0, 0, 0), |d| (d.commit_total, d.checks.len(), d.checks.iter().filter(|c| c.outcome == "failure").count()))
    }

    /// Its state's word and colour, for a pill.
    pub fn state_pill(&self, theme: &Theme) -> (&'static str, Hsla) {
        self.state_tint(theme)
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

    /// Its repo, number and URL, to look it up in the local caches.
    pub fn place(&self) -> (String, i64, String) {
        (self.pr.repo.clone(), self.pr.number, self.pr.url.clone())
    }

    pub fn set_local(&mut self, local: Vec<LocalIssue>, cx: &mut Context<Self>) {
        if self.local != local {
            self.local = local;
            self.relink();
            self.share(cx);
            cx.notify();
        }
    }

    /// The plans and requirements about the PR or anything Related lists.
    fn relink(&mut self) {
        let mut items = vec![(self.pr.repo.clone(), self.pr.number)];
        if let Some(data) = &self.data {
            items.extend(data.linked.iter().chain(data.mentions.iter()).map(|l| (l.repo.clone(), l.number)));
        }
        items.extend(self.local.iter().map(|l| (l.repo.clone(), l.number)));
        let wanted = |d: &crate::harness::Doc| matches!(d.kind, crate::harness::HarnessKind::Plans | crate::harness::HarnessKind::Requirements);
        self.plans = crate::harness::linked(&self.docs, &items).into_iter().filter(|(d, _)| wanted(d)).collect();
    }

    pub fn set_related(&mut self, related: Vec<Related>, cx: &mut Context<Self>) {
        if self.related != related {
            self.related = related;
            self.share(cx);
            cx.notify();
        }
    }

    /// Fetches the PR and reads the harness's documents, off the main
    /// thread; `relink` then picks the plans and requirements.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.loading = true;
        self.share(cx);
        cx.notify();
        let (repo, number, org) = (self.pr.repo.clone(), self.pr.number, self.org.clone());
        self._fetch = Some(cx.spawn(async move |this, cx| {
            let (fetched, docs) = cx.background_executor().spawn(async move { (fetch(&repo, number), crate::harness::load(&org)) }).await;
            this.update(cx, |page, cx| {
                page.loading = false;
                match fetched {
                    Ok(data) => {
                        page.data = Some(std::rc::Rc::new(data));
                        page.error = None;
                    }
                    Err(e) => page.error = Some(e),
                }
                page.docs = std::sync::Arc::new(docs);
                page.relink();
                page.share(cx);
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
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_row()
                            .flex_wrap()
                            .items_baseline()
                            .gap_x_2()
                            .text_2xl()
                            .child(div().child(title))
                            .child(div().flex_none().text_color(theme.tertiary).child(format!("#{}", self.pr.number))),
                    )
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

    /// The timeline's events at `indexes`, as cards and lines.
    fn events(&self, data: &PullData, indexes: &[usize], theme: &Theme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let mut out = Vec::new();
        for &i in indexes {
            let event = &data.timeline[i];
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
                Event::Note { actor, text, at, .. } => Self::note(theme, actor, text, *at, None).into_any_element(),
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

    /// Who a thread waits on: the author when a reviewer spoke last, the
    /// one who started it when the author answered.
    fn thread_owner<'a>(thread: &'a Thread, author: &'a str) -> &'a str {
        if thread.last_by == author { &thread.started_by } else { author }
    }

    /// The one line that says where the PR stands and whose move it is,
    /// and its colour.
    fn decision(&self, data: &PullData, theme: &Theme) -> (String, Hsla) {
        let author = data.author.login.as_str();
        let names = |list: Vec<&str>| match list.len() {
            0 => String::new(),
            1 => list[0].to_string(),
            n => format!("{} and {}", list[..n - 1].join(", "), list[n - 1]),
        };
        match data.state.as_str() {
            "MERGED" => return (format!("Merged by {} {}", data.merged_by.clone().unwrap_or_default(), Self::when(data.merged_at)), theme.slot(5)),
            "CLOSED" => return (format!("Closed without merging {}", Self::when(data.closed_at)), theme.secondary),
            _ => {}
        }
        if data.draft {
            return (format!("Draft: {author} hasn't asked for review yet"), theme.secondary);
        }
        let changes: Vec<&str> = data.reviewers.iter().filter(|r| r.state == "CHANGES_REQUESTED").map(|r| r.person.login.as_str()).collect();
        let failing = data.checks.iter().filter(|c| c.outcome == "failure").count();
        let on_author = data.threads.iter().filter(|t| !t.resolved && Self::thread_owner(t, author) == author).count();
        if !changes.is_empty() {
            return (format!("Waiting on {author}: {} requested changes", names(changes)), theme.orange());
        }
        if failing > 0 {
            return (format!("Waiting on {author}: {failing} check{} failing", if failing == 1 { "" } else { "s" }), theme.critical());
        }
        if on_author > 0 {
            return (format!("Waiting on {author}: {on_author} open thread{} to answer", if on_author == 1 { "" } else { "s" }), theme.orange());
        }
        let asked: Vec<&str> = data.reviewers.iter().filter(|r| r.state == "REQUESTED").map(|r| r.person.login.as_str()).collect();
        let approved = data.reviewers.iter().any(|r| r.state == "APPROVED");
        if approved && data.checks.iter().all(|c| c.outcome != "pending") {
            return (format!("Approved: ready for {author} to merge"), theme.good());
        }
        if !asked.is_empty() {
            return (format!("Waiting on {} to review", names(asked)), gpui::rgb(0xEDA100).into());
        }
        if data.checks.iter().any(|c| c.outcome == "pending") {
            return ("Waiting on checks to finish".into(), gpui::rgb(0xEDA100).into());
        }
        (format!("Waiting on {author} to ask for a review"), theme.secondary)
    }

    /// The decision, then the facts behind it as chips.
    fn decision_block(&self, data: &PullData, theme: &Theme) -> impl IntoElement {
        let (line, tint) = self.decision(data, theme);
        let open = data.threads.iter().filter(|t| !t.resolved).count();
        let (failing, pending) = (data.checks.iter().filter(|c| c.outcome == "failure").count(), data.checks.iter().filter(|c| c.outcome == "pending").count());
        let approvals = data.reviewers.iter().filter(|r| r.state == "APPROVED").count();
        let chip = |text: String, tint: Hsla| div().flex().flex_row().items_center().gap_1().text_sm().child(div().size(px(7.)).rounded_full().bg(tint)).child(text);
        let checks = if data.checks.is_empty() {
            chip("No checks".into(), theme.tertiary)
        } else if failing > 0 {
            chip(format!("{failing} failing"), theme.critical())
        } else if pending > 0 {
            chip(format!("{pending} checks running"), gpui::rgb(0xEDA100).into())
        } else {
            chip("Checks passing".into(), theme.good())
        };
        let risk = crate::risk::level_for(&data.id);
        div()
            .flex()
            .flex_col()
            .gap_1p5()
            .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).text_color(tint).child(line))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .gap_x_4()
                    .gap_y_1()
                    .text_color(theme.secondary)
                    .child(chip(if open == 1 { "1 open thread".into() } else { format!("{open} open threads") }, if open > 0 { theme.orange() } else { theme.good() }))
                    .child(checks)
                    .child(chip(if approvals == 1 { "1 approval".into() } else { format!("{approvals} approvals") }, if approvals > 0 { theme.good() } else { theme.tertiary }))
                    .child(match risk {
                        Some(level) => chip(format!("Merge risk {}", level.title()), crate::review_panel::risk_tint(level, theme)),
                        None => chip("Merge risk not graded".into(), theme.tertiary),
                    }),
            )
    }

    /// What's open, each with whose move it is and for how long: changes
    /// requested, failing checks, open threads, reviewers yet to review.
    /// What's open on GitHub, each with whose move it is: changes
    /// requested, failing checks, open threads, reviewers yet to review.
    fn attention_items(data: &PullData) -> Vec<AttentionItem> {
        let author = data.author.login.clone();
        let mut items: Vec<AttentionItem> = Vec::new();
        if data.state == "OPEN" {
            for r in data.reviewers.iter().filter(|r| r.state == "CHANGES_REQUESTED") {
                items.push(AttentionItem { kind: AttentionKind::ChangesRequested, text: format!("{} requested changes", r.person.login), detail: None, owner: author.clone(), since: r.at, url: None });
            }
            for c in data.checks.iter().filter(|c| c.outcome == "failure") {
                items.push(AttentionItem { kind: AttentionKind::Failing, text: format!("{} is failing", c.name), detail: None, owner: author.clone(), since: None, url: c.url.clone() });
            }
            let mut threads: Vec<&Thread> = data.threads.iter().filter(|t| !t.resolved).collect();
            threads.sort_by_key(|t| t.last_at);
            for t in threads {
                let first = t.comments.first().map(|(_, body)| body.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string());
                items.push(AttentionItem {
                    kind: AttentionKind::Thread,
                    text: match t.line {
                        Some(line) => format!("{} line {line}", t.path),
                        None => t.path.clone(),
                    },
                    detail: first.map(|f| format!("{}: {f}", t.started_by)),
                    owner: Self::thread_owner(t, &author).to_string(),
                    since: t.last_at,
                    url: Some(t.url.clone()).filter(|u| !u.is_empty()),
                });
            }
            for r in data.reviewers.iter().filter(|r| r.state == "REQUESTED") {
                items.push(AttentionItem { kind: AttentionKind::Unreviewed, text: format!("{} hasn't reviewed", r.person.login), detail: None, owner: r.person.login.clone(), since: r.at, url: None });
            }
        }
        items
    }

    /// What's open on GitHub, for a page that lists it with its own.
    pub fn open_items(&self) -> Vec<AttentionItem> {
        self.data.as_deref().map(Self::attention_items).unwrap_or_default()
    }

    /// Where it stands and whose move it is, and the facts behind it: open
    /// threads, failing checks and approvals.
    pub fn standing_facts(&self, theme: &Theme) -> Option<(String, usize, usize, usize)> {
        let data = self.data.as_ref()?;
        Some((
            self.decision(data, theme).0,
            data.threads.iter().filter(|t| !t.resolved).count(),
            data.checks.iter().filter(|c| c.outcome == "failure").count(),
            data.reviewers.iter().filter(|r| r.state == "APPROVED").count(),
        ))
    }

    fn attention(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let items = Self::attention_items(data);
        if items.is_empty() {
            return div().text_sm().text_color(theme.secondary).child(if data.state == "OPEN" { "Nothing open." } else { "Nothing open: it's done." }).into_any_element();
        }
        let count = items.len();
        div()
            .flex()
            .flex_col()
            .gap_1()
            .child(div().flex().flex_row().gap_1p5().font_weight(FontWeight::SEMIBOLD).child("Needs attention").child(div().text_color(theme.secondary).font_weight(FontWeight::NORMAL).child(count.to_string())))
            .child(div().flex().flex_col().rounded_lg().border_1().border_color(theme.border).children(items.into_iter().enumerate().map(|(i, item)| {
                let tint = match item.kind {
                    AttentionKind::Failing => theme.critical(),
                    AttentionKind::Unreviewed => gpui::rgb(0xEDA100).into(),
                    _ => theme.orange(),
                };
                div()
                    .id(("pull-attention", i))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_1p5()
                    .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                    .when_some(item.url, |d, url| d.cursor_pointer().hover(|s| s.bg(theme.tile)).on_click(cx.listener(move |_, _: &ClickEvent, _, cx| cx.open_url(&url))))
                    .child(div().flex_none().size(px(7.)).rounded_full().bg(tint))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().truncate().text_sm().child(item.text))
                            .when_some(item.detail, |d, detail| d.child(div().truncate().text_xs().text_color(theme.secondary).child(detail))),
                    )
                    .child(div().flex_none().text_sm().text_color(theme.secondary).child(format!("on {}", item.owner)))
                    .when_some(item.since, |d, at| d.child(div().flex_none().w(px(80.)).text_right().text_sm().text_color(theme.tertiary).child(Self::when(Some(at)))))
            })))
            .into_any_element()
    }

    /// The timeline in rounds: each starts with a push of commits and
    /// holds what followed it, in order. Indexes into `timeline`.
    fn rounds(data: &PullData) -> Vec<Vec<usize>> {
        let mut rounds: Vec<Vec<usize>> = Vec::new();
        let mut current: Vec<usize> = Vec::new();
        for (i, event) in data.timeline.iter().enumerate() {
            let commit = matches!(event, Event::Commit { .. });
            if commit && current.iter().any(|&j| !matches!(data.timeline[j], Event::Commit { .. })) {
                rounds.push(std::mem::take(&mut current));
            }
            current.push(i);
        }
        if !current.is_empty() {
            rounds.push(current);
        }
        rounds
    }

    /// When the viewer last commented or reviewed here.
    fn last_look(data: &PullData) -> Option<DateTime<Utc>> {
        data.timeline
            .iter()
            .filter_map(|e| match e {
                Event::Comment { author, at, .. } | Event::Review { author, at, .. } if author.login.eq_ignore_ascii_case(&data.viewer) => *at,
                _ => None,
            })
            .max()
    }

    /// The rounds, newest first: the latest and any since the viewer
    /// looked open, the rest a line each; in each, what folds away (bots,
    /// review requests, labels) is one line until clicked.
    fn rounds_view(&self, data: &PullData, theme: &Theme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let rounds = Self::rounds(data);
        let last_look = Self::last_look(data);
        let latest = rounds.len().saturating_sub(1);
        let mut out = Vec::new();
        for (index, round) in rounds.iter().enumerate().rev() {
            let end = round.iter().filter_map(|&i| data.timeline[i].at()).max();
            let new = last_look.is_some_and(|look| round.iter().any(|&i| {
                let e = &data.timeline[i];
                e.at().is_some_and(|at| at > look) && !e.is_noise() && !matches!(e, Event::Comment { author, .. } | Event::Review { author, .. } if author.login.eq_ignore_ascii_case(&data.viewer))
            }));
            let open = self.rounds_open.get(&index).copied().unwrap_or(index == latest || new);
            let commits = round.iter().filter(|&&i| matches!(data.timeline[i], Event::Commit { .. })).count();
            let reviews = round.iter().filter(|&&i| matches!(&data.timeline[i], Event::Review { author, .. } if !author.bot)).count();
            let comments = round.iter().filter(|&&i| matches!(&data.timeline[i], Event::Comment { .. }) && !data.timeline[i].is_noise()).count();
            let mut summary: Vec<String> = Vec::new();
            for (n, one, many) in [(commits, "commit", "commits"), (reviews, "review", "reviews"), (comments, "comment", "comments")] {
                if n > 0 {
                    summary.push(format!("{n} {}", if n == 1 { one } else { many }));
                }
            }
            let header = div()
                .id(("pull-round", index))
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .py_1()
                .cursor_pointer()
                .text_sm()
                .hover(|s| s.text_color(theme.fg))
                .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                    page.rounds_open.insert(index, !open);
                    cx.notify();
                }))
                .child(div().flex_none().w(px(10.)).text_color(theme.tertiary).child(if open { "▾" } else { "▸" }))
                .child(div().font_weight(FontWeight::SEMIBOLD).child(format!("Round {}", index + 1)))
                .child(div().text_color(theme.secondary).child(summary.join(", ")))
                .when(new, |d| d.child(div().px_1p5().rounded_full().text_xs().bg(theme.selected).text_color(theme.on_selected).child("New since you looked")))
                .child(div().flex_1())
                .child(div().text_color(theme.tertiary).child(Self::when(end)));
            out.push(header.into_any_element());
            if !open {
                continue;
            }
            let shown: Vec<usize> = round.iter().copied().filter(|&i| !data.timeline[i].is_noise()).collect();
            let folded: Vec<usize> = round.iter().copied().filter(|&i| data.timeline[i].is_noise()).collect();
            let events = self.events(data, &shown, theme, cx);
            let mut body = div().flex().flex_col().gap_2().pl_4().pb_2().children(events);
            if !folded.is_empty() {
                let bots = folded.iter().filter(|&&i| matches!(data.timeline[i], Event::Comment { .. } | Event::Review { .. })).count();
                let notes = folded.len() - bots;
                let mut parts = Vec::new();
                if bots > 0 {
                    parts.push(format!("{bots} bot comment{}", if bots == 1 { "" } else { "s" }));
                }
                if notes > 0 {
                    parts.push(format!("{notes} review request{} and label{}", if notes == 1 { "" } else { "s" }, if notes == 1 { "" } else { "s" }));
                }
                let showing = self.noise_open.contains(&index);
                body = body.child(
                    div()
                        .id(("pull-noise", index))
                        .px_3()
                        .text_sm()
                        .text_color(theme.tertiary)
                        .cursor_pointer()
                        .hover(|s| s.text_color(theme.secondary))
                        .on_click(cx.listener(move |page, _: &ClickEvent, _, cx| {
                            if !page.noise_open.remove(&index) {
                                page.noise_open.insert(index);
                            }
                            cx.notify();
                        }))
                        .child(format!("{} {}", if showing { "Hide" } else { "Show" }, parts.join(", "))),
                );
                if showing {
                    body = body.children(self.events(data, &folded, theme, cx));
                }
            }
            out.push(body.into_any_element());
        }
        out
    }

    /// Gannin's question first (where it stands, whose move, what's open),
    /// then what the harness knows, the description, and the rounds.
    fn overview(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let Some(data) = &self.data else {
            return div().p_4().text_color(theme.secondary).child(self.error.clone().unwrap_or_else(|| "Loading the pull request".into())).into_any_element();
        };
        let attention = self.attention(data, theme, cx);
        let rounds = self.rounds_view(data, theme, cx);
        div()
            .flex()
            .flex_col()
            .gap_4()
            .child(self.decision_block(data, theme))
            .child(attention)
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
            .child(div().flex().flex_col().gap_1().children(rounds))
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
        // Related: what it closes, the issues and PRs that mention it, and
        // the harness's plans and requirements about it or what it closes.
        // Each opens in its drawer: an issue's, a PR's, a plan's.
        let caption = |text: &str| div().pt_1().text_xs().text_color(theme.tertiary).child(text.to_string());
        let own_repo = self.pr.repo.clone();
        let item_row = |key: (&'static str, usize), l: &Linked, cx: &mut Context<Self>| {
            let (pull, id, url, repo, number, title, open) = (l.pull, l.id.clone(), l.url.clone(), l.repo.clone(), l.number, l.title.clone(), l.open);
            let tip = format!("{} {}", if l.open { "Open" } else { "Closed" }, if l.pull { "pull request" } else { "issue" });
            let reference = if l.repo.eq_ignore_ascii_case(&own_repo) { format!("#{}", l.number) } else { format!("{}#{}", l.repo.rsplit('/').next().unwrap_or(&l.repo), l.number) };
            div()
                .id(key)
                .flex()
                .flex_row()
                .items_center()
                .gap_2()
                .text_sm()
                .cursor_pointer()
                .hover(|s| s.text_color(theme.selected))
                .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| {
                    if pull {
                        cx.emit(OpenPull(PrItem::stub(&id, &repo, number, &title, &url)));
                    } else {
                        cx.emit(OpenLinked { id: id.clone(), url: url.clone(), repo: repo.clone(), number, title: title.clone(), open });
                    }
                }))
                // Its kind as an icon, coloured by state: open green,
                // closed (or merged) purple. The tooltip says which.
                .child(
                    div()
                        .id((key.0, key.1 + 10_000))
                        .flex_none()
                        .tooltip(move |_, cx| cx.new(|_| crate::issues::Tooltip(tip.clone())).into())
                        .child(gpui::svg().path(if l.pull { crate::icons::PULL } else { crate::icons::issue(l.open) }).size(px(14.)).text_color(if l.open { theme.good() } else { theme.slot(5) })),
                )
                .child(div().flex_1().min_w_0().truncate().child(l.title.clone()))
                .child(div().flex_none().text_color(theme.secondary).child(reference))
        };
        // The local issue cache first, then what GitHub's fetch adds, each
        // item once; an issue it closes is listed under Closes only.
        let local = |closes: bool| self.local.iter().filter(move |l| l.closes == closes).map(|l| Linked { pull: false, id: l.id.clone(), number: l.number, title: l.title.clone(), url: l.url.clone(), open: l.open, repo: l.repo.clone() });
        let mut closes: Vec<Linked> = local(true).collect();
        for l in &data.linked {
            if !closes.iter().any(|c| c.id == l.id) {
                closes.push(Linked { pull: l.pull, id: l.id.clone(), number: l.number, title: l.title.clone(), url: l.url.clone(), open: l.open, repo: l.repo.clone() });
            }
        }
        let mut mentions: Vec<Linked> = Vec::new();
        for l in local(false).chain(data.mentions.iter().map(|l| Linked { pull: l.pull, id: l.id.clone(), number: l.number, title: l.title.clone(), url: l.url.clone(), open: l.open, repo: l.repo.clone() })) {
            if !closes.iter().chain(mentions.iter()).any(|c| c.id == l.id) {
                mentions.push(l);
            }
        }
        let mut related = group("Related");
        if closes.is_empty() && mentions.is_empty() && self.plans.is_empty() {
            related = related.child(none("Nothing related"));
        }
        if !closes.is_empty() {
            related = related.child(caption("Closes"));
            for (i, l) in closes.iter().enumerate() {
                related = related.child(item_row(("pull-linked", i), l, cx));
            }
        }
        if !mentions.is_empty() {
            related = related.child(caption("Mentioned in"));
            for (i, l) in mentions.iter().enumerate() {
                related = related.child(item_row(("pull-mention", i), l, cx));
            }
        }
        let (plans, requirements): (Vec<_>, Vec<_>) = self.plans.iter().cloned().partition(|(d, _)| d.kind == crate::harness::HarnessKind::Plans);
        if !plans.is_empty() {
            related = related.child(caption("Plans")).children(crate::harness::plan_rows("pull-related-plan", &plans, theme, cx));
        }
        if !requirements.is_empty() {
            related = related.child(caption("Requirements")).children(crate::harness::plan_rows("pull-related-requirement", &requirements, theme, cx));
        }
        let mut participants = div().flex().flex_row().flex_wrap().gap_1();
        for p in &data.participants {
            participants = participants.child(Self::avatar(p, 22., theme, cx));
        }
        div()
            .w_full()
            .flex()
            .flex_col()
            .gap_3()
            // Laid beside a review, its Needs attention says all this.
            .when(self.part != Part::Sidebar, |d| {
                d.child(group("Activity").child(row("Approvals", approvals)).child(row("Changes requested", changes)).child(row("Unresolved threads", unresolved)).child(row("Commits", data.commit_total)))
            })
            // What it relates to first: each opens in a drawer.
            .child(related)
            .child(reviewers)
            .child(assignees)
            .child(labels)
            .child(milestone)
            .child(group(&if data.participants.len() == 1 { "1 participant".to_string() } else { format!("{} participants", data.participants.len()) }).child(participants))
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
                let (oid, headline, url) = (c.oid.clone(), c.headline.clone(), c.url.clone());
                let open = self.commit_view.as_ref().is_some_and(|(sha, _)| *sha == c.oid);
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
                    .when(open, |d| d.bg(theme.row_selected))
                    .when(!open, |d| d.hover(|s| s.bg(theme.tile)))
                    .on_click(cx.listener(move |page, _: &ClickEvent, window, cx| page.open_commit(oid.clone(), headline.clone(), url.clone(), window, cx)))
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
                let (url, name, id) = (c.url.clone(), c.name.clone(), c.id);
                let open = self.check_view.as_ref().is_some_and(|(n, _)| *n == c.name);
                let clickable = id.is_some() || url.is_some();
                div()
                    .id(("pull-check", i))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_1p5()
                    .when(i > 0, |d| d.border_t_1().border_color(theme.border))
                    .when(open, |d| d.bg(theme.row_selected))
                    // A check run opens here; a status (no report to read) on its site.
                    .when(clickable, |d| {
                        d.cursor_pointer().when(!open, |d| d.hover(|s| s.bg(theme.tile))).on_click(cx.listener(move |page, _: &ClickEvent, window, cx| match id {
                            Some(id) => page.open_check(name.clone(), id, url.clone(), window, cx),
                            None => {
                                if let Some(url) = &url {
                                    cx.open_url(url);
                                }
                            }
                        }))
                    })
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
        // The PR page is the review panel with the PR merged in.
        if let (Part::Whole, Some(panel)) = (self.part, &self.merged) {
            return panel.clone().into_any_element();
        }
        if self.part != Part::Whole {
            let Some(data) = &self.data else { return div().into_any_element() };
            return match self.part {
                Part::Description => Self::card(&theme)
                    .child(Self::card_head(&data.author, div().child("opened this").into_any_element(), data.created_at, None, &theme, cx))
                    .child(div().p_3().child(markdown("pull-body", &data.body, &theme)))
                    .into_any_element(),
                Part::Timeline => div().flex().flex_col().gap_1().children(self.rounds_view(data, &theme, cx)).into_any_element(),
                Part::Commits => {
                    let list = self.commits(data, &theme, cx);
                    Self::list_over("pull-commits-list", list, self.commit_view.as_ref().map(|(_, v)| v.clone().into_any_element()), &theme)
                }
                Part::Checks => {
                    let list = self.checks(data, &theme, cx);
                    Self::list_over("pull-checks-list", list, self.check_view.as_ref().map(|(_, v)| v.clone().into_any_element()), &theme)
                }
                Part::Sidebar => self.sidebar(data, &theme, cx).into_any_element(),
                Part::Whole => unreachable!(),
            };
        }
        // Narrow: one column, the sidebar under it. From 900 the sidebar
        // sits at the right edge and scrolls on its own; from 1500 Checks
        // and Files changed take a column between them.
        let width = self.width.get();
        let (beside, three) = (width >= 900., width >= 1500.);
        let scroll = |id: &'static str| div().id(id).h_full().min_h_0().overflow_y_scroll();
        let body: AnyElement = match (&self.data, self.section) {
            (None, _) | (_, Section::Overview) => {
                let overview = self.overview(&theme, cx);
                let side = self.data.as_ref().map(|d| self.sidebar(d, &theme, cx).into_any_element());
                let middle = self.data.as_ref().filter(|_| three).map(|d| {
                    let heading = |text: String| div().pb_1().font_weight(FontWeight::SEMIBOLD).child(text);
                    let checks = self.checks(d, &theme, cx);
                    let files = self.files(d, &theme, cx);
                    div()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .child(heading(format!("Checks {}", d.checks.len())))
                        .child(checks)
                        .child(div().pt_3().child(heading(format!("Files changed {}", d.file_total))))
                        .child(files)
                        .into_any_element()
                });
                if beside {
                    div()
                        .size_full()
                        .flex()
                        .flex_row()
                        .child(scroll("pull-main").flex_1().min_w_0().px_6().py_4().child(div().max_w(px(1100.)).child(overview)))
                        .when_some(middle, |d, middle| d.child(scroll("pull-middle").flex_1().min_w(px(360.)).max_w(px(640.)).py_4().pr_6().child(middle)))
                        .when_some(side, |d, side| d.child(scroll("pull-side").flex_none().w(px(312.)).px_4().py_4().border_l_1().border_color(theme.border).bg(theme.sidebar).child(side)))
                        .into_any_element()
                } else {
                    scroll("pull-main").size_full().px_6().py_4().child(div().flex().flex_col().gap_6().child(overview).children(side)).into_any_element()
                }
            }
            (Some(data), Section::Commits) => scroll("pull-list").size_full().px_6().py_4().child(div().max_w(px(1100.)).child(self.commits(data, &theme, cx))).into_any_element(),
            (Some(data), Section::Checks) => scroll("pull-list").size_full().px_6().py_4().child(div().max_w(px(1100.)).child(self.checks(data, &theme, cx))).into_any_element(),
            (Some(data), Section::Files) => scroll("pull-list").size_full().px_6().py_4().child(div().max_w(px(1100.)).child(self.files(data, &theme, cx))).into_any_element(),
        };
        let measured = self.width.clone();
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(theme.bg)
            .child(self.header(&theme, cx))
            .when_some(self.error.clone().filter(|_| self.data.is_some()), |d, e| d.child(div().px_6().py_1().text_sm().text_color(theme.critical()).child(format!("Couldn't refresh: {e}"))))
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .child(
                        gpui::canvas(
                            move |bounds, window, _| {
                                let now = f32::from(bounds.size.width);
                                if (now - measured.get()).abs() > 1. {
                                    measured.set(now);
                                    window.refresh();
                                }
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .top_0()
                        .left_0()
                        .w_full()
                        .h(px(0.)),
                    )
                    .child(body),
            )
            .into_any_element()
    }
}
