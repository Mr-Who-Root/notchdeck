//! Clipboard history: what was copied, most recent first, ready to be put back with a click — the
//! Mac's `ClipboardMonitor` for Windows.
//!
//! Windows numbers every clipboard change, so the sequence number is polled a few times a second and
//! the clipboard is only opened when it moved. Text and copied files are kept. Anything an app marks
//! as not for clipboard monitors or history — `ExcludeClipboardContentFromMonitorProcessing`, or
//! `CanIncludeInClipboardHistory` set to 0, which password managers set — is never recorded, nor is
//! anything copied while a password manager is in front. With `clipboard_remember` on, the history is
//! kept in `clipboard-history.json` beside the config, readable by this user only.

use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

/// Clips kept, pinned ones aside.
pub const LIMIT: usize = 50;
/// Longest text kept, so a log copied by accident does not sit in memory and on disk forever.
pub const MAX_TEXT: usize = 100_000;

#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum ClipKind {
    Text,
    Link,
    Files,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct Clip {
    pub id: u64,
    pub kind: ClipKind,
    /// The text itself, or the files' paths one per line.
    pub text: String,
    #[serde(default)]
    pub pinned: bool,
    /// Unix milliseconds.
    pub at: i64,
}

/// A clip as the notch draws it: one line, and the rest for the preview shown while the pointer
/// is on a clip its row cuts short.
#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct ClipView {
    pub id: u64,
    pub kind: ClipKind,
    pub preview: String,
    /// The clip itself, up to `DETAIL_CHARS` of it.
    pub detail: String,
    /// The whole clip's length and line count, which the preview names.
    pub chars: usize,
    pub lines: usize,
    pub pinned: bool,
    pub at: i64,
}

/// How much of a clip the preview carries: far more than it can show, so it is never short, and
/// little enough that a history of long clips stays a small message.
pub const DETAIL_CHARS: usize = 2_000;

#[derive(Default)]
pub struct History {
    clips: Vec<Clip>,
    next_id: u64,
}

impl History {
    pub fn from_saved(clips: Vec<Clip>) -> Self {
        let next_id = clips.iter().map(|c| c.id).max().unwrap_or(0) + 1;
        Self { clips, next_id }
    }

    /// A new clip goes to the top; the same thing copied again moves up rather than appearing
    /// twice, and keeps its pin.
    pub fn record(&mut self, kind: ClipKind, text: String, at: i64) {
        let text: String = text.chars().take(MAX_TEXT).collect();
        let mut pinned = false;
        let mut id = None;
        if let Some(i) = self.clips.iter().position(|c| c.kind == kind && c.text == text) {
            let old = self.clips.remove(i);
            pinned = old.pinned;
            id = Some(old.id);
        }
        let id = id.unwrap_or_else(|| {
            self.next_id += 1;
            self.next_id - 1
        });
        self.clips.insert(0, Clip { id, kind, text, pinned, at });
        self.trim();
    }

    fn trim(&mut self) {
        let mut unpinned = 0;
        self.clips.retain(|c| {
            if c.pinned {
                return true;
            }
            unpinned += 1;
            unpinned <= LIMIT
        });
    }

    pub fn get(&self, id: u64) -> Option<&Clip> {
        self.clips.iter().find(|c| c.id == id)
    }

    pub fn toggle_pin(&mut self, id: u64) {
        if let Some(c) = self.clips.iter_mut().find(|c| c.id == id) {
            c.pinned = !c.pinned;
        }
        self.trim();
    }

    pub fn remove(&mut self, id: u64) {
        self.clips.retain(|c| c.id != id);
    }

    /// Everything but the pinned clips.
    pub fn clear(&mut self) {
        self.clips.retain(|c| c.pinned);
    }

    pub fn clips(&self) -> &[Clip] {
        &self.clips
    }

    /// Pinned first, then the most recent.
    pub fn view(&self) -> Vec<ClipView> {
        let pinned = self.clips.iter().filter(|c| c.pinned);
        let rest = self.clips.iter().filter(|c| !c.pinned);
        pinned.chain(rest).map(view_of).collect()
    }

    /// The clips whose text holds every word of `query`, ignoring case, in the same order as
    /// `view`. For copied files that is their paths, so a file is found by its name.
    pub fn search(&self, query: &str) -> Vec<ClipView> {
        let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
        if words.is_empty() {
            return self.view();
        }
        let hit = |c: &&Clip| {
            let text = c.text.to_lowercase();
            words.iter().all(|w| text.contains(w.as_str()))
        };
        let pinned = self.clips.iter().filter(|c| c.pinned).filter(hit);
        let rest = self.clips.iter().filter(|c| !c.pinned).filter(hit);
        pinned.chain(rest).map(view_of).collect()
    }
}

/// A piece of text kept to be pasted again and again — the Mac's snippets.
#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct Snippet {
    pub id: u64,
    /// Optional: the card shows the text's first line without one.
    #[serde(default)]
    pub title: String,
    pub text: String,
}

#[derive(Default)]
pub struct Snippets {
    list: Vec<Snippet>,
}

impl Snippets {
    pub fn from_saved(list: Vec<Snippet>) -> Self {
        Self { list }
    }

    /// A new one (no id) goes at the end; an existing one is changed in place. Empty text is refused.
    pub fn save(&mut self, id: Option<u64>, title: &str, text: &str) -> Result<u64, String> {
        if text.trim().is_empty() {
            return Err("a snippet needs some text".into());
        }
        let text: String = text.chars().take(MAX_TEXT).collect();
        let title = title.trim().chars().take(80).collect::<String>();
        if let Some(id) = id {
            if let Some(s) = self.list.iter_mut().find(|s| s.id == id) {
                s.title = title;
                s.text = text;
                return Ok(id);
            }
        }
        // The same text twice is one snippet.
        if let Some(s) = self.list.iter_mut().find(|s| s.text == text) {
            if !title.is_empty() {
                s.title = title;
            }
            return Ok(s.id);
        }
        let id = self.list.iter().map(|s| s.id).max().unwrap_or(0) + 1;
        self.list.push(Snippet { id, title, text });
        Ok(id)
    }

    pub fn remove(&mut self, id: u64) {
        self.list.retain(|s| s.id != id);
    }

    /// Saves the text as a snippet, or removes the snippet that already has it. Returns whether it
    /// is saved now.
    pub fn toggle_text(&mut self, text: &str) -> Result<bool, String> {
        let text: String = text.chars().take(MAX_TEXT).collect();
        if let Some(id) = self.list.iter().find(|s| s.text == text).map(|s| s.id) {
            self.remove(id);
            return Ok(false);
        }
        self.save(None, "", &text)?;
        Ok(true)
    }

    pub fn get(&self, id: u64) -> Option<&Snippet> {
        self.list.iter().find(|s| s.id == id)
    }

    pub fn list(&self) -> &[Snippet] {
        &self.list
    }
}

fn view_of(clip: &Clip) -> ClipView {
    let preview = match clip.kind {
        ClipKind::Files => {
            let names: Vec<&str> = clip
                .text
                .lines()
                .map(|p| p.rsplit(['\\', '/']).next().unwrap_or(p))
                .collect();
            match names.len() {
                0 => String::new(),
                1 => names[0].to_string(),
                n => format!("{} +{}", names[0], n - 1),
            }
        }
        ClipKind::Text | ClipKind::Link => clip
            .text
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or("")
            .chars()
            .take(160)
            .collect(),
    };
    ClipView {
        id: clip.id,
        kind: clip.kind,
        preview,
        detail: clip.text.chars().take(DETAIL_CHARS).collect(),
        chars: clip.text.chars().count(),
        lines: clip.text.lines().filter(|l| !l.trim().is_empty()).count().max(1),
        pinned: clip.pinned,
        at: clip.at,
    }
}

/// Text, or a single web address on its own.
pub fn classify(text: &str) -> Option<ClipKind> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    let is_link = (lower.starts_with("http://") || lower.starts_with("https://"))
        && !trimmed.chars().any(char::is_whitespace)
        && trimmed.len() > "https://".len();
    Some(if is_link { ClipKind::Link } else { ClipKind::Text })
}

static ENABLED: AtomicBool = AtomicBool::new(false);
static REMEMBER: AtomicBool = AtomicBool::new(true);
/// Every copy of formatted text is put back as plain text.
static PLAIN: AtomicBool = AtomicBool::new(false);
static SNIPPETS: Mutex<Option<Snippets>> = Mutex::new(None);
/// The sequence number of the clipboard as we last read or wrote it.
static SEEN: AtomicU32 = AtomicU32::new(0);
static HISTORY: Mutex<Option<History>> = Mutex::new(None);

fn history() -> std::sync::MutexGuard<'static, Option<History>> {
    HISTORY.lock().unwrap_or_else(|e| e.into_inner())
}

fn store_path() -> std::path::PathBuf {
    crate::config::config_path()
        .parent()
        .map(|d| d.join("clipboard-history.json"))
        .unwrap_or_else(|| "clipboard-history.json".into())
}

fn load() -> History {
    let saved = std::fs::read_to_string(store_path())
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<Clip>>(&s).ok())
        .unwrap_or_default();
    History::from_saved(saved)
}

fn save(h: &History) {
    let path = store_path();
    if !REMEMBER.load(Ordering::SeqCst) {
        let _ = std::fs::remove_file(&path);
        return;
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string(h.clips()) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

fn changed(app: &AppHandle, h: &History) {
    save(h);
    let _ = app.emit("clipboard", h.view());
}

pub fn set_enabled(on: bool) {
    let was = ENABLED.swap(on, Ordering::SeqCst);
    if on && !was {
        // Whatever is on the clipboard already was copied before we looked.
        SEEN.store(platform::sequence(), Ordering::SeqCst);
    }
}

pub fn set_remember(on: bool) {
    REMEMBER.store(on, Ordering::SeqCst);
    if let Some(h) = history().as_ref() {
        save(h);
    }
}

pub fn set_plain(on: bool) {
    PLAIN.store(on, Ordering::SeqCst);
}

#[tauri::command]
pub fn get_clipboard() -> Vec<ClipView> {
    history().get_or_insert_with(load).view()
}

/// The search box in the card: every word typed, anywhere in a clip.
#[tauri::command]
pub fn clipboard_search(query: String) -> Vec<ClipView> {
    history().get_or_insert_with(load).search(&query)
}

fn snippets() -> std::sync::MutexGuard<'static, Option<Snippets>> {
    SNIPPETS.lock().unwrap_or_else(|e| e.into_inner())
}

fn snippets_path() -> std::path::PathBuf {
    crate::config::config_path()
        .parent()
        .map(|d| d.join("snippets.json"))
        .unwrap_or_else(|| "snippets.json".into())
}

fn load_snippets() -> Snippets {
    Snippets::from_saved(
        std::fs::read_to_string(snippets_path())
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<Snippet>>(&s).ok())
            .unwrap_or_default(),
    )
}

/// Snippets are kept whether or not the history is: they were saved on purpose.
fn snippets_changed(app: &AppHandle, s: &Snippets) {
    let path = snippets_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string_pretty(s.list()) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
    let _ = app.emit("snippets", s.list());
}

#[tauri::command]
pub fn get_snippets() -> Vec<Snippet> {
    snippets().get_or_insert_with(load_snippets).list().to_vec()
}

#[tauri::command]
pub fn snippet_save(app: AppHandle, id: Option<u64>, title: String, text: String) -> Result<Vec<Snippet>, String> {
    let mut guard = snippets();
    let s = guard.get_or_insert_with(load_snippets);
    s.save(id, &title, &text)?;
    snippets_changed(&app, s);
    Ok(s.list().to_vec())
}

#[tauri::command]
pub fn snippet_delete(app: AppHandle, id: u64) -> Vec<Snippet> {
    let mut guard = snippets();
    let s = guard.get_or_insert_with(load_snippets);
    s.remove(id);
    snippets_changed(&app, s);
    s.list().to_vec()
}

/// The star on a clip's row: keeps the clip as a snippet, or — already kept — takes it back out.
#[tauri::command]
pub fn clipboard_toggle_snippet(app: AppHandle, id: u64) -> Result<Vec<Snippet>, String> {
    let text = {
        let mut guard = history();
        let h = guard.get_or_insert_with(load);
        let clip = h.get(id).ok_or("no such clip")?;
        if clip.kind == ClipKind::Files {
            return Err("files cannot be a snippet".into());
        }
        clip.text.clone()
    };
    let mut guard = snippets();
    let s = guard.get_or_insert_with(load_snippets);
    s.toggle_text(&text)?;
    snippets_changed(&app, s);
    Ok(s.list().to_vec())
}

/// Puts a snippet on the clipboard, as plain text. Not recorded as a new clip: it is not one.
#[tauri::command]
pub fn snippet_copy(id: u64) -> Result<(), String> {
    let text = snippets().get_or_insert_with(load_snippets).get(id).map(|s| s.text.clone()).ok_or("no such snippet")?;
    platform::write(&Clip { id: 0, kind: ClipKind::Text, text, pinned: false, at: 0 })?;
    SEEN.store(platform::sequence(), Ordering::SeqCst);
    Ok(())
}

/// Puts a clip back on the clipboard, ready to paste.
#[tauri::command]
pub fn clipboard_copy(app: AppHandle, id: u64) -> Result<(), String> {
    let mut guard = history();
    let h = guard.get_or_insert_with(load);
    let clip = h.get(id).cloned().ok_or("no such clip")?;
    platform::write(&clip)?;
    // Ours: not a new clip, but the old one coming back to the top.
    SEEN.store(platform::sequence(), Ordering::SeqCst);
    h.record(clip.kind, clip.text, crate::media::now_ms());
    changed(&app, h);
    Ok(())
}

#[tauri::command]
pub fn clipboard_pin(app: AppHandle, id: u64) {
    let mut guard = history();
    let h = guard.get_or_insert_with(load);
    h.toggle_pin(id);
    changed(&app, h);
}

#[tauri::command]
pub fn clipboard_remove(app: AppHandle, id: u64) {
    let mut guard = history();
    let h = guard.get_or_insert_with(load);
    h.remove(id);
    changed(&app, h);
}

#[tauri::command]
pub fn clipboard_clear(app: AppHandle) {
    let mut guard = history();
    let h = guard.get_or_insert_with(load);
    h.clear();
    changed(&app, h);
}

pub fn start(app: AppHandle) {
    {
        history().get_or_insert_with(load);
    }
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        loop {
            std::thread::sleep(Duration::from_millis(400));
            if !ENABLED.load(Ordering::SeqCst) {
                continue;
            }
            let seq = platform::sequence();
            if seq == SEEN.swap(seq, Ordering::SeqCst) {
                continue;
            }
            if platform::excluded() {
                continue;
            }
            let Some((kind, text)) = platform::read() else {
                continue;
            };
            // "Always strip formatting": formatted text goes back as the same text, plain, and that
            // rewrite is ours, so it is not seen as another copy.
            if PLAIN.load(Ordering::SeqCst) && kind != ClipKind::Files && platform::has_formatting() {
                let plain = Clip { id: 0, kind: ClipKind::Text, text: text.clone(), pinned: false, at: 0 };
                if platform::write(&plain).is_ok() {
                    SEEN.store(platform::sequence(), Ordering::SeqCst);
                }
            }
            let mut guard = history();
            let h = guard.get_or_insert_with(load);
            h.record(kind, text, crate::media::now_ms());
            changed(&app, h);
        }
    });
}

#[cfg(windows)]
mod platform {
    use super::{classify, Clip, ClipKind};
    use windows::core::w;
    use windows::Win32::Foundation::{CloseHandle, HANDLE, HGLOBAL, HWND};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, GetClipboardData, GetClipboardSequenceNumber,
        IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
    };
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::System::Ole::{CF_HDROP, CF_UNICODETEXT};
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Shell::{DragQueryFileW, DROPFILES, HDROP};
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

    /// Password managers: nothing copied while one of these is in front is kept.
    const PASSWORD_MANAGERS: &[&str] = &[
        "1password.exe",
        "keepass.exe",
        "keepassxc.exe",
        "bitwarden.exe",
        "dashlane.exe",
        "enpass.exe",
        "nordpass.exe",
        "lastpass.exe",
        "roboform.exe",
        "keeper.exe",
        "proton pass.exe",
    ];

    pub fn sequence() -> u32 {
        unsafe { GetClipboardSequenceNumber() }
    }

    /// Whether what is on the clipboard carries formatting beside its plain text: a web page's HTML,
    /// or Word's and WordPad's rich text.
    pub fn has_formatting() -> bool {
        unsafe {
            [w!("HTML Format"), w!("Rich Text Format")].iter().any(|name| {
                let f = RegisterClipboardFormatW(*name);
                f != 0 && IsClipboardFormatAvailable(f).is_ok()
            })
        }
    }

    /// The clipboard is shared, and another app may be holding it open for a moment.
    fn open() -> bool {
        for _ in 0..5 {
            if unsafe { OpenClipboard(HWND::default()) }.is_ok() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(30));
        }
        false
    }

    struct Opened;
    impl Drop for Opened {
        fn drop(&mut self) {
            let _ = unsafe { CloseClipboard() };
        }
    }

    pub fn excluded() -> bool {
        unsafe {
            let exclude = RegisterClipboardFormatW(w!("ExcludeClipboardContentFromMonitorProcessing"));
            if exclude != 0 && IsClipboardFormatAvailable(exclude).is_ok() {
                return true;
            }
            let viewer_ignore = RegisterClipboardFormatW(w!("Clipboard Viewer Ignore"));
            if viewer_ignore != 0 && IsClipboardFormatAvailable(viewer_ignore).is_ok() {
                return true;
            }
            let history = RegisterClipboardFormatW(w!("CanIncludeInClipboardHistory"));
            if history != 0 && IsClipboardFormatAvailable(history).is_ok() && open() {
                let _open = Opened;
                if let Ok(handle) = GetClipboardData(history) {
                    let mem = HGLOBAL(handle.0);
                    let ptr = GlobalLock(mem) as *const u32;
                    let allowed = ptr.is_null() || GlobalSize(mem) < 4 || *ptr != 0;
                    let _ = GlobalUnlock(mem);
                    if !allowed {
                        return true;
                    }
                }
            }
        }
        foreground_is_password_manager()
    }

    fn foreground_is_password_manager() -> bool {
        unsafe {
            let hwnd = GetForegroundWindow();
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == 0 {
                return false;
            }
            let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
                return false;
            };
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            let ok = QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                windows::core::PWSTR(buf.as_mut_ptr()),
                &mut len,
            )
            .is_ok();
            let _ = CloseHandle(process);
            if !ok {
                return false;
            }
            let path = String::from_utf16_lossy(&buf[..len as usize]).to_ascii_lowercase();
            let exe = path.rsplit('\\').next().unwrap_or(&path).to_string();
            PASSWORD_MANAGERS.contains(&exe.as_str())
        }
    }

    pub fn read() -> Option<(ClipKind, String)> {
        unsafe {
            let files = IsClipboardFormatAvailable(CF_HDROP.0 as u32).is_ok();
            let text = IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).is_ok();
            if !files && !text {
                return None;
            }
            if !open() {
                return None;
            }
            let _open = Opened;
            if files {
                if let Ok(handle) = GetClipboardData(CF_HDROP.0 as u32) {
                    let drop = HDROP(handle.0);
                    let count = DragQueryFileW(drop, u32::MAX, None);
                    let mut paths = Vec::new();
                    for i in 0..count {
                        let len = DragQueryFileW(drop, i, None) as usize;
                        let mut buf = vec![0u16; len + 1];
                        let got = DragQueryFileW(drop, i, Some(&mut buf)) as usize;
                        paths.push(String::from_utf16_lossy(&buf[..got]));
                    }
                    if !paths.is_empty() {
                        return Some((ClipKind::Files, paths.join("\n")));
                    }
                }
            }
            let handle = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
            let mem = HGLOBAL(handle.0);
            let ptr = GlobalLock(mem) as *const u16;
            if ptr.is_null() {
                return None;
            }
            let max = GlobalSize(mem) / 2;
            let mut len = 0usize;
            while len < max && *ptr.add(len) != 0 {
                len += 1;
            }
            let text = String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len));
            let _ = GlobalUnlock(mem);
            classify(&text).map(|kind| (kind, text))
        }
    }

    /// One block of moveable global memory holding `bytes`, which the clipboard takes over.
    fn global(bytes: &[u8]) -> Result<HGLOBAL, String> {
        unsafe {
            let mem = GlobalAlloc(GMEM_MOVEABLE, bytes.len()).map_err(|e| e.to_string())?;
            let ptr = GlobalLock(mem) as *mut u8;
            if ptr.is_null() {
                return Err("could not lock clipboard memory".into());
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
            let _ = GlobalUnlock(mem);
            Ok(mem)
        }
    }

    fn wide(s: &str) -> Vec<u8> {
        s.encode_utf16().chain(std::iter::once(0)).flat_map(u16::to_le_bytes).collect()
    }

    pub fn write(clip: &Clip) -> Result<(), String> {
        let (format, bytes) = match clip.kind {
            ClipKind::Text | ClipKind::Link => (CF_UNICODETEXT.0 as u32, wide(&clip.text)),
            ClipKind::Files => {
                // DROPFILES, then the paths as wide strings, each ended, and one more end.
                let header = std::mem::size_of::<DROPFILES>();
                let mut bytes = vec![0u8; header];
                bytes[0..4].copy_from_slice(&(header as u32).to_le_bytes()); // pFiles
                // fWide sits after pFiles (4), pt (8) and fNC (4).
                bytes[16..20].copy_from_slice(&1u32.to_le_bytes());
                for path in clip.text.lines() {
                    bytes.extend(wide(path));
                }
                bytes.extend([0u8, 0u8]);
                (CF_HDROP.0 as u32, bytes)
            }
        };
        if !open() {
            return Err("the clipboard is busy".into());
        }
        let _open = Opened;
        unsafe {
            EmptyClipboard().map_err(|e| e.to_string())?;
            let mem = global(&bytes)?;
            SetClipboardData(format, HANDLE(mem.0)).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

/// Elsewhere (the Linux build CI runs) there is no clipboard to watch; the history still works.
#[cfg(not(windows))]
mod platform {
    use super::{Clip, ClipKind};

    pub fn sequence() -> u32 {
        0
    }
    pub fn has_formatting() -> bool {
        false
    }
    pub fn excluded() -> bool {
        true
    }
    pub fn read() -> Option<(ClipKind, String)> {
        None
    }
    pub fn write(_clip: &Clip) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{classify, ClipKind, History, LIMIT};

    #[test]
    fn tells_links_from_text() {
        assert_eq!(classify("https://example.com/a?b=c"), Some(ClipKind::Link));
        assert_eq!(classify("  https://example.com  "), Some(ClipKind::Link));
        assert_eq!(classify("see https://example.com"), Some(ClipKind::Text));
        assert_eq!(classify("hello"), Some(ClipKind::Text));
        assert_eq!(classify(" \n\t "), None);
        assert_eq!(classify("https://"), Some(ClipKind::Text));
    }

    #[test]
    fn copying_the_same_thing_again_moves_it_up() {
        let mut h = History::default();
        h.record(ClipKind::Text, "one".into(), 1);
        h.record(ClipKind::Text, "two".into(), 2);
        let first = h.clips()[1].id;
        h.record(ClipKind::Text, "one".into(), 3);
        let texts: Vec<_> = h.clips().iter().map(|c| c.text.as_str()).collect();
        assert_eq!(texts, ["one", "two"]);
        assert_eq!(h.clips()[0].id, first, "the clip keeps its id");
    }

    #[test]
    fn pinned_clips_outlive_clearing_and_the_limit() {
        let mut h = History::default();
        h.record(ClipKind::Text, "keep".into(), 0);
        let id = h.clips()[0].id;
        h.toggle_pin(id);
        for n in 0..LIMIT + 10 {
            h.record(ClipKind::Text, format!("clip {n}"), n as i64);
        }
        assert_eq!(h.clips().iter().filter(|c| !c.pinned).count(), LIMIT);
        assert_eq!(h.view()[0].preview, "keep", "pinned clips are listed first");
        h.clear();
        assert_eq!(h.clips().len(), 1);
        assert!(h.clips()[0].pinned);
    }

    #[test]
    fn previews_are_one_line() {
        let mut h = History::default();
        h.record(ClipKind::Text, "\n  first line  \nsecond".into(), 0);
        h.record(ClipKind::Files, "C:\\a\\one.txt\nC:\\b\\two.png".into(), 1);
        let v = h.view();
        assert_eq!(v[0].preview, "one.txt +1");
        assert_eq!(v[1].preview, "first line");
    }

    #[test]
    fn the_preview_carries_the_clip_and_its_size() {
        let mut h = History::default();
        let long: String = "x".repeat(super::DETAIL_CHARS + 50);
        h.record(ClipKind::Text, format!("{long}\nsecond line"), 0);
        let v = &h.view()[0];
        assert_eq!(v.detail.chars().count(), super::DETAIL_CHARS);
        assert_eq!(v.chars, super::DETAIL_CHARS + 50 + 1 + "second line".len());
        assert_eq!(v.lines, 2);
    }

    #[test]
    fn search_finds_every_word_ignoring_case() {
        let mut h = History::default();
        h.record(ClipKind::Text, "Quarterly report draft".into(), 0);
        h.record(ClipKind::Link, "https://example.com/Report".into(), 1);
        h.record(ClipKind::Files, "C:\\Users\\me\\Desktop\\budget.xlsx".into(), 2);
        h.record(ClipKind::Text, "lunch order".into(), 3);
        let id = h.clips().iter().find(|c| c.text == "lunch order").unwrap().id;
        h.toggle_pin(id);
        let previews = |q: &str| h.search(q).into_iter().map(|v| v.preview).collect::<Vec<_>>();
        assert_eq!(previews("report"), ["https://example.com/Report", "Quarterly report draft"]);
        assert_eq!(previews("REPORT draft"), ["Quarterly report draft"], "every word has to be there");
        assert_eq!(previews("budget"), ["budget.xlsx"], "files by their names");
        assert_eq!(previews("  ").len(), 4, "an empty search is the whole history");
        assert_eq!(previews("")[0], "lunch order", "pinned first, as the card lists them");
        assert!(previews("nothing like this").is_empty());
    }

    #[test]
    fn snippets_are_saved_edited_and_deduped() {
        use super::Snippets;
        let mut s = Snippets::default();
        assert!(s.save(None, "", "   ").is_err(), "empty text is not a snippet");
        let a = s.save(None, "Address", "1 Infinite Loop").unwrap();
        let b = s.save(None, "", "Thanks, talk soon!").unwrap();
        assert_ne!(a, b);
        assert_eq!(s.save(None, "", "1 Infinite Loop").unwrap(), a, "the same text is the same snippet");
        s.save(Some(b), "Sign-off", "Thanks — talk soon!").unwrap();
        assert_eq!(s.get(b).unwrap().title, "Sign-off");
        assert_eq!(s.get(b).unwrap().text, "Thanks — talk soon!");
        s.remove(a);
        assert_eq!(s.list().len(), 1);
        let c = s.save(None, "", "new").unwrap();
        assert!(c > b, "ids are not reused");
    }

    #[test]
    fn the_star_saves_a_snippet_and_takes_it_back_out() {
        let mut s = super::Snippets::default();
        assert_eq!(s.toggle_text("ssh demo@host"), Ok(true));
        assert_eq!(s.list().len(), 1);
        assert_eq!(s.toggle_text("ssh demo@host"), Ok(false));
        assert!(s.list().is_empty());
        assert!(s.toggle_text("   ").is_err());
    }

    #[test]
    fn saved_history_continues_its_ids() {
        let mut h = History::default();
        h.record(ClipKind::Text, "a".into(), 0);
        h.record(ClipKind::Text, "b".into(), 1);
        let saved = h.clips().to_vec();
        let mut again = History::from_saved(saved);
        again.record(ClipKind::Text, "c".into(), 2);
        let ids: std::collections::HashSet<_> = again.clips().iter().map(|c| c.id).collect();
        assert_eq!(ids.len(), 3);
    }
}
