//! The game's local save format, the same on every build and platform:
//!
//! ```text
//! magic[32] ‖ iv[32] ‖ Rijndael-256-CBC(key, iv, PKCS#7(json))
//! ```
//!
//! The key and magic are constants of the game client, not account secrets.

use serde_json::{Map, Value};

use crate::rijndael::Rijndael256;

pub const MAX_FILE_BYTES: usize = 16 << 20;

const MAGIC: [u8; 32] = hex32("b50b23a5fd628c3dc386f7488f81d6b0450b8c89671574f55a3ad815f10b8e30");
const KEY: [u8; 32] = hex32("0532791c510a08eb7ede6b46c6ba71ea9aa2a3cfb678a595f89d67c8a5e493b6");

const fn hex32(text: &str) -> [u8; 32] {
    const fn digit(c: u8) -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            _ => panic!("hex"),
        }
    }
    let bytes = text.as_bytes();
    let mut out = [0u8; 32];
    let mut i = 0;
    while i < 32 {
        out[i] = digit(bytes[i * 2]) << 4 | digit(bytes[i * 2 + 1]);
        i += 1;
    }
    out
}

fn cipher() -> &'static Rijndael256 {
    static CIPHER: std::sync::OnceLock<Rijndael256> = std::sync::OnceLock::new();
    CIPHER.get_or_init(|| Rijndael256::new(&KEY))
}

/// Cheap check on the first bytes, before decrypting anything.
pub fn looks_like_save(bytes: &[u8]) -> bool {
    bytes.len() >= 96 && bytes.len() <= MAX_FILE_BYTES && (bytes.len() - 64) % 32 == 0 && bytes[..32] == MAGIC
}

/// Reads an original encrypted save or its decrypted UTF-8 JSON object.
pub fn decode(bytes: &[u8]) -> Option<Map<String, Value>> {
    if bytes.len() > MAX_FILE_BYTES {
        return None;
    }
    if !looks_like_save(bytes) {
        return json(bytes);
    }
    let iv: [u8; 32] = bytes[32..64].try_into().ok()?;
    let mut plain = cipher().decrypt_cbc(&bytes[64..], &iv)?;
    let result = (|| {
        let pad = *plain.last()? as usize;
        if pad == 0 || pad > 32 || pad > plain.len() {
            return None;
        }
        if plain[plain.len() - pad..].iter().any(|&b| b as usize != pad) {
            return None;
        }
        json(&plain[..plain.len() - pad])
    })();
    plain.fill(0);
    result
}

fn json(bytes: &[u8]) -> Option<Map<String, Value>> {
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    let start = bytes.iter().position(|b| !b.is_ascii_whitespace())?;
    if bytes[start] != b'{' {
        return None;
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}
