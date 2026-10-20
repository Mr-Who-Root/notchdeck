//! The deck: the cells NotchDeck carries after the usage rings — Now Playing (media.rs, with its
//! volume row in audio.rs), the clipboard history (clipboard.rs), a focus timer (the page's own, with
//! its cycles and record in focus_timer.rs), the Vault (vault.rs), the next meeting (meeting.rs), and
//! the downloads cell and charger cards of live status (live.rs). This module holds their switches:
//! Settings sets them, the notch draws whichever are on, and a watcher only runs while its cell is
//! shown.

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
    pub vault: bool,
    pub vault_clear_after: String,
    pub vault_keep_copies: bool,
    pub meeting: bool,
    /// How many calendar feeds there are — never the addresses, which are secret.
    pub meeting_feeds: usize,
    pub meeting_heads_up: u32,
    pub live_charging: bool,
    pub live_downloads: bool,
    pub timer_cycles: bool,
    pub timer_short_break: u32,
    pub timer_long_break: u32,
    pub timer_long_every: u32,
    pub timer_auto_start: bool,
    pub clipboard_plain: bool,
}

impl DeckPrefs {
    fn of(c: &config::Config) -> Self {
        Self {
            now_playing: c.deck_now_playing,
            clipboard: c.deck_clipboard,
            timer: c.deck_timer,
            clipboard_remember: c.clipboard_remember,
            timer_minutes: c.timer_minutes,
            vault: c.deck_vault,
            vault_clear_after: c.vault_clear_after.clone(),
            vault_keep_copies: c.vault_keep_copies,
            meeting: c.deck_meeting,
            meeting_feeds: c.meeting_feeds.len(),
            meeting_heads_up: c.meeting_heads_up,
            live_charging: c.live_charging,
            live_downloads: c.live_downloads,
            timer_cycles: c.timer_cycles,
            timer_short_break: c.timer_short_break,
            timer_long_break: c.timer_long_break,
            timer_long_every: c.timer_long_every,
            timer_auto_start: c.timer_auto_start,
            clipboard_plain: c.clipboard_plain,
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
    crate::audio::set_enabled(app, p.now_playing);
    crate::clipboard::set_enabled(p.clipboard);
    crate::clipboard::set_remember(p.clipboard_remember);
    crate::clipboard::set_plain(p.clipboard_plain);
    crate::vault::set_enabled(p.vault);
    crate::vault::set_keep_copies(p.vault_keep_copies);
    crate::vault::set_clear_after(&p.vault_clear_after);
    crate::meeting::set_enabled(p.meeting);
    crate::meeting::set_heads_up(p.meeting_heads_up);
    crate::live::set_charging(p.live_charging);
    crate::live::set_downloads(app, p.live_downloads);
    let _ = app.emit("deck", &p);
    p
}

#[tauri::command]
pub fn get_deck(app: AppHandle) -> DeckPrefs {
    prefs(&app)
}

/// Sets one switch on a config. False for a key that is not one.
pub fn set_switch(c: &mut config::Config, key: &str, on: bool) -> bool {
    match key {
        "now_playing" => c.deck_now_playing = on,
        "clipboard" => c.deck_clipboard = on,
        "timer" => c.deck_timer = on,
        "clipboard_remember" => c.clipboard_remember = on,
        "vault" => c.deck_vault = on,
        "vault_keep_copies" => c.vault_keep_copies = on,
        "meeting" => c.deck_meeting = on,
        "live_charging" => c.live_charging = on,
        "live_downloads" => c.live_downloads = on,
        "timer_cycles" => c.timer_cycles = on,
        "timer_auto_start" => c.timer_auto_start = on,
        "clipboard_plain" => c.clipboard_plain = on,
        _ => return false,
    }
    true
}

/// Sets one of the deck's choices that is not a switch, kept to the values Settings offers.
pub fn set_choice(c: &mut config::Config, key: &str, value: &str) -> Result<(), String> {
    let number = || value.trim().parse::<u32>().map_err(|_| format!("{value} is not a number"));
    match key {
        "vault_clear_after" => c.vault_clear_after = config::vault_clear_or_never(value),
        "meeting_heads_up" => c.meeting_heads_up = config::heads_up_or_default(number()?),
        "timer_short_break" => c.timer_short_break = number()?.clamp(1, 60),
        "timer_long_break" => c.timer_long_break = number()?.clamp(1, 90),
        "timer_long_every" => c.timer_long_every = number()?.clamp(2, 12),
        _ => return Err(format!("unknown deck choice {key}")),
    }
    Ok(())
}

/// One switch: any key `set_switch` knows.
#[tauri::command]
pub fn set_deck(app: AppHandle, key: String, on: bool) -> Result<DeckPrefs, String> {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if !set_switch(&mut c, &key, on) {
            return Err(format!("unknown deck switch {key}"));
        }
        config::save(&c);
    }
    Ok(apply(&app))
}

/// One choice: the Vault's "Clear items after", the meeting heads-up, the break lengths.
#[tauri::command]
pub fn set_deck_choice(app: AppHandle, key: String, value: String) -> Result<DeckPrefs, String> {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        set_choice(&mut c, &key, &value)?;
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
    crate::audio::start(app.clone());
    crate::clipboard::start(app.clone());
    crate::vault::start(app.clone());
    crate::meeting::start(app.clone());
    crate::live::start(app.clone());
    apply(&app);
}

#[cfg(test)]
mod tests {
    use super::{clamp_minutes, set_choice, set_switch, DeckPrefs};
    use crate::config::Config;

    #[test]
    fn every_tool_is_on_for_a_fresh_install() {
        let p = DeckPrefs::of(&Config::default());
        assert!(p.now_playing && p.clipboard && p.timer && p.clipboard_remember);
        assert!(p.vault && p.meeting && p.live_charging && p.live_downloads);
        assert!(!p.timer_cycles && p.timer_auto_start && !p.clipboard_plain && !p.vault_keep_copies);
        assert_eq!(p.timer_minutes, 25);
        assert_eq!((p.timer_short_break, p.timer_long_break, p.timer_long_every), (5, 15, 4));
        assert_eq!(p.vault_clear_after, "never");
        assert_eq!(p.meeting_heads_up, 5);
        assert_eq!(p.meeting_feeds, 0);
    }

    #[test]
    fn an_old_config_gains_the_deck_switched_on() {
        let c: Config = serde_json::from_str(r#"{"notch_visible":true}"#).unwrap();
        let p = DeckPrefs::of(&c);
        assert!(p.now_playing && p.clipboard && p.timer);
        assert!(p.vault && p.meeting && p.live_charging && p.live_downloads, "the new cells too");
    }

    #[test]
    fn timer_lengths_are_clamped() {
        assert_eq!(clamp_minutes(0), 1);
        assert_eq!(clamp_minutes(25), 25);
        assert_eq!(clamp_minutes(1_000), 180);
    }

    #[test]
    fn switches_and_choices_land_where_they_belong() {
        let mut c = Config::default();
        assert!(set_switch(&mut c, "vault", false));
        assert!(!c.deck_vault);
        assert!(set_switch(&mut c, "timer_cycles", true));
        assert!(c.timer_cycles);
        assert!(!set_switch(&mut c, "nonsense", true));
        set_choice(&mut c, "vault_clear_after", "1d").unwrap();
        assert_eq!(c.vault_clear_after, "1d");
        set_choice(&mut c, "vault_clear_after", "forever").unwrap();
        assert_eq!(c.vault_clear_after, "never", "an unknown choice keeps items");
        set_choice(&mut c, "meeting_heads_up", "10").unwrap();
        assert_eq!(c.meeting_heads_up, 10);
        set_choice(&mut c, "meeting_heads_up", "7").unwrap();
        assert_eq!(c.meeting_heads_up, 5, "only the offered lead times");
        set_choice(&mut c, "timer_long_every", "1").unwrap();
        assert_eq!(c.timer_long_every, 2);
        assert!(set_choice(&mut c, "timer_short_break", "abc").is_err());
        assert!(set_choice(&mut c, "nope", "1").is_err());
    }
}
