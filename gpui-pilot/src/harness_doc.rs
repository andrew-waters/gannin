//! Reads a harness document, as Gannin's `HarnessDocument.init(path:...)`
//! (parser version 11) does: its kind from where it sits or its front
//! matter's `type`, the title, status, summary, date, area, checkboxes and
//! the issues it's about or mentions. Keep it in step with
//! `HarnessModels.swift` and the harness's `STANDARDS.md`.

use crate::harness::{Doc, HarnessKind};
use chrono::{DateTime, NaiveDate, Utc};
use std::collections::BTreeMap;

/// The harness's layout, as `HarnessKind(path:)`: `plans/` (and
/// `requirements/<module>/plans/`), the rest of `requirements/`,
/// `decisions/` and the others; READMEs and `_templates` aren't documents,
/// except in `research/` and `refines/`, where each folder's README is.
fn kind_of(path: &str) -> Option<HarnessKind> {
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    if !path.ends_with(".md") {
        return None;
    }
    let (top, file) = (*parts.first()?, *parts.last()?);
    if top == "research" || top == "refines" {
        return (parts.len() == 3 && file == "README.md").then(|| if top == "research" { HarnessKind::Research } else { HarnessKind::Refines });
    }
    if file == "README.md" || file.starts_with('_') {
        return None;
    }
    Some(match top {
        "plans" => HarnessKind::Plans,
        "requirements" if parts.contains(&"plans") => HarnessKind::Plans,
        "requirements" => HarnessKind::Requirements,
        "decisions" => HarnessKind::Decisions,
        "findings" => HarnessKind::Findings,
        "skills" => HarnessKind::Skills,
        "prompts" => HarnessKind::Prompts,
        "learnings" => HarnessKind::Learnings,
        "specialists" => HarnessKind::Specialists,
        _ => return None,
    })
}

/// A front matter `type`: `plan`, `requirement` and so on.
fn kind_of_type(kind: &str) -> Option<HarnessKind> {
    let singular = |k: HarnessKind| match k {
        HarnessKind::Plans => "plan",
        HarnessKind::Requirements => "requirement",
        HarnessKind::Decisions => "decision",
        HarnessKind::Findings => "finding",
        HarnessKind::Skills => "skill",
        HarnessKind::Prompts => "prompt",
        HarnessKind::Learnings => "learning",
        HarnessKind::Research => "research",
        HarnessKind::Refines => "refine",
        HarnessKind::Specialists => "specialist",
    };
    HarnessKind::ALL.into_iter().find(|k| singular(*k) == kind.to_lowercase())
}

/// A front matter value: text, or a list.
#[derive(Clone)]
enum Value {
    Text(String),
    List(Vec<String>),
}

impl Value {
    fn text(&self) -> Option<String> {
        match self {
            Value::Text(t) => (!t.is_empty()).then(|| t.clone()),
            Value::List(items) => items.first().cloned(),
        }
    }

    fn list(&self) -> Vec<String> {
        match self {
            Value::Text(t) if t.is_empty() => Vec::new(),
            Value::Text(t) => vec![t.clone()],
            Value::List(items) => items.clone(),
        }
    }
}

fn unquoted(text: &str) -> String {
    let text = text.trim();
    let b = text.as_bytes();
    if b.len() >= 2 && b[0] == b[b.len() - 1] && (b[0] == b'"' || b[0] == b'\'') {
        return text[1..text.len() - 1].to_string();
    }
    text.to_string()
}

/// The front matter, as `HarnessFrontMatter.parse`: `key: value`,
/// `[inline, lists]`, `- item` lists, and `>` or `|` blocks. None when the
/// text doesn't open with `---` or never closes it.
fn front_matter(lines: &[&str]) -> Option<BTreeMap<String, Value>> {
    if lines.first()?.trim() != "---" {
        return None;
    }
    let mut fields: BTreeMap<String, Value> = BTreeMap::new();
    let mut key: Option<String> = None;
    let mut block: Option<Vec<String>> = None;
    fn flush(fields: &mut BTreeMap<String, Value>, key: &Option<String>, block: &mut Option<Vec<String>>) {
        if let (Some(key), Some(lines)) = (key, block.take()) {
            fields.insert(key.clone(), Value::Text(lines.into_iter().filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")));
        }
    }
    for line in &lines[1..] {
        let trimmed = line.trim();
        if trimmed == "---" {
            flush(&mut fields, &key, &mut block);
            return Some(fields);
        }
        if let Some(lines) = block.as_mut() {
            if line.starts_with(' ') || line.starts_with('\t') || trimmed.is_empty() {
                lines.push(trimmed.to_string());
                continue;
            }
            flush(&mut fields, &key, &mut block);
        }
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let (Some(item), Some(k)) = (trimmed.strip_prefix("- "), key.as_ref()) {
            let mut items = match fields.get(k) {
                Some(Value::List(items)) => items.clone(),
                _ => Vec::new(),
            };
            items.push(unquoted(item));
            fields.insert(k.clone(), Value::List(items));
            continue;
        }
        let Some(colon) = line.find(':') else { continue };
        if line.starts_with(' ') {
            continue;
        }
        let name = line[..colon].trim();
        if name.is_empty() || name.contains(' ') {
            continue;
        }
        let value = line[colon + 1..].trim();
        key = Some(name.to_string());
        if [">", "|", ">-", "|-"].contains(&value) {
            block = Some(Vec::new());
        } else if value.starts_with('[') && value.ends_with(']') && value.len() >= 2 {
            let items = value[1..value.len() - 1].split(',').map(unquoted).filter(|s| !s.is_empty()).collect();
            fields.insert(name.to_string(), Value::List(items));
        } else {
            fields.insert(name.to_string(), if value.is_empty() { Value::List(Vec::new()) } else { Value::Text(unquoted(value)) });
        }
    }
    None
}

/// A `YYYY-MM-DD` at the start of a file or folder name.
fn leading_date(name: &str) -> Option<DateTime<Utc>> {
    let head = name.get(..10)?;
    NaiveDate::parse_from_str(head, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)).map(|d| d.and_utc())
}

/// `2026-07-15-dwt-receipt.md` as "Dwt receipt".
fn title_from_file(name: &str) -> String {
    let mut stem = name.strip_suffix(".md").unwrap_or(name);
    if leading_date(stem).is_some() {
        stem = &stem[10..];
    }
    let words = stem.split(['-', '_']).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ");
    let mut chars = words.chars();
    chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
}

fn table_cells(line: &str) -> Vec<String> {
    if !line.starts_with('|') {
        return Vec::new();
    }
    line.split('|').map(str::trim).filter(|c| !c.is_empty()).map(str::to_string).collect()
}

fn is_word(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// `owner/name#123`, GitHub issue and PR links, and `PRD-123` (the
/// harness's usual issue repo, `None`), as `HarnessDocument.references`.
fn references(line: &str, subject: bool, out: &mut Vec<(Option<String>, i64, bool)>) {
    let b = line.as_bytes();
    let name_char = |c: u8| c.is_ascii_alphanumeric() || c == b'.' || c == b'_' || c == b'-';
    let owner_char = |c: u8| c.is_ascii_alphanumeric() || c == b'-';
    let mut i = 0;
    while i < b.len() {
        let sep = if b[i] == b'#' {
            Some(1)
        } else if b[i..].starts_with(b"/issues/") {
            Some(8)
        } else if b[i..].starts_with(b"/pull/") {
            Some(6)
        } else {
            None
        };
        let Some(sep) = sep else {
            i += 1;
            continue;
        };
        let digits_end = (i + sep..b.len()).find(|&j| !b[j].is_ascii_digit()).unwrap_or(b.len());
        // The name runs back from the separator to a slash; the owner back
        // from that slash, starting at a letter or digit.
        let mut name_start = i;
        while name_start > 0 && name_char(b[name_start - 1]) {
            name_start -= 1;
        }
        let found = (|| {
            if digits_end == i + sep || name_start == i || name_start == 0 || b[name_start - 1] != b'/' {
                return None;
            }
            let slash = name_start - 1;
            let mut owner_start = slash;
            while owner_start > 0 && owner_char(b[owner_start - 1]) {
                owner_start -= 1;
            }
            while owner_start < slash && b[owner_start] == b'-' {
                owner_start += 1;
            }
            if owner_start == slash {
                return None;
            }
            let number = line[i + sep..digits_end].parse().ok()?;
            Some((format!("{}/{}", &line[owner_start..slash], &line[name_start..i]), number))
        })();
        match found {
            Some((repo, number)) => {
                out.push((Some(repo), number, subject));
                i = digits_end;
            }
            None => i += sep,
        }
    }
    let lower = line.to_ascii_lowercase();
    let lb = lower.as_bytes();
    let mut from = 0;
    while let Some(at) = lower[from..].find("prd-").map(|a| a + from) {
        from = at + 4;
        if at > 0 && is_word(lb[at - 1]) {
            continue;
        }
        let end = (at + 4..lb.len()).find(|&j| !lb[j].is_ascii_digit()).unwrap_or(lb.len());
        if end == at + 4 || (end < lb.len() && is_word(lb[end])) {
            continue;
        }
        if let Ok(number) = lower[at + 4..end].parse() {
            out.push((None, number, subject));
        }
    }
}

/// A document from its path and text, or None for a file that isn't one.
pub fn parse(path: &str, text: &str, harness: &str, branch: &str) -> Option<Doc> {
    let path_kind = kind_of(path)?;
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let file = parts.last().copied().unwrap_or(path);
    let module = (matches!(parts.first(), Some(&"requirements") | Some(&"learnings")) && parts.len() > 2).then(|| parts[1].to_string());
    let date = parts.iter().rev().find_map(|p| leading_date(p));
    let lines: Vec<&str> = text.lines().collect();
    let front = front_matter(&lines);
    let field = |name: &str| front.as_ref().and_then(|f| f.get(name));
    let kind = field("type").and_then(Value::text).and_then(|t| kind_of_type(&t)).unwrap_or(path_kind);
    let summary = field("summary").and_then(Value::text).or_else(|| field("description").and_then(Value::text));
    let domains = field("domains").map(Value::list);
    let title = lines.iter().map(|l| l.trim()).find(|l| l.starts_with("# ")).map(|l| l[2..].trim().to_string()).unwrap_or_else(|| title_from_file(file));

    let mut status: Option<String> = None;
    let (mut tasks, mut done) = (0, 0);
    let mut refs: Vec<(Option<String>, i64, bool)> = Vec::new();
    let mut in_front = lines.first() == Some(&"---");
    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if in_front && index > 0 && trimmed == "---" {
            in_front = false;
        }
        let cells = table_cells(trimmed);
        let label = cells.first().map(|c| c.to_lowercase());
        if status.is_none() && label.as_deref() == Some("status") && cells.len() > 1 {
            status = Some(cells[1].clone());
        }
        let key = trimmed.split(':').find(|p| !p.is_empty()).map(str::to_lowercase);
        let subject = matches!(label.as_deref(), Some("github" | "issue" | "issues" | "ticket")) || (in_front && matches!(key.as_deref(), Some("github" | "issue" | "issues")));
        references(line, subject, &mut refs);
        if trimmed.starts_with("- [") || trimmed.starts_with("* [") {
            let box_ = trimmed.trim_start_matches(['-', '*', ' ']);
            if box_.starts_with("[ ]") {
                tasks += 1;
            }
            if box_.starts_with("[x]") || box_.starts_with("[X]") {
                tasks += 1;
                done += 1;
            }
        }
    }
    references(file, true, &mut refs);
    for issue in field("issues").map(Value::list).unwrap_or_default() {
        references(&issue, true, &mut refs);
    }
    let status = field("status").and_then(Value::text).or(status);
    // One per issue, the subject if any mention is.
    let mut merged: BTreeMap<(String, i64), (Option<String>, i64, bool)> = BTreeMap::new();
    for r in refs {
        let key = (r.0.clone().unwrap_or_default(), r.1);
        if merged.get(&key).is_some_and(|held| held.2 || !r.2) {
            continue;
        }
        merged.insert(key, r);
    }

    let mut facts: Vec<(String, String)> = front
        .as_ref()
        .map(|f| {
            f.iter()
                .filter(|(k, _)| !matches!(k.as_str(), "summary" | "status" | "type"))
                .map(|(k, v)| (k.clone(), v.list().join(", ")))
                .filter(|(_, v)| !v.is_empty())
                .collect()
        })
        .unwrap_or_default();
    facts.sort();
    Some(Doc {
        path: path.to_string(),
        harness: harness.to_string(),
        branch: branch.to_string(),
        kind,
        title,
        text: text.to_string(),
        standard: front.is_some() && summary.is_some(),
        status,
        summary,
        date,
        area: domains.and_then(|d| d.into_iter().next()).or(module),
        tasks,
        tasks_done: done,
        references: merged.into_values().collect(),
        front_matter: facts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_plan() {
        let text = "---\ntype: plan\nsummary: Do the thing\nstatus: in-progress\ndomains: [billing, api]\nissues:\n  - acme/api#12\n---\n# The thing\n\n- [x] one\n- [ ] two\n\nSee acme/web#3 and PRD-9.\n";
        let doc = parse("plans/2026-07-15-the-thing.md", text, "acme/harness", "main").unwrap();
        assert_eq!(doc.title, "The thing");
        assert_eq!(doc.status.as_deref(), Some("in-progress"));
        assert_eq!(doc.summary.as_deref(), Some("Do the thing"));
        assert_eq!(doc.area.as_deref(), Some("billing"));
        assert_eq!((doc.tasks, doc.tasks_done), (2, 1));
        assert!(doc.standard);
        assert!(doc.date.is_some());
        assert!(doc.references.contains(&(Some("acme/api".into()), 12, true)));
        assert!(doc.references.contains(&(Some("acme/web".into()), 3, false)));
        assert!(doc.references.contains(&(None, 9, false)));
    }

    #[test]
    fn reads_links_and_skips_non_documents() {
        let mut found = Vec::new();
        references("https://github.com/acme/lib.slugify/pull/4 and acme/api/issues/7", false, &mut found);
        assert_eq!(found, vec![(Some("acme/lib.slugify".into()), 4, false), (Some("acme/api".into()), 7, false)]);
        assert!(parse("plans/README.md", "# x", "a/b", "main").is_none());
        assert!(parse("research/2026-01-01-x/README.md", "# x", "a/b", "main").is_some());
        assert_eq!(title_from_file("2026-07-15-dwt-receipt.md"), "Dwt receipt");
    }
}
