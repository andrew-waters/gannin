//! Which of a session's pull requests need which others merged first.
//!
//! Two signs count, and nothing is guessed:
//! - A stacked branch: a PR whose base is another's head, in one repo.
//! - A written link in its description: "Depends on ctrl-hub/mono#1630",
//!   "Blocked by #12", "Needs infra.k8s#15199" and the like, or a list
//!   under a "Dependencies" heading. Work sessions are briefed to write
//!   one (`launch.rs`), so cross-repo work carries its order.

use std::collections::HashMap;

/// A PR as (repo, number).
pub type Key = (String, i64);

/// The words that, ahead of a reference on the same line, say it's needed
/// first.
const SIGNS: [&str; 11] = ["depends on", "dependent on", "depend on", "blocked by", "requires", "needs", "builds on", "stacked on", "merge after", "after", "waiting on"];

/// The PRs a description says it needs, with `repo` for short references.
pub fn needs(body: &str, repo: &str) -> Vec<Key> {
    let mut out: Vec<Key> = Vec::new();
    let mut in_section = false;
    for line in body.lines() {
        let plain: String = line.chars().filter(|c| !matches!(c, '*' | '_' | '`')).collect::<String>().to_lowercase();
        let trimmed = plain.trim_start_matches(['>', ' ']).trim();
        if trimmed.starts_with('#') && trimmed.trim_start_matches('#').starts_with(' ') {
            // A heading: a Dependencies section lists what's needed.
            in_section = trimmed.contains("depend") || trimmed.contains("blocked by") || trimmed.contains("merge order");
            continue;
        }
        let rest = if in_section && (trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("1")) {
            Some(trimmed.to_string())
        } else {
            sign_at(trimmed).map(|at| trimmed[at..].to_string())
        };
        if let Some(rest) = rest {
            for key in references(&rest, repo) {
                if !out.contains(&key) {
                    out.push(key);
                }
            }
        }
    }
    out
}

/// Where the text after a sign starts, when the line has one as words.
fn sign_at(line: &str) -> Option<usize> {
    SIGNS.iter().find_map(|sign| {
        line.match_indices(sign).find_map(|(at, _)| {
            let before = line[..at].chars().next_back();
            let after = line[at + sign.len()..].chars().next();
            let edge = |c: Option<char>| c.is_none_or(|c| !c.is_alphanumeric());
            (edge(before) && edge(after)).then_some(at + sign.len())
        })
    })
}

/// The PR references in some text: GitHub pull URLs, `owner/repo#n`,
/// `repo#n` (in `repo`'s owner) and `#n` (in `repo`).
fn references(text: &str, repo: &str) -> Vec<Key> {
    let owner = repo.split('/').next().unwrap_or("");
    let mut out = Vec::new();
    for token in text.split(|c: char| c.is_whitespace() || ",;()[]<>".contains(c)) {
        let token = token.trim_end_matches(['.', ':', '!', '?']);
        if let Some(path) = token.strip_prefix("https://github.com/") {
            let parts: Vec<&str> = path.split('/').collect();
            if parts.len() >= 4 && parts[2] == "pull" {
                if let Ok(n) = parts[3].parse() {
                    out.push((format!("{}/{}", parts[0], parts[1]), n));
                }
            }
            continue;
        }
        let Some((name, number)) = token.rsplit_once('#') else { continue };
        let Ok(number) = number.parse::<i64>() else { continue };
        let full = match name.split('/').count() {
            _ if name.is_empty() => repo.to_string(),
            1 => format!("{owner}/{name}"),
            2 => name.to_string(),
            _ => continue,
        };
        out.push((full, number));
    }
    out
}

/// A PR as the graph needs it.
pub struct Node {
    pub key: Key,
    pub base: String,
    pub head: String,
    pub needs: Vec<Key>,
}

/// What each PR needs first: its written links (to any PR, listed or not)
/// and the listed PR its branch is stacked on. Never itself.
pub fn graph(nodes: &[Node]) -> HashMap<Key, Vec<Key>> {
    let mut out: HashMap<Key, Vec<Key>> = HashMap::new();
    for node in nodes {
        let mut needs: Vec<Key> = Vec::new();
        let mut add = |key: Key| {
            if key != node.key && !needs.iter().any(|k| same(k, &key)) {
                needs.push(key);
            }
        };
        for key in &node.needs {
            add(key.clone());
        }
        if let Some(under) = nodes.iter().find(|o| o.key != node.key && o.key.0.eq_ignore_ascii_case(&node.key.0) && !o.head.is_empty() && o.head == node.base) {
            add(under.key.clone());
        }
        if !needs.is_empty() {
            out.insert(node.key.clone(), needs);
        }
    }
    out
}

pub fn same(a: &Key, b: &Key) -> bool {
    a.1 == b.1 && a.0.eq_ignore_ascii_case(&b.0)
}

/// The listed PRs with what's needed first ahead of what needs it, and how
/// deep each sits in its chain (0 for one that needs nothing listed).
/// Otherwise in the order given; a loop is left as it was given.
pub fn order(keys: &[Key], graph: &HashMap<Key, Vec<Key>>) -> Vec<(usize, usize)> {
    let listed = |k: &Key| keys.iter().position(|o| same(o, k));
    let mut depth: Vec<Option<usize>> = vec![None; keys.len()];
    fn depth_of(i: usize, keys: &[Key], graph: &HashMap<Key, Vec<Key>>, depth: &mut Vec<Option<usize>>, seen: &mut Vec<usize>, listed: &dyn Fn(&Key) -> Option<usize>) -> usize {
        if let Some(d) = depth[i] {
            return d;
        }
        if seen.contains(&i) {
            return 0;
        }
        seen.push(i);
        let d = graph.get(&keys[i]).into_iter().flatten().filter_map(listed).map(|j| depth_of(j, keys, graph, depth, seen, listed) + 1).max().unwrap_or(0);
        seen.pop();
        depth[i] = Some(d);
        d
    }
    for i in 0..keys.len() {
        depth_of(i, keys, graph, &mut depth, &mut Vec::new(), &listed);
    }
    let mut out: Vec<(usize, usize)> = depth.into_iter().enumerate().map(|(i, d)| (i, d.unwrap_or(0))).collect();
    // Each chain kept together: a PR straight after the last thing it needs.
    let mut placed: Vec<(usize, usize)> = Vec::new();
    out.sort_by_key(|&(i, d)| (d, i));
    for (i, d) in out {
        let after = graph.get(&keys[i]).into_iter().flatten().filter_map(&listed).filter_map(|j| placed.iter().position(|&(p, _)| p == j)).max();
        match after {
            Some(at) => {
                // Past anything already hanging off that one.
                let mut at = at + 1;
                while at < placed.len() && placed[at].1 >= d {
                    at += 1;
                }
                placed.insert(at, (i, d));
            }
            None => placed.push((i, d)),
        }
    }
    placed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(repo: &str, n: i64) -> Key {
        (repo.to_string(), n)
    }

    #[test]
    fn written_links_in_a_description() {
        let body = "Adds the service report.\n\n**Depends on:** ctrl-hub/infra.k8s#15199 and mono#1630.\n\nAfter this lands, users can see it.\nCloses #45\n";
        assert_eq!(needs(body, "ctrl-hub/clients"), vec![key("ctrl-hub/infra.k8s", 15199), key("ctrl-hub/mono", 1630)]);
        let section = "## Dependencies\n\n- https://github.com/ctrl-hub/mono/pull/1630\n- #12\n\n## Testing\n\n- #99 is unrelated\n";
        assert_eq!(needs(section, "ctrl-hub/clients"), vec![key("ctrl-hub/mono", 1630), key("ctrl-hub/clients", 12)]);
        assert_eq!(needs("Blocked by #7", "o/r"), vec![key("o/r", 7)]);
        // Signs only as words, and mentions without one don't count.
        assert!(needs("Fixes the requirement in #7\nSee mono#3", "o/r").is_empty());
    }

    #[test]
    fn stacked_and_written_make_one_graph_in_merge_order() {
        let nodes = vec![
            Node { key: key("o/clients", 2), base: "main".into(), head: "c".into(), needs: vec![key("o/mono", 1)] },
            Node { key: key("o/mono", 1), base: "main".into(), head: "m".into(), needs: vec![key("o/infra", 3)] },
            Node { key: key("o/infra", 3), base: "main".into(), head: "i".into(), needs: Vec::new() },
            Node { key: key("o/mono", 4), base: "m".into(), head: "m2".into(), needs: Vec::new() },
            Node { key: key("o/web", 5), base: "main".into(), head: "w".into(), needs: Vec::new() },
        ];
        let g = graph(&nodes);
        assert_eq!(g[&key("o/mono", 4)], vec![key("o/mono", 1)]);
        let keys: Vec<Key> = nodes.iter().map(|n| n.key.clone()).collect();
        let ordered: Vec<(i64, usize)> = order(&keys, &g).into_iter().map(|(i, d)| (keys[i].1, d)).collect();
        assert_eq!(ordered, vec![(3, 0), (1, 1), (2, 2), (4, 2), (5, 0)]);
    }

    #[test]
    fn a_loop_is_left_alone() {
        let nodes = vec![
            Node { key: key("o/a", 1), base: "main".into(), head: "a".into(), needs: vec![key("o/b", 2)] },
            Node { key: key("o/b", 2), base: "main".into(), head: "b".into(), needs: vec![key("o/a", 1)] },
        ];
        let keys: Vec<Key> = nodes.iter().map(|n| n.key.clone()).collect();
        assert_eq!(order(&keys, &graph(&nodes)).len(), 2);
    }
}
