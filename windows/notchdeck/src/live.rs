//! Live status — the Mac's `LiveActivityMonitor`: the notch peeks with a short card when the charger
//! goes in or out, and a cell of its own appears while something downloads.
//!
//! The charger is read with GetSystemPowerStatus every two seconds; only a change is news, so nothing
//! shows at startup or on a desktop without a battery. Downloads are watched in the user's Downloads
//! folder: a browser writes a download under a temporary name (.crdownload for Chrome and Edge, .part
//! for Firefox, .partial for old Edge) and renames it when it is done. That gives what is in progress
//! and how fast it is growing, but never how big it will be, so the cell's ring turns rather than
//! fills. When a temporary file gives way to its finished name, the notch peeks with it.

use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};

/// What the battery says.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Power {
    pub has_battery: bool,
    pub on_ac: bool,
    pub percent: Option<u8>,
    /// Seconds of battery left, when Windows has an estimate.
    pub secs_left: Option<u32>,
}

/// A card the notch peeks with.
#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct LiveCard {
    /// "charging", "battery" or "downloaded".
    pub kind: String,
    pub title: String,
    pub detail: String,
    pub percent: Option<u8>,
    /// The finished download, for Open and Show in Explorer.
    pub path: Option<String>,
}

pub fn time_left_text(secs: u32) -> String {
    let minutes = secs / 60;
    match (minutes / 60, minutes % 60) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}

/// The card for the charger going in or out — only when it did, and only with a battery to speak of.
pub fn power_card(before: Option<Power>, now: Power) -> Option<LiveCard> {
    let before = before?;
    if !now.has_battery || before.on_ac == now.on_ac {
        return None;
    }
    let pct = now.percent.map(|p| format!(" \u{b7} {p}%")).unwrap_or_default();
    Some(if now.on_ac {
        LiveCard {
            kind: "charging".into(),
            title: format!("Charging{pct}"),
            detail: if now.percent == Some(100) { "Fully charged".into() } else { String::new() },
            percent: now.percent,
            path: None,
        }
    } else {
        LiveCard {
            kind: "battery".into(),
            title: format!("On battery{pct}"),
            detail: now.secs_left.map(|s| format!("{} left", time_left_text(s))).unwrap_or_default(),
            percent: now.percent,
            path: None,
        }
    })
}

/// The finished name of a download still being written, or None for an ordinary file.
pub fn download_target(name: &str) -> Option<String> {
    let lower = name.to_ascii_lowercase();
    for ext in [".crdownload", ".partial", ".part", ".download", ".opdownload"] {
        if lower.ends_with(ext) && lower.len() > ext.len() {
            return Some(name[..name.len() - ext.len()].to_string());
        }
    }
    None
}

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct Transfer {
    /// The name it will have.
    pub name: String,
    pub bytes: u64,
    /// Bytes a second over the last few seconds.
    pub speed: u64,
}

/// "12 MB", "640 KB", "1.4 GB".
pub fn size_text(bytes: u64) -> String {
    const K: f64 = 1000.0;
    let b = bytes as f64;
    if b < K {
        format!("{bytes} B")
    } else if b < K * K {
        format!("{:.0} KB", b / K)
    } else if b < K * K * K {
        let mb = b / (K * K);
        if mb < 10.0 {
            format!("{mb:.1} MB")
        } else {
            format!("{mb:.0} MB")
        }
    } else {
        format!("{:.1} GB", b / (K * K * K))
    }
}

struct Track {
    bytes: u64,
    samples: Vec<(Instant, u64)>,
}

/// Follows the temporary files in one folder from one look to the next.
#[derive(Default)]
pub struct Watch {
    tracks: HashMap<String, Track>,
}

impl Watch {
    /// One look at the folder: `temp` is what is being written now (file name → bytes), `exists` says
    /// whether a finished name is there. Returns the transfers and the downloads that just finished.
    pub fn step(&mut self, temp: &HashMap<String, u64>, now: Instant, exists: impl Fn(&str) -> bool) -> (Vec<Transfer>, Vec<String>) {
        let mut finished = Vec::new();
        let gone: Vec<String> = self.tracks.keys().filter(|k| !temp.contains_key(*k)).cloned().collect();
        for name in gone {
            self.tracks.remove(&name);
            if let Some(target) = download_target(&name) {
                if exists(&target) {
                    finished.push(target);
                }
            }
        }
        for (name, bytes) in temp {
            let t = self.tracks.entry(name.clone()).or_insert_with(|| Track { bytes: *bytes, samples: Vec::new() });
            t.bytes = *bytes;
            t.samples.push((now, *bytes));
            t.samples.retain(|(at, _)| now.duration_since(*at) <= Duration::from_secs(4));
        }
        let mut list: Vec<Transfer> = self
            .tracks
            .iter()
            .map(|(name, t)| {
                let speed = match (t.samples.first(), t.samples.last()) {
                    (Some((a, x)), Some((b, y))) if b > a && y >= x => {
                        ((y - x) as f64 / b.duration_since(*a).as_secs_f64()) as u64
                    }
                    _ => 0,
                };
                Transfer { name: download_target(name).unwrap_or_else(|| name.clone()), bytes: t.bytes, speed }
            })
            .collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        (list, finished)
    }
}

static CHARGING: AtomicBool = AtomicBool::new(false);
static DOWNLOADS: AtomicBool = AtomicBool::new(false);
static TRANSFERS: Mutex<Vec<Transfer>> = Mutex::new(Vec::new());
/// Downloads the notch has been told about, which are the only files Open may open.
static FINISHED: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);

pub fn set_charging(on: bool) {
    CHARGING.store(on, Ordering::SeqCst);
}

pub fn set_downloads(app: &AppHandle, on: bool) {
    let was = DOWNLOADS.swap(on, Ordering::SeqCst);
    if was && !on {
        TRANSFERS.lock().unwrap_or_else(|e| e.into_inner()).clear();
        let _ = app.emit("transfers", Vec::<Transfer>::new());
    }
}

#[tauri::command]
pub fn get_transfers() -> Vec<Transfer> {
    TRANSFERS.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

fn announced(path: &str) -> bool {
    FINISHED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_some_and(|s| s.contains(Path::new(path)))
}

/// Opens a download the notch announced — nothing else.
#[tauri::command]
pub fn live_open(path: String) -> Result<(), String> {
    if !announced(&path) {
        return Err("not a download NotchDeck saw finish".into());
    }
    crate::shell::open(&path);
    Ok(())
}

#[tauri::command]
pub fn live_reveal(path: String) -> Result<(), String> {
    if !announced(&path) {
        return Err("not a download NotchDeck saw finish".into());
    }
    crate::shell::reveal(&path);
    Ok(())
}

fn read_temp(dir: &Path) -> HashMap<String, u64> {
    let mut out = HashMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return out };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if download_target(&name).is_none() {
            continue;
        }
        if let Ok(meta) = e.metadata() {
            if meta.is_file() {
                out.insert(name, meta.len());
            }
        }
    }
    out
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let mut before: Option<Power> = None;
        let mut watch = Watch::default();
        let mut tick = 0u64;
        let dir = dirs::download_dir();
        loop {
            std::thread::sleep(Duration::from_secs(1));
            tick += 1;
            if tick % 2 == 0 {
                match platform::power() {
                    Some(now) => {
                        if CHARGING.load(Ordering::SeqCst) {
                            if let Some(card) = power_card(before, now) {
                                let _ = app.emit("live", &card);
                            }
                        }
                        before = Some(now);
                    }
                    None => before = None,
                }
            }
            if !DOWNLOADS.load(Ordering::SeqCst) {
                continue;
            }
            let Some(dir) = dir.as_ref() else { continue };
            let temp = read_temp(dir);
            let (list, finished) = watch.step(&temp, Instant::now(), |name| dir.join(name).exists());
            for name in finished {
                let path = dir.join(&name);
                FINISHED
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get_or_insert_with(HashSet::new)
                    .insert(path.clone());
                let _ = app.emit(
                    "live",
                    LiveCard {
                        kind: "downloaded".into(),
                        title: "Downloaded".into(),
                        detail: name.clone(),
                        percent: None,
                        path: Some(path.to_string_lossy().to_string()),
                    },
                );
            }
            let changed = {
                let mut current = TRANSFERS.lock().unwrap_or_else(|e| e.into_inner());
                let changed = *current != list;
                *current = list.clone();
                changed
            };
            if changed {
                let _ = app.emit("transfers", &list);
            }
        }
    });
}

#[cfg(windows)]
mod platform {
    use super::Power;
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    pub fn power() -> Option<Power> {
        let mut s = SYSTEM_POWER_STATUS::default();
        unsafe { GetSystemPowerStatus(&mut s) }.ok()?;
        if s.ACLineStatus == 255 {
            return None;
        }
        // 128 = no system battery, 255 = unknown
        let has_battery = s.BatteryFlag != 128 && s.BatteryFlag != 255;
        Some(Power {
            has_battery,
            on_ac: s.ACLineStatus == 1,
            percent: (s.BatteryLifePercent <= 100).then_some(s.BatteryLifePercent),
            secs_left: (s.BatteryLifeTime != u32::MAX && s.BatteryLifeTime > 0).then_some(s.BatteryLifeTime),
        })
    }
}

/// Elsewhere there is no battery to read: no charging cards.
#[cfg(not(windows))]
mod platform {
    pub fn power() -> Option<super::Power> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn power(on_ac: bool, percent: u8) -> Power {
        Power { has_battery: true, on_ac, percent: Some(percent), secs_left: None }
    }

    #[test]
    fn only_the_charger_changing_is_news() {
        assert_eq!(power_card(None, power(true, 50)), None, "nothing at startup");
        assert_eq!(power_card(Some(power(true, 50)), power(true, 51)), None);
        let c = power_card(Some(power(false, 76)), power(true, 76)).unwrap();
        assert_eq!((c.kind.as_str(), c.title.as_str()), ("charging", "Charging \u{b7} 76%"));
        let mut off = power(false, 76);
        off.secs_left = Some(5 * 3600 + 20 * 60);
        let c = power_card(Some(power(true, 76)), off).unwrap();
        assert_eq!(c.title, "On battery \u{b7} 76%");
        assert_eq!(c.detail, "5 h 20 min left");
        let desktop = Power { has_battery: false, ..power(true, 0) };
        assert_eq!(power_card(Some(Power { on_ac: false, ..desktop }), desktop), None, "no battery, no card");
    }

    #[test]
    fn temporary_download_names() {
        assert_eq!(download_target("report.pdf.crdownload").as_deref(), Some("report.pdf"));
        assert_eq!(download_target("Unconfirmed 123456.crdownload").as_deref(), Some("Unconfirmed 123456"));
        assert_eq!(download_target("setup.exe.part").as_deref(), Some("setup.exe"));
        assert_eq!(download_target("movie.mkv.PARTIAL").as_deref(), Some("movie.mkv"));
        assert_eq!(download_target("notes.txt"), None);
        assert_eq!(download_target(".part"), None);
    }

    #[test]
    fn a_download_is_followed_to_its_finished_name() {
        let mut w = Watch::default();
        let t0 = Instant::now();
        let mut temp = HashMap::new();
        temp.insert("big.iso.crdownload".to_string(), 1_000_000u64);
        let (list, done) = w.step(&temp, t0, |_| false);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "big.iso");
        assert!(done.is_empty());
        temp.insert("big.iso.crdownload".to_string(), 3_000_000);
        let (list, _) = w.step(&temp, t0 + Duration::from_secs(2), |_| false);
        assert_eq!(list[0].speed, 1_000_000, "two megabytes in two seconds");
        // Renamed: finished
        let (list, done) = w.step(&HashMap::new(), t0 + Duration::from_secs(3), |n| n == "big.iso");
        assert!(list.is_empty());
        assert_eq!(done, ["big.iso"]);
        // Cancelled: the temporary file goes and nothing takes its place
        let mut temp = HashMap::new();
        temp.insert("x.zip.part".to_string(), 10u64);
        w.step(&temp, t0, |_| false);
        let (_, done) = w.step(&HashMap::new(), t0, |_| false);
        assert!(done.is_empty());
    }

    #[test]
    fn sizes_and_times_read_naturally() {
        assert_eq!(size_text(512), "512 B");
        assert_eq!(size_text(640_000), "640 KB");
        assert_eq!(size_text(2_400_000), "2.4 MB");
        assert_eq!(size_text(12_000_000), "12 MB");
        assert_eq!(size_text(1_400_000_000), "1.4 GB");
        assert_eq!(time_left_text(45 * 60), "45 min");
        assert_eq!(time_left_text(2 * 3600), "2 h");
    }
}
