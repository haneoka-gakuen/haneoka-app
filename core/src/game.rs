//! Reads from the game's own servers with the session a save already holds:
//! gacha history and the current card, character and band item progress.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use bytes::{Buf, Bytes};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::proto::{Field, FormatError, Reader};
use crate::save::{DocumentKind, GameSave, SaveDocument};

pub const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Region {
    Jp,
    Hmt,
    En,
    Ko,
}

impl Region {
    pub fn id(self) -> &'static str {
        match self {
            Region::Jp => "jp",
            Region::Hmt => "global-hmt",
            Region::En => "global-en",
            Region::Ko => "global-kr",
        }
    }

    pub fn host(self) -> &'static str {
        match self {
            Region::Jp => "api.bang-dream-on.jp",
            Region::Hmt => "l14-prod-hk-all-gs-sirius.gamerfusiontech.com",
            Region::En => "l14-prod-va-all-gs-sirius.bilibiligame.net",
            Region::Ko => "l14-prod-kr-all-gs-sirius.bilibiligame.net",
        }
    }

    pub fn of(save: &GameSave) -> Option<Self> {
        match save.region()? {
            "jp" => Some(Region::Jp),
            "tw" => Some(Region::Hmt),
            "en" => Some(Region::En),
            "kr" => Some(Region::Ko),
            _ => None,
        }
    }
}

/// The certification a `LocalPersistData` document holds. Kept in memory
/// only for the request.
pub struct Session {
    player_id: String,
    credential: String,
    device_id: Option<String>,
}

impl Session {
    fn metadata(&self) -> Vec<(&'static str, String)> {
        let mut out = vec![("x-player-id", self.player_id.clone()), ("x-player-credential", self.credential.clone())];
        if let Some(device) = &self.device_id {
            out.push(("x-device-id", device.clone()));
        }
        out
    }
}

pub fn session(save: &GameSave) -> Option<Session> {
    let certification = save.documents.get(&DocumentKind::Persist)?.data.get("_certification")?.as_object()?;
    let text = |key: &str| certification.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned);
    Some(Session {
        player_id: text("_playerId")?,
        credential: text("_authorizationKey")?,
        device_id: text("_deviceId"),
    })
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct GameError(pub &'static str);

impl From<FormatError> for GameError {
    fn from(_: FormatError) -> Self {
        GameError("history_response_invalid")
    }
}

/// An HTTP proxy for the game's hosts, as the platform names it.
#[derive(Clone, Debug)]
pub struct Proxy {
    pub host: String,
    pub port: u16,
}

struct Response {
    status: Option<u32>,
    message: String,
    metadata: HashMap<String, String>,
    body: Vec<u8>,
}

/// Web PKI roots with the ring provider, shared by every HTTPS request the app makes.
pub(crate) fn tls_roots() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            Arc::new(
                rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                    .with_safe_default_protocol_versions()
                    .expect("protocol versions")
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )
        })
        .clone()
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth();
            config.alpn_protocols = vec![b"h2".to_vec()];
            Arc::new(config)
        })
        .clone()
}

/// Every resolved address in turn, IPv4 first, each with its own time limit,
/// so one unroutable address cannot use up the whole attempt. When none
/// answers, as when a VPN's fake-IP table has lost the name, the addresses
/// from DNS over HTTPS are tried as well.
async fn direct(host: &str) -> std::io::Result<TcpStream> {
    let mut addresses: Vec<std::net::SocketAddr> = match tokio::net::lookup_host((host, 443)).await {
        Ok(found) => found.collect(),
        Err(error) => {
            log::warn!("game resolve {host}: {error}");
            Vec::new()
        }
    };
    addresses.sort_by_key(|address| address.is_ipv6());
    let mut last = std::io::Error::new(std::io::ErrorKind::NotFound, "no address");
    if let Some(stream) = first_answering(host, &addresses, &mut last).await {
        return Ok(stream);
    }
    let fallback: Vec<_> = resolve_over_https(host).await.into_iter().filter(|address| !addresses.contains(address)).collect();
    first_answering(host, &fallback, &mut last).await.ok_or(last)
}

async fn first_answering(host: &str, addresses: &[std::net::SocketAddr], last: &mut std::io::Error) -> Option<TcpStream> {
    for &address in addresses {
        match tokio::time::timeout(Duration::from_secs(6), TcpStream::connect(address)).await {
            Ok(Ok(stream)) => return Some(stream),
            Ok(Err(error)) => {
                log::warn!("game connect {host} {address}: {error}");
                *last = error;
            }
            Err(_) => {
                log::warn!("game connect {host} {address}: timed out");
                *last = std::io::Error::from(std::io::ErrorKind::TimedOut);
            }
        }
    }
    None
}

async fn resolve_over_https(host: &str) -> Vec<std::net::SocketAddr> {
    for server in ["223.5.5.5", "8.8.8.8"] {
        let url = format!("https://{server}/resolve?name={host}&type=A");
        let Ok(Ok(body)) = tokio::time::timeout(Duration::from_secs(5), crate::http::get(&url, 64 * 1024)).await else { continue };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) else { continue };
        let found: Vec<_> = value["Answer"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|answer| answer["type"] == 1)
            .filter_map(|answer| answer["data"].as_str()?.parse::<std::net::Ipv4Addr>().ok())
            .map(|ip| std::net::SocketAddr::from((ip, 443)))
            .collect();
        if !found.is_empty() {
            return found;
        }
    }
    Vec::new()
}

async fn connect(host: &str, proxy: Option<&Proxy>) -> std::io::Result<TcpStream> {
    let Some(proxy) = proxy else {
        return direct(host).await;
    };
    let mut stream = TcpStream::connect((proxy.host.as_str(), proxy.port)).await?;
    stream
        .write_all(format!("CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n").as_bytes())
        .await?;
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 8192 {
            return Err(std::io::Error::other("proxy"));
        }
        let byte = stream.read_u8().await?;
        head.push(byte);
    }
    let line = String::from_utf8_lossy(&head);
    if !line.split_whitespace().nth(1).is_some_and(|code| code.starts_with('2')) {
        return Err(std::io::Error::other("proxy"));
    }
    Ok(stream)
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(value) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(value);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

async fn unary(
    region: Region,
    method: &str,
    metadata: &[(&str, String)],
    timeout: Duration,
    proxy: Option<&Proxy>,
) -> Result<Response, GameError> {
    let network = GameError("history_network_error");
    let host = region.host();
    let failed = |stage: &str, error: &dyn std::fmt::Display| {
        log::warn!("game {stage} {host}: {error}");
        GameError("history_network_error")
    };
    let tcp = tokio::time::timeout(Duration::from_secs(20), connect(host, proxy))
        .await
        .map_err(|error| failed("connect", &error))?
        .map_err(|error| failed("connect", &error))?;
    let name = rustls::pki_types::ServerName::try_from(host.to_owned()).map_err(|error| failed("name", &error))?;
    let tls = tokio_rustls::TlsConnector::from(tls_config()).connect(name, tcp).await.map_err(|error| failed("tls", &error))?;
    let exchange = async {
        let (client, connection) = h2::client::handshake(tls).await.map_err(|error| failed("h2", &error))?;
        tokio::spawn(async move {
            let _ = connection.await;
        });
        let mut client = client.ready().await.map_err(|_| GameError("history_network_error"))?;
        let mut request = http::Request::builder()
            .method("POST")
            .uri(format!("https://{host}/{method}"))
            .header("content-type", "application/grpc")
            .header("te", "trailers")
            .header("grpc-accept-encoding", "identity")
            .header("grpc-timeout", format!("{}m", timeout.as_millis()))
            .header("user-agent", "grpc-rust/haneoka-app");
        for (key, value) in metadata {
            request = request.header(*key, value);
        }
        let request = request.body(()).map_err(|_| GameError("history_network_error"))?;
        let (response, mut send) = client.send_request(request, false).map_err(|_| GameError("history_network_error"))?;
        send.send_data(Bytes::from_static(&[0, 0, 0, 0, 0]), true).map_err(|_| GameError("history_network_error"))?;
        let response = response.await.map_err(|error| failed("response", &error))?;
        let (parts, mut body) = response.into_parts();
        let mut collected = HashMap::new();
        for (key, value) in &parts.headers {
            if let Ok(value) = value.to_str() {
                collected.insert(key.as_str().to_owned(), value.to_owned());
            }
        }
        let mut data = Vec::new();
        while let Some(chunk) = body.data().await {
            let chunk = chunk.map_err(|_| GameError("history_network_error"))?;
            let _ = body.flow_control().release_capacity(chunk.len());
            if data.len() + chunk.len() > RESPONSE_LIMIT + 5 {
                return Err(GameError("history_response_invalid"));
            }
            data.extend_from_slice(chunk.chunk());
        }
        if let Ok(Some(trailers)) = body.trailers().await {
            for (key, value) in &trailers {
                if let Ok(value) = value.to_str() {
                    collected.insert(key.as_str().to_owned(), value.to_owned());
                }
            }
        }
        let status = collected.get("grpc-status").and_then(|s| s.parse().ok());
        let message = collected.get("grpc-message").map(|m| percent_decode(m)).unwrap_or_default();
        let body = if status == Some(0) && data.len() >= 5 {
            if data[0] != 0 {
                return Err(GameError("history_response_invalid"));
            }
            let size = u32::from_be_bytes([data[1], data[2], data[3], data[4]]) as usize;
            if size > RESPONSE_LIMIT || data.len() < 5 + size {
                return Err(GameError("history_response_invalid"));
            }
            data[5..5 + size].to_vec()
        } else {
            Vec::new()
        };
        Ok(Response { status, message, metadata: collected, body })
    };
    tokio::time::timeout(timeout + Duration::from_secs(5), exchange).await.map_err(|_| network)?
}

const PERMISSION_DENIED: u32 = 7;
const UNAUTHENTICATED: u32 = 16;
const UNAVAILABLE: u32 = 14;
const DEADLINE: u32 = 4;
const CANCELLED: u32 = 1;
const DATA_LOSS: u32 = 15;

fn versions() -> &'static Mutex<HashMap<Region, String>> {
    static VERSIONS: OnceLock<Mutex<HashMap<Region, String>>> = OnceLock::new();
    VERSIONS.get_or_init(Default::default)
}

fn version_valid(version: &str) -> bool {
    let parts: Vec<&str> = version.split('.').collect();
    version.len() <= 32 && (2..=5).contains(&parts.len()) && parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

fn base_metadata(region: Region, version: &str) -> Vec<(&'static str, String)> {
    let mut out = Vec::new();
    if region == Region::Jp {
        out.push(("x-platform", if cfg!(target_os = "ios") { "iOS" } else { "Android" }.to_owned()));
    }
    out.push(("x-client-version", version.to_owned()));
    out
}

async fn discover(region: Region, proxy: Option<&Proxy>) -> Result<String, GameError> {
    let method = if region == Region::Jp {
        "app.announcement.AnnouncementService/GetList"
    } else {
        "app.masterdata.MasterdataService/Version"
    };
    for attempt in 0..2 {
        let response = unary(region, method, &base_metadata(region, "0.0.0"), Duration::from_secs(10), proxy).await;
        let response = match response {
            Ok(response) => response,
            Err(_) if attempt == 0 => continue,
            Err(error) => return Err(error),
        };
        if matches!(response.status, Some(PERMISSION_DENIED | UNAUTHENTICATED)) || response.message == "authentication failed" {
            return Err(GameError("history_service_unavailable"));
        }
        if let Some(version) = response.metadata.get("x-client-recommended-version").filter(|v| version_valid(v)) {
            versions().lock().unwrap().insert(region, version.clone());
            return Ok(version.clone());
        }
        match response.status {
            Some(UNAVAILABLE) if attempt == 0 => continue,
            Some(UNAVAILABLE | DEADLINE | CANCELLED) => return Err(GameError("history_network_error")),
            Some(DATA_LOSS) => return Err(GameError("history_response_invalid")),
            _ => return Err(GameError("history_version_unavailable")),
        }
    }
    Err(GameError("history_version_unavailable"))
}

async fn authenticated(session: &Session, region: Region, method: &str, proxy: Option<&Proxy>) -> Result<(Vec<u8>, String), GameError> {
    let cached = versions().lock().unwrap().get(&region).cloned();
    let mut version = match cached {
        Some(version) => version,
        None => discover(region, proxy).await?,
    };
    for attempt in 0..2 {
        let mut metadata = base_metadata(region, &version);
        metadata.extend(session.metadata());
        let response = unary(region, method, &metadata, Duration::from_secs(25), proxy).await?;
        match response.status {
            Some(0) => return Ok((response.body, version)),
            _ if attempt == 0 && response.message == "client update required" => {
                versions().lock().unwrap().remove(&region);
                version = discover(region, proxy).await?;
            }
            _ if response.status == Some(UNAUTHENTICATED) || response.message == "authentication failed" => {
                return Err(GameError("history_session_expired"))
            }
            Some(PERMISSION_DENIED) => return Err(GameError("history_service_unavailable")),
            Some(DATA_LOSS) => return Err(GameError("history_response_invalid")),
            _ => return Err(GameError("history_network_error")),
        }
    }
    Err(GameError("history_version_unavailable"))
}

fn sha(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// The key the website files an account's history under.
pub fn history_key(save: &GameSave) -> Option<String> {
    let region = Region::of(save)?;
    let save_key = sha(&format!("{}:{}", save.server().unwrap_or("unknown"), save.profile_id));
    Some(format!("{save_key}-{}", region.id()))
}

fn scalars(bytes: &[u8], fields: &[u64]) -> Result<HashMap<u64, u64>, FormatError> {
    let mut values = HashMap::new();
    let mut reader = Reader::new(bytes);
    while let Some((number, field)) = reader.next()? {
        if fields.contains(&number) {
            let Field::Varint(value) = field else { return Err(FormatError("history_field")) };
            if values.insert(number, value).is_some() || (value as i64) < 0 {
                return Err(FormatError("history_field"));
            }
        }
    }
    Ok(values)
}

fn amount(value: Option<u64>, maximum: u64) -> Result<Value, FormatError> {
    match value {
        None => Ok(Value::Null),
        Some(v) if v <= maximum => Ok(json!(v)),
        _ => Err(FormatError("history_amount")),
    }
}

fn identifier(value: Option<u64>) -> Value {
    value.map(|v| Value::String(v.to_string())).unwrap_or(Value::Null)
}

fn prize(bytes: &[u8], legacy: bool) -> Result<Value, FormatError> {
    let values = scalars(bytes, if legacy { &[1, 2, 3] } else { &[1, 2] })?;
    let converted = values.get(&if legacy { 3 } else { 2 }).copied().unwrap_or(0);
    if converted > 1 {
        return Err(FormatError("history_prize"));
    }
    Ok(json!({ "prizeId": values.get(&1).copied().unwrap_or(0).to_string(), "converted": converted == 1 }))
}

const MAX_TIME: u64 = 253402271999;
const MAX_AMOUNT: u64 = 2147483647;

/// The `haneoka-gacha-history-v1` snapshot for one GachaService/History response.
pub fn decode_history(bytes: &[u8], server: &str, client_version: &str, account_key: Option<&str>) -> Result<Value, FormatError> {
    if bytes.len() > RESPONSE_LIMIT {
        return Err(FormatError("history_size"));
    }
    let (mut legacy, mut raw) = (Vec::new(), Vec::new());
    let mut reader = Reader::new(bytes);
    while let Some((number, field)) = reader.next()? {
        if number == 1 || number == 2 {
            let Field::Bytes(value) = field else { return Err(FormatError("history_field")) };
            let target = if number == 1 { &mut legacy } else { &mut raw };
            target.push(value);
            if target.len() > 100000 {
                return Err(FormatError("history_size"));
            }
        }
    }
    if !bytes.is_empty() && legacy.is_empty() && raw.is_empty() {
        return Err(FormatError("history_response"));
    }
    let mut batches = Vec::new();
    let mut count = 0;
    for row in &raw {
        let values = scalars(row, &[1, 2, 3, 4, 5, 6])?;
        let mut prizes = Vec::new();
        let mut inner = Reader::new(row);
        while let Some((number, field)) = inner.next()? {
            if number == 7 {
                let Field::Bytes(value) = field else { return Err(FormatError("history_prize")) };
                count += 1;
                if count > 250000 {
                    return Err(FormatError("history_prize"));
                }
                prizes.push(prize(value, false)?);
            }
        }
        if prizes.is_empty() {
            return Err(FormatError("history_batch"));
        }
        batches.push(json!({
            "poolId": identifier(values.get(&1).copied()),
            "productId": identifier(values.get(&2).copied().filter(|&v| v != 0)),
            "executedAt": amount(values.get(&6).copied().filter(|&v| v != 0), MAX_TIME)?,
            "freeGems": amount(Some(values.get(&3).copied().unwrap_or(0)), MAX_AMOUNT)?,
            "paidGems": amount(Some(values.get(&4).copied().unwrap_or(0)), MAX_AMOUNT)?,
            "tickets": amount(Some(values.get(&5).copied().unwrap_or(0)), MAX_AMOUNT)?,
            "prizes": prizes,
        }));
    }
    if raw.is_empty() {
        for row in &legacy {
            let values = scalars(row, &[1, 2, 3])?;
            batches.push(json!({
                "poolId": null,
                "productId": null,
                "executedAt": amount(values.get(&2).copied().filter(|&v| v != 0), MAX_TIME)?,
                "freeGems": null,
                "paidGems": null,
                "tickets": null,
                "prizes": [prize(row, true)?],
            }));
        }
    }
    let mut source = json!({ "server": server, "clientVersion": client_version });
    if let Some(key) = account_key {
        source["accountKey"] = json!(key);
    }
    Ok(json!({
        "schema": "haneoka-gacha-history-v1",
        "source": source,
        "queriedAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "historyKind": if !raw.is_empty() { "execution" } else if !legacy.is_empty() { "legacy" } else { "empty" },
        "legacyOmittedCount": if raw.is_empty() { 0 } else { legacy.len() },
        "coverage": { "scope": "server-returned", "retentionDays": null, "orderWithinBatch": null },
        "batches": batches,
    }))
}

/// The account's gacha history as the website's importer takes it.
pub async fn read_history(save: &GameSave, proxy: Option<&Proxy>) -> Result<(String, String), GameError> {
    let (session, region) = match (session(save), Region::of(save)) {
        (Some(s), Some(r)) => (s, r),
        _ => return Err(GameError("history_missing_session")),
    };
    let key = history_key(save).ok_or(GameError("history_missing_session"))?;
    let (bytes, version) = authenticated(&session, region, "app.gacha.GachaService/History", proxy).await?;
    let portable = sha(&format!("{}:{key}", region.id()));
    let snapshot = decode_history(&bytes, region.id(), &version, Some(&portable))?;
    Ok((format!("{key}.json"), snapshot.to_string()))
}

const PLAYER_COLLECTIONS: &[(u64, &str, &[(u64, &str)])] = &[
    (2, "_memberCards", &[(2, "_masterId"), (3, "_exp"), (4, "_awakeCount"), (5, "_rank"), (7, "_liveSkillLevel"), (8, "_performanceSkillLevel")]),
    (3, "_supportCards", &[(2, "_masterId"), (3, "_exp"), (5, "_rank"), (7, "_duplicateCount")]),
    (8, "_bandItems", &[(1, "_masterId"), (2, "_level")]),
    (12, "_characters", &[(1, "_masterId"), (2, "_exp")]),
];

/// The progress in a GetPlayerDataResponse, keyed as LocalCacheData's `_player`.
pub fn decode_player_data(response: &[u8]) -> Result<Map<String, Value>, FormatError> {
    if response.len() > RESPONSE_LIMIT {
        return Err(FormatError("player_data_size"));
    }
    let mut players = Vec::new();
    let mut reader = Reader::new(response);
    while let Some((number, field)) = reader.next()? {
        if let (1, Field::Bytes(value)) = (number, field) {
            players.push(value);
        }
    }
    if players.len() != 1 {
        return Err(FormatError("player_data_missing"));
    }
    let mut out: Map<String, Value> = PLAYER_COLLECTIONS.iter().map(|(_, key, _)| ((*key).to_owned(), json!([]))).collect();
    let mut records = 0;
    let mut reader = Reader::new(players[0]);
    while let Some((number, field)) = reader.next()? {
        let Some((_, key, spec)) = PLAYER_COLLECTIONS.iter().find(|(n, _, _)| *n == number) else { continue };
        let Field::Bytes(value) = field else { continue };
        records += 1;
        if records > 10000 {
            return Err(FormatError("player_data_size"));
        }
        let mut row: Map<String, Value> = spec.iter().map(|(_, name)| ((*name).to_owned(), json!(0))).collect();
        let mut inner = Reader::new(value);
        while let Some((field_number, field)) = inner.next()? {
            if let (Some((_, name)), Field::Varint(v)) = (spec.iter().find(|(n, _)| *n == field_number), field) {
                row.insert((*name).to_owned(), json!(v as i64));
            }
        }
        if row.get("_masterId").and_then(Value::as_i64).unwrap_or(0) <= 0 {
            return Err(FormatError("player_data_identity"));
        }
        out.get_mut(*key).unwrap().as_array_mut().unwrap().push(Value::Object(row));
    }
    Ok(out)
}

fn ids(rows: Option<&Value>) -> std::collections::HashSet<String> {
    rows.and_then(Value::as_array)
        .map(|rows| rows.iter().filter_map(|r| r.get("_masterId")).map(|v| v.to_string().trim_matches('"').to_owned()).collect())
        .unwrap_or_default()
}

/// The save with its card, character and band item lists replaced by the
/// game server's current ones. A response missing cards the save already has
/// is refused: cards are never lost in the game.
pub async fn refresh(save: &GameSave, proxy: Option<&Proxy>) -> Result<GameSave, GameError> {
    let (session, region) = match (session(save), Region::of(save)) {
        (Some(s), Some(r)) => (s, r),
        _ => return Err(GameError("no_session")),
    };
    let (bytes, _) = authenticated(&session, region, "app.player.PlayerService/GetPlayerData", proxy).await?;
    let fresh = decode_player_data(&bytes)?;
    let player = save.player().cloned().unwrap_or_default();
    for key in ["_memberCards", "_supportCards"] {
        let known = ids(player.get(key));
        if !known.is_empty() && !known.is_subset(&ids(fresh.get(key))) {
            return Err(GameError("player_data_unrecognized"));
        }
    }
    if fresh.get("_memberCards").and_then(Value::as_array).is_none_or(Vec::is_empty) {
        return Err(GameError("player_data_unrecognized"));
    }
    let mut updated = save.clone();
    let mut cache = save.documents.get(&DocumentKind::Cache).map(|d| d.data.clone()).unwrap_or_default();
    let mut next = player;
    for (key, value) in fresh {
        next.insert(key, value);
    }
    cache.insert("_player".into(), Value::Object(next));
    updated.documents.insert(
        DocumentKind::Cache,
        SaveDocument { kind: DocumentKind::Cache, data: cache, modified_at: Some(chrono::Utc::now()) },
    );
    Ok(updated)
}

/// The client version the region's server recommends now.
pub async fn client_version(region: Region, proxy: Option<&Proxy>) -> Result<String, GameError> {
    discover(region, proxy).await
}
