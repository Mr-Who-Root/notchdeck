//! The focus timer's cycles and its record — the Mac's `FocusTimer` phases and `FocusStats`.
//!
//! The countdown itself is the page's (notch.html), as it always was; Rust decides what comes after a
//! phase ends, because that is the part worth pinning with tests: focus, a short break, focus again,
//! and a long break after every few focus phases. Only completed focus phases count towards the day:
//! one that is reset or skipped half-way was not time spent focusing. The record keeps 30 days in
//! `focus-stats.json` beside the config.

use crate::{config, AppState};
use chrono::{Datelike, Duration as Days, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Focus,
    ShortBreak,
    LongBreak,
}

/// The lengths and the rhythm, as Settings has them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cycle {
    pub cycles: bool,
    pub focus: u32,
    pub short_break: u32,
    pub long_break: u32,
    pub long_every: u32,
    pub auto_start: bool,
}

impl Cycle {
    pub fn of(c: &config::Config) -> Self {
        Self {
            cycles: c.timer_cycles,
            focus: c.timer_minutes,
            short_break: c.timer_short_break,
            long_break: c.timer_long_break,
            long_every: c.timer_long_every.max(2),
            auto_start: c.timer_auto_start,
        }
    }

    pub fn minutes(&self, phase: Phase) -> u32 {
        match phase {
            Phase::Focus => self.focus,
            Phase::ShortBreak => self.short_break,
            Phase::LongBreak => self.long_break,
        }
    }
}

/// What the page runs next, and what it says about it.
#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct Next {
    pub phase: Phase,
    pub minutes: u32,
    /// Which focus phase of the cycle this is, from 1; for a break, the one just finished.
    pub round: u32,
    pub of: u32,
    /// Start counting straight away rather than waiting for a click.
    pub auto_start: bool,
    /// The card's line for the phase just ended: "Focus done — 5 min break".
    pub notice: String,
}

/// After `done` ends with `completed` focus phases already finished in this cycle: the phase that
/// follows and the new count. Pure, so the rhythm is pinned by the tests below.
pub fn advance(done: Phase, completed: u32, cycle: &Cycle) -> (Phase, u32) {
    if !cycle.cycles {
        return (Phase::Focus, 0);
    }
    match done {
        Phase::Focus => {
            let completed = completed + 1;
            if completed % cycle.long_every == 0 {
                (Phase::LongBreak, completed)
            } else {
                (Phase::ShortBreak, completed)
            }
        }
        Phase::ShortBreak => (Phase::Focus, completed),
        Phase::LongBreak => (Phase::Focus, 0),
    }
}

/// The 1-based focus phase a cycle is on, given how many are done.
pub fn round_of(phase: Phase, completed: u32, cycle: &Cycle) -> u32 {
    let every = cycle.long_every.max(1);
    match phase {
        Phase::Focus => completed % every + 1,
        _ => ((completed + every - 1) % every) + 1,
    }
}

pub fn notice(done: Phase, next: Phase, minutes: u32) -> String {
    match (done, next) {
        (Phase::Focus, Phase::ShortBreak) | (Phase::Focus, Phase::LongBreak) => {
            format!("Focus done \u{2014} {minutes} min break")
        }
        (Phase::Focus, Phase::Focus) => "Focus done".into(),
        _ => "Break's over \u{2014} back to focus".into(),
    }
}

/// One day of the record.
#[derive(Clone, Copy, Serialize, Deserialize, Default, PartialEq, Debug)]
pub struct Day {
    pub minutes: u32,
    pub sessions: u32,
}

#[derive(Default, Clone, Debug, PartialEq)]
pub struct Record {
    days: BTreeMap<NaiveDate, Day>,
}

/// How long the record goes back.
pub const KEEP_DAYS: i64 = 30;

impl Record {
    pub fn add(&mut self, today: NaiveDate, minutes: u32) {
        let day = self.days.entry(today).or_default();
        day.minutes += minutes;
        day.sessions += 1;
        let oldest = today - Days::days(KEEP_DAYS - 1);
        self.days.retain(|d, _| *d >= oldest);
    }

    pub fn day(&self, date: NaiveDate) -> Day {
        self.days.get(&date).copied().unwrap_or_default()
    }

    /// The week the card draws: six days back to today, oldest first.
    pub fn week(&self, today: NaiveDate) -> Vec<DayView> {
        (0..7)
            .rev()
            .map(|back| {
                let date = today - Days::days(back);
                let d = self.day(date);
                DayView {
                    date: date.format("%Y-%m-%d").to_string(),
                    label: weekday_letter(date),
                    minutes: d.minutes,
                    sessions: d.sessions,
                    today: back == 0,
                }
            })
            .collect()
    }

    fn to_saved(&self) -> BTreeMap<String, Day> {
        self.days.iter().map(|(d, v)| (d.format("%Y-%m-%d").to_string(), *v)).collect()
    }

    fn from_saved(saved: BTreeMap<String, Day>) -> Self {
        Self {
            days: saved
                .into_iter()
                .filter_map(|(k, v)| NaiveDate::parse_from_str(&k, "%Y-%m-%d").ok().map(|d| (d, v)))
                .collect(),
        }
    }
}

fn weekday_letter(date: NaiveDate) -> String {
    ["M", "T", "W", "T", "F", "S", "S"][date.weekday().num_days_from_monday() as usize].into()
}

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct DayView {
    pub date: String,
    pub label: String,
    pub minutes: u32,
    pub sessions: u32,
    pub today: bool,
}

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct Stats {
    pub today_minutes: u32,
    pub today_sessions: u32,
    /// "1 h 15 m" or "40 m".
    pub today_text: String,
    pub days: Vec<DayView>,
}

pub fn duration_text(minutes: u32) -> String {
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("{m} m"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} m"),
    }
}

pub fn stats_of(record: &Record, today: NaiveDate) -> Stats {
    let d = record.day(today);
    Stats {
        today_minutes: d.minutes,
        today_sessions: d.sessions,
        today_text: duration_text(d.minutes),
        days: record.week(today),
    }
}

struct Live {
    record: Record,
    completed: u32,
}

static LIVE: Mutex<Option<Live>> = Mutex::new(None);

fn store_path() -> std::path::PathBuf {
    config::config_path()
        .parent()
        .map(|d| d.join("focus-stats.json"))
        .unwrap_or_else(|| "focus-stats.json".into())
}

fn load() -> Live {
    let saved = std::fs::read_to_string(store_path())
        .ok()
        .and_then(|s| serde_json::from_str::<BTreeMap<String, Day>>(&s).ok())
        .unwrap_or_default();
    Live { record: Record::from_saved(saved), completed: 0 }
}

fn save(record: &Record) {
    let path = store_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string_pretty(&record.to_saved()) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

fn today() -> NaiveDate {
    chrono::Local::now().date_naive()
}

fn cycle(app: &AppHandle) -> Cycle {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    Cycle::of(&c)
}

/// A phase ended — run out (`skipped` false) or skipped. Answers with what comes next.
#[tauri::command]
pub fn focus_phase_done(app: AppHandle, phase: Phase, skipped: bool) -> Next {
    let cycle = cycle(&app);
    let mut guard = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    let live = guard.get_or_insert_with(load);
    if phase == Phase::Focus && !skipped {
        live.record.add(today(), cycle.focus);
        save(&live.record);
    }
    let (next, completed) = advance(phase, live.completed, &cycle);
    live.completed = completed;
    let minutes = cycle.minutes(next);
    Next {
        phase: next,
        minutes,
        round: round_of(next, completed, &cycle),
        of: cycle.long_every,
        auto_start: cycle.cycles && cycle.auto_start,
        notice: notice(phase, next, minutes),
    }
}

/// Reset: the cycle starts again from its first focus phase.
#[tauri::command]
pub fn focus_reset_cycle(app: AppHandle) -> Next {
    let cycle = cycle(&app);
    let mut guard = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    guard.get_or_insert_with(load).completed = 0;
    Next {
        phase: Phase::Focus,
        minutes: cycle.focus,
        round: 1,
        of: cycle.long_every,
        auto_start: false,
        notice: String::new(),
    }
}

#[tauri::command]
pub fn get_focus_stats() -> Stats {
    let mut guard = LIVE.lock().unwrap_or_else(|e| e.into_inner());
    stats_of(&guard.get_or_insert_with(load).record, today())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cycle() -> Cycle {
        Cycle { cycles: true, focus: 25, short_break: 5, long_break: 15, long_every: 4, auto_start: true }
    }

    #[test]
    fn focus_and_short_breaks_then_a_long_one() {
        let c = cycle();
        let mut phase = Phase::Focus;
        let mut done = 0;
        let mut seen = Vec::new();
        for _ in 0..9 {
            let (next, completed) = advance(phase, done, &c);
            seen.push(next);
            phase = next;
            done = completed;
        }
        use Phase::*;
        assert_eq!(
            seen,
            [ShortBreak, Focus, ShortBreak, Focus, ShortBreak, Focus, LongBreak, Focus, ShortBreak],
            "three short breaks, then a long one after the fourth focus, and round again"
        );
    }

    #[test]
    fn rounds_count_within_the_cycle() {
        let c = cycle();
        assert_eq!(round_of(Phase::Focus, 0, &c), 1);
        assert_eq!(round_of(Phase::Focus, 3, &c), 4);
        assert_eq!(round_of(Phase::ShortBreak, 1, &c), 1, "the break after the first focus");
        assert_eq!(round_of(Phase::LongBreak, 4, &c), 4);
        assert_eq!(round_of(Phase::Focus, 4, &c), 1, "a long break starts the count over");
    }

    #[test]
    fn without_cycles_it_is_one_timer() {
        let c = Cycle { cycles: false, ..cycle() };
        assert_eq!(advance(Phase::Focus, 3, &c), (Phase::Focus, 0));
        assert_eq!(notice(Phase::Focus, Phase::Focus, 25), "Focus done");
    }

    #[test]
    fn phase_notices_read_as_the_card_says_them() {
        assert_eq!(notice(Phase::Focus, Phase::ShortBreak, 5), "Focus done \u{2014} 5 min break");
        assert_eq!(notice(Phase::ShortBreak, Phase::Focus, 25), "Break's over \u{2014} back to focus");
        assert_eq!(notice(Phase::LongBreak, Phase::Focus, 25), "Break's over \u{2014} back to focus");
    }

    #[test]
    fn the_record_adds_up_a_day_and_keeps_a_month() {
        let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        let mut r = Record::default();
        r.add(d("2026-10-20"), 25);
        r.add(d("2026-10-20"), 25);
        r.add(d("2026-10-18"), 50);
        let s = stats_of(&r, d("2026-10-20"));
        assert_eq!((s.today_minutes, s.today_sessions), (50, 2));
        assert_eq!(s.today_text, "50 m");
        assert_eq!(s.days.len(), 7);
        assert!(s.days[6].today && s.days[6].date == "2026-10-20");
        assert_eq!(s.days[4].minutes, 50, "two days back");
        assert_eq!(s.days[0].label, "W", "2026-10-14 was a Wednesday");

        // Thirty days on, the old days are gone
        r.add(d("2026-11-25"), 25);
        assert_eq!(r.day(d("2026-10-20")), Day::default());
        assert_eq!(r.day(d("2026-11-25")).sessions, 1);
    }

    #[test]
    fn the_record_survives_a_save() {
        let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        let mut r = Record::default();
        r.add(d("2026-10-20"), 25);
        let json = serde_json::to_string(&r.to_saved()).unwrap();
        let back = Record::from_saved(serde_json::from_str(&json).unwrap());
        assert_eq!(back, r);
    }

    #[test]
    fn durations_read_as_hours_and_minutes() {
        assert_eq!(duration_text(0), "0 m");
        assert_eq!(duration_text(40), "40 m");
        assert_eq!(duration_text(60), "1 h");
        assert_eq!(duration_text(75), "1 h 15 m");
    }
}
