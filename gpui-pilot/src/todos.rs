//! Todos: a plain checklist kept in Marra's window, with no AI in it.
//! Each one keeps when it was added and when it was ticked off, and what
//! it's about (`links.rs`). They live in `~/.gannin/todos.json` on this Mac
//! only, and nothing sends them to Marra's claude or anywhere else.
//! `NotesStore` (`notes.rs`) holds them for every window.
//!
//! A todo can be due on a day, and can stand for an unticked item in a
//! harness plan's checklist; it reminds once on its day, and ticks itself
//! off when the plan's item is ticked.

use chrono::{DateTime, Datelike, Duration, Local, Months, NaiveDate, Timelike, Weekday};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Todo {
    pub id: String,
    pub text: String,
    pub added: DateTime<Local>,
    #[serde(default)]
    pub done: Option<DateTime<Local>>,
    /// As `Link` writes them; none on todos from before links.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<NaiveDate>,
    /// The due day it last reminded for, so it reminds once a day it's set to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reminded: Option<NaiveDate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<PlanItem>,
}

/// An item in a harness plan's checklist, found again by its text.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlanItem {
    /// `owner/repo` of the harness.
    pub harness: String,
    pub path: String,
    pub title: String,
    pub item: String,
}

impl PlanItem {
    pub fn url(&self) -> String {
        format!("https://github.com/{}/blob/HEAD/{}", self.harness, self.path)
    }
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

/// Adds one; a due phrase at the end ("in a week", "by fri", "on 29 Nov")
/// becomes its due date and leaves the text.
pub fn add(todos: &mut Vec<Todo>, text: &str, links: Vec<String>) {
    let (text, due) = split_due(text.trim(), Local::now().date_naive());
    if text.is_empty() {
        return;
    }
    todos.push(Todo { id: new_id(), text, added: Local::now(), done: None, links, due, reminded: None, plan: None });
    save(todos);
}

/// A todo for a plan's checklist item, due when chosen.
pub fn add_plan(todos: &mut Vec<Todo>, plan: PlanItem, due: Option<NaiveDate>, links: Vec<String>) {
    todos.push(Todo { id: new_id(), text: plan.item.clone(), added: Local::now(), done: None, links, due, reminded: None, plan: Some(plan) });
    save(todos);
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_string()
}

pub fn set_due(todos: &mut [Todo], id: &str, due: Option<NaiveDate>) {
    if let Some(todo) = todos.iter_mut().find(|t| t.id == id) {
        todo.due = due;
        save(todos);
    }
}

/// Open ones due today or before, the most overdue first.
pub fn due_now(todos: &[Todo], today: NaiveDate) -> Vec<&Todo> {
    let mut due: Vec<&Todo> = todos.iter().filter(|t| t.done.is_none() && t.due.is_some_and(|d| d <= today)).collect();
    due.sort_by_key(|t| (t.due, t.added));
    due
}

/// Whether to remind about it now: open and due before today, or due today
/// once it's 9am, and not yet reminded for that day.
pub fn should_remind(todo: &Todo, now: DateTime<Local>) -> bool {
    let today = now.date_naive();
    match todo.due {
        Some(due) if todo.done.is_none() && todo.reminded != Some(due) => due < today || (due == today && now.hour() >= 9),
        _ => false,
    }
}

/// Those to remind about now, marked as reminded and saved.
pub fn remind(todos: &mut [Todo], now: DateTime<Local>) -> Vec<Todo> {
    let mut out = Vec::new();
    for todo in todos.iter_mut().filter(|t| should_remind(t, now)) {
        todo.reminded = todo.due;
        out.push(todo.clone());
    }
    if !out.is_empty() {
        save(todos);
    }
    out
}

/// Ticks off the open ones whose plan item is now ticked; `ticked` says
/// whether it is, `None` when the plan isn't known. True when any changed.
pub fn tick_plan_items(todos: &mut [Todo], ticked: impl Fn(&PlanItem) -> Option<bool>) -> bool {
    let mut changed = false;
    for todo in todos.iter_mut().filter(|t| t.done.is_none()) {
        if todo.plan.as_ref().and_then(&ticked) == Some(true) {
            todo.done = Some(Local::now());
            changed = true;
        }
    }
    if changed {
        save(todos);
    }
    changed
}

/// A checklist's items, as (ticked, text), in the order they're written.
pub fn checklist(text: &str) -> Vec<(bool, String)> {
    text.lines()
        .filter_map(|line| {
            let rest = line.trim_start().strip_prefix("- [").or_else(|| line.trim_start().strip_prefix("* ["))?;
            let (mark, item) = (rest.chars().next()?, rest.get(1..)?.strip_prefix(']')?);
            let ticked = match mark {
                ' ' => false,
                'x' | 'X' => true,
                _ => return None,
            };
            let item = item.trim();
            (!item.is_empty()).then(|| (ticked, item.to_string()))
        })
        .collect()
}

/// Whether the item is ticked in the plan's text; `None` when it's gone.
pub fn item_ticked(text: &str, item: &str) -> Option<bool> {
    checklist(text).into_iter().find(|(_, t)| t == item).map(|(ticked, _)| ticked)
}

/// The text without a due phrase at its end, and the day it names.
pub fn split_due(text: &str, today: NaiveDate) -> (String, Option<NaiveDate>) {
    let words: Vec<&str> = text.split_whitespace().collect();
    for n in (1..=4).rev() {
        if words.len() <= n {
            continue;
        }
        let tail: Vec<String> = words[words.len() - n..].iter().map(|w| w.trim_end_matches(['.', ',', '!', ';']).to_lowercase()).collect();
        let tail: Vec<&str> = tail.iter().map(String::as_str).collect();
        if let Some(due) = phrase(&tail, today) {
            let rest = words[..words.len() - n].join(" ");
            let rest = rest.trim_end_matches([',', '-', ':']).trim_end().to_string();
            return (rest, Some(due));
        }
    }
    (text.to_string(), None)
}

fn phrase(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    if let ["due", rest @ ..] = words {
        return if rest.is_empty() { None } else { phrase(rest, today).or_else(|| day(rest, today)) };
    }
    match words {
        ["today"] => Some(today),
        ["tomorrow" | "tmrw"] => Some(today + Duration::days(1)),
        ["next", "week"] => Some(next_weekday(today, Weekday::Mon)),
        ["in", rest @ ..] => span(rest, today),
        ["on" | "by", rest @ ..] => match rest {
            ["today"] | ["tomorrow" | "tmrw"] | ["next", "week"] => phrase(rest, today),
            _ => day(rest, today),
        },
        ["next", w] => weekday(w).map(|w| next_weekday(today, w)),
        _ => None,
    }
}

/// "a week", "2 weeks", "3d", "1w", "a month", "a fortnight".
fn span(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    let (count, unit) = match words {
        ["a" | "an" | "one", unit] => (1, unit.to_string()),
        [count, unit] => (count.parse::<u32>().ok()?, unit.to_string()),
        [joined] => {
            let at = joined.find(|c: char| !c.is_ascii_digit())?;
            (joined[..at].parse::<u32>().ok()?, joined[at..].to_string())
        }
        _ => return None,
    };
    match unit.as_str() {
        "d" | "day" | "days" => Some(today + Duration::days(count as i64)),
        "w" | "wk" | "wks" | "week" | "weeks" => Some(today + Duration::weeks(count as i64)),
        "fortnight" | "fortnights" => Some(today + Duration::weeks(2 * count as i64)),
        "m" | "mo" | "month" | "months" => today.checked_add_months(Months::new(count)),
        _ => None,
    }
}

/// "fri", "next fri", "29 nov", "nov 29", "29th november", "29/11", "2026-11-29".
fn day(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    match words {
        [w] if weekday(w).is_some() => weekday(w).map(|w| next_weekday(today, w)),
        ["next", w] => weekday(w).map(|w| next_weekday(today, w)),
        [one] => {
            if let Ok(date) = NaiveDate::parse_from_str(one, "%Y-%m-%d") {
                return Some(date);
            }
            let (d, m) = one.split_once('/')?;
            on_or_after(today, m.parse().ok()?, d.parse().ok()?)
        }
        [a, b] => {
            let (d, m) = match (number(a), month(b), number(b), month(a)) {
                (Some(d), Some(m), _, _) => (d, m),
                (_, _, Some(d), Some(m)) => (d, m),
                _ => return None,
            };
            on_or_after(today, m, d)
        }
        _ => None,
    }
}

/// That day and month this year, or next year once it's passed.
fn on_or_after(today: NaiveDate, month: u32, day: u32) -> Option<NaiveDate> {
    let date = NaiveDate::from_ymd_opt(today.year(), month, day)?;
    if date < today { NaiveDate::from_ymd_opt(today.year() + 1, month, day) } else { Some(date) }
}

fn number(word: &str) -> Option<u32> {
    word.trim_end_matches("st").trim_end_matches("nd").trim_end_matches("rd").trim_end_matches("th").parse().ok()
}

fn month(word: &str) -> Option<u32> {
    const NAMES: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    let word = if word.starts_with("sept") { "sep" } else { word };
    (word.len() >= 3).then(|| NAMES.iter().position(|n| word.starts_with(n) && n.starts_with(&word[..3])))?.map(|i| i as u32 + 1)
}

fn weekday(word: &str) -> Option<Weekday> {
    const DAYS: [(&str, Weekday); 7] = [("mon", Weekday::Mon), ("tue", Weekday::Tue), ("wed", Weekday::Wed), ("thu", Weekday::Thu), ("fri", Weekday::Fri), ("sat", Weekday::Sat), ("sun", Weekday::Sun)];
    (word.len() >= 3).then(|| DAYS.iter().find(|(d, _)| word.starts_with(d)).map(|(_, w)| *w))?
}

/// The next such day after today: on a Friday, "fri" is a week on.
fn next_weekday(today: NaiveDate, day: Weekday) -> NaiveDate {
    let ahead = (day.num_days_from_monday() as i64 - today.weekday().num_days_from_monday() as i64).rem_euclid(7);
    today + Duration::days(if ahead == 0 { 7 } else { ahead })
}

/// How soon, and how much it matters.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Urgency {
    Overdue,
    Today,
    Soon,
    Later,
}

/// "Overdue 3d", "Due today", "Due tomorrow", "Due Fri", "Due 29 Nov".
pub fn due_label(due: NaiveDate, today: NaiveDate) -> (String, Urgency) {
    let days = (due - today).num_days();
    match days {
        d if d < -1 => (format!("Overdue {}d", -d), Urgency::Overdue),
        -1 => ("Due yesterday".into(), Urgency::Overdue),
        0 => ("Due today".into(), Urgency::Today),
        1 => ("Due tomorrow".into(), Urgency::Soon),
        d if d < 7 => (format!("Due {}", due.format("%a")), Urgency::Soon),
        _ if due.year() == today.year() => (format!("Due {}", due.format("%-d %b")), Urgency::Later),
        _ => (format!("Due {}", due.format("%-d %b %Y")), Urgency::Later),
    }
}

/// The choices a due menu offers, as (label, day).
pub fn due_choices(today: NaiveDate) -> Vec<(&'static str, NaiveDate)> {
    vec![
        ("Today", today),
        ("Tomorrow", today + Duration::days(1)),
        ("Next Monday", next_weekday(today, Weekday::Mon)),
        ("In a week", today + Duration::weeks(1)),
        ("In 2 weeks", today + Duration::weeks(2)),
        ("In a month", today.checked_add_months(Months::new(1)).unwrap_or(today + Duration::days(30))),
    ]
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
        let todo = Todo { id: "a".into(), text: "x".into(), added, done: Some(added + chrono::Duration::minutes(185)), links: Vec::new(), due: None, reminded: None, plan: None };
        assert_eq!(took(&todo).as_deref(), Some("3h 5m"));
        assert_eq!(took(&Todo { done: None, ..todo }), None);
    }

    #[test]
    fn todos_from_before_links_still_read() {
        let old = r#"[{"id":"a1","text":"send it","added":"2026-11-14T09:00:00+00:00","done":null}]"#;
        let todos: Vec<Todo> = serde_json::from_str(old).unwrap();
        assert!(todos[0].links.is_empty());
    }

    fn day(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn due_phrases_leave_the_text() {
        // A Sunday.
        let today = day("2026-11-22");
        let split = |t: &str| split_due(t, today);
        assert_eq!(split("Run the numbers report in a week"), ("Run the numbers report".into(), Some(day("2026-11-29"))));
        assert_eq!(split("Run it in 3d"), ("Run it".into(), Some(day("2026-11-25"))));
        assert_eq!(split("Run it in 2 weeks"), ("Run it".into(), Some(day("2026-12-06"))));
        assert_eq!(split("Send it by fri"), ("Send it".into(), Some(day("2026-11-27"))));
        assert_eq!(split("Send it on 29th Nov."), ("Send it".into(), Some(day("2026-11-29"))));
        assert_eq!(split("Send it due 3 Jan"), ("Send it".into(), Some(day("2027-01-03"))));
        assert_eq!(split("Send it tomorrow"), ("Send it".into(), Some(day("2026-11-23"))));
        assert_eq!(split("Send it next week"), ("Send it".into(), Some(day("2026-11-23"))));
        assert_eq!(split("Send it on sun"), ("Send it".into(), Some(day("2026-11-29"))));
        // Nothing that reads as a day is taken.
        assert_eq!(split("Look in the monthly report"), ("Look in the monthly report".into(), None));
        assert_eq!(split("Ping Fri team"), ("Ping Fri team".into(), None));
        assert_eq!(split("tomorrow"), ("tomorrow".into(), None));
    }

    #[test]
    fn reminds_once_from_nine_on_its_day() {
        let today = day("2026-11-22");
        let at = |d: NaiveDate, h: u32| d.and_hms_opt(h, 0, 0).unwrap().and_local_timezone(Local).unwrap();
        let todo = Todo { id: "a".into(), text: "x".into(), added: at(today, 8), done: None, links: Vec::new(), due: Some(today), reminded: None, plan: None };
        assert!(!should_remind(&todo, at(today, 8)));
        assert!(should_remind(&todo, at(today, 9)));
        assert!(!should_remind(&Todo { reminded: Some(today), ..todo.clone() }, at(today, 10)));
        // Overdue reminds whatever the hour; moved on, it reminds again.
        let tomorrow = today + Duration::days(1);
        assert!(should_remind(&todo, at(tomorrow, 7)));
        assert!(should_remind(&Todo { reminded: Some(today), due: Some(tomorrow), ..todo.clone() }, at(tomorrow, 9)));
        assert!(!should_remind(&Todo { done: Some(at(today, 8)), ..todo }, at(today, 10)));
    }

    #[test]
    fn checklist_items_and_their_ticks() {
        let text = "# Plan\n\n- [x] Ship it\n- [ ] Run the numbers report\n* [X] Tell CS\n- [ ]\n- not a task\n";
        assert_eq!(checklist(text), vec![(true, "Ship it".into()), (false, "Run the numbers report".into()), (true, "Tell CS".into())]);
        assert_eq!(item_ticked(text, "Run the numbers report"), Some(false));
        assert_eq!(item_ticked(text, "Gone"), None);
    }

    #[test]
    fn due_labels() {
        let today = day("2026-11-22");
        assert_eq!(due_label(day("2026-11-19"), today), ("Overdue 3d".into(), Urgency::Overdue));
        assert_eq!(due_label(today, today).1, Urgency::Today);
        assert_eq!(due_label(day("2026-11-27"), today).0, "Due Fri");
        assert_eq!(due_label(day("2026-12-25"), today).0, "Due 25 Dec");
    }
}
