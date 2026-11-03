# Haneoka App

[![CI](https://github.com/haneoka-gakuen/haneoka-app/actions/workflows/ci.yml/badge.svg)](https://github.com/haneoka-gakuen/haneoka-app/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-2f356f.svg)](LICENSE)

[Haneoka](https://haneoka.org) for *BanG Dream! Our Notes* on Android, iOS, Windows, macOS and Linux. The app shows the live website, so every page and tool is always the current one, and adds what a browser cannot do.

## Features

- The whole website, with the system bars in the page's colours and players in true fullscreen
- Startup progress and retry, with game-save access available while the website is offline
- Game accounts read from this phone (Shizuku or the game folder), an Android phone over USB or Wi-Fi, an iPhone backup, or save files
- Card progress sent to the team builder, refreshed from the game server first
- Gacha history read from the game server into the gacha history page
- Provider sign-in through the system browser, and file downloads saved to the device

Accounts imported by earlier versions stay on the device and appear in the account list.

## Install

Download a build from the [download page](https://haneoka.org/en/download) or [GitHub Releases](https://github.com/haneoka-gakuen/haneoka-app/releases). Linux packages use the system's WebKitGTK 4.1; Windows uses WebView2.

## Development

You need Flutter 3.47.7.

```sh
flutter pub get
flutter analyze
flutter run --dart-define=HANEOKA_ORIGIN=http://127.0.0.1:4319
```

`HANEOKA_ORIGIN` points the app at a local preview; it defaults to `https://haneoka.org`. Packaging for each platform is in [`.github/workflows/release.yml`](.github/workflows/release.yml) and [`scripts/`](scripts).

| Path | Contents |
| --- | --- |
| `lib/shell` | Web view, startup and recovery screens, page bridge, native colours, sign-in, strings |
| `lib/accounts` | Game account sheet and its sources |
| `lib/save`, `lib/sources` | Save reading, account storage and game-server refresh |
| `lib/gacha_history` | Gacha history read for the website |

The website side of the bridge is `src/lib/app-bridge.ts` in the Haneoka repository: `boxAccount`, `gachaHistory` and `signIn`.

The native launch screen renders before bundled text and WebView initialization. Native public API clients are created on first use, keeping Cronet/JNI initialization out of app startup; the WebView starts after Flutter's first frame is rasterized. Intel Android builds use Skia for graphics compatibility. Initialization has a 20-second deadline; page loading has a separate 30-second deadline. A Haneoka document's first-paint signal or a document-readiness check reveals the page. Network and initialization failures retain Retry and Open in browser; game-save screens remain available without the website. Retrying keeps cookies, account data and imported saves.

## License

[MPL-2.0](LICENSE). Game content belongs to its rights holders. This project is unofficial.
