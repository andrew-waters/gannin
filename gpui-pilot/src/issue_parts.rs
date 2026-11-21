//! What New Issue brings beside the issue itself, after Gannin's
//! `IssueTemplate`, `HarnessSkill` and `IssueImages`:
//!
//! - **Skills** read from the harness checkout on this Mac (`skills/*.md`,
//!   `skills/<name>/SKILL.md`, `.claude/skills/<name>/SKILL.md`), never
//!   from Gannin's harness index. Claude runs in that checkout, so it reads
//!   the ticked ones at the same paths.
//! - **Templates** from the repository's `.github/ISSUE_TEMPLATE`: Markdown
//!   ones with their front matter, and issue forms (YAML) as their top-level
//!   facts with each field's label as a heading, as Gannin reads them. Read
//!   by hand: nothing in the build parses YAML.
//! - **Images**, committed to the harness in one commit before the issue is
//!   made, under `attachments/issues/<owner>/<name>/<date>-<id>/`, and linked
//!   at that commit with `?raw=true`, which GitHub serves to anyone who can
//!   read the harness. Until then the description holds a placeholder,
//!   `![name](attachment:file)`. A branch whose rules refuse a direct commit
//!   gets it through a pull request, merged when GitHub allows; the links
//!   name the commit, so they work either way.

use crate::github::{self, Error};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;

// MARK: - Front matter

#[derive(Clone, Debug)]
pub enum Fm {
    Text(String),
    List(Vec<String>),
}

impl Fm {
    pub fn text(&self) -> Option<&str> {
        match self {
            Fm::Text(t) => Some(t.as_str()),
            Fm::List(_) => None,
        }
    }

    /// A list, or a text as `[a, b]` or `a, b`.
    pub fn list(&self) -> Vec<String> {
        match self {
            Fm::List(items) => items.clone(),
            Fm::Text(text) => {
                let inner = text.strip_prefix('[').and_then(|t| t.strip_suffix(']')).unwrap_or(text);
                inner.split(',').map(unquoted).filter(|s| !s.is_empty()).collect()
            }
        }
    }
}

pub fn unquoted(text: &str) -> String {
    let text = text.trim();
    let quoted = text.len() >= 2 && ((text.starts_with('"') && text.ends_with('"')) || (text.starts_with('\'') && text.ends_with('\'')));
    if quoted { text[1..text.len() - 1].to_string() } else { text.to_string() }
}

/// The front matter between a leading `---` and the next, and the text
/// after it; none when the text doesn't open with one.
pub fn front_matter(text: &str) -> Option<(BTreeMap<String, Fm>, String)> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.first().map(|l| l.trim()) != Some("---") {
        return None;
    }
    let end = lines.iter().skip(1).position(|l| l.trim() == "---")? + 1;
    let mut map = BTreeMap::new();
    let mut open_list: Option<String> = None;
    for line in &lines[1..end] {
        let trimmed = line.trim();
        if let (Some(key), Some(item)) = (&open_list, trimmed.strip_prefix("- ")) {
            if let Some(Fm::List(items)) = map.get_mut(key) {
                items.push(unquoted(item));
            }
            continue;
        }
        open_list = None;
        if line.starts_with(' ') || line.starts_with('\t') {
            continue;
        }
        let Some((key, value)) = trimmed.split_once(':') else { continue };
        let (key, value) = (key.trim().to_string(), value.trim());
        if value.is_empty() {
            map.insert(key.clone(), Fm::List(Vec::new()));
            open_list = Some(key);
        } else {
            map.insert(key, Fm::Text(unquoted(value)));
        }
    }
    Some((map, lines[end + 1..].join("\n").trim().to_string()))
}

// MARK: - Skills

#[derive(Clone, Debug)]
pub struct Skill {
    /// From the harness root, as Claude reads it there.
    pub path: String,
    pub name: String,
    pub summary: Option<String>,
}

impl Skill {
    /// Ticked to start with: a skill about issues, as Gannin ticks them.
    pub fn about_issues(&self) -> bool {
        format!("{} {}", self.name, self.summary.as_deref().unwrap_or("")).to_lowercase().contains("issue")
    }
}

fn read_skill(root: &Path, relative: &str, folder_name: Option<&str>) -> Option<Skill> {
    let text = std::fs::read_to_string(root.join(relative)).ok()?;
    let stem = folder_name.map(str::to_string).unwrap_or_else(|| relative.rsplit('/').next().unwrap_or(relative).trim_end_matches(".md").to_string());
    let (front, body) = front_matter(&text).unwrap_or_else(|| (BTreeMap::new(), text.clone()));
    let summary = front
        .get("description")
        .or_else(|| front.get("summary"))
        .and_then(|v| v.text().map(str::to_string))
        .or_else(|| body.lines().map(str::trim).find(|l| !l.is_empty() && !l.starts_with('#')).map(|l| l.chars().take(160).collect()));
    Some(Skill { path: relative.to_string(), name: front.get("name").and_then(|v| v.text().map(str::to_string)).unwrap_or(stem), summary })
}

/// The harness's skills, by name. Blocking (reads files).
pub fn skills(harness: &Path) -> Vec<Skill> {
    let mut found = Vec::new();
    for base in ["skills", ".claude/skills"] {
        let Ok(entries) = std::fs::read_dir(harness.join(base)) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            let path = entry.path();
            if path.is_dir() {
                if path.join("SKILL.md").is_file() {
                    found.extend(read_skill(harness, &format!("{base}/{name}/SKILL.md"), Some(&name)));
                }
            } else if name.ends_with(".md") && !name.eq_ignore_ascii_case("README.md") {
                found.extend(read_skill(harness, &format!("{base}/{name}"), None));
            }
        }
    }
    found.sort_by_key(|s| s.name.to_lowercase());
    found
}

// MARK: - Templates

#[derive(Clone, Debug)]
pub struct Template {
    pub file: String,
    pub name: String,
    pub about: Option<String>,
    pub title: String,
    pub labels: Vec<String>,
    pub assignees: Vec<String>,
    pub body: String,
}

/// A template from its file; none for what isn't one (`config.yml`).
pub fn parse_template(file: &str, text: &str) -> Option<Template> {
    let lower = file.to_lowercase();
    if lower.ends_with(".md") {
        let (front, body) = front_matter(text).unwrap_or_else(|| (BTreeMap::new(), text.trim().to_string()));
        let text_of = |key: &str| front.get(key).and_then(|v| v.text().map(str::to_string));
        return Some(Template {
            file: file.into(),
            name: text_of("name").unwrap_or_else(|| file[..file.len() - 3].to_string()),
            about: text_of("about"),
            title: text_of("title").unwrap_or_default(),
            labels: front.get("labels").map(Fm::list).unwrap_or_default(),
            assignees: front.get("assignees").map(Fm::list).unwrap_or_default(),
            body,
        });
    }
    if !(lower.ends_with(".yml") || lower.ends_with(".yaml")) || lower.starts_with("config.") {
        return None;
    }
    // An issue form: its top-level facts, and each field's label as a
    // heading to write under.
    let (mut name, mut about, mut title) = (None, None, String::new());
    let (mut labels, mut headings) = (Vec::new(), Vec::new());
    let mut in_labels = false;
    let value = |line: &str, key: &str| line.strip_prefix(&format!("{key}:")).map(unquoted);
    for line in text.lines() {
        let trimmed = line.trim();
        let top = !line.starts_with(' ') && !line.starts_with('-');
        if in_labels && trimmed.starts_with("- ") && (line.starts_with(' ') || line.starts_with('-')) {
            labels.push(unquoted(&trimmed[2..]));
            continue;
        }
        in_labels = false;
        if top {
            if let Some(v) = value(trimmed, "name") {
                name = Some(v);
            } else if let Some(v) = value(trimmed, "description") {
                about = Some(v);
            } else if let Some(v) = value(trimmed, "title") {
                title = v;
            } else if let Some(v) = value(trimmed, "labels") {
                if v.is_empty() { in_labels = true } else { labels = Fm::Text(v).list() }
            }
        } else if let Some(v) = value(trimmed, "label").filter(|v| !v.is_empty()) {
            headings.push(v);
        }
    }
    Some(Template {
        file: file.into(),
        name: name?,
        about,
        title,
        labels,
        assignees: Vec::new(),
        body: headings.iter().map(|h| format!("### {h}\n\n")).collect::<Vec<_>>().join("\n"),
    })
}

/// The repository's issue templates. Blocking.
pub fn fetch_templates(token: &str, repo: &str) -> Result<Vec<Template>, Error> {
    const QUERY: &str = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { object(expression: \"HEAD:.github/ISSUE_TEMPLATE\") { ... on Tree { entries { name object { ... on Blob { text } } } } } } }";
    let (owner, name) = repo.split_once('/').ok_or_else(|| Error::Other(format!("{repo} isn't owner/name")))?;
    let data = github::graphql(token, QUERY, json!({ "owner": owner, "name": name }))?;
    let mut templates: Vec<Template> = data["repository"]["object"]["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|e| parse_template(e["name"].as_str()?, e["object"]["text"].as_str()?))
        .collect();
    templates.sort_by_key(|t| t.name.to_lowercase());
    Ok(templates)
}

// MARK: - Images

/// The most an image can be: `createCommitOnBranch` takes the whole commit
/// in one request, base64 encoded.
pub const MAX_BYTES: usize = 5 * 1024 * 1024;
pub const ROOT: &str = "attachments/issues";
const SCHEME: &str = "attachment";

fn web(ext: &str) -> bool {
    matches!(ext, "png" | "jpg" | "jpeg" | "gif" | "webp")
}

/// An image as it's committed: a web type as it is, anything else as a
/// PNG, and one over the limit as a JPEG when that fits (not a GIF, which
/// would lose its frames). Errors name the file as it was picked.
pub fn prepare(name: &str, bytes: Vec<u8>) -> Result<(String, Vec<u8>), String> {
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) => (stem.to_string(), ext.to_lowercase()),
        None => (name.to_string(), String::new()),
    };
    let decoded = || image::load_from_memory(&bytes).map_err(|_| format!("{name} isn't an image Gannin can read."));
    let (mut kept, mut data) = (name.to_string(), bytes.clone());
    if !web(&ext) {
        let mut png = Vec::new();
        decoded()?.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).map_err(|e| e.to_string())?;
        kept = format!("{stem}.png");
        data = png;
    }
    if data.len() > MAX_BYTES {
        if ext == "gif" {
            return Err(format!("{name} is over 5 MB, more than goes through GitHub's API."));
        }
        let rgb = image::load_from_memory(&data).map_err(|_| format!("{name} isn't an image Gannin can read."))?.to_rgb8();
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85).encode_image(&rgb).map_err(|e| e.to_string())?;
        if jpeg.len() > MAX_BYTES {
            return Err(format!("{name} is over 5 MB even as a JPEG."));
        }
        kept = format!("{stem}.jpg");
        data = jpeg;
    }
    Ok((kept, data))
}

pub fn gpui_format(name: &str) -> gpui::ImageFormat {
    match name.rsplit('.').next().unwrap_or("").to_lowercase().as_str() {
        "jpg" | "jpeg" => gpui::ImageFormat::Jpeg,
        "gif" => gpui::ImageFormat::Gif,
        "webp" => gpui::ImageFormat::Webp,
        _ => gpui::ImageFormat::Png,
    }
}

pub fn extension(format: gpui::ImageFormat) -> &'static str {
    match format {
        gpui::ImageFormat::Jpeg => "jpg",
        gpui::ImageFormat::Gif => "gif",
        gpui::ImageFormat::Webp => "webp",
        gpui::ImageFormat::Svg => "svg",
        gpui::ImageFormat::Bmp => "bmp",
        gpui::ImageFormat::Tiff => "tiff",
        _ => "png",
    }
}

/// `![shot](attachment:shot.png)`, where the image goes until it's committed.
pub fn placeholder(name: &str) -> String {
    let stem = name.rsplit_once('.').map_or(name, |(s, _)| s);
    format!("![{stem}]({SCHEME}:{name})")
}

pub fn appending_placeholder(text: &str, name: &str) -> String {
    let trimmed = text.trim_end();
    if trimmed.is_empty() { placeholder(name) } else { format!("{trimmed}\n\n{}", placeholder(name)) }
}

pub fn removing_placeholder(text: &str, name: &str) -> String {
    let tag = placeholder(name);
    text.replace(&format!("\n\n{tag}"), "").replace(&tag, "")
}

/// The description as it's sent: each placeholder pointed at its image,
/// images with none left (removed, or dropped by Claude's draft) added at
/// the end, and placeholders for images no longer attached taken out, so
/// nothing links nowhere.
pub fn body(text: &str, links: &[(String, String)]) -> String {
    let mut body = text.to_string();
    let mut missing = Vec::new();
    for (name, url) in links {
        let target = format!("({SCHEME}:{name})");
        if body.contains(&target) {
            body = body.replace(&target, &format!("({url})"));
        } else {
            let stem = name.rsplit_once('.').map_or(name.as_str(), |(s, _)| s);
            missing.push(format!("![{stem}]({url})"));
        }
    }
    // Placeholders left over: `![...](attachment:...)` with the blank lines
    // before it.
    let mut out = String::new();
    let mut rest = body.as_str();
    let opener = format!("]({SCHEME}:");
    while let Some(at) = rest.find(&opener) {
        let Some(start) = rest[..at].rfind("![").filter(|s| !rest[*s..at].contains('\n')) else {
            out.push_str(&rest[..at + opener.len()]);
            rest = &rest[at + opener.len()..];
            continue;
        };
        let Some(close) = rest[at..].find(')') else { break };
        out.push_str(rest[..start].trim_end_matches('\n'));
        rest = &rest[at + close + 1..];
    }
    out.push_str(rest);
    if missing.is_empty() {
        return out;
    }
    let trimmed = out.trim_end();
    format!("{}{}", if trimmed.is_empty() { String::new() } else { format!("{trimmed}\n\n") }, missing.join("\n\n"))
}

/// The folder one issue's images go in.
pub fn folder(repo: &str, started: chrono::DateTime<chrono::Utc>, id: u64) -> String {
    format!("{ROOT}/{repo}/{}-{:08x}", started.format("%Y-%m-%d"), id as u32)
}

/// Who'll see them, said before they're committed.
pub fn audience(harness: &str, repo: &str) -> String {
    let place = if harness == repo {
        format!("They're committed to {repo} under {ROOT}/ and show in the issue to anyone who can see it.")
    } else {
        format!("They're committed to the harness, {harness}, under {ROOT}/, and show in the issue only to people who can read {harness}.")
    };
    format!("{place} Git keeps them in its history, so leave out customer details and anything else sensitive.")
}

fn refusal_needs_pull_request(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("protected branch") || lower.contains("rule") || lower.contains("pull request")
}

/// Commits the files to the harness's default branch in one commit and
/// returns its ID. A head that moved is tried once more; a branch whose
/// rules refuse a direct commit gets it through a pull request. A write.
pub fn commit_files(token: &str, harness: &str, files: &[(String, Vec<u8>)], message: &str) -> Result<String, Error> {
    use base64::Engine;
    let (owner, name) = harness.split_once('/').ok_or_else(|| Error::Other(format!("{harness} isn't owner/name")))?;
    let additions: Vec<Value> = files.iter().map(|(path, data)| json!({ "path": path, "contents": base64::engine::general_purpose::STANDARD.encode(data) })).collect();
    let commit = |branch: &str, head: &str| {
        github::mutate(
            token,
            "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
            json!({ "input": {
                "branch": { "repositoryNameWithOwner": harness, "branchName": branch },
                "expectedHeadOid": head,
                "message": { "headline": message },
                "fileChanges": { "additions": additions },
            } }),
            "createCommitOnBranch",
        )
        .map(|v| v["commit"]["oid"].as_str().unwrap_or_default().to_string())
    };
    for attempt in 0..2 {
        let data = github::graphql(
            token,
            "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id defaultBranchRef { name target { oid } } } }",
            json!({ "owner": owner, "name": name }),
        )?;
        let repo_id = data["repository"]["id"].as_str().ok_or_else(|| Error::Other(format!("Couldn't find {harness}")))?.to_string();
        let branch = data["repository"]["defaultBranchRef"]["name"].as_str().unwrap_or("main").to_string();
        let head = data["repository"]["defaultBranchRef"]["target"]["oid"].as_str().unwrap_or_default().to_string();
        match commit(&branch, &head) {
            Ok(oid) => return Ok(oid),
            Err(Error::Other(m)) if attempt == 0 && m.to_lowercase().contains("expected") => continue,
            Err(Error::Other(m)) if refusal_needs_pull_request(&m) => return through_pull_request(token, harness, &repo_id, &branch, &head, &commit, message),
            Err(e) => return Err(e),
        }
    }
    Err(Error::Other(format!("{harness} kept moving; try again.")))
}

fn through_pull_request(
    token: &str,
    harness: &str,
    repo_id: &str,
    base: &str,
    head: &str,
    commit: &dyn Fn(&str, &str) -> Result<String, Error>,
    message: &str,
) -> Result<String, Error> {
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    let branch = format!("gannin/issue-images-{stamp}");
    github::mutate(
        token,
        "mutation($input: CreateRefInput!) { createRef(input: $input) { ref { id } } }",
        json!({ "input": { "repositoryId": repo_id, "name": format!("refs/heads/{branch}"), "oid": head } }),
        "createRef",
    )?;
    let oid = commit(&branch, head)?;
    let pr = github::mutate(
        token,
        "mutation($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { id url } } }",
        json!({ "input": { "repositoryId": repo_id, "baseRefName": base, "headRefName": branch, "title": message, "body": format!("Images for a new issue, from Gannin. {harness}'s rules don't take a direct commit; the issue links them at {oid}.") } }),
        "createPullRequest",
    )?;
    // Merged when GitHub allows; else the PR stays open, and the links
    // still work, as they name the commit.
    let _ = github::mutate(
        token,
        "mutation($id: ID!) { mergePullRequest(input: { pullRequestId: $id }) { pullRequest { id } } }",
        json!({ "id": pr["pullRequest"]["id"] }),
        "mergePullRequest",
    );
    Ok(oid)
}

/// The link an issue shows an image by: the file at that commit, raw.
pub fn url(harness: &str, commit: &str, path: &str) -> String {
    format!("https://github.com/{harness}/blob/{commit}/{path}?raw=true")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_links_and_drops() {
        let text = "Intro\n\n![a](attachment:a.png)\n\n![gone](attachment:gone.png)";
        let out = body(text, &[("a.png".into(), "U".into()), ("b.png".into(), "V".into())]);
        assert_eq!(out, "Intro\n\n![a](U)\n\n![b](V)");
    }

    #[test]
    fn markdown_template() {
        let t = parse_template("bug.md", "---\nname: Bug\nabout: Something broke\nlabels: [bug, triage]\n---\n\n## What happened\n").unwrap();
        assert_eq!(t.name, "Bug");
        assert_eq!(t.labels, vec!["bug", "triage"]);
        assert_eq!(t.body, "## What happened");
    }

    #[test]
    fn form_template() {
        let t = parse_template("feature.yml", "name: Feature\ndescription: Ask for it\nlabels:\n  - enhancement\nbody:\n  - type: textarea\n    attributes:\n      label: Problem\n").unwrap();
        assert_eq!(t.labels, vec!["enhancement"]);
        assert_eq!(t.body, "### Problem\n\n");
        assert!(parse_template("config.yml", "blank_issues_enabled: false").is_none());
    }
}
