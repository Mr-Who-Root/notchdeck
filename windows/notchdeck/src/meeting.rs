//! The next meeting — the Mac's `MeetingMonitor`, which reads the Mac's own calendars. Windows has no
//! calendar a desktop app may read without a package identity, so this reads the iCal (ICS) feeds
//! pasted into Settings: Google's "secret address in iCal format", Outlook's published calendar,
//! iCloud's public one. Each is fetched every ten minutes; between fetches the next meeting is worked
//! out again every few seconds from what was read, so the countdown stays current offline.
//!
//! A feed is plain text, but the parts that matter are fiddly: times in the event's own zone (named
//! the IANA way, the Windows way, or only by a VTIMEZONE block in the file), repeating events
//! (RRULE), the repeats that were cancelled (EXDATE) and the ones that were moved (RECURRENCE-ID).
//! All of that is pure and tested below. All-day and cancelled events are left out: neither is a
//! meeting to join.

use chrono::{
    DateTime, Datelike, Duration, FixedOffset, LocalResult, NaiveDate, NaiveDateTime, NaiveTime, TimeZone,
    Utc, Weekday,
};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

// ---- Lines and properties ---------------------------------------------------------------------

/// One content line: `NAME;PARAM=VALUE:value`, unfolded and with its parameters split out.
#[derive(Clone, Debug, PartialEq)]
pub struct Prop {
    pub name: String,
    pub params: Vec<(String, String)>,
    pub value: String,
}

impl Prop {
    pub fn param(&self, name: &str) -> Option<&str> {
        self.params.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

/// RFC 5545 folds long lines by breaking them and starting the next with a space or a tab.
pub fn unfold(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some(rest) = line.strip_prefix(' ').or_else(|| line.strip_prefix('\t')) {
            if let Some(last) = lines.last_mut() {
                last.push_str(rest);
                continue;
            }
        }
        if !line.is_empty() {
            lines.push(line.to_string());
        }
    }
    lines
}

pub fn parse_line(line: &str) -> Option<Prop> {
    // The value starts at the first colon that is not inside a quoted parameter value.
    let mut quoted = false;
    let mut split = None;
    for (i, c) in line.char_indices() {
        match c {
            '"' => quoted = !quoted,
            ':' if !quoted => {
                split = Some(i);
                break;
            }
            _ => {}
        }
    }
    let split = split?;
    let (head, value) = (&line[..split], &line[split + 1..]);
    let mut parts = Vec::new();
    let mut current = String::new();
    quoted = false;
    for c in head.chars() {
        match c {
            '"' => quoted = !quoted,
            ';' if !quoted => parts.push(std::mem::take(&mut current)),
            _ => current.push(c),
        }
    }
    parts.push(current);
    let name = parts.first()?.trim().to_ascii_uppercase();
    if name.is_empty() {
        return None;
    }
    let params = parts[1..]
        .iter()
        .filter_map(|p| p.split_once('=').map(|(k, v)| (k.trim().to_ascii_uppercase(), v.trim().to_string())))
        .collect();
    Some(Prop { name, params, value: value.to_string() })
}

/// TEXT values escape commas, semicolons, backslashes and newlines.
pub fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') | Some('N') => out.push('\n'),
            Some(other) => out.push(other),
            None => {}
        }
    }
    out
}

// ---- Time zones -------------------------------------------------------------------------------

/// Where a wall-clock time is.
#[derive(Clone, Debug, PartialEq)]
pub enum Zone {
    Utc,
    Iana(chrono_tz::Tz),
    Fixed(FixedOffset),
    /// A VTIMEZONE block's own rules, for a zone with a name nothing else knows.
    Rules(VTimezone),
    /// No zone: the computer's own (a "floating" time).
    Local,
}

/// Turns a wall-clock time into an instant. A time that does not exist (inside a spring-forward gap)
/// is taken an hour later; one that happens twice (the autumn overlap) is taken the first time.
pub fn to_utc(zone: &Zone, wall: NaiveDateTime) -> DateTime<Utc> {
    fn pick<T: TimeZone>(r: LocalResult<DateTime<T>>, fallback: impl FnOnce() -> Option<DateTime<T>>) -> Option<DateTime<Utc>> {
        match r {
            LocalResult::Single(t) => Some(t.with_timezone(&Utc)),
            LocalResult::Ambiguous(a, _) => Some(a.with_timezone(&Utc)),
            LocalResult::None => fallback().map(|t| t.with_timezone(&Utc)),
        }
    }
    let shifted = wall + Duration::hours(1);
    let r = match zone {
        Zone::Utc => Some(Utc.from_utc_datetime(&wall)),
        Zone::Iana(tz) => pick(tz.from_local_datetime(&wall), || tz.from_local_datetime(&shifted).earliest()),
        Zone::Fixed(off) => pick(off.from_local_datetime(&wall), || None),
        Zone::Rules(v) => Some(Utc.from_utc_datetime(&(wall - Duration::seconds(v.offset_at(wall) as i64)))),
        Zone::Local => pick(chrono::Local.from_local_datetime(&wall), || {
            chrono::Local.from_local_datetime(&shifted).earliest()
        }),
    };
    r.unwrap_or_else(|| Utc.from_utc_datetime(&wall))
}

/// The zones Windows (and Outlook's feeds) name their own way, mapped to the IANA zone that keeps
/// the same clock — CLDR's windowsZones table, its main entries.
const WINDOWS_ZONES: &[(&str, &str)] = &[
    ("Dateline Standard Time", "Etc/GMT+12"),
    ("UTC-11", "Etc/GMT+11"),
    ("Hawaiian Standard Time", "Pacific/Honolulu"),
    ("Alaskan Standard Time", "America/Anchorage"),
    ("Pacific Standard Time (Mexico)", "America/Tijuana"),
    ("Pacific Standard Time", "America/Los_Angeles"),
    ("US Mountain Standard Time", "America/Phoenix"),
    ("Mountain Standard Time (Mexico)", "America/Mazatlan"),
    ("Mountain Standard Time", "America/Denver"),
    ("Central America Standard Time", "America/Guatemala"),
    ("Central Standard Time (Mexico)", "America/Mexico_City"),
    ("Central Standard Time", "America/Chicago"),
    ("Canada Central Standard Time", "America/Regina"),
    ("SA Pacific Standard Time", "America/Bogota"),
    ("Eastern Standard Time (Mexico)", "America/Cancun"),
    ("US Eastern Standard Time", "America/Indiana/Indianapolis"),
    ("Eastern Standard Time", "America/New_York"),
    ("Venezuela Standard Time", "America/Caracas"),
    ("Atlantic Standard Time", "America/Halifax"),
    ("SA Western Standard Time", "America/La_Paz"),
    ("Pacific SA Standard Time", "America/Santiago"),
    ("Newfoundland Standard Time", "America/St_Johns"),
    ("E. South America Standard Time", "America/Sao_Paulo"),
    ("Argentina Standard Time", "America/Argentina/Buenos_Aires"),
    ("SA Eastern Standard Time", "America/Cayenne"),
    ("Greenland Standard Time", "America/Godthab"),
    ("Montevideo Standard Time", "America/Montevideo"),
    ("UTC-02", "Etc/GMT+2"),
    ("Azores Standard Time", "Atlantic/Azores"),
    ("Cape Verde Standard Time", "Atlantic/Cape_Verde"),
    ("UTC", "Etc/UTC"),
    ("Coordinated Universal Time", "Etc/UTC"),
    ("GMT Standard Time", "Europe/London"),
    ("Greenwich Standard Time", "Atlantic/Reykjavik"),
    ("W. Europe Standard Time", "Europe/Berlin"),
    ("Central Europe Standard Time", "Europe/Budapest"),
    ("Romance Standard Time", "Europe/Paris"),
    ("Central European Standard Time", "Europe/Warsaw"),
    ("W. Central Africa Standard Time", "Africa/Lagos"),
    ("GTB Standard Time", "Europe/Bucharest"),
    ("Middle East Standard Time", "Asia/Beirut"),
    ("Egypt Standard Time", "Africa/Cairo"),
    ("E. Europe Standard Time", "Europe/Chisinau"),
    ("South Africa Standard Time", "Africa/Johannesburg"),
    ("FLE Standard Time", "Europe/Kiev"),
    ("Israel Standard Time", "Asia/Jerusalem"),
    ("Arabic Standard Time", "Asia/Baghdad"),
    ("Turkey Standard Time", "Europe/Istanbul"),
    ("Arab Standard Time", "Asia/Riyadh"),
    ("Russian Standard Time", "Europe/Moscow"),
    ("E. Africa Standard Time", "Africa/Nairobi"),
    ("Iran Standard Time", "Asia/Tehran"),
    ("Arabian Standard Time", "Asia/Dubai"),
    ("Azerbaijan Standard Time", "Asia/Baku"),
    ("Georgian Standard Time", "Asia/Tbilisi"),
    ("Afghanistan Standard Time", "Asia/Kabul"),
    ("West Asia Standard Time", "Asia/Tashkent"),
    ("Pakistan Standard Time", "Asia/Karachi"),
    ("India Standard Time", "Asia/Kolkata"),
    ("Sri Lanka Standard Time", "Asia/Colombo"),
    ("Nepal Standard Time", "Asia/Kathmandu"),
    ("Central Asia Standard Time", "Asia/Almaty"),
    ("Bangladesh Standard Time", "Asia/Dhaka"),
    ("Myanmar Standard Time", "Asia/Yangon"),
    ("SE Asia Standard Time", "Asia/Bangkok"),
    ("N. Central Asia Standard Time", "Asia/Novosibirsk"),
    ("China Standard Time", "Asia/Shanghai"),
    ("North Asia Standard Time", "Asia/Krasnoyarsk"),
    ("Singapore Standard Time", "Asia/Singapore"),
    ("W. Australia Standard Time", "Australia/Perth"),
    ("Taipei Standard Time", "Asia/Taipei"),
    ("Tokyo Standard Time", "Asia/Tokyo"),
    ("Korea Standard Time", "Asia/Seoul"),
    ("Cen. Australia Standard Time", "Australia/Adelaide"),
    ("AUS Central Standard Time", "Australia/Darwin"),
    ("E. Australia Standard Time", "Australia/Brisbane"),
    ("AUS Eastern Standard Time", "Australia/Sydney"),
    ("West Pacific Standard Time", "Pacific/Port_Moresby"),
    ("Tasmania Standard Time", "Australia/Hobart"),
    ("Vladivostok Standard Time", "Asia/Vladivostok"),
    ("Central Pacific Standard Time", "Pacific/Guadalcanal"),
    ("New Zealand Standard Time", "Pacific/Auckland"),
    ("Fiji Standard Time", "Pacific/Fiji"),
    ("Tonga Standard Time", "Pacific/Tongatapu"),
    ("Samoa Standard Time", "Pacific/Apia"),
    ("Line Islands Standard Time", "Pacific/Kiritimati"),
];

/// "+0530", "-0800", "+053000" → seconds east of UTC.
pub fn parse_offset(s: &str) -> Option<i32> {
    let s = s.trim();
    let (sign, digits) = match s.as_bytes().first()? {
        b'+' => (1, &s[1..]),
        b'-' => (-1, &s[1..]),
        _ => return None,
    };
    if digits.len() < 4 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let h: i32 = digits[0..2].parse().ok()?;
    let m: i32 = digits[2..4].parse().ok()?;
    let sec: i32 = if digits.len() >= 6 { digits[4..6].parse().ok()? } else { 0 };
    Some(sign * (h * 3600 + m * 60 + sec))
}

/// A zone name as a feed writes it, without the VTIMEZONE blocks: IANA ("Europe/London", also with
/// a vendor prefix such as "/mozilla.org/20050126_1/Europe/London"), Windows ("India Standard
/// Time"), or Outlook's display name ("(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi").
pub fn zone_named(name: &str) -> Option<Zone> {
    let name = name.trim().trim_matches('"');
    if name.is_empty() {
        return None;
    }
    if name.eq_ignore_ascii_case("utc") || name.eq_ignore_ascii_case("gmt") || name == "Z" {
        return Some(Zone::Utc);
    }
    if let Ok(tz) = chrono_tz::Tz::from_str(name) {
        return Some(Zone::Iana(tz));
    }
    // A vendor prefix: try each tail of the path, longest first.
    let segments: Vec<&str> = name.split('/').filter(|s| !s.is_empty()).collect();
    for start in 0..segments.len() {
        if let Ok(tz) = chrono_tz::Tz::from_str(&segments[start..].join("/")) {
            return Some(Zone::Iana(tz));
        }
    }
    if let Some((_, iana)) = WINDOWS_ZONES.iter().find(|(w, _)| w.eq_ignore_ascii_case(name)) {
        return chrono_tz::Tz::from_str(iana).ok().map(Zone::Iana);
    }
    // "(UTC+05:30) …" or "(GMT-08:00) …": the offset in the name is all there is to go on.
    let lower = name.to_ascii_lowercase();
    for prefix in ["(utc", "(gmt", "utc", "gmt"] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let digits: String = rest.chars().take_while(|c| *c != ')' && !c.is_whitespace()).filter(|c| *c != ':').collect();
            if digits.is_empty() {
                return Some(Zone::Utc);
            }
            if let Some(secs) = parse_offset(&digits) {
                return FixedOffset::east_opt(secs).map(Zone::Fixed);
            }
        }
    }
    None
}

/// One half of a VTIMEZONE: the offset from a yearly transition on, e.g. the second Sunday of March.
#[derive(Clone, Debug, PartialEq)]
pub struct Transition {
    pub offset_from: i32,
    pub offset_to: i32,
    /// The transition, as the RRULE has it: a month and an nth weekday (-1 = last). None for a
    /// one-off transition, which is then taken as always in force.
    pub month: Option<u32>,
    pub nth: i32,
    pub weekday: Weekday,
    /// The wall-clock time of the change, in the offset before it.
    pub at: NaiveTime,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct VTimezone {
    pub standard: Option<Transition>,
    pub daylight: Option<Transition>,
}

impl VTimezone {
    /// Seconds east of UTC in force at a wall-clock time.
    pub fn offset_at(&self, wall: NaiveDateTime) -> i32 {
        let (std, dst) = match (&self.standard, &self.daylight) {
            (Some(s), Some(d)) => (s, d),
            (Some(only), None) | (None, Some(only)) => return only.offset_to,
            (None, None) => return 0,
        };
        let (Some(dst_on), Some(std_on)) = (transition_in(dst, wall.year()), transition_in(std, wall.year())) else {
            return std.offset_to;
        };
        let in_dst = if dst_on < std_on { wall >= dst_on && wall < std_on } else { wall >= dst_on || wall < std_on };
        if in_dst {
            dst.offset_to
        } else {
            std.offset_to
        }
    }
}

fn transition_in(t: &Transition, year: i32) -> Option<NaiveDateTime> {
    let day = nth_weekday(year, t.month?, t.nth, t.weekday)?;
    Some(day.and_time(t.at))
}

/// The nth (1-based; negative counts from the end) given weekday of a month.
pub fn nth_weekday(year: i32, month: u32, nth: i32, weekday: Weekday) -> Option<NaiveDate> {
    if nth == 0 {
        return None;
    }
    if nth > 0 {
        let first = NaiveDate::from_ymd_opt(year, month, 1)?;
        let shift = (7 + weekday.num_days_from_monday() as i64 - first.weekday().num_days_from_monday() as i64) % 7;
        let day = first + Duration::days(shift + 7 * (nth as i64 - 1));
        (day.month() == month).then_some(day)
    } else {
        let last = last_of_month(year, month)?;
        let shift = (7 + last.weekday().num_days_from_monday() as i64 - weekday.num_days_from_monday() as i64) % 7;
        let day = last - Duration::days(shift + 7 * (-nth as i64 - 1));
        (day.month() == month).then_some(day)
    }
}

fn last_of_month(year: i32, month: u32) -> Option<NaiveDate> {
    let (y, m) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    NaiveDate::from_ymd_opt(y, m, 1).map(|d| d - Duration::days(1))
}

pub fn weekday_of(code: &str) -> Option<Weekday> {
    Some(match code.to_ascii_uppercase().as_str() {
        "MO" => Weekday::Mon,
        "TU" => Weekday::Tue,
        "WE" => Weekday::Wed,
        "TH" => Weekday::Thu,
        "FR" => Weekday::Fri,
        "SA" => Weekday::Sat,
        "SU" => Weekday::Sun,
        _ => return None,
    })
}

/// "2SU", "-1FR", "MO" → (ordinal, weekday); 0 = every one.
pub fn parse_byday(code: &str) -> Option<(i32, Weekday)> {
    let code = code.trim();
    if code.len() < 2 {
        return None;
    }
    let (num, day) = code.split_at(code.len() - 2);
    let nth = if num.is_empty() || num == "+" { 0 } else { num.trim_start_matches('+').parse().ok()? };
    Some((nth, weekday_of(day)?))
}

// ---- Times ------------------------------------------------------------------------------------

/// A DTSTART-like value: a date (all-day), or a wall-clock time in a zone.
#[derive(Clone, Debug, PartialEq)]
pub enum When {
    Date(NaiveDate),
    Time(NaiveDateTime, Zone),
}

impl When {
    pub fn instant(&self) -> Option<DateTime<Utc>> {
        match self {
            When::Time(wall, zone) => Some(to_utc(zone, *wall)),
            When::Date(_) => None,
        }
    }
}

pub fn parse_date(s: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(s.get(0..8)?, "%Y%m%d").ok()
}

pub fn parse_datetime(s: &str) -> Option<(NaiveDateTime, bool)> {
    let s = s.trim();
    let utc = s.ends_with('Z') || s.ends_with('z');
    let core = s.trim_end_matches(['Z', 'z']);
    let dt = NaiveDateTime::parse_from_str(core, "%Y%m%dT%H%M%S")
        .or_else(|_| NaiveDateTime::parse_from_str(core, "%Y%m%dT%H%M"))
        .ok()?;
    Some((dt, utc))
}

/// One value of a date-time property, read against the zones the file defines.
pub fn parse_when(value: &str, tzid: Option<&str>, date_only: bool, zones: &HashMap<String, VTimezone>) -> Option<When> {
    let value = value.trim();
    if date_only || (value.len() == 8 && !value.contains('T')) {
        return parse_date(value).map(When::Date);
    }
    let (wall, utc) = parse_datetime(value)?;
    if utc {
        return Some(When::Time(wall, Zone::Utc));
    }
    let zone = match tzid {
        None => Zone::Local,
        Some(id) => zone_named(id)
            .or_else(|| zones.get(id.trim_matches('"')).cloned().map(Zone::Rules))
            .unwrap_or(Zone::Local),
    };
    Some(When::Time(wall, zone))
}

/// "PT45M", "PT1H30M", "P1D", "P1DT2H", "-PT15M", "P2W".
pub fn parse_duration(s: &str) -> Option<Duration> {
    let s = s.trim();
    let (neg, s) = match s.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, s.strip_prefix('+').unwrap_or(s)),
    };
    let s = s.strip_prefix('P')?;
    let mut total = Duration::zero();
    let mut num = String::new();
    let mut in_time = false;
    for c in s.chars() {
        match c {
            'T' => in_time = true,
            '0'..='9' => num.push(c),
            unit => {
                let n: i64 = num.parse().ok()?;
                num.clear();
                total += match (unit, in_time) {
                    ('W', false) => Duration::weeks(n),
                    ('D', false) => Duration::days(n),
                    ('H', true) => Duration::hours(n),
                    ('M', true) => Duration::minutes(n),
                    ('S', true) => Duration::seconds(n),
                    _ => return None,
                };
            }
        }
    }
    if !num.is_empty() {
        return None;
    }
    Some(if neg { -total } else { total })
}

// ---- Repeats ----------------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Freq {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Until {
    Instant(DateTime<Utc>),
    Wall(NaiveDateTime),
    Date(NaiveDate),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    pub freq: Freq,
    pub interval: u32,
    pub count: Option<u32>,
    pub until: Option<Until>,
    pub by_day: Vec<(i32, Weekday)>,
    pub by_month_day: Vec<i32>,
    pub by_month: Vec<u32>,
    pub by_set_pos: Vec<i32>,
}

pub fn parse_rule(value: &str) -> Option<Rule> {
    let mut rule = Rule {
        freq: Freq::Daily,
        interval: 1,
        count: None,
        until: None,
        by_day: Vec::new(),
        by_month_day: Vec::new(),
        by_month: Vec::new(),
        by_set_pos: Vec::new(),
    };
    let mut freq = None;
    for part in value.split(';') {
        let Some((k, v)) = part.split_once('=') else { continue };
        match k.trim().to_ascii_uppercase().as_str() {
            "FREQ" => {
                freq = Some(match v.trim().to_ascii_uppercase().as_str() {
                    "DAILY" => Freq::Daily,
                    "WEEKLY" => Freq::Weekly,
                    "MONTHLY" => Freq::Monthly,
                    "YEARLY" => Freq::Yearly,
                    // Hourly and finer repeat inside a day; no calendar a person keeps does that.
                    _ => return None,
                })
            }
            "INTERVAL" => rule.interval = v.trim().parse().ok().filter(|n: &u32| *n > 0).unwrap_or(1),
            "COUNT" => rule.count = v.trim().parse().ok(),
            "UNTIL" => {
                let v = v.trim();
                rule.until = if v.len() == 8 {
                    parse_date(v).map(Until::Date)
                } else {
                    parse_datetime(v).map(|(dt, utc)| {
                        if utc {
                            Until::Instant(Utc.from_utc_datetime(&dt))
                        } else {
                            Until::Wall(dt)
                        }
                    })
                }
            }
            "BYDAY" => rule.by_day = v.split(',').filter_map(parse_byday).collect(),
            "BYMONTHDAY" => rule.by_month_day = v.split(',').filter_map(|d| d.trim().parse().ok()).collect(),
            "BYMONTH" => rule.by_month = v.split(',').filter_map(|d| d.trim().parse().ok()).collect(),
            "BYSETPOS" => rule.by_set_pos = v.split(',').filter_map(|d| d.trim().parse().ok()).collect(),
            _ => {}
        }
    }
    rule.freq = freq?;
    Some(rule)
}

/// The days one month offers under a monthly (or yearly-by-month) rule, in order.
fn days_in_month(rule: &Rule, year: i32, month: u32, start: NaiveDate) -> Vec<NaiveDate> {
    let Some(last) = last_of_month(year, month) else { return Vec::new() };
    let mut days: Vec<NaiveDate> = if !rule.by_month_day.is_empty() {
        rule.by_month_day
            .iter()
            .filter_map(|&d| {
                let day = if d > 0 { d } else { last.day() as i32 + d + 1 };
                if day < 1 {
                    None
                } else {
                    NaiveDate::from_ymd_opt(year, month, day as u32)
                }
            })
            .collect()
    } else if !rule.by_day.is_empty() {
        let mut out = Vec::new();
        for &(nth, wd) in &rule.by_day {
            if nth != 0 {
                out.extend(nth_weekday(year, month, nth, wd));
            } else {
                let mut d = nth_weekday(year, month, 1, wd);
                while let Some(day) = d {
                    if day.month() != month {
                        break;
                    }
                    out.push(day);
                    d = Some(day + Duration::days(7));
                }
            }
        }
        out
    } else {
        NaiveDate::from_ymd_opt(year, month, start.day()).into_iter().collect()
    };
    if !rule.by_month_day.is_empty() && !rule.by_day.is_empty() {
        let wanted: Vec<Weekday> = rule.by_day.iter().map(|(_, w)| *w).collect();
        days.retain(|d| wanted.contains(&d.weekday()));
    }
    days.sort();
    days.dedup();
    apply_set_pos(days, &rule.by_set_pos)
}

fn apply_set_pos(days: Vec<NaiveDate>, set_pos: &[i32]) -> Vec<NaiveDate> {
    if set_pos.is_empty() {
        return days;
    }
    let n = days.len() as i32;
    let mut out: Vec<NaiveDate> = set_pos
        .iter()
        .filter_map(|&p| {
            let i = if p > 0 { p - 1 } else { n + p };
            (i >= 0 && i < n).then(|| days[i as usize])
        })
        .collect();
    out.sort();
    out.dedup();
    out
}

fn add_months(year: i32, month: u32, add: i64) -> (i32, u32) {
    let total = year as i64 * 12 + (month as i64 - 1) + add;
    ((total.div_euclid(12)) as i32, (total.rem_euclid(12) + 1) as u32)
}

/// Periods walked at most, so a malformed rule can never spin: daily for 30 years.
const MAX_PERIODS: i64 = 11_000;

/// Every start of a repeating event, in its own wall-clock time, up to `limit` (an instant) — in
/// order, starting with the first. `is_after_limit` is asked of each candidate so the walk stops as
/// soon as it is past the window.
pub fn expand(rule: &Rule, start: NaiveDateTime, zone: &Zone, limit: DateTime<Utc>) -> Vec<NaiveDateTime> {
    let time = start.time();
    let first_day = start.date();
    let mut out = Vec::new();
    let mut emitted = 0u32;
    let until_ok = |wall: NaiveDateTime| -> bool {
        match &rule.until {
            None => true,
            Some(Until::Instant(t)) => to_utc(zone, wall) <= *t,
            Some(Until::Wall(w)) => wall <= *w,
            Some(Until::Date(d)) => wall.date() <= *d,
        }
    };
    let month_ok = |d: NaiveDate| rule.by_month.is_empty() || rule.by_month.contains(&d.month());
    let interval = rule.interval.max(1) as i64;
    'periods: for period in 0..MAX_PERIODS {
        let candidates: Vec<NaiveDate> = match rule.freq {
            Freq::Daily => {
                let d = first_day + Duration::days(period * interval);
                let day_ok = rule.by_day.is_empty() || rule.by_day.iter().any(|(_, w)| *w == d.weekday());
                if day_ok && month_ok(d) {
                    vec![d]
                } else {
                    Vec::new()
                }
            }
            Freq::Weekly => {
                // Weeks run Monday to Sunday (WKST=MO, the default and Outlook's and Google's own).
                let week_start = first_day - Duration::days(first_day.weekday().num_days_from_monday() as i64)
                    + Duration::weeks(period * interval);
                let mut days: Vec<NaiveDate> = if rule.by_day.is_empty() {
                    vec![week_start + Duration::days(first_day.weekday().num_days_from_monday() as i64)]
                } else {
                    rule.by_day
                        .iter()
                        .map(|(_, w)| week_start + Duration::days(w.num_days_from_monday() as i64))
                        .collect()
                };
                days.sort();
                days.dedup();
                days.retain(|d| month_ok(*d));
                days
            }
            Freq::Monthly => {
                let (y, m) = add_months(first_day.year(), first_day.month(), period * interval);
                if !rule.by_month.is_empty() && !rule.by_month.contains(&m) {
                    Vec::new()
                } else {
                    days_in_month(rule, y, m, first_day)
                }
            }
            Freq::Yearly => {
                let y = first_day.year() + (period * interval) as i32;
                let months: Vec<u32> = if rule.by_month.is_empty() { vec![first_day.month()] } else { rule.by_month.clone() };
                let mut days = Vec::new();
                for m in months {
                    if rule.by_day.is_empty() && rule.by_month_day.is_empty() {
                        days.extend(NaiveDate::from_ymd_opt(y, m, first_day.day()));
                    } else {
                        days.extend(days_in_month(rule, y, m, first_day));
                    }
                }
                days.sort();
                days
            }
        };
        for day in candidates {
            let wall = day.and_time(time);
            if wall < start {
                continue;
            }
            if !until_ok(wall) {
                break 'periods;
            }
            if let Some(count) = rule.count {
                if emitted >= count {
                    break 'periods;
                }
            }
            if to_utc(zone, wall) > limit {
                break 'periods;
            }
            emitted += 1;
            out.push(wall);
        }
    }
    out
}

// ---- Events -----------------------------------------------------------------------------------

#[derive(Clone, Debug, Default)]
struct RawEvent {
    props: Vec<Prop>,
}

impl RawEvent {
    fn get(&self, name: &str) -> Option<&Prop> {
        self.props.iter().find(|p| p.name == name)
    }
    fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Prop> + 'a {
        self.props.iter().filter(move |p| p.name == name)
    }
    fn text(&self, name: &str) -> String {
        self.get(name).map(|p| unescape(&p.value)).unwrap_or_default()
    }
    fn when(&self, name: &str, zones: &HashMap<String, VTimezone>) -> Option<When> {
        let p = self.get(name)?;
        parse_when(&p.value, p.param("TZID"), p.param("VALUE").is_some_and(|v| v.eq_ignore_ascii_case("DATE")), zones)
    }
}

/// One meeting at one time — a single event, or one repeat of a repeating one.
#[derive(Clone, Debug, PartialEq)]
pub struct Occurrence {
    pub uid: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub location: String,
    pub link: Option<String>,
    pub calendar: String,
}

/// What a feed holds: its name, and its events as written.
pub struct Feed {
    pub name: String,
    events: Vec<RawEvent>,
    zones: HashMap<String, VTimezone>,
}

fn read_transition(props: &[Prop]) -> Option<Transition> {
    let get = |n: &str| props.iter().find(|p| p.name == n);
    let offset_to = parse_offset(&get("TZOFFSETTO")?.value)?;
    let offset_from = get("TZOFFSETFROM").and_then(|p| parse_offset(&p.value)).unwrap_or(offset_to);
    let start = get("DTSTART").and_then(|p| parse_datetime(&p.value)).map(|(dt, _)| dt);
    let at = start.map(|s| s.time()).unwrap_or(NaiveTime::from_hms_opt(2, 0, 0)?);
    let rule = get("RRULE").and_then(|p| parse_rule(&p.value));
    let (month, nth, weekday) = match rule {
        Some(r) => {
            let month = r.by_month.first().copied().or_else(|| start.map(|s| s.month()));
            let (nth, wd) = r.by_day.first().copied().unwrap_or((1, Weekday::Sun));
            (month, if nth == 0 { 1 } else { nth }, wd)
        }
        None => (None, 1, Weekday::Sun),
    };
    Some(Transition { offset_from, offset_to, month, nth, weekday, at })
}

pub fn parse_feed(text: &str, fallback_name: &str) -> Feed {
    let mut name = String::new();
    let mut events = Vec::new();
    let mut zones = HashMap::new();
    // What is being read: the event or zone part, and its properties.
    let mut stack: Vec<String> = Vec::new();
    let mut event: Option<RawEvent> = None;
    let mut zone_id: Option<String> = None;
    let mut zone = VTimezone::default();
    let mut part: Vec<Prop> = Vec::new();
    for line in unfold(text) {
        let Some(p) = parse_line(&line) else { continue };
        match p.name.as_str() {
            "BEGIN" => {
                let what = p.value.trim().to_ascii_uppercase();
                match what.as_str() {
                    "VEVENT" if stack.last().map(String::as_str) == Some("VCALENDAR") => event = Some(RawEvent::default()),
                    "VTIMEZONE" => {
                        zone_id = None;
                        zone = VTimezone::default();
                    }
                    "STANDARD" | "DAYLIGHT" => part.clear(),
                    _ => {}
                }
                stack.push(what);
            }
            "END" => {
                let what = p.value.trim().to_ascii_uppercase();
                match what.as_str() {
                    "VEVENT" => events.extend(event.take()),
                    "STANDARD" => zone.standard = read_transition(&part),
                    "DAYLIGHT" => zone.daylight = read_transition(&part),
                    "VTIMEZONE" => {
                        if let Some(id) = zone_id.take() {
                            zones.insert(id, std::mem::take(&mut zone));
                        }
                    }
                    _ => {}
                }
                // Pop back to the matching BEGIN, so one malformed block cannot derail the rest.
                if let Some(i) = stack.iter().rposition(|s| *s == what) {
                    stack.truncate(i);
                }
            }
            _ => match stack.last().map(String::as_str) {
                Some("VEVENT") => {
                    if let Some(e) = event.as_mut() {
                        e.props.push(p);
                    }
                }
                Some("STANDARD") | Some("DAYLIGHT") => part.push(p),
                Some("VTIMEZONE") if p.name == "TZID" => zone_id = Some(p.value.trim().to_string()),
                Some("VCALENDAR") if p.name == "X-WR-CALNAME" => name = unescape(&p.value).trim().to_string(),
                _ => {}
            },
        }
    }
    if name.is_empty() {
        name = fallback_name.to_string();
    }
    Feed { name, events, zones }
}

/// The hosts whose links are a meeting to join, and what the path has to look like.
fn is_meeting_link(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("https://").or_else(|| lower.strip_prefix("http://")) else {
        return false;
    };
    let (host, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let host = host.split(':').next().unwrap_or(host);
    let under = |domain: &str| host == domain || host.ends_with(&format!(".{domain}"));
    if under("zoom.us") || under("zoomgov.com") {
        return ["/j/", "/my/", "/w/", "/s/"].iter().any(|p| path.starts_with(p));
    }
    if host == "meet.google.com" {
        return path.len() > 1;
    }
    if host == "teams.microsoft.com" {
        return path.starts_with("/l/meetup-join") || path.starts_with("/meet/");
    }
    if host == "teams.live.com" {
        return path.len() > 1;
    }
    if under("webex.com") {
        return path.len() > 1;
    }
    if host == "gotomeet.me" || under("gotomeeting.com") {
        return path.len() > 1;
    }
    if host == "whereby.com" || host == "chime.aws" {
        return path.len() > 1;
    }
    if host == "facetime.apple.com" {
        return path.starts_with("/join");
    }
    false
}

/// Every web address in a piece of text, in order.
pub fn links_in(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let lower = text.to_ascii_lowercase();
    let mut from = 0;
    while let Some(found) = ["https://", "http://"].iter().filter_map(|s| lower[from..].find(s)).min() {
        let start = from + found;
        let end = text[start..]
            .find(|c: char| c.is_whitespace() || matches!(c, '<' | '>' | '"' | '\'' | '[' | ']' | '{' | '}' | '|' | '\\' | '^' | '`'))
            .map(|i| start + i)
            .unwrap_or(text.len());
        let link = text[start..end].trim_end_matches(['.', ',', ';', ':', '!', '?', ')', '*']);
        if link.len() > "https://".len() {
            out.push(link.to_string());
        }
        from = end.max(start + 1);
    }
    out
}

/// The first link to a meeting, looked for where calendars put them: the event's URL, Google's and
/// Teams' own conference properties, then the location and the description.
pub fn meeting_link(props: &[(&str, &str)]) -> Option<String> {
    props.iter().flat_map(|(_, text)| links_in(text)).find(|l| is_meeting_link(l))
}

impl Feed {
    /// Every occurrence that ends after `from` and starts before `to`.
    pub fn occurrences(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<Occurrence> {
        // Moved or cancelled repeats, by event and by the start they replace.
        let mut overrides: HashMap<String, HashSet<DateTime<Utc>>> = HashMap::new();
        for e in &self.events {
            if let (Some(rid), uid) = (e.when("RECURRENCE-ID", &self.zones), e.text("UID")) {
                let key = match rid {
                    When::Time(..) => rid.instant(),
                    When::Date(d) => Some(Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap_or_default())),
                };
                if let Some(at) = key {
                    overrides.entry(uid).or_default().insert(at);
                }
            }
        }
        let mut out = Vec::new();
        for e in &self.events {
            if e.text("STATUS").eq_ignore_ascii_case("CANCELLED") {
                continue;
            }
            let Some(When::Time(wall, zone)) = e.when("DTSTART", &self.zones) else {
                continue; // all-day, or unreadable
            };
            let start = to_utc(&zone, wall);
            let length = match e.when("DTEND", &self.zones).and_then(|w| w.instant()) {
                Some(end) if end >= start => end - start,
                _ => e.get("DURATION").and_then(|p| parse_duration(&p.value)).filter(|d| *d >= Duration::zero()).unwrap_or_else(Duration::zero),
            };
            let uid = e.text("UID");
            let sources = [
                ("URL", e.text("URL")),
                ("X-GOOGLE-CONFERENCE", e.text("X-GOOGLE-CONFERENCE")),
                ("X-MICROSOFT-ONLINEMEETINGEXTERNALLINK", e.text("X-MICROSOFT-ONLINEMEETINGEXTERNALLINK")),
                ("X-MICROSOFT-SKYPETEAMSMEETINGURL", e.text("X-MICROSOFT-SKYPETEAMSMEETINGURL")),
                ("LOCATION", e.text("LOCATION")),
                ("DESCRIPTION", e.text("DESCRIPTION")),
            ];
            let link = meeting_link(&sources.iter().map(|(k, v)| (*k, v.as_str())).collect::<Vec<_>>());
            let title = {
                let t = e.text("SUMMARY");
                if t.trim().is_empty() {
                    "Busy".to_string()
                } else {
                    t.trim().to_string()
                }
            };
            let location = e.text("LOCATION").lines().next().unwrap_or("").trim().to_string();
            let make = |at: DateTime<Utc>| Occurrence {
                uid: uid.clone(),
                title: title.clone(),
                start: at,
                end: at + length,
                location: location.clone(),
                link: link.clone(),
                calendar: self.name.clone(),
            };
            let is_override = e.get("RECURRENCE-ID").is_some();
            let rule = if is_override { None } else { e.get("RRULE").and_then(|p| parse_rule(&p.value)) };
            match rule {
                None => {
                    if start < to && start + length > from {
                        out.push(make(start));
                    }
                }
                Some(rule) => {
                    let excluded: Vec<When> = e
                        .all("EXDATE")
                        .flat_map(|p| {
                            let tzid = p.param("TZID").map(str::to_string);
                            let date_only = p.param("VALUE").is_some_and(|v| v.eq_ignore_ascii_case("DATE"));
                            p.value
                                .split(',')
                                .filter_map(|v| parse_when(v, tzid.as_deref(), date_only, &self.zones))
                                .collect::<Vec<_>>()
                        })
                        .collect();
                    let moved = overrides.get(&uid);
                    for at_wall in expand(&rule, wall, &zone, to) {
                        let at = to_utc(&zone, at_wall);
                        if at + length <= from {
                            continue;
                        }
                        let skip = excluded.iter().any(|x| match x {
                            When::Date(d) => *d == at_wall.date(),
                            When::Time(..) => x.instant() == Some(at),
                        }) || moved.is_some_and(|m| m.contains(&at));
                        if !skip {
                            out.push(make(at));
                        }
                    }
                }
            }
        }
        out
    }
}

/// The meeting the notch shows, and the next few after it. An event already under way is shown
/// unless it began more than 15 minutes ago and another starts within the hour — a long block in
/// the diary should not hide the call that comes up in the middle of it.
pub fn pick(mut all: Vec<Occurrence>, now: DateTime<Utc>) -> (Option<Occurrence>, Vec<Occurrence>) {
    all.retain(|o| o.end > now && o.start < now + Duration::hours(24));
    all.sort_by(|a, b| a.start.cmp(&b.start).then_with(|| a.title.cmp(&b.title)));
    all.dedup_by(|a, b| a.uid == b.uid && a.start == b.start && !a.uid.is_empty());
    let soon = all.iter().find(|o| o.start > now).map(|o| o.start);
    let pos = all.iter().position(|o| {
        let under_way = o.start <= now;
        !(under_way && now - o.start > Duration::minutes(15) && soon.is_some_and(|s| s - now <= Duration::hours(1)))
    });
    let Some(pos) = pos else { return (None, Vec::new()) };
    let next = all.remove(pos);
    let end_of_day = {
        let local = next.start.with_timezone(&chrono::Local);
        let midnight = local.date_naive().and_hms_opt(23, 59, 59).unwrap_or_default();
        to_utc(&Zone::Local, midnight)
    };
    let later = all.into_iter().filter(|o| o.start > next.start && o.start <= end_of_day).take(2).collect();
    (Some(next), later)
}

// ---- What the notch is sent -------------------------------------------------------------------

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct EventView {
    /// The event and the time, so a heads-up is given once per meeting.
    pub id: String,
    pub title: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub location: String,
    pub link: Option<String>,
    pub calendar: String,
}

impl EventView {
    fn of(o: &Occurrence) -> Self {
        Self {
            id: format!("{}@{}", o.uid, o.start.timestamp()),
            title: o.title.clone(),
            start_ms: o.start.timestamp_millis(),
            end_ms: o.end.timestamp_millis(),
            location: o.location.clone(),
            link: o.link.clone(),
            calendar: o.calendar.clone(),
        }
    }
}

#[derive(Clone, Serialize, PartialEq, Debug, Default)]
pub struct MeetingState {
    /// Whether any feed is set up; without one the card says how to add one.
    pub configured: bool,
    /// Why the last read failed, for every feed that did.
    pub error: Option<String>,
    pub next: Option<EventView>,
    pub later: Vec<EventView>,
}

/// webcal:// is how calendar sites offer a feed to subscribe to; it is https underneath.
pub fn normalize_feed(url: &str) -> Option<String> {
    let url = url.trim();
    if url.is_empty() || url.chars().any(char::is_whitespace) {
        return None;
    }
    let lower = url.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("webcal://").map(|_| &url["webcal://".len()..]) {
        return Some(format!("https://{rest}"));
    }
    (lower.starts_with("https://") || lower.starts_with("http://")).then(|| url.to_string())
}

fn feed_host(url: &str) -> String {
    url.split("://").nth(1).and_then(|r| r.split('/').next()).unwrap_or("Calendar").to_string()
}

static ENABLED: AtomicBool = AtomicBool::new(false);
static POKED: AtomicBool = AtomicBool::new(true);
static FEEDS: Mutex<Vec<String>> = Mutex::new(Vec::new());
static READ: Mutex<Vec<Occurrence>> = Mutex::new(Vec::new());
static ERROR: Mutex<Option<String>> = Mutex::new(None);
static STATE: Mutex<Option<MeetingState>> = Mutex::new(None);
static HEADS_UP: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(5);

pub fn set_enabled(on: bool) {
    let was = ENABLED.swap(on, Ordering::SeqCst);
    if on && !was {
        POKED.store(true, Ordering::SeqCst);
    }
}

pub fn set_heads_up(minutes: u32) {
    HEADS_UP.store(minutes, Ordering::SeqCst);
}

pub fn set_feeds(feeds: Vec<String>) {
    *FEEDS.lock().unwrap_or_else(|e| e.into_inner()) = feeds;
    POKED.store(true, Ordering::SeqCst);
}

#[tauri::command]
pub fn get_meeting() -> MeetingState {
    STATE.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or_default()
}

/// The feeds, for Settings only: they are secret addresses, so the notch is never sent them.
#[tauri::command]
pub fn get_meeting_feeds(app: AppHandle) -> Vec<String> {
    let st = app.state::<crate::AppState>();
    let c = st.cfg.lock().unwrap();
    c.meeting_feeds.clone()
}

/// Keeps the addresses that are web addresses (webcal:// becomes https://) and reads them now.
#[tauri::command]
pub fn set_meeting_feeds(app: AppHandle, feeds: Vec<String>) -> Result<Vec<String>, String> {
    let mut clean: Vec<String> = Vec::new();
    for f in &feeds {
        if f.trim().is_empty() {
            continue;
        }
        let Some(url) = normalize_feed(f) else {
            return Err(format!("“{}” is not a web address", f.trim()));
        };
        if !clean.contains(&url) {
            clean.push(url);
        }
    }
    {
        let st = app.state::<crate::AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.meeting_feeds = clean.clone();
        crate::config::save(&c);
    }
    set_feeds(clean.clone());
    Ok(clean)
}

#[tauri::command]
pub fn meeting_refresh() {
    POKED.store(true, Ordering::SeqCst);
}

/// Opens a meeting link in the browser. Only web addresses: the link came from a calendar feed.
#[tauri::command]
pub fn meeting_join(link: String) -> Result<(), String> {
    if !crate::shell::is_web_link(&link) {
        return Err("not a web address".into());
    }
    crate::shell::open(link.trim());
    Ok(())
}

fn fetch(url: &str) -> Result<String, String> {
    let resp = ureq::get(url)
        .timeout(std::time::Duration::from_secs(20))
        .set("Accept", "text/calendar, text/plain, */*")
        .call()
        .map_err(|e| match e {
            ureq::Error::Status(code, _) => format!("the calendar answered {code}"),
            other => other.kind().to_string(),
        })?;
    let mut text = String::new();
    use std::io::Read;
    resp.into_reader()
        .take(8 * 1024 * 1024)
        .read_to_string(&mut text)
        .map_err(|e| e.to_string())?;
    if !text.contains("BEGIN:VCALENDAR") {
        return Err("that address is not an iCal calendar".into());
    }
    Ok(text)
}

fn read_all(feeds: &[String]) -> (Vec<Occurrence>, Option<String>) {
    let now = Utc::now();
    let (from, to) = (now - Duration::hours(24), now + Duration::hours(48));
    let mut all = Vec::new();
    let mut errors = Vec::new();
    for url in feeds {
        match fetch(url) {
            Ok(text) => all.extend(parse_feed(&text, &feed_host(url)).occurrences(from, to)),
            Err(e) => {
                crate::applog(&format!("meeting: {} could not be read ({e})", feed_host(url)));
                errors.push(format!("{}: {e}", feed_host(url)));
            }
        }
    }
    (all, (!errors.is_empty()).then(|| errors.join("; ")))
}

const REFRESH: std::time::Duration = std::time::Duration::from_secs(600);

pub fn start(app: AppHandle) {
    {
        let st = app.state::<crate::AppState>();
        let c = st.cfg.lock().unwrap();
        set_feeds(c.meeting_feeds.clone());
        set_heads_up(c.meeting_heads_up);
    }
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let mut last_read: Option<std::time::Instant> = None;
        let mut announced: HashSet<String> = HashSet::new();
        loop {
            if ENABLED.load(Ordering::SeqCst) {
                let feeds = FEEDS.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let due = last_read.is_none_or(|t| t.elapsed() >= REFRESH);
                if POKED.swap(false, Ordering::SeqCst) || due {
                    last_read = Some(std::time::Instant::now());
                    let (read, error) = if feeds.is_empty() { (Vec::new(), None) } else { read_all(&feeds) };
                    *READ.lock().unwrap_or_else(|e| e.into_inner()) = read;
                    *ERROR.lock().unwrap_or_else(|e| e.into_inner()) = error;
                }
                let now = Utc::now();
                let (next, later) = pick(READ.lock().unwrap_or_else(|e| e.into_inner()).clone(), now);
                let state = MeetingState {
                    configured: !feeds.is_empty(),
                    error: ERROR.lock().unwrap_or_else(|e| e.into_inner()).clone(),
                    next: next.as_ref().map(EventView::of),
                    later: later.iter().map(EventView::of).collect(),
                };
                let changed = {
                    let mut current = STATE.lock().unwrap_or_else(|e| e.into_inner());
                    let changed = current.as_ref() != Some(&state);
                    *current = Some(state.clone());
                    changed
                };
                if changed {
                    let _ = app.emit("meeting", &state);
                }
                // The heads-up, once per meeting, while it is still ahead.
                let lead = HEADS_UP.load(Ordering::SeqCst) as i64;
                if let Some(n) = &next {
                    let until = n.start - now;
                    let view = EventView::of(n);
                    if lead > 0 && until > Duration::zero() && until <= Duration::minutes(lead) && announced.insert(view.id.clone()) {
                        let _ = app.emit("meeting_heads_up", &view);
                    }
                }
                if announced.len() > 200 {
                    announced.clear();
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(5));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        Utc.from_utc_datetime(&NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap())
    }

    fn wall(s: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M").unwrap()
    }

    #[test]
    fn folded_lines_are_joined_and_params_split() {
        let lines = unfold("SUMMARY:Weekly sync wit\r\n h the team\r\nDTSTART;TZID=\"Europe/London\":20261020T090000\r\n");
        assert_eq!(lines, ["SUMMARY:Weekly sync with the team", "DTSTART;TZID=\"Europe/London\":20261020T090000"]);
        let p = parse_line(&lines[1]).unwrap();
        assert_eq!(p.name, "DTSTART");
        assert_eq!(p.param("tzid"), Some("Europe/London"));
        assert_eq!(p.value, "20261020T090000");
        let q = parse_line("ATTENDEE;CN=\"Doe: Jane\";PARTSTAT=ACCEPTED:mailto:jane@example.com").unwrap();
        assert_eq!(q.param("CN"), Some("Doe: Jane"));
        assert_eq!(q.value, "mailto:jane@example.com");
        assert_eq!(unescape("Room 4\\, Floor 2\\nBring\\; snacks\\\\"), "Room 4, Floor 2\nBring; snacks\\");
    }

    #[test]
    fn zones_by_every_name_a_feed_uses() {
        assert!(matches!(zone_named("Europe/London"), Some(Zone::Iana(_))));
        assert!(matches!(zone_named("/mozilla.org/20050126_1/America/New_York"), Some(Zone::Iana(_))));
        assert_eq!(zone_named("India Standard Time"), Some(Zone::Iana(chrono_tz::Asia::Kolkata)));
        assert_eq!(zone_named("(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi"), FixedOffset::east_opt(19800).map(Zone::Fixed));
        assert_eq!(zone_named("UTC"), Some(Zone::Utc));
        assert_eq!(zone_named("Nowhere Standard Time"), None);
        for (w, iana) in WINDOWS_ZONES {
            assert!(chrono_tz::Tz::from_str(iana).is_ok(), "{w} maps to {iana}, which chrono-tz must know");
        }
    }

    #[test]
    fn wall_times_become_instants_across_daylight_saving() {
        let ny = zone_named("Eastern Standard Time").unwrap();
        assert_eq!(to_utc(&ny, wall("2026-07-01 09:00")), utc("2026-07-01 13:00"), "EDT is UTC-4");
        assert_eq!(to_utc(&ny, wall("2026-12-01 09:00")), utc("2026-12-01 14:00"), "EST is UTC-5");
        // 2:30 on the spring-forward night does not exist; it is read as 3:30
        assert_eq!(to_utc(&ny, wall("2026-03-08 02:30")), utc("2026-03-08 07:30"));
    }

    #[test]
    fn a_vtimezone_with_its_own_rules() {
        let ics = "BEGIN:VCALENDAR\nBEGIN:VTIMEZONE\nTZID:Custom Eastern\nBEGIN:STANDARD\nDTSTART:16011104T020000\nRRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11\nTZOFFSETFROM:-0400\nTZOFFSETTO:-0500\nEND:STANDARD\nBEGIN:DAYLIGHT\nDTSTART:16010311T020000\nRRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3\nTZOFFSETFROM:-0500\nTZOFFSETTO:-0400\nEND:DAYLIGHT\nEND:VTIMEZONE\nBEGIN:VEVENT\nUID:a\nSUMMARY:Summer\nDTSTART;TZID=Custom Eastern:20260701T090000\nDTEND;TZID=Custom Eastern:20260701T093000\nEND:VEVENT\nBEGIN:VEVENT\nUID:b\nSUMMARY:Winter\nDTSTART;TZID=Custom Eastern:20261201T090000\nDURATION:PT45M\nEND:VEVENT\nEND:VCALENDAR\n";
        let feed = parse_feed(ics, "x");
        let all = feed.occurrences(utc("2026-01-01 00:00"), utc("2027-01-01 00:00"));
        let summer = all.iter().find(|o| o.title == "Summer").unwrap();
        assert_eq!(summer.start, utc("2026-07-01 13:00"));
        assert_eq!(summer.end, utc("2026-07-01 13:30"));
        let winter = all.iter().find(|o| o.title == "Winter").unwrap();
        assert_eq!(winter.start, utc("2026-12-01 14:00"));
        assert_eq!(winter.end - winter.start, Duration::minutes(45));
    }

    #[test]
    fn nth_weekdays_of_a_month() {
        let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        assert_eq!(nth_weekday(2026, 3, 2, Weekday::Sun), Some(d("2026-03-08")));
        assert_eq!(nth_weekday(2026, 10, -1, Weekday::Fri), Some(d("2026-10-30")));
        assert_eq!(nth_weekday(2026, 2, 5, Weekday::Mon), None, "February 2026 has four Mondays");
        assert_eq!(parse_byday("-1FR"), Some((-1, Weekday::Fri)));
        assert_eq!(parse_byday("MO"), Some((0, Weekday::Mon)));
    }

    #[test]
    fn durations_parse() {
        assert_eq!(parse_duration("PT45M"), Some(Duration::minutes(45)));
        assert_eq!(parse_duration("PT1H30M"), Some(Duration::minutes(90)));
        assert_eq!(parse_duration("P1DT2H"), Some(Duration::hours(26)));
        assert_eq!(parse_duration("-PT15M"), Some(Duration::minutes(-15)));
        assert_eq!(parse_duration("P2W"), Some(Duration::weeks(2)));
        assert_eq!(parse_duration("PT"), Some(Duration::zero()));
        assert_eq!(parse_duration("45M"), None);
    }

    #[test]
    fn weekly_repeats_on_chosen_days_with_count_and_until() {
        let rule = parse_rule("FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=5").unwrap();
        let got = expand(&rule, wall("2026-10-19 10:00"), &Zone::Utc, utc("2027-01-01 00:00"));
        let want: Vec<_> = ["2026-10-19 10:00", "2026-10-21 10:00", "2026-10-23 10:00", "2026-10-26 10:00", "2026-10-28 10:00"]
            .iter()
            .map(|s| wall(s))
            .collect();
        assert_eq!(got, want);

        let every_other = parse_rule("FREQ=WEEKLY;INTERVAL=2;UNTIL=20261117T235959Z").unwrap();
        let got = expand(&every_other, wall("2026-10-20 15:00"), &Zone::Utc, utc("2027-01-01 00:00"));
        assert_eq!(got, [wall("2026-10-20 15:00"), wall("2026-11-03 15:00"), wall("2026-11-17 15:00")]);
    }

    #[test]
    fn a_weekly_rule_starting_mid_week_skips_the_days_before_it() {
        let rule = parse_rule("FREQ=WEEKLY;BYDAY=MO,TH").unwrap();
        let got = expand(&rule, wall("2026-10-21 09:00"), &Zone::Utc, utc("2026-10-28 00:00"));
        assert_eq!(got, [wall("2026-10-22 09:00"), wall("2026-10-26 09:00")]);
    }

    #[test]
    fn monthly_repeats_by_weekday_day_and_set_position() {
        let second_tuesday = parse_rule("FREQ=MONTHLY;BYDAY=2TU").unwrap();
        let got = expand(&second_tuesday, wall("2026-10-13 11:00"), &Zone::Utc, utc("2027-01-01 00:00"));
        assert_eq!(got, [wall("2026-10-13 11:00"), wall("2026-11-10 11:00"), wall("2026-12-08 11:00")]);

        let last_weekday = parse_rule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3").unwrap();
        let got = expand(&last_weekday, wall("2026-10-30 16:00"), &Zone::Utc, utc("2027-06-01 00:00"));
        assert_eq!(got, [wall("2026-10-30 16:00"), wall("2026-11-30 16:00"), wall("2026-12-31 16:00")]);

        // The 31st: months without one are skipped, as RFC 5545 says
        let on_31 = parse_rule("FREQ=MONTHLY").unwrap();
        let got = expand(&on_31, wall("2026-10-31 08:00"), &Zone::Utc, utc("2027-02-01 00:00"));
        assert_eq!(got, [wall("2026-10-31 08:00"), wall("2026-12-31 08:00"), wall("2027-01-31 08:00")]);
    }

    #[test]
    fn daily_and_yearly() {
        let weekdays = parse_rule("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR").unwrap();
        let got = expand(&weekdays, wall("2026-10-23 09:30"), &Zone::Utc, utc("2026-10-28 00:00"));
        assert_eq!(got, [wall("2026-10-23 09:30"), wall("2026-10-26 09:30"), wall("2026-10-27 09:30")]);
        let yearly = parse_rule("FREQ=YEARLY;COUNT=2").unwrap();
        let got = expand(&yearly, wall("2026-10-20 12:00"), &Zone::Utc, utc("2030-01-01 00:00"));
        assert_eq!(got, [wall("2026-10-20 12:00"), wall("2027-10-20 12:00")]);
    }

    #[test]
    fn a_repeat_keeps_its_wall_clock_time_across_daylight_saving() {
        let rule = parse_rule("FREQ=WEEKLY").unwrap();
        let zone = zone_named("America/New_York").unwrap();
        let got: Vec<_> = expand(&rule, wall("2026-10-26 09:00"), &zone, utc("2026-11-10 00:00"))
            .into_iter()
            .map(|w| to_utc(&zone, w))
            .collect();
        assert_eq!(got, [utc("2026-10-26 13:00"), utc("2026-11-02 14:00"), utc("2026-11-09 14:00")]);
    }

    const FEED: &str = "BEGIN:VCALENDAR\r
X-WR-CALNAME:Work\r
BEGIN:VEVENT\r
UID:standup\r
SUMMARY:Standup\r
DTSTART;TZID=Europe/Berlin:20261019T093000\r
DTEND;TZID=Europe/Berlin:20261019T094500\r
RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR\r
EXDATE;TZID=Europe/Berlin:20261021T093000\r
LOCATION:https://meet.google.com/abc-defg-hij\r
BEGIN:VALARM\r
TRIGGER:-PT10M\r
END:VALARM\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:standup\r
RECURRENCE-ID;TZID=Europe/Berlin:20261022T093000\r
SUMMARY:Standup (moved)\r
DTSTART;TZID=Europe/Berlin:20261022T110000\r
DTEND;TZID=Europe/Berlin:20261022T111500\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:review\r
SUMMARY:Design review\r
DTSTART:20261020T130000Z\r
DTEND:20261020T140000Z\r
DESCRIPTION:Join Microsoft Teams Meeting\\n<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d>\\nOr call in\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:holiday\r
SUMMARY:Holiday\r
DTSTART;VALUE=DATE:20261020\r
DTEND;VALUE=DATE:20261021\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:gone\r
SUMMARY:Cancelled thing\r
STATUS:CANCELLED\r
DTSTART:20261020T150000Z\r
DTEND:20261020T160000Z\r
END:VEVENT\r
END:VCALENDAR\r
";

    #[test]
    fn a_feed_with_repeats_exceptions_moves_and_all_day_events() {
        let feed = parse_feed(FEED, "calendar.google.com");
        assert_eq!(feed.name, "Work");
        let all = feed.occurrences(utc("2026-10-19 00:00"), utc("2026-10-24 00:00"));
        let standups: Vec<_> = all.iter().filter(|o| o.uid == "standup").map(|o| (o.title.as_str(), o.start)).collect();
        assert_eq!(
            standups,
            [
                ("Standup", utc("2026-10-19 07:30")),
                ("Standup", utc("2026-10-20 07:30")),
                // the 21st is excluded; the 22nd's repeat is replaced by the moved one
                ("Standup", utc("2026-10-23 07:30")),
                ("Standup (moved)", utc("2026-10-22 09:00")),
            ]
        );
        assert!(all.iter().all(|o| o.uid != "holiday"), "all-day events are not meetings");
        assert!(all.iter().all(|o| o.uid != "gone"), "cancelled events are left out");
        let standup = all.iter().find(|o| o.title == "Standup").unwrap();
        assert_eq!(standup.link.as_deref(), Some("https://meet.google.com/abc-defg-hij"));
        assert_eq!(standup.end - standup.start, Duration::minutes(15));
        let review = all.iter().find(|o| o.uid == "review").unwrap();
        assert_eq!(
            review.link.as_deref(),
            Some("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d")
        );
        assert_eq!(review.calendar, "Work");
    }

    #[test]
    fn picking_the_next_meeting() {
        let feed = parse_feed(FEED, "x");
        let all = feed.occurrences(utc("2026-10-19 00:00"), utc("2026-10-24 00:00"));
        let (next, _) = pick(all.clone(), utc("2026-10-20 07:00"));
        assert_eq!(next.unwrap().title, "Standup");
        // During the standup it is still the one shown
        let (next, _) = pick(all.clone(), utc("2026-10-20 07:35"));
        assert_eq!(next.as_ref().unwrap().start, utc("2026-10-20 07:30"));
        // After it, the review
        let (next, _) = pick(all, utc("2026-10-20 08:00"));
        assert_eq!(next.unwrap().title, "Design review");
    }

    #[test]
    fn a_long_block_gives_way_to_a_call_inside_it() {
        let o = |uid: &str, s: &str, e: &str| Occurrence {
            uid: uid.into(),
            title: uid.into(),
            start: utc(s),
            end: utc(e),
            location: String::new(),
            link: None,
            calendar: String::new(),
        };
        let all = vec![o("block", "2026-10-20 12:00", "2026-10-20 17:00"), o("call", "2026-10-20 14:00", "2026-10-20 14:30")];
        assert_eq!(pick(all.clone(), utc("2026-10-20 12:05")).0.unwrap().uid, "block", "just started: still the block");
        assert_eq!(pick(all.clone(), utc("2026-10-20 13:30")).0.unwrap().uid, "call", "the call is within the hour");
        assert_eq!(pick(all, utc("2026-10-20 12:40")).0.unwrap().uid, "block", "the call is still over an hour off");
        assert_eq!(pick(Vec::new(), utc("2026-10-20 12:00")), (None, Vec::new()));
    }

    #[test]
    fn meeting_links_are_recognised_and_others_are_not() {
        let found = |t: &str| meeting_link(&[("DESCRIPTION", t)]);
        assert_eq!(found("Zoom: https://us02web.zoom.us/j/8123456789?pwd=abc."), Some("https://us02web.zoom.us/j/8123456789?pwd=abc".into()));
        assert_eq!(found("https://zoom.us/my/someone"), Some("https://zoom.us/my/someone".into()));
        assert_eq!(found("see https://zoom.us/pricing"), None);
        assert_eq!(found("(https://meet.google.com/xyz-abcd-efg)"), Some("https://meet.google.com/xyz-abcd-efg".into()));
        assert_eq!(found("https://company.webex.com/meet/jane"), Some("https://company.webex.com/meet/jane".into()));
        assert_eq!(found("https://teams.live.com/meet/9876"), Some("https://teams.live.com/meet/9876".into()));
        assert_eq!(found("https://www.gotomeet.me/acme"), None, "gotomeet.me only on its own host");
        assert_eq!(found("https://gotomeet.me/acme"), Some("https://gotomeet.me/acme".into()));
        assert_eq!(found("https://whereby.com/team-room"), Some("https://whereby.com/team-room".into()));
        assert_eq!(found("https://chime.aws/1234567890"), Some("https://chime.aws/1234567890".into()));
        assert_eq!(found("https://facetime.apple.com/join#v=1&p=abc"), Some("https://facetime.apple.com/join#v=1&p=abc".into()));
        assert_eq!(found("Agenda: https://docs.google.com/document/d/1"), None);
        assert_eq!(found("no links here"), None);
    }

    #[test]
    fn feed_addresses_are_cleaned() {
        assert_eq!(normalize_feed(" webcal://p01-calendars.icloud.com/x.ics "), Some("https://p01-calendars.icloud.com/x.ics".into()));
        assert_eq!(normalize_feed("https://calendar.google.com/calendar/ical/a/private-b/basic.ics"), Some("https://calendar.google.com/calendar/ical/a/private-b/basic.ics".into()));
        assert_eq!(normalize_feed("calendar.google.com/x"), None);
        assert_eq!(normalize_feed("https://a b"), None);
        assert_eq!(feed_host("https://outlook.office365.com/owa/calendar/x/calendar.ics"), "outlook.office365.com");
    }
}
