//! The Haneoka app: the live website in the system web view, plus the native
//! work the website asks for over `window.haneokaApp` (src/bridge.js).

mod bridge;
mod platform;
mod sign_in;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use haneoka_core::store::AccountStore;
use serde::Serialize;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_plugin_opener::OpenerExt;

pub const ORIGINS: [&str; 2] = ["https://haneoka.org", "https://haneoka.com"];

pub struct AppState {
    pub accounts: AccountStore,
    pub config: PathBuf,
    /// A website page a link asked for before the window had a site loaded.
    pub pending_path: Mutex<Option<String>>,
    pub sign_in: sign_in::Waiter,
    #[cfg(desktop)]
    pub resources: Option<PathBuf>,
}

impl AppState {
    fn origin_file(&self) -> PathBuf {
        self.config.join("site-origin")
    }

    pub fn remembered_origin(&self) -> Option<String> {
        let text = std::fs::read_to_string(self.origin_file()).ok()?;
        let text = text.trim();
        ORIGINS.contains(&text).then(|| text.to_owned())
    }
}

pub fn site_origin(url: &url::Url) -> Option<&'static str> {
    let origin = url.origin().ascii_serialization();
    ORIGINS.into_iter().find(|o| *o == origin)
}

/// The window's current site, or the remembered one.
pub fn current_origin(app: &AppHandle) -> String {
    app.get_webview_window("main")
        .and_then(|w| w.url().ok())
        .and_then(|u| site_origin(&u))
        .map(str::to_owned)
        .or_else(|| app.state::<AppState>().remembered_origin())
        .unwrap_or_else(|| ORIGINS[0].to_owned())
}

#[derive(Serialize)]
struct LaunchInfo {
    origins: Vec<&'static str>,
    remembered: Option<String>,
    path: String,
}

fn default_path(locale: &str) -> String {
    let locale = match locale {
        "ja" | "ko" | "zh-CN" | "zh-TW" | "en" => locale,
        _ => "en",
    };
    format!("/{}/{locale}/", if locale == "ja" { "jp" } else { "intl" })
}

#[tauri::command]
fn launch_info(state: tauri::State<'_, AppState>, locale: String) -> LaunchInfo {
    LaunchInfo {
        origins: ORIGINS.to_vec(),
        remembered: state.remembered_origin(),
        path: state.pending_path.lock().unwrap().take().unwrap_or_else(|| default_path(&locale)),
    }
}

#[tauri::command]
fn remember_origin(state: tauri::State<'_, AppState>, origin: String) {
    if ORIGINS.contains(&origin.as_str()) {
        let _ = std::fs::create_dir_all(&state.config);
        let _ = std::fs::write(state.origin_file(), origin);
    }
}

/// Opens a link the system hands the app: a website page, the saves page,
/// gacha history, or a sign-in code.
fn open_link(app: &AppHandle, url: &url::Url) {
    let path = if url.scheme() == "haneoka" {
        match url.host_str() {
            Some("auth") => {
                app.state::<AppState>().sign_in.deliver(url.clone());
                return;
            }
            Some("saves") => Some("/en/saves/".to_owned()),
            Some("gacha-history") => Some("/intl/en/gacha-history/".to_owned()),
            _ => None,
        }
    } else if site_origin(url).is_some() {
        Some(format!("{}{}", url.path(), url.query().map(|q| format!("?{q}")).unwrap_or_default()))
    } else {
        None
    };
    let Some(path) = path else { return };
    let window = app.get_webview_window("main");
    let loaded = window.as_ref().and_then(|w| w.url().ok()).is_some_and(|u| site_origin(&u).is_some());
    match window {
        Some(window) if loaded => {
            let path = localized(&window, &path);
            if let Ok(target) = url::Url::parse(&format!("{}{path}", current_origin(app))) {
                let _ = window.navigate(target);
            }
            let _ = window.set_focus();
        }
        _ => *app.state::<AppState>().pending_path.lock().unwrap() = Some(path),
    }
}

/// `/en/…` placeholders take the reader's current locale.
fn localized(window: &WebviewWindow, path: &str) -> String {
    let current = window.url().ok();
    let segments: Vec<String> =
        current.iter().flat_map(|u| u.path_segments().into_iter().flatten().map(str::to_owned)).collect();
    let locale = segments
        .iter()
        .find(|s| ["en", "ja", "ko", "zh-CN", "zh-TW"].contains(&s.as_str()))
        .cloned()
        .unwrap_or_else(|| "en".into());
    path.replacen("/en/", &format!("/{locale}/"), 1)
}

fn build_window(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    let script = include_str!("bridge.js")
        .replace("__ORIGINS__", &serde_json::to_string(&ORIGINS).unwrap())
        .replace("__VERSION__", env!("CARGO_PKG_VERSION"))
        .replace("__PLATFORM__", std::env::consts::OS);
    let handle = app.clone();
    let builder = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .initialization_script(&script)
        .on_navigation(move |url| {
            if site_origin(url).is_some()
                || matches!(url.scheme(), "tauri" | "about" | "blob" | "data" | "asset")
                || url.host_str() == Some("tauri.localhost")
            {
                return true;
            }
            if url.scheme() == "haneoka" {
                open_link(&handle, url);
            } else if matches!(url.scheme(), "http" | "https" | "mailto") {
                let _ = handle.opener().open_url(url.as_str(), None::<&str>);
            }
            false
        })
        .on_document_title_changed(|_, title| {
            if cfg!(debug_assertions) && title.starts_with("self-test:") {
                eprintln!("{title}");
            }
        })
        .on_page_load(|window, payload| {
            if cfg!(debug_assertions) {
                eprintln!("page {:?} {}", payload.event(), payload.url());
                if std::env::var_os("HANEOKA_SELF_TEST").is_some()
                    && matches!(payload.event(), tauri::webview::PageLoadEvent::Finished)
                    && site_origin(payload.url()).is_some()
                {
                    let _ = window.eval(include_str!("self_test.js"));
                }
            }
        });
    #[cfg(desktop)]
    let builder = builder
        .title("haneoka")
        .inner_size(1280.0, 860.0)
        .min_inner_size(360.0, 480.0)
        .background_color(tauri::window::Color(0xf6, 0xf8, 0xf9, 0xff));
    builder.build()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.unminimize();
            let _ = window.set_focus();
        }
    }));
    builder
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![launch_info, remember_origin, bridge::bridge])
        .setup(|app| {
            let paths = app.path();
            let data = paths.app_data_dir()?;
            let accounts = AccountStore::new(data.join("accounts"));
            for legacy in platform::legacy_account_folders(&data) {
                let _ = accounts.adopt(&legacy);
            }
            app.manage(AppState {
                accounts,
                config: paths.app_config_dir()?,
                pending_path: Mutex::new(None),
                sign_in: sign_in::Waiter::default(),
                #[cfg(desktop)]
                resources: paths.resource_dir().ok(),
            });
            #[cfg(any(target_os = "linux", windows))]
            let _ = app.deep_link().register_all();
            let handle = app.handle().clone();
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                for url in urls {
                    open_link(&handle, &url);
                }
            }
            let links = handle.clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    open_link(&links, &url);
                }
            });
            build_window(&handle)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("haneoka failed to start");
}

pub type Shared<T> = Arc<Mutex<T>>;
