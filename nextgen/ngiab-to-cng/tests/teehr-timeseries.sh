#!/usr/bin/env bash
# ngiab-to-cng --format teehr-timeseries, in containers, on ngiab-run's test folder: the files and their
# contents match t-route's flow and the hydrofabric's gages, teehr 0.8.0 itself loads them, the default
# format is still ngen-cng, and each input it can't convert is refused (or written empty) with its reason.
#
#   nextgen/ngiab-to-cng/tests/teehr-timeseries.sh      (from the repository root; needs Docker)
#
# Images: hydrowf/ngiab-to-cng:0.4.0 (built from this folder) and an image with teehr 0.8.0 and its Spark
# jars (TEEHR, see the teehr-evaluate tool; any image where `from teehr import Evaluation` works offline).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TEST_RUN=$ROOT/nextgen/ngiab-run/tests/ngen-run      # one gaged flowpath: wb-2658, USGS 01031510
TO_CNG=${TO_CNG:-hydrowf/ngiab-to-cng:0.4.0}
TEEHR=${TEEHR:?set TEEHR to an image with teehr 0.8.0 (and its Spark jars) installed}
ME="$(id -u):$(id -g)"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
py() {                                  # <python> [args]: run in the tool image, with $W at /w
  docker run --rm --network none --user "$ME" -v "$W:/w" --entrypoint python "$TO_CNG" -I -c "$@"
}
to_teehr() {                            # <run folder under $W> <output name> [more args]
  local run=$1 name=$2; shift 2
  docker run --rm --network none --user "$ME" -v "$W/$run:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" \
    /in/ngen-run --output "/out/$name" --run-id test --configuration-name ngiab_test --format teehr-timeseries "$@"
}
refuses() {                             # <reason it must give> <run folder under $W>
  if to_teehr "$2" "$2_out" >/dev/null 2>"$W/err"; then fail "ngiab-to-cng accepted: $1"; fi
  grep -qF -- "$1" "$W/err" || fail "refused for another reason than '$1': $(tail -1 "$W/err")"
  echo "   refused: $(tail -1 "$W/err")"
}

cp -r "$TEST_RUN" "$W/run"

echo "== --format teehr-timeseries"
to_teehr run out >/dev/null
py '
import json, os
import numpy as np, pyarrow as pa, pyarrow.parquet as pq, xarray as xr
out = "/w/out"
files = sorted(os.path.relpath(os.path.join(d, f), out) for d, _, fs in os.walk(out) for f in fs)
assert files == ["crosswalk.parquet", "manifest.json", "timeseries/secondary.parquet"], files

m = json.load(open(f"{out}/manifest.json"))
assert m["tool"] == {"name": "ngiab-to-cng", "version": "0.4.0"} and m["manifest_version"] == "0.4", m["tool"]
assert m["format"] == "teehr-timeseries", m.get("format")
t = m["teehr"]
assert t["schema"].startswith("teehr.secondary_timeseries@0.8"), t
assert t["crosswalk_schema"].startswith("teehr.location_crosswalks@0.8"), t
assert (t["configuration_name"], t["variable_name"], t["unit_name"]) == \
    ("ngiab_test", "streamflow_hourly_inst", "m^3/s"), t
assert len(m["bbox"]) == 4 and m["bbox"][0] < m["bbox"][2] and m["bbox"][1] < m["bbox"][3], m["bbox"]
assert (m["start_datetime"], m["end_datetime"]) == ("2020-01-01T01:00:00+00:00", "2020-01-31T00:00:00+00:00"), m
assert "rerun" not in m and m["not_converted"] == [], m["not_converted"]

def teehr_schema(name):
    with pa.OSFile(f"/app/teehr_{name}.arrow") as f:
        return pa.ipc.read_schema(f).remove_metadata()
ts = pq.read_table(f"{out}/timeseries/secondary.parquet")
assert ts.schema.remove_metadata().equals(teehr_schema("secondary_timeseries")), ts.schema
df = ts.to_pandas()
assert set(df.location_id) == {"ngen-2658"} and set(df.variable_name) == {"streamflow_hourly_inst"}, df.head()
assert set(df.unit_name) == {"m^3/s"} and set(df.configuration_name) == {"ngiab_test"}, df.head()
flow = xr.open_dataset("/w/run/outputs/troute/troute_output_202001010000.nc")["flow"].sel(feature_id=2658)
assert len(df) == flow.sizes["time"] == 720, len(df)
assert (df.value_time.values == flow.time.values).all()
assert np.array_equal(df.value.to_numpy(), flow.values.astype("float32")), "values differ from t-route flow"

xw = pq.read_table(f"{out}/crosswalk.parquet")
assert xw.schema.remove_metadata().equals(teehr_schema("location_crosswalks")), xw.schema
xw = xw.select(["secondary_location_id", "primary_location_id"]).to_pylist()
assert xw == [{"secondary_location_id": "ngen-2658", "primary_location_id": "usgs-01031510"}], xw
print("   3 files; 720 values of ngen-2658 equal t-route flow at wb-2658; crosswalk to usgs-01031510")
' || fail "teehr-timeseries output"

echo "== teehr 0.8.0 loads it"
docker run --rm --network none -v "$W/out:/in:ro" "$TEEHR" python -I -c '
import logging; logging.disable(logging.WARNING)
import geopandas as gpd, pandas as pd
from shapely.geometry import Point
from teehr import Configuration, Evaluation
ev = Evaluation(dir_path="/tmp/ev", create_dir=True)
ev.locations.load_dataframe(gpd.GeoDataFrame(
    {"id": ["usgs-01031510"], "name": ["test gage"]}, geometry=[Point(-69.3, 45.2)], crs="EPSG:4326"))
ev.configurations.add(Configuration(name="ngiab_test", timeseries_type="secondary", description="test"))
ev.location_crosswalks.load_dataframe(pd.read_parquet("/in/crosswalk.parquet"))
sec = pd.read_parquet("/in/timeseries/secondary.parquet")
ev.secondary_timeseries.load_dataframe(sec)
ev.configurations.add(Configuration(name="usgs_test", timeseries_type="primary", description="test"))
obs = sec[["value_time", "value", "variable_name", "unit_name"]].assign(          # synthetic observations
    location_id="usgs-01031510", configuration_name="usgs_test", value=sec["value"] * 1.1)
ev.primary_timeseries.load_dataframe(obs)
joined = ev.joined_timeseries_view().to_pandas()
pairs = joined[(joined.primary_location_id == "usgs-01031510") & (joined.secondary_location_id == "ngen-2658")]
assert len(pairs) == 720, len(pairs)
print(f"   teehr loaded it and joins {len(pairs)} simulated values to usgs-01031510 through the crosswalk")
' >"$W/teehr.log" 2>&1 || { tail -20 "$W/teehr.log" >&2; fail "teehr refused the output"; }
grep -o "teehr loaded.*" "$W/teehr.log" | sed 's/^/   /'   # the rest is Spark's log and progress bar (and log4j's hostname lookup, offline)

echo "== the default format is still ngen-cng"
docker run --rm --network none --user "$ME" -v "$W/run:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" \
  /in/ngen-run --output /out/cng --run-id test >/dev/null
py '
import json, os
m = json.load(open("/w/cng/manifest.json"))
assert m["tool"]["version"] == "0.4.0" and m["format"] == "ngen-cng" and "rerun" in m, m["tool"]
assert os.path.exists("/w/cng/timeseries/troute.parquet") and not os.path.exists("/w/cng/crosswalk.parquet")
print("   ngen-cng, with rerun/ and timeseries/troute.parquet")
' || fail "default format"

echo "== a hydrofabric that lists several gages on a flowpath: the first"
cp -r "$TEST_RUN" "$W/several"
py 'import sqlite3; c = sqlite3.connect("/w/several/config/ngen-run_subset.gpkg")
c.execute("update \"flowpath-attributes\" set gage = '"'"'01031510,01031500'"'"' where id = '"'"'wb-2658'"'"'"); c.commit()'
to_teehr several several_out >/dev/null
py 'import pyarrow.parquet as pq; xw = pq.read_table("/w/several_out/crosswalk.parquet").to_pylist()
assert [r["primary_location_id"] for r in xw] == ["usgs-01031510"], xw; print("   usgs-01031510")' \
  || fail "several gages"

echo "== no gaged flowpath: empty files, and the reason"
cp -r "$TEST_RUN" "$W/nogage"
py 'import sqlite3; c = sqlite3.connect("/w/nogage/config/ngen-run_subset.gpkg")
c.execute("update \"flowpath-attributes\" set gage = NULL"); c.commit()'
to_teehr nogage nogage_out >/dev/null
py '
import json, pyarrow as pa, pyarrow.parquet as pq
m = json.load(open("/w/nogage_out/manifest.json"))
for path, name in (("timeseries/secondary.parquet", "secondary_timeseries"), ("crosswalk.parquet", "location_crosswalks")):
    table = pq.read_table(f"/w/nogage_out/{path}")
    with pa.OSFile(f"/app/teehr_{name}.arrow") as f:
        expected = pa.ipc.read_schema(f).remove_metadata()
    assert table.num_rows == 0 and table.schema.remove_metadata().equals(expected), (path, table.schema)
reasons = [n["reason"] for n in m["not_converted"]]
assert any("no flowpath with a gage" in r for r in reasons), reasons
print("   0 rows, in TEEHR'"'"'s schemas;", reasons[0])' || fail "no gage"

echo "== one gage on two flowpaths: the one flowing into the gage, and the other listed"
cp -r "$TEST_RUN" "$W/twice"
py 'import sqlite3; c = sqlite3.connect("/w/twice/config/ngen-run_subset.gpkg")
c.execute("update \"flowpath-attributes\" set gage = '"'"'01031510'"'"' where id = '"'"'wb-2654'"'"'"); c.commit()'
to_teehr twice twice_out >/dev/null
py '
import json, pyarrow.parquet as pq
xw = pq.read_table("/w/twice_out/crosswalk.parquet").select(["secondary_location_id"]).to_pylist()
assert xw == [{"secondary_location_id": "ngen-2658"}], xw
assert set(pq.read_table("/w/twice_out/timeseries/secondary.parquet").column("location_id").to_pylist()) == {"ngen-2658"}
notes = json.load(open("/w/twice_out/manifest.json"))["not_converted"]
assert [n["path"].rsplit(":", 1)[1] for n in notes] == ["wb-2654"], notes
print("   kept ngen-2658;", notes[0]["reason"])' || fail "one gage on two flowpaths"

echo "== a gaged flowpath whose flow is all missing: no crosswalk row for it"
cp -r "$TEST_RUN" "$W/nanflow"
py 'import numpy as np, xarray as xr; p = "/w/nanflow/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p); ds["flow"].loc[dict(feature_id=2658)] = np.nan; ds.to_netcdf(p)'
to_teehr nanflow nanflow_out >/dev/null
py 'import pyarrow.parquet as pq
assert pq.read_table("/w/nanflow_out/crosswalk.parquet").num_rows == 0
assert pq.read_table("/w/nanflow_out/timeseries/secondary.parquet").num_rows == 0
print("   0 crosswalk rows")' || fail "all-missing flow"

echo "== one missing hour is not a different time step"
cp -r "$TEST_RUN" "$W/onegap"
py 'import numpy as np, xarray as xr; p = "/w/onegap/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p); ds["flow"].loc[dict(feature_id=2658, time=ds.time[100])] = np.nan; ds.to_netcdf(p)'
to_teehr onegap onegap_out >/dev/null || fail "refused a run with one missing hour"
py 'import pyarrow.parquet as pq; n = pq.read_table("/w/onegap_out/timeseries/secondary.parquet").num_rows
assert n == 719, n; print("   719 values, no refusal")' || fail "one missing hour"

echo "== one gage on two flowpaths, the one flowing into it without flow: the other"
cp -r "$TEST_RUN" "$W/twicenan"
py 'import numpy as np, sqlite3, xarray as xr
c = sqlite3.connect("/w/twicenan/config/ngen-run_subset.gpkg")
c.execute("update \"flowpath-attributes\" set gage = '"'"'01031510'"'"' where id = '"'"'wb-2654'"'"'"); c.commit()
p = "/w/twicenan/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p); ds["flow"].loc[dict(feature_id=2658)] = np.nan; ds.to_netcdf(p)'
to_teehr twicenan twicenan_out >/dev/null
py 'import pyarrow.parquet as pq
xw = pq.read_table("/w/twicenan_out/crosswalk.parquet").select(["secondary_location_id", "primary_location_id"])
assert xw.to_pylist() == [{"secondary_location_id": "ngen-2654", "primary_location_id": "usgs-01031510"}], xw
print("   ngen-2654 -> usgs-01031510")' || fail "duplicate gage, kept one without flow"

echo "== a gaged id that is not wb-<n>: left out, not a traceback"
cp -r "$TEST_RUN" "$W/oddid"
py 'import sqlite3; c = sqlite3.connect("/w/oddid/config/ngen-run_subset.gpkg")
c.execute("update \"flowpath-attributes\" set id = '"'"'wb-x2658'"'"' where id = '"'"'wb-2658'"'"'"); c.commit()'
to_teehr oddid oddid_out >/dev/null || fail "failed on a gaged id that is not wb-<n>"
py 'import pyarrow.parquet as pq; assert pq.read_table("/w/oddid_out/crosswalk.parquet").num_rows == 0
print("   0 crosswalk rows")' || fail "odd id"

echo "== refused: t-route flow in a unit it does not know, or not hourly"
cp -r "$TEST_RUN" "$W/feet"
py 'import xarray as xr; p = "/w/feet/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p); ds["flow"].attrs["units"] = "ft3 s-1"; ds.to_netcdf(p)'
refuses "unit 'ft3 s-1'" feet
cp -r "$TEST_RUN" "$W/twohourly"
py 'import xarray as xr; p = "/w/twohourly/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p).isel(time=slice(0, None, 2)); ds.to_netcdf(p)'
refuses "not hourly" twohourly

echo "== refused: what teehr-timeseries is made from is missing"
cp -r "$TEST_RUN" "$W/noroute"; rm "$W/noroute/outputs/troute/"*.nc
refuses "no t-route output" noroute
cp -r "$TEST_RUN" "$W/noflow"
py 'import xarray as xr; p = "/w/noflow/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p).drop_vars("flow"); ds.to_netcdf(p)'
refuses "has no \`flow\` variable" noflow
cp -r "$TEST_RUN" "$W/nogagecol"
py 'import sqlite3; c = sqlite3.connect("/w/nogagecol/config/ngen-run_subset.gpkg")
c.execute("alter table \"flowpath-attributes\" drop column gage"); c.commit()'
refuses "has no id or gage column" nogagecol
cp -r "$TEST_RUN" "$W/nolayer"
py 'import sqlite3; c = sqlite3.connect("/w/nolayer/config/ngen-run_subset.gpkg")
c.execute("drop table \"flowpath-attributes\""); c.execute("delete from gpkg_contents where table_name = '"'"'flowpath-attributes'"'"'")
c.commit()'
refuses "has no flowpath-attributes layer" nolayer
cp -r "$TEST_RUN" "$W/transposed"
py 'import xarray as xr; p = "/w/transposed/outputs/troute/troute_output_202001010000.nc"
ds = xr.load_dataset(p); ds["flow"] = ds["flow"].transpose("time", "feature_id"); ds.to_netcdf(p)'
refuses "not (feature_id, time)" transposed

echo "== refused: a format it does not write"
if docker run --rm --network none --user "$ME" -v "$W/run:/in/ngen-run:ro" -v "$W:/out" "$TO_CNG" \
     /in/ngen-run --output /out/bad --format zarr >/dev/null 2>"$W/err"; then fail "accepted --format zarr"; fi
grep -qF "invalid choice: 'zarr'" "$W/err" || fail "refused --format zarr for another reason: $(tail -1 "$W/err")"
echo "   refused: $(tail -1 "$W/err")"

echo "PASS: teehr-timeseries"
