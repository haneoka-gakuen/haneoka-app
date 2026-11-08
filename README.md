# Haneoka App

[![CI](https://github.com/haneoka-gakuen/haneoka-app/actions/workflows/ci.yml/badge.svg)](https://github.com/haneoka-gakuen/haneoka-app/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-2f356f.svg)](LICENSE)

[Haneoka](https://haneoka.org) for *BanG Dream! Our Notes* as an app on Android, iOS, Windows, macOS and Linux.

The app shows the live website in the system web view and adds what a browser cannot do:

- Read game saves from the phone's own game folder (Shizuku, or a folder grant on Android 8–12), a phone connected over USB or wireless debugging, an iPhone backup, or files and folders
- Keep those saves on the device and read gacha history and current card progress from the game's servers with the save's own session
- Provider sign-in in the system browser, file downloads and fullscreen playback

## Install

Download a build from the [download page](https://haneoka.org/en/download) or [GitHub Releases](https://github.com/haneoka-gakuen/haneoka-app/releases).

## Development

You need Rust, Node.js 22 and the [Tauri prerequisites](https://tauri.app/start/prerequisites/) for your platform.

```sh
npm ci
cargo test --workspace
npx tauri dev
```

`npx tauri build` packages the desktop app. For phones, run `npx tauri android init` or `npx tauri ios init` once, then `npx tauri android build` or `npx tauri ios build`. Release packaging for every platform is in [`.github/workflows/release.yml`](.github/workflows/release.yml).

| Path | Contents |
| --- | --- |
| `core` | Save decoding, account storage, file, ADB and iPhone backup sources, game-server reads |
| `src-tauri` | Window, launch page, deep links, sign-in and the `window.haneokaApp` bridge |
| `plugins/device` | Android: Shizuku and folder-grant reading, system bars, fullscreen and orientation |
| `ui` | The bundled launch page |

The website calls the app through `window.haneokaApp` (`src/lib/app-bridge.ts` in the website repository); [`src-tauri/src/bridge.rs`](src-tauri/src/bridge.rs) answers each method.

## License

[MPL-2.0](LICENSE). Game content belongs to its rights holders. This project is unofficial.
