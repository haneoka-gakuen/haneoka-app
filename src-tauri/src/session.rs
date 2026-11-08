//! One sign-in for both sites. The site's session cookies belong to the
//! site that set them; after a page of one site loads, the other site gets
//! the same session, or loses it when the reader signed out.

use std::collections::BTreeMap;

use tauri::{AppHandle, Manager};

use crate::ORIGINS;

/// The site's own cookies: `haneoka.*`, with the Secure prefix in production.
fn is_session(name: &str) -> bool {
    name.trim_start_matches("__Secure-").trim_start_matches("__Host-").starts_with("haneoka.")
}

const MAX_AGE_SECONDS: i64 = 7 * 24 * 60 * 60;

async fn read(app: &AppHandle, origin: &str) -> Option<BTreeMap<String, String>> {
    #[cfg(target_os = "android")]
    let pairs: Vec<(String, String)> = {
        use tauri_plugin_haneoka_device::DeviceExt;
        let value: serde_json::Value = app.device().call("siteCookies", serde_json::json!({ "url": origin })).await.ok()?;
        value["cookie"]
            .as_str()
            .unwrap_or_default()
            .split(';')
            .filter_map(|part| part.trim().split_once('=').map(|(n, v)| (n.to_owned(), v.to_owned())))
            .collect()
    };
    #[cfg(not(target_os = "android"))]
    let pairs: Vec<(String, String)> = {
        let window = app.get_webview_window("main")?;
        let url = tauri::Url::parse(origin).ok()?;
        let cookies = tauri::async_runtime::spawn_blocking(move || window.cookies_for_url(url)).await.ok()?.ok()?;
        cookies.iter().map(|c| (c.name().to_owned(), c.value().to_owned())).collect()
    };
    Some(pairs.into_iter().filter(|(name, _)| is_session(name)).collect())
}

/// Sets `name` on `origin`, or removes it when `value` is `None`.
async fn write(app: &AppHandle, origin: &str, name: &str, value: Option<&str>) {
    #[cfg(target_os = "android")]
    {
        use tauri_plugin_haneoka_device::DeviceExt;
        let cookie = format!(
            "{name}={}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age={}",
            value.unwrap_or(""),
            if value.is_some() { MAX_AGE_SECONDS } else { 0 }
        );
        let _: Result<serde_json::Value, String> = app.device().call("setSiteCookie", serde_json::json!({ "url": origin, "cookie": cookie })).await;
    }
    #[cfg(not(target_os = "android"))]
    {
        let Some(window) = app.get_webview_window("main") else { return };
        let Some(host) = tauri::Url::parse(origin).ok().and_then(|u| u.host_str().map(str::to_owned)) else { return };
        let (name, value) = (name.to_owned(), value.map(str::to_owned));
        let _ = tauri::async_runtime::spawn_blocking(move || {
            let builder = tauri::webview::Cookie::build((name, value.clone().unwrap_or_default()))
                .domain(host)
                .path("/")
                .secure(true)
                .http_only(true)
                .same_site(tauri::webview::cookie::SameSite::Lax);
            match value {
                Some(_) => window.set_cookie(builder.max_age(tauri::webview::cookie::time::Duration::seconds(MAX_AGE_SECONDS)).build()),
                None => window.delete_cookie(builder.build()),
            }
        })
        .await;
    }
}

/// Gives the other sites the session of `from`, the site the reader is on.
pub async fn share(app: AppHandle, from: String) {
    let Some(current) = read(&app, &from).await else { return };
    for to in ORIGINS.iter().filter(|origin| **origin != from) {
        let Some(other) = read(&app, to).await else { continue };
        for (name, value) in &current {
            if other.get(name) != Some(value) {
                write(&app, to, name, Some(value)).await;
            }
        }
        for name in other.keys().filter(|name| !current.contains_key(*name)) {
            write(&app, to, name, None).await;
        }
    }
}
