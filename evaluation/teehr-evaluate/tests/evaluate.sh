#!/usr/bin/env bash
# teehr-evaluate in containers, on a teehr-timeseries made from ngiab-run's test folder (one gage, USGS 01031510,
# January 2020). That January the gage has only ice-affected estimates at :15 past the hour (62 values) and
# TEEHR keeps values on the hour, so the cases that need metrics shift the series to June 2020 (or 2024).
#
# Offline: every input it can't evaluate is refused with its reason before any download; an input with no gage
# gives an empty evaluation; Spark starts from the image's jars as a uid the image doesn't name.
# Online (USGS, NOAA's public bucket): the metrics from a local folder, with the NWM 3.0 retrospective
# baseline, and read in place from S3 (a RustFS container, keys in a credentials file and the step's endpoint
# set, as uid 4321) with the baseline; two gages, one USGS doesn't know, outside the baseline's period; and
# the real January 2020, which has no hourly observations.
#
#   evaluation/teehr-evaluate/tests/evaluate.sh      (from the repository root; needs Docker and the internet)
#
# Images: hydrowf/teehr-evaluate:0.1.1 (built from this folder), hydrowf/ngiab-to-cng:0.4.1, and RustFS.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TEST_RUN=$ROOT/nextgen/ngiab-run/tests/ngen-run
EVAL=${EVAL:-hydrowf/teehr-evaluate:0.1.1}
TO_CNG=${TO_CNG:-hydrowf/ngiab-to-cng:0.4.1}
RUSTFS=docker.io/rustfs/rustfs:1.0.5@sha256:b81d16a90ee25bd9511280127ca1471788c6e874cf0f0da759645f46b2dc1d74
ME="$(id -u):$(id -g)"
NET=teehr-evaluate-test-$$

W=$(mktemp -d)
cleanup() {
  docker rm -f "$NET-s3" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
py() {                                  # <python> [args]: run in the tool image, with $W at /w
  docker run --rm --network none -v "$W:/w" --user "$ME" --entrypoint python "$EVAL" -I -c "$@"
}
evaluate() {                            # <network> <input under /w or s3://...> <output name> [more args]
  local net=$1 in=$2 name=$3; shift 3
  docker run --rm --network "$net" -v "$W:/w" --user "$ME" "$EVAL" "$in" --output "/w/$name" --run-id test "$@" \
    >"$W/$name.log" 2>&1 || { tail -15 "$W/$name.log" >&2; return 1; }
}
refuses() {                             # <reason it must give> <input under /w> [more args]
  local reason=$1 in=$2; shift 2
  if docker run --rm --network none -v "$W:/w" --user "$ME" "$EVAL" "$in" --output /w/refused "$@" \
       >/dev/null 2>"$W/err"; then fail "teehr-evaluate accepted: $reason"; fi
  grep -qF -- "$reason" "$W/err" || fail "refused for another reason than '$reason': $(tail -1 "$W/err")"
  [ ! -e "$W/refused" ] || fail "wrote output before refusing: $reason"
  echo "   refused: $(tail -1 "$W/err")"
}

echo "== the input: ngiab-to-cng --format teehr-timeseries"
docker run --rm --network none --user "$ME" -v "$TEST_RUN:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" \
  /in/ngen-run --output /out/ts --run-id test --configuration-name ngiab_test --format teehr-timeseries >/dev/null
docker run --rm --network none --user "$ME" -v "$TEST_RUN:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" \
  /in/ngen-run --output /out/cng --run-id test >/dev/null

# June 2020: the same values, 152 days later (the metrics are meaningless; the pairing, joins and I/O are real)
cp -r "$W/ts" "$W/june"
py 'import pandas as pd, pyarrow as pa, pyarrow.parquet as pq; p = "/w/june/timeseries/secondary.parquet"
t = pq.read_table(p); df = t.to_pandas(); df["value_time"] += pd.Timedelta(days=152)
pq.write_table(pa.Table.from_pandas(df, schema=t.schema, preserve_index=False), p)'

echo "== refused, offline, before any download"
refuses "(unknown: 'knee')" /w/ts --metrics kge,knee
refuses "(unknown: '')" /w/ts --metrics kge,
docker run --rm --network none --entrypoint python "$EVAL" -I -c '
import sys; sys.path.insert(0, "/app"); import teehr_evaluate as t
assert t.parse_metrics("kge,nse,kge,rmsdr,nse") == ["kge", "nse", "rmsdr"]      # repeats dropped, order kept
assert t.parse_metrics(" kge , nse ") == ["kge", "nse"]                          # spaces around names
print("   kge,nse,kge,rmsdr,nse -> kge, nse, rmsdr; \" kge , nse \" -> kge, nse")' 2>&1 | grep -v WARN || fail "repeated metrics"
refuses "invalid choice: 'nwm21'" /w/ts --baseline nwm21
refuses "format 'ngen-cng', not teehr-timeseries" /w/cng
edit() {                                # <copy name> <python editing the manifest dict m>
  cp -r "$W/ts" "$W/$1"
  py "import json; p = '/w/$1/manifest.json'; m = json.load(open(p)); $2; json.dump(m, open(p, 'w'))"
}
edit oldschema 'm["teehr"]["schema"] = "teehr.secondary_timeseries@0.6.2"'
refuses "this tool reads teehr.secondary_timeseries@0.8." /w/oldschema
edit daily 'm["teehr"]["variable_name"] = "streamflow_daily_mean"'
refuses "this tool evaluates streamflow_hourly_inst in m^3/s" /w/daily
cp -r "$W/ts" "$W/noxwalk"; rm "$W/noxwalk/crosswalk.parquet"
refuses "no crosswalk.parquet" /w/noxwalk
cp -r "$W/ts" "$W/badgage"
py 'import pyarrow as pa, pyarrow.parquet as pq; p = "/w/badgage/crosswalk.parquet"; t = pq.read_table(p)
pq.write_table(t.set_column(t.schema.get_field_index("primary_location_id"), "primary_location_id",
                            pa.array(["01031510"])), p)'
refuses "must be usgs-<site number>" /w/badgage
cp -r "$W/ts" "$W/nullgage"
py 'import pyarrow as pa, pyarrow.parquet as pq; p = "/w/nullgage/crosswalk.parquet"; t = pq.read_table(p)
pq.write_table(t.set_column(t.schema.get_field_index("primary_location_id"), "primary_location_id",
                            pa.array([None], pa.string())), p)'
refuses "must be usgs-<site number>" /w/nullgage
cp -r "$W/ts" "$W/nosec"; rm "$W/nosec/timeseries/secondary.parquet"
refuses "no timeseries/secondary.parquet" /w/nosec
cp -r "$W/ts" "$W/twoseries"
py 'import pyarrow as pa, pyarrow.parquet as pq; p = "/w/twoseries/crosswalk.parquet"; t = pq.read_table(p)
t = t.select(["primary_location_id", "secondary_location_id"])
extra = pa.Table.from_pylist([{"primary_location_id": "usgs-01031510", "secondary_location_id": "ngen-2654"}], schema=t.schema)
pq.write_table(pa.concat_tables([t, extra]), p)'
refuses "gives these gages several series: usgs-01031510" /w/twoseries
cp -r "$W/ts" "$W/oddrows"
py 'import pyarrow as pa, pyarrow.parquet as pq; p = "/w/oddrows/timeseries/secondary.parquet"; t = pq.read_table(p)
i = t.schema.get_field_index("unit_name"); pq.write_table(t.set_column(i, "unit_name", pa.array(["ft^3/s"] * t.num_rows)), p)'
refuses "rows aren't streamflow_hourly_inst in m^3/s" /w/oddrows
edit otherconfig 'm["teehr"]["configuration_name"] = "another_run"'
refuses "not only the manifest's 'another_run'" /w/otherconfig
edit reserved 'm["teehr"]["configuration_name"] = "usgs_observations"'
refuses "other than usgs_observations, nwm30_retrospective" /w/reserved

echo "== offline: no gaged series, an empty evaluation and the reason, without any download"
cp -r "$TEST_RUN" "$W/nogage_run"
docker run --rm --network none --user "$ME" -v "$W:/w" --entrypoint python "$TO_CNG" -I -c '
import sqlite3; c = sqlite3.connect("/w/nogage_run/config/ngen-run_subset.gpkg")
c.execute("update \"flowpath-attributes\" set gage = NULL"); c.commit()'
docker run --rm --network none --user "$ME" -v "$W/nogage_run:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" \
  /in/ngen-run --output /out/nogage_ts --configuration-name ngiab_test --format teehr-timeseries >/dev/null
evaluate none /w/nogage_ts nogage_out || fail "teehr-evaluate on an input with no gage"
py 'import json, geopandas as gpd, pandas as pd; m = json.load(open("/w/nogage_out/manifest.json"))
assert pd.read_parquet("/w/nogage_out/metrics.parquet").empty and gpd.read_parquet("/w/nogage_out/locations.parquet").empty
assert m["not_evaluated"] and "bbox" not in m and "start_datetime" not in m, m
print("  ", m["not_evaluated"])' || fail "no gage"

echo "== offline: Spark starts from the image's jars, as a uid the image doesn't name"
docker run --rm --network none --user 4321:4321 --entrypoint /app/entrypoint.sh "$EVAL" python -I -c '
import logging, os; logging.disable(logging.WARNING)
from teehr import Evaluation; ev = Evaluation(dir_path="/tmp/ev", create_dir=True)
print(f"   uid {os.getuid()}: {len(ev.list_tables())} tables, offline")' 2>/dev/null | grep -o "uid 4321: .*" \
  | sed "s/^/   /" | grep . || fail "Spark didn't start offline as uid 4321"

check() {                               # <output name> <configurations expected, comma-separated>
  py '
import json, math, sys
import geopandas as gpd, pandas as pd
out, configs = sys.argv[1], sys.argv[2].split(",")
m = pd.read_parquet(f"/w/{out}/metrics.parquet")
assert sorted(m.configuration_name) == sorted(configs), m.configuration_name.tolist()
assert set(m.primary_location_id) == {"usgs-01031510"}, m
values = m.drop(columns=["primary_location_id", "configuration_name"])
assert values.shape[1] == 4 and values.map(math.isfinite).all().all(), values
loc = gpd.read_parquet(f"/w/{out}/locations.parquet")
assert loc.id.tolist() == ["usgs-01031510"] and loc.crs.to_epsg() == 4326, loc
x, y = loc.geometry.iloc[0].x, loc.geometry.iloc[0].y
assert abs(x + 69.236) < 0.01 and abs(y - 45.150) < 0.01, (x, y)
man = json.load(open(f"/w/{out}/manifest.json"))
assert man["tool"] == {"name": "teehr-evaluate", "version": "0.1.1"} and man["manifest_version"] == "0.2", man
assert (man["start_datetime"], man["end_datetime"]) == ("2020-06-01T01:00:00+00:00", "2020-07-01T00:00:00+00:00")
assert len(man["bbox"]) == 4 and man["left_out"] == [], man
assert man["teehr"]["metrics"] == ["kge", "nse", "relative_bias", "rmsdr"], man["teehr"]
print("  ", "; ".join(f"{r.configuration_name}: " + ", ".join(f"{c}={r[c]:.3f}" for c in values.columns)
                     for _, r in m.iterrows()))
' "$1" "$2"
}

echo "== online: against USGS, from a local folder"
evaluate bridge /w/june local || fail "teehr-evaluate on a local folder"
check local ngiab_test || fail "local"

echo "== online: with the NWM 3.0 retrospective baseline"
evaluate bridge /w/june baseline --baseline nwm30_retrospective || fail "with the baseline"
check baseline ngiab_test,nwm30_retrospective || fail "baseline"
py 'import json; b = json.load(open("/w/baseline/manifest.json"))["teehr"]["baseline"]
assert b["reaches"] == {"usgs-01031510": "nwm30-1722933"}, b; print("   reach", b["reaches"])' || fail "baseline reach"

echo "== online: read in place from S3, keys in a credentials file, as uid 4321, with the NWM baseline"
docker network create "$NET" >/dev/null
docker run -d --name "$NET-s3" --network "$NET" -e RUSTFS_ACCESS_KEY=testkey -e RUSTFS_SECRET_KEY=testsecret123 \
  --entrypoint sh "$RUSTFS" -c 'mkdir -p /data/bucket && exec rustfs /data' >/dev/null
mkdir -p "$W/aws"
printf '[default]\naws_access_key_id = testkey\naws_secret_access_key = testsecret123\n' > "$W/aws/credentials"
chmod a+rx "$W" "$W/aws"; chmod a+r "$W/aws/credentials"     # test-only keys, read by uid 4321 below
s3env=(-e AWS_SHARED_CREDENTIALS_FILE=/w/aws/credentials -e AWS_PROFILE=default -e AWS_CONFIG_FILE=/w/aws/config
       -e "AWS_ENDPOINT_URL=http://$NET-s3:9000" -e AWS_REGION=us-east-1 -e AWS_DEFAULT_REGION=us-east-1)
for try in $(seq 30); do              # RustFS takes a moment; the upload is also the check that it serves
  docker run --rm --network "$NET" -v "$W:/w" --user "$ME" "${s3env[@]}" --entrypoint python "$EVAL" -I -c '
import s3fs; fs = s3fs.S3FileSystem(); fs.put("/w/june", "bucket/job/ts", recursive=True)' >/dev/null 2>&1 && break
  [ "$try" -lt 30 ] || fail "couldn't upload to RustFS"
  sleep 1
done
# as a uid the image doesn't name (a pod's securityContext may set one): entrypoint.sh names it for Hadoop
mkdir -m 0777 "$W/s3"
# the endpoint is the step's S3 (as hydrowf-core's Reader sets it); NOAA's bucket must still be read from AWS
docker run --rm --network "$NET" -v "$W:/w" --user 4321:4321 "${s3env[@]}" "$EVAL" s3://bucket/job/ts --output /w/s3 \
  --run-id test --baseline nwm30_retrospective >"$W/s3.log" 2>&1 \
  || { tail -15 "$W/s3.log" >&2; fail "teehr-evaluate from S3, as uid 4321, with the baseline"; }
check s3 ngiab_test,nwm30_retrospective || fail "from S3"
py 'import json, pandas as pd; a, b = (pd.read_parquet(f"/w/{o}/metrics.parquet") for o in ("baseline", "s3"))
assert a.equals(b), (a, b)
inputs = json.load(open("/w/s3/manifest.json"))["inputs"]
assert [i["path"] for i in inputs] == ["manifest.json", "timeseries/secondary.parquet", "crosswalk.parquet"], inputs
print("   the same metrics as from the local folder; the inputs'"'"' sha256 recorded")' || fail "S3 vs local"

echo "== online: a gage the USGS site service doesn't know is left out, and said"
cp -r "$W/june" "$W/unknown"
py 'import pyarrow as pa, pyarrow.parquet as pq; p = "/w/unknown/crosswalk.parquet"; t = pq.read_table(p)
pq.write_table(t.set_column(t.schema.get_field_index("primary_location_id"), "primary_location_id",
                            pa.array(["usgs-99999999"])), p)'
evaluate bridge /w/unknown unknown_out || fail "teehr-evaluate with an unknown gage"
py 'import json, pandas as pd; m = json.load(open("/w/unknown_out/manifest.json"))
assert pd.read_parquet("/w/unknown_out/metrics.parquet").empty and m["not_evaluated"], m
assert m["left_out"] == [{"gage": "usgs-99999999", "reason": "the USGS site service doesn'"'"'t know this site"}], m
print("   no metrics;", m["left_out"][0]["reason"])' || fail "unknown gage"

echo "== online: two gages in June 2024, one USGS doesn't know, with the baseline outside its period"
cp -r "$W/ts" "$W/two"
py '
import pandas as pd, pyarrow as pa, pyarrow.parquet as pq
p = "/w/two/timeseries/secondary.parquet"; t = pq.read_table(p); df = t.to_pandas()
df["value_time"] += pd.Timestamp("2024-06-01 01:00") - pd.Timestamp("2020-01-01 01:00")
df = pd.concat([df, df.assign(location_id="ngen-9999")], ignore_index=True)
pq.write_table(pa.Table.from_pandas(df, schema=t.schema, preserve_index=False), p)
p = "/w/two/crosswalk.parquet"; t = pq.read_table(p)
extra = pa.Table.from_pylist([{"primary_location_id": "usgs-99999999", "secondary_location_id": "ngen-9999"}],
                             schema=t.select(["primary_location_id", "secondary_location_id"]).schema)
pq.write_table(pa.concat_tables([t, extra], promote_options="default"), p)'
evaluate bridge /w/two two_out --baseline nwm30_retrospective || fail "teehr-evaluate on two gages"
py '
import json, pandas as pd
m, man = pd.read_parquet("/w/two_out/metrics.parquet"), json.load(open("/w/two_out/manifest.json"))
assert m[["primary_location_id", "configuration_name"]].values.tolist() == [["usgs-01031510", "ngiab_test"]], m
assert man["left_out"] == [{"gage": "usgs-99999999", "reason": "the USGS site service doesn'"'"'t know this site"}], man
assert "outside the NWM 3.0 retrospective" in man["teehr"]["baseline"]["skipped"], man["teehr"]["baseline"]
print("   usgs-01031510 evaluated; usgs-99999999 left out; baseline:", man["teehr"]["baseline"]["skipped"])' \
  || fail "two gages"

echo "== online: the real January 2020, without hourly observations: left out, and said"
evaluate bridge /w/ts january || fail "teehr-evaluate on January 2020"
py 'import json, pandas as pd; m = json.load(open("/w/january/manifest.json"))
assert pd.read_parquet("/w/january/metrics.parquet").empty, "metrics without observations"
assert m["left_out"] == [{"gage": "usgs-01031510", "reason": "USGS has no hourly observations in the period"}], m
print("  ", m["left_out"][0]["reason"])' || fail "January 2020"

echo "PASS: teehr-evaluate"
