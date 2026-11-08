//! Saves as the game keeps them: three documents per account, grouped by the
//! player ID in `LocalCacheData`.

use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, Utc};
use serde_json::{Map, Value};

use crate::codec;

/// Which release a save belongs to. Android packages and iOS bundle IDs share
/// these names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GameRelease {
    IntlOfficial,
    IntlStore,
    Jp,
}

impl GameRelease {
    pub const ALL: [GameRelease; 3] = [GameRelease::IntlOfficial, GameRelease::IntlStore, GameRelease::Jp];

    pub fn package_id(self) -> &'static str {
        match self {
            GameRelease::IntlOfficial => "com.bilibili.sirius.official",
            GameRelease::IntlStore => "com.bilibili.sirius",
            GameRelease::Jp => "com.bushiroad.sirius",
        }
    }

    /// The name stored in account files (`haneoka-account-v1`).
    pub fn name(self) -> &'static str {
        match self {
            GameRelease::IntlOfficial => "intlOfficial",
            GameRelease::IntlStore => "intlStore",
            GameRelease::Jp => "jp",
        }
    }

    pub fn server(self) -> &'static str {
        match self {
            GameRelease::Jp => "jp",
            _ => "intl",
        }
    }

    pub fn from_package(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.package_id() == id)
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.name() == name)
    }

    /// A path under the game's own data folder names its package.
    pub fn from_path(path: &str) -> Option<Self> {
        let parts: Vec<&str> = path.split(['/', '\\']).collect();
        Self::ALL.into_iter().find(|r| parts.contains(&r.package_id()))
    }
}

/// The game region an 11-digit player ID belongs to: its first digit names it.
pub fn region_of_profile(profile_id: &str) -> Option<&'static str> {
    let bytes = profile_id.as_bytes();
    if bytes.len() != 11 || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    match bytes[0] {
        b'2' => Some("tw"),
        b'3' => Some("en"),
        b'4' => Some("kr"),
        b'5' => Some("jp"),
        _ => None,
    }
}

/// The catalogue server holding a player's cards.
pub fn server_of_profile(profile_id: &str) -> Option<&'static str> {
    region_of_profile(profile_id).map(|region| if region == "jp" { "jp" } else { "intl" })
}

pub fn region_name(region: &str) -> Option<&'static str> {
    match region {
        "jp" => Some("JP"),
        "tw" => Some("TW/HK/MO"),
        "en" => Some("EN Regions"),
        "kr" => Some("KR"),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DocumentKind {
    /// `LocalCacheData`: settings plus `_player`, the account's progress.
    Cache,
    /// `LocalPersistData`: latest live result, story resume points, the session.
    Persist,
    /// `LocalPermanentData`: device-level flags.
    Permanent,
}

impl DocumentKind {
    pub const ALL: [DocumentKind; 3] = [DocumentKind::Cache, DocumentKind::Persist, DocumentKind::Permanent];

    pub fn name(self) -> &'static str {
        match self {
            DocumentKind::Cache => "cache",
            DocumentKind::Persist => "persist",
            DocumentKind::Permanent => "permanent",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.name() == name)
    }

    fn of(data: &Map<String, Value>) -> Option<Self> {
        if data.contains_key("_player") {
            Some(DocumentKind::Cache)
        } else if ["_tutorialPhase", "_latestLiveResult", "_advResumePoints"].iter().any(|k| data.contains_key(*k)) {
            Some(DocumentKind::Persist)
        } else if ["_isTutorialCompleted", "_bulkDownloadLastCompletedAtTicks"].iter().any(|k| data.contains_key(*k)) {
            Some(DocumentKind::Permanent)
        } else {
            None
        }
    }
}

#[derive(Clone, Debug)]
pub struct SaveDocument {
    pub kind: DocumentKind,
    pub data: Map<String, Value>,
    pub modified_at: Option<DateTime<Utc>>,
}

impl SaveDocument {
    fn newer_than(&self, previous: &SaveDocument) -> bool {
        match (self.modified_at, previous.modified_at) {
            (Some(a), Some(b)) => a > b,
            (Some(_), None) => true,
            _ => false,
        }
    }
}

#[derive(Clone, Debug)]
pub struct GameSave {
    /// The in-game player ID (`_profileId`).
    pub profile_id: String,
    pub name: Option<String>,
    pub release: Option<GameRelease>,
    /// Where the files were read from, for display.
    pub source: String,
    pub documents: BTreeMap<DocumentKind, SaveDocument>,
}

impl GameSave {
    pub fn region(&self) -> Option<&'static str> {
        region_of_profile(&self.profile_id)
    }

    pub fn server(&self) -> Option<&'static str> {
        server_of_profile(&self.profile_id).or_else(|| self.release.map(GameRelease::server))
    }

    /// The bridge's key for this save.
    pub fn key(&self) -> String {
        format!("{}-{}", self.server().unwrap_or("null"), self.profile_id)
    }

    pub fn player(&self) -> Option<&Map<String, Value>> {
        self.documents.get(&DocumentKind::Cache)?.data.get("_player")?.as_object()
    }

    pub fn modified_at(&self) -> Option<DateTime<Utc>> {
        self.documents.get(&DocumentKind::Cache)?.modified_at
    }

    pub fn rows(&self, field: &str) -> Vec<&Map<String, Value>> {
        self.player()
            .and_then(|p| p.get(field))
            .and_then(Value::as_array)
            .map(|rows| rows.iter().filter_map(Value::as_object).collect())
            .unwrap_or_default()
    }

    pub fn player_rank(&self) -> Option<i64> {
        integer(self.player()?.get("_playerRankUpData")?.get("_afterRank")?)
    }
}

pub fn integer(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n.as_i64().or_else(|| n.to_string().parse().ok()),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// A file offered to the collector.
#[derive(Clone, Debug)]
pub struct SaveCandidate {
    pub source: String,
    pub modified_at: Option<DateTime<Utc>>,
    pub release: Option<GameRelease>,
    /// Files from the same account directory share a group, which is how the
    /// persist and permanent documents find their player.
    pub group: Option<String>,
}

type Group = (Option<&'static str>, String);

/// Turns candidate files into saves, whatever they came from. Names are
/// content hashes that change between versions, so a file is a save exactly
/// when it decrypts; the newest copy of an account wins.
#[derive(Default)]
pub struct SaveCollector {
    by_profile: HashMap<String, GameSave>,
    profiles_of_group: HashMap<Group, HashSet<String>>,
    documents: HashMap<(Group, DocumentKind), SaveDocument>,
    pub unreadable: usize,
}

impl SaveCollector {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns true when the bytes were a save document.
    pub fn offer(&mut self, bytes: &[u8], candidate: &SaveCandidate) -> bool {
        match codec::decode(bytes) {
            Some(data) => self.offer_json(data, candidate),
            None => false,
        }
    }

    /// A decoded JSON document: a game document, or a Haneoka export that
    /// holds all three.
    pub fn offer_json(&mut self, document: Map<String, Value>, candidate: &SaveCandidate) -> bool {
        if document.get("schema").and_then(Value::as_str) != Some("haneoka-game-save-v1") {
            return self.offer_document(document, candidate);
        }
        let Some(player) = document.get("player").and_then(Value::as_object).cloned() else {
            return false;
        };
        let metadata = SaveCandidate {
            source: candidate.source.clone(),
            group: candidate.group.clone(),
            release: document
                .get("release")
                .and_then(Value::as_str)
                .and_then(GameRelease::from_package)
                .or(candidate.release),
            modified_at: document
                .get("savedAt")
                .and_then(Value::as_str)
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.with_timezone(&Utc))
                .or(candidate.modified_at),
        };
        let mut cache = document.get("settings").and_then(Value::as_object).cloned().unwrap_or_default();
        cache.insert("_player".into(), Value::Object(player));
        let found = self.offer_document(cache, &metadata);
        for key in ["persist", "permanent"] {
            if let Some(data) = document.get(key).and_then(Value::as_object) {
                self.offer_document(data.clone(), &metadata);
            }
        }
        found
    }

    fn offer_document(&mut self, data: Map<String, Value>, candidate: &SaveCandidate) -> bool {
        let Some(kind) = DocumentKind::of(&data) else {
            self.unreadable += 1;
            return false;
        };
        let group: Group = (
            candidate.release.map(GameRelease::server),
            candidate.group.clone().unwrap_or_else(|| candidate.source.clone()),
        );
        let id = data.get("_player").and_then(Value::as_object).and_then(|p| profile_id(p.get("_profileId")?));
        let name = data
            .get("_player")
            .and_then(|p| p.get("_name"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_owned);
        let document = SaveDocument { kind, data, modified_at: candidate.modified_at };
        if kind != DocumentKind::Cache {
            let key = (group, kind);
            if self.documents.get(&key).is_none_or(|previous| document.newer_than(previous)) {
                self.documents.insert(key, document);
            }
            self.bind_documents();
            return true;
        }
        let Some(id) = id else {
            self.unreadable += 1;
            return false;
        };
        let identity = format!(
            "{}:{id}",
            server_of_profile(&id).or(candidate.release.map(GameRelease::server)).unwrap_or("unknown")
        );
        let existing = self.by_profile.get(&identity);
        let newer = match existing {
            None => true,
            Some(existing) => match (candidate.modified_at, existing.modified_at()) {
                (Some(a), Some(b)) => a > b,
                (Some(_), None) => true,
                _ => false,
            },
        };
        if newer {
            let release = candidate.release.or(existing.and_then(|e| e.release));
            let mut save = GameSave { profile_id: id, name, release, source: candidate.source.clone(), documents: BTreeMap::new() };
            save.documents.insert(DocumentKind::Cache, document);
            self.by_profile.insert(identity.clone(), save);
        }
        self.profiles_of_group.entry(group).or_default().insert(identity);
        self.bind_documents();
        true
    }

    fn bind_documents(&mut self) {
        for save in self.by_profile.values_mut() {
            save.documents.retain(|kind, _| *kind == DocumentKind::Cache);
        }
        for ((group, _), document) in &self.documents {
            let Some(profiles) = self.profiles_of_group.get(group) else { continue };
            if profiles.len() != 1 {
                continue;
            }
            let Some(save) = self.by_profile.get_mut(profiles.iter().next().unwrap()) else { continue };
            if save.documents.get(&document.kind).is_none_or(|current| document.newer_than(current)) {
                save.documents.insert(document.kind, document.clone());
            }
        }
    }

    pub fn saves(self) -> Vec<GameSave> {
        self.by_profile.into_values().collect()
    }

    pub fn is_empty(&self) -> bool {
        self.by_profile.is_empty()
    }
}

fn profile_id(raw: &Value) -> Option<String> {
    let text = match raw {
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.trim().to_owned(),
        _ => return None,
    };
    let valid = !text.is_empty()
        && text.len() <= 19
        && text.as_bytes()[0] != b'0'
        && text.bytes().all(|b| b.is_ascii_digit())
        && (text.len() < 19 || text.as_str() <= "9223372036854775807");
    valid.then_some(text)
}
