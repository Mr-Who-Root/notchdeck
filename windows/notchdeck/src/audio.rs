//! Now Playing's volume row — the Mac's `AudioOutput`: the default output's volume and mute, the
//! outputs there are, and switching between them.
//!
//! The volume is IAudioEndpointVolume on the default render endpoint, read once a second while the
//! Now Playing cell is on so the slider follows the keyboard's volume keys. Windows has no public way
//! to change the default output; every switcher (the volume flyout's own included) goes through
//! IPolicyConfig, an interface Windows has kept stable since Windows 7, so that is what this uses.

use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub default: bool,
}

#[derive(Clone, Serialize, PartialEq, Debug, Default)]
pub struct Audio {
    /// false = no output to control (no sound device, or the read failed).
    pub available: bool,
    /// 0–100.
    pub volume: u32,
    pub muted: bool,
    pub devices: Vec<Device>,
}

/// The endpoint's 0.0–1.0 as the slider's 0–100.
pub fn percent(scalar: f32) -> u32 {
    if !scalar.is_finite() {
        return 0;
    }
    (scalar.clamp(0.0, 1.0) * 100.0).round() as u32
}

pub fn scalar(percent: u32) -> f32 {
    percent.min(100) as f32 / 100.0
}

static ENABLED: AtomicBool = AtomicBool::new(false);
static POKED: AtomicBool = AtomicBool::new(false);
static STATE: Mutex<Option<Audio>> = Mutex::new(None);

pub fn set_enabled(app: &AppHandle, on: bool) {
    let was = ENABLED.swap(on, Ordering::SeqCst);
    if was && !on {
        *STATE.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let _ = app.emit("audio", Audio::default());
    }
    if on && !was {
        POKED.store(true, Ordering::SeqCst);
    }
}

#[tauri::command]
pub fn get_audio() -> Audio {
    STATE.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or_default()
}

/// Each change runs on a thread of its own with COM set up for it, and the next reading confirms it.
fn act(what: &'static str, f: impl FnOnce() -> Result<(), String> + Send + 'static) {
    std::thread::spawn(move || {
        platform::init();
        if let Err(e) = f() {
            crate::applog(&format!("audio: {what} failed ({e})"));
        }
        POKED.store(true, Ordering::SeqCst);
    });
}

#[tauri::command]
pub fn set_volume(volume: u32) {
    act("set volume", move || platform::set_volume(scalar(volume)));
}

#[tauri::command]
pub fn set_muted(muted: bool) {
    act("set mute", move || platform::set_muted(muted));
}

/// Makes `id` the default output for everything: music, calls and system sounds alike.
#[tauri::command]
pub fn set_output(id: String) -> Result<(), String> {
    if id.is_empty() {
        return Err("no output chosen".into());
    }
    act("switch output", move || platform::set_default(&id));
    Ok(())
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        crate::activity::lower_thread_priority();
        platform::init();
        let mut tick = 0u32;
        let mut devices: Vec<Device> = Vec::new();
        loop {
            let poked = POKED.swap(false, Ordering::SeqCst);
            if ENABLED.load(Ordering::SeqCst) {
                // The list of outputs changes rarely; it is read every five seconds, or after a switch.
                if poked || tick % 5 == 0 || devices.is_empty() {
                    devices = platform::devices().unwrap_or_default();
                }
                let next = match platform::volume() {
                    Ok((v, muted)) => Audio { available: true, volume: percent(v), muted, devices: devices.clone() },
                    Err(_) => Audio { devices: devices.clone(), ..Audio::default() },
                };
                let changed = {
                    let mut current = STATE.lock().unwrap_or_else(|e| e.into_inner());
                    let changed = current.as_ref() != Some(&next);
                    *current = Some(next.clone());
                    changed
                };
                if changed {
                    let _ = app.emit("audio", &next);
                }
            }
            tick = tick.wrapping_add(1);
            for _ in 0..4 {
                std::thread::sleep(Duration::from_millis(250));
                if POKED.load(Ordering::SeqCst) {
                    break;
                }
            }
        }
    });
}

// The COM interface keeps Windows' own method names, as the windows crate's do.
#[cfg(windows)]
#[allow(non_snake_case)]
mod platform {
    use super::Device;
    use std::ffi::c_void;
    use windows::core::{interface, IUnknown, IUnknown_Vtbl, GUID, HRESULT, PCWSTR};
    use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{
        eCommunications, eConsole, eMultimedia, eRender, ERole, IMMDevice, IMMDeviceEnumerator, MMDeviceEnumerator,
        DEVICE_STATE_ACTIVE,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED, STGM_READ};

    /// Windows' own default-output switcher: IPolicyConfig, CPolicyConfigClient's interface since
    /// Windows 7. Only SetDefaultEndpoint is called; the others are declared to keep the vtable in order.
    #[interface("f8679f50-850a-41cf-9c72-430f290290c8")]
    unsafe trait IPolicyConfig: IUnknown {
        fn GetMixFormat(&self, device: PCWSTR, format: *mut *mut c_void) -> HRESULT;
        fn GetDeviceFormat(&self, device: PCWSTR, default: i32, format: *mut *mut c_void) -> HRESULT;
        fn ResetDeviceFormat(&self, device: PCWSTR) -> HRESULT;
        fn SetDeviceFormat(&self, device: PCWSTR, endpoint: *mut c_void, mix: *mut c_void) -> HRESULT;
        fn GetProcessingPeriod(&self, device: PCWSTR, default: i32, period: *mut i64, minimum: *mut i64) -> HRESULT;
        fn SetProcessingPeriod(&self, device: PCWSTR, period: *mut i64) -> HRESULT;
        fn GetShareMode(&self, device: PCWSTR, mode: *mut c_void) -> HRESULT;
        fn SetShareMode(&self, device: PCWSTR, mode: *mut c_void) -> HRESULT;
        fn GetPropertyValue(&self, device: PCWSTR, key: *const c_void, value: *mut c_void) -> HRESULT;
        fn SetPropertyValue(&self, device: PCWSTR, key: *const c_void, value: *mut c_void) -> HRESULT;
        fn SetDefaultEndpoint(&self, device: PCWSTR, role: ERole) -> HRESULT;
        fn SetEndpointVisibility(&self, device: PCWSTR, visible: i32) -> HRESULT;
    }

    const CLSID_POLICY_CONFIG: GUID = GUID::from_u128(0x870af99c_171d_4f9e_af0d_e63df40c2bc9);

    pub fn init() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn enumerator() -> windows::core::Result<IMMDeviceEnumerator> {
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
    }

    fn default_device() -> windows::core::Result<IMMDevice> {
        unsafe { enumerator()?.GetDefaultAudioEndpoint(eRender, eConsole) }
    }

    fn endpoint() -> windows::core::Result<IAudioEndpointVolume> {
        unsafe { default_device()?.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None) }
    }

    fn id_of(device: &IMMDevice) -> windows::core::Result<String> {
        unsafe {
            let raw = device.GetId()?;
            let id = raw.to_string().unwrap_or_default();
            CoTaskMemFree(Some(raw.0 as *const c_void));
            Ok(id)
        }
    }

    pub fn volume() -> Result<(f32, bool), String> {
        let ep = endpoint().map_err(|e| e.to_string())?;
        unsafe {
            let v = ep.GetMasterVolumeLevelScalar().map_err(|e| e.to_string())?;
            let muted = ep.GetMute().map_err(|e| e.to_string())?.as_bool();
            Ok((v, muted))
        }
    }

    pub fn set_volume(v: f32) -> Result<(), String> {
        let ep = endpoint().map_err(|e| e.to_string())?;
        unsafe {
            ep.SetMasterVolumeLevelScalar(v, std::ptr::null()).map_err(|e| e.to_string())?;
            // Turning it up from muted unmutes, as the volume keys do
            if v > 0.0 {
                let _ = ep.SetMute(false, std::ptr::null());
            }
        }
        Ok(())
    }

    pub fn set_muted(muted: bool) -> Result<(), String> {
        let ep = endpoint().map_err(|e| e.to_string())?;
        unsafe { ep.SetMute(muted, std::ptr::null()).map_err(|e| e.to_string()) }
    }

    pub fn devices() -> Result<Vec<Device>, String> {
        let err = |e: windows::core::Error| e.to_string();
        unsafe {
            let en = enumerator().map_err(err)?;
            let default = en.GetDefaultAudioEndpoint(eRender, eConsole).ok().and_then(|d| id_of(&d).ok()).unwrap_or_default();
            let list = en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE).map_err(err)?;
            let mut out = Vec::new();
            for i in 0..list.GetCount().map_err(err)? {
                let Ok(device) = list.Item(i) else { continue };
                let Ok(id) = id_of(&device) else { continue };
                let name = device
                    .OpenPropertyStore(STGM_READ)
                    .and_then(|store| store.GetValue(&PKEY_Device_FriendlyName))
                    .map(|v| v.to_string())
                    .unwrap_or_default();
                out.push(Device { default: id == default, name: if name.is_empty() { "Output".into() } else { name }, id });
            }
            out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            Ok(out)
        }
    }

    pub fn set_default(id: &str) -> Result<(), String> {
        let wide: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let policy: IPolicyConfig = CoCreateInstance(&CLSID_POLICY_CONFIG, None, CLSCTX_ALL).map_err(|e| e.to_string())?;
            for role in [eConsole, eMultimedia, eCommunications] {
                policy.SetDefaultEndpoint(PCWSTR(wide.as_ptr()), role).ok().map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
}

/// Elsewhere there is no output to read: the row is not shown.
#[cfg(not(windows))]
mod platform {
    use super::Device;

    pub fn init() {}
    pub fn volume() -> Result<(f32, bool), String> {
        Err("no audio here".into())
    }
    pub fn set_volume(_v: f32) -> Result<(), String> {
        Ok(())
    }
    pub fn set_muted(_m: bool) -> Result<(), String> {
        Ok(())
    }
    pub fn devices() -> Result<Vec<Device>, String> {
        Ok(Vec::new())
    }
    pub fn set_default(_id: &str) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{percent, scalar};

    #[test]
    fn the_endpoint_scale_and_the_slider_agree() {
        assert_eq!(percent(0.0), 0);
        assert_eq!(percent(0.555), 56);
        assert_eq!(percent(1.0), 100);
        assert_eq!(percent(1.7), 100);
        assert_eq!(percent(f32::NAN), 0);
        assert_eq!(scalar(50), 0.5);
        assert_eq!(scalar(250), 1.0);
        for p in 0..=100 {
            assert_eq!(percent(scalar(p)), p, "a slider value survives the round trip");
        }
    }
}
