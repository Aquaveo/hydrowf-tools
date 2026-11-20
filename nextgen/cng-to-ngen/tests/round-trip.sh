#!/usr/bin/env bash
# Proves the NGIAB round trip in containers: ngiab-run's test folder -> ngiab-to-cng -> cng-to-ngen gives
# back the files a rerun reads, byte for byte, and ngiab-run on the rebuilt folder gives the same t-route
# flow as ngiab-run on the original. Also checks that cng-to-ngen refuses a tampered or unsafe output.
#
#   nextgen/cng-to-ngen/tests/round-trip.sh        (from the repository root; needs Docker and python3)
#
# Images: hydrowf/ngiab-to-cng:0.3.0 and hydrowf/cng-to-ngen:0.1.0 (built locally from their folders),
# and the ngen image ngiab-run pins. Each model run takes a few minutes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TEST_RUN=$ROOT/nextgen/ngiab-run/tests/ngen-run
TO_CNG=${TO_CNG:-hydrowf/ngiab-to-cng:0.3.0}
TO_NGEN=${TO_NGEN:-hydrowf/cng-to-ngen:0.1.0}
NGEN=awiciroh/ciroh-ngen-image@sha256:d5ee1a6c15c025f9be2f9ce140dd9cdc2e933bc30f531a41f180d45b15c8ab17
CORES=${CORES:-4}                       # the test folder's partitions_4.json
ME="$(id -u):$(id -g)"

W=$(mktemp -d)
cleanup() {                             # the ngen image runs as root: hand the files back before removing
  docker run --rm -v "$W:/w" --entrypoint chown "$TO_NGEN" -R "$ME" /w >/dev/null 2>&1 || true
  rm -rf "$W" 2>/dev/null || echo "warning: some files in $W are left (root-owned?)" >&2
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

ngiab_run() {                           # <run folder>: ngen + t-route, as the ngiab-run tool runs them
  docker run --rm -v "$1:/ngen/ngen/data" "$NGEN" /ngen/ngen/data auto "$CORES" local >"$1.log" 2>&1 \
    || { tail -20 "$1.log" >&2; fail "ngiab-run on $(basename "$1")"; }
}

echo "== the original, with its outputs cleared, run again as the baseline"
cp -r "$TEST_RUN" "$W/baseline"
rm -rf "$W/baseline/outputs/ngen"/* "$W/baseline/outputs/troute"/*

echo "== ngiab-to-cng"
mkdir "$W/cng"
docker run --rm --user "$ME" -v "$TEST_RUN:/in/ngen-run:ro" -v "$W/cng:/out" "$TO_CNG" \
  /in/ngen-run --output /out/ngen-run_cng --run-id round-trip
CNG=$W/cng/ngen-run_cng

echo "== cng-to-ngen"
docker run --rm --user "$ME" -v "$CNG:/in/cng:ro" -v "$W:/out" "$TO_NGEN" /in/cng --output /out/rebuilt

echo "== every file a rerun reads is back, byte for byte"
n=0
while IFS= read -r rel; do
  cmp -s "$TEST_RUN/$rel" "$W/rebuilt/$rel" || fail "$rel differs from the original"
  n=$((n + 1))
done < <(python3 -c 'import json,sys; [print(f["path"]) for f in json.load(open(sys.argv[1]))["rerun"]["files"]]' \
           "$CNG/manifest.json")
[ "$n" -gt 0 ] || fail "the manifest lists no rerun files"
echo "   $n files identical"

echo "== cng-to-ngen refuses a tampered or unsafe output, with the reason"
refuses() {                             # <reason it must give> <python that edits sys.argv[1], the cng copy>
  rm -rf "$W/bad" "$W/bad-out"; cp -r "$CNG" "$W/bad"
  python3 -c "$2" "$W/bad"
  if docker run --rm --user "$ME" -v "$W/bad:/in/cng:ro" -v "$W:/out" "$TO_NGEN" /in/cng --output /out/bad-out \
       >/dev/null 2>"$W/err"; then fail "cng-to-ngen accepted: $1"; fi
  grep -qF -- "$1" "$W/err" || fail "cng-to-ngen refused for another reason than '$1': $(tail -1 "$W/err")"
  [ ! -e "$W/bad-out" ] || fail "cng-to-ngen left a partial run folder after: $1"
  echo "   refused: $(tail -1 "$W/err")"
}
EDIT='import json, sys; p = sys.argv[1] + "/manifest.json"; m = json.load(open(p))'
SAVE='json.dump(m, open(p, "w"))'
refuses "doesn't match its sha256" 'import sys; open(sys.argv[1] + "/run/config/realization.json", "a").write(" ")'
refuses "is not a plain relative path" "$EDIT; m['rerun']['files'][0]['path'] = '../../etc/passwd'; $SAVE"
refuses "is not a plain relative path" "$EDIT; m['rerun']['dir'] = '..'; $SAVE"
refuses "has no \`rerun\`" "$EDIT; del m['rerun']; $SAVE"
refuses "would be a folder of another file" "$EDIT; m['rerun']['files'].append(dict(m['rerun']['files'][0], path='config')); $SAVE"
refuses "is missing, a symlink, or outside" '
import os, sys; f = sys.argv[1] + "/run/config/realization.json"; os.remove(f); os.symlink("/etc/hostname", f)'
refuses "can't be read" 'import sys; open(sys.argv[1] + "/manifest.json", "w").write("{not json")'
refuses "run/ is missing or a symlink" '
import os, shutil, sys; c = sys.argv[1]; shutil.move(c + "/run", c + "/real"); os.symlink("real", c + "/run")'

echo "== ngiab-to-cng refuses a symlinked folder, and keeps no rerun cng-to-ngen would refuse"
cp -r "$TEST_RUN" "$W/linked"; rm -rf "$W/linked/config/cat_config"; ln -s /etc "$W/linked/config/cat_config"
if docker run --rm --user "$ME" -v "$W/linked:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" /in/ngen-run --output /out/linked_cng \
     >/dev/null 2>"$W/err"; then fail "ngiab-to-cng copied through a symlinked folder"; fi
grep -qF "is a symlink" "$W/err" || fail "ngiab-to-cng refused for another reason: $(tail -1 "$W/err")"
[ ! -e "$W/linked_cng" ] || fail "ngiab-to-cng wrote output before refusing the symlink"
echo "   refused: $(tail -1 "$W/err")"
cp -r "$TEST_RUN" "$W/oddname"; cp "$W/oddname/config/troute.yaml" "$W/oddname/config/troute copy.yaml"
docker run --rm --user "$ME" -v "$W/oddname:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" /in/ngen-run \
  --output /out/oddname_cng >/dev/null || fail "ngiab-to-cng failed on a run it can convert but not keep"
python3 -c '
import json, sys; m = json.load(open(sys.argv[1]))
assert "rerun" not in m, "kept a rerun cng-to-ngen would refuse"
reason = [n["reason"] for n in m["not_converted"] if n["path"] == "run"]
assert reason and "troute copy.yaml" in reason[0], m["not_converted"]
print("   converted, no rerun kept:", reason[0])' "$W/oddname_cng/manifest.json" || fail "odd file name case"

echo "== cng-to-ngen checks a large manifest in well under a second (one cat_config file per catchment)"
docker run --rm --entrypoint python "$TO_NGEN" -c '
import sys, time; sys.path.insert(0, "/app"); import cng_to_ngen as t
files = [{"path": f"config/cat_config/CFE/cat-{n}.txt", "sha256": "0" * 64} for n in range(30000)]
files += [{"path": "config/realization.json", "sha256": "0" * 64}]
start = time.perf_counter(); t.rerun_files({"rerun": {"dir": "run", "files": files}})
took = time.perf_counter() - start
print(f"   {len(files)} paths checked in {took:.3f} s"); sys.exit(0 if took < 1 else "FAIL: too slow")' \
  || fail "the path checks are too slow"

echo "== ngiab-to-cng refuses a FIFO before converting anything"
cp -r "$TEST_RUN" "$W/fifo"; mkfifo "$W/fifo/config/pipe"
if docker run --rm --user "$ME" -v "$W/fifo:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" /in/ngen-run --output /out/fifo_cng \
     >/dev/null 2>"$W/err"; then fail "ngiab-to-cng accepted a FIFO"; fi
grep -qF "config/pipe is not a regular file" "$W/err" || fail "refused for another reason: $(tail -1 "$W/err")"
[ ! -e "$W/fifo_cng" ] || fail "ngiab-to-cng wrote output before refusing"
echo "   refused before any output: $(tail -1 "$W/err")"
rm "$W/fifo/config/pipe"

echo "== ngiab-run on the baseline and on the rebuilt folder"
ngiab_run "$W/baseline"
ngiab_run "$W/rebuilt"

echo "== t-route's flow is the same"
docker run --rm -v "$W:/w:ro" --entrypoint python "$TO_CNG" -c '
import glob, os, sys
import numpy as np, xarray as xr
names = {side: sorted(os.path.basename(f) for f in glob.glob(f"/w/{side}/outputs/troute/*.nc"))
         for side in ("baseline", "rebuilt")}
if not names["baseline"] or names["baseline"] != names["rebuilt"]:
    sys.exit(f"FAIL: t-route wrote different files: {names}")
worst, cells, identical = 0.0, 0, True
for name in names["baseline"]:
    a, b = (xr.open_dataset(f"/w/{side}/outputs/troute/{name}")["flow"].load() for side in ("baseline", "rebuilt"))
    if a.shape != b.shape or not (a["feature_id"].values == b["feature_id"].values).all():
        sys.exit(f"FAIL: {name}: different shapes {a.shape} {b.shape}")
    identical &= bool(np.array_equal(a.values, b.values, equal_nan=True))
    worst = max(worst, float(np.nanmax(np.abs(a.values - b.values))) if a.size else 0.0)
    cells += a.size
files = len(names["baseline"])
print(f"   flow in {files} file(s), {cells} values: identical={identical}, max |difference|={worst:g}")
# the same image on byte-identical inputs: any difference means the rerun read something else
sys.exit(0 if identical else "FAIL: t-route flow differs")
'
echo "PASS: round trip"
