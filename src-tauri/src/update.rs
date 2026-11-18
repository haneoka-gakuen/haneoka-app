//! Updates. The desktop app installs signed updates itself; phones and
//! system-packaged Linux builds open the download page.

use std::sync::atomic::{AtomicBool, Ordering};

use tauri::AppHandle;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_opener::OpenerExt;

use crate::ORIGINS;

static CHECKED: AtomicBool = AtomicBool::new(false);
static UPDATE_CHECK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[cfg_attr(not(desktop), allow(dead_code))]
struct Text {
    title: &'static str,
    ready: &'static str,
    available: &'static str,
    update: &'static str,
    download: &'static str,
    later: &'static str,
}

fn text(locale: &str) -> Text {
    match locale {
        "ja" => Text { title: "アップデート", ready: "haneoka {version} をインストールできます", available: "haneoka {version} が公開されています", update: "アップデート", download: "ダウンロード", later: "後で" },
        "ko" => Text { title: "업데이트", ready: "haneoka {version}을(를) 설치할 수 있습니다", available: "haneoka {version}이(가) 출시되었습니다", update: "업데이트", download: "다운로드", later: "나중에" },
        "zh-CN" => Text { title: "更新", ready: "haneoka {version} 可以安装", available: "haneoka {version} 已发布", update: "更新", download: "下载", later: "稍后" },
        "zh-TW" => Text { title: "更新", ready: "haneoka {version} 可以安裝", available: "haneoka {version} 已發布", update: "更新", download: "下載", later: "稍後" },
        _ => Text { title: "Update", ready: "haneoka {version} is ready to install", available: "haneoka {version} is available", update: "Update", download: "Download", later: "Later" },
    }
}

fn ask(app: &AppHandle, title: &str, message: String, ok: &str, cancel: &str) -> bool {
    app.dialog()
        .message(message)
        .title(title)
        .buttons(MessageDialogButtons::OkCancelCustom(ok.to_owned(), cancel.to_owned()))
        .blocking_show()
}

/// The mirrors in the order the window reached them, then GitHub.
fn feeds(origin: &str, name: &str) -> Vec<tauri::Url> {
    let mut sites = vec![origin.to_owned()];
    sites.extend(ORIGINS.iter().filter(|o| **o != origin).map(|o| (*o).to_owned()));
    sites
        .iter()
        .map(|site| format!("{site}/downloads/app/latest/{name}"))
        .chain([format!("https://github.com/haneoka-gakuen/haneoka-app/releases/latest/download/{name}")])
        .filter_map(|url| tauri::Url::parse(&url).ok())
        .collect()
}

/// Mirror URLs follow the site this window reached.
#[cfg(desktop)]
fn on_site(url: &tauri::Url, origin: &str) -> tauri::Url {
    if crate::site_origin(url).is_none() {
        return url.clone();
    }
    tauri::Url::parse(&format!("{origin}{}", url.path())).unwrap_or_else(|_| url.clone())
}

fn newer(candidate: &str, current: &str) -> bool {
    let parse = |v: &str| v.trim_start_matches('v').split('.').map(|p| p.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parse(candidate) > parse(current)
}

/// Once per run, after the first page of a working site has loaded.
pub fn check(app: &AppHandle, origin: String, locale: String) {
    if cfg!(debug_assertions) || CHECKED.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        check_now(&app, &origin, &locale).await;
    });
}

pub async fn check_now(app: &AppHandle, origin: &str, locale: &str) -> &'static str {
    let Ok(_guard) = UPDATE_CHECK.try_lock() else { return "busy" };
    CHECKED.store(true, Ordering::SeqCst);
    #[cfg(desktop)]
    let signed = if self_updating() {
        match install(app, origin, locale).await {
            "handled" => return "handled",
            "install_failed" => return "install_failed",
            "current" => true,
            _ => false,
        }
    } else {
        false
    };
    #[cfg(not(desktop))]
    let signed = false;
    match notify(app, origin, locale).await {
        "unavailable" if signed => "current",
        status => status,
    }
}

/// Installed from the updater's own packages: Windows and macOS installs and
/// the AppImage. Distribution packages are updated by their package manager.
#[cfg(desktop)]
fn self_updating() -> bool {
    !cfg!(target_os = "linux") || std::env::var_os("APPIMAGE").is_some()
}

#[cfg(desktop)]
async fn install(app: &AppHandle, origin: &str, locale: &str) -> &'static str {
    use tauri_plugin_updater::UpdaterExt;
    let mut builder = app.updater_builder().timeout(std::time::Duration::from_secs(60));
    if let Ok(with_feeds) = app.updater_builder().endpoints(feeds(origin, "updater.json")) {
        builder = with_feeds.timeout(std::time::Duration::from_secs(60));
    }
    if let Some(proxy) = crate::platform::game_proxy().and_then(|p| tauri::Url::parse(&format!("http://{}:{}", p.host, p.port)).ok()) {
        builder = builder.proxy(proxy);
    }
    let Ok(updater) = builder.build() else { return "unavailable" };
    let mut update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => return "current",
        Err(_) => return "unavailable",
    };
    update.download_url = on_site(&update.download_url, origin);
    let words = text(locale);
    let message = words.ready.replace("{version}", &update.version);
    let handle = app.clone();
    let accepted = tauri::async_runtime::spawn_blocking(move || ask(&handle, words.title, message, words.update, words.later))
        .await
        .unwrap_or(false);
    if accepted {
        if update.download_and_install(|_, _| {}, || {}).await.is_err() {
            let _ = app.opener().open_url(download_page(origin, locale), None::<&str>);
            return "install_failed";
        }
        app.restart();
    }
    "handled"
}

/// Phones and package-managed installs: the download page.
async fn notify(app: &AppHandle, origin: &str, locale: &str) -> &'static str {
    let mut reachable = false;
    let mut newer_version = None;
    for feed in feeds(origin, "release-version.json") {
        if let Ok(Ok(version)) = tokio::time::timeout(std::time::Duration::from_secs(8), fetch_version(&feed)).await {
            reachable = true;
            if newer(&version, env!("CARGO_PKG_VERSION")) {
                newer_version = Some(version);
                break;
            }
        }
    }
    let Some(version) = newer_version else { return if reachable { "current" } else { "unavailable" } };
    let words = text(locale);
    let message = words.available.replace("{version}", &version);
    let handle = app.clone();
    let accepted = tauri::async_runtime::spawn_blocking(move || ask(&handle, words.title, message, words.download, words.later))
        .await
        .unwrap_or(false);
    if accepted {
        return if app.opener().open_url(download_page(origin, locale), None::<&str>).is_ok() { "handled" } else { "unavailable" };
    }
    "handled"
}

fn download_page(origin: &str, locale: &str) -> String {
    let locale = if ["en", "ja", "ko", "zh-CN", "zh-TW"].contains(&locale) { locale } else { "en" };
    format!("{origin}/{locale}/download/")
}

/// `release-version.json` from a release: `{ "version": … }`.
async fn fetch_version(url: &tauri::Url) -> Result<String, ()> {
    let body = haneoka_core::http::get(url.as_str(), 64 * 1024).await.map_err(|_| ())?;
    let value: serde_json::Value = serde_json::from_slice(&body).map_err(|_| ())?;
    value.get("version").and_then(|v| v.as_str()).filter(|v| {
        let parts: Vec<_> = v.trim_start_matches('v').split('.').collect();
        parts.len() == 3 && parts.iter().all(|part| part.parse::<u64>().is_ok())
    }).map(str::to_owned).ok_or(())
}
