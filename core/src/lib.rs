//! The Haneoka app's native work: reading the game's saves wherever they are,
//! keeping them on the device, and reading the game's servers with their
//! session. Everything the reader sees is drawn by the website.

pub mod codec;
pub mod export;
pub mod files;
pub mod direct;
pub mod game;
pub mod http;
pub mod proto;
mod rijndael;
pub mod save;
pub mod store;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub mod adb;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub mod ios_backup;
