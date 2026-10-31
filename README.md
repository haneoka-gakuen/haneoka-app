# Haneoka App

[![CI](https://github.com/haneoka-gakuen/haneoka-app/actions/workflows/ci.yml/badge.svg)](https://github.com/haneoka-gakuen/haneoka-app/actions/workflows/ci.yml)
[![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-2f356f.svg)](LICENSE)

The native [Haneoka](https://haneoka.org) client for *BanG Dream! Our Notes*, on Android, iOS, Windows, macOS and Linux.

## Features

- The full catalogue, stories, charts, Live2D and Spine, drawn natively
- Reads your save from a file, a phone or a backup, and shows what it holds
- Team builder with the same engine as the website, running on the device
- Card import from screenshots and screen recordings, recognised on the device
- Chart editor, community, playlists, event and Arena rankings, and player lookup
- Character, seasonal and birthday themes

## Install

Download a build from the [download page](https://haneoka.org/en/download) or [GitHub Releases](https://github.com/haneoka-gakuen/haneoka-app/releases).

## Development

You need Flutter 3.47.7 and the Rust toolchain in `rust-toolchain.toml`.

```sh
git submodule update --init --recursive
flutter pub get
flutter analyze
flutter build linux --release --no-pub
```

Replace `linux` with your target. Packaging for each platform is in [`.github/workflows/release.yml`](.github/workflows/release.yml) and [`scripts/`](scripts).

| Path | Contents |
| --- | --- |
| `lib/catalog`, `lib/search`, `lib/stories` | Catalogue, search and story playback |
| `lib/team_builder` | Team builder, Box and card import |
| `lib/save`, `lib/sources` | Save reading and sources |
| `lib/chart_editor`, `lib/rendering` | Chart editor and renderers |
| `lib/community`, `lib/playlists`, `lib/admin` | Community features |
| `lib/shell` | Navigation, routes and settings |
| `native/team_engine` | [Team engine](https://github.com/haneoka-gakuen/ournotes-team-builder) submodule |
| `assets/i18n` | Strings in five languages, shared with the website |

## License

[MPL-2.0](LICENSE). Game content belongs to its rights holders. This project is unofficial.
