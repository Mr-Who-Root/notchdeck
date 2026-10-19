//! Now Playing: what Windows' media sessions say is playing — Spotify, a browser tab, Media Player,
//! anything that shows in the volume flyout — and the transport controls for it, as the Mac's
//! `NowPlayingMonitor` gives the notch.
//!
//! Read on a thread of its own once a second while the deck's Now Playing cell is switched on, and
//! broadcast as `media` only when something changed. Where playback is between reports the page
//! works out from `position_ms`, `updated_ms` and `playing`, so a playing track does not cost an
//! event a second. The artwork is fetched once per track and kept here; the page asks for it with
//! `get_media_art` when `art_key` changes.

use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize, Default, PartialEq, Debug)]
pub struct MediaState {
    /// false = nothing is playing, or nothing has said so.
    pub present: bool,
    pub title: String,
    pub artist: String,
    pub album: String,
    /// The playing app, as a person would name it: "Spotify", "Chrome".
    pub app: String,
    pub playing: bool,
    /// Where playback was at `updated_ms`, and how long the item is (0 = not known).
    pub position_ms: i64,
    pub duration_ms: i64,
    /// Unix milliseconds of the position reading.
    pub updated_ms: i64,
    pub can_toggle: bool,
    pub can_next: bool,
    pub can_previous: bool,
    pub can_seek: bool,
    /// Changes whenever the artwork does; 0 = there is none.
    pub art_key: u64,
}

impl MediaState {
    /// Whether `next` is worth telling the page about: anything but the position moving on as
    /// expected while it plays.
    fn differs_meaningfully(&self, next: &MediaState, now_ms: i64) -> bool {
        let mut a = self.clone();
        let mut b = next.clone();
        let expected = a.position_ms + if a.playing { now_ms - a.updated_ms } else { 0 };
        let drift = (expected - b.position_ms).abs();
        a.position_ms = 0;
        a.updated_ms = 0;
        b.position_ms = 0;
        b.updated_ms = 0;
        a != b || drift > 2_000
    }
}

static ENABLED: AtomicBool = AtomicBool::new(false);
static STATE: Mutex<Option<MediaState>> = Mutex::new(None);
static ART: Mutex<Option<String>> = Mutex::new(None);

pub fn set_enabled(app: &AppHandle, on: bool) {
    let was = ENABLED.swap(on, Ordering::SeqCst);
    if was && !on {
        *STATE.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *ART.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let _ = app.emit("media", MediaState::default());
    }
}

#[tauri::command]
pub fn get_media() -> MediaState {
    STATE.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or_default()
}

/// The current artwork as a data: URL, or nothing.
#[tauri::command]
pub fn get_media_art() -> Option<String> {
    ART.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// `toggle`, `next` or `previous`. Returns at once; the next reading reports what happened.
#[tauri::command]
pub fn media_control(action: String) -> Result<(), String> {
    if !matches!(action.as_str(), "toggle" | "next" | "previous") {
        return Err(format!("unknown media action {action}"));
    }
    std::thread::spawn(move || {
        if let Err(e) = platform::control(&action) {
            crate::applog(&format!("media: {action} failed ({e})"));
        }
        poke();
    });
    Ok(())
}

#[tauri::command]
pub fn media_seek(position_ms: i64) -> Result<(), String> {
    if position_ms < 0 {
        return Err("negative position".into());
    }
    std::thread::spawn(move || {
        if let Err(e) = platform::seek(position_ms) {
            crate::applog(&format!("media: seek failed ({e})"));
        }
        poke();
    });
    Ok(())
}

static POKED: AtomicBool = AtomicBool::new(false);

/// Read again now rather than at the next second: a button was pressed.
fn poke() {
    POKED.store(true, Ordering::SeqCst);
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// "Spotify.exe" → "Spotify"; "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic" → "Media Player".
pub fn app_name(aumid: &str) -> String {
    let tail = aumid.rsplit('!').next().unwrap_or(aumid);
    let tail = tail.rsplit(['\\', '/']).next().unwrap_or(tail);
    let stem = tail.strip_suffix(".exe").or_else(|| tail.strip_suffix(".EXE")).unwrap_or(tail);
    let lower = stem.to_ascii_lowercase();
    let known = [
        ("chrome", "Chrome"),
        ("msedge", "Edge"),
        ("firefox", "Firefox"),
        ("brave", "Brave"),
        ("opera", "Opera"),
        ("spotify", "Spotify"),
        ("zunemusic", "Media Player"),
        ("mediaplayer", "Media Player"),
        ("vlc", "VLC"),
        ("itunes", "iTunes"),
        ("applemusic", "Apple Music"),
    ];
    for (needle, name) in known {
        if lower.contains(needle) {
            return name.to_string();
        }
    }
    let last = stem.rsplit('.').next().unwrap_or(stem);
    let mut chars = last.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        let mut last_track = String::new();
        let mut art_key = 0u64;
        loop {
            let poked = POKED.swap(false, Ordering::SeqCst);
            if ENABLED.load(Ordering::SeqCst) {
                let mut next = platform::read().unwrap_or_default();
                let track = format!("{}\u{1f}{}\u{1f}{}\u{1f}{}", next.title, next.artist, next.album, next.app);
                if next.present && track != last_track {
                    last_track = track;
                    let art = platform::artwork().ok().flatten();
                    art_key = if art.is_some() { art_key.wrapping_add(1).max(1) } else { 0 };
                    *ART.lock().unwrap_or_else(|e| e.into_inner()) = art;
                } else if !next.present {
                    last_track.clear();
                    art_key = 0;
                    *ART.lock().unwrap_or_else(|e| e.into_inner()) = None;
                }
                next.art_key = art_key;
                let changed = {
                    let mut current = STATE.lock().unwrap_or_else(|e| e.into_inner());
                    let changed = current
                        .as_ref()
                        .is_none_or(|c| c.differs_meaningfully(&next, now_ms()));
                    if changed {
                        *current = Some(next.clone());
                    }
                    changed
                };
                if changed {
                    let _ = app.emit("media", &next);
                }
            }
            // A press is answered within a quarter of a second, the rest of the time once a second.
            for _ in 0..4 {
                std::thread::sleep(Duration::from_millis(if poked { 150 } else { 250 }));
                if POKED.load(Ordering::SeqCst) {
                    break;
                }
            }
        }
    });
}

#[cfg(windows)]
mod platform {
    use super::{app_name, MediaState};
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Storage::Streams::DataReader;

    /// 100 ns ticks between 1601-01-01 and 1970-01-01.
    const EPOCH_TICKS: i64 = 116_444_736_000_000_000;

    fn session() -> windows::core::Result<Session> {
        Manager::RequestAsync()?.get()?.GetCurrentSession()
    }

    pub fn read() -> windows::core::Result<MediaState> {
        let session = match session() {
            Ok(s) => s,
            Err(_) => return Ok(MediaState::default()),
        };
        let props = session.TryGetMediaPropertiesAsync()?.get()?;
        let info = session.GetPlaybackInfo()?;
        let controls = info.Controls()?;
        let timeline = session.GetTimelineProperties()?;
        let title = props.Title().map(|s| s.to_string()).unwrap_or_default();
        let artist = props.Artist().map(|s| s.to_string()).unwrap_or_default();
        let album = props.AlbumTitle().map(|s| s.to_string()).unwrap_or_default();
        let status = info.PlaybackStatus()?;
        let start = timeline.StartTime().map(|t| t.Duration).unwrap_or(0);
        let end = timeline.EndTime().map(|t| t.Duration).unwrap_or(0);
        let position = timeline.Position().map(|t| t.Duration).unwrap_or(0);
        let updated = timeline
            .LastUpdatedTime()
            .map(|t| (t.UniversalTime - EPOCH_TICKS) / 10_000)
            .unwrap_or_else(|_| super::now_ms());
        let duration_ms = ((end - start) / 10_000).max(0);
        Ok(MediaState {
            present: !title.is_empty() || !artist.is_empty(),
            title,
            artist,
            album,
            app: session
                .SourceAppUserModelId()
                .map(|s| app_name(&s.to_string()))
                .unwrap_or_default(),
            playing: status == Status::Playing,
            position_ms: ((position - start) / 10_000).max(0),
            duration_ms,
            updated_ms: if updated > 0 { updated } else { super::now_ms() },
            can_toggle: controls.IsPlayPauseToggleEnabled().unwrap_or(false)
                || controls.IsPlayEnabled().unwrap_or(false)
                || controls.IsPauseEnabled().unwrap_or(false),
            can_next: controls.IsNextEnabled().unwrap_or(false),
            can_previous: controls.IsPreviousEnabled().unwrap_or(false),
            can_seek: controls.IsPlaybackPositionEnabled().unwrap_or(false) && duration_ms > 0,
            art_key: 0,
        })
    }

    /// The thumbnail the session publishes, as a data: URL. Capped at 2 MB.
    pub fn artwork() -> windows::core::Result<Option<String>> {
        use base64::Engine as _;
        let session = match session() {
            Ok(s) => s,
            Err(_) => return Ok(None),
        };
        let Ok(thumb) = session.TryGetMediaPropertiesAsync()?.get()?.Thumbnail() else {
            return Ok(None);
        };
        let stream = thumb.OpenReadAsync()?.get()?;
        let size = stream.Size()?;
        if size == 0 || size > 2 * 1024 * 1024 {
            return Ok(None);
        }
        let mime = stream.ContentType().map(|s| s.to_string()).unwrap_or_default();
        let reader = DataReader::CreateDataReader(&stream)?;
        let loaded = reader.LoadAsync(size as u32)?.get()?;
        let mut bytes = vec![0u8; loaded as usize];
        reader.ReadBytes(&mut bytes)?;
        let mime = if mime.starts_with("image/") { mime } else { "image/png".to_string() };
        Ok(Some(format!(
            "data:{mime};base64,{}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        )))
    }

    pub fn control(action: &str) -> windows::core::Result<()> {
        let session = session()?;
        let _ = match action {
            "toggle" => session.TryTogglePlayPauseAsync()?.get()?,
            "next" => session.TrySkipNextAsync()?.get()?,
            "previous" => session.TrySkipPreviousAsync()?.get()?,
            _ => false,
        };
        Ok(())
    }

    pub fn seek(position_ms: i64) -> windows::core::Result<()> {
        let session = session()?;
        let start = session.GetTimelineProperties()?.StartTime().map(|t| t.Duration).unwrap_or(0);
        session.TryChangePlaybackPositionAsync(start + position_ms * 10_000)?.get()?;
        Ok(())
    }
}

/// Elsewhere (the Linux build CI runs) there are no media sessions to read: the cell says nothing
/// is playing.
#[cfg(not(windows))]
mod platform {
    use super::MediaState;

    pub fn read() -> Result<MediaState, String> {
        Ok(MediaState::default())
    }
    pub fn artwork() -> Result<Option<String>, String> {
        Ok(None)
    }
    pub fn control(_action: &str) -> Result<(), String> {
        Ok(())
    }
    pub fn seek(_position_ms: i64) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{app_name, MediaState};

    #[test]
    fn names_the_playing_app_as_a_person_would() {
        assert_eq!(app_name("Spotify.exe"), "Spotify");
        assert_eq!(app_name("chrome"), "Chrome");
        assert_eq!(app_name("MSEdge"), "Edge");
        assert_eq!(app_name("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"), "Media Player");
        assert_eq!(app_name("C:\\Apps\\foobar2000.exe"), "Foobar2000");
        assert_eq!(app_name(""), "");
    }

    #[test]
    fn a_track_playing_on_as_expected_is_not_news() {
        let playing = MediaState {
            present: true,
            title: "Song".into(),
            playing: true,
            position_ms: 10_000,
            duration_ms: 200_000,
            updated_ms: 1_000_000,
            ..Default::default()
        };
        let later = MediaState { position_ms: 15_000, updated_ms: 1_005_000, ..playing.clone() };
        assert!(!playing.differs_meaningfully(&later, 1_005_000));
        let seeked = MediaState { position_ms: 90_000, updated_ms: 1_005_000, ..playing.clone() };
        assert!(playing.differs_meaningfully(&seeked, 1_005_000));
        let paused = MediaState { playing: false, ..later.clone() };
        assert!(playing.differs_meaningfully(&paused, 1_005_000));
        let next = MediaState { title: "Other".into(), ..later };
        assert!(playing.differs_meaningfully(&next, 1_005_000));
    }
}
