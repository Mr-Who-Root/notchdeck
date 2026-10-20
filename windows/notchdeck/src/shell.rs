//! Opening things the way Explorer would: a meeting link in the default browser, a file in its app,
//! a file shown selected in its folder. `cmd /C start` (what the provider pages use) reads `&` as a
//! command separator, and meeting links carry them, so these go through the shell directly.

/// Opens a URL or a file with whatever Windows has for it.
pub fn open(target: &str) {
    #[cfg(windows)]
    unsafe {
        use windows::core::{w, HSTRING, PCWSTR};
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::Shell::ShellExecuteW;
        use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
        let _ = ShellExecuteW(
            HWND::default(),
            w!("open"),
            &HSTRING::from(target),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
    }
    #[cfg(not(windows))]
    {
        let _ = std::process::Command::new("xdg-open").arg(target).spawn();
    }
}

/// A file or folder, selected in an Explorer window of its folder.
pub fn reveal(path: &str) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Explorer's own switch; the path is one argument, so spaces and `&` are safe in it.
        let _ = std::process::Command::new("explorer.exe")
            .raw_arg(format!("/select,\"{}\"", path.replace('"', "")))
            .spawn();
    }
    #[cfg(not(windows))]
    {
        let dir = std::path::Path::new(path).parent().map(|p| p.to_path_buf()).unwrap_or_default();
        let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
    }
}

/// Only web addresses are opened from what a calendar feed says, never a local program.
pub fn is_web_link(link: &str) -> bool {
    let lower = link.trim().to_ascii_lowercase();
    (lower.starts_with("https://") || lower.starts_with("http://")) && !link.chars().any(char::is_whitespace)
}

#[cfg(test)]
mod tests {
    #[test]
    fn only_web_addresses_count_as_links() {
        assert!(super::is_web_link("https://zoom.us/j/123?pwd=a&b=c"));
        assert!(!super::is_web_link("file:///C:/Windows/system32/calc.exe"));
        assert!(!super::is_web_link("C:\\evil.exe"));
        assert!(!super::is_web_link("https://a b"));
    }
}
