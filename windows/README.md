# NotchDeck for Windows

The Windows build of NotchDeck — the usage notch that sits on the edge of your screen and
answers two questions at a glance: **how much of my AI allowance is left**, and **is Claude
still working** — with the same deck of tools beside the rings as on the Mac: **Now Playing**,
**Clipboard history**, a **Focus Timer**, the **Vault**, your **Next meeting** and **live status**
for the charger and downloads (see [the deck](#the-deck)).

Same design language as the macOS original (inverse-rounded pill, colour-graded rings,
hover card with per-window bars), rebuilt for Windows in Rust + Tauri 2 / WebView2.
No code is copied from the Swift app; the providers are reimplemented from their
documented behaviour and the wire formats.

## What it shows

| Cell | Source | How it reads it |
|---|---|---|
| **Claude** | `GET https://api.anthropic.com/api/oauth/usage` with the token Claude Code keeps in `~/.claude/.credentials.json` | Session / weekly windows with a five-minute request-attempt floor per account, including manual refresh. 429 back-off honours the full Retry-After (seconds or HTTP-date), with per-account deadlines persisted across restarts; stale readings dimmed with their age. Renews that token by running the standalone `claude -p` shortly before it expires (Claude Code inside the desktop app never writes this file), and never sends an expired one. A thin arc spins inside the ring while a Claude session is working, and pulses amber when one is waiting on you (Claude Code hooks + transcript watcher, desktop app included). |
| **Codex** | The local Codex sign-in in `~/.codex/auth.json` (read only, never refreshed), falling back to the newest session snapshot | Live primary/secondary windows (5h + weekly on paid plans, a monthly window on free) while Codex is signed in; Spark and Code review appear on the hover card when Codex reports them; otherwise the last snapshot, marked stale by its own timestamp. |
| **Cursor** | The editor's own session from `state.vscdb` → `cursor.com/api/usage-summary` | Included usage / API usage / on-demand, reset at billing-cycle end. Nothing to sign into: it borrows the editor's session, so there is only ever one account. |
| **Grok** | The Grok CLI's own session in `~/.grok/auth.json` (read only, never refreshed) → `cli-chat-proxy.grok.com/v1/billing?format=credits`, the endpoint that CLI's own `/usage` asks | The weekly Grok Build allowance, with the account on the hover card. Only a session minted by `auth.x.ai` is used — the file can also hold a customer IdP token meant for that customer's private proxy. A fresh weekly period reads 0 %, not "unmetered". |
| **GitHub Copilot** | The GitHub CLI's own session, read only: `GH_TOKEN`/`GITHUB_TOKEN` when set, else `oauth_token` in `%APPDATA%\GitHub CLI\hosts.yml`, else `gh auth token` run hidden (the token may live in Credential Manager) → `api.github.com/copilot_internal/user`, the quota endpoint GitHub's own editors ask | Premium requests on the ring, with chat requests and completions on the hover card; all reset on the first of the month. An `unlimited` quota, or one with no entitlement, draws nothing. The account and plan are named on the card. Sign in with `gh auth login`; NotchDeck never starts a sign-in itself. |
| **OpenCode** | OpenCode's own sign-in, read only: the `opencode-go` key in `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage`, or — since OpenCode 1.18 — the OAuth sign-in in `opencode.db` (`credential` table) → `opencode.ai/inference/go/v1/usage` | The Go plan's 5-hour, weekly and monthly windows. A sign-in without a Go plan shows "No OpenCode Go subscription" instead of a ring; Zen pay-as-you-go credit has no balance or usage API, so it is not shown. |
| **Antigravity** | Official `agy` CLI `/usage` print when installed; otherwise the existing local `language_server` bridge, Google Cloud Code API, or transcript model count | Official four quota rows (Gemini & Claude/GPT 5h/weekly) without running the full IDE. When CLI is absent, falls back to legacy local bridge/API. |
| **OpenCode Go** | `GET https://opencode.ai/zen/go/v1/usage` | Reads the `opencode-go` key in OpenCode's `auth.json`, or `OPENCODE_APIKEY` when set. The environment key takes precedence. Shows rolling 5-hour, weekly and monthly usage. This is a separate subscription from the Z.ai GLM Coding Plan; its key must not be sent to Z.ai's monitor endpoint. |

Providers that are not installed simply do not get a cell.

### Codex quota recovery

The direct usage endpoint remains the first choice. If it fails, NotchDeck can
ask an installed **native** `codex.exe` via the documented
[`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
app-server method before falling back to a rollout snapshot. The desktop's
`%LOCALAPPDATA%\OpenAI\Codex\bin` installation is checked as well as native CLI
candidates. No `.cmd`/Node wrapper is launched. The owned process is hidden,
limited to 20 seconds, and terminated/reaped after the read; no inference or
login command is sent. Existing HTTP 429 backoff and five-minute polling remain.

The main ring/tray selects only core `primary`, never a weekly, Spark or
code-review replacement. If `primary` is absent the headline stays blank;
`secondary` remains available to the separate weekly ring. App-server
multi-bucket replies prefer `codex`. Rollout fallback ignores explicitly different
bucket ids and, like macOS, reads the latest eight non-archived paths from
`state_5.sqlite` using a read-only, WAL-aware connection (50 ms busy timeout).
This finds resumed threads without scanning every session file. If the index
is unavailable, the original three-date-directory scan remains the fallback;
old resumed threads cannot be discovered through that scan alone. Missing data is
not a zero. Percentages retain the existing **used** semantics; this is quota
utilization, not an exact token count or a model-specific allowance.

Why launch a process at all? A borrowed stored-token HTTP read can fail while
the installed Codex client can still authenticate. The native client owns its
managed OAuth lifecycle and can recover live quotas without NotchDeck copying
its refresh logic. This is not guaranteed for externally managed credentials
that require a host app: if it cannot read the quota, the usual stale/missing
rollout status remains. Unlike the old unconditional wrapper-based path, this
recovery runs only after HTTP failure, directly owns a native executable, and
does not use `taskkill` or launch a Node/cmd tree. NotchDeck sends no login or
explicit token-refresh request; Codex may perform its own normal managed refresh.

Regression checks: `cargo test --locked` and `node --test test-codex-headline.cjs`
from `windows/`. Tests use synthetic quota fixtures, not account credentials.
The optional `cargo test --release --locked codex::tests::live_native_quota -- --ignored`
checks the actual native transport against an already signed-in local client;
it prints no account credentials or quota values and is not run by CI.

### Reset cards

The Windows app can show a short card when any active provider — Claude,
Codex, Cursor, GLM, OpenCode, Grok, Antigravity — renews a quota window it was
using. Each provider's own windows are watched independently and by their own
id, not by a fixed duration, so this needs no per-provider list to stay
current. Each window needs at least 10% usage before its reset counts, and a
fresh reading must confirm the change, so the card can appear on the next
poll rather than instantly. Saved, stale and first-launch readings do not
trigger a card, and a provider's own cooldown after firing keeps a jittery
reading from reporting the same reset twice.

The card uses the notch's appearance and follows its configured screen, edge,
size and theme, positioned from the notch's own measured on-screen rectangle
rather than an assumed offset — a taskbar docked to that edge, or the notch
dragged along it, cannot leave the card off by itself. It also appears when
the notch is set to **Hide**, without changing that setting. General →
Notifications has one switch for every provider's reset cards (on by
default), a switch for the notification sound, and a **Preview card** button.
When more than one window renews together, their cards appear one after the
other. The Windows app must be running to observe and show a reset.

### Claude sign-in

When Claude is signed out, its card offers **Sign in**, which opens the standalone
Claude Code CLI's browser login (`claude auth login --claudeai`). It is offered on
the default `~/.claude` account only, since that is the one the CLI signs in.
Finish in the browser; if it
displays a code, paste it in the opened terminal, not in NotchDeck. The card
refreshes after the CLI exits without restarting the widget. The native CLI must
already be installed; missing CLI, cancellation and launch errors are shown.

This explicit action shares a busy guard with automatic token renewal. Only the
CLI handles OAuth and writes credentials; NotchDeck does not receive login codes
or expose tokens through UI IPC. The interactive child has a 15-minute timeout.
To read Claude again, click its ring or choose **Refresh now** from the notch's
right-click menu. HTTP 403 is reported as an access/network refusal rather than claiming
that a still-valid login has expired. Existing automatic renewal is unchanged.
Manual refresh respects the five-minute per-account attempt floor and any
rate-limit deadline. A newly crossed reset boundary permits one earlier attempt;
credential renewal still runs on the existing 60-second active loop.

Browser approval is only one part of sign-in: wait for the CLI terminal to report
`Login successful`. If it reports 403 afterwards, do not interpret that as a
successful login or repeatedly delete credentials. Check the CLI error and the
network/account access used by that CLI; browser and terminal connectivity can
differ. Keep authorization codes, tokens and raw debug logs out of issue reports.

The Claude quota arcs and headline require a fresh successful reading whose
reported reset has not passed. On sign-out or a stale/error response they show
no quota arc instead of presenting a cached percentage as current. The hover
card can retain the last known values, explicitly labelled as historical, with
their last reported reset time. A successful refresh restores the live reading;
this display rule does not bypass HTTP 403 or change OAuth, polling or backoff.

### Antigravity

- **Official CLI (Preferred)**: When the official Antigravity CLI (`agy.exe`) is installed (`%LOCALAPPDATA%\agy\bin\agy.exe` or on `PATH`) and signed in, NotchDeck reads official quotas directly without keeping the full IDE running.
- **Execution**: Runs the official CLI in a hidden Windows pseudo-console, with a 70-second timeout and cleanup of its process tree. It does not need PowerShell scripts or a separate service.
- **Refresh**: Checks at startup and on hover/explicit request when readings are at least five minutes old; failed attempts are also limited to once per five minutes. It keeps previous readings on failure, without switching to legacy APIs. The CLI is not launched periodically while idle.
- **Fallback**: When the official CLI is not installed, NotchDeck preserves the legacy local bridge (`language_server`), Credential Manager, and transcript model turn counting to maintain compatibility with existing installations.
- **Official CLI Reference**: Standalone `/usage` printing is described in the [official Antigravity CLI documentation](https://www.antigravity.google/docs/cli/headless). Note: no categorical Terms of Service guarantee is made.

Restart NotchDeck after installing or removing `agy`: the source is selected at startup.
The CLI's text report is parsed defensively; an unsupported format or failed sign-in
shows an error or the last reading marked stale. NotchDeck does not automate sign-in.

## The deck

Cells after the rings, each with its own card, switched on and off in **Settings → General
→ Deck**:

- **Now Playing** reads the system media sessions (`GlobalSystemMediaTransportControlsSessionManager`,
  the ones the volume flyout shows) once a second from `media.rs`: title, artist, app, artwork,
  progress, and previous / play-pause / next / seek. Click the cell to play or pause. Its card has a
  volume row (`audio.rs`): mute, a slider that follows the volume keys, and a list of outputs to
  switch to — through `IPolicyConfig`, the interface Windows' own switcher uses.
- **Clipboard** (`clipboard.rs`) watches the clipboard's sequence number and keeps text, links and
  copied files, most recent first, with pinning. Anything marked
  `ExcludeClipboardContentFromMonitorProcessing` or `CanIncludeInClipboardHistory = 0` — what
  password managers set — is never recorded, nor is anything copied while a password manager is in
  front. With **Remember clipboard history** on, clips are kept in `clipboard-history.json` in the
  data folder; switched off, that file is deleted. The card searches the history (the notch takes
  the keyboard only while its search box is in use), keeps **snippets** (`snippets.json`; star a
  clip — again to take it back out — or add them in Settings); **Always strip formatting** turns
  every copy of formatted text into plain text.
- **Focus Timer** runs in the notch page itself; Rust keeps its lengths, plays the system sound when
  a phase ends, and (`focus_timer.rs`) runs **cycles** of focus and short and long breaks and keeps
  the day's focused time and the week before it in `focus-stats.json`. Windows has no API an app may
  use for Do Not Disturb, so the timer does not change it.
- **Vault** (`vault.rs`): drag files onto the notch to hold them, drag them out to copy them (Shift
  moves). Files are held by path; ones from temporary places (Outlook attachments, browser caches,
  `%TEMP%`) and text, links and pictures dragged from a browser are kept in
  `%LOCALAPPDATA%\NotchDeck\Vault`. Share, Zip, Clear, and clearing after an hour, a day or a week.
  The notch window has a drop target of its own (wry's only reads files); dragging out uses the
  shell's data object and `SHDoDragDrop`, offered as a copy.
- **Next meeting** (`meeting.rs`) reads iCal feeds pasted in Settings (Google's secret iCal address,
  Outlook's published calendar), with time zones, repeats, cancelled and moved repeats. A ring counts
  down the last hour, the card has **Join** for Zoom, Meet, Teams, Webex and others, and the notch
  peeks a few minutes before.
- **Live status** (`live.rs`): the notch peeks when the charger goes in or out, and a **Downloads**
  cell appears while a browser downloads into the Downloads folder, peeking with Open and Show in
  Explorer when it finishes.

## Install / build

Download `NotchDeck-Setup.exe` from your release (the Windows Package workflow builds it on every
push and attaches it to `v*` releases). It installs for the current user without administrator rights, puts
`notchdeck-hook.exe` beside the app where **Install hooks** looks for it, and fetches WebView2 if
Windows does not already have it. The installer is not code-signed, so SmartScreen stops it the
first time with *Windows protected your PC*: choose **More info**, then **Run anyway**.

### Updates

Updates are off unless the build names a repository to check: set the `NOTCHDECK_UPDATE_REPO`
environment variable (`owner/name`) when building — the Windows Package workflow passes
`github.repository`. A build without it never checks and Settings says updates aren't set up.

With a repository set, NotchDeck looks for a newer release about twenty seconds after it starts,
and again whenever **Check for updates** is pressed in Settings → General. It compares the
installed version with that repository's latest release and confirms that release carries a
Windows installer. When you have published a signed `latest.json` feed for that same version and
listed it in `plugins.updater.endpoints`, **Update** downloads and installs it through Tauri.
Otherwise **Download installer** opens the release's installer for you to run.

Nothing about this nags. A check that fails — no network or no Windows installer yet — leaves the
app as it was and says so next to the version. Before the first completed check, the page makes
no "Up to date" claim. There is no dialogue and no badge.

Automatic updates use a minisign-signed archive; Tauri checks its signature against the public
key in `tauri.conf.json` before running it. The manually downloaded installer is unsigned, so
SmartScreen may warn, as it does for a first installation.

Before the first signed release, the key has to exist:

```powershell
npx --yes @tauri-apps/cli@2.11.4 signer generate -w $env:USERPROFILE\.tauri\notchdeck.key
```

Put the **private** key in the repository secret `TAURI_SIGNING_PRIVATE_KEY` and its password in
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, and paste the **public** key into `plugins.updater.pubkey`
in `notchdeck/tauri.conf.json`, replacing `REPLACE_WITH_TAURI_PUBLIC_KEY`, and add
`https://github.com/<owner>/<repo>/releases/latest/download/latest.json` to
`plugins.updater.endpoints`. Until that is done the app still checks GitHub releases and offers the
manual installer. The packaging job builds an ordinary installer without a signed feed, and a `v*`
release job fails to flag the missing signing configuration.

Keep the private key. Losing it means no installed copy can be updated again, because every one of
them checks against the public key it shipped with — they would all have to reinstall by hand.

To build from source instead — prerequisites: Rust (MSVC toolchain), WebView2 runtime (ships with Windows 11).

```powershell
# from this directory (windows/)
cargo build --release
.\target\release\notchdeck.exe          # pill appears on the right edge of the primary monitor
.\target\release\notchdeck.exe doctor   # self-diagnosis: credentials, data sources, icons, hooks
```

To build the installer the way the Windows Package workflow does:

```powershell
# the hook gets its own target dir, so the bundler never copies it onto itself
cargo build --release --locked -p notchdeck-hook --target-dir target/hook
cd notchdeck
npx @tauri-apps/cli@2 build --config tauri.bundle.conf.json
# → ..\target\release\bundle\nsis\NotchDeck_<version>_x64-setup.exe
```

### Linux

The same crate builds and runs on Linux; the Win32 pieces already sat behind `cfg(windows)`,
and the rest of the port is portable Rust. Prerequisites on a Debian or Ubuntu machine:

```sh
sudo apt install build-essential pkg-config libssl-dev libwebkit2gtk-4.1-dev \
                 libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev
cargo build --release -p notchdeck
./scripts/run-linux.sh          # pill appears on the right edge
./scripts/run-linux.sh doctor   # self-diagnosis, same as on Windows
```

`scripts/run-linux.sh` exists because of two things the desktop does not do by itself.
**Wayland does not let a client place its own windows**, and the notch has to sit on a
screen edge, so it runs as an X11 client under XWayland. And a shell started from a
**snap** — Ubuntu's VS Code, for one — exports that snap's library paths, which make a
binary built against the system glibc die with
`symbol lookup error: … undefined symbol: __libc_pthread_init`. The script unsets those
and sets `GDK_BACKEND=x11`; launched from the desktop rather than such a shell, the
binary runs on its own.

The tray needs GNOME's *AppIndicator Support* extension, as every Tauri tray does there.
The data folder follows the XDG directories (`~/.config/notchdeck`), and providers are
found at their Linux paths: `~/.claude`, `~/.codex`, `~/.grok`,
`~/.config/Cursor/User/globalStorage/state.vscdb`.

What does not work yet, and degrades quietly rather than misbehaving:

| Feature | Why |
|---|---|
| Dragging the pill along its edge | Follows the mouse through `GetAsyncKeyState`; needs an X11 pointer query. |
| Seen-clears-it, and jumping back to the terminal | `focus.rs` reads the foreground window and the process tree through Toolhelp; `/proc` plus a window-manager call would replace it. |
| Antigravity | Its credential is read from the Windows Credential Manager; libsecret is the equivalent. |
| App icons taken from an installed `.exe` | The built-in provider SVGs cover every provider, so little is lost. |

Everything else — all providers, the hover card, the settings window, the tray menu, hooks,
start at sign-in (an XDG autostart entry rather than a registry value) — behaves as it does
on Windows.

Tray menu: the readings themselves — a line per provider with its headline figure, and under it
one line per limit window — then **Refresh all**, **Settings…** and **Quit NotchDeck**. Clicking a
provider's line re-reads that provider. Everything else is in the settings window: which rings the
notch shows, its size, the weekly ring, which screen edge it sits on and which screen,
start with Windows, the language, Claude Code hooks, reset
position, and the data folder (`%APPDATA%\notchdeck` — logs, persisted readings, icon overrides).

Notch: clicking a ring re-reads that provider, as on the Mac. Right-clicking the notch or its card
offers **Refresh now**, the provider's usage page (**Open claude.ai**, **Open chatgpt.com**, …) and
**Quit NotchDeck**. Neither click nor the tray bypasses Claude's five-minute
per-account attempt floor or its rate-limit wait.

### Where the notch sits

The notch pins to one edge of one screen. Six dots come out beside the settings button while the
pointer is on it: hold them (or hold Alt anywhere on the notch) and drag, and the notch follows the
pointer round the screen's border — along an edge, and round each corner — and lands where it is
let go.
**Appearance → Edge** picks left, right, top or bottom: it stands upright on the left and right
edges with the hover card opening sideways, and lies flat on the top and bottom ones with the card
opening below or above. **Appearance → Screen** appears once more than one monitor is attached.

Carried well onto another monitor, 150 px past the one it is on, the notch goes there, across a
change of DPI between them too. The choice is stored as `notch_edge`, `notch_monitor` (the device
name, e.g. `\\.\DISPLAY2`) and `notch_along` (where along each edge, 0–1) in `config.json`. A monitor that is no longer
attached falls back to the primary one, so unplugging a screen cannot strand the notch off-screen;
**Recentre** centres it on the edge it is on, or on the primary screen's right-hand edge when the screen it was on is gone.

Folded (**Appearance → Show → Show on hover**), the notch rests as a small pill at the edge, in
**Theme**'s colour, with an edge that shows even against a backdrop of that colour.
**Appearance → Adaptive pill**, off unless switched on, makes it follow what is behind it instead:
light over a dark backdrop, black over a light one, the way the iPhone's home indicator does. To tell
which, NotchDeck reads a thin strip of the screen beside the pill twice a second while it is folded,
and keeps only its average brightness, which is never stored or sent. With the switch off, the notch
open, or Show set to Always show, nothing is read.

**Appearance → Fold for full-screen apps**, on unless switched off, folds the notch to its pill while
a full-screen app — a video, a game, a slideshow — is in front on its screen, whatever Show says, as
the Mac's does. Hovering the pill still opens it, and leaving the app unfolds it again. Switch on or
off, the notch moves to the screen's very edge meanwhile, into the room the taskbar has made for the
app, and back when the taskbar returns.

### Icons

Provider marks are the SVGs from [`@lobehub/icons-static-svg`](https://github.com/lobehub/lobe-icons)
(MIT), embedded unmodified — see `notchdeck/glyphs/NOTICE.md`. Drop your own
`claude|codex|cursor|gemini.svg` (or `.png`) into `%APPDATA%\notchdeck\glyphs\` to override.
The marks remain the trademarks of their owners.

### Translations

Three surfaces draw their own text, so each keeps its own table:

| Surface | Table | Languages today |
|---|---|---|
| Tray menu | `notchdeck/src/i18n.rs` (`tr`), `notchdeck/src/traymenu.rs` (`label`) | en · ru · zh · ja · ko · uk |
| Hover card | `notchdeck/ui/notch.html` (`TEXT`, `PATTERNS`, `UI`) | en · ru · zh |
| Settings window | `notchdeck/ui/settings.html` (`STATIC_TEXT`, `STATUS_TEXT`) | en · ru · zh · ja · ko |

Help is welcome on the gaps, which fall back to English rather than breaking anything:

- the hover card has no Japanese, Korean or Ukrainian;
- the settings window has no Ukrainian, although the tray menu and the language picker have had it
  since Ukrainian was added;
- Korean has none of the window names the Mac's catalog carries — `Current session`, `Weekly limit`,
  `Monthly limit`, `5-hour Limit`, `Included usage`, `API usage` — because the catalog has no Korean
  to take them from.

Keys are the exact English string. A string the Mac also shows should be taken from
`Sources/Localizable.xcstrings` rather than translated afresh, so both platforms word it the same
way. One catalog feeding all three tables is the intended fix; until then a test in `traymenu.rs`
fails if the menu and the card stop naming the same window.

## Layout

```
.
├── notchdeck/          the Windows app (pill, hover card, settings, providers)
└── notchdeck-hook/     tiny helper Claude Code calls to report session events
```

A pull request that touches this tree is built and tested on Windows and Linux.

## License

MIT — see `LICENSE`, which also carries the copyright notices of the MIT-licensed projects this
port is derived from.
