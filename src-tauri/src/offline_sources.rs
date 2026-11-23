//! Downloads portable provider and published community stories into the shared offline object store.
use super::*;
use reqwest::header::{CONTENT_RANGE, CONTENT_TYPE, ETAG, IF_NONE_MATCH, IF_RANGE, RANGE};

#[derive(Clone, Copy)]
pub(super) enum Source<'a> {
    Garupa(&'a str),
    Sekai(&'a str),
    Community,
}

impl<'a> Source<'a> {
    pub(super) fn parse(server: &'a str) -> Option<Self> {
        if server == "community" {
            return Some(Self::Community);
        }
        let (provider, region) = server.split_once('.')?;
        if !matches!(region, "jp" | "en" | "tw" | "cn" | "kr") {
            return None;
        }
        match provider {
            "gbp" => Some(Self::Garupa(region)),
            "sekai" => Some(Self::Sekai(region)),
            _ => None,
        }
    }

    fn base(self) -> String {
        match self {
            Self::Garupa(region) => format!("/api/v1/garupa/bestdori/{region}"),
            Self::Sekai(region) => format!("/api/v1/sekai/{region}"),
            Self::Community => "/api/v1/community/stories".to_owned(),
        }
    }

    fn valid_section(self, section: &str) -> bool {
        match self {
            Self::Garupa(_) => matches!(section, "event" | "band" | "main" | "afterlive" | "card"),
            Self::Sekai(_) => matches!(
                section,
                "event" | "unit" | "character" | "card" | "area" | "special" | "mysekai" | "live"
            ),
            Self::Community => section.is_empty(),
        }
    }

    pub(super) fn valid_id(self, id: &str) -> bool {
        if id.is_empty()
            || id.len() > 240
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'_'))
        {
            return false;
        }
        match self {
            Self::Community => {
                id.len() == 36
                    && id.split('-').map(str::len).eq([8, 4, 4, 4, 12])
                    && id.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
            }
            _ => id
                .split_once('.')
                .is_some_and(|(section, suffix)| !suffix.is_empty() && self.valid_section(section)),
        }
    }

    fn story_path(self, id: &str) -> Result<String> {
        if !self.valid_id(id) {
            return Err("story_episode".into());
        }
        Ok(match self {
            Self::Community => format!("{}/{id}/offline", self.base()),
            _ => format!("{}/offline/{id}", self.base()),
        })
    }

    fn catalog_path(self, section: &str) -> Result<String> {
        if !self.valid_section(section) {
            return Err("story_section".into());
        }
        Ok(match self {
            Self::Community => format!("{}?offline=1", self.base()),
            _ => format!("{}/offline-catalog/{section}", self.base()),
        })
    }
}

#[derive(Deserialize)]
struct CatalogRow {
    id: String,
    title: Value,
    #[serde(default)]
    group: Value,
    #[serde(default, rename = "groupId")]
    group_id: Option<String>,
    #[serde(default, alias = "coverUrl")]
    thumbnail: Option<String>,
    #[serde(default)]
    bytes: u64,
}

impl CatalogRow {
    fn package(self) -> Package {
        Package {
            episodes: vec![Episode {
                id: self.id.clone(),
                title: self.title.clone(),
                manifest: None,
                thumbnail: self.thumbnail.clone(),
                bytes: None,
            }],
            id: self.id,
            title: self.title,
            manifest: String::new(),
            bytes: self.bytes,
            group: self.group,
            group_id: self.group_id,
            thumbnail: self.thumbnail,
            missing_media: 0,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pin {
    url: String,
    sha256: String,
    bytes: u64,
}

#[derive(Deserialize)]
struct PortableStory {
    schema: String,
    story: Value,
    #[serde(default)]
    live2d: Vec<Value>,
    #[serde(default)]
    characters: Vec<Value>,
    #[serde(default)]
    project: Option<Value>,
    thumbnail: Option<String>,
    #[serde(default)]
    assets: Vec<Pin>,
}

pub(super) fn catalog_key(server: &str, section: &str) -> String {
    if section.is_empty() {
        server.to_owned()
    } else {
        format!("{server}/{section}")
    }
}

async fn read_story(
    client: &reqwest::Client,
    origin: &str,
    source: Source<'_>,
    id: &str,
) -> Result<(Url, PortableStory)> {
    let url = Url::parse(&format!("{origin}{}", source.story_path(id)?)).map_err(fail)?;
    let body = read_json::<PortableStory>(&descriptor(client, url.as_str(), None).await?)?;
    if body.schema != "haneoka-portable-story-v1" || !body.story.is_object() {
        return Err("story_manifest".into());
    }
    Ok((url, body))
}

impl Offline {
    pub(super) async fn load_portable_catalog(
        &self,
        client: &reqwest::Client,
        origin: &str,
        server: &str,
        source: Source<'_>,
        section: &str,
        selected: Option<&str>,
    ) -> Result<()> {
        let body = descriptor(
            client,
            &format!("{origin}{}", source.catalog_path(section)?),
            None,
        )
        .await?;
        let rows: Vec<CatalogRow> = match source {
            Source::Community => {
                #[derive(Deserialize)]
                struct Shared {
                    stories: Vec<CatalogRow>,
                }
                read_json::<Shared>(&body)?.stories
            }
            _ => read_json(&body)?,
        };
        let mut packages: Vec<_> = rows
            .into_iter()
            .filter(|item| source.valid_id(&item.id))
            .map(CatalogRow::package)
            .collect();
        if let Some(id) = selected.filter(|id| !packages.iter().any(|package| package.id == *id)) {
            let (_, story) = read_story(client, origin, source, id).await?;
            packages.insert(
                0,
                CatalogRow {
                    id: id.to_owned(),
                    title: story
                        .story
                        .get("title")
                        .cloned()
                        .unwrap_or_else(|| json!(id)),
                    group: Value::Null,
                    group_id: None,
                    thumbnail: story.thumbnail,
                    bytes: story.assets.iter().map(|asset| asset.bytes).sum(),
                }
                .package(),
            );
        }
        let key = catalog_key(server, section);
        let mut library = self.library.lock().unwrap();
        library.catalogs.insert(
            key,
            Catalog {
                schema: "haneoka-portable-story-v1".to_owned(),
                server: server.to_owned(),
                common: String::new(),
                root_sha: None,
                packages,
            },
        );
        self.persist(&library)
    }

    pub(super) async fn install_portable_story(
        &self,
        origin: &str,
        server: &str,
        source: Source<'_>,
        id: &str,
        transfer: &Transfer,
    ) -> Result<()> {
        transfer.discovering.store(true, Ordering::Relaxed);
        let client = client()?;
        let (url, portable) = read_story(&client, origin, source, id).await?;
        let section = match source {
            Source::Community => "",
            _ => id
                .split_once('.')
                .map(|(section, _)| section)
                .ok_or("story_section")?,
        };
        let key = catalog_key(server, section);
        let has_catalog = self.library.lock().unwrap().catalogs.contains_key(&key);
        if !has_catalog {
            if let Err(error) = self
                .load_portable_catalog(&client, origin, server, source, section, None)
                .await
            {
                log::debug!("Offline catalogue {}: {error}", source.base());
            }
        }
        let mut package = {
            let library = self.library.lock().unwrap();
            library
                .catalogs
                .get(&key)
                .and_then(|catalog| {
                    catalog
                        .packages
                        .iter()
                        .find(|package| package.id == id)
                        .cloned()
                })
                .unwrap_or_else(|| {
                    CatalogRow {
                        id: id.to_owned(),
                        title: portable
                            .story
                            .get("title")
                            .cloned()
                            .unwrap_or_else(|| json!(id)),
                        group: Value::Null,
                        group_id: None,
                        thumbnail: portable.thumbnail.clone(),
                        bytes: 0,
                    }
                    .package()
                })
        };
        if let Some(title) = portable.story.get("title").filter(|title| !title.is_null()) {
            package.title = title.clone();
            package.episodes[0].title = title.clone();
        }
        if let Some(group) = portable
            .story
            .get("chapterName")
            .filter(|group| !group.is_null())
        {
            package.group = group.clone();
        }
        if let Some(group_id) = portable
            .story
            .get("chapterKey")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        {
            package.group_id = Some(group_id.to_owned());
        }
        if let Some(thumb) = portable
            .thumbnail
            .as_deref()
            .or_else(|| portable.story.get("episodeImage").and_then(Value::as_str))
        {
            package.thumbnail = Some(thumb.to_owned());
        }
        let objects_dir = self.root.join("objects");
        let partial_dir = self.root.join("partial-assets");
        fs::create_dir_all(&objects_dir).map_err(fail)?;
        fs::create_dir_all(&partial_dir).map_err(fail)?;
        let mut chapter = Chapter {
            server: server.to_owned(),
            release_id: String::new(),
            package,
            resources: BTreeMap::new(),
            objects: BTreeMap::new(),
        };
        let mut document = json!({
            "story": portable.story, "live2d": portable.live2d, "characters": portable.characters, "project": portable.project,
            "provider": !matches!(source, Source::Community),
        });
        let mut pending = BTreeMap::new();
        collect_urls(&mut document, &url, &mut pending, false, false);
        for pin in portable.assets {
            let target = media_url(&url, &pin.url, false).ok_or("story_asset_url")?;
            if !digest(&pin.sha256) || pin.bytes > MAX_OBJECT {
                return Err("story_asset_pin".into());
            }
            pending.insert(
                media_key(&target)?,
                Asset {
                    url: target,
                    pin: Some(pin),
                    optional: false,
                },
            );
        }
        let mut unavailable = BTreeMap::new();
        while !pending.is_empty() {
            if transfer.paused.load(Ordering::Relaxed) {
                return Err("paused".into());
            }
            if pending.len() + chapter.objects.len() > 30_000 {
                return Err("story_asset_count".into());
            }
            let mut hashes = BTreeSet::new();
            let keys: Vec<_> = pending
                .iter()
                .filter(|(_, asset)| {
                    asset
                        .pin
                        .as_ref()
                        .is_none_or(|pin| hashes.insert(&pin.sha256))
                })
                .take(6)
                .map(|(key, _)| key.clone())
                .collect();
            let jobs = keys
                .into_iter()
                .filter_map(|key| pending.remove_entry(&key));
            let downloads = jobs
                .into_iter()
                .map(|(key, asset)| {
                    (
                        key,
                        asset,
                        client.clone(),
                        objects_dir.clone(),
                        partial_dir.clone(),
                    )
                })
                .collect::<Vec<_>>();
            let saved = stream::iter(downloads)
                .map(|(key, asset, client, objects, partial)| async move {
                    let result =
                        download_asset(&client, &asset, &objects, &partial, transfer).await?;
                    Ok::<_, String>((key, asset, result))
                })
                .buffer_unordered(6)
                .try_collect::<Vec<_>>()
                .await?;
            for (key, asset, result) in saved {
                let Some((mut hash, mut object)) = result else {
                    unavailable.insert(key, fallback_media(&asset.url).unwrap_or(""));
                    continue;
                };
                let file = objects_dir.join(&hash);
                if let Some(descriptor) = expand_asset(&asset.url, &file, &mut pending)? {
                    hash = format!("{:x}", Sha256::digest(&descriptor));
                    atomic(&objects_dir.join(&hash), &descriptor)?;
                    object = Object {
                        bytes: descriptor.len() as u64,
                        media_type: "application/json".to_owned(),
                    };
                }
                chapter.objects.insert(hash.clone(), object);
                chapter.resources.insert(
                    key.clone(),
                    Reference {
                        sha256: hash.clone(),
                        selector: None,
                    },
                );
                if let Some((path, _)) = key.split_once('?') {
                    chapter
                        .resources
                        .entry(path.to_owned())
                        .or_insert(Reference {
                            sha256: hash,
                            selector: None,
                        });
                }
            }
            pending.retain(|key, _| {
                !chapter.resources.contains_key(key) && !unavailable.contains_key(key)
            });
        }
        replace_unavailable(&mut document, &url, &unavailable);
        chapter.package.missing_media = unavailable.len();
        if let Some(cover) = chapter
            .package
            .thumbnail
            .as_ref()
            .and_then(|src| media_url(&url, src, false))
        {
            let key = media_key(&cover)?;
            if !chapter.resources.contains_key(&key) {
                let asset = Asset {
                    url: cover,
                    pin: None,
                    optional: true,
                };
                match download_asset(&client, &asset, &objects_dir, &partial_dir, transfer).await {
                    Ok(Some((hash, object))) if thumbnail_type(&object.media_type) => {
                        chapter.resources.insert(
                            key.clone(),
                            Reference {
                                sha256: hash.clone(),
                                selector: None,
                            },
                        );
                        chapter.objects.insert(hash, object);
                    }
                    Err(error) if error == "paused" => return Err(error),
                    _ => {}
                }
            }
            if chapter.resources.contains_key(&key) {
                chapter.package.thumbnail = Some(format!("/{key}"));
                chapter.package.episodes[0].thumbnail = chapter.package.thumbnail.clone();
            }
        }
        let body = serde_json::to_vec(&document).map_err(fail)?;
        let sha256 = format!("{:x}", Sha256::digest(&body));
        atomic(&objects_dir.join(&sha256), &body)?;
        chapter.resources.insert(
            "offline/document.json".to_owned(),
            Reference {
                sha256: sha256.clone(),
                selector: None,
            },
        );
        chapter.objects.insert(
            sha256.clone(),
            Object {
                bytes: body.len() as u64,
                media_type: "application/json".to_owned(),
            },
        );
        chapter.release_id = format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(&chapter.resources).map_err(fail)?)
        );
        chapter.package.manifest = chapter.release_id.clone();
        chapter.package.bytes = chapter.objects.values().map(|entry| entry.bytes).sum();
        if transfer.paused.load(Ordering::Relaxed) {
            return Err("paused".into());
        }
        self.commit_chapter(chapter)
    }
}

fn local_origin(url: &Url) -> bool {
    url.scheme() == "https"
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && matches!(url.host_str(), Some("haneoka.org" | "haneoka.com"))
}

fn media_url(base: &Url, value: &str, relative: bool) -> Option<Url> {
    if value.is_empty() || (!relative && !value.starts_with('/') && !value.starts_with("https://"))
    {
        return None;
    }
    let mut target = base.join(value).ok()?;
    if !local_origin(&target) {
        return None;
    }
    let host = base.host_str()?;
    target.set_host(Some(host)).ok()?;
    target.set_fragment(None);
    let key = path_key(target.path()).ok()?;
    let parts: Vec<_> = key.split('/').collect();
    let supported = matches!(
        parts.as_slice(),
        [
            "api",
            "v1",
            "garupa",
            "bestdori",
            _,
            "raw",
            "assets" | "res",
            _,
            ..
        ] | [
            "api",
            "v1",
            "sekai",
            _,
            "media" | "live2d-file" | "live2d-model" | "live2d-expression",
            _,
            ..
        ] | ["api", "v1", "community", "stories", _, "assets", _, _, ..]
            | ["api", "v1", "servers", "jp" | "intl", "sources", _, ..]
            | ["assets" | "runtime" | "objects", "jp" | "intl", _, ..]
    );
    let provider = base.path().starts_with("/api/v1/garupa/bestdori/")
        || base.path().starts_with("/api/v1/sekai/");
    let provider_asset = target.path().starts_with("/api/v1/garupa/bestdori/")
        || target.path().starts_with("/api/v1/sekai/");
    (supported && (!provider || provider_asset)).then_some(target)
}

fn media_key(url: &Url) -> Result<String> {
    let key = path_key(url.path())?;
    Ok(match url.query() {
        Some(query) => format!("{key}?{query}"),
        None => key,
    })
}

struct Asset {
    url: Url,
    pin: Option<Pin>,
    optional: bool,
}

fn collect_urls(
    value: &mut Value,
    base: &Url,
    pending: &mut BTreeMap<String, Asset>,
    relative: bool,
    optional: bool,
) {
    match value {
        Value::String(text) => {
            let Some(url) = media_url(base, text, relative) else {
                return;
            };
            if Path::new(url.path()).extension().is_none() && !url.path().starts_with("/objects/") {
                return;
            }
            if let Ok(key) = media_key(&url) {
                if text.starts_with("https://") {
                    *text = format!(
                        "{}{}",
                        url.path(),
                        url.query().map(|q| format!("?{q}")).unwrap_or_default()
                    );
                }
                pending
                    .entry(key)
                    .and_modify(|asset| asset.optional &= optional)
                    .or_insert(Asset {
                        url,
                        pin: None,
                        optional,
                    });
            }
        }
        Value::Array(rows) => rows
            .iter_mut()
            .for_each(|row| collect_urls(row, base, pending, relative, optional)),
        Value::Object(row) => row.iter_mut().for_each(|(key, value)| {
            if !matches!(
                key.as_str(),
                "sourcePath" | "raw" | "sourceDiagnostics" | "provenance"
            ) {
                collect_urls(
                    value,
                    base,
                    pending,
                    relative,
                    optional
                        || matches!(
                            key.as_str(),
                            "thumbnail" | "episodeImage" | "faceImage" | "coverUrl"
                        ),
                );
            }
        }),
        _ => {}
    }
}

fn expand_asset(
    url: &Url,
    file: &Path,
    pending: &mut BTreeMap<String, Asset>,
) -> Result<Option<Vec<u8>>> {
    let path = url.path();
    if path.ends_with(".json") || path.contains("/sources/") {
        if file.metadata().map_err(fail)?.len() > MAX_DESCRIPTOR as u64 {
            return Err("story_descriptor_size".into());
        }
        let mut data: Value = read_json(&fs::read(file).map_err(fail)?)?;
        let original = data.clone();
        if let Some(references) = data.get_mut("FileReferences") {
            collect_urls(references, url, pending, true, false);
        } else if data.get("model").is_some() && data.get("textures").is_some() {
            collect_urls(&mut data, url, pending, true, false);
        } else if path.contains("/sources/") {
            collect_urls(&mut data, url, pending, false, false);
        }
        if original != data {
            return serde_json::to_vec(&data).map(Some).map_err(fail);
        }
    } else if path.ends_with(".atlas") {
        if file.metadata().map_err(fail)?.len() > MAX_DESCRIPTOR as u64 {
            return Err("story_descriptor_size".into());
        }
        let atlas = fs::read_to_string(file).map_err(fail)?;
        let mut page_start = true;
        for line in atlas.lines().map(str::trim) {
            if line.is_empty() {
                page_start = true;
            } else if page_start {
                collect_urls(
                    &mut Value::String(line.to_owned()),
                    url,
                    pending,
                    true,
                    false,
                );
                page_start = false;
            }
        }
    }
    Ok(None)
}

// Provider archives can list an audio cue or backdrop that their media server no longer serves.
fn fallback_media(url: &Url) -> Option<&'static str> {
    const EMPTY_BACKGROUND: &str = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=";
    let path = url.path();
    let provider_asset =
        path.starts_with("/api/v1/garupa/bestdori/") || path.starts_with("/api/v1/sekai/");
    if !provider_asset {
        return None;
    }
    if (path.contains("/sound/") || path.contains("/voice/"))
        && (path.ends_with(".mp3") || path.ends_with(".wav") || path.ends_with(".ogg"))
    {
        return Some("");
    }
    if (path.contains("/bg/") || path.contains("/scenario/background/"))
        && (path.ends_with(".png") || path.ends_with(".webp"))
    {
        return Some(EMPTY_BACKGROUND);
    }
    None
}

fn replace_unavailable(value: &mut Value, base: &Url, missing: &BTreeMap<String, &str>) {
    if missing.is_empty() {
        return;
    }
    match value {
        Value::String(text) => {
            if let Some(replacement) = media_url(base, text, false)
                .and_then(|url| media_key(&url).ok())
                .and_then(|key| missing.get(&key))
            {
                *text = (*replacement).to_owned();
            }
        }
        Value::Array(rows) => rows
            .iter_mut()
            .for_each(|row| replace_unavailable(row, base, missing)),
        Value::Object(row) => row
            .values_mut()
            .for_each(|value| replace_unavailable(value, base, missing)),
        _ => {}
    }
}

#[derive(Deserialize, Serialize)]
struct Receipt {
    etag: String,
    sha256: String,
    bytes: u64,
    media_type: String,
}

fn content_type(url: &Url, supplied: &str) -> String {
    let mime = supplied.split(';').next().unwrap_or("").trim();
    if mime.starts_with("audio/")
        || mime.starts_with("video/")
        || mime.starts_with("image/")
        || mime.starts_with("font/")
    {
        return mime.to_owned();
    }
    match Path::new(url.path())
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
    {
        "png" => "image/png",
        "webp" => "image/webp",
        "jpg" | "jpeg" => "image/jpeg",
        "svg" => "image/svg+xml",
        "mp3" => "audio/mpeg",
        "ogg" | "opus" => "audio/ogg",
        "wav" => "audio/wav",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "json" => "application/json",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
    .to_owned()
}

async fn download_asset(
    client: &reqwest::Client,
    asset: &Asset,
    objects: &Path,
    partials: &Path,
    transfer: &Transfer,
) -> Result<Option<(String, Object)>> {
    let url = &asset.url;
    if let Some(pin) = &asset.pin {
        transfer.total.fetch_add(pin.bytes, Ordering::Relaxed);
        object_download(
            client,
            url.as_str(),
            &objects.join(&pin.sha256),
            &pin.sha256,
            pin.bytes,
            transfer,
        )
        .await?;
        return Ok(Some((
            pin.sha256.clone(),
            Object {
                bytes: pin.bytes,
                media_type: content_type(url, ""),
            },
        )));
    }

    let key = format!("{:x}", Sha256::digest(url.as_str().as_bytes()));
    let partial = partials.join(format!("{key}.part"));
    let tag_file = partials.join(format!("{key}.etag"));
    let receipt_file = partials.join(format!("{key}.json"));
    let receipt = fs::read(&receipt_file)
        .ok()
        .and_then(|body| read_json::<Receipt>(&body).ok());
    let receipt = receipt.filter(|entry| {
        digest(&entry.sha256)
            && objects
                .join(&entry.sha256)
                .metadata()
                .is_ok_and(|meta| meta.len() == entry.bytes)
    });
    let mut offset = partial.metadata().map_or(0, |meta| meta.len());
    let tag = fs::read_to_string(&tag_file)
        .ok()
        .filter(|tag| tag.starts_with('"') && tag.ends_with('"') && tag.len() <= 256);
    if tag.is_none() || offset >= MAX_OBJECT {
        offset = 0;
    }
    let mut request = client
        .get(url.clone())
        .header("Accept-Encoding", "identity");
    if offset > 0 {
        request = request
            .header(RANGE, format!("bytes={offset}-"))
            .header(IF_RANGE, tag.as_deref().unwrap());
    } else if let Some(entry) = &receipt {
        request = request.header(IF_NONE_MATCH, &entry.etag);
    }
    let mut response = request.send().await.map_err(fail)?;
    if response.status().as_u16() == 304 {
        let entry = receipt.ok_or("story_asset_cache")?;
        if !matches_file(&objects.join(&entry.sha256), &entry.sha256, entry.bytes).await? {
            let _ = fs::remove_file(receipt_file);
            return Err("object_digest".into());
        }
        transfer.total.fetch_add(entry.bytes, Ordering::Relaxed);
        transfer
            .downloaded
            .fetch_add(entry.bytes, Ordering::Relaxed);
        return Ok(Some((
            entry.sha256,
            Object {
                bytes: entry.bytes,
                media_type: entry.media_type,
            },
        )));
    }
    let mut expected = response.content_length();
    let etag = response
        .headers()
        .get(ETAG)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_owned();
    let media_type = content_type(
        url,
        response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or(""),
    );
    match response.status().as_u16() {
        200 => offset = 0,
        206 if offset > 0 && tag.as_deref() == Some(etag.as_str()) => {
            let range = response
                .headers()
                .get(CONTENT_RANGE)
                .and_then(|value| value.to_str().ok())
                .ok_or("object_range")?;
            let (_, full_size) = range.rsplit_once('/').ok_or("object_range")?;
            let full_size = full_size.parse::<u64>().map_err(fail)?;
            if full_size <= offset
                || range != format!("bytes {offset}-{}/{full_size}", full_size - 1)
            {
                return Err("object_range".into());
            }
            expected = Some(full_size);
        }
        404 | 410 if asset.optional || fallback_media(url).is_some() => {
            let _ = fs::remove_file(partial);
            let _ = fs::remove_file(tag_file);
            return Ok(None);
        }
        416 => {
            let _ = fs::remove_file(partial);
            return Err("object_range".into());
        }
        _ => {
            return Err(format!(
                "story_asset_status {} {}",
                response.status(),
                url.path()
            ))
        }
    }
    if expected.is_some_and(|bytes| bytes > MAX_OBJECT) {
        return Err("story_asset_size".into());
    }
    let mut output = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(offset == 0)
        .append(offset > 0)
        .open(&partial)
        .await
        .map_err(fail)?;
    if !etag.is_empty() {
        atomic(&tag_file, etag.as_bytes())?;
    } else {
        let _ = fs::remove_file(&tag_file);
    }
    transfer
        .total
        .fetch_add(expected.unwrap_or(offset), Ordering::Relaxed);
    transfer.downloaded.fetch_add(offset, Ordering::Relaxed);
    while let Some(chunk) = response.chunk().await.map_err(fail)? {
        if transfer.paused.load(Ordering::Relaxed) {
            return Err("paused".into());
        }
        offset += chunk.len() as u64;
        if offset > MAX_OBJECT {
            return Err("story_asset_size".into());
        }
        output.write_all(&chunk).await.map_err(fail)?;
        if expected.is_none() {
            transfer
                .total
                .fetch_add(chunk.len() as u64, Ordering::Relaxed);
        }
        transfer
            .downloaded
            .fetch_add(chunk.len() as u64, Ordering::Relaxed);
    }
    output.sync_all().await.map_err(fail)?;
    drop(output);
    if offset == 0 || expected.is_some_and(|bytes| bytes != offset) {
        return Err("story_asset_size".into());
    }
    let mut file = tokio::fs::File::open(&partial).await.map_err(fail)?;
    let mut digest = Sha256::new();
    let mut buffer = vec![0; 128 * 1024];
    loop {
        let length = file.read(&mut buffer).await.map_err(fail)?;
        if length == 0 {
            break;
        }
        digest.update(&buffer[..length]);
    }
    drop(file);
    let sha256 = format!("{:x}", digest.finalize());
    let target = objects.join(&sha256);
    tokio::fs::rename(&partial, &target).await.map_err(fail)?;
    let _ = fs::remove_file(tag_file);
    if !etag.is_empty() {
        atomic(
            &receipt_file,
            &serde_json::to_vec(&Receipt {
                etag,
                sha256: sha256.clone(),
                bytes: offset,
                media_type: media_type.clone(),
            })
            .map_err(fail)?,
        )?;
    }
    Ok(Some((
        sha256,
        Object {
            bytes: offset,
            media_type,
        },
    )))
}
