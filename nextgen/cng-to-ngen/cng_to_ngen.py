#!/usr/bin/env python3
"""Turn an ngiab-to-cng output back into an NGIAB run folder that ngiab-run can run again.

ngiab-to-cng (0.3.0 and later) copies what a rerun needs into <cng>/run/ byte for byte and lists each
file with its SHA-256 in manifest.json (`rerun`). This copies those files to --output, checks every hash,
and creates the empty outputs/ folders ngen and t-route write to. Nothing is converted, so the rerun reads
exactly what the first run read.

Output layout (under --output):
  config/**            realization.json, troute.yaml, the gpkg, cat_config/
  forcings/forcings.nc
  partitions_*.json
  outputs/ngen/, outputs/troute/   empty
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

TOOL_VERSION = "0.1.0"
SAFE_PATH = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*")   # relative, no empty part


def load_manifest(cng: Path) -> dict:
    try:
        manifest = json.loads((cng / "manifest.json").read_text())
    except (OSError, ValueError) as err:
        raise SystemExit(f"manifest.json can't be read: {err}") from None
    if not isinstance(manifest, dict):
        raise SystemExit("manifest.json is not an object")
    return manifest


def rerun_files(manifest: dict) -> tuple[str, list[dict]]:
    """The manifest's `rerun` folder and files, checked: the paths decide where files are written, so each
    must be a plain relative path with no `.` or `..` part, listed once, never a parent of another
    path, and never under outputs/ (which the rerun writes)."""
    rerun = manifest.get("rerun")
    if not isinstance(rerun, dict) or not isinstance(rerun.get("files"), list):
        tool = manifest.get("tool") if isinstance(manifest.get("tool"), dict) else {}
        raise SystemExit(f"manifest.json has no `rerun`: ngiab-to-cng 0.3.0 or later keeps what a rerun needs "
                         f"(this one: {tool.get('version')!r}; see not_converted for why a run wasn't kept)")
    folder, files = rerun.get("dir"), rerun["files"]
    for path in [folder] + [f.get("path") if isinstance(f, dict) else None for f in files]:
        if not isinstance(path, str) or not SAFE_PATH.fullmatch(path) or \
                any(part in (".", "..") for part in path.split("/")):
            raise SystemExit(f"manifest.json: {path!r} is not a plain relative path")
    paths = [f["path"] for f in files]
    if len(set(paths)) != len(paths):
        raise SystemExit("manifest.json: a rerun path is listed twice")
    # every folder some path sits in, once: a path that is one of them would be a file and a folder
    folders = {"/".join(parts[:i]) for parts in (p.split("/") for p in paths) for i in range(1, len(parts))}
    for path in paths:
        if path in folders or path.split("/")[0] == "outputs":
            raise SystemExit(f"manifest.json: {path!r} would be a folder of another file, or under outputs/")
    for f in files:
        if not isinstance(f.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", f["sha256"]):
            raise SystemExit(f"manifest.json: {f['path']!r} has no sha256")
    if not any(re.fullmatch(r"config/[^/]*realization[^/]*\.json", p) for p in paths):
        raise SystemExit("manifest.json: `rerun` has no config/*realization*.json")
    return folder, files


def copy_checked(source: Path, target: Path, expected: str, label: str) -> None:
    """Copy `source` to `target`, hashing as it goes (one read); SystemExit when the hash isn't `expected`."""
    h = hashlib.sha256()
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src, target.open("xb") as dst:
        for block in iter(lambda: src.read(1 << 20), b""):
            h.update(block)
            dst.write(block)
    if h.hexdigest() != expected:
        raise SystemExit(f"{label} doesn't match its sha256 in manifest.json")


def rebuild(cng: Path, out: Path) -> list[str]:
    folder, files = rerun_files(load_manifest(cng))
    if (cng / folder).is_symlink() or not (cng / folder).is_dir():
        raise SystemExit(f"{folder}/ is missing or a symlink")
    base = (cng / folder).resolve()
    copied = []
    for f in files:
        source = cng / folder / f["path"]
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(base):
            raise SystemExit(f"{folder}/{f['path']} is missing, a symlink, or outside {folder}/")
        copy_checked(source, out / f["path"], f["sha256"], f"{folder}/{f['path']}")
        copied.append(f["path"])
    for name in ("outputs/ngen", "outputs/troute"):
        (out / name).mkdir(parents=True, exist_ok=True)
    return copied


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cng", type=Path, help="ngiab-to-cng output folder (manifest.json, run/)")
    p.add_argument("--output", type=Path, required=True, help="the run folder to write (new or empty)")
    args = p.parse_args()
    out = args.output
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise SystemExit(f"{out} is not a new or empty folder")
    out.mkdir(parents=True, exist_ok=True)
    try:
        copied = rebuild(args.cng, out)
    except BaseException:
        shutil.rmtree(out, ignore_errors=True)      # never leave half a run folder for the runtime to collect
        raise
    print(json.dumps({"tool": f"cng-to-ngen@{TOOL_VERSION}", "files": len(copied)}))


if __name__ == "__main__":
    main()
