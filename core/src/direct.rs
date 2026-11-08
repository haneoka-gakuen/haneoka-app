//! A loopback HTTP proxy for the app's web view. Requests for the site go to
//! the Cloudflare address that answers fastest from this network, found over
//! DNS over HTTPS and measured, so a poisoned or slow route does not block
//! the site; TLS stays end to end in the web view. Other hosts connect as
//! they would without the proxy, or through the system proxy when one is set.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::game::Proxy;

const SITES: [&str; 2] = ["haneoka.org", "haneoka.com"];

/// Addresses across Cloudflare's anycast ranges; any of them serves a
/// proxied hostname by its TLS server name.
const ANYCAST: [[u8; 4]; 12] = [
    [104, 16, 132, 229],
    [104, 17, 64, 4],
    [104, 18, 32, 47],
    [104, 19, 236, 172],
    [104, 21, 17, 205],
    [104, 24, 0, 1],
    [172, 64, 80, 1],
    [172, 66, 40, 1],
    [172, 67, 178, 75],
    [162, 159, 36, 1],
    [188, 114, 96, 3],
    [141, 101, 90, 1],
];

const MEASURE_EVERY: Duration = Duration::from_secs(600);

struct Ranking {
    addresses: Vec<IpAddr>,
    measured: Option<Instant>,
}

/// The measured order of site addresses, shared by every connection.
#[derive(Clone)]
pub struct Router {
    ranking: Arc<Mutex<Ranking>>,
    measuring: Arc<tokio::sync::Mutex<()>>,
    upstream: Option<Proxy>,
}

fn is_site(host: &str) -> bool {
    SITES.iter().any(|site| host == *site || host.ends_with(&format!(".{site}")))
}

impl Router {
    pub fn new(upstream: Option<Proxy>) -> Self {
        Router {
            ranking: Arc::new(Mutex::new(Ranking { addresses: Vec::new(), measured: None })),
            measuring: Arc::new(tokio::sync::Mutex::new(())),
            upstream,
        }
    }

    /// The site's addresses from DNS over HTTPS and the anycast sample,
    /// fastest TCP handshake first.
    pub async fn measure(&self) {
        let _guard = self.measuring.lock().await;
        let mut candidates: Vec<IpAddr> = ANYCAST.iter().map(|a| IpAddr::V4(Ipv4Addr::from(*a))).collect();
        for site in SITES {
            for address in crate::game::resolve_over_https(site).await {
                if !candidates.contains(&address.ip()) {
                    candidates.push(address.ip());
                }
            }
        }
        let probes = candidates.into_iter().map(|ip| async move {
            let start = Instant::now();
            let served = tokio::time::timeout(Duration::from_secs(4), serves_site(ip)).await;
            matches!(served, Ok(true)).then(|| (start.elapsed(), ip))
        });
        let mut timed: Vec<(Duration, IpAddr)> = futures_join(probes).await.into_iter().flatten().collect();
        timed.sort();
        log::info!("direct ranking {:?}", timed.iter().take(4).collect::<Vec<_>>());
        let mut ranking = self.ranking.lock().unwrap();
        ranking.addresses = timed.into_iter().map(|(_, ip)| ip).collect();
        ranking.measured = Some(Instant::now());
    }

    fn ranked(&self) -> (Vec<IpAddr>, bool) {
        let ranking = self.ranking.lock().unwrap();
        let stale = ranking.measured.is_none_or(|at| at.elapsed() > MEASURE_EVERY);
        (ranking.addresses.clone(), stale)
    }

    async fn connect_site(&self, host: &str, port: u16) -> std::io::Result<TcpStream> {
        let (addresses, stale) = self.ranked();
        if stale {
            let router = self.clone();
            tokio::spawn(async move { router.measure().await });
        }
        // The three fastest race; the system's own route is the last resort.
        let racing = addresses.into_iter().take(3).enumerate().map(|(index, ip)| async move {
            tokio::time::sleep(Duration::from_millis(150 * index as u64)).await;
            tokio::time::timeout(Duration::from_secs(4), TcpStream::connect(SocketAddr::new(ip, port))).await
        });
        if let Some(stream) = first_ok(racing).await {
            return Ok(stream);
        }
        if !self.ranked().1 {
            let router = self.clone();
            tokio::spawn(async move { router.measure().await });
        }
        TcpStream::connect((host, port)).await
    }

    async fn connect(&self, host: &str, port: u16) -> std::io::Result<TcpStream> {
        if let Some(upstream) = &self.upstream {
            return crate::game::connect_through(upstream, host, port).await;
        }
        if is_site(host) && port == 443 {
            return self.connect_site(host, port).await;
        }
        TcpStream::connect((host, port)).await
    }
}

/// Whether `ip` answers for the site: a TLS handshake for haneoka.org and
/// a 200 for robots.txt. Not every Cloudflare address serves
/// every zone.
async fn serves_site(ip: IpAddr) -> bool {
    async fn probe(ip: IpAddr) -> std::io::Result<bool> {
        let tcp = TcpStream::connect(SocketAddr::new(ip, 443)).await?;
        let name = rustls::pki_types::ServerName::try_from("haneoka.org").map_err(std::io::Error::other)?;
        let mut config = (*crate::game::tls_roots()).clone();
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        let mut tls = tokio_rustls::TlsConnector::from(Arc::new(config)).connect(name, tcp).await?;
        tls.write_all(b"GET /robots.txt HTTP/1.1\r\nHost: haneoka.org\r\nConnection: close\r\n\r\n").await?;
        let mut head = [0u8; 16];
        let read = tls.read(&mut head).await?;
        Ok(head[..read].starts_with(b"HTTP/1.1 200"))
    }
    probe(ip).await.unwrap_or(false)
}

async fn futures_join<F>(futures: impl IntoIterator<Item = F>) -> Vec<F::Output>
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let handles: Vec<_> = futures.into_iter().map(tokio::spawn).collect();
    let mut out = Vec::with_capacity(handles.len());
    for handle in handles {
        if let Ok(value) = handle.await {
            out.push(value);
        }
    }
    out
}

async fn first_ok<F>(futures: impl IntoIterator<Item = F>) -> Option<TcpStream>
where
    F: std::future::Future<Output = Result<std::io::Result<TcpStream>, tokio::time::error::Elapsed>> + Send + 'static,
{
    let (sender, mut receiver) = tokio::sync::mpsc::channel(4);
    let mut count = 0;
    for future in futures {
        count += 1;
        let sender = sender.clone();
        tokio::spawn(async move {
            let _ = sender.send(future.await).await;
        });
    }
    drop(sender);
    for _ in 0..count {
        if let Some(Ok(Ok(stream))) = receiver.recv().await {
            return Some(stream);
        }
    }
    None
}

/// Serves the proxy on `listener` until the app exits.
pub async fn serve(listener: TcpListener, router: Router) {
    {
        let router = router.clone();
        tokio::spawn(async move { router.measure().await });
    }
    loop {
        let Ok((client, _)) = listener.accept().await else { continue };
        let router = router.clone();
        tokio::spawn(async move {
            if let Err(error) = relay(client, router).await {
                log::debug!("direct relay: {error}");
            }
        });
    }
}

async fn relay(mut client: TcpStream, router: Router) -> std::io::Result<()> {
    let _ = client.set_nodelay(true);
    let mut head = Vec::with_capacity(1024);
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 16 * 1024 || client.read(&mut byte).await? == 0 {
            return Ok(());
        }
        head.push(byte[0]);
    }
    let text = String::from_utf8_lossy(&head).into_owned();
    let mut words = text.split_whitespace();
    let (method, target) = (words.next().unwrap_or(""), words.next().unwrap_or(""));
    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = target.rsplit_once(':').and_then(|(h, p)| Some((h.trim_matches(['[', ']']), p.parse().ok()?))).unwrap_or((target, 443));
        let mut upstream = match router.connect(host, port).await {
            Ok(stream) => stream,
            Err(_) => {
                client.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n").await?;
                return Ok(());
            }
        };
        let _ = upstream.set_nodelay(true);
        client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
        tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
        return Ok(());
    }
    // Plain HTTP in absolute form: forward it to the host in origin form.
    let Some(rest) = target.strip_prefix("http://") else { return Ok(()) };
    let (authority, path) = rest.find('/').map_or((rest, "/"), |slash| (&rest[..slash], &rest[slash..]));
    let (host, port) = authority.rsplit_once(':').and_then(|(h, p)| Some((h, p.parse().ok()?))).unwrap_or((authority, 80));
    let mut upstream = router.connect(host, port).await?;
    let rewritten = text.replacen(target, path, 1);
    upstream.write_all(rewritten.as_bytes()).await?;
    tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
    Ok(())
}
