//! Where earlier versions kept their data, and how this platform routes
//! requests to the game's servers.

use std::path::{Path, PathBuf};

use haneoka_core::game::Proxy;

/// Account folders the Flutter app wrote (`getApplicationSupportDirectory`
/// + `accounts`) that differ from this app's folder.
pub fn legacy_account_folders(data: &Path) -> Vec<PathBuf> {
    let mut out = vec![data.join("files").join("accounts")];
    if let Some(parent) = data.parent() {
        out.push(parent.join("files").join("accounts"));
    }
    if cfg!(windows) {
        if let Some(roaming) = std::env::var_os("APPDATA") {
            out.push(PathBuf::from(roaming).join("org.haneoka").join("haneoka").join("accounts"));
        }
    }
    if cfg!(target_os = "ios") {
        if let Some(library) = data.ancestors().find(|p| p.ends_with("Library")) {
            out.push(library.join("Application Support").join("accounts"));
        }
    }
    out
}

fn parse_proxy(text: &str) -> Option<Proxy> {
    let text = text.trim();
    let text = text.strip_prefix("http://").unwrap_or(text);
    let text = text.split('/').next()?;
    let text = text.rsplit('@').next()?;
    let (host, port) = text.rsplit_once(':')?;
    Some(Proxy { host: host.trim_matches(['[', ']']).to_owned(), port: port.parse().ok()? })
}

/// The HTTP proxy the system or environment names for the game's hosts.
pub fn game_proxy() -> Option<Proxy> {
    for key in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"] {
        if let Some(proxy) = std::env::var(key).ok().filter(|v| !v.starts_with("socks")).and_then(|v| parse_proxy(&v)) {
            return Some(proxy);
        }
    }
    #[cfg(windows)]
    {
        use winreg::enums::HKEY_CURRENT_USER;
        let settings = winreg::RegKey::predef(HKEY_CURRENT_USER)
            .open_subkey("Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings")
            .ok()?;
        let enabled: u32 = settings.get_value("ProxyEnable").ok()?;
        if enabled == 0 {
            return None;
        }
        let server: String = settings.get_value("ProxyServer").ok()?;
        // Either one address for every protocol or `https=host:port;http=…`.
        let address = server
            .split(';')
            .find_map(|part| part.strip_prefix("https="))
            .or_else(|| server.split(';').find(|part| !part.contains('=')))?;
        return parse_proxy(address);
    }
    #[allow(unreachable_code)]
    None
}
