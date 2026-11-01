#!/usr/bin/env python3
"""Builds assets/render/base-pack.{bin,json}: the chart and story files every
song and story uses, so the players start without downloading them.

The paths are listed in scripts/base_pack.txt (one site path per line, as the
app requests it). Each file is fetched from the site's current release.
"""
import argparse
import json
import pathlib
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parent.parent


def fetch(origin: str, path: str) -> bytes | None:
    request = urllib.request.Request(origin + path, headers={"User-Agent": "haneoka-base-pack"})
    for _ in range(4):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read() if response.status == 200 else None
        except OSError:
            continue
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--origin", default="https://haneoka.org")
    parser.add_argument("--list", default=str(ROOT / "scripts/base_pack.txt"))
    parser.add_argument("--out", default=str(ROOT / "assets/render/base-pack"))
    args = parser.parse_args()
    paths = [line.strip() for line in pathlib.Path(args.list).read_text().splitlines() if line.strip() and not line.startswith("#")]
    with ThreadPoolExecutor(8) as pool:
        bodies = list(pool.map(lambda path: fetch(args.origin, path), paths))
    files, blob, missing = {}, bytearray(), []
    for path, body in zip(paths, bodies):
        if body is None:
            missing.append(path)
            continue
        files[path] = [len(blob), len(body)]
        blob += body
    out = pathlib.Path(args.out)
    out.with_suffix(".bin").write_bytes(bytes(blob))
    out.with_suffix(".json").write_text(json.dumps({"files": files}, separators=(",", ":")))
    print(f"base pack: {len(files)} files, {len(blob)} bytes, {len(missing)} missing")
    for path in missing:
        print(f"  missing {path}")


if __name__ == "__main__":
    main()
