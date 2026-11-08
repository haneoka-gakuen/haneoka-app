//! A local iPhone or iPad backup made by Finder (macOS), Apple Devices or
//! iTunes (Windows), or `idevicebackup2` (Linux).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use aes::cipher::{generic_array::GenericArray, BlockDecrypt, BlockDecryptMut, KeyInit, KeyIvInit};
use chrono::{DateTime, TimeZone, Utc};
use plist::Value as Plist;
use serde::Serialize;

use crate::codec::MAX_FILE_BYTES;
use crate::save::{GameRelease, SaveCandidate, SaveCollector};

#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error("backup_password")]
    Password,
    #[error("backup_unreadable")]
    Unreadable,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct BackupInfo {
    pub path: String,
    pub device_name: Option<String>,
    pub product_type: Option<String>,
    pub date: Option<i64>,
    pub encrypted: bool,
}

/// Where the system tools keep backups. macOS needs Full Disk Access for
/// this folder; Linux backups live wherever `idevicebackup2` wrote them.
pub fn default_folders() -> Vec<PathBuf> {
    let env = |key: &str| std::env::var_os(key).map(PathBuf::from).unwrap_or_default();
    if cfg!(target_os = "macos") {
        vec![env("HOME").join("Library/Application Support/MobileSync/Backup")]
    } else if cfg!(windows) {
        vec![env("APPDATA").join("Apple Computer/MobileSync/Backup"), env("USERPROFILE").join("Apple/MobileSync/Backup")]
    } else {
        Vec::new()
    }
}

fn read_plist(path: &Path) -> Option<plist::Dictionary> {
    Plist::from_file(path).ok()?.into_dictionary()
}

fn date(value: Option<&Plist>) -> Option<i64> {
    let date = value?.as_date()?;
    Some(std::time::SystemTime::from(date).duration_since(std::time::UNIX_EPOCH).ok()?.as_millis() as i64)
}

pub fn open(path: &Path) -> Option<BackupInfo> {
    if !path.join("Manifest.db").is_file() {
        return None;
    }
    let manifest = read_plist(&path.join("Manifest.plist"))?;
    let info = read_plist(&path.join("Info.plist")).unwrap_or_default();
    let lockdown = manifest.get("Lockdown").and_then(Plist::as_dictionary);
    let text = |key: &str, lock: &str| {
        info.get(key)
            .or_else(|| lockdown.and_then(|l| l.get(lock)))
            .and_then(Plist::as_string)
            .map(str::to_owned)
    };
    Some(BackupInfo {
        path: path.to_string_lossy().into_owned(),
        device_name: text("Device Name", "DeviceName"),
        product_type: text("Product Type", "ProductType"),
        date: date(info.get("Last Backup Date")).or_else(|| date(manifest.get("Date"))),
        encrypted: manifest.get("IsEncrypted").and_then(Plist::as_boolean).unwrap_or(false),
    })
}

/// Every backup directly inside [folder], or [folder] itself if it is one.
pub fn find(folder: &Path) -> Vec<BackupInfo> {
    if let Some(backup) = open(folder) {
        return vec![backup];
    }
    let mut out: Vec<BackupInfo> = std::fs::read_dir(folder)
        .map(|entries| entries.flatten().filter(|e| e.path().is_dir()).filter_map(|e| open(&e.path())).collect())
        .unwrap_or_default();
    out.sort_by(|a, b| b.date.cmp(&a.date));
    out
}

const SKIPPED: &[&str] = &["Library", "tmp", "EncryptedBundles", "Addressables", "UnityCache", "il2cpp"];

/// Offers the game's files in the backup at [path]; returns how many of the
/// game's files it holds. [password] is needed only for encrypted backups.
pub fn scan(path: &Path, password: Option<&str>, collector: &mut SaveCollector) -> Result<usize, BackupError> {
    let manifest = read_plist(&path.join("Manifest.plist")).ok_or(BackupError::Unreadable)?;
    let encrypted = manifest.get("IsEncrypted").and_then(Plist::as_boolean).unwrap_or(false);
    let keys = if encrypted { Some(Keys::unlock(&manifest, password.unwrap_or(""))?) } else { None };
    let temporary = tempfile::tempdir().map_err(|_| BackupError::Unreadable)?;
    let database = match &keys {
        None => path.join("Manifest.db"),
        Some(keys) => {
            let manifest_key = manifest.get("ManifestKey").and_then(Plist::as_data).ok_or(BackupError::Unreadable)?;
            if manifest_key.len() < 4 {
                return Err(BackupError::Unreadable);
            }
            let class = u32::from_le_bytes(manifest_key[..4].try_into().unwrap());
            let key = keys.unwrap(class, &manifest_key[4..])?;
            let encrypted = std::fs::read(path.join("Manifest.db")).map_err(|_| BackupError::Unreadable)?;
            let plain = cbc_decrypt(&key, &encrypted).ok_or(BackupError::Unreadable)?;
            let file = temporary.path().join("Manifest.db");
            std::fs::write(&file, plain).map_err(|_| BackupError::Unreadable)?;
            file
        }
    };
    let db = rusqlite::Connection::open_with_flags(&database, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|_| BackupError::Unreadable)?;
    let domains: HashMap<String, GameRelease> =
        GameRelease::ALL.into_iter().map(|r| (format!("AppDomain-{}", r.package_id()), r)).collect();
    let placeholders = vec!["?"; domains.len()].join(",");
    let mut statement = db
        .prepare(&format!("SELECT fileID, domain, relativePath, file FROM Files WHERE flags = 1 AND domain IN ({placeholders})"))
        .map_err(|_| BackupError::Unreadable)?;
    let names: Vec<&String> = domains.keys().collect();
    let mut rows = statement.query(rusqlite::params_from_iter(names)).map_err(|_| BackupError::Unreadable)?;
    let mut count = 0;
    while let Ok(Some(row)) = rows.next() {
        count += 1;
        let (Ok(file_id), Ok(domain), Ok(relative)) = (row.get::<_, String>(0), row.get::<_, String>(1), row.get::<_, String>(2)) else {
            continue;
        };
        if relative.split('/').any(|part| SKIPPED.contains(&part)) || file_id.len() < 2 {
            continue;
        }
        let stored = path.join(&file_id[..2]).join(&file_id);
        let Ok(length) = std::fs::metadata(&stored).map(|m| m.len() as usize) else { continue };
        let meta = FileMeta::read(row.get::<_, Option<Vec<u8>>>(3).ok().flatten().as_deref());
        if meta.size > MAX_FILE_BYTES || length > MAX_FILE_BYTES + 16 {
            continue;
        }
        let Ok(mut bytes) = std::fs::read(&stored) else { continue };
        if let Some(keys) = &keys {
            let Some(wrapped) = &meta.wrapped_key else { continue };
            let Ok(key) = keys.unwrap(meta.protection_class, wrapped) else { continue };
            let Some(mut plain) = cbc_decrypt(&key, &bytes) else { continue };
            if meta.size > 0 && meta.size <= plain.len() {
                plain.truncate(meta.size);
            }
            bytes = plain;
        }
        let directory = relative.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
        collector.offer(
            &bytes,
            &SaveCandidate {
                source: format!("{domain}/{relative}"),
                modified_at: meta.modified,
                release: domains.get(&domain).copied(),
                group: Some(format!("{domain}/{directory}")),
            },
        );
    }
    Ok(count)
}

/// The per-file record Manifest.db keeps as an NSKeyedArchiver blob.
struct FileMeta {
    size: usize,
    protection_class: u32,
    wrapped_key: Option<Vec<u8>>,
    modified: Option<DateTime<Utc>>,
}

impl FileMeta {
    fn read(blob: Option<&[u8]>) -> Self {
        let empty = FileMeta { size: 0, protection_class: 0, wrapped_key: None, modified: None };
        let Some(archive) = blob.and_then(|b| Plist::from_reader(std::io::Cursor::new(b)).ok()).and_then(Plist::into_dictionary) else {
            return empty;
        };
        let Some(objects) = archive.get("$objects").and_then(Plist::as_array) else { return empty };
        let uid = |value: Option<&Plist>| value.and_then(Plist::as_uid).map(|u| u.get() as usize);
        let Some(root) = uid(archive.get("$top").and_then(Plist::as_dictionary).and_then(|t| t.get("root")))
            .and_then(|i| objects.get(i))
            .and_then(Plist::as_dictionary)
        else {
            return empty;
        };
        let integer = |key: &str| root.get(key).and_then(Plist::as_unsigned_integer);
        let wrapped_key = uid(root.get("EncryptionKey"))
            .and_then(|i| objects.get(i))
            .and_then(Plist::as_dictionary)
            .and_then(|d| d.get("NS.data"))
            .and_then(Plist::as_data)
            .filter(|d| d.len() > 4)
            .map(|d| d[4..].to_vec());
        FileMeta {
            size: integer("Size").unwrap_or(0) as usize,
            protection_class: integer("ProtectionClass").unwrap_or(0) as u32,
            wrapped_key,
            modified: integer("LastModified").and_then(|s| Utc.timestamp_opt(s as i64, 0).single()),
        }
    }
}

/// The backup keybag, unlocked with the backup password.
struct Keys {
    classes: HashMap<u32, Vec<u8>>,
}

fn number(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0, |v, &b| (v << 8) | u64::from(b))
}

impl Keys {
    fn unlock(manifest: &plist::Dictionary, password: &str) -> Result<Self, BackupError> {
        let bag = manifest.get("BackupKeyBag").and_then(Plist::as_data).ok_or(BackupError::Unreadable)?;
        let mut attrs: HashMap<String, Vec<u8>> = HashMap::new();
        let mut classes: Vec<HashMap<String, Vec<u8>>> = Vec::new();
        let mut current: Option<HashMap<String, Vec<u8>>> = None;
        let mut at = 0;
        while at + 8 <= bag.len() {
            let tag = String::from_utf8_lossy(&bag[at..at + 4]).into_owned();
            let length = u32::from_be_bytes(bag[at + 4..at + 8].try_into().unwrap()) as usize;
            let Some(value) = bag.get(at + 8..at + 8 + length) else { break };
            at += 8 + length;
            if tag == "UUID" && attrs.contains_key("UUID") {
                classes.extend(current.take());
                current = Some(HashMap::from([(tag, value.to_vec())]));
            } else if let Some(class) = current.as_mut() {
                class.insert(tag, value.to_vec());
            } else {
                attrs.insert(tag, value.to_vec());
            }
        }
        classes.extend(current);
        let get = |key: &str| attrs.get(key).ok_or(BackupError::Unreadable);
        let mut secret = password.as_bytes().to_vec();
        if let Some(salt) = attrs.get("DPSL") {
            let mut derived = [0u8; 32];
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(&secret, salt, number(get("DPIC")?) as u32, &mut derived);
            secret = derived.to_vec();
        }
        let mut key = [0u8; 32];
        pbkdf2::pbkdf2_hmac::<sha1::Sha1>(&secret, get("SALT")?, number(get("ITER")?) as u32, &mut key);
        let mut keys = HashMap::new();
        for class in &classes {
            let (Some(wrapped), Some(cls), Some(wrap)) = (class.get("WPKY"), class.get("CLAS"), class.get("WRAP")) else { continue };
            if number(wrap) & 2 == 0 {
                continue;
            }
            keys.insert(number(cls) as u32, aes_unwrap(&key, wrapped).ok_or(BackupError::Password)?);
        }
        if keys.is_empty() {
            return Err(BackupError::Password);
        }
        Ok(Keys { classes: keys })
    }

    fn unwrap(&self, class: u32, wrapped: &[u8]) -> Result<Vec<u8>, BackupError> {
        self.classes.get(&class).and_then(|k| aes_unwrap(k, wrapped)).ok_or(BackupError::Password)
    }
}

fn decrypt_block(key: &[u8], block: &mut [u8; 16]) -> Option<()> {
    let block = GenericArray::from_mut_slice(block);
    match key.len() {
        16 => aes::Aes128::new_from_slice(key).ok()?.decrypt_block(block),
        32 => aes::Aes256::new_from_slice(key).ok()?.decrypt_block(block),
        _ => return None,
    }
    Some(())
}

/// RFC 3394 AES key unwrap; None when the integrity check fails (wrong password).
fn aes_unwrap(kek: &[u8], wrapped: &[u8]) -> Option<Vec<u8>> {
    if wrapped.len() < 24 || wrapped.len() % 8 != 0 {
        return None;
    }
    let n = wrapped.len() / 8 - 1;
    let mut a: [u8; 8] = wrapped[..8].try_into().ok()?;
    let mut r: Vec<[u8; 8]> = (0..n).map(|i| wrapped[8 + i * 8..16 + i * 8].try_into().unwrap()).collect();
    for j in (0..=5).rev() {
        for i in (1..=n).rev() {
            let t = (n * j + i) as u64;
            let mut block = [0u8; 16];
            for k in 0..8 {
                block[k] = a[k] ^ ((t >> (8 * (7 - k))) & 0xff) as u8;
            }
            block[8..].copy_from_slice(&r[i - 1]);
            decrypt_block(kek, &mut block)?;
            a.copy_from_slice(&block[..8]);
            r[i - 1].copy_from_slice(&block[8..]);
        }
    }
    (a == [0xa6; 8]).then(|| r.concat())
}

/// AES-256-CBC with a zero IV, as backups use; trailing PKCS#7 padding removed.
fn cbc_decrypt(key: &[u8], data: &[u8]) -> Option<Vec<u8>> {
    let length = data.len() - data.len() % 16;
    let mut out = data[..length].to_vec();
    let decryptor = cbc::Decryptor::<aes::Aes256>::new_from_slices(key, &[0u8; 16]).ok()?;
    let mut decryptor = decryptor;
    for chunk in out.chunks_exact_mut(16) {
        decryptor.decrypt_block_mut(GenericArray::from_mut_slice(chunk));
    }
    if let Some(&pad) = out.last() {
        let pad = pad as usize;
        if (1..=16).contains(&pad) && out[out.len() - pad..].iter().all(|&b| b as usize == pad) {
            out.truncate(out.len() - pad);
        }
    }
    Some(out)
}
