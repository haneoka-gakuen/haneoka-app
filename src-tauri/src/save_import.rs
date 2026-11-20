use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::AppState;

#[derive(Clone, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    pub key: String,
    pub server: String,
    pub actions: Vec<String>,
    #[serde(default, rename = "accountScoped")]
    pub account_scoped: bool,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default, rename = "savedAt")]
    pub saved_at: Option<i64>,
}

const ACTIONS: [&str; 5] = ["team", "songs", "history", "link", "save"];

pub fn options(state: &AppState) -> serde_json::Value {
    let saved = read(&state.config.join("save-import-options.json"));
    serde_json::Value::Object(ACTIONS.into_iter().map(|key| {
        (key.to_owned(), serde_json::json!(saved[key].as_bool().unwrap_or(true)))
    }).collect())
}

pub fn set_options(state: &AppState, patch: &serde_json::Value) -> Result<serde_json::Value, String> {
    let _lock = state.pending.lock().unwrap();
    let mut settings = options(state);
    for key in ACTIONS {
        if let Some(value) = patch[key].as_bool() {
            settings[key] = serde_json::json!(value);
        }
    }
    write(&state.config.join("save-import-options.json"), &settings)?;
    Ok(settings)
}

pub fn enqueue(state: &AppState, keys: &[String]) -> Result<(), String> {
    let _lock = state.pending.lock().unwrap();
    let options = options(state);
    let mut jobs = read_jobs(state);
    let previous = jobs.clone();
    let accounts = state.accounts.saves();
    let owner = state.preference("saveImportOwner").as_str().map(str::to_owned);
    for save in accounts.iter().filter(|save| keys.contains(&save.key())) {
        let Some(server) = save.server() else { continue };
        let key = save.key();
        jobs.retain(|job| job.key != key || job.account_scoped && job.owner != owner);
        let actions = ACTIONS.into_iter().filter(|action| options[*action] == true)
            .map(str::to_owned).collect::<Vec<_>>();
        if actions.is_empty() { continue; }
        jobs.push(Job {
            id: format!("{:016x}", rand::random::<u64>()),
            key,
            server: server.into(),
            actions,
            account_scoped: true,
            owner: owner.clone(),
            saved_at: save.modified_at().map(|date| date.timestamp_millis()),
        });
    }
    jobs.retain(|job| !job.actions.is_empty());
    write(&state.config.join("save-import-jobs.json"), &jobs)?;
    for old in previous {
        for action in old.actions {
            if !jobs.iter().any(|job| job.id == old.id && job.actions.contains(&action)) {
                let _ = fs::remove_file(result_path(state, &old.id, &action));
            }
        }
    }
    Ok(())
}

pub fn jobs(state: &AppState) -> Vec<Job> {
    let _lock = state.pending.lock().unwrap();
    read_jobs(state)
}

pub fn complete(state: &AppState, id: &str, action: &str) -> Result<(), String> {
    let _lock = state.pending.lock().unwrap();
    let mut jobs = read_jobs(state);
    if let Some(job) = jobs.iter_mut().find(|job| job.id == id && job.actions.iter().any(|value| value == action)) {
        job.actions.retain(|value| value != action);
        jobs.retain(|job| !job.actions.is_empty());
        write(&state.config.join("save-import-jobs.json"), &jobs)?;
        let _ = fs::remove_file(result_path(state, id, action));
    }
    Ok(())
}

pub fn prepared(state: &AppState, id: &str, action: &str) -> Option<Result<serde_json::Value, String>> {
    serde_json::from_value(read(&result_path(state, id, action))).ok()
}

pub fn save_prepared(state: &AppState, id: &str, action: &str, result: &Result<serde_json::Value, String>) {
    let _lock = state.pending.lock().unwrap();
    if read_jobs(state).iter().any(|job| job.id == id && job.actions.iter().any(|item| item == action)) {
        let _ = write(&result_path(state, id, action), result);
    }
}

fn result_path(state: &AppState, id: &str, action: &str) -> std::path::PathBuf {
    state.config.join("save-import-results").join(format!("{id}-{action}.json"))
}

fn read_jobs(state: &AppState) -> Vec<Job> {
    serde_json::from_value(read(&state.config.join("save-import-jobs.json"))).unwrap_or_default()
}

fn read(path: &Path) -> serde_json::Value {
    fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

fn write(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let data = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let temporary = path.with_extension("tmp");
    fs::create_dir_all(path.parent().expect("config directory"))
        .and_then(|()| fs::write(&temporary, data))
        .and_then(|()| fs::rename(temporary, path))
        .map_err(|error| error.to_string())
}
