//! Reads saves from an Android phone through the platform tools' `adb`. Only
//! `pm list packages`, `ls`, `stat` and `cat` run on the phone, and only
//! under the game's own `Android/data` folder.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use chrono::{TimeZone, Utc};
use serde::Serialize;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

use crate::codec::MAX_FILE_BYTES;
use crate::save::{GameRelease, SaveCandidate, SaveCollector};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct AdbError(pub String);

#[derive(Serialize, Clone, Debug)]
pub struct AdbDevice {
    pub serial: String,
    /// `device`, `unauthorized` or `offline`.
    pub state: String,
    pub model: Option<String>,
}

pub struct Adb {
    path: PathBuf,
}

/// `adb` bundled with the app, on PATH, or in an Android SDK.
pub fn locate(bundled: Option<&Path>) -> Option<PathBuf> {
    let name = if cfg!(windows) { "adb.exe" } else { "adb" };
    let env = |key: &str| std::env::var_os(key).map(PathBuf::from);
    let home = env("HOME").or_else(|| env("USERPROFILE")).unwrap_or_default();
    let mut candidates: Vec<PathBuf> = bundled.map(|b| b.join(name)).into_iter().collect();
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join(name)));
    }
    for sdk in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let Some(sdk) = env(sdk) {
            candidates.push(sdk.join("platform-tools").join(name));
        }
    }
    if cfg!(target_os = "macos") {
        candidates.push(home.join("Library/Android/sdk/platform-tools").join(name));
        candidates.push("/opt/homebrew/bin/adb".into());
        candidates.push("/usr/local/bin/adb".into());
    }
    if cfg!(windows) {
        if let Some(local) = env("LOCALAPPDATA") {
            candidates.push(local.join("Android/Sdk/platform-tools").join(name));
        }
    }
    if cfg!(target_os = "linux") {
        candidates.push(home.join("Android/Sdk/platform-tools").join(name));
    }
    candidates.into_iter().find(|c| c.is_file())
}

fn quote(path: &str) -> String {
    format!("'{}'", path.replace('\'', r"'\''"))
}

impl Adb {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.path);
        if cfg!(target_os = "linux") {
            if let Some(libraries) = self.path.parent().map(|p| p.join("lib")).filter(|p| p.is_dir()) {
                let existing = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
                command.env("LD_LIBRARY_PATH", format!("{}:{existing}", libraries.display()));
            }
        }
        #[cfg(windows)]
        command.creation_flags(0x0800_0000);
        command.stdin(Stdio::null()).kill_on_drop(true);
        command
    }

    async fn run(&self, args: &[&str]) -> Result<(bool, String, String), AdbError> {
        let output = tokio::time::timeout(Duration::from_secs(30), self.command().args(args).output())
            .await
            .map_err(|_| AdbError("connection timed out".into()))?
            .map_err(|e| AdbError(e.to_string()))?;
        Ok((
            output.status.success(),
            String::from_utf8_lossy(&output.stdout).into_owned(),
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ))
    }

    pub async fn devices(&self) -> Result<Vec<AdbDevice>, AdbError> {
        let (ok, out, _) = self.run(&["devices", "-l"]).await?;
        if !ok {
            return Err(AdbError("adb devices failed".into()));
        }
        Ok(out
            .lines()
            .skip(1)
            .filter_map(|line| {
                let mut parts = line.split_whitespace();
                let serial = parts.next()?.to_owned();
                let state = parts.next()?.to_owned();
                let model = parts.find_map(|p| p.strip_prefix("model:")).map(str::to_owned);
                Some(AdbDevice { serial, state, model })
            })
            .collect())
    }

    /// Wireless debugging on Android 11+: pair once with the code the phone shows.
    pub async fn pair(&self, host_port: &str, code: &str) -> Result<bool, AdbError> {
        let (ok, out, _) = self.run(&["pair", host_port, code]).await?;
        Ok(ok && out.contains("Successfully"))
    }

    pub async fn connect(&self, host_port: &str) -> Result<bool, AdbError> {
        let (ok, out, _) = self.run(&["connect", host_port]).await?;
        Ok(ok && out.contains("connected"))
    }

    async fn shell(&self, serial: &str, command: &str) -> Result<String, AdbError> {
        let (ok, out, err) = self.run(&["-s", serial, "shell", command]).await?;
        if !ok && err.to_lowercase().contains("permission denied") {
            return Err(AdbError("adb_access_denied".into()));
        }
        Ok(if ok { out } else { String::new() })
    }

    pub async fn installed(&self, serial: &str) -> Result<Vec<GameRelease>, AdbError> {
        let out = self.shell(serial, "pm list packages").await?;
        let packages: Vec<&str> = out.lines().map(|l| l.trim().trim_start_matches("package:")).collect();
        Ok(GameRelease::ALL.into_iter().filter(|r| packages.contains(&r.package_id())).collect())
    }

    async fn cat(&self, serial: &str, file: &str) -> Result<Vec<u8>, AdbError> {
        let mut child = self
            .command()
            .args(["-s", serial, "exec-out", &format!("cat {}", quote(file))])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| AdbError(e.to_string()))?;
        let mut stdout = child.stdout.take().ok_or_else(|| AdbError("read save".into()))?;
        let read = async {
            let mut bytes = Vec::new();
            (&mut stdout).take(MAX_FILE_BYTES as u64 + 1).read_to_end(&mut bytes).await.map_err(|e| AdbError(e.to_string()))?;
            if bytes.len() > MAX_FILE_BYTES {
                return Err(AdbError("save file exceeds the size limit".into()));
            }
            let status = child.wait().await.map_err(|e| AdbError(e.to_string()))?;
            if !status.success() {
                return Err(AdbError("read save".into()));
            }
            Ok(bytes)
        };
        tokio::time::timeout(Duration::from_secs(30), read).await.map_err(|_| AdbError("connection timed out".into()))?
    }

    /// Offers every small file in the release's account directories; returns
    /// whether the game's folder exists on the phone.
    pub async fn scan(&self, serial: &str, release: GameRelease, collector: &mut SaveCollector) -> Result<bool, AdbError> {
        let root = format!("/sdcard/Android/data/{}/files", release.package_id());
        let top = self.shell(serial, &format!("ls -1p {}", quote(&root))).await?;
        if top.is_empty() {
            return Ok(false);
        }
        let dirs: Vec<String> = top
            .lines()
            .filter_map(|l| l.strip_suffix('/'))
            .filter(|d| (16..=128).contains(&d.len()) && d.bytes().all(|b| b.is_ascii_hexdigit()))
            .map(str::to_owned)
            .collect();
        for dir in dirs {
            let path = format!("{root}/{dir}");
            let listing = self.shell(serial, &format!("ls -1p {}", quote(&path))).await?;
            for name in listing.lines().filter(|n| !n.is_empty() && !n.ends_with('/')) {
                let file = format!("{path}/{name}");
                let stat = self.shell(serial, &format!("stat -c \"%s %Y\" {}", quote(&file))).await?;
                let mut parts = stat.split_whitespace();
                let size: usize = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                if size == 0 || size > MAX_FILE_BYTES {
                    continue;
                }
                let seconds: Option<i64> = parts.next().and_then(|s| s.parse().ok());
                let Ok(bytes) = self.cat(serial, &file).await else { continue };
                collector.offer(
                    &bytes,
                    &SaveCandidate {
                        source: format!("{}/{dir}/{name}", release.package_id()),
                        modified_at: seconds.and_then(|s| Utc.timestamp_opt(s, 0).single()),
                        release: Some(release),
                        group: Some(format!("{}/{dir}", release.package_id())),
                    },
                );
            }
        }
        Ok(true)
    }
}
