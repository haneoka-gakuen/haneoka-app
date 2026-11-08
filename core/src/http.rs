//! A small HTTPS GET for release metadata on platforms without the updater.

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct HttpError(pub &'static str);

/// The body of `url`, following up to five redirects; at most `limit` bytes.
pub async fn get(url: &str, limit: usize) -> Result<Vec<u8>, HttpError> {
    let mut target = url.to_owned();
    for _ in 0..6 {
        let request = tokio::time::timeout(Duration::from_secs(20), once(&target, limit));
        match request.await.map_err(|_| HttpError("timeout"))?? {
            Response::Body(body) => return Ok(body),
            Response::Redirect(location) => target = location,
        }
    }
    Err(HttpError("redirects"))
}

enum Response {
    Body(Vec<u8>),
    Redirect(String),
}

fn split(url: &str) -> Option<(&str, &str)> {
    let rest = url.strip_prefix("https://")?;
    let slash = rest.find('/').unwrap_or(rest.len());
    let path = if slash == rest.len() { "/" } else { &rest[slash..] };
    Some((&rest[..slash], path))
}

async fn once(url: &str, limit: usize) -> Result<Response, HttpError> {
    let (host, path) = split(url).ok_or(HttpError("url"))?;
    let tcp = tokio::net::TcpStream::connect((host, 443)).await.map_err(|_| HttpError("connect"))?;
    let name = rustls::pki_types::ServerName::try_from(host.to_owned()).map_err(|_| HttpError("host"))?;
    let mut config = (*crate::game::tls_roots()).clone();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let mut stream = tokio_rustls::TlsConnector::from(std::sync::Arc::new(config))
        .connect(name, tcp)
        .await
        .map_err(|_| HttpError("tls"))?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: haneoka-app\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).await.map_err(|_| HttpError("write"))?;
    let mut raw = Vec::new();
    (&mut stream).take((limit + 16 * 1024) as u64).read_to_end(&mut raw).await.map_err(|_| HttpError("read"))?;
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or(HttpError("response"))?;
    let head = String::from_utf8_lossy(&raw[..end]).into_owned();
    let mut body = raw[end + 4..].to_vec();
    let status: u16 = head.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or(HttpError("response"))?;
    let header = |name: &str| {
        head.lines().skip(1).find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim().eq_ignore_ascii_case(name).then(|| value.trim().to_owned())
        })
    };
    if (300..400).contains(&status) {
        let location = header("location").ok_or(HttpError("redirect"))?;
        let absolute = if location.starts_with("https://") { location } else { format!("https://{host}{location}") };
        return Ok(Response::Redirect(absolute));
    }
    if status != 200 {
        return Err(HttpError("status"));
    }
    if header("transfer-encoding").is_some_and(|v| v.eq_ignore_ascii_case("chunked")) {
        body = dechunk(&body).ok_or(HttpError("chunked"))?;
    }
    if body.len() > limit {
        return Err(HttpError("size"));
    }
    Ok(Response::Body(body))
}

fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let line = data.windows(2).position(|w| w == b"\r\n")?;
        let size = usize::from_str_radix(std::str::from_utf8(&data[..line]).ok()?.split(';').next()?.trim(), 16).ok()?;
        data = &data[line + 2..];
        if size == 0 {
            return Some(out);
        }
        out.extend_from_slice(data.get(..size)?);
        data = data.get(size + 2..)?;
    }
}
