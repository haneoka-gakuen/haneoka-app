//! The phone's own access to the game's folder (Shizuku, or a folder grant
//! on Android 8–12), and the system bars, fullscreen and orientation the
//! page asks for. Android only; other platforms register nothing.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::plugin::{Builder, TauriPlugin};
use tauri::{Manager, Runtime};

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "org.haneoka.device";

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_haneoka_device);

/// One file the phone staged for reading.
#[derive(Deserialize, Debug)]
pub struct StagedFile {
    pub source: String,
    pub group: String,
    /// Milliseconds since the epoch; 0 when unknown.
    pub modified: i64,
    pub package: String,
    pub path: String,
}

#[derive(Deserialize, Debug)]
pub struct Batch {
    pub id: String,
    pub files: Vec<StagedFile>,
}

pub struct Device<R: Runtime> {
    #[cfg(any(target_os = "android", target_os = "ios"))]
    handle: tauri::plugin::PluginHandle<R>,
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    _runtime: std::marker::PhantomData<fn() -> R>,
}

#[derive(Debug)]
pub struct Unsupported;

impl std::fmt::Display for Unsupported {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("unsupported")
    }
}

impl<R: Runtime> Device<R> {
    pub async fn call<T: DeserializeOwned, P: Serialize>(&self, command: &str, payload: P) -> Result<T, String> {
        #[cfg(any(target_os = "android", target_os = "ios"))]
        {
            return self.handle.run_mobile_plugin_async(command, payload).await.map_err(|e| e.to_string());
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        {
            let _ = (command, serde_json::to_value(payload));
            Err(Unsupported.to_string())
        }
    }

    pub async fn status(&self) -> Result<Value, String> {
        self.call("shizukuStatus", json!({})).await
    }

    pub async fn shizuku_read(&self, package_id: &str) -> Result<Batch, String> {
        self.call("shizukuRead", json!({ "packageId": package_id })).await
    }

    pub async fn folder_read(&self, uri: &str) -> Result<Batch, String> {
        self.call("readFolder", json!({ "uri": uri })).await
    }

    pub async fn release(&self, id: &str) {
        let _: Result<Value, String> = self.call("releaseRead", json!({ "id": id })).await;
    }
}

pub trait DeviceExt<R: Runtime> {
    fn device(&self) -> &Device<R>;
}

impl<R: Runtime, T: Manager<R>> DeviceExt<R> for T {
    fn device(&self) -> &Device<R> {
        self.state::<Device<R>>().inner()
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("haneoka-device")
        .setup(|app, _api| {
            #[cfg(target_os = "android")]
            let device = Device { handle: _api.register_android_plugin(PLUGIN_IDENTIFIER, "DevicePlugin")? };
            #[cfg(target_os = "ios")]
            let device = Device { handle: _api.register_ios_plugin(init_plugin_haneoka_device)? };
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            let device = Device::<R> { _runtime: std::marker::PhantomData };
            app.manage(device);
            Ok(())
        })
        .build()
}
