//! The deck: the cells NotchDeck carries after the usage rings — Now Playing (media.rs), the
//! clipboard history (clipboard.rs) and a focus timer, which lives in the page itself. This module
//! holds their switches: Settings sets them, the notch draws whichever are on, and a watcher only
//! runs while its cell is shown.

use crate::{config, AppState};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct DeckPrefs {
    pub now_playing: bool,
    pub clipboard: bool,
    pub timer: bool,
    pub clipboard_remember: bool,
    pub timer_minutes: u32,
}

impl DeckPrefs {
    fn of(c: &config::Config) -> Self {
        Self {
            now_playing: c.deck_now_playing,
            clipboard: c.deck_clipboard,
            timer: c.deck_timer,
            clipboard_remember: c.clipboard_remember,
            timer_minutes: c.timer_minutes,
        }
    }
}

/// The timer's length, kept to what the card can show.
pub fn clamp_minutes(minutes: u32) -> u32 {
    minutes.clamp(1, 180)
}

fn prefs(app: &AppHandle) -> DeckPrefs {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    DeckPrefs::of(&c)
}

/// Starts or stops each watcher to match the switches, and tells every window.
fn apply(app: &AppHandle) -> DeckPrefs {
    let p = prefs(app);
    crate::media::set_enabled(app, p.now_playing);
    crate::clipboard::set_enabled(p.clipboard);
    crate::clipboard::set_remember(p.clipboard_remember);
    let _ = app.emit("deck", &p);
    p
}

#[tauri::command]
pub fn get_deck(app: AppHandle) -> DeckPrefs {
    prefs(&app)
}

/// One switch: `now_playing`, `clipboard`, `timer` or `clipboard_remember`.
#[tauri::command]
pub fn set_deck(app: AppHandle, key: String, on: bool) -> Result<DeckPrefs, String> {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        match key.as_str() {
            "now_playing" => c.deck_now_playing = on,
            "clipboard" => c.deck_clipboard = on,
            "timer" => c.deck_timer = on,
            "clipboard_remember" => c.clipboard_remember = on,
            _ => return Err(format!("unknown deck switch {key}")),
        }
        config::save(&c);
    }
    Ok(apply(&app))
}

#[tauri::command]
pub fn set_timer_minutes(app: AppHandle, minutes: u32) -> DeckPrefs {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.timer_minutes = clamp_minutes(minutes);
        config::save(&c);
    }
    apply(&app)
}

/// The timer ran out: a sound, since the page cannot count on being allowed one.
#[tauri::command]
pub fn timer_finished() {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::System::Diagnostics::Debug::MessageBeep;
        use windows::Win32::UI::WindowsAndMessaging::MB_ICONASTERISK;
        let _ = MessageBeep(MB_ICONASTERISK);
    }
}

pub fn start(app: AppHandle) {
    crate::media::start(app.clone());
    crate::clipboard::start(app.clone());
    apply(&app);
}

#[cfg(test)]
mod tests {
    use super::{clamp_minutes, DeckPrefs};
    use crate::config::Config;

    #[test]
    fn every_tool_is_on_for_a_fresh_install() {
        let p = DeckPrefs::of(&Config::default());
        assert!(p.now_playing && p.clipboard && p.timer && p.clipboard_remember);
        assert_eq!(p.timer_minutes, 25);
    }

    #[test]
    fn an_old_config_gains_the_deck_switched_on() {
        let c: Config = serde_json::from_str(r#"{"notch_visible":true}"#).unwrap();
        let p = DeckPrefs::of(&c);
        assert!(p.now_playing && p.clipboard && p.timer);
    }

    #[test]
    fn timer_lengths_are_clamped() {
        assert_eq!(clamp_minutes(0), 1);
        assert_eq!(clamp_minutes(25), 25);
        assert_eq!(clamp_minutes(1_000), 180);
    }
}
