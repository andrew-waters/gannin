//! What a note or a todo is about: a pull request (a review is one), an
//! issue, or another note. Kept as text in each, `pr:owner/repo#12`,
//! `issue:owner/repo#45` or `note:3f9a1c2e`, on one side only: the other
//! side finds it by looking (`NotesStore::linked`), so a link can't be half
//! removed.

use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Link {
    Pr { repo: String, number: u64 },
    Issue { repo: String, number: u64 },
    Note(String),
}

impl Link {
    pub fn parse(text: &str) -> Option<Link> {
        let (kind, rest) = text.trim().split_once(':')?;
        if kind == "note" {
            return (!rest.is_empty()).then(|| Link::Note(rest.to_string()));
        }
        let (repo, number) = rest.rsplit_once('#')?;
        let number = number.parse().ok()?;
        if repo.split('/').filter(|p| !p.is_empty()).count() != 2 {
            return None;
        }
        let repo = repo.to_string();
        match kind {
            "pr" => Some(Link::Pr { repo, number }),
            "issue" => Some(Link::Issue { repo, number }),
            _ => None,
        }
    }

    /// The org a PR or issue is in.
    pub fn org(&self) -> Option<&str> {
        match self {
            Link::Pr { repo, .. } | Link::Issue { repo, .. } => repo.split('/').next(),
            Link::Note(_) => None,
        }
    }

    /// `clients#2581`: the repo without its owner.
    pub fn short(&self) -> String {
        match self {
            Link::Pr { repo, number } | Link::Issue { repo, number } => format!("{}#{number}", repo.rsplit('/').next().unwrap_or(repo)),
            Link::Note(id) => id.clone(),
        }
    }

    pub fn icon(&self) -> &'static str {
        match self {
            Link::Pr { .. } => crate::icons::PULL,
            Link::Issue { .. } => crate::icons::ISSUE,
            Link::Note(_) => crate::icons::NOTE,
        }
    }

    /// What two links to the same thing share. A PR and an issue in one
    /// repo never share a number, so `owner/repo#12` written in a note finds
    /// either, whichever it turns out to be.
    pub fn key(&self) -> String {
        match self {
            Link::Pr { repo, number } | Link::Issue { repo, number } => format!("{}#{number}", repo.to_lowercase()),
            Link::Note(id) => format!("note:{id}"),
        }
    }

    pub fn url(&self) -> Option<String> {
        match self {
            Link::Pr { repo, number } => Some(format!("https://github.com/{repo}/pull/{number}")),
            Link::Issue { repo, number } => Some(format!("https://github.com/{repo}/issues/{number}")),
            Link::Note(_) => None,
        }
    }
}

impl fmt::Display for Link {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Link::Pr { repo, number } => write!(f, "pr:{repo}#{number}"),
            Link::Issue { repo, number } => write!(f, "issue:{repo}#{number}"),
            Link::Note(id) => write!(f, "note:{id}"),
        }
    }
}

/// The PRs and issues mentioned in text: GitHub addresses (`/pull/12`,
/// `/issues/12`) and `owner/repo#12`, once each.
pub fn mentions(text: &str) -> Vec<Link> {
    let b = text.as_bytes();
    let name_char = |c: u8| c.is_ascii_alphanumeric() || c == b'.' || c == b'_' || c == b'-';
    let owner_char = |c: u8| c.is_ascii_alphanumeric() || c == b'-';
    let mut out: Vec<Link> = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let (sep, pull) = if b[i] == b'#' {
            (1, false)
        } else if b[i..].starts_with(b"/issues/") {
            (8, false)
        } else if b[i..].starts_with(b"/pull/") {
            (6, true)
        } else {
            i += 1;
            continue;
        };
        let digits_end = (i + sep..b.len()).find(|&j| !b[j].is_ascii_digit()).unwrap_or(b.len());
        // The name runs back from the separator to a slash; the owner back
        // from that slash.
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
            if owner_start == slash {
                return None;
            }
            let number = text[i + sep..digits_end].parse().ok()?;
            let repo = format!("{}/{}", &text[owner_start..slash], &text[name_start..i]);
            Some(if pull { Link::Pr { repo, number } } else { Link::Issue { repo, number } })
        })();
        match found {
            Some(link) => {
                if !out.iter().any(|l| l.key() == link.key()) {
                    out.push(link);
                }
                i = digits_end;
            }
            None => i += sep,
        }
    }
    out
}

/// A link from what someone pasted: a GitHub PR or issue address,
/// `owner/repo#12`, or a link as written here.
pub fn from_input(text: &str) -> Option<Link> {
    let text = text.trim().trim_end_matches('/');
    if let Some(link) = Link::parse(text) {
        return Some(link);
    }
    if !text.contains("github.com/") {
        return mentions(text).into_iter().next();
    }
    let path = text.split_once("github.com/")?.1;
    let path = path.split(['?', '#']).next()?;
    let parts: Vec<&str> = path.split('/').collect();
    let [owner, name, kind, number, ..] = parts.as_slice() else { return None };
    let repo = format!("{owner}/{name}");
    let number = number.parse().ok()?;
    match *kind {
        "pull" => Some(Link::Pr { repo, number }),
        "issues" => Some(Link::Issue { repo, number }),
        _ => None,
    }
}

/// The links among `texts` that read, skipping any that don't.
pub fn parse_all(texts: &[String]) -> Vec<Link> {
    texts.iter().filter_map(|t| Link::parse(t)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_read_back_as_written() {
        for text in ["pr:ctrl-hub/clients#2581", "issue:ctrl-hub/product#45", "note:3f9a1c2e"] {
            assert_eq!(Link::parse(text).unwrap().to_string(), text);
        }
        assert_eq!(Link::parse("pr:ctrl-hub/clients#2581").unwrap().short(), "clients#2581");
        assert_eq!(Link::parse("pr:clients#2"), None);
        assert_eq!(Link::parse("pr:a/b#x"), None);
        assert_eq!(Link::parse("thing:a/b#1"), None);
        assert_eq!(from_input("https://github.com/ctrl-hub/clients/pull/2581/files").unwrap().to_string(), "pr:ctrl-hub/clients#2581");
        assert_eq!(from_input("https://github.com/ctrl-hub/product/issues/45#issuecomment-1").unwrap().to_string(), "issue:ctrl-hub/product#45");
        assert_eq!(from_input("https://github.com/ctrl-hub/product"), None);
        assert_eq!(from_input("ctrl-hub/clients#12").unwrap().key(), "ctrl-hub/clients#12");
        let found: Vec<String> = mentions("See https://github.com/ctrl-hub/clients/pull/2581/files and ctrl-hub/product#45, and #3 alone; ctrl-hub/Clients#2581 again.").iter().map(|l| l.to_string()).collect();
        assert_eq!(found, ["pr:ctrl-hub/clients#2581", "issue:ctrl-hub/product#45"]);
        assert!(mentions("https://github.com/ctrl-hub/product/issues/45#issuecomment-1").len() == 1);
    }
}
