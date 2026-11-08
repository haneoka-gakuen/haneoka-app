//! `window.haneokaApp.call(method, args)`: the website's app methods
//! (src/lib/app-bridge.ts in the website).

use base64::Engine;
use haneoka_core::save::{GameRelease, GameSave, SaveCollector};
use haneoka_core::{export, game};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager, WebviewWindow};
use tauri_plugin_dialog::{DialogExt, FilePath};
use tauri_plugin_fs::FsExt;
use tauri_plugin_haneoka_device::DeviceExt;

use crate::{platform, sign_in, AppState};

type Result<T> = std::result::Result<T, String>;

fn text<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn state(app: &AppHandle) -> tauri::State<'_, AppState> {
    app.state::<AppState>()
}

/// The page's account lists follow the store.
fn accounts_changed(window: &WebviewWindow) {
    let _ = window.eval("dispatchEvent(new Event('haneoka-app-accounts'))");
}

/// The save a request names, or the only one on [server]. Several saves and
/// no key: the page asks the reader to choose (`choose_account`).
fn choose(app: &AppHandle, args: &Value, matches: impl Fn(&GameSave) -> bool) -> Result<Option<GameSave>> {
    let saves = state(app).accounts.saves();
    if let Some(key) = text(args, "key") {
        return Ok(saves.into_iter().find(|s| s.key() == key));
    }
    let mut candidates: Vec<GameSave> = saves.into_iter().filter(|s| matches(s)).collect();
    match candidates.len() {
        0 => Ok(None),
        1 => Ok(candidates.pop()),
        _ => Err("choose_account".into()),
    }
}

fn store(app: &AppHandle, saves: Vec<GameSave>) -> Result<Vec<String>> {
    let accounts = &state(app).accounts;
    saves
        .into_iter()
        .map(|save| accounts.put(save).map(|s| s.key()).map_err(|e| e.to_string()))
        .collect()
}

fn imported(app: &AppHandle, window: &WebviewWindow, collector: SaveCollector) -> Result<Value> {
    let unreadable = collector.unreadable;
    let keys = store(app, collector.saves())?;
    if !keys.is_empty() {
        accounts_changed(window);
    }
    Ok(json!({ "keys": keys, "unreadable": unreadable }))
}

async fn read_picked(app: &AppHandle, path: FilePath) -> Option<(Vec<u8>, String)> {
    let name = path.to_string();
    let bytes = match path {
        FilePath::Path(path) => tokio::fs::read(path).await.ok()?,
        url => app.fs().read(url).ok()?,
    };
    Some((bytes, name))
}

async fn pick_files(app: &AppHandle) -> Option<Vec<FilePath>> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_files(move |files| {
        let _ = sender.send(files);
    });
    receiver.await.ok().flatten()
}

#[cfg(desktop)]
async fn pick_folder(app: &AppHandle) -> Option<std::path::PathBuf> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_folder(move |folder| {
        let _ = sender.send(folder.and_then(|f| f.into_path().ok()));
    });
    receiver.await.ok().flatten()
}

async fn save_file(app: &AppHandle, name: &str, bytes: Vec<u8>) -> Result<bool> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog().file().set_file_name(name).save_file(move |path| {
        let _ = sender.send(path);
    });
    let Some(path) = receiver.await.ok().flatten() else { return Ok(false) };
    match path {
        FilePath::Path(path) => tokio::fs::write(path, bytes).await.map_err(|e| e.to_string())?,
        url => {
            use std::io::Write;
            let mut options = tauri_plugin_fs::OpenOptions::new();
            options.write(true).create(true).truncate(true);
            let mut file = app.fs().open(url, options).map_err(|e| e.to_string())?;
            file.write_all(&bytes).map_err(|e| e.to_string())?;
        }
    }
    Ok(true)
}

fn release_arg(args: &Value) -> Option<GameRelease> {
    text(args, "release").and_then(|r| GameRelease::from_package(r).or_else(|| GameRelease::from_name(r)))
}

#[cfg(desktop)]
fn adb(app: &AppHandle) -> Result<haneoka_core::adb::Adb> {
    let bundled = state(app).resources.as_ref().map(|r| r.join("tools").join("adb"));
    haneoka_core::adb::locate(bundled.as_deref()).map(haneoka_core::adb::Adb::new).ok_or_else(|| "adb_missing".to_owned())
}

/// Reads a save's current progress from the game server when it carries a
/// session; the stored save is updated. Failures keep the stored progress.
async fn refreshed(app: &AppHandle, save: GameSave) -> GameSave {
    if game::session(&save).is_none() {
        return save;
    }
    match game::refresh(&save, platform::game_proxy().as_ref()).await {
        Ok(updated) => state(app).accounts.put(updated).unwrap_or(save),
        Err(_) => save,
    }
}

async fn dispatch(app: &AppHandle, window: &WebviewWindow, method: &str, args: &Value) -> Result<Value> {
    let window = window.clone();
    match method {
        "gameAccounts" => Ok(Value::Array(state(app).accounts.saves().iter().map(export::account_entry).collect())),
        "saveSnapshot" => {
            let save = state(app).accounts.find(text(args, "key").unwrap_or_default()).ok_or("save_not_found")?;
            Ok(json!({ "text": export::snapshot(&save) }))
        }
        "boxAccount" => {
            let server = text(args, "server");
            let Some(save) = choose(app, args, |s| server.is_none_or(|server| s.server() == Some(server)))? else {
                return Ok(Value::Null);
            };
            let save = refreshed(app, save).await;
            accounts_changed(&window);
            Ok(json!({ "text": export::team_package(&save), "key": save.key() }))
        }
        "songProgress" => {
            let server = text(args, "server");
            let save = choose(app, args, |s| server.is_none_or(|server| s.server() == Some(server)))?;
            Ok(save.map_or(Value::Null, |save| json!({ "marks": export::song_marks(&save), "key": save.key() })))
        }
        "gachaHistory" => {
            let history = text(args, "key");
            let saves = state(app).accounts.saves();
            let save = match history.and_then(|key| saves.iter().find(|s| game::history_key(s).as_deref() == Some(key))) {
                Some(save) => Some(save.clone()),
                None => choose(app, &json!({ "key": text(args, "account") }), |s| game::session(s).is_some())?,
            };
            let Some(save) = save else { return Ok(Value::Null) };
            let (name, text) = game::read_history(&save, platform::game_proxy().as_ref()).await.map_err(|e| e.0.to_owned())?;
            Ok(json!({ "files": [{ "name": name, "text": text }] }))
        }
        "pendingGachaHistory" | "pendingSongProgress" | "pendingBoxImport" => Ok(Value::Null),
        "signIn" => {
            let origin = crate::current_origin(app);
            let provider = text(args, "provider").ok_or("provider")?;
            let result = sign_in::sign_in(app, &state(app).sign_in, &origin, provider).await?;
            Ok(result.map_or(Value::Null, |(code, verifier)| json!({ "code": code, "verifier": verifier })))
        }
        "orientation" | "systemBars" => {
            #[cfg(target_os = "android")]
            app.device().call::<Value, _>(method, args).await?;
            Ok(Value::Null)
        }
        "fullscreen" => {
            #[cfg(desktop)]
            window.set_fullscreen(args.get("active").and_then(Value::as_bool).unwrap_or(false)).map_err(|e| e.to_string())?;
            #[cfg(target_os = "android")]
            app.device().call::<Value, _>(method, args).await?;
            Ok(Value::Null)
        }
        "download" => {
            let data = base64::engine::general_purpose::STANDARD.decode(text(args, "data").unwrap_or_default()).map_err(|e| e.to_string())?;
            Ok(json!(save_file(app, text(args, "name").unwrap_or("download"), data).await?))
        }
        "saveSources" => {
            let mut sources = vec!["files"];
            #[cfg(desktop)]
            sources.extend(["folder", "adb", "iosBackup"]);
            #[cfg(target_os = "android")]
            sources.extend(["shizuku", "gameFolder"]);
            Ok(json!({ "sources": sources, "releases": GameRelease::ALL.iter().map(|r| r.package_id()).collect::<Vec<_>>() }))
        }
        "readFiles" => {
            let release = release_arg(args);
            let folder = args.get("folder").and_then(Value::as_bool).unwrap_or(false);
            let collector = if folder {
                #[cfg(desktop)]
                {
                    let Some(path) = pick_folder(app).await else { return Ok(Value::Null) };
                    tauri::async_runtime::spawn_blocking(move || {
                        let mut collector = SaveCollector::new();
                        haneoka_core::files::FileSource { collector: &mut collector, release }.add_path(&path);
                        collector
                    })
                    .await
                    .map_err(|e| e.to_string())?
                }
                #[cfg(mobile)]
                return Err("unsupported: folder".into());
            } else {
                let Some(files) = pick_files(app).await else { return Ok(Value::Null) };
                let mut picked = Vec::new();
                for path in files {
                    if let Some(file) = read_picked(app, path).await {
                        picked.push(file);
                    }
                }
                tauri::async_runtime::spawn_blocking(move || {
                    let mut collector = SaveCollector::new();
                    let mut source = haneoka_core::files::FileSource { collector: &mut collector, release };
                    for (bytes, name) in &picked {
                        source.add_bytes(bytes, name, None);
                    }
                    collector
                })
                .await
                .map_err(|e| e.to_string())?
            };
            imported(app, &window, collector)
        }
        #[cfg(desktop)]
        "adbDevices" => {
            let adb = adb(app)?;
            let devices = adb.devices().await.map_err(|e| e.0)?;
            let mut out = Vec::new();
            for device in devices {
                let releases = if device.state == "device" {
                    adb.installed(&device.serial).await.unwrap_or_default().iter().map(|r| r.package_id()).collect()
                } else {
                    Vec::new()
                };
                out.push(json!({ "serial": device.serial, "state": device.state, "model": device.model, "releases": releases }));
            }
            Ok(Value::Array(out))
        }
        #[cfg(desktop)]
        "adbPair" => {
            let adb = adb(app)?;
            Ok(json!(adb.pair(text(args, "address").ok_or("address")?, text(args, "code").ok_or("code")?).await.map_err(|e| e.0)?))
        }
        #[cfg(desktop)]
        "adbConnect" => {
            let adb = adb(app)?;
            Ok(json!(adb.connect(text(args, "address").ok_or("address")?).await.map_err(|e| e.0)?))
        }
        #[cfg(desktop)]
        "adbRead" => {
            let adb = adb(app)?;
            let serial = text(args, "serial").ok_or("serial")?;
            let releases = match release_arg(args) {
                Some(release) => vec![release],
                None => adb.installed(serial).await.map_err(|e| e.0)?,
            };
            let mut collector = SaveCollector::new();
            for release in releases {
                adb.scan(serial, release, &mut collector).await.map_err(|e| e.0)?;
            }
            imported(app, &window, collector)
        }
        #[cfg(desktop)]
        "iosBackups" => {
            let folders = if args.get("pick").and_then(Value::as_bool).unwrap_or(false) {
                match pick_folder(app).await {
                    Some(folder) => vec![folder],
                    None => return Ok(Value::Null),
                }
            } else {
                haneoka_core::ios_backup::default_folders()
            };
            let backups = tauri::async_runtime::spawn_blocking(move || {
                folders.iter().flat_map(|f| haneoka_core::ios_backup::find(f)).collect::<Vec<_>>()
            })
            .await
            .map_err(|e| e.to_string())?;
            Ok(json!(backups))
        }
        #[cfg(desktop)]
        "iosBackupRead" => {
            let path = std::path::PathBuf::from(text(args, "path").ok_or("path")?);
            let password = text(args, "password").map(str::to_owned);
            let collector = tauri::async_runtime::spawn_blocking(move || {
                let mut collector = SaveCollector::new();
                haneoka_core::ios_backup::scan(&path, password.as_deref(), &mut collector).map(|_| collector)
            })
            .await
            .map_err(|e| e.to_string())?
            .map_err(|e| e.to_string())?;
            imported(app, &window, collector)
        }
        "deviceStatus" => app.device().status().await,
        "shizukuRequest" | "openShizuku" => app.device().call(method, json!({})).await,
        "shizukuRead" => {
            let releases = match release_arg(args) {
                Some(release) => vec![release],
                None => GameRelease::ALL.to_vec(),
            };
            let mut batches = Vec::new();
            for release in releases {
                batches.push(app.device().shizuku_read(release.package_id()).await?);
            }
            read_batches(app, &window, batches).await
        }
        "gameFolder" => {
            let mut uris: Vec<String> = Vec::new();
            if let Some(release) = release_arg(args) {
                let granted: Value = app.device().call("grantGameFolder", json!({ "packageId": release.package_id() })).await?;
                match granted.get("uri").and_then(Value::as_str) {
                    Some(uri) => uris.push(uri.to_owned()),
                    None => return Ok(Value::Null),
                }
            } else {
                let granted: Value = app.device().call("grantedFolders", json!({})).await?;
                uris.extend(granted["folders"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned));
            }
            let mut batches = Vec::new();
            for uri in uris {
                batches.push(app.device().folder_read(&uri).await?);
            }
            read_batches(app, &window, batches).await
        }
        "refreshGameAccount" => {
            let save = state(app).accounts.find(text(args, "key").ok_or("key")?).ok_or("save_not_found")?;
            let updated = game::refresh(&save, platform::game_proxy().as_ref()).await.map_err(|e| e.0.to_owned())?;
            state(app).accounts.put(updated).map_err(|e| e.to_string())?;
            accounts_changed(&window);
            Ok(Value::Null)
        }
        "exportGameAccount" => {
            let save = state(app).accounts.find(text(args, "key").ok_or("key")?).ok_or("save_not_found")?;
            Ok(json!(save_file(app, &format!("haneoka-save-{}.json", save.profile_id), export::full(&save)).await?))
        }
        "deleteGameAccount" => {
            state(app).accounts.remove(text(args, "key").ok_or("key")?).map_err(|e| e.to_string())?;
            accounts_changed(&window);
            Ok(Value::Null)
        }
        #[cfg(debug_assertions)]
        "log" => {
            eprintln!("page log: {args}");
            Ok(Value::Null)
        }
        _ => Err(format!("unsupported: {method}")),
    }
}

/// Files the phone staged; each batch is released once read.
async fn read_batches(app: &AppHandle, window: &WebviewWindow, batches: Vec<tauri_plugin_haneoka_device::Batch>) -> Result<Value> {
    let mut collector = SaveCollector::new();
    for batch in batches {
        for file in &batch.files {
            let Ok(bytes) = tokio::fs::read(&file.path).await else { continue };
            collector.offer(
                &bytes,
                &haneoka_core::save::SaveCandidate {
                    source: file.source.clone(),
                    group: Some(file.group.clone()),
                    modified_at: (file.modified > 0).then(|| chrono::DateTime::from_timestamp_millis(file.modified)).flatten(),
                    release: GameRelease::from_package(&file.package),
                },
            );
        }
        app.device().release(&batch.id).await;
    }
    imported(app, window, collector)
}

#[tauri::command]
pub async fn bridge(app: AppHandle, window: WebviewWindow, method: String, args: Value) -> Result<Value> {
    let page = window.url().map_err(|e| e.to_string())?;
    if crate::site_origin(&page).is_none() {
        return Err("origin".into());
    }
    dispatch(&app, &window, &method, &args).await
}
