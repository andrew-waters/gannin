//! Number formatting as the Swift app shows it (`compactDuration`,
//! `ActionsView.percent`, `StatChange`).

use chrono::{DateTime, Datelike, Local, Utc};

/// "today", "3 days ago", "2 months ago", as a relative date reads.
pub fn relative_date(time: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let days = (now - time).num_days();
    let unit = |n: i64, singular: &str| format!("{n} {singular}{} ago", if n == 1 { "" } else { "s" });
    match days {
        i64::MIN..=0 => "today".into(),
        1 => "yesterday".into(),
        2..=6 => unit(days, "day"),
        7..=29 => unit(days / 7, "week"),
        30..=364 => unit(days / 30, "month"),
        _ => unit(days / 365, "year"),
    }
}

/// 4161 as "4,161".
pub fn thousands(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

pub fn compact_duration(seconds: f64) -> String {
    if seconds < 59.5 {
        return format!("{}s", seconds.max(0.0).round() as i64);
    }
    let minutes = seconds / 60.0;
    if minutes < 60.0 {
        return format!("{}m", minutes.round() as i64);
    }
    let hours = minutes / 60.0;
    if hours < 48.0 {
        return if hours < 10.0 { format!("{hours:.1}h") } else { format!("{hours:.0}h") };
    }
    let days = hours / 24.0;
    if days < 10.0 { format!("{days:.1}d") } else { format!("{days:.0}d") }
}

pub fn percent(value: Option<f64>) -> String {
    value.map(|v| format!("{:.0}%", v * 100.0)).unwrap_or_else(|| "-".into())
}

pub fn duration_or_dash(value: Option<f64>) -> String {
    value.map(compact_duration).unwrap_or_else(|| "-".into())
}

/// A change on the period before, and whether it's bad news (`None` when
/// it's neither).
pub struct Change {
    pub text: String,
    pub is_worse: Option<bool>,
}

impl Change {
    pub fn percent(current: f64, previous: f64, higher_is_worse: Option<bool>) -> Option<Change> {
        if previous <= 0.0 {
            return None;
        }
        let rounded = ((current / previous - 1.0) * 100.0).round();
        if rounded == 0.0 {
            return Some(Change { text: "0%".into(), is_worse: None });
        }
        Some(Change {
            text: format!("{}{}%", if rounded > 0.0 { "+" } else { "" }, rounded as i64),
            is_worse: higher_is_worse.map(|worse| worse == (rounded > 0.0)),
        })
    }

    pub fn points(current: Option<f64>, previous: Option<f64>, higher_is_worse: bool) -> Option<Change> {
        let rounded = ((current? - previous?) * 100.0).round();
        if rounded == 0.0 {
            return Some(Change { text: "0 pp".into(), is_worse: None });
        }
        Some(Change {
            text: format!("{}{} pp", if rounded > 0.0 { "+" } else { "" }, rounded as i64),
            is_worse: Some(higher_is_worse == (rounded > 0.0)),
        })
    }
}

/// A date for a table cell, in local time: the time alone when it's today,
/// else the day and time, with the year when it isn't this one.
pub fn table_date(time: DateTime<Utc>) -> String {
    let local = time.with_timezone(&Local);
    let today = Local::now().date_naive();
    if local.date_naive() == today {
        local.format("%H:%M").to_string()
    } else if local.year() == today.year() {
        local.format("%-d %b, %H:%M").to_string()
    } else {
        local.format("%-d %b %Y").to_string()
    }
}
