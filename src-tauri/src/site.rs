//! Which site the window uses. The reader chooses on the start page; a site
//! page that never reports the site's markup sends the window back there,
//! naming the site that did not open.

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
        first
    }
}

/// One of the app's bundled pages.
pub fn local_url(page: &str) -> tauri::Url {
    let base = if cfg!(any(windows, target_os = "android")) { "http://tauri.localhost/" } else { "tauri://localhost/" };
    tauri::Url::parse(base).and_then(|b| b.join(page)).expect("local url")
}

pub fn launch_url(failed: &str, path: &str) -> tauri::Url {
    let mut url = local_url("index.html");
    url.query_pairs_mut().append_pair("failed", failed).append_pair("path", path);
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
        let _ = window.navigate(launch_url(origin, &path));
    });
}

pub fn page_load(window: &WebviewWindow, event: PageLoadEvent, url: &tauri::Url) {
    if site_origin(url).is_none() {
        let state = window.app_handle().state::<AppState>();
        if url.path().ends_with("/saves.html") {
            state.pending.lock().unwrap().page = None;
        } else if url.path().ends_with("/index.html") && matches!(event, PageLoadEvent::Finished) {
            // A link that launched the app arrived before the launch page could ask for it.
            if let Some(page) = state.pending.lock().unwrap().page.take() {
                let _ = window.navigate(crate::site::local_url(&page));
            }
        }
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
