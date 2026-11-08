//! Provider sign-in in the system browser, where providers allow it: the
//! provider's page hands a one-time code back to the app (PKCE) and the page
//! exchanges code and verifier for its session cookie.

use std::sync::Mutex;
use std::time::Duration;

use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};
use tauri::AppHandle;
use tauri_plugin_opener::OpenerExt;
use tokio::sync::oneshot;

#[derive(Default)]
pub struct Waiter(Mutex<Option<oneshot::Sender<url::Url>>>);

impl Waiter {
    /// A `haneoka://auth` link from the browser.
    pub fn deliver(&self, url: url::Url) {
        if let Some(sender) = self.0.lock().unwrap().take() {
            let _ = sender.send(url);
        }
    }

    fn wait(&self) -> oneshot::Receiver<url::Url> {
        let (sender, receiver) = oneshot::channel();
        *self.0.lock().unwrap() = Some(sender);
        receiver
    }
}

fn token(bytes: usize) -> String {
    let mut data = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut data);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

/// Desktop builds receive the code on a loopback listener (RFC 8252).
#[cfg(desktop)]
async fn loopback() -> std::io::Result<(u16, oneshot::Receiver<url::Url>)> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await?;
    let port = listener.local_addr()?.port();
    let (sender, receiver) = oneshot::channel();
    tauri::async_runtime::spawn(async move {
        let mut sender = Some(sender);
        let deadline = tokio::time::sleep(Duration::from_secs(600));
        tokio::pin!(deadline);
        loop {
            let accepted = tokio::select! {
                accepted = listener.accept() => accepted,
                _ = &mut deadline => return,
            };
            let Ok((mut stream, _)) = accepted else { continue };
            let mut buffer = vec![0u8; 8192];
            let Ok(read) = stream.read(&mut buffer).await else { continue };
            let request = String::from_utf8_lossy(&buffer[..read]);
            let target = request.lines().next().and_then(|l| l.split_whitespace().nth(1)).unwrap_or("/");
            let Ok(url) = url::Url::parse(&format!("http://127.0.0.1{target}")) else { continue };
            if url.path() != "/auth" {
                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                continue;
            }
            let body = "<!doctype html><meta charset=\"utf-8\"><title>Haneoka</title><body style=\"font:16px system-ui;text-align:center;padding:48px\">&#10003;</body>";
            let _ = stream
                .write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes())
                .await;
            if let Some(sender) = sender.take() {
                let _ = sender.send(url);
            }
            return;
        }
    });
    Ok((port, receiver))
}

/// The code and verifier, or None when the reader backs out.
pub async fn sign_in(app: &AppHandle, waiter: &Waiter, origin: &str, provider: &str) -> Result<Option<(String, String)>, String> {
    let verifier = token(48);
    let state = token(16);
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut url = url::Url::parse(&format!("{origin}/api/v1/account/app/oauth")).map_err(|e| e.to_string())?;
    url.query_pairs_mut().append_pair("challenge", &challenge).append_pair("state", &state).append_pair("provider", provider);
    #[cfg(desktop)]
    let receiver = {
        let _ = waiter;
        let (port, receiver) = loopback().await.map_err(|e| e.to_string())?;
        url.query_pairs_mut().append_pair("redirect", &format!("http://127.0.0.1:{port}/auth"));
        receiver
    };
    #[cfg(mobile)]
    let receiver = waiter.wait();
    #[cfg(desktop)]
    let _ = Waiter::wait;
    app.opener().open_url(url.as_str(), None::<&str>).map_err(|e| e.to_string())?;
    let Ok(Ok(returned)) = tokio::time::timeout(Duration::from_secs(600), receiver).await else {
        return Ok(None);
    };
    let query: std::collections::HashMap<_, _> = returned.query_pairs().into_owned().collect();
    if query.get("state") != Some(&state) {
        return Ok(None);
    }
    Ok(query.get("code").map(|code| (code.clone(), verifier)))
}
