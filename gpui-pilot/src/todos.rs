//! Todos: a plain checklist kept in Marra's window, with no AI in it.
//! Each one keeps when it was added and when it was ticked off, and what
//! it's about (`links.rs`). They live in `~/.gannin/todos.json` on this Mac
//! only, and nothing sends them to Marra's claude or anywhere else.
//! `NotesStore` (`notes.rs`) holds them for every window.
//!
//! A todo can be due on a day, at a time if it's given one, and can stand
//! for an unticked item in a harness plan's checklist; it reminds once when
//! it's due, and ticks itself off when the plan's item is ticked. Its own
//! title and notes are yours: the plan's wording stays in `PlanItem`.

use chrono::{DateTime, Datelike, Duration, Local, Months, NaiveDate, NaiveDateTime, NaiveTime, Timelike, Weekday};
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
    /// The time on the due day, when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_time: Option<NaiveTime>,
    /// Your own notes on it, kept here only.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub notes: String,
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

/// A due day, and the time on it when there is one.
pub type When = (NaiveDate, Option<NaiveTime>);

/// Adds one; a due phrase at the end ("in a week", "by fri at 3pm", "on 29
/// Nov 14:00") becomes when it's due and leaves the text.
pub fn add(todos: &mut Vec<Todo>, text: &str, links: Vec<String>) {
    let (text, due) = split_due(text.trim(), Local::now().naive_local());
    if text.is_empty() {
        return;
    }
    todos.push(Todo { id: new_id(), text, added: Local::now(), done: None, links, due: due.map(|d| d.0), due_time: due.and_then(|d| d.1), notes: String::new(), reminded: None, plan: None });
    save(todos);
}

/// A todo for a plan's checklist item, due when chosen. Its title starts as
/// the item's wording, and can change without changing the plan.
pub fn add_plan(todos: &mut Vec<Todo>, plan: PlanItem, due: Option<When>, links: Vec<String>) {
    todos.push(Todo { id: new_id(), text: plan.item.clone(), added: Local::now(), done: None, links, due: due.map(|d| d.0), due_time: due.and_then(|d| d.1), notes: String::new(), reminded: None, plan: Some(plan) });
    save(todos);
}

/// Its title and notes, as typed; an empty title is left as it was.
pub fn edit(todos: &mut [Todo], id: &str, text: &str, notes: &str) {
    let Some(todo) = todos.iter_mut().find(|t| t.id == id) else { return };
    let text = text.trim();
    let changed = (!text.is_empty() && todo.text != text) || todo.notes != notes;
    if !text.is_empty() {
        todo.text = text.to_string();
    }
    todo.notes = notes.to_string();
    if changed {
        save(todos);
    }
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..8].to_string()
}

/// A new due day and time, or none; it reminds again for the new one.
pub fn set_due(todos: &mut [Todo], id: &str, due: Option<When>) {
    if let Some(todo) = todos.iter_mut().find(|t| t.id == id) {
        todo.due = due.map(|d| d.0);
        todo.due_time = due.and_then(|d| d.1);
        todo.reminded = None;
        save(todos);
    }
}

impl Todo {
    pub fn when(&self) -> Option<When> {
        self.due.map(|d| (d, self.due_time))
    }

    /// When it's due as a moment: its time, or the end of a day without one.
    fn due_at(&self) -> Option<NaiveDateTime> {
        self.due.map(|d| d.and_time(self.due_time.unwrap_or(NaiveTime::from_hms_opt(23, 59, 59).unwrap_or_default())))
    }

    /// Past when it was due.
    pub fn overdue(&self, now: NaiveDateTime) -> bool {
        self.done.is_none() && self.due_at().is_some_and(|at| at < now)
    }
}

/// Open ones due today or before, the soonest due first.
pub fn due_now(todos: &[Todo], today: NaiveDate) -> Vec<&Todo> {
    let mut due: Vec<&Todo> = todos.iter().filter(|t| t.done.is_none() && t.due.is_some_and(|d| d <= today)).collect();
    due.sort_by_key(|t| (t.due, t.due_time, t.added));
    due
}

/// Whether to remind about it now, once for when it's due: at its time when
/// it has one, else from 9am on its day; straight away once past.
pub fn should_remind(todo: &Todo, now: DateTime<Local>) -> bool {
    let (today, at) = (now.date_naive(), now.naive_local());
    match todo.due {
        Some(due) if todo.done.is_none() && todo.reminded != Some(due) => match todo.due_time {
            Some(time) => due.and_time(time) <= at,
            None => due < today || (due == today && now.hour() >= 9),
        },
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

/// The text without a due phrase at its end, and when it names: a day
/// ("by fri"), a day and time ("tomorrow 14:00", "on 29 Nov at 3pm"), or a
/// time with "at" ("at 3pm": today, or tomorrow once it's passed).
pub fn split_due(text: &str, now: NaiveDateTime) -> (String, Option<When>) {
    let today = now.date();
    let words: Vec<&str> = text.split_whitespace().collect();
    let lower: Vec<String> = words.iter().map(|w| w.trim_end_matches(['.', ',', '!', ';']).to_lowercase()).collect();
    let lower: Vec<&str> = lower.iter().map(String::as_str).collect();
    let rest = |end: usize| words[..end].join(" ").trim_end_matches([',', '-', ':']).trim_end().to_string();
    let (end, time) = match trailing_time(&lower) {
        Some((time, n, _)) => (lower.len() - n, Some(time)),
        None => (lower.len(), None),
    };
    for n in (1..=4).rev() {
        if end <= n {
            continue;
        }
        if let Some(day) = phrase(&lower[end - n..end], today) {
            return (rest(end - n), Some((day, time)));
        }
    }
    if let Some((time, n, true)) = trailing_time(&lower) {
        if lower.len() > n {
            return (rest(lower.len() - n), Some((next_at(now, time), Some(time))));
        }
    }
    (text.to_string(), None)
}

/// Today at that time, or tomorrow once it's passed.
fn next_at(now: NaiveDateTime, time: NaiveTime) -> NaiveDate {
    if now.time() < time { now.date() } else { now.date() + Duration::days(1) }
}

/// What's typed in a due menu: a day ("29 Nov", "fri", "in 3 days",
/// "2026-12-01"), a day and a time ("tomorrow 9:30", "29/11 at 3pm"), or a
/// time alone, on `base`'s day when there is one, else the next one.
pub fn parse_when(text: &str, now: NaiveDateTime, base: Option<NaiveDate>) -> Option<When> {
    let lower: Vec<String> = text.split_whitespace().map(|w| w.trim_end_matches(['.', ',', '!', ';']).to_lowercase()).collect();
    let lower: Vec<&str> = lower.iter().map(String::as_str).collect();
    if lower.is_empty() {
        return None;
    }
    let (end, time) = match trailing_time(&lower) {
        Some((time, n, _)) => (lower.len() - n, Some(time)),
        None => (lower.len(), None),
    };
    let words = &lower[..end];
    if words.is_empty() {
        let time = time?;
        return Some((base.unwrap_or_else(|| next_at(now, time)), Some(time)));
    }
    let day = phrase(words, now.date()).or_else(|| day(words, now.date())).or_else(|| span(words, now.date()))?;
    Some((day, time))
}

/// A time at the end: "14:00", "9:30", "3pm", "3:30 pm", "noon", with an
/// "at" ahead of it or not; as (time, words taken, whether "at" was there).
fn trailing_time(words: &[&str]) -> Option<(NaiveTime, usize, bool)> {
    let n = words.len();
    let (time, taken) = match words {
        [.., hour, meridiem @ ("am" | "pm")] => (clock(&format!("{hour}{meridiem}"))?, 2),
        [.., last] => (clock(last)?, 1),
        [] => return None,
    };
    let at = n > taken && words[n - taken - 1] == "at";
    Some((time, taken + usize::from(at), at))
}

fn clock(word: &str) -> Option<NaiveTime> {
    match word {
        "noon" | "midday" => return NaiveTime::from_hms_opt(12, 0, 0),
        "midnight" => return NaiveTime::from_hms_opt(0, 0, 0),
        _ => {}
    }
    let (digits, pm) = match (word.strip_suffix("pm"), word.strip_suffix("am")) {
        (Some(d), _) => (d, Some(true)),
        (_, Some(d)) => (d, Some(false)),
        _ => (word, None),
    };
    let (hour, minute) = match digits.split_once([':', '.']) {
        Some((h, m)) if m.len() == 2 => (h.parse::<u32>().ok()?, m.parse::<u32>().ok()?),
        // A bare number is a time only with am or pm.
        None if pm.is_some() => (digits.parse::<u32>().ok()?, 0),
        _ => return None,
    };
    let hour = match pm {
        Some(true) if (1..12).contains(&hour) => hour + 12,
        Some(false) if hour == 12 => 0,
        Some(_) if !(1..=12).contains(&hour) => return None,
        _ => hour,
    };
    NaiveTime::from_hms_opt(hour, minute, 0)
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

/// How soon, and how much it matters: overdue, and a time within the hour,
/// are both red.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Urgency {
    Overdue,
    Imminent,
    Today,
    Soon,
    Later,
}

/// "Overdue 3d", "Overdue 20m", "Due in 25m", "Due today 14:00", "Due
/// tomorrow", "Due Fri 9:30", "Due 29 Nov".
pub fn due_label(due: NaiveDate, time: Option<NaiveTime>, now: NaiveDateTime) -> (String, Urgency) {
    let today = now.date();
    let days = (due - today).num_days();
    let at = time.map(|t| format!(" {}", t.format("%H:%M"))).unwrap_or_default();
    if let Some(time) = time {
        let minutes = (due.and_time(time) - now).num_minutes();
        match minutes {
            m if m < -60 * 24 => return (format!("Overdue {}d", -m / 60 / 24), Urgency::Overdue),
            m if m < -60 => return (format!("Overdue {}h", -m / 60), Urgency::Overdue),
            m if m < 0 => return (format!("Overdue {}m", -m), Urgency::Overdue),
            m if m <= 60 => return (format!("Due in {m}m"), Urgency::Imminent),
            _ => {}
        }
    }
    match days {
        d if d < -1 => (format!("Overdue {}d", -d), Urgency::Overdue),
        -1 => ("Due yesterday".into(), Urgency::Overdue),
        0 => (format!("Due today{at}"), Urgency::Today),
        1 => (format!("Due tomorrow{at}"), Urgency::Soon),
        d if d < 7 => (format!("Due {}{at}", due.format("%a")), Urgency::Soon),
        _ if due.year() == today.year() => (format!("Due {}{at}", due.format("%-d %b")), Urgency::Later),
        _ => (format!("Due {}{at}", due.format("%-d %b %Y")), Urgency::Later),
    }
}

/// The weeks a calendar shows for a month, Monday first; each day with
/// whether it's in that month.
pub fn month_grid(month: NaiveDate) -> Vec<Vec<(NaiveDate, bool)>> {
    let first = month.with_day(1).unwrap_or(month);
    let start = first - Duration::days(first.weekday().num_days_from_monday() as i64);
    let mut weeks = Vec::new();
    let mut day = start;
    while weeks.len() < 6 && (weeks.is_empty() || day.month() == first.month() || day < first) {
        let week: Vec<(NaiveDate, bool)> = (0..7).map(|i| day + Duration::days(i)).map(|d| (d, d.month() == first.month())).collect();
        day += Duration::days(7);
        weeks.push(week);
    }
    weeks
}

/// The first of the month before or after.
pub fn shift_month(month: NaiveDate, by: i32) -> NaiveDate {
    let first = month.with_day(1).unwrap_or(month);
    if by >= 0 { first.checked_add_months(Months::new(by as u32)) } else { first.checked_sub_months(Months::new((-by) as u32)) }.unwrap_or(first)
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
        let todo = Todo { id: "a".into(), text: "x".into(), added, done: Some(added + chrono::Duration::minutes(185)), links: Vec::new(), due: None, due_time: None, notes: String::new(), reminded: None, plan: None };
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
        let now = today.and_hms_opt(10, 0, 0).unwrap();
        let split = |t: &str| split_due(t, now);
        let on = |d: &str| Some((day(d), None));
        let at = |d: &str, h: u32, m: u32| Some((day(d), NaiveTime::from_hms_opt(h, m, 0)));
        assert_eq!(split("Run the numbers report in a week"), ("Run the numbers report".into(), on("2026-11-29")));
        assert_eq!(split("Run it in 3d"), ("Run it".into(), on("2026-11-25")));
        assert_eq!(split("Run it in 2 weeks"), ("Run it".into(), on("2026-12-06")));
        assert_eq!(split("Send it by fri"), ("Send it".into(), on("2026-11-27")));
        assert_eq!(split("Send it on 29th Nov."), ("Send it".into(), on("2026-11-29")));
        assert_eq!(split("Send it due 3 Jan"), ("Send it".into(), on("2027-01-03")));
        assert_eq!(split("Send it tomorrow"), ("Send it".into(), on("2026-11-23")));
        assert_eq!(split("Send it next week"), ("Send it".into(), on("2026-11-23")));
        assert_eq!(split("Send it on sun"), ("Send it".into(), on("2026-11-29")));
        assert_eq!(split("Send it tomorrow 14:00"), ("Send it".into(), at("2026-11-23", 14, 0)));
        assert_eq!(split("Send it on 29 Nov at 3:30pm"), ("Send it".into(), at("2026-11-29", 15, 30)));
        assert_eq!(split("Send it by fri at 9 am"), ("Send it".into(), at("2026-11-27", 9, 0)));
        assert_eq!(split("Call them at 3pm"), ("Call them".into(), at("2026-11-22", 15, 0)));
        assert_eq!(split("Call them at 9:00"), ("Call them".into(), at("2026-11-23", 9, 0)));
        // A time needs "at" or a day with it.
        assert_eq!(split("Bump to 1.20"), ("Bump to 1.20".into(), None));
        assert_eq!(split("Read chapter 3pm"), ("Read chapter 3pm".into(), None));
        // Nothing that reads as a day is taken.
        assert_eq!(split("Look in the monthly report"), ("Look in the monthly report".into(), None));
        assert_eq!(split("Ping Fri team"), ("Ping Fri team".into(), None));
        assert_eq!(split("tomorrow"), ("tomorrow".into(), None));
    }

    #[test]
    fn typed_whens() {
        let now = day("2026-11-22").and_hms_opt(10, 0, 0).unwrap();
        let parse = |t: &str| parse_when(t, now, None);
        assert_eq!(parse("29 Nov"), Some((day("2026-11-29"), None)));
        assert_eq!(parse("29/11 14:30"), Some((day("2026-11-29"), NaiveTime::from_hms_opt(14, 30, 0))));
        assert_eq!(parse("fri 9am"), Some((day("2026-11-27"), NaiveTime::from_hms_opt(9, 0, 0))));
        assert_eq!(parse("in 3 days"), Some((day("2026-11-25"), None)));
        assert_eq!(parse("3 days"), Some((day("2026-11-25"), None)));
        assert_eq!(parse("2026-12-01 noon"), Some((day("2026-12-01"), NaiveTime::from_hms_opt(12, 0, 0))));
        assert_eq!(parse("9:00"), Some((day("2026-11-23"), NaiveTime::from_hms_opt(9, 0, 0))));
        assert_eq!(parse_when("9:00", now, Some(day("2026-12-25"))), Some((day("2026-12-25"), NaiveTime::from_hms_opt(9, 0, 0))));
        assert_eq!(parse("whenever"), None);
    }

    #[test]
    fn a_calendar_month() {
        let weeks = month_grid(day("2026-11-10"));
        // November 2026 starts on a Sunday: six weeks, from 26 October.
        assert_eq!(weeks.len(), 6);
        assert_eq!(weeks[0][0], (day("2026-10-26"), false));
        assert_eq!(weeks[0][6], (day("2026-11-01"), true));
        assert_eq!(shift_month(day("2026-01-31"), -1), day("2025-12-01"));
    }

    #[test]
    fn reminds_once_from_nine_on_its_day() {
        let today = day("2026-11-22");
        let at = |d: NaiveDate, h: u32| d.and_hms_opt(h, 0, 0).unwrap().and_local_timezone(Local).unwrap();
        let todo = Todo { id: "a".into(), text: "x".into(), added: at(today, 8), done: None, links: Vec::new(), due: Some(today), due_time: None, notes: String::new(), reminded: None, plan: None };
        assert!(!should_remind(&todo, at(today, 8)));
        assert!(should_remind(&todo, at(today, 9)));
        assert!(!should_remind(&Todo { reminded: Some(today), ..todo.clone() }, at(today, 10)));
        // Overdue reminds whatever the hour; moved on, it reminds again.
        let tomorrow = today + Duration::days(1);
        assert!(should_remind(&todo, at(tomorrow, 7)));
        assert!(should_remind(&Todo { reminded: Some(today), due: Some(tomorrow), ..todo.clone() }, at(tomorrow, 9)));
        assert!(!should_remind(&Todo { done: Some(at(today, 8)), ..todo.clone() }, at(today, 10)));
        // With a time, at that time.
        let timed = Todo { due_time: NaiveTime::from_hms_opt(14, 30, 0), ..todo };
        assert!(!should_remind(&timed, at(today, 14)));
        assert!(should_remind(&timed, at(today, 15)));
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
        let now = today.and_hms_opt(10, 0, 0).unwrap();
        let t = |h: u32, m: u32| NaiveTime::from_hms_opt(h, m, 0);
        assert_eq!(due_label(day("2026-11-19"), None, now), ("Overdue 3d".into(), Urgency::Overdue));
        assert_eq!(due_label(today, None, now).1, Urgency::Today);
        assert_eq!(due_label(day("2026-11-27"), None, now).0, "Due Fri");
        assert_eq!(due_label(day("2026-12-25"), None, now).0, "Due 25 Dec");
        assert_eq!(due_label(today, t(14, 0), now), ("Due today 14:00".into(), Urgency::Today));
        assert_eq!(due_label(today, t(10, 40), now), ("Due in 40m".into(), Urgency::Imminent));
        assert_eq!(due_label(today, t(9, 30), now), ("Overdue 30m".into(), Urgency::Overdue));
        assert_eq!(due_label(day("2026-11-27"), t(9, 30), now).0, "Due Fri 09:30");
    }
}
