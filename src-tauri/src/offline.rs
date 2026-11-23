//! Durable story downloads and the isolated local Vega origin.
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{stream, StreamExt, TryStreamExt};
use minisign_verify::{PublicKey, Signature};
use percent_encoding::percent_decode_str;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tauri::{
    http::{Request, Response},
    Manager, Url, WebviewWindow,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[path = "offline_queue.rs"]
mod queue;
#[path = "offline_sources.rs"]
mod sources;
use queue::{DownloadJob, JobState};
use sources::Source;

type Result<T> = std::result::Result<T, String>;
const SCHEMA: &str = "haneoka-story-offline-v2";
const PLAYER_SCHEMA: &str = "haneoka-story-player-v2";
const PROTOCOL: &str = "haneoka-story";
const MAX_DESCRIPTOR: usize = 16 * 1024 * 1024;
const MAX_PLAYER: u64 = 64 * 1024 * 1024;
const MAX_OBJECT: u64 = 128 * 1024 * 1024;
const CSP: &str = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob: data:; font-src 'self' data: blob:; connect-src 'self' blob:; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Player {
    schema: String,
    version: String,
    sha256: String,
    bytes: u64,
}

#[derive(Clone, Deserialize, Serialize)]
struct Episode {
    id: String,
    title: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    manifest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    thumbnail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bytes: Option<u64>,
}

#[derive(Clone, Deserialize, Serialize)]
struct Package {
    id: String,
    title: Value,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    manifest: String,
    bytes: u64,
    episodes: Vec<Episode>,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    group: Value,
    #[serde(rename = "groupId", skip_serializing_if = "Option::is_none")]
    group_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    thumbnail: Option<String>,
    #[serde(default)]
    missing_media: usize,
}

#[derive(Clone, Deserialize, Serialize)]
struct Catalog {
    schema: String,
    server: String,
    common: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root_sha: Option<String>,
    packages: Vec<Package>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pointer {
    schema: String,
    server: String,
    release_id: String,
    sha256: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct Reference {
    sha256: String,
    selector: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Object {
    bytes: u64,
    media_type: String,
}

#[derive(Deserialize)]
struct Manifest {
    schema: String,
    resources: BTreeMap<String, Reference>,
    objects: BTreeMap<String, Object>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Chapter {
    server: String,
    release_id: String,
    package: Package,
    resources: BTreeMap<String, Reference>,
    objects: BTreeMap<String, Object>,
}

impl Chapter {
    fn presented_package(&self) -> Package {
        let mut package = self.package.clone();
        let fallback = self
            .resources
            .iter()
            .find(|(path, row)| {
                [
                    "/bg/",
                    "/scenario/background/",
                    "/Adv/Stage/",
                    "/game/background/",
                ]
                .iter()
                .any(|prefix| path.contains(prefix))
                    && self
                        .objects
                        .get(&row.sha256)
                        .is_some_and(|object| thumbnail_type(&object.media_type))
            })
            .map(|(_, reference)| cover_url(&reference.sha256));
        let cover = |value: &str| {
            let url = Url::parse(value)
                .or_else(|_| Url::parse("https://haneoka.org").unwrap().join(value))
                .ok()?;
            let key = path_key(url.path()).ok()?;
            let full_key = url.query().map(|query| format!("{key}?{query}"));
            let reference = full_key
                .as_ref()
                .and_then(|full| self.resources.get(full))
                .or_else(|| self.resources.get(&key))?;
            let object = self.objects.get(&reference.sha256)?;
            thumbnail_type(&object.media_type).then(|| cover_url(&reference.sha256))
        };
        for episode in &mut package.episodes {
            episode.thumbnail = episode.thumbnail.as_deref().and_then(&cover);
            episode.manifest = None;
        }
        package.thumbnail = package
            .thumbnail
            .as_deref()
            .and_then(&cover)
            .or_else(|| {
                package
                    .episodes
                    .iter()
                    .find_map(|episode| episode.thumbnail.clone())
            })
            .or(fallback);
        package
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
struct Library {
    active: Option<Player>,
    previous: Option<Player>,
    pending: Option<Player>,
    rejected: Option<String>,
    chapters: BTreeMap<String, Chapter>,
    catalogs: BTreeMap<String, Catalog>,
    queue: Vec<DownloadJob>,
    queue_paused: bool,
}

struct Session {
    token: String,
    player: Player,
    chapter: Arc<Chapter>,
    episode: Episode,
    locale: String,
    theme: Option<&'static str>,
    ready: AtomicBool,
}

#[derive(Default)]
struct Transfer {
    downloaded: AtomicU64,
    total: AtomicU64,
    paused: AtomicBool,
    discovering: AtomicBool,
}

pub struct Offline {
    root: PathBuf,
    library: Mutex<Library>,
    transfer: Mutex<Option<Arc<Transfer>>>,
    session: Mutex<Option<Arc<Session>>>,
    action: tokio::sync::Mutex<()>,
    queue_running: AtomicBool,
}

fn fail(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || matches!(c, b'a'..=b'f'))
}

fn release_id(value: &str) -> bool {
    value.strip_prefix("r-").is_some_and(|id| {
        id.len() == 20
            && id
                .bytes()
                .all(|c| c.is_ascii_digit() || matches!(c, b'a'..=b'f'))
    })
}

fn path_key(value: &str) -> Result<String> {
    let value = percent_decode_str(value).decode_utf8().map_err(fail)?;
    let path = value.strip_prefix('/').ok_or("path")?;
    if path.len() > 2048
        || path.split('/').any(|segment| {
            segment.is_empty()
                || matches!(segment, "." | "..")
                || segment.contains(['\\', ':', '\0'])
        })
    {
        return Err("path".into());
    }
    Ok(path.to_owned())
}

fn atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let partial = path.with_extension("writing");
    let mut file = File::create(&partial).map_err(fail)?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(fail)?;
    drop(file);
    fs::rename(partial, path).map_err(fail)
}

fn read_json<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    serde_json::from_slice(bytes).map_err(fail)
}

fn client() -> Result<reqwest::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .user_agent("HaneokaApp offline stories")
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(25))
        .build()
        .map_err(fail)
}

async fn descriptor(
    client: &reqwest::Client,
    url: &str,
    expected: Option<&str>,
) -> Result<Vec<u8>> {
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(fail)?
        .error_for_status()
        .map_err(fail)?;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(fail)? {
        if body.len() + chunk.len() > MAX_DESCRIPTOR {
            return Err("manifest_size".into());
        }
        body.extend_from_slice(&chunk);
    }
    if let Some(hash) = expected {
        if format!("{:x}", Sha256::digest(&body)) != hash {
            return Err("manifest_digest".into());
        }
    }
    Ok(body)
}

async fn object_download(
    client: &reqwest::Client,
    url: &str,
    file: &Path,
    hash: &str,
    bytes: u64,
    transfer: &Transfer,
) -> Result<()> {
    if file.is_file() {
        if matches_file(file, hash, bytes).await? {
            transfer.downloaded.fetch_add(bytes, Ordering::Relaxed);
            return Ok(());
        }
        tokio::fs::remove_file(file).await.map_err(fail)?;
    }
    let partial = file.with_extension("part");
    let mut offset = partial.metadata().map_or(0, |meta| meta.len());
    if offset > bytes {
        tokio::fs::remove_file(&partial).await.map_err(fail)?;
        offset = 0;
    }
    if offset == bytes && !partial.is_file() {
        tokio::fs::File::create(&partial).await.map_err(fail)?;
    }
    if offset < bytes {
        if transfer.paused.load(Ordering::Relaxed) {
            return Err("paused".into());
        }
        let mut request = client.get(url).header("Accept-Encoding", "identity");
        if offset > 0 {
            request = request.header("Range", format!("bytes={offset}-"));
        }
        let mut response = request
            .send()
            .await
            .map_err(fail)?
            .error_for_status()
            .map_err(fail)?;
        match response.status().as_u16() {
            200 => offset = 0,
            206 if offset > 0 => {
                let expected = format!("bytes {offset}-{}/{bytes}", bytes - 1);
                if response
                    .headers()
                    .get("Content-Range")
                    .and_then(|value| value.to_str().ok())
                    != Some(&expected)
                {
                    return Err("object_range".into());
                }
            }
            _ => return Err("object_status".into()),
        }
        let mut output = tokio::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(offset == 0)
            .append(offset > 0)
            .open(&partial)
            .await
            .map_err(fail)?;
        transfer.downloaded.fetch_add(offset, Ordering::Relaxed);
        while let Some(chunk) = response.chunk().await.map_err(fail)? {
            if transfer.paused.load(Ordering::Relaxed) {
                return Err("paused".into());
            }
            offset += chunk.len() as u64;
            if offset > bytes {
                return Err("object_size".into());
            }
            output.write_all(&chunk).await.map_err(fail)?;
            transfer
                .downloaded
                .fetch_add(chunk.len() as u64, Ordering::Relaxed);
        }
        output.sync_all().await.map_err(fail)?;
    } else {
        transfer.downloaded.fetch_add(offset, Ordering::Relaxed);
    }
    if offset != bytes {
        return Err("object_size".into());
    }
    if !matches_file(&partial, hash, bytes).await? {
        let _ = tokio::fs::remove_file(partial).await;
        return Err("object_digest".into());
    }
    tokio::fs::rename(partial, file).await.map_err(fail)
}

async fn matches_file(path: &Path, expected: &str, size: u64) -> Result<bool> {
    let mut file = tokio::fs::File::open(path).await.map_err(fail)?;
    if file.metadata().await.map_err(fail)?.len() != size {
        return Ok(false);
    }
    let mut hash = Sha256::new();
    let mut chunk = vec![0; 128 * 1024];
    loop {
        let length = file.read(&mut chunk).await.map_err(fail)?;
        if length == 0 {
            break;
        }
        hash.update(&chunk[..length]);
    }
    Ok(format!("{:x}", hash.finalize()) == expected)
}

fn verified_player(body: &[u8]) -> Result<Player> {
    #[derive(Deserialize)]
    struct Signed {
        manifest: String,
        signature: String,
    }
    let signed: Signed = read_json(body)?;
    let manifest = STANDARD.decode(signed.manifest).map_err(fail)?;
    let signature =
        String::from_utf8(STANDARD.decode(signed.signature).map_err(fail)?).map_err(fail)?;
    let config: Value = read_json(include_bytes!("../tauri.conf.json"))?;
    let key = config["plugins"]["updater"]["pubkey"]
        .as_str()
        .ok_or("player_public_key")?;
    let key = String::from_utf8(STANDARD.decode(key).map_err(fail)?).map_err(fail)?;
    PublicKey::decode(&key)
        .map_err(fail)?
        .verify(
            &manifest,
            &Signature::decode(&signature).map_err(fail)?,
            false,
        )
        .map_err(fail)?;
    let player: Player = read_json(&manifest)?;
    if player.schema != PLAYER_SCHEMA
        || !digest(&player.sha256)
        || !(1..=MAX_PLAYER).contains(&player.bytes)
        || !(1..=100).contains(&player.version.len())
    {
        return Err("player_manifest".into());
    }
    Ok(player)
}

fn extract_player(zip: &Path, target: &Path) -> Result<()> {
    let mut archive = zip::ZipArchive::new(File::open(zip).map_err(fail)?).map_err(fail)?;
    if archive.len() > 4096 {
        return Err("player_archive".into());
    }
    fs::create_dir_all(target).map_err(fail)?;
    let mut total = 0;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(fail)?;
        if entry.is_dir() {
            continue;
        }
        if entry.is_symlink() || entry.enclosed_name().is_none() || entry.name().contains('%') {
            return Err("player_archive".into());
        }
        let key = path_key(&format!("/{}", entry.name()))?;
        total += entry.size();
        if total > 256 * 1024 * 1024 || entry.size() > MAX_PLAYER {
            return Err("player_size".into());
        }
        let dest = target.join(key);
        fs::create_dir_all(dest.parent().ok_or("player_path")?).map_err(fail)?;
        let mut file = File::create_new(dest).map_err(fail)?;
        let size =
            std::io::copy(&mut (&mut entry).take(MAX_PLAYER + 1), &mut file).map_err(fail)?;
        if size != entry.size() {
            return Err("player_size".into());
        }
    }
    if ["index.html", "player.js", "player.css"]
        .iter()
        .any(|name| !target.join(name).is_file())
    {
        return Err("player_entry".into());
    }
    Ok(())
}

impl Offline {
    pub fn new(root: PathBuf) -> Self {
        let mut library: Library = fs::read(root.join("library.json"))
            .ok()
            .and_then(|bytes| read_json(&bytes).ok())
            .unwrap_or_default();
        for job in &mut library.queue {
            if job.state == JobState::Downloading {
                job.state = JobState::Queued;
            }
        }
        Self {
            root,
            library: Mutex::new(library),
            transfer: Mutex::new(None),
            session: Mutex::new(None),
            action: tokio::sync::Mutex::new(()),
            queue_running: AtomicBool::new(false),
        }
    }

    fn persist(&self, library: &Library) -> Result<()> {
        fs::create_dir_all(&self.root).map_err(fail)?;
        atomic(
            &self.root.join("library.json"),
            &serde_json::to_vec(library).map_err(fail)?,
        )
    }

    async fn install_player(&self, origin: &str, transfer: &Transfer) -> Result<()> {
        let client = client()?;
        let base = format!("{origin}/downloads/story-player");
        let body = descriptor(&client, &format!("{base}/v1/latest.json"), None).await?;
        let player = verified_player(&body)?;
        let target = self.root.join("players").join(&player.sha256);
        {
            let library = self.library.lock().unwrap();
            if library.rejected.as_deref() == Some(&player.sha256) {
                return if library.active.is_some() {
                    Ok(())
                } else {
                    Err("player_rejected".into())
                };
            }
            if target.join("index.html").is_file()
                && [&library.active, &library.pending]
                    .into_iter()
                    .flatten()
                    .any(|entry| entry.sha256 == player.sha256)
            {
                return Ok(());
            }
        }
        let players = self.root.join("players");
        fs::create_dir_all(&players).map_err(fail)?;
        if !target.is_dir() {
            transfer.total.store(player.bytes, Ordering::Relaxed);
            let file = players.join(format!("{}.zip", player.sha256));
            object_download(
                &client,
                &format!("{base}/{}.zip", player.sha256),
                &file,
                &player.sha256,
                player.bytes,
                transfer,
            )
            .await?;
            tokio::task::spawn_blocking(move || {
                let staging = target.with_extension("installing");
                if staging.exists() {
                    fs::remove_dir_all(&staging).map_err(fail)?;
                }
                let result = extract_player(&file, &staging)
                    .and_then(|_| fs::rename(&staging, &target).map_err(fail));
                if result.is_ok() {
                    let _ = fs::remove_file(file);
                } else {
                    let _ = fs::remove_dir_all(staging);
                }
                result
            })
            .await
            .map_err(fail)??;
        }
        let mut library = self.library.lock().unwrap();
        let previous = library.pending.replace(player);
        if let Err(error) = self.persist(&library) {
            library.pending = previous;
            return Err(error);
        }
        self.collect_players(&library);
        Ok(())
    }

    async fn latest(
        &self,
        client: &reqwest::Client,
        base: &str,
        server: &str,
    ) -> Result<(String, Catalog)> {
        let pointer: Pointer =
            read_json(&descriptor(client, &format!("{base}/latest.json"), None).await?)?;
        if pointer.schema != SCHEMA
            || pointer.server != server
            || !release_id(&pointer.release_id)
            || !digest(&pointer.sha256)
        {
            return Err("story_release".into());
        }
        if let Some(catalog) = self
            .library
            .lock()
            .unwrap()
            .catalogs
            .get(server)
            .filter(|catalog| catalog.root_sha.as_ref() == Some(&pointer.sha256))
            .cloned()
        {
            return Ok((pointer.release_id, catalog));
        }
        let url = format!(
            "{base}/{}/manifests/{}.json",
            pointer.release_id, pointer.sha256
        );
        let mut catalog: Catalog =
            read_json(&descriptor(client, &url, Some(&pointer.sha256)).await?)?;
        if catalog.schema != SCHEMA || catalog.server != server || !digest(&catalog.common) {
            return Err("story_catalog".into());
        }
        catalog.root_sha = Some(pointer.sha256);
        let mut library = self.library.lock().unwrap();
        library.catalogs.insert(server.to_owned(), catalog.clone());
        self.persist(&library)?;
        Ok((pointer.release_id, catalog))
    }

    async fn install_episode(
        &self,
        origin: &str,
        server: &str,
        id: &str,
        story: &str,
        transfer: &Transfer,
    ) -> Result<()> {
        let client = client()?;
        let base = format!("{origin}/downloads/stories/{server}");
        let (release_id, catalog) = self.latest(&client, &base, server).await?;
        let group = catalog
            .packages
            .into_iter()
            .find(|row| row.id == id)
            .ok_or("story_chapter")?;
        let episode = group
            .episodes
            .into_iter()
            .find(|entry| entry.id == story)
            .ok_or("story_episode")?;
        let package = Package {
            id: episode.id.clone(),
            title: episode.title.clone(),
            manifest: episode.manifest.clone().ok_or("story_episode_manifest")?,
            bytes: episode.bytes.unwrap_or(0),
            group: group.title,
            group_id: Some(group.id),
            thumbnail: episode.thumbnail.clone(),
            episodes: vec![episode],
            missing_media: 0,
        };
        if !digest(&package.manifest) {
            return Err("story_manifest".into());
        }
        let base = format!("{base}/{release_id}");
        let manifest_url = |hash: &str| format!("{base}/manifests/{hash}.json");
        let common_url = manifest_url(&catalog.common);
        let chapter_url = manifest_url(&package.manifest);
        let (common, episode) = tokio::try_join!(
            descriptor(&client, &common_url, Some(&catalog.common)),
            descriptor(&client, &chapter_url, Some(&package.manifest)),
        )?;
        let mut chapter = Chapter {
            server: server.into(),
            release_id,
            package,
            resources: BTreeMap::new(),
            objects: BTreeMap::new(),
        };
        for body in [common, episode] {
            let manifest: Manifest = read_json(&body)?;
            if manifest.schema != SCHEMA {
                return Err("story_manifest".into());
            }
            chapter.objects.extend(manifest.objects);
            for (url, reference) in manifest.resources {
                chapter.resources.insert(path_key(&url)?, reference);
            }
        }
        if chapter
            .objects
            .iter()
            .any(|(key, object)| !digest(key) || object.bytes > MAX_OBJECT)
            || chapter
                .resources
                .values()
                .any(|reference| !chapter.objects.contains_key(&reference.sha256))
        {
            return Err("story_objects".into());
        }
        let objects = self.root.join("objects");
        fs::create_dir_all(&objects).map_err(fail)?;
        let player_bytes = transfer.total.load(Ordering::Relaxed);
        transfer.total.store(
            player_bytes
                + chapter
                    .objects
                    .values()
                    .map(|entry| entry.bytes)
                    .sum::<u64>(),
            Ordering::Relaxed,
        );
        let downloads: Vec<_> = chapter
            .objects
            .iter()
            .map(|(key, entry)| {
                (
                    client.clone(),
                    objects.join(key),
                    format!("{base}/objects/{key}"),
                    key.clone(),
                    entry.bytes,
                )
            })
            .collect();
        stream::iter(downloads)
            .map(|(client, file, url, hash, bytes)| async move {
                object_download(&client, &url, &file, &hash, bytes, transfer).await
            })
            .buffer_unordered(6)
            .try_collect::<Vec<_>>()
            .await?;
        if transfer.paused.load(Ordering::Relaxed) {
            return Err("paused".into());
        }
        self.commit_chapter(chapter)
    }

    fn commit_chapter(&self, chapter: Chapter) -> Result<()> {
        let mut library = self.library.lock().unwrap();
        let key = format!("{}/{}", chapter.server, chapter.package.id);
        let previous = library.chapters.insert(key.clone(), chapter);
        if let Err(error) = self.persist(&library) {
            if let Some(previous) = previous {
                library.chapters.insert(key, previous);
            } else {
                library.chapters.remove(&key);
            }
            return Err(error);
        }
        self.collect_objects(&library);
        Ok(())
    }

    fn collect_objects(&self, library: &Library) {
        let session = self.session.lock().unwrap();
        let used: BTreeSet<_> = library
            .chapters
            .values()
            .chain(session.iter().map(|play| play.chapter.as_ref()))
            .flat_map(|chapter| chapter.objects.keys().map(String::as_str))
            .collect();
        if let Ok(entries) = self.root.join("objects").read_dir() {
            for entry in entries.flatten() {
                if let Some(name) = entry.file_name().to_str() {
                    if digest(name) && !used.contains(name) {
                        let _ = fs::remove_file(entry.path());
                    }
                }
            }
        }
    }

    fn collect_players(&self, library: &Library) {
        let session = self.session.lock().unwrap();
        let used: BTreeSet<_> = [&library.active, &library.previous, &library.pending]
            .into_iter()
            .flatten()
            .chain(session.iter().map(|play| &play.player))
            .map(|player| player.sha256.as_str())
            .collect();
        if let Ok(entries) = self.root.join("players").read_dir() {
            for entry in entries.flatten() {
                if let Some(name) = entry.file_name().to_str() {
                    if digest(name) && !used.contains(name) {
                        let _ = fs::remove_dir_all(entry.path());
                    }
                }
            }
        }
    }

    fn transfer_status(&self) -> Value {
        let transfer = self.transfer.lock().unwrap();
        transfer.as_ref().map_or(Value::Null, |status| {
            json!({
                "bytes": status.downloaded.load(Ordering::Relaxed),
                "total": status.total.load(Ordering::Relaxed),
                "discovering": status.discovering.load(Ordering::Relaxed),
            })
        })
    }

    fn view(&self) -> Value {
        let library = self.library.lock().unwrap();
        let objects: BTreeMap<_, _> = library
            .chapters
            .values()
            .flat_map(|chapter| chapter.objects.iter())
            .collect();
        let story_bytes: u64 = objects.values().map(|entry| entry.bytes).sum();
        let bytes = story_bytes
            + directory_bytes(&self.root.join("players"))
            + directory_bytes(&self.root.join("partial-assets"));
        let installed: Vec<_> = library.chapters.iter().map(|(key, chapter)| {
            json!({"key": key, "server": chapter.server, "package": chapter.presented_package()})
        }).collect();
        json!({
            "installed": installed, "catalogs": library.catalogs, "bytes": bytes,
            "player": library.active.as_ref(),
            "pendingPlayer": library.pending.as_ref(),
            "transfer": self.transfer_status(),
            "queue": library.queue,
            "queuePaused": library.queue_paused,
        })
    }

    fn player_present(&self) -> bool {
        let library = self.library.lock().unwrap();
        library
            .active
            .iter()
            .chain(library.pending.iter())
            .chain(library.previous.iter())
            .any(|player| player.schema == PLAYER_SCHEMA)
    }

    fn open(
        &self,
        window: &WebviewWindow,
        server: &str,
        id: &str,
        episode: &str,
        locale: &str,
    ) -> Result<()> {
        let library = self.library.lock().unwrap();
        let chapter = Arc::new(
            library
                .chapters
                .get(&format!("{server}/{id}"))
                .ok_or("story_missing")?
                .clone(),
        );
        let episode = chapter
            .package
            .episodes
            .iter()
            .find(|row| row.id == episode)
            .ok_or("story_missing")?
            .clone();
        let player = [&library.pending, &library.active, &library.previous]
            .into_iter()
            .flatten()
            .find(|player| player.schema == PLAYER_SCHEMA)
            .ok_or("player_missing")?
            .clone();
        let candidate = library
            .pending
            .as_ref()
            .is_some_and(|pending| pending.sha256 == player.sha256);
        drop(library);
        self.launch(
            window,
            chapter,
            episode,
            player,
            locale.to_owned(),
            candidate,
        )
    }

    fn launch(
        &self,
        window: &WebviewWindow,
        chapter: Arc<Chapter>,
        episode: Episode,
        player: Player,
        locale: String,
        candidate: bool,
    ) -> Result<()> {
        let mut entropy = [0; 16];
        rand::thread_rng().fill_bytes(&mut entropy);
        let token = entropy
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let session = Arc::new(Session {
            token,
            chapter,
            episode,
            player,
            locale,
            theme: {
                let theme = window.state::<crate::AppState>().preference("theme");
                match theme["preference"].as_str() {
                    Some("dark") => Some("dark"),
                    Some("light") => Some("light"),
                    _ => None,
                }
            },
            ready: AtomicBool::new(false),
        });
        *self.session.lock().unwrap() = Some(session.clone());
        let mut url = player_url();
        url.query_pairs_mut().append_pair("session", &session.token);
        window.navigate(url).map_err(fail)?;
        if candidate {
            let window = window.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_secs(40)).await;
                let state = window.state::<crate::AppState>();
                let offline = &state.offline;
                let current = offline.session.lock().unwrap().clone();
                if session.ready.load(Ordering::Acquire)
                    || current.is_none_or(|current| current.token != session.token)
                    || window
                        .url()
                        .ok()
                        .as_ref()
                        .is_none_or(|url| !is_player_url(url))
                {
                    return;
                }
                let active = {
                    let mut library = offline.library.lock().unwrap();
                    if library
                        .pending
                        .as_ref()
                        .is_none_or(|pending| pending.sha256 != session.player.sha256)
                    {
                        return;
                    }
                    library.pending = None;
                    library.rejected = Some(session.player.sha256.clone());
                    let _ = offline.persist(&library);
                    library
                        .active
                        .iter()
                        .chain(library.previous.iter())
                        .find(|player| player.schema == PLAYER_SCHEMA)
                        .cloned()
                };
                if let Some(active) = active {
                    let _ = offline.launch(
                        &window,
                        session.chapter.clone(),
                        session.episode.clone(),
                        active,
                        session.locale.clone(),
                        false,
                    );
                } else {
                    let _ = window
                        .navigate(crate::site::local_url("offline-stories.html?playerError=1"));
                }
            });
        }
        Ok(())
    }

    fn confirm(&self, session: &Session) -> Result<()> {
        let mut library = self.library.lock().unwrap();
        if library
            .pending
            .as_ref()
            .is_some_and(|player| player.sha256 == session.player.sha256)
        {
            let older = library.previous.take();
            library.previous = library.active.take();
            library.active = library.pending.take();
            if let Err(error) = self.persist(&library) {
                library.pending = library.active.take();
                library.active = library.previous.take();
                library.previous = older;
                return Err(error);
            }
            self.collect_players(&library);
        }
        session.ready.store(true, Ordering::Release);
        Ok(())
    }

    fn progress_file(&self, session: &Session) -> PathBuf {
        let identity = format!(
            "{}/{}/{}",
            session.chapter.server, session.chapter.release_id, session.episode.id
        );
        self.root
            .join("progress")
            .join(format!("{:x}.json", Sha256::digest(identity.as_bytes())))
    }

    pub fn clear_session(&self) {
        *self.session.lock().unwrap() = None;
    }

    fn reply(&self, request: Request<Vec<u8>>) -> Result<Response<Vec<u8>>> {
        let session = self
            .session
            .lock()
            .unwrap()
            .clone()
            .ok_or("player_session")?;
        let key = path_key(request.uri().path())?;
        let method = request.method().as_str();
        match (method, key.as_str()) {
            ("GET", "offline/session.json") => {
                let progress = fs::read(self.progress_file(&session))
                    .ok()
                    .and_then(|body| read_json::<u64>(&body).ok())
                    .unwrap_or(0);
                let title = localized(&session.episode.title, &session.locale);
                return respond(200, "application/json", serde_json::to_vec(&json!({
                    "server": session.chapter.server, "releaseId": session.chapter.release_id, "episode": session.episode.id,
                    "title": title, "locale": session.locale, "returnUrl": crate::site::local_url("offline-stories.html").as_str(), "progress": progress,
                    "chapterTitle": localized(&session.chapter.package.group, &session.locale),
                    "chapter": session.chapter.package.group_id,
                    "token": session.token, "theme": session.theme,
                    "portableStory": Source::parse(&session.chapter.server).is_some(),
                })).map_err(fail)?);
            }
            ("POST", "offline/ready" | "offline/detail-ready" | "offline/progress") => {
                if request
                    .headers()
                    .get("X-Haneoka-Session")
                    .and_then(|value| value.to_str().ok())
                    != Some(&session.token)
                {
                    return Err("player_session".into());
                }
                if key == "offline/detail-ready" {
                    session.ready.store(true, Ordering::Release);
                } else if key == "offline/ready" {
                    self.confirm(&session)?;
                } else {
                    let ordinal = std::str::from_utf8(request.body())
                        .map_err(fail)?
                        .parse::<u64>()
                        .map_err(fail)?;
                    if ordinal > 1_000_000 {
                        return Err("story_progress".into());
                    }
                    let file = self.progress_file(&session);
                    fs::create_dir_all(file.parent().ok_or("progress_path")?).map_err(fail)?;
                    let _lock = self.library.lock().unwrap();
                    atomic(&file, ordinal.to_string().as_bytes())?;
                }
                return respond(204, "text/plain", Vec::new());
            }
            ("GET" | "HEAD", _) => {}
            _ => return Err("method".into()),
        }
        let resource = if let Some(query) = request.uri().query() {
            session
                .chapter
                .resources
                .get(&format!("{key}?{query}"))
                .or_else(|| session.chapter.resources.get(&key))
        } else {
            session.chapter.resources.get(&key)
        };
        if let Some(reference) = resource {
            let path = self.root.join("objects").join(&reference.sha256);
            if let Some(selector) = &reference.selector {
                let body = fs::read(path).map_err(fail)?;
                let value: Value = read_json(&body)?;
                let row = value.get(selector).ok_or("story_selector")?;
                return respond(
                    200,
                    "application/json",
                    serde_json::to_vec(row).map_err(fail)?,
                );
            }
            let object = &session.chapter.objects[&reference.sha256];
            return file_response(&request, path, &object.media_type);
        }
        if key == "index.html" {
            let token = request
                .uri()
                .query()
                .and_then(|query| query.strip_prefix("session="));
            if token != Some(&session.token) {
                return Err("player_session".into());
            }
        }
        let mime = match Path::new(&key)
            .extension()
            .and_then(|extension| extension.to_str())
        {
            Some("html") => "text/html; charset=utf-8",
            Some("js" | "mjs") => "text/javascript; charset=utf-8",
            Some("css") => "text/css; charset=utf-8",
            Some("svg") => "image/svg+xml",
            Some("wasm") => "application/wasm",
            Some("json") => "application/json",
            Some("woff2") => "font/woff2",
            Some("png") => "image/png",
            Some("webp") => "image/webp",
            Some("ktx2") => "image/ktx2",
            _ => "application/octet-stream",
        };
        file_response(
            &request,
            self.root
                .join("players")
                .join(&session.player.sha256)
                .join(key),
            mime,
        )
    }

    pub fn cover(&self, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
        let key = request.uri().path().trim_start_matches('/');
        let object = if digest(key) && matches!(request.method().as_str(), "GET" | "HEAD") {
            let library = self.library.lock().unwrap();
            library.chapters.values().find_map(|chapter| {
                chapter
                    .objects
                    .get(key)
                    .filter(|object| thumbnail_type(&object.media_type))
                    .cloned()
            })
        } else {
            None
        };
        if let Some(object) = object {
            if let Ok(response) = file_response(
                &request,
                self.root.join("objects").join(key),
                &object.media_type,
            ) {
                return response;
            }
        }
        respond(404, "text/plain", Vec::new()).unwrap()
    }

    pub fn respond(&self, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
        self.reply(request).unwrap_or_else(|error| {
            log::debug!("Offline story resource: {error}");
            respond(404, "text/plain", Vec::new()).unwrap()
        })
    }

    pub async fn command(
        &self,
        window: &WebviewWindow,
        origin: &str,
        method: &str,
        args: &Value,
    ) -> Result<Value> {
        if let Some(result) = self.queue_command(window, method, args).await {
            return result;
        }
        if method == "offlineStories" {
            return Ok(self.view());
        }
        if method == "offlineTransfer" {
            return Ok(self.transfer_status());
        }
        if method == "offlinePause" {
            if let Some(transfer) = self.transfer.lock().unwrap().as_ref() {
                transfer.paused.store(true, Ordering::Relaxed);
            }
            return Ok(Value::Null);
        }
        if method == "offlinePlayerUpdate" {
            let _guard = self.action.try_lock().map_err(|_| "offline_busy")?;
            return self
                .transfer(|status| async move { self.install_player(origin, &status).await })
                .await;
        }
        let server = args["server"].as_str().ok_or("story_server")?;
        let source = Source::parse(server);
        if source.is_none() && !matches!(server, "jp" | "intl") {
            return Err("story_server".into());
        }
        if method == "offlinePlay" {
            let id = args["chapter"].as_str().ok_or("story_chapter")?;
            let episode = args["episode"].as_str().ok_or("story_episode")?;
            let locale = args["locale"]
                .as_str()
                .filter(|locale| ["en", "ja", "ko", "zh-CN", "zh-TW"].contains(locale))
                .unwrap_or("en");
            self.open(window, server, id, episode, locale)?;
            return Ok(Value::Null);
        }
        let _guard = self.action.try_lock().map_err(|_| "offline_busy")?;
        if method == "offlineCatalog" {
            let client = client()?;
            if let Some(source) = source {
                self.load_portable_catalog(
                    &client,
                    origin,
                    server,
                    source,
                    args["section"].as_str().unwrap_or(""),
                    args["episode"].as_str(),
                )
                .await?;
            } else {
                self.latest(
                    &client,
                    &format!("{origin}/downloads/stories/{server}"),
                    server,
                )
                .await?;
            }
            return Ok(self.view());
        }
        Err("offline_method".into())
    }

    async fn transfer<F, Fut>(&self, run: F) -> Result<Value>
    where
        F: FnOnce(Arc<Transfer>) -> Fut,
        Fut: std::future::Future<Output = Result<()>>,
    {
        let status = Arc::new(Transfer::default());
        *self.transfer.lock().unwrap() = Some(status.clone());
        let result = run(status).await;
        *self.transfer.lock().unwrap() = None;
        result?;
        Ok(self.view())
    }
}

fn thumbnail_type(mime: &str) -> bool {
    matches!(
        mime.split(';').next(),
        Some("image/jpeg" | "image/png" | "image/webp")
    )
}

fn cover_url(sha256: &str) -> String {
    let origin = if cfg!(any(windows, target_os = "android")) {
        "http://haneoka-cover.localhost"
    } else {
        "haneoka-cover://localhost"
    };
    format!("{origin}/{sha256}")
}

fn directory_bytes(directory: &Path) -> u64 {
    let Ok(entries) = directory.read_dir() else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.file_type() {
            Ok(kind) if kind.is_dir() => directory_bytes(&entry.path()),
            Ok(kind) if kind.is_file() => entry.metadata().map_or(0, |meta| meta.len()),
            _ => 0,
        })
        .sum()
}

fn localized(value: &Value, locale: &str) -> String {
    if let Some(text) = value.as_str() {
        return text.to_owned();
    }
    let position = ["ja", "en", "zh-TW", "zh-CN", "ko"]
        .iter()
        .position(|code| *code == locale)
        .unwrap_or(0);
    value
        .get(position)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            value
                .as_array()?
                .iter()
                .filter_map(Value::as_str)
                .find(|text| !text.is_empty())
        })
        .unwrap_or_default()
        .to_owned()
}

pub fn is_player_url(url: &Url) -> bool {
    if cfg!(any(windows, target_os = "android")) {
        url.scheme() == "http"
            && url.host_str() == Some("haneoka-story.localhost")
            && url.port().is_none()
    } else {
        url.scheme() == PROTOCOL && url.host_str() == Some("localhost")
    }
}

fn player_url() -> Url {
    let address = if cfg!(any(windows, target_os = "android")) {
        "http://haneoka-story.localhost/index.html"
    } else {
        "haneoka-story://localhost/index.html"
    };
    Url::parse(address).expect("story player origin")
}

fn respond(status: u16, mime: &str, body: Vec<u8>) -> Result<Response<Vec<u8>>> {
    Response::builder()
        .status(status)
        .header("Content-Type", mime)
        .header("Cache-Control", "no-store")
        .header("X-Content-Type-Options", "nosniff")
        .header("Content-Security-Policy", CSP)
        .body(body)
        .map_err(fail)
}

fn file_response(
    request: &Request<Vec<u8>>,
    path: PathBuf,
    mime: &str,
) -> Result<Response<Vec<u8>>> {
    let mut file = File::open(path).map_err(fail)?;
    let size = file.metadata().map_err(fail)?.len();
    if size > MAX_OBJECT {
        return Err("story_size".into());
    }
    let mut builder = Response::builder()
        .header("Content-Type", mime)
        .header("X-Content-Type-Options", "nosniff")
        .header("Content-Security-Policy", CSP)
        .header("Accept-Ranges", "bytes")
        .header("Cache-Control", "no-store");
    if request.method() == "HEAD" {
        return builder
            .header("Content-Length", size)
            .body(Vec::new())
            .map_err(fail);
    }
    let mut body = Vec::new();
    if let Some(range) = request
        .headers()
        .get("Range")
        .and_then(|value| value.to_str().ok())
    {
        let span = range
            .strip_prefix("bytes=")
            .and_then(|value| value.split_once('-'))
            .and_then(|(start, end)| {
                let (start, end) = if start.is_empty() {
                    (size.saturating_sub(end.parse().ok()?), size.checked_sub(1)?)
                } else {
                    (
                        start.parse::<u64>().ok()?,
                        if end.is_empty() {
                            size.checked_sub(1)?
                        } else {
                            end.parse::<u64>().ok()?.min(size.checked_sub(1)?)
                        },
                    )
                };
                (start <= end).then_some((start, end))
            });
        let Some((start, end)) = span else {
            return builder
                .status(416)
                .header("Content-Range", format!("bytes */{size}"))
                .body(body)
                .map_err(fail);
        };
        file.seek(SeekFrom::Start(start)).map_err(fail)?;
        file.take(end - start + 1)
            .read_to_end(&mut body)
            .map_err(fail)?;
        builder = builder
            .status(206)
            .header("Content-Range", format!("bytes {start}-{end}/{size}"));
    } else {
        file.read_to_end(&mut body).map_err(fail)?;
    }
    builder
        .header("Content-Length", body.len())
        .body(body)
        .map_err(fail)
}
