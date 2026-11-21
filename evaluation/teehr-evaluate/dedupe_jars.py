#!/usr/bin/env python3
"""Replace each jar Ivy retrieved into <ivy>/jars/ with a hardlink to the identical file in <ivy>/cache/.

    dedupe_jars.py <ivy dir>

Run at image build (see Dockerfile). A jar with no identical cached file is left as it is.
"""
import filecmp
import os
import sys
from pathlib import Path

ivy = Path(sys.argv[1])
by_size: dict[int, list[Path]] = {}
for cached in (ivy / "cache").rglob("*.jar"):
    by_size.setdefault(cached.stat().st_size, []).append(cached)
linked = 0
for jar in sorted((ivy / "jars").glob("*.jar")):
    same = next((c for c in by_size.get(jar.stat().st_size, []) if filecmp.cmp(c, jar, shallow=False)), None)
    if same is not None:
        tmp = jar.with_suffix(".link")
        os.link(same, tmp)          # the cached file's own time: Ivy copies only a newer source, so it never does
        tmp.replace(jar)
        linked += 1
print(f"dedupe_jars: {linked} of {len(list((ivy / 'jars').glob('*.jar')))} jars in {ivy / 'jars'} are hardlinks now")
