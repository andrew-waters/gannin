//! Todos: a plain checklist kept in Marra's window, with no AI in it.
//! Each one keeps when it was added and when it was ticked off. They live
//! in `~/.gannin/todos.json` on this Mac only, and nothing sends them to
//! Marra's claude or anywhere else.

use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Todo {
    pub id: String,
    pub text: String,
    pub added: DateTime<Local>,
    #[serde(default)]
    pub done: Option<DateTime<Local>>,
}

fn path() -> PathBuf {
    crate::paths::app_dir().join("todos.json")
}

/// Every todo, in the order they were added; none when there's no file or
/// it can't be read.
pub fn load() -> Vec<Todo> {
    std::fs::read(path()).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

/// Writes to a temporary file and moves it over, so a half-written list is
/// never read back.
pub fn save(todos: &[Todo]) {
    let path = path();
    let Ok(json) = serde_json::to_vec_pretty(todos) else { return };
    if let Some(folder) = path.parent() {
        let _ = std::fs::create_dir_all(folder);
    }
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, json).is_ok() {
        let _ = std::fs::rename(&temporary, &path);
    }
}

pub fn add(todos: &mut Vec<Todo>, text: &str) {
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    todos.push(Todo { id: uuid::Uuid::new_v4().simple().to_string()[..8].to_string(), text: text.to_string(), added: Local::now(), done: None });
    save(todos);
}

/// Ticks it off, or back on.
pub fn toggle(todos: &mut [Todo], id: &str) {
    if let Some(todo) = todos.iter_mut().find(|t| t.id == id) {
        todo.done = match todo.done {
            Some(_) => None,
            None => Some(Local::now()),
        };
        save(todos);
    }
}

pub fn remove(todos: &mut Vec<Todo>, id: &str) {
    todos.retain(|t| t.id != id);
    save(todos);
}

/// Removes every ticked-off one.
pub fn clear_done(todos: &mut Vec<Todo>) {
    todos.retain(|t| t.done.is_none());
    save(todos);
}

/// When: "09:14" today, "Mon 09:14" this week, else "12 Nov 09:14".
pub fn when(at: DateTime<Local>) -> String {
    let now = Local::now();
    if at.date_naive() == now.date_naive() {
        at.format("%H:%M").to_string()
    } else if (now - at).num_days() < 7 {
        at.format("%a %H:%M").to_string()
    } else {
        at.format("%-d %b %H:%M").to_string()
    }
}

/// How long it took, from added to done: "12m", "3h 5m", "2d 4h".
pub fn took(todo: &Todo) -> Option<String> {
    let minutes = (todo.done? - todo.added).num_minutes().max(0);
    Some(match minutes {
        m if m < 60 => format!("{m}m"),
        m if m < 60 * 24 => format!("{}h {}m", m / 60, m % 60),
        m => format!("{}d {}h", m / 60 / 24, m / 60 % 24),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn took_reads_as_a_duration() {
        let added = Local::now() - chrono::Duration::minutes(185);
        let todo = Todo { id: "a".into(), text: "x".into(), added, done: Some(added + chrono::Duration::minutes(185)) };
        assert_eq!(took(&todo).as_deref(), Some("3h 5m"));
        assert_eq!(took(&Todo { done: None, ..todo }), None);
    }
}
