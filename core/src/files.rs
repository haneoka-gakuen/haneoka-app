//! Files, folders and ZIP archives the user picked: a copied account folder,
//! single save files, or an archive such as an app-container export.

use std::fs;
use std::io::{Read, Seek};
use std::path::Path;

use chrono::{DateTime, TimeZone, Utc};

use crate::codec::MAX_FILE_BYTES;
use crate::save::{GameRelease, SaveCandidate, SaveCollector};

/// The game's asset caches sit next to the account directories and hold
/// gigabytes of bundles and no saves; a folder walk never enters them.
pub const SKIPPED_DIRECTORIES: &[&str] = &[
    "EncryptedBundles",
    "Addressables",
    "Master",
    "RemoteCatalog",
    "il2cpp",
    "Unity",
    "UnityCache",
    "cache",
    "tmp",
    "com.unity3d.player",
    "Library",
];

const MAX_DEPTH: usize = 6;

pub struct FileSource<'a> {
    pub collector: &'a mut SaveCollector,
    /// The release the user named; a picked file does not say which it came from.
    pub release: Option<GameRelease>,
}

fn is_zip(bytes: &[u8]) -> bool {
    bytes.starts_with(b"PK\x03\x04")
}

fn parent(path: &str) -> String {
    match path.rfind(['/', '\\']) {
        Some(i) => path[..i].to_owned(),
        None => String::new(),
    }
}

impl FileSource<'_> {
    pub fn add_path(&mut self, path: &Path) {
        if path.is_dir() {
            self.walk(path, 0);
        } else if path.is_file() {
            self.file(path);
        }
    }

    pub fn add_bytes(&mut self, bytes: &[u8], name: &str, modified_at: Option<DateTime<Utc>>) {
        if is_zip(bytes) {
            self.zip(std::io::Cursor::new(bytes), name);
        } else {
            self.offer(bytes, name, modified_at, parent(name));
        }
    }

    fn walk(&mut self, directory: &Path, depth: usize) {
        if depth > MAX_DEPTH {
            return;
        }
        // A folder the app may not read holds no save it could import.
        let Ok(entries) = fs::read_dir(directory) else { return };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_dir() {
                if !SKIPPED_DIRECTORIES.contains(&entry.file_name().to_string_lossy().as_ref()) {
                    self.walk(&path, depth + 1);
                }
            } else if kind.is_file() {
                self.file(&path);
            }
        }
    }

    fn file(&mut self, path: &Path) {
        let Ok(metadata) = fs::metadata(path) else { return };
        if metadata.len() == 0 {
            return;
        }
        let Ok(mut file) = fs::File::open(path) else { return };
        let mut header = [0u8; 4];
        let is_archive = file.read_exact(&mut header).is_ok() && is_zip(&header);
        let name = path.to_string_lossy().into_owned();
        if is_archive {
            if file.rewind().is_ok() {
                self.zip(std::io::BufReader::new(file), &name);
            }
            return;
        }
        if metadata.len() as usize > MAX_FILE_BYTES {
            return;
        }
        let Ok(bytes) = fs::read(path) else { return };
        let modified = metadata.modified().ok().map(DateTime::<Utc>::from);
        let group = path.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        self.offer(&bytes, &name, modified, group);
    }

    fn offer(&mut self, bytes: &[u8], source: &str, modified_at: Option<DateTime<Utc>>, group: String) {
        let candidate = SaveCandidate {
            source: source.to_owned(),
            modified_at,
            release: self.release.or_else(|| GameRelease::from_path(source)),
            group: Some(group),
        };
        self.collector.offer(bytes, &candidate);
    }

    fn zip<R: Read + Seek>(&mut self, reader: R, name: &str) {
        let Ok(mut archive) = zip::ZipArchive::new(reader) else { return };
        let release = self.release.or_else(|| app_release(&mut archive)).or_else(|| GameRelease::from_path(name));
        for index in 0..archive.len() {
            let Ok(mut entry) = archive.by_index(index) else { continue };
            let entry_name = entry.name().to_owned();
            if !entry.is_file()
                || entry.size() == 0
                || entry.size() as usize > MAX_FILE_BYTES
                || entry_name.split(['/', '\\']).any(|part| SKIPPED_DIRECTORIES.contains(&part))
            {
                continue;
            }
            // A damaged or oversized entry; the other entries still import.
            let mut content = Vec::with_capacity(entry.size() as usize);
            if (&mut entry).take(MAX_FILE_BYTES as u64 + 1).read_to_end(&mut content).is_err() || content.len() > MAX_FILE_BYTES {
                continue;
            }
            let modified = entry.last_modified().and_then(|dos| {
                Utc.with_ymd_and_hms(
                    dos.year() as i32,
                    dos.month() as u32,
                    dos.day() as u32,
                    dos.hour() as u32,
                    dos.minute() as u32,
                    dos.second() as u32,
                )
                .single()
            });
            let candidate = SaveCandidate {
                source: format!("{name}!{entry_name}"),
                modified_at: modified,
                release: release.or_else(|| GameRelease::from_path(&entry_name)),
                group: Some(format!("{name}!{}", parent(&entry_name))),
            };
            self.collector.offer(&content, &candidate);
        }
    }
}

/// An app-container export (iMazing's `.imazingapp`) names its app in
/// `iTunesMetadata.plist`.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn app_release<R: Read + Seek>(archive: &mut zip::ZipArchive<R>) -> Option<GameRelease> {
    let index = (0..archive.len()).find(|&i| {
        archive.name_for_index(i).is_some_and(|n| n.rsplit('/').next() == Some("iTunesMetadata.plist"))
    })?;
    let mut entry = archive.by_index(index).ok()?;
    if entry.size() as usize > MAX_FILE_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes).ok()?;
    let value = plist::Value::from_reader(std::io::Cursor::new(bytes)).ok()?;
    GameRelease::from_package(value.as_dictionary()?.get("softwareVersionBundleId")?.as_string()?)
}

#[cfg(any(target_os = "android", target_os = "ios"))]
fn app_release<R: Read + Seek>(_: &mut zip::ZipArchive<R>) -> Option<GameRelease> {
    None
}
