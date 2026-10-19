//! Check published Windows releases, then use a signed Tauri update when one exists.
//! Until signing is configured, Settings links to the release's installer instead.
//!
//! Which GitHub repository publishes the releases is fixed at build time by the
//! `NOTCHDECK_UPDATE_REPO` environment variable (`owner/name`; the release
//! workflow passes `github.repository`). A build without it never checks.

use semver::Version;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tauri_plugin_updater::UpdaterExt;

const UPDATE_REPO: Option<&str> = option_env!("NOTCHDECK_UPDATE_REPO");
const NOT_CONFIGURED: &str = "Automatic updates aren't set up for this build";

/// `owner/name`, or nothing when the value could not name a repository.
fn update_repo(raw: Option<&str>) -> Option<&str> {
    let repo = raw?.trim();
    let (owner, name) = repo.split_once('/')?;
    let ok = |part: &str| {
        !part.is_empty()
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    (ok(owner) && ok(name)).then_some(repo)
}

#[derive(Serialize)]
pub struct ProjectLinks {
    pub repo: Option<String>,
    pub version: String,
}

/// The repository this build checks for updates, for Settings' links.
#[tauri::command]
pub fn get_project_links() -> ProjectLinks {
    ProjectLinks {
        repo: update_repo(UPDATE_REPO).map(str::to_string),
        version: env!("CARGO_PKG_VERSION").to_string(),
    }
}

/// `repo` or `release` (this version's notes). The page never supplies a URL.
fn project_page(repo: &str, page: &str, version: &str) -> Option<String> {
    match page {
        "repo" => Some(format!("https://github.com/{repo}")),
        "release" => Some(format!("https://github.com/{repo}/releases/tag/v{version}")),
        _ => None,
    }
}

#[tauri::command]
pub fn open_project_page(page: String) -> Result<(), String> {
    let repo = update_repo(UPDATE_REPO).ok_or(NOT_CONFIGURED)?;
    let url = project_page(repo, &page, env!("CARGO_PKG_VERSION")).ok_or("unknown page")?;
    let mut command = std::process::Command::new("cmd");
    command.args(["/C", "start", "", &url]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    command.spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn release_api(repo: &str) -> String {
    format!("https://api.github.com/repos/{repo}/releases/latest")
}
const INSTALLER_NAME: &str = "NotchDeck-Setup.exe";
const UNSET_PUBKEY: &str = "REPLACE_WITH_TAURI_PUBLIC_KEY";
const CHECK_ERROR: &str = "Could not check for updates";
const INSTALL_ERROR: &str = "Could not install the update";

#[derive(Clone, Serialize, Default)]
pub struct UpdateState {
    pub available: Option<String>,
    pub checking: bool,
    pub installing: bool,
    /// An unchecked build must not claim to be up to date.
    pub checked: bool,
    /// Tauri found a signed feed for this exact release.
    pub can_install: bool,
    pub message: Option<String>,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    assets: Vec<GithubAsset>,
}

#[derive(Deserialize)]
struct GithubAsset {
    name: String,
}

static STATE: Mutex<Option<UpdateState>> = Mutex::new(None);

fn state() -> std::sync::MutexGuard<'static, Option<UpdateState>> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

fn set(app: &AppHandle, next: UpdateState) {
    *state() = Some(next.clone());
    let _ = app.emit("update_state", &next);
}

#[tauri::command]
pub fn get_update_state() -> UpdateState {
    state().clone().unwrap_or_default()
}

fn configured(app: &AppHandle) -> bool {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .is_some_and(|k| !k.is_empty() && k != UNSET_PUBKEY)
}

/// A Mac-only release cannot be advertised as a Windows update.
fn newer_windows_release(body: &str, current: &Version) -> Result<Option<Version>, String> {
    let release: GithubRelease = serde_json::from_str(body).map_err(|e| e.to_string())?;
    let tag = release
        .tag_name
        .strip_prefix('v')
        .ok_or("release tag has no v prefix")?;
    let version = Version::parse(tag).map_err(|e| e.to_string())?;
    if !release
        .assets
        .iter()
        .any(|asset| asset.name == INSTALLER_NAME)
    {
        return Err(format!(
            "release {} has no Windows installer",
            release.tag_name
        ));
    }
    Ok((version > *current).then_some(version))
}

fn latest_windows_release(repo: &str, current: &Version) -> Result<Option<Version>, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(12))
        .build();
    let body = agent
        .get(&release_api(repo))
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "NotchDeck-Windows")
        .call()
        .map_err(|e| e.to_string())?
        .into_string()
        .map_err(|e| e.to_string())?;
    newer_windows_release(&body, current)
}

fn signed_offer_matches(release: &Version, signed: &str) -> bool {
    Version::parse(signed).is_ok_and(|version| version == *release)
}

fn newer_signed_release(signed: &str, current: &Version) -> Option<Version> {
    Version::parse(signed)
        .ok()
        .filter(|version| version > current)
}

fn signed_feed_offer(app: &AppHandle) -> Option<String> {
    match tauri::async_runtime::block_on(async { app.updater()?.check().await }) {
        Ok(Some(update)) => Some(update.version),
        Ok(None) => None,
        Err(e) => {
            crate::applog(&format!("updater: signed feed unavailable ({e})"));
            None
        }
    }
}

/// Returns immediately; release and signed-feed checks happen off the UI thread.
#[tauri::command]
pub fn check_for_update(app: AppHandle) {
    if state().as_ref().is_some_and(|s| s.checking || s.installing) {
        return;
    }
    let Some(repo) = update_repo(UPDATE_REPO) else {
        set(
            &app,
            UpdateState {
                message: Some(NOT_CONFIGURED.into()),
                ..Default::default()
            },
        );
        return;
    };
    set(
        &app,
        UpdateState {
            checking: true,
            ..Default::default()
        },
    );
    std::thread::spawn(move || {
        let current = match Version::parse(env!("CARGO_PKG_VERSION")) {
            Ok(version) => version,
            Err(e) => {
                crate::applog(&format!("updater: invalid installed version ({e})"));
                set(
                    &app,
                    UpdateState {
                        message: Some(CHECK_ERROR.into()),
                        ..Default::default()
                    },
                );
                return;
            }
        };
        match latest_windows_release(repo, &current) {
            Ok(Some(version)) => {
                let can_install = configured(&app)
                    && signed_feed_offer(&app)
                        .is_some_and(|signed| signed_offer_matches(&version, &signed));
                crate::applog(&format!(
                    "updater: {version} available (signed={can_install})"
                ));
                set(
                    &app,
                    UpdateState {
                        available: Some(version.to_string()),
                        checked: true,
                        can_install,
                        ..Default::default()
                    },
                );
            }
            Ok(None) => {
                crate::applog("updater: this is the newest Windows release");
                set(
                    &app,
                    UpdateState {
                        checked: true,
                        ..Default::default()
                    },
                );
            }
            Err(e) => {
                crate::applog(&format!("updater: release check failed ({e})"));
                // A working signed feed can still update a build when GitHub's
                // release API is unavailable or rate limited.
                let signed = configured(&app)
                    .then(|| signed_feed_offer(&app))
                    .flatten()
                    .and_then(|offer| newer_signed_release(&offer, &current));
                if let Some(version) = signed {
                    set(
                        &app,
                        UpdateState {
                            available: Some(version.to_string()),
                            checked: true,
                            can_install: true,
                            ..Default::default()
                        },
                    );
                } else {
                    set(
                        &app,
                        UpdateState {
                            message: Some(CHECK_ERROR.into()),
                            ..Default::default()
                        },
                    );
                }
            }
        }
    });
}

/// Open only the GitHub asset named by a successful release check. The webview
/// supplies neither the version nor a URL.
#[tauri::command]
pub fn open_update_installer() -> Result<(), String> {
    let version = {
        let current = state();
        let offer = current.as_ref().ok_or("No update has been checked")?;
        if offer.checking || offer.installing || offer.can_install {
            return Err("No manual installer is available".into());
        }
        offer
            .available
            .clone()
            .ok_or("No Windows update is available")?
    };
    let version = Version::parse(&version).map_err(|e| e.to_string())?;
    let repo = update_repo(UPDATE_REPO).ok_or(NOT_CONFIGURED)?;
    let url = format!("https://github.com/{repo}/releases/download/v{version}/{INSTALLER_NAME}");
    let mut command = std::process::Command::new("cmd");
    command.args(["/C", "start", "", &url]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    command.spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Install only an offer previously found in a signed Tauri feed.
#[tauri::command]
pub fn install_update(app: AppHandle) {
    let offered = {
        let current = state();
        let Some(offer) = current.as_ref() else {
            return;
        };
        if offer.checking || offer.installing || !offer.can_install {
            return;
        }
        let Some(version) = offer.available.clone() else {
            return;
        };
        version
    };
    if !configured(&app) {
        return;
    }
    set(
        &app,
        UpdateState {
            available: Some(offered.clone()),
            installing: true,
            checked: true,
            can_install: true,
            ..Default::default()
        },
    );
    std::thread::spawn(move || {
        let outcome = tauri::async_runtime::block_on(async {
            let Some(update) = app.updater()?.check().await? else {
                return Ok::<bool, tauri_plugin_updater::Error>(false);
            };
            if update.version != offered {
                return Ok(false);
            }
            // Tauri verifies the archive against the configured public key.
            update.download_and_install(|_, _| {}, || {}).await?;
            Ok(true)
        });
        match outcome {
            Ok(true) => crate::applog("updater: signed update installed, restarting"),
            Ok(false) => {
                crate::applog("updater: signed offer changed before installation");
                set(
                    &app,
                    UpdateState {
                        available: Some(offered),
                        checked: true,
                        message: Some(INSTALL_ERROR.into()),
                        ..Default::default()
                    },
                );
            }
            Err(e) => {
                crate::applog(&format!("updater: signed install failed ({e})"));
                set(
                    &app,
                    UpdateState {
                        available: Some(offered),
                        checked: true,
                        can_install: true,
                        message: Some(INSTALL_ERROR.into()),
                        ..Default::default()
                    },
                );
            }
        }
    });
}

pub fn check_on_launch(app: &AppHandle) {
    if update_repo(UPDATE_REPO).is_none() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(20));
        check_for_update(app);
    });
}

#[cfg(test)]
mod tests {
    use super::{newer_signed_release, newer_windows_release, project_page, signed_offer_matches, update_repo};
    use semver::Version;

    fn release(tag: &str, windows: bool) -> String {
        let asset = if windows {
            r#"[{"name":"NotchDeck-Setup.exe"}]"#
        } else {
            "[]"
        };
        format!(r#"{{"tag_name":"{tag}","assets":{asset}}}"#)
    }

    #[test]
    fn compares_only_windows_releases() {
        let current = Version::parse("1.18.0").unwrap();
        assert_eq!(
            newer_windows_release(&release("v1.19.0", true), &current).unwrap(),
            Some(Version::parse("1.19.0").unwrap())
        );
        assert_eq!(
            newer_windows_release(&release("v1.18.0", true), &current).unwrap(),
            None
        );
        assert_eq!(
            newer_windows_release(&release("v1.17.0", true), &current).unwrap(),
            None
        );
        assert!(newer_windows_release(&release("v1.19.0", false), &current).is_err());
        assert!(newer_windows_release("not json", &current).is_err());
        assert!(newer_windows_release(&release("latest", true), &current).is_err());
    }

    #[test]
    fn update_repo_must_name_owner_and_repository() {
        assert_eq!(update_repo(None), None);
        assert_eq!(update_repo(Some("")), None);
        assert_eq!(update_repo(Some("owner")), None);
        assert_eq!(update_repo(Some("owner/")), None);
        assert_eq!(update_repo(Some("owner/name/extra")), None);
        assert_eq!(update_repo(Some("a b/c")), None);
        assert_eq!(update_repo(Some(" owner/notch-deck ")), Some("owner/notch-deck"));
    }

    #[test]
    fn project_pages_are_built_here_not_taken_from_the_page() {
        assert_eq!(project_page("o/n", "repo", "1.2.3").as_deref(), Some("https://github.com/o/n"));
        assert_eq!(
            project_page("o/n", "release", "1.2.3").as_deref(),
            Some("https://github.com/o/n/releases/tag/v1.2.3")
        );
        assert_eq!(project_page("o/n", "https://evil.example", "1.2.3"), None);
    }

    #[test]
    fn signed_offer_must_match_the_release() {
        let release = Version::parse("1.19.0").unwrap();
        assert!(signed_offer_matches(&release, "1.19.0"));
        assert!(!signed_offer_matches(&release, "1.18.0"));
        assert!(!signed_offer_matches(&release, "bad version"));
        assert_eq!(
            newer_signed_release("1.19.0", &Version::parse("1.18.0").unwrap()),
            Some(release)
        );
        assert_eq!(
            newer_signed_release("1.18.0", &Version::parse("1.18.0").unwrap()),
            None
        );
    }
}
