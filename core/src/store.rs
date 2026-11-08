//! The accounts imported on this device, in the app's private storage. The
//! file format (`haneoka-account-v1`) is the one the Flutter app wrote, so a
//! folder from an earlier version is read as it is.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};

use crate::save::{DocumentKind, GameRelease, GameSave, SaveDocument};

pub struct AccountStore {
    folder: PathBuf,
    saves: Mutex<Option<Vec<GameSave>>>,
}

fn file_key(save: &GameSave) -> String {
    format!("{}-{}", save.server().unwrap_or("save"), save.profile_id)
}

fn file_name(save: &GameSave) -> String {
    // Uri.encodeComponent leaves these characters as they are.
    file_key(save)
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || "-_.!~*'()".contains(c) { c.to_string() } else { format!("%{:02X}", c as u32) })
        .collect::<String>()
        + ".json"
}

impl AccountStore {
    pub fn new(folder: impl Into<PathBuf>) -> Self {
        Self { folder: folder.into(), saves: Mutex::new(None) }
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    /// Copies account files from an earlier app's folder that this folder
    /// does not have yet.
    pub fn adopt(&self, legacy: &Path) -> std::io::Result<usize> {
        if legacy == self.folder || !legacy.is_dir() {
            return Ok(0);
        }
        fs::create_dir_all(&self.folder)?;
        let mut copied = 0;
        for entry in fs::read_dir(legacy)? {
            let entry = entry?;
            let name = entry.file_name();
            if !name.to_string_lossy().ends_with(".json") {
                continue;
            }
            let target = self.folder.join(&name);
            if !target.exists() {
                fs::copy(entry.path(), target)?;
                copied += 1;
            }
        }
        if copied > 0 {
            *self.saves.lock().unwrap() = None;
        }
        Ok(copied)
    }

    fn load_locked(&self, slot: &mut Option<Vec<GameSave>>) {
        if slot.is_some() {
            return;
        }
        let mut saves = Vec::new();
        if let Ok(entries) = fs::read_dir(&self.folder) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("json") {
                    continue;
                }
                let Ok(bytes) = fs::read(&path) else { continue };
                if let Some(save) = serde_json::from_slice::<Value>(&bytes).ok().and_then(|v| decode(&v)) {
                    saves.push(save);
                }
            }
        }
        sort(&mut saves);
        *slot = Some(saves);
    }

    pub fn saves(&self) -> Vec<GameSave> {
        let mut slot = self.saves.lock().unwrap();
        self.load_locked(&mut slot);
        slot.clone().unwrap_or_default()
    }

    pub fn find(&self, key: &str) -> Option<GameSave> {
        self.saves().into_iter().find(|s| s.key() == key)
    }

    /// Stores [incoming], merged with the same account's newest documents.
    pub fn put(&self, incoming: GameSave) -> std::io::Result<GameSave> {
        let mut slot = self.saves.lock().unwrap();
        self.load_locked(&mut slot);
        let saves = slot.as_mut().unwrap();
        let previous = saves.iter().find(|s| file_key(s) == file_key(&incoming)).cloned();
        let retain_metadata = matches!(
            (incoming.modified_at(), previous.as_ref().and_then(GameSave::modified_at)),
            (Some(a), Some(b)) if a < b
        );
        let metadata = if retain_metadata { previous.clone().unwrap() } else { incoming.clone() };
        let mut save = GameSave {
            profile_id: metadata.profile_id.clone(),
            name: metadata.name.clone().or_else(|| previous.as_ref().and_then(|p| p.name.clone())),
            release: metadata.release,
            source: metadata.source.clone(),
            documents: previous.as_ref().map(|p| p.documents.clone()).unwrap_or_default(),
        };
        for (kind, document) in incoming.documents {
            let older = matches!(
                (save.documents.get(&kind).and_then(|d| d.modified_at), document.modified_at),
                (Some(old), Some(new)) if new < old
            );
            if !older {
                save.documents.insert(kind, document);
            }
        }
        fs::create_dir_all(&self.folder)?;
        let target = self.folder.join(file_name(&save));
        let temporary = self.folder.join(format!(
            "{}.{}.tmp",
            file_name(&save),
            Utc::now().timestamp_micros()
        ));
        let text = serde_json::to_vec(&encode(&save)).map_err(std::io::Error::other)?;
        let written = (|| {
            let mut file = fs::File::create(&temporary)?;
            file.write_all(&text)?;
            file.sync_all()?;
            fs::rename(&temporary, &target)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        written?;
        saves.retain(|s| file_key(s) != file_key(&save));
        saves.push(save.clone());
        sort(saves);
        Ok(save)
    }

    pub fn remove(&self, key: &str) -> std::io::Result<()> {
        let mut slot = self.saves.lock().unwrap();
        self.load_locked(&mut slot);
        let saves = slot.as_mut().unwrap();
        if let Some(save) = saves.iter().find(|s| s.key() == key) {
            let path = self.folder.join(file_name(save));
            if path.exists() {
                fs::remove_file(path)?;
            }
        }
        saves.retain(|s| s.key() != key);
        Ok(())
    }
}

fn sort(saves: &mut [GameSave]) {
    saves.sort_by(|a, b| b.modified_at().cmp(&a.modified_at()));
}

/// One account as stored (`haneoka-account-v1`).
pub fn encode(save: &GameSave) -> Value {
    let documents: Map<String, Value> = save
        .documents
        .iter()
        .map(|(kind, document)| {
            (
                kind.name().to_owned(),
                json!({
                    "modifiedAt": document.modified_at.map(|d| d.to_rfc3339_opts(chrono::SecondsFormat::Micros, true)),
                    "data": document.data,
                }),
            )
        })
        .collect();
    json!({
        "schema": "haneoka-account-v1",
        "profileId": save.profile_id,
        "name": save.name,
        "release": save.release.map(GameRelease::name),
        "source": save.source,
        "documents": documents,
    })
}

/// An account read back from [encode]; None for anything else.
pub fn decode(value: &Value) -> Option<GameSave> {
    if value.get("schema")?.as_str()? != "haneoka-account-v1" {
        return None;
    }
    let profile_id = match value.get("profileId")? {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    let valid = !profile_id.is_empty()
        && profile_id.len() <= 19
        && !profile_id.starts_with('0')
        && profile_id.bytes().all(|b| b.is_ascii_digit())
        && (profile_id.len() < 19 || profile_id.as_str() <= "9223372036854775807");
    if !valid {
        return None;
    }
    let mut documents = BTreeMap::new();
    if let Some(map) = value.get("documents").and_then(Value::as_object) {
        for (key, entry) in map {
            let Some(kind) = DocumentKind::from_name(key) else { continue };
            let data = entry.get("data").and_then(Value::as_object).cloned().unwrap_or_default();
            let modified_at = entry
                .get("modifiedAt")
                .and_then(Value::as_str)
                .and_then(parse_date);
            documents.insert(kind, SaveDocument { kind, data, modified_at });
        }
    }
    Some(GameSave {
        profile_id,
        name: value.get("name").and_then(Value::as_str).map(str::to_owned),
        release: value.get("release").and_then(Value::as_str).and_then(GameRelease::from_name),
        source: value.get("source").and_then(Value::as_str).unwrap_or_default().to_owned(),
        documents,
    })
}

/// Dart's `toIso8601String` omits the zone for local times; those were
/// written as UTC by the Flutter app.
fn parse_date(text: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(text)
        .map(|d| d.with_timezone(&Utc))
        .ok()
        .or_else(|| chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S%.f").ok().map(|d| d.and_utc()))
}
