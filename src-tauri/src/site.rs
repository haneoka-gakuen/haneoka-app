//! Which site the window uses. A site counts as working only once one of its
//! pages has loaded and said so; a page that never does sends the window
//! back to the launch page, which tries the other site first.

use std::sync::Mutex;
use std::time::Duration;

use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Manager, WebviewWindow};

use crate::{site_origin, AppState};

/// A page that finished loading without the site's own markup is an error page.
const AFTER_FINISH: Duration = Duration::from_secs(4);
/// A page that has not loaded at all by now is not coming.
const OVERALL: Duration = Duration::from_secs(30);

#[derive(Default)]
pub struct Watch {
    state: Mutex<(u64, bool)>,
    /// Fallbacks since a page last loaded; both sites failing stops at Retry.
    failures: Mutex<u32>,
}

impl Watch {
    fn arm(&self) -> u64 {
        let mut state = self.state.lock().unwrap();
        state.0 += 1;
        state.1 = false;
        state.0
    }

    fn current(&self, generation: u64) -> bool {
        let state = self.state.lock().unwrap();
        state.0 == generation && !state.1
    }

    fn generation(&self) -> u64 {
        self.state.lock().unwrap().0
    }

    /// The page reported the site's markup; returns true the first time per load.
    pub fn ready(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        let first = !state.1;
        state.1 = true;
        *self.failures.lock().unwrap() = 0;
        first
    }
}

pub fn launch_url(skip: &str, path: &str, failed: bool) -> tauri::Url {
    let base = if cfg!(any(windows, target_os = "android")) { "http://tauri.localhost/index.html" } else { "tauri://localhost/index.html" };
    let mut url = tauri::Url::parse(base).expect("launch url");
    url.query_pairs_mut().append_pair("skip", skip).append_pair("path", path);
    if failed {
        url.query_pairs_mut().append_pair("failed", "1");
    }
    url
}

fn fall_back(app: &AppHandle, generation: u64, delay: Duration) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(delay).await;
        let state = app.state::<AppState>();
        if !state.watch.current(generation) {
            return;
        }
        let Some(window) = app.get_webview_window("main") else { return };
        let Ok(page) = window.url() else { return };
        let Some(origin) = site_origin(&page) else { return };
        let path = format!("{}{}", page.path(), page.query().map(|q| format!("?{q}")).unwrap_or_default());
        let failures = {
            let mut failures = state.watch.failures.lock().unwrap();
            *failures += 1;
            *failures
        };
        let _ = window.navigate(launch_url(origin, &path, failures > 2));
    });
}

pub fn page_load(window: &WebviewWindow, event: PageLoadEvent, url: &tauri::Url) {
    if site_origin(url).is_none() {
        return;
    }
    let app = window.app_handle();
    let watch = &app.state::<AppState>().watch;
    match event {
        PageLoadEvent::Started => {
            let generation = watch.arm();
            fall_back(app, generation, OVERALL);
        }
        PageLoadEvent::Finished => fall_back(app, watch.generation(), AFTER_FINISH),
    }
}
