//! What leaves the app for the website: progress without identity.

use std::io::Write;

use base64::Engine;
use serde_json::{json, Map, Value};

use crate::save::{integer, DocumentKind, GameSave};

/// Fields that identify the person or let someone act as them. They never
/// leave the device in an export.
const IDENTITY_FIELDS: &[&str] = &[
    "_name",
    "_accountid",
    "_accountId",
    "_password",
    "_hasPassword",
    "_friendInvitationCode",
    "_linkedAccountTypes",
    "_specialFocusAccountIds",
    "_certification",
    "_grantedIapTransactions",
    "_cpServerId",
    "_cpServerName",
    "_world_room_id",
    "_reportedPlayerIds",
    "_friendProfile",
    "_sendingRequestProfile",
    "_pendingApprovalProfile",
    "_externalPaymentNotifications",
    "_chatRead",
];

pub fn without_identity(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter(|(k, _)| !IDENTITY_FIELDS.contains(&k.as_str()))
                .map(|(k, v)| (k.clone(), without_identity(v)))
                .collect(),
        ),
        Value::Array(rows) => Value::Array(rows.iter().map(without_identity).collect()),
        other => other.clone(),
    }
}

fn saved_at(save: &GameSave) -> Value {
    save.modified_at()
        .map(|d| Value::String(d.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)))
        .unwrap_or(Value::Null)
}

/// The progress snapshot the website's save workspace stores: the player
/// document only.
pub fn snapshot(save: &GameSave) -> String {
    let player = save.player().map(|p| without_identity(&Value::Object(p.clone()))).unwrap_or(Value::Null);
    json!({
        "schema": "haneoka-game-save-v1",
        "server": save.server(),
        "savedAt": saved_at(save),
        "player": player,
    })
    .to_string()
}

/// The whole save, minus identity: every progress, collection, result and
/// setting the game keeps.
pub fn full(save: &GameSave) -> Vec<u8> {
    let cache = save.documents.get(&DocumentKind::Cache).map(|d| d.data.clone()).unwrap_or_default();
    let settings: Map<String, Value> = cache.iter().filter(|(k, _)| *k != "_player").map(|(k, v)| (k.clone(), v.clone())).collect();
    let document = |kind| save.documents.get(&kind).map(|d| without_identity(&Value::Object(d.data.clone()))).unwrap_or(Value::Null);
    let value = json!({
        "schema": "haneoka-game-save-v1",
        "server": save.server(),
        "release": save.release.map(|r| r.package_id()),
        "exportedAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "savedAt": saved_at(save),
        "player": cache.get("_player").map(without_identity).unwrap_or(Value::Null),
        "settings": without_identity(&Value::Object(settings)),
        "persist": document(DocumentKind::Persist),
        "permanent": document(DocumentKind::Permanent),
    });
    serde_json::to_vec_pretty(&value).unwrap_or_default()
}

fn decimal(value: Option<&Value>) -> Value {
    match value {
        None | Some(Value::Null) => Value::Null,
        Some(Value::String(s)) => Value::String(s.clone()),
        Some(other) => Value::String(other.to_string()),
    }
}

fn field(row: &Map<String, Value>, key: &str) -> Value {
    row.get(key).cloned().unwrap_or(Value::Null)
}

/// `ONPKG1:` text for the team builder: card, character and band item
/// progress as positional rows. Experience stays a decimal string.
pub fn team_package(save: &GameSave) -> String {
    let package = json!({
        "v": 1,
        "m": save.rows("_memberCards").iter().map(|row| json!([
            field(row, "_masterId"), decimal(row.get("_exp")), field(row, "_awakeCount"),
            field(row, "_rank"), field(row, "_liveSkillLevel"), field(row, "_performanceSkillLevel"),
        ])).collect::<Vec<_>>(),
        "s": save.rows("_supportCards").iter().map(|row| json!([
            field(row, "_masterId"), decimal(row.get("_exp")), field(row, "_rank"),
        ])).collect::<Vec<_>>(),
        "c": save.rows("_characters").iter().map(|row| json!([
            field(row, "_masterId"), decimal(row.get("_exp")),
        ])).collect::<Vec<_>>(),
        "b": save.rows("_bandItems").iter().map(|row| json!([
            field(row, "_masterId"), field(row, "_level"),
        ])).collect::<Vec<_>>(),
    });
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(package.to_string().as_bytes()).expect("memory write");
    let zipped = encoder.finish().expect("memory write");
    format!("ONPKG1:{}", base64::engine::general_purpose::STANDARD.encode(zipped))
}

/// Each chart's clear mark for the website's song progress
/// (`l.{song}.{difficulty}`): `_<difficulty>ClearedStatus` 10, 20 and 30 as
/// clear, full combo and all perfect.
pub fn song_marks(save: &GameSave) -> Map<String, Value> {
    let mut marks = Map::new();
    for row in save.rows("_liveMusicResults") {
        let Some(song) = row.get("_mLiveMusicId") else { continue };
        let song = match song {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        for (index, name) in ["easy", "normal", "hard", "expert"].iter().enumerate() {
            let status = row.get(&format!("_{name}ClearedStatus")).and_then(integer).unwrap_or(0);
            let mark = match status {
                s if s >= 30 => 3,
                s if s >= 20 => 2,
                s if s >= 10 => 1,
                _ => 0,
            };
            if mark > 0 {
                marks.insert(format!("l.{song}.{index}"), json!(mark));
            }
        }
    }
    marks
}

/// One row of the bridge's `gameAccounts`.
pub fn account_entry(save: &GameSave) -> Value {
    json!({
        "key": save.key(),
        "name": save.name,
        "profileId": save.profile_id,
        "region": save.region().and_then(crate::save::region_name),
        "server": save.server(),
        "rank": save.player_rank(),
        "savedAt": save.modified_at().map(|d| d.timestamp_millis()),
        "canRefresh": crate::game::session(save).is_some() && crate::game::Region::of(save).is_some(),
        "release": save.release.map(|r| r.package_id()),
    })
}

/// Everything a save's page shows, without identity: the player document,
/// the settings beside it and the latest-live document.
pub fn detail(save: &GameSave) -> Value {
    let cache = save.documents.get(&DocumentKind::Cache).map(|d| d.data.clone()).unwrap_or_default();
    let settings: Map<String, Value> = cache.iter().filter(|(k, _)| *k != "_player").map(|(k, v)| (k.clone(), v.clone())).collect();
    json!({
        "account": account_entry(save),
        "release": save.release.map(|r| r.package_id()),
        "player": cache.get("_player").map(without_identity).unwrap_or(Value::Null),
        "settings": without_identity(&Value::Object(settings)),
        "persist": save.documents.get(&DocumentKind::Persist).map(|d| without_identity(&Value::Object(d.data.clone()))).unwrap_or(Value::Null),
    })
}
