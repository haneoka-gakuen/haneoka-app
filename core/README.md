# haneoka-core

Native work for the Haneoka app: decoding the game's saves, keeping imported accounts on the device, reading saves from files, ZIP archives, a phone over ADB and iPhone backups, and reading gacha history and card progress from the game's servers with a save's own session.

```sh
cargo test -p haneoka-core
cargo test -p haneoka-core --test live -- --ignored   # contacts the game servers
```
