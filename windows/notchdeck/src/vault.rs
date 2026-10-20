//! The Vault — the Mac's `VaultStore`: files dragged onto the notch are held there, to be dragged out
//! again into Explorer, a mail, a chat or a browser's upload box.
//!
//! A file is held by its path, so the Vault never fills the disk with copies — unless it sits
//! somewhere temporary (an Outlook attachment, a browser's cache, %TEMP%), where it would vanish, or
//! "Keep a copy" is on. Those are copied into `%LOCALAPPDATA%\NotchDeck\Vault`, and removing one from
//! the Vault puts that copy in the Recycle Bin. Text, links and pictures dragged out of a browser have
//! no file at all, so they are saved there as one (.txt, .url, .png).
//!
//! Drops: Tauri's own drop handler only ever reports files, so the notch window gets a drop target of
//! this module's own (`register_drop_target`) that reads the rest of a drag too. Dragging out: the
//! shell's own data object for the files and SHDoDragDrop, so Explorer gets exactly what it would from
//! one of its own windows, drag image included. It is offered as a copy (Preferred DropEffect), and
//! Shift makes it a move, as in Explorer; a file moved away leaves the Vault.

// Taking drops in is Windows-only (the platform module below); elsewhere those parts are unused.
#![cfg_attr(not(windows), allow(dead_code))]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
pub struct Item {
    pub id: u64,
    pub path: String,
    /// A copy kept in the vault folder, which goes when the item does.
    #[serde(default)]
    pub owned: bool,
    /// Unix milliseconds.
    pub added: i64,
}

/// An item as the card draws it.
#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct View {
    pub id: u64,
    pub name: String,
    pub path: String,
    pub owned: bool,
    pub is_dir: bool,
    pub missing: bool,
    /// "2.4 MB", "Folder" or "Missing".
    pub detail: String,
    /// The file's icon as a PNG data URL, when Windows has one.
    pub icon: Option<String>,
    pub added: i64,
}

pub fn detail_of(size: Option<u64>, is_dir: bool, missing: bool) -> String {
    if missing {
        "Missing".into()
    } else if is_dir {
        "Folder".into()
    } else {
        size.map(crate::live::size_text).unwrap_or_default()
    }
}

/// Where a file sits only for a while: copied in rather than pointed at. `temp_roots` are the
/// temporary folders (lower case, backslashes); the rest are recognised wherever they are.
pub fn is_temporary(path: &str, temp_roots: &[String]) -> bool {
    let p = path.replace('/', "\\").to_lowercase();
    let under = |root: &str| {
        let root = root.trim_end_matches('\\');
        !root.is_empty() && (p == root || p.starts_with(&format!("{root}\\")))
    };
    temp_roots.iter().any(|r| under(r))
        || ["\\content.outlook\\", "\\content.mso\\", "\\inetcache\\", "\\temporary internet files\\", "\\tempstate\\"]
            .iter()
            .any(|part| p.contains(part))
        || p.ends_with(".tmp")
}

/// A name not yet used in `dir`: "notes.txt", then "notes (2).txt".
pub fn unique_name(dir: &Path, name: &str) -> PathBuf {
    let clean: String = name
        .chars()
        .map(|c| if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || c.is_control() { '_' } else { c })
        .collect();
    let clean = clean.trim().trim_end_matches('.').to_string();
    let clean = if clean.is_empty() { "Item".to_string() } else { clean };
    let first = dir.join(&clean);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = match clean.rfind('.') {
        Some(i) if i > 0 => (&clean[..i], &clean[i..]),
        _ => (clean.as_str(), ""),
    };
    (2..10_000)
        .map(|n| dir.join(format!("{stem} ({n}){ext}")))
        .find(|p| !p.exists())
        .unwrap_or(first)
}

/// How long items stay, from the "Clear items after" choice.
pub fn keep_for_ms(choice: &str) -> Option<i64> {
    match choice {
        "1h" => Some(3_600_000),
        "1d" => Some(86_400_000),
        "1w" => Some(7 * 86_400_000),
        _ => None,
    }
}

#[derive(Default)]
pub struct Store {
    items: Vec<Item>,
    next_id: u64,
}

impl Store {
    pub fn from_saved(items: Vec<Item>) -> Self {
        let next_id = items.iter().map(|i| i.id).max().unwrap_or(0) + 1;
        Self { items, next_id }
    }

    /// Adds a path at the top; the same path again moves up rather than appearing twice.
    pub fn add(&mut self, path: String, owned: bool, at: i64) -> u64 {
        if let Some(i) = self.items.iter().position(|x| x.path.eq_ignore_ascii_case(&path)) {
            let mut item = self.items.remove(i);
            item.added = at;
            let id = item.id;
            self.items.insert(0, item);
            return id;
        }
        let id = self.next_id.max(1);
        self.next_id = id + 1;
        self.items.insert(0, Item { id, path, owned, added: at });
        id
    }

    #[cfg(test)]
    pub fn contains_path(&self, path: &str) -> bool {
        self.items.iter().any(|x| x.path.eq_ignore_ascii_case(path))
    }

    pub fn get(&self, id: u64) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }

    pub fn remove(&mut self, id: u64) -> Option<Item> {
        let i = self.items.iter().position(|x| x.id == id)?;
        Some(self.items.remove(i))
    }

    /// Everything older than `keep` at `now`, taken out.
    pub fn expire(&mut self, now: i64, keep: Option<i64>) -> Vec<Item> {
        let Some(keep) = keep else { return Vec::new() };
        let (old, kept): (Vec<Item>, Vec<Item>) = self.items.drain(..).partition(|i| now - i.added >= keep);
        self.items = kept;
        old
    }

    pub fn take_all(&mut self) -> Vec<Item> {
        std::mem::take(&mut self.items)
    }

    pub fn items(&self) -> &[Item] {
        &self.items
    }
}

static ENABLED: AtomicBool = AtomicBool::new(false);
static KEEP_COPIES: AtomicBool = AtomicBool::new(false);
static KEEP_FOR: AtomicU64 = AtomicU64::new(0); // ms; 0 = forever
static STORE: Mutex<Option<Store>> = Mutex::new(None);
static ICONS: Mutex<Option<HashMap<String, Option<String>>>> = Mutex::new(None);

fn store() -> std::sync::MutexGuard<'static, Option<Store>> {
    STORE.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn vault_dir() -> PathBuf {
    dirs::data_local_dir().unwrap_or_else(std::env::temp_dir).join("NotchDeck").join("Vault")
}

fn store_path() -> PathBuf {
    crate::config::config_path()
        .parent()
        .map(|d| d.join("vault.json"))
        .unwrap_or_else(|| "vault.json".into())
}

fn load() -> Store {
    let saved = std::fs::read_to_string(store_path())
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<Item>>(&s).ok())
        .unwrap_or_default();
    Store::from_saved(saved)
}

fn save(s: &Store) {
    let path = store_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string(s.items()) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::SeqCst);
}

pub fn set_keep_copies(on: bool) {
    KEEP_COPIES.store(on, Ordering::SeqCst);
}

pub fn set_clear_after(choice: &str) {
    KEEP_FOR.store(keep_for_ms(choice).unwrap_or(0) as u64, Ordering::SeqCst);
}

fn icon_for(path: &Path, is_dir: bool, missing: bool) -> Option<String> {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    // Programs, shortcuts and icons carry their own; everything else shares its type's.
    let key = if is_dir {
        "<dir>".to_string()
    } else if !missing && matches!(ext.as_str(), "exe" | "lnk" | "ico" | "url" | "appref-ms") {
        path.to_string_lossy().to_lowercase()
    } else {
        format!(".{ext}")
    };
    let mut guard = ICONS.lock().unwrap_or_else(|e| e.into_inner());
    let cache = guard.get_or_insert_with(HashMap::new);
    if let Some(hit) = cache.get(&key) {
        return hit.clone();
    }
    let icon = platform::icon(path, is_dir, missing);
    cache.insert(key, icon.clone());
    icon
}

fn view_of(item: &Item) -> View {
    let path = Path::new(&item.path);
    let meta = std::fs::metadata(path).ok();
    let missing = meta.is_none();
    let is_dir = meta.as_ref().is_some_and(|m| m.is_dir());
    let size = meta.as_ref().filter(|m| m.is_file()).map(|m| m.len());
    View {
        id: item.id,
        name: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| item.path.clone()),
        path: item.path.clone(),
        owned: item.owned,
        is_dir,
        missing,
        detail: detail_of(size, is_dir, missing),
        icon: icon_for(path, is_dir, missing),
        added: item.added,
    }
}

fn views() -> Vec<View> {
    store().get_or_insert_with(load).items().iter().map(view_of).collect()
}

fn changed(app: &AppHandle) {
    let _ = app.emit("vault", views());
}

/// The copy an owned item kept goes to the Recycle Bin, never straight to nothing: it may be the
/// only copy of an attachment.
fn discard(item: &Item) {
    if item.owned && Path::new(&item.path).starts_with(vault_dir()) {
        platform::recycle(&item.path);
    }
}

#[tauri::command]
pub fn get_vault() -> Vec<View> {
    views()
}

#[tauri::command]
pub fn vault_remove(app: AppHandle, id: u64) {
    let removed = {
        let mut guard = store();
        let s = guard.get_or_insert_with(load);
        let r = s.remove(id);
        save(s);
        r
    };
    if let Some(item) = removed {
        discard(&item);
    }
    changed(&app);
}

#[tauri::command]
pub fn vault_clear(app: AppHandle) {
    let all = {
        let mut guard = store();
        let s = guard.get_or_insert_with(load);
        let all = s.take_all();
        save(s);
        all
    };
    all.iter().for_each(discard);
    changed(&app);
}

fn path_of(id: u64) -> Option<String> {
    store().get_or_insert_with(load).get(id).map(|i| i.path.clone())
}

#[tauri::command]
pub fn vault_reveal(id: u64) -> Result<(), String> {
    let path = path_of(id).ok_or("no such item")?;
    crate::shell::reveal(&path);
    Ok(())
}

#[tauri::command]
pub fn vault_open(id: u64) -> Result<(), String> {
    let path = path_of(id).ok_or("no such item")?;
    if !Path::new(&path).exists() {
        return Err("that file is no longer there".into());
    }
    crate::shell::open(&path);
    Ok(())
}

#[tauri::command]
pub fn vault_open_folder() {
    let dir = vault_dir();
    let _ = std::fs::create_dir_all(&dir);
    crate::shell::open(&dir.to_string_lossy());
}

/// Paths dropped or handed in: held where they are, or copied in when they would not last.
pub fn add_paths(app: &AppHandle, paths: Vec<String>) {
    if paths.is_empty() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        let dir = vault_dir();
        let temp_roots = temp_roots();
        let keep = KEEP_COPIES.load(Ordering::SeqCst);
        let mut added = Vec::new();
        for p in paths {
            let path = Path::new(&p);
            if !path.exists() {
                continue;
            }
            let inside = path.starts_with(&dir);
            if !inside && (keep || is_temporary(&p, &temp_roots)) {
                let _ = std::fs::create_dir_all(&dir);
                let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                let target = unique_name(&dir, &name);
                match copy_any(path, &target) {
                    Ok(()) => added.push((target.to_string_lossy().to_string(), true)),
                    Err(e) => crate::applog(&format!("vault: could not keep a copy of {name} ({e})")),
                }
            } else {
                added.push((p.clone(), inside));
            }
        }
        if added.is_empty() {
            return;
        }
        {
            let mut guard = store();
            let s = guard.get_or_insert_with(load);
            let now = crate::media::now_ms();
            for (p, owned) in added {
                s.add(p, owned, now);
            }
            save(s);
        }
        changed(&app);
    });
}

/// What a drag carried that is not a file: saved in the vault folder as one.
pub enum Loose {
    Text(String),
    Link(String),
    Png(Vec<u8>),
    /// A file a program offered by its contents only (an Outlook attachment, a browser's picture).
    Named(String, Vec<u8>),
}

pub fn file_for(loose: &Loose, stamp: &str) -> (String, Vec<u8>) {
    match loose {
        Loose::Text(t) => {
            let first: String = t.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("Text").chars().take(40).collect();
            (format!("{} {stamp}.txt", first.trim()), t.as_bytes().to_vec())
        }
        Loose::Link(url) => {
            let host = url.split("://").nth(1).and_then(|r| r.split(['/', '?', '#']).next()).unwrap_or("Link");
            (format!("{host}.url"), format!("[InternetShortcut]\r\nURL={url}\r\n").into_bytes())
        }
        Loose::Png(bytes) => (format!("Image {stamp}.png"), bytes.clone()),
        Loose::Named(name, bytes) => (name.clone(), bytes.clone()),
    }
}

pub fn add_loose(app: &AppHandle, loose: Vec<Loose>) {
    if loose.is_empty() {
        return;
    }
    let dir = vault_dir();
    let _ = std::fs::create_dir_all(&dir);
    let stamp = chrono::Local::now().format("%Y-%m-%d %H.%M.%S").to_string();
    let mut paths = Vec::new();
    for l in &loose {
        let (name, bytes) = file_for(l, &stamp);
        let target = unique_name(&dir, &name);
        if std::fs::write(&target, bytes).is_ok() {
            paths.push(target.to_string_lossy().to_string());
        }
    }
    add_paths(app, paths);
}

fn temp_roots() -> Vec<String> {
    let mut roots = vec![std::env::temp_dir().to_string_lossy().to_lowercase()];
    if let Some(local) = dirs::data_local_dir() {
        roots.push(local.join("Temp").to_string_lossy().to_lowercase());
    }
    roots.into_iter().map(|r| r.replace('/', "\\")).collect()
}

fn copy_any(from: &Path, to: &Path) -> std::io::Result<()> {
    if from.is_dir() {
        std::fs::create_dir_all(to)?;
        for entry in std::fs::read_dir(from)? {
            let entry = entry?;
            copy_any(&entry.path(), &to.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(from, to).map(|_| ())
    }
}

/// Zips the chosen items (or all) into the vault folder and adds the archive.
#[tauri::command]
pub async fn vault_zip(app: AppHandle, ids: Vec<u64>) -> Result<(), String> {
    let items: Vec<Item> = {
        let mut guard = store();
        let s = guard.get_or_insert_with(load);
        s.items().iter().filter(|i| ids.is_empty() || ids.contains(&i.id)).cloned().collect()
    };
    let present: Vec<PathBuf> = items.iter().map(|i| PathBuf::from(&i.path)).filter(|p| p.exists()).collect();
    if present.is_empty() {
        return Err("nothing to zip".into());
    }
    let dir = vault_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let name = if present.len() == 1 {
        let stem = present[0].file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Archive".into());
        format!("{stem}.zip")
    } else {
        "Archive.zip".to_string()
    };
    let target = unique_name(&dir, &name);
    write_zip(&target, &present).map_err(|e| {
        let _ = std::fs::remove_file(&target);
        e.to_string()
    })?;
    {
        let mut guard = store();
        let s = guard.get_or_insert_with(load);
        s.add(target.to_string_lossy().to_string(), true, crate::media::now_ms());
        save(s);
    }
    changed(&app);
    Ok(())
}

pub fn write_zip(target: &Path, sources: &[PathBuf]) -> zip::result::ZipResult<()> {
    use std::io::Write;
    let file = std::fs::File::create(target)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    fn add(
        zip: &mut zip::ZipWriter<std::fs::File>,
        path: &Path,
        name: &str,
        options: zip::write::SimpleFileOptions,
    ) -> zip::result::ZipResult<()> {
        if path.is_dir() {
            zip.add_directory(format!("{name}/"), options)?;
            for entry in std::fs::read_dir(path)? {
                let entry = entry?;
                let child = format!("{name}/{}", entry.file_name().to_string_lossy());
                add(zip, &entry.path(), &child, options)?;
            }
        } else {
            zip.start_file(name, options)?;
            let mut f = std::fs::File::open(path)?;
            std::io::copy(&mut f, zip)?;
        }
        Ok(())
    }
    let mut used = std::collections::HashSet::new();
    for src in sources {
        let base = src.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "item".into());
        // Two files of one name from two folders: the second gets a number, as unique_name does.
        let mut name = base.clone();
        let mut n = 2;
        while !used.insert(name.to_lowercase()) {
            name = format!("{n} {base}");
            n += 1;
        }
        add(&mut zip, src, &name, options)?;
    }
    zip.finish()?.flush()?;
    Ok(())
}

/// Windows' Share panel for the chosen items (or all).
#[tauri::command]
pub async fn vault_share(app: AppHandle, ids: Vec<u64>) -> Result<(), String> {
    let paths = chosen_paths(&ids);
    if paths.is_empty() {
        return Err("nothing to share".into());
    }
    platform::share(&app, paths)
}

fn chosen_paths(ids: &[u64]) -> Vec<String> {
    let mut guard = store();
    let s = guard.get_or_insert_with(load);
    s.items()
        .iter()
        .filter(|i| ids.is_empty() || ids.contains(&i.id))
        .map(|i| i.path.clone())
        .filter(|p| Path::new(p).exists())
        .collect()
}

/// Starts dragging the chosen items (or all) out of the notch. The page calls this from a press that
/// has started to move, while the button is still down.
#[tauri::command]
pub fn vault_drag_out(app: AppHandle, ids: Vec<u64>) -> Result<(), String> {
    let paths = chosen_paths(&ids);
    if paths.is_empty() {
        return Err("those files are no longer there".into());
    }
    let handle = app.clone();
    app.run_on_main_thread(move || {
        let Some(w) = handle.get_webview_window("notch") else { return };
        if let Err(e) = platform::drag_out(&w, &paths) {
            crate::applog(&format!("vault: drag out failed ({e})"));
        }
        // A file moved away (Shift) is not in the Vault any more.
        let gone: Vec<Item> = {
            let mut guard = store();
            let s = guard.get_or_insert_with(load);
            let ids: Vec<u64> = s
                .items()
                .iter()
                .filter(|i| paths.iter().any(|p| p.eq_ignore_ascii_case(&i.path)) && !Path::new(&i.path).exists())
                .map(|i| i.id)
                .collect();
            let gone = ids.into_iter().filter_map(|id| s.remove(id)).collect();
            save(s);
            gone
        };
        if !gone.is_empty() {
            crate::applog(&format!("vault: {} item(s) moved out", gone.len()));
        }
        changed(&handle);
    })
    .map_err(|e| e.to_string())
}

/// The drop target goes on once the notch's WebView has made its windows; asked again a little
/// later in case WebView2 made more after the first look.
pub fn start(app: AppHandle) {
    {
        let st = app.state::<crate::AppState>();
        let c = st.cfg.lock().unwrap();
        set_keep_copies(c.vault_keep_copies);
        set_clear_after(&c.vault_clear_after);
    }
    for delay in [0u64, 2, 10] {
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(delay));
            let handle = app.clone();
            let _ = app.run_on_main_thread(move || platform::register_drop_target(&handle));
        });
    }
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(60));
        let keep = match KEEP_FOR.load(Ordering::SeqCst) {
            0 => None,
            ms => Some(ms as i64),
        };
        let old = {
            let mut guard = store();
            let s = guard.get_or_insert_with(load);
            let old = s.expire(crate::media::now_ms(), keep);
            if !old.is_empty() {
                save(s);
            }
            old
        };
        if !old.is_empty() {
            old.iter().for_each(discard);
            changed(&app);
        }
    });
}

fn drag_state(app: &AppHandle, over: bool) {
    let _ = app.emit_to("notch", "vault_drag", over);
}

#[cfg(windows)]
mod platform {
    use super::{add_loose, add_paths, drag_state, Loose, ENABLED};
    use std::cell::Cell;
    use std::path::Path;
    use std::sync::atomic::Ordering;
    use tauri::AppHandle;
    use windows::core::{implement, w, Interface, HSTRING, PCWSTR};
    use windows::Win32::Foundation::{HGLOBAL, HWND, LPARAM, POINTL, BOOL};
    use windows::Win32::System::Com::{IDataObject, IStream, DVASPECT_CONTENT, FORMATETC, STGMEDIUM, TYMED_HGLOBAL, TYMED_ISTREAM};
    use windows::Win32::System::DataExchange::RegisterClipboardFormatW;
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::System::Ole::{
        IDropTarget, IDropTarget_Impl, RegisterDragDrop, ReleaseStgMedium, RevokeDragDrop, CF_HDROP, CF_UNICODETEXT,
        DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_MOVE, DROPEFFECT_NONE,
    };
    use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
    use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};
    use windows::Win32::UI::WindowsAndMessaging::EnumChildWindows;

    fn format(name: PCWSTR) -> u16 {
        unsafe { RegisterClipboardFormatW(name) as u16 }
    }

    fn etc(cf: u16, tymed: u32, index: i32) -> FORMATETC {
        FORMATETC { cfFormat: cf, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: index, tymed }
    }

    fn has(data: &IDataObject, cf: u16) -> bool {
        unsafe { data.QueryGetData(&etc(cf, (TYMED_HGLOBAL.0 | TYMED_ISTREAM.0) as u32, -1)) }.is_ok()
    }

    /// The bytes behind a format, from memory or a stream.
    fn bytes(data: &IDataObject, cf: u16, index: i32) -> Option<Vec<u8>> {
        unsafe {
            let mut medium: STGMEDIUM = data.GetData(&etc(cf, (TYMED_HGLOBAL.0 | TYMED_ISTREAM.0) as u32, index)).ok()?;
            let out = if medium.tymed == TYMED_HGLOBAL.0 as u32 {
                let mem: HGLOBAL = medium.u.hGlobal;
                let ptr = GlobalLock(mem) as *const u8;
                let v = if ptr.is_null() { None } else { Some(std::slice::from_raw_parts(ptr, GlobalSize(mem)).to_vec()) };
                let _ = GlobalUnlock(mem);
                v
            } else if medium.tymed == TYMED_ISTREAM.0 as u32 {
                let stream: Option<IStream> = (*medium.u.pstm).clone();
                stream.map(|s| {
                    let mut all = Vec::new();
                    let mut buf = vec![0u8; 64 * 1024];
                    loop {
                        let mut read = 0u32;
                        let hr = s.Read(buf.as_mut_ptr() as *mut _, buf.len() as u32, Some(&mut read));
                        if read > 0 {
                            all.extend_from_slice(&buf[..read as usize]);
                        }
                        if hr.is_err() || read == 0 || all.len() > 512 * 1024 * 1024 {
                            break;
                        }
                    }
                    all
                })
            } else {
                None
            };
            ReleaseStgMedium(&mut medium);
            out
        }
    }

    fn wide_text(bytes: &[u8]) -> String {
        let units: Vec<u16> = bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|u| *u != 0).collect();
        String::from_utf16_lossy(&units)
    }

    fn files(data: &IDataObject) -> Vec<String> {
        unsafe {
            let Ok(mut medium) = data.GetData(&etc(CF_HDROP.0, TYMED_HGLOBAL.0 as u32, -1)) else { return Vec::new() };
            let drop = HDROP(medium.u.hGlobal.0);
            let count = DragQueryFileW(drop, u32::MAX, None);
            let mut out = Vec::new();
            for i in 0..count {
                let len = DragQueryFileW(drop, i, None) as usize;
                let mut buf = vec![0u16; len + 1];
                let got = DragQueryFileW(drop, i, Some(&mut buf)) as usize;
                out.push(String::from_utf16_lossy(&buf[..got]));
            }
            ReleaseStgMedium(&mut medium);
            out
        }
    }

    /// Files offered by their contents (FileGroupDescriptorW + FileContents).
    fn virtual_files(data: &IDataObject) -> Vec<Loose> {
        use windows::Win32::UI::Shell::{FILEDESCRIPTORW, FILEGROUPDESCRIPTORW};
        let group = format(w!("FileGroupDescriptorW"));
        let contents = format(w!("FileContents"));
        let Some(raw) = bytes(data, group, -1) else { return Vec::new() };
        if raw.len() < 4 {
            return Vec::new();
        }
        let count = u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]) as usize;
        let size = std::mem::size_of::<FILEDESCRIPTORW>();
        let first = std::mem::offset_of!(FILEGROUPDESCRIPTORW, fgd);
        let mut out = Vec::new();
        for i in 0..count.min(64) {
            let at = first + i * size;
            if at + size > raw.len() {
                break;
            }
            let fd: FILEDESCRIPTORW = unsafe { std::ptr::read_unaligned(raw[at..].as_ptr() as *const FILEDESCRIPTORW) };
            // The struct is packed, so its fields are copied out rather than borrowed.
            let (flags, attributes, file_name) = (fd.dwFlags, fd.dwFileAttributes, fd.cFileName);
            // FILE_ATTRIBUTE_DIRECTORY, when the attributes are said to be valid (FD_ATTRIBUTES)
            if flags & 0x4 != 0 && attributes & 0x10 != 0 {
                continue;
            }
            let name_len = file_name.iter().position(|c| *c == 0).unwrap_or(file_name.len());
            let name = String::from_utf16_lossy(&file_name[..name_len]);
            let name = name.rsplit(['\\', '/']).next().unwrap_or(&name).to_string();
            if let Some(b) = bytes(data, contents, i as i32) {
                out.push(Loose::Named(name, b));
            }
        }
        out
    }

    /// What the Vault can take from a drag: files, then file contents, a picture, a link, text.
    fn supported(data: &IDataObject) -> bool {
        has(data, CF_HDROP.0)
            || has(data, format(w!("FileGroupDescriptorW")))
            || has(data, format(w!("PNG")))
            || has(data, format(w!("UniformResourceLocatorW")))
            || has(data, CF_UNICODETEXT.0)
    }

    fn take(app: &AppHandle, data: &IDataObject) {
        let paths = files(data);
        if !paths.is_empty() {
            return add_paths(app, paths);
        }
        let mut loose = virtual_files(data);
        if loose.is_empty() {
            if let Some(png) = bytes(data, format(w!("PNG")), -1).filter(|b| b.starts_with(b"\x89PNG")) {
                loose.push(Loose::Png(png));
            } else if let Some(url) = bytes(data, format(w!("UniformResourceLocatorW")), -1).map(|b| wide_text(&b)) {
                let url = url.trim().to_string();
                if crate::shell::is_web_link(&url) {
                    loose.push(Loose::Link(url));
                }
            }
        }
        if loose.is_empty() {
            if let Some(text) = bytes(data, CF_UNICODETEXT.0, -1).map(|b| wide_text(&b)) {
                let t = text.trim();
                if crate::shell::is_web_link(t) {
                    loose.push(Loose::Link(t.to_string()));
                } else if !t.is_empty() {
                    loose.push(Loose::Text(text));
                }
            }
        }
        add_loose(app, loose);
    }

    #[implement(IDropTarget)]
    struct VaultDrop {
        app: AppHandle,
        accepts: Cell<bool>,
    }

    impl IDropTarget_Impl for VaultDrop_Impl {
        fn DragEnter(&self, data: Option<&IDataObject>, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
            let ok = ENABLED.load(Ordering::SeqCst) && data.is_some_and(supported);
            self.accepts.set(ok);
            unsafe { *effect = if ok { DROPEFFECT_COPY } else { DROPEFFECT_NONE } };
            if ok {
                drag_state(&self.app, true);
            }
            Ok(())
        }

        fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
            unsafe { *effect = if self.accepts.get() { DROPEFFECT_COPY } else { DROPEFFECT_NONE } };
            Ok(())
        }

        fn DragLeave(&self) -> windows::core::Result<()> {
            if self.accepts.replace(false) {
                drag_state(&self.app, false);
            }
            Ok(())
        }

        fn Drop(&self, data: Option<&IDataObject>, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
            let ok = self.accepts.replace(false);
            unsafe { *effect = if ok { DROPEFFECT_COPY } else { DROPEFFECT_NONE } };
            if ok {
                if let Some(data) = data {
                    take(&self.app, data);
                }
                drag_state(&self.app, false);
            }
            Ok(())
        }
    }

    /// Puts the Vault's drop target on the notch window and every window WebView2 made inside it,
    /// in place of wry's, which only ever reads files.
    pub fn register_drop_target(app: &AppHandle) {
        use tauri::Manager;
        let Some(win) = app.get_webview_window("notch") else { return };
        let Ok(hwnd) = win.hwnd() else { return };
        let target: IDropTarget = VaultDrop { app: app.clone(), accepts: Cell::new(false) }.into();
        unsafe extern "system" fn each(child: HWND, lparam: LPARAM) -> BOOL {
            let target = &*(lparam.0 as *const IDropTarget);
            let _ = RevokeDragDrop(child);
            let _ = RegisterDragDrop(child, target);
            BOOL(1)
        }
        unsafe {
            let parent = HWND(hwnd.0 as _);
            let _ = RevokeDragDrop(parent);
            let _ = RegisterDragDrop(parent, &target);
            let _ = EnumChildWindows(parent, Some(each), LPARAM(&target as *const IDropTarget as isize));
        }
    }

    /// Drags files out with the shell's own data object, as a copy unless Shift asks for a move.
    pub fn drag_out(win: &tauri::WebviewWindow, paths: &[String]) -> Result<(), String> {
        use windows::Win32::System::Ole::IDropSource;
        use windows::Win32::UI::Shell::Common::ITEMIDLIST;
        use windows::Win32::UI::Shell::{
            IShellItemArray, ILCreateFromPathW, ILFree, SHCreateShellItemArrayFromIDLists, SHDoDragDrop, BHID_DataObject,
        };
        let hwnd = win.hwnd().map_err(|e| e.to_string())?;
        unsafe {
            let pidls: Vec<*mut ITEMIDLIST> = paths
                .iter()
                .map(|p| ILCreateFromPathW(&HSTRING::from(p.as_str())))
                .filter(|p| !p.is_null())
                .collect();
            if pidls.is_empty() {
                return Err("the files could not be found".into());
            }
            let consts: Vec<*const ITEMIDLIST> = pidls.iter().map(|p| *p as *const _).collect();
            let result = (|| -> windows::core::Result<()> {
                let array: IShellItemArray = SHCreateShellItemArrayFromIDLists(&consts)?;
                let data: IDataObject = array.BindToHandler(None, &BHID_DataObject)?;
                set_preferred_effect(&data, DROPEFFECT_COPY);
                let _ = SHDoDragDrop(HWND(hwnd.0 as _), &data, None::<&IDropSource>, DROPEFFECT_COPY | DROPEFFECT_MOVE)?;
                Ok(())
            })();
            for p in pidls {
                ILFree(Some(p as *const _));
            }
            result.map_err(|e| e.to_string())
        }
    }

    /// Explorer copies a drop whose data says it prefers a copy, unless Shift or Ctrl say otherwise.
    fn set_preferred_effect(data: &IDataObject, effect: DROPEFFECT) {
        unsafe {
            let Ok(mem) = GlobalAlloc(GMEM_MOVEABLE, 4) else { return };
            let ptr = GlobalLock(mem) as *mut u32;
            if ptr.is_null() {
                return;
            }
            *ptr = effect.0;
            let _ = GlobalUnlock(mem);
            let medium = STGMEDIUM {
                tymed: TYMED_HGLOBAL.0 as u32,
                u: windows::Win32::System::Com::STGMEDIUM_0 { hGlobal: mem },
                pUnkForRelease: std::mem::ManuallyDrop::new(None),
            };
            let _ = data.SetData(&etc(format(w!("Preferred DropEffect")), TYMED_HGLOBAL.0 as u32, -1), &medium, true);
        }
    }

    /// The file's icon from the shell — by its type alone when it is missing.
    pub fn icon(path: &Path, is_dir: bool, missing: bool) -> Option<String> {
        use windows::Win32::Storage::FileSystem::{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, FILE_FLAGS_AND_ATTRIBUTES};
        use windows::Win32::UI::Shell::{SHGetFileInfoW, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON, SHGFI_USEFILEATTRIBUTES};
        use windows::Win32::UI::WindowsAndMessaging::DestroyIcon;
        let mut info = SHFILEINFOW::default();
        let mut flags = SHGFI_ICON | SHGFI_LARGEICON;
        let mut attrs = FILE_FLAGS_AND_ATTRIBUTES(0);
        if missing {
            flags |= SHGFI_USEFILEATTRIBUTES;
            attrs = if is_dir { FILE_ATTRIBUTE_DIRECTORY } else { FILE_ATTRIBUTE_NORMAL };
        }
        unsafe {
            let ok = SHGetFileInfoW(
                &HSTRING::from(path.to_string_lossy().as_ref()),
                attrs,
                Some(&mut info),
                std::mem::size_of::<SHFILEINFOW>() as u32,
                flags,
            );
            if ok == 0 || info.hIcon.is_invalid() {
                return None;
            }
            let url = crate::glyphs::icon_png_url(info.hIcon);
            let _ = DestroyIcon(info.hIcon);
            url
        }
    }

    /// To the Recycle Bin, silently.
    pub fn recycle(path: &str) {
        use windows::Win32::UI::Shell::{SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW};
        let mut from: Vec<u16> = path.encode_utf16().collect();
        from.extend([0, 0]); // double-ended list
        let mut op = SHFILEOPSTRUCTW {
            wFunc: FO_DELETE,
            pFrom: PCWSTR(from.as_ptr()),
            fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI).0 as u16,
            ..Default::default()
        };
        unsafe {
            let _ = SHFileOperationW(&mut op);
        }
    }

    thread_local! {
        static SHARE: std::cell::RefCell<Option<(windows::ApplicationModel::DataTransfer::DataTransferManager, i64)>> =
            const { std::cell::RefCell::new(None) };
    }

    /// Windows' Share panel, for files: they are read as storage items first, off the main thread,
    /// then handed over when the panel asks.
    pub fn share(app: &AppHandle, paths: Vec<String>) -> Result<(), String> {
        use tauri::Manager;
        use windows::ApplicationModel::DataTransfer::{DataRequestedEventArgs, DataTransferManager};
        use windows::Foundation::Collections::IIterable;
        use windows::Foundation::TypedEventHandler;
        use windows::Storage::{IStorageItem, StorageFile, StorageFolder};
        use windows::Win32::UI::Shell::IDataTransferManagerInterop;

        // Agile references: the panel asks for the items on the main thread, and they are read here.
        let mut items: Vec<windows_core::AgileReference<IStorageItem>> = Vec::new();
        for p in &paths {
            let h = HSTRING::from(p.as_str());
            let item: Option<IStorageItem> = if Path::new(p).is_dir() {
                StorageFolder::GetFolderFromPathAsync(&h).and_then(|op| op.get()).and_then(|f| f.cast()).ok()
            } else {
                StorageFile::GetFileFromPathAsync(&h).and_then(|op| op.get()).and_then(|f| f.cast()).ok()
            };
            if let Some(agile) = item.and_then(|i| windows_core::AgileReference::new(&i).ok()) {
                items.push(agile);
            }
        }
        if items.is_empty() {
            return Err("those files could not be shared".into());
        }
        let count = items.len();
        let win = app.get_webview_window("notch").ok_or("no notch window")?;
        let hwnd = win.hwnd().map_err(|e| e.to_string())?.0 as isize;
        let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();
        app.run_on_main_thread(move || {
            let result = (|| -> windows::core::Result<()> {
                let interop = windows::core::factory::<DataTransferManager, IDataTransferManagerInterop>()?;
                let hwnd = HWND(hwnd as _);
                let manager: DataTransferManager = unsafe { interop.GetForWindow(hwnd)? };
                SHARE.with(|s| {
                    if let Some((m, token)) = s.borrow_mut().take() {
                        let _ = m.RemoveDataRequested(windows::Foundation::EventRegistrationToken { Value: token });
                    }
                });
                let token = manager.DataRequested(&TypedEventHandler::new(
                    move |_, args: &Option<DataRequestedEventArgs>| {
                        let Some(args) = args.as_ref() else { return Ok(()) };
                        let data = args.Request()?.Data()?;
                        data.Properties()?.SetTitle(&HSTRING::from(if count == 1 { "1 item from the Vault".to_string() } else { format!("{count} items from the Vault") }))?;
                        let resolved: Vec<Option<IStorageItem>> = items.iter().map(|a| a.resolve().ok()).collect();
                        let list: IIterable<IStorageItem> = resolved.try_into()?;
                        data.SetStorageItemsReadOnly(&list)?;
                        Ok(())
                    },
                ))?;
                SHARE.with(|s| *s.borrow_mut() = Some((manager, token.Value)));
                unsafe { interop.ShowShareUIForWindow(hwnd) }
            })();
            let _ = tx.send(result.map_err(|e| e.to_string()));
        })
        .map_err(|e| e.to_string())?;
        rx.recv_timeout(std::time::Duration::from_secs(10)).unwrap_or(Err("the Share panel did not answer".into()))
    }
}

/// Elsewhere (the Linux build CI runs) there is no shell to drag with; the store still works.
#[cfg(not(windows))]
mod platform {
    use std::path::Path;
    use tauri::AppHandle;

    pub fn register_drop_target(_app: &AppHandle) {}
    pub fn drag_out(_win: &tauri::WebviewWindow, _paths: &[String]) -> Result<(), String> {
        Err("dragging out needs Windows".into())
    }
    pub fn icon(_path: &Path, _is_dir: bool, _missing: bool) -> Option<String> {
        None
    }
    pub fn recycle(path: &str) {
        let p = Path::new(path);
        let _ = if p.is_dir() { std::fs::remove_dir_all(p) } else { std::fs::remove_file(p) };
    }
    pub fn share(_app: &AppHandle, _paths: Vec<String>) -> Result<(), String> {
        Err("sharing needs Windows".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temporary_places_are_recognised() {
        let roots = vec!["c:\\users\\me\\appdata\\local\\temp".to_string()];
        assert!(is_temporary("C:\\Users\\me\\AppData\\Local\\Temp\\screenshot.png", &roots));
        assert!(is_temporary("C:/Users/me/AppData/Local/Temp/x/y.txt", &roots));
        assert!(is_temporary("C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\INetCache\\Content.Outlook\\AB12\\invoice.pdf", &roots));
        assert!(is_temporary("C:\\Users\\me\\Downloads\\a1b2.tmp", &roots));
        assert!(!is_temporary("C:\\Users\\me\\Documents\\report.pdf", &roots));
        assert!(!is_temporary("C:\\Users\\me\\AppData\\Local\\Tempest\\file.txt", &roots), "a folder that only starts with the name");
    }

    #[test]
    fn the_store_dedupes_and_keeps_ids() {
        let mut s = Store::default();
        let a = s.add("C:\\a.txt".into(), false, 1);
        let b = s.add("C:\\b.txt".into(), false, 2);
        assert_ne!(a, b);
        let again = s.add("c:\\A.TXT".into(), false, 3);
        assert_eq!(again, a, "the same path, however it is cased, is the same item");
        assert_eq!(s.items().len(), 2);
        assert_eq!(s.items()[0].path, "C:\\a.txt", "and it moves to the top");
        let saved = s.items().to_vec();
        let mut back = Store::from_saved(saved);
        let c = back.add("C:\\c.txt".into(), true, 4);
        assert!(c > a && c > b);
        assert!(back.remove(a).is_some());
        assert!(!back.contains_path("C:\\a.txt"));
    }

    #[test]
    fn items_expire_after_the_chosen_time() {
        let mut s = Store::default();
        s.add("C:\\old.txt".into(), false, 0);
        s.add("C:\\new.txt".into(), false, 3_000_000);
        assert!(s.expire(3_700_000, None).is_empty(), "never");
        let gone = s.expire(3_700_000, keep_for_ms("1h"));
        assert_eq!(gone.len(), 1);
        assert_eq!(gone[0].path, "C:\\old.txt");
        assert_eq!(s.items().len(), 1);
        assert_eq!(keep_for_ms("1w"), Some(604_800_000));
        assert_eq!(keep_for_ms("never"), None);
    }

    #[test]
    fn details_and_names() {
        assert_eq!(detail_of(Some(2_400_000), false, false), "2.4 MB");
        assert_eq!(detail_of(None, true, false), "Folder");
        assert_eq!(detail_of(Some(1), false, true), "Missing");
        let dir = std::env::temp_dir().join(format!("notchdeck-vault-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let first = unique_name(&dir, "notes.txt");
        assert_eq!(first.file_name().unwrap(), "notes.txt");
        std::fs::write(&first, "x").unwrap();
        assert_eq!(unique_name(&dir, "notes.txt").file_name().unwrap(), "notes (2).txt");
        assert_eq!(unique_name(&dir, "a:b?.txt").file_name().unwrap(), "a_b_.txt");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn loose_drops_become_files() {
        let (name, bytes) = file_for(&Loose::Link("https://example.com/a/b?c".into()), "s");
        assert_eq!(name, "example.com.url");
        assert_eq!(String::from_utf8(bytes).unwrap(), "[InternetShortcut]\r\nURL=https://example.com/a/b?c\r\n");
        let (name, _) = file_for(&Loose::Text("\n  Shopping list\nmilk".into()), "2026-10-20 11.06.12");
        assert_eq!(name, "Shopping list 2026-10-20 11.06.12.txt");
        let (name, _) = file_for(&Loose::Png(vec![1]), "s");
        assert_eq!(name, "Image s.png");
    }

    #[test]
    fn a_zip_holds_files_and_folders() {
        let dir = std::env::temp_dir().join(format!("notchdeck-zip-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("folder/inner")).unwrap();
        std::fs::write(dir.join("one.txt"), "hello").unwrap();
        std::fs::write(dir.join("folder/inner/two.txt"), "world").unwrap();
        let target = dir.join("out.zip");
        write_zip(&target, &[dir.join("one.txt"), dir.join("folder")]).unwrap();
        let mut zip = zip::ZipArchive::new(std::fs::File::open(&target).unwrap()).unwrap();
        let names: Vec<String> = (0..zip.len()).map(|i| zip.by_index(i).unwrap().name().to_string()).collect();
        assert!(names.contains(&"one.txt".to_string()), "{names:?}");
        assert!(names.contains(&"folder/inner/two.txt".to_string()), "{names:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
