#!/usr/bin/env python3
"""Convert a finished NGIAB run folder into cloud-native files.

Output layout (under --output):
  manifest.json
  run/{config/**,forcings/forcings.nc,partitions_*.json}     what a rerun needs, copied as is (cng-to-ngen)
  timeseries/{catchment,nexus,troute,forcings}.parquet   TEEHR 0.8 secondary timeseries schema
  timeseries/{catchment,troute,forcings}.zarr            the same values as (location_id, time) arrays, Zarr v3
  hydrofabric/<layer>.parquet                            icefabric v2.2 schemas, WKB + GeoParquet metadata
  gridded/forcings.zarr                                  forcings/raw_gridded_data.nc as Zarr v3
  gridded/cog/<variable>_<mean|total>.tif                one-band COGs: each variable's mean over the run,
                                                         and the precipitation total (mm)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

import geopandas as gpd
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
import pyogrio
import rioxarray  # noqa: F401  (registers the .rio accessor)
import xarray as xr
from pyproj import CRS, Transformer
from zarr.codecs import ZstdCodec

import icefabric_hydrofabric as hf

TOOL_VERSION = "0.3.0"
# 0.2: bbox (WGS84) and start/end_datetime, for the job's STAC Item. 0.3: `rerun`, the run inputs copied as is
MANIFEST_VERSION = "0.3"
RERUN_DIR = "run"
PARQUET_OPTS = {"compression": "zstd", "compression_level": 6}
# Time series Zarr chunks: at most this many locations, and about this many values (1 MiB of float32)
ZARR_CHUNK_LOCATIONS = 512
ZARR_CHUNK_VALUES = 262_144

# TEEHR's secondary timeseries schema, written by export_teehr_schema.py from the teehr library
# at image build time (teehr needs pyspark, so it isn't installed in this image).
TEEHR_SCHEMA_FILE = Path(
    os.environ.get("TEEHR_SCHEMA_FILE", Path(__file__).with_name("teehr_secondary_timeseries.arrow"))
)

# ngen nexus flow: src/core/nexus/HY_PointHydroNexus.cpp:228 returns "m3/s"
NEXUS_UNIT = "m3 s-1"

# gpkg layer -> icefabric v2.2 schema class (same list as icefabric tools/hydrofabric/hf2.2_gpkg_to_parquet.py)
HYDROFABRIC_LAYERS = {
    "divide-attributes": hf.DivideAttributes,
    "divides": hf.Divides,
    "flowpath-attributes-ml": hf.FlowpathAttributesML,
    "flowpath-attributes": hf.FlowpathAttributes,
    "flowpaths": hf.Flowpaths,
    "hydrolocations": hf.Hydrolocations,
    "lakes": hf.Lakes,
    "network": hf.Network,
    "nexus": hf.Nexus,
    "pois": hf.POIs,
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load_teehr_schema() -> pa.Schema:
    if not TEEHR_SCHEMA_FILE.exists():
        raise SystemExit(f"{TEEHR_SCHEMA_FILE} not found: create it with export_teehr_schema.py")
    with pa.OSFile(str(TEEHR_SCHEMA_FILE)) as f:
        return pa.ipc.read_schema(f)


def write_timeseries(df: pd.DataFrame, path: Path, schema: pa.Schema, configuration_name: str) -> dict:
    """Write long-format rows (location_id, value_time, variable_name, unit_name, value) as TEEHR timeseries.

    Columns come from TEEHR's schema. The ones this tool doesn't fill (reference_time, member,
    created_at, updated_at) are null; a new required column in a later teehr version stops the tool.
    """
    df = df.dropna(subset=["value"]).sort_values(["location_id", "variable_name", "value_time"])
    df = df.assign(configuration_name=configuration_name)
    n = len(df)
    columns = []
    for field in schema:
        if field.name in df.columns:
            columns.append(pa.array(df[field.name].to_numpy(), from_pandas=True).cast(field.type))
        elif field.nullable:
            columns.append(pa.nulls(n, field.type))
        else:
            raise SystemExit(f"TEEHR schema column '{field.name}' is required but this tool doesn't fill it")
    table = pa.Table.from_arrays(columns, schema=schema.remove_metadata())
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, path, **PARQUET_OPTS)
    # Per-variable stats so a bad model value (e.g. a t-route depth of 1e35) shows up in the manifest
    stats = df.groupby("variable_name")["value"].agg(["count", "min", "max"])
    teehr_version = (schema.metadata or {}).get(b"teehr_version", b"unknown").decode()
    return {
        "path": str(path), "format": "parquet", "schema": f"teehr.secondary_timeseries@{teehr_version}",
        "rows": n, "locations": int(df["location_id"].nunique()),
        "value_time": [str(df["value_time"].min()), str(df["value_time"].max())] if n else None,
        "variables": {v: {"count": int(r["count"]), "min": float(r["min"]), "max": float(r["max"])}
                      for v, r in stats.iterrows()},
    }


def write_timeseries_zarr(df: pd.DataFrame, path: Path, source: str) -> dict:
    """Write long-format rows as a Zarr v3 store with one (location_id, time) array per variable.

    The same rows as the Parquet file, laid out for array readers (maps, plots): values are float32,
    as in TEEHR's schema, and each variable's units come from unit_name. Missing values are NaN.
    """
    locations = sorted(df["location_id"].unique())
    times = sorted(df["value_time"].unique())
    data_vars = {}
    for var, rows in df.groupby("variable_name", sort=True):
        units = rows["unit_name"].unique()
        # pivot raises on a repeated (location, time), which would be a bug in the readers above
        grid = rows.pivot(index="location_id", columns="value_time", values="value")
        grid = grid.reindex(index=locations, columns=times)
        data_vars[var] = (("location_id", "time"), grid.to_numpy(dtype="float32"),
                          {"units": str(units[0]) if len(units) == 1 else "unknown"})
    ds = xr.Dataset(data_vars, coords={"location_id": locations, "time": pd.DatetimeIndex(times)},
                    attrs={"source": source})

    # Up to ZARR_CHUNK_LOCATIONS locations and ~ZARR_CHUNK_VALUES values per chunk, so reading one
    # location's series or every location at one time each touches a few chunks.
    n_loc, n_time = ds.sizes["location_id"], ds.sizes["time"]
    loc_chunk = min(n_loc, ZARR_CHUNK_LOCATIONS)
    time_chunk = max(1, min(n_time, ZARR_CHUNK_VALUES // loc_chunk))
    encoding = {v: {"compressors": [ZstdCodec(level=5)], "chunks": (loc_chunk, time_chunk)} for v in ds.data_vars}
    ds.to_zarr(path, mode="w", zarr_format=3, encoding=encoding, consolidated=False)
    return {
        "path": str(path), "format": "zarr", "zarr_format": 3, "dims": dict(ds.sizes),
        "chunks": {"location_id": loc_chunk, "time": time_chunk},
        "time": [str(ds["time"].values[0]), str(ds["time"].values[-1])] if n_time else None,
        "variables": {v: {"units": ds[v].attrs["units"]} for v in ds.data_vars},
    }


def catchment_rows(ngen_dir: Path) -> tuple[pd.DataFrame, str]:
    """Catchment output rows and where they came from.

    Reads ngen's NetCDF catchment output (every cat_output.nc, e.g. one per MPI rank under rank_<N>/)
    when the run has it, since it carries each variable's units; otherwise the per-catchment CSVs.
    """
    ncs = sorted(ngen_dir.rglob("cat_output.nc"))
    if ncs:
        return pd.concat([netcdf_catchment_rows(nc) for nc in ncs], ignore_index=True), "outputs/ngen/**/cat_output.nc"
    csvs = sorted(ngen_dir.glob("cat-*.csv"))
    if not csvs:
        raise SystemExit(f"no catchment output in {ngen_dir}: expected cat-*.csv or cat_output.nc")
    frames = []
    for csv in csvs:
        df = pd.read_csv(csv).drop(columns=["Time Step"])
        df = df.melt(id_vars="Time", var_name="variable_name", value_name="value")
        df["location_id"] = csv.stem
        frames.append(df)
    df = pd.concat(frames, ignore_index=True)
    df["value_time"] = pd.to_datetime(df.pop("Time"))
    df["unit_name"] = "unknown"  # ngen's catchment CSVs have no units; cat_output.nc does
    return df, "outputs/ngen/cat-*.csv"


def netcdf_catchment_rows(nc: Path) -> pd.DataFrame:
    # ngen's CatchmentNetcdfOutputMgr (CIROH-UA/ngen#49): catchment ids in the char variable feature_id,
    # time in minutes since 1970-01-01, one (feature_id, time) variable per output with the model's
    # units in its "units" attribute (absent when the model reports none).
    frames = []
    with xr.open_dataset(nc) as ds:
        ids = ds["feature_id"].values.astype(str)
        times = pd.DatetimeIndex(ds["time"].values, name="value_time")
        for var in ds.data_vars:
            da = ds[var]
            if da.dims != ("feature_id", "time"):
                continue
            df = pd.DataFrame(da.values.T, index=times, columns=ids)
            df = df.reset_index().melt(id_vars="value_time", var_name="location_id", value_name="value")
            df["variable_name"] = var
            df["unit_name"] = da.attrs.get("units") or "unknown"
            frames.append(df)
    if not frames:
        raise SystemExit(f"{nc} has no (feature_id, time) variables")
    return pd.concat(frames, ignore_index=True)


def nexus_rows(ngen_dir: Path) -> pd.DataFrame:
    # PerNexusCsvOutputMgr.cpp:64 writes "<step>, <time>, <flow>" with no header
    frames = []
    for csv in sorted(ngen_dir.glob("nex-*_output.csv")):
        df = pd.read_csv(csv, header=None, names=["step", "time", "value"], skipinitialspace=True)
        df["location_id"] = csv.name.removesuffix("_output.csv")
        frames.append(df)
    df = pd.concat(frames, ignore_index=True)
    df["value_time"] = pd.to_datetime(df.pop("time"))
    df["variable_name"] = "flow"
    df["unit_name"] = NEXUS_UNIT
    return df.drop(columns="step")


def troute_rows(troute_dir: Path) -> pd.DataFrame:
    frames = []
    for nc in sorted(troute_dir.glob("*.nc")):
        with xr.open_dataset(nc) as ds:
            for var in ds.data_vars:
                da = ds[var]
                if da.dims != ("feature_id", "time"):
                    continue  # e.g. "type", per feature only
                df = da.to_dataframe(name="value").reset_index()
                df["location_id"] = "wb-" + df["feature_id"].astype(str)  # feature_id 2654 = flowpath wb-2654
                df["variable_name"] = var
                df["unit_name"] = da.attrs.get("units", "unknown")
                frames.append(df.rename(columns={"time": "value_time"}).drop(columns="feature_id"))
    return pd.concat(frames, ignore_index=True)


def forcing_rows(forcings_nc: Path) -> pd.DataFrame:
    # forcings.py:586-611 in NGIAB_data_preprocess: dims (catchment-id, time), ids in "ids",
    # time as a 2-D "Time" array of Unix seconds, the same row for every catchment
    with xr.open_dataset(forcings_nc) as ds:
        ids = ds["ids"].values.astype(str)
        times = pd.to_datetime(ds["Time"].values[0], unit="s")
        frames = []
        for var in ds.data_vars:
            if var in ("ids", "Time"):
                continue
            da = ds[var]
            df = pd.DataFrame(da.values.T, index=times, columns=ids).rename_axis("value_time")
            df = df.reset_index().melt(id_vars="value_time", var_name="location_id", value_name="value")
            df["variable_name"] = var
            df["unit_name"] = da.attrs.get("units", "unknown")
            frames.append(df)
    return pd.concat(frames, ignore_index=True)


def geo_metadata(gdf: gpd.GeoDataFrame) -> dict:
    """GeoParquet 1.1 file metadata for a WKB "geometry" column."""
    return {
        "version": "1.1.0",
        "primary_column": "geometry",
        "columns": {"geometry": {
            "encoding": "WKB",
            "geometry_types": sorted(gdf.geom_type.dropna().unique().tolist()),
            "crs": gdf.crs.to_json_dict() if gdf.crs else None,
            "bbox": [float(v) for v in gdf.total_bounds],
        }},
    }


def wgs84_bounds(geo: dict) -> list[float]:
    """A GeoParquet bbox in its column's CRS as [west, south, east, north] in WGS84 degrees. The edges
    are densified, so a projected box's curved sides stay inside the result."""
    column = geo["columns"]["geometry"]
    to_wgs84 = Transformer.from_crs(CRS.from_json_dict(column["crs"]), "EPSG:4326", always_xy=True)
    return list(to_wgs84.transform_bounds(*column["bbox"], densify_pts=21))


def union_bounds(boxes: list[list[float]]) -> list[float] | None:
    if not boxes:
        return None
    return [min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)]


def write_hydrofabric(gpkg: Path, out_dir: Path) -> tuple[list[dict], list[dict], list[float] | None]:
    """The gpkg's layers as (Geo)Parquet: their outputs, the layers skipped, and the WGS84 bounds of
    every layer with geometry (None when none has a CRS)."""
    outputs, skipped, boxes = [], [], []
    present = {name for name, _ in pyogrio.list_layers(gpkg)}
    out_dir.mkdir(parents=True, exist_ok=True)
    for layer, schema in HYDROFABRIC_LAYERS.items():
        if layer not in present:
            skipped.append({"path": f"{gpkg.name}:{layer}", "reason": "layer not in subset gpkg"})
            continue
        df = gpd.read_file(gpkg, layer=layer)
        columns = schema.columns()
        missing = [c for c in columns if c not in df.columns]
        dropped = [c for c in df.columns if c not in columns]
        for c in missing:
            df[c] = None  # e.g. divide-attributes.glacier_percent: nullable in icefabric, absent in community gpkg
        geo = None
        if "geometry" in columns:
            geo = geo_metadata(df)
            if geo["columns"]["geometry"]["crs"] and len(df):
                boxes.append(wgs84_bounds(geo))
            wkb = df.geometry.to_wkb().values
            df = pd.DataFrame(df.drop(columns="geometry"))
            df["geometry"] = wkb
        table = pa.Table.from_pandas(pd.DataFrame(df[columns]), schema=schema.arrow_schema(), preserve_index=False)
        if geo:
            table = table.replace_schema_metadata({**(table.schema.metadata or {}), b"geo": json.dumps(geo).encode()})
        path = out_dir / f"{layer}.parquet"
        pq.write_table(table, path, **PARQUET_OPTS)
        outputs.append({
            "path": str(path), "format": "geoparquet" if geo else "parquet",
            "schema": f"icefabric.hydrofabric_v2.2.{schema.__name__}@9bcff38", "rows": table.num_rows,
            "filled_with_nulls": missing, "dropped_columns": dropped,
        })
    return outputs, skipped, union_bounds(boxes)


def write_gridded(raw_nc: Path, out_dir: Path) -> list[dict]:
    outputs = []
    with xr.open_dataset(raw_nc) as raw:
        # The WKT is NWM's LCC on a 6,370,000 m sphere, followed by ESRI precision text after ";"
        crs = CRS.from_wkt(raw.attrs["crs"].split(";")[0])
        ds = raw.drop_attrs().rio.write_crs(crs.to_wkt()).sortby("y", ascending=False)
        ds.attrs = {"source": "NGIAB_data_preprocess forcings/raw_gridded_data.nc",
                    "source_name": raw.attrs.get("name", "")}
        for var in ds.data_vars:
            ds[var].attrs.update(raw[var].attrs)
            # CF link to the CRS variable; set as an attribute because the encoding passed to
            # to_zarr below replaces the one rioxarray put it in
            ds[var].encoding.pop("grid_mapping", None)
            ds[var].attrs["grid_mapping"] = "spatial_ref"
        ds = ds.load()

    zarr_path = out_dir / "forcings.zarr"
    # Spatial chunks up to 256 x 256 and ~ZARR_CHUNK_VALUES values per chunk, so a small grid gets long
    # time chunks instead of thousands of tiny ones.
    n_time, cy, cx = ds.sizes["time"], min(256, ds.sizes["y"]), min(256, ds.sizes["x"])
    chunks = {"time": max(1, min(n_time, ZARR_CHUNK_VALUES // (cy * cx))), "y": cy, "x": cx}
    encoding = {v: {"compressors": [ZstdCodec(level=5)], "chunks": tuple(chunks[d] for d in ds[v].dims)}
                for v in ds.data_vars}
    # consolidated metadata is not part of the Zarr v3 spec, so leave it off
    ds.to_zarr(zarr_path, mode="w", zarr_format=3, encoding=encoding, consolidated=False)
    outputs.append({"path": str(zarr_path), "format": "zarr", "zarr_format": 3, "crs_wkt": crs.to_wkt(),
                    "dims": dict(ds.sizes), "chunks": chunks, "variables": list(ds.data_vars)})

    # COGs are map layers: one band each, a summary over the whole run. The hourly data is in the Zarr store.
    # A time step with a missing value makes that cell NaN rather than a mean or total over fewer steps.
    times = pd.DatetimeIndex(ds["time"].values)
    period = [times[0].isoformat(), times[-1].isoformat()]
    summaries = [(var, "mean", ds[var].mean("time", skipna=False), ds[var].attrs.get("units", "unknown"))
                 for var in ds.data_vars]
    steps = times.to_series().diff().dropna().unique()
    if "precip_rate" in ds and ds["precip_rate"].attrs.get("units") == "mm s^-1" and len(steps) == 1:
        # precip_rate is the mean rate over each step (cell_methods "time: mean"), so the depth is rate x step
        step_s = pd.Timedelta(steps[0]).total_seconds()
        summaries.append(("precip_rate", "total", ds["precip_rate"].sum("time", skipna=False) * step_s, "mm"))
    cog_dir = out_dir / "cog"
    cog_dir.mkdir(parents=True, exist_ok=True)
    for var, stat, da, units in summaries:
        da.attrs = {"long_name": f"{stat} of {var}, {period[0]} to {period[1]}", "units": units}
        path = cog_dir / f"{var}_{stat}.tif"
        da.rio.to_raster(path, driver="COG", compress="ZSTD", overview_resampling="average")
        outputs.append({"path": str(path), "format": "cog", "variable": var, "statistic": stat,
                        "period": period, "time_steps": n_time, "units": units})
    return outputs


def period(outputs: list[dict]) -> tuple[str, str] | None:
    """The first and last value_time over every time series written, in UTC (TEEHR's times have no
    zone and are UTC)."""
    spans = [o["value_time"] for o in outputs if o.get("value_time")]
    if not spans:
        return None
    first, last = min(pd.Timestamp(s[0]) for s in spans), max(pd.Timestamp(s[1]) for s in spans)
    return tuple(t.tz_localize("UTC").isoformat() if t.tzinfo is None else t.tz_convert("UTC").isoformat()
                 for t in (first, last))


# A rerun file's path, as cng-to-ngen accepts it: relative, plain characters, no empty part (no `.`/`..`
# below: they are refused separately)
SAFE_PATH = re.compile(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*")


class NotRerunnable(Exception):
    """The run folder can be converted, but not kept for a rerun (the reason goes to not_converted)."""


def walk_files(top: Path, run: Path) -> list[Path]:
    """Every regular file under `top`, refusing any symlink (file or folder) and anything that resolves
    outside the run folder: these files are copied into the job's output as they are."""
    if top.is_symlink():
        raise SystemExit(f"{top.relative_to(run)} is a symlink: the run folder must hold real files")
    found = []
    for folder, dirs, files in os.walk(top, followlinks=False):
        for name in dirs + files:
            path = Path(folder) / name
            if path.is_symlink():
                raise SystemExit(f"{path.relative_to(run)} is a symlink: the run folder must hold real files")
        for name in files:
            path = Path(folder) / name
            if not path.is_file():                 # a FIFO, socket or device: nothing to copy
                raise SystemExit(f"{path.relative_to(run)} is not a regular file")
            found.append(path)
    return found


def rerun_files(run: Path) -> list[Path]:
    """What ngen and t-route read to run again, relative to the run folder: every file under config/
    (realization, troute.yaml, the gpkg, cat_config/), forcings/forcings.nc and the MPI partitions.
    The outputs and the gridded forcings (already converted, and read by no model) are left out.
    SystemExit on a symlink; NotRerunnable when cng-to-ngen couldn't rebuild a runnable folder from them."""
    files = walk_files(run / "config", run) if (run / "config").is_dir() else []
    forcings = run / "forcings/forcings.nc"
    if not forcings.is_file():
        raise NotRerunnable("no forcings/forcings.nc")
    walk_files(run / "forcings", run)            # no symlink in forcings/; only forcings.nc is kept
    files.append(forcings)
    files += sorted(f for f in run.glob("partitions_*.json") if f.is_file())
    root = run.resolve()
    for f in files:
        if f.is_symlink() or not f.resolve().is_relative_to(root):
            raise SystemExit(f"{f.relative_to(run)} is a symlink or outside the run folder")
    rels = sorted(f.relative_to(run) for f in files)
    if not any(r.parent == Path("config") and "realization" in r.name and r.suffix == ".json" for r in rels):
        raise NotRerunnable("no config/*realization*.json")
    odd = [str(r) for r in rels if not SAFE_PATH.fullmatch(str(r))]
    if odd:
        raise NotRerunnable(f"file names cng-to-ngen won't take (A-Z a-z 0-9 . _ - only): {odd[:3]}")
    return rels


def copy_rerun(run: Path, out: Path, files: list[Path]) -> dict:
    """Copy `files` (rerun_files' answer) to out/run/, byte for byte, and describe them for the manifest."""
    copied = []
    for rel in files:
        target = out / RERUN_DIR / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(run / rel, target)
        copied.append({"path": str(rel), "sha256": sha256(target), "bytes": target.stat().st_size})
    return {"dir": RERUN_DIR, "files": copied}


def read_run_metadata(path: Path) -> dict:
    if not path.exists():
        return {}
    pairs = (line.split(":", 1) for line in path.read_text().splitlines() if ":" in line)
    return {k.strip(): v.strip() for k, v in pairs}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run_dir", type=Path, help="NGIAB run folder (config/, forcings/, outputs/)")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--run-id", default=None, help="Defaults to the run folder name")
    p.add_argument("--configuration-name", default="ngiab")
    args = p.parse_args()

    run, out = args.run_dir, args.output
    # What a rerun keeps is decided first: a symlink or special file stops the job before minutes of conversion
    try:
        keep, not_kept = rerun_files(run), None
    except NotRerunnable as err:
        keep, not_kept = None, str(err)
    out.mkdir(parents=True, exist_ok=True)
    gpkgs = sorted((run / "config").glob("*.gpkg"))
    if len(gpkgs) != 1:
        raise SystemExit(f"expected one gpkg in {run / 'config'}, found {len(gpkgs)}")

    ts, schema, config = out / "timeseries", load_teehr_schema(), args.configuration_name
    outputs = []
    catchment, catchment_source = catchment_rows(run / "outputs/ngen")
    # Each table goes to Parquet (TEEHR, evaluation) and, except nexus flow (t-route's output holds the
    # routed flow), to a (location_id, time) Zarr store (maps and plots).
    for name, rows, source in (
        ("catchment", catchment, catchment_source),
        ("nexus", nexus_rows(run / "outputs/ngen"), None),
        ("troute", troute_rows(run / "outputs/troute"), "outputs/troute/*.nc"),
        ("forcings", forcing_rows(run / "forcings/forcings.nc"), "forcings/forcings.nc"),
    ):
        outputs.append(write_timeseries(rows, ts / f"{name}.parquet", schema, config))
        if source:
            outputs.append(write_timeseries_zarr(rows, ts / f"{name}.zarr", source))
    hf_outputs, not_converted, bbox = write_hydrofabric(gpkgs[0], out / "hydrofabric")
    outputs += hf_outputs
    raw_nc = run / "forcings/raw_gridded_data.nc"
    if raw_nc.exists():
        outputs += write_gridded(raw_nc, out / "gridded")
    else:
        not_converted.append({"path": "forcings/raw_gridded_data.nc", "reason": "not in run folder"})
    if (run / "outputs/summa").exists():
        not_converted.append({"path": "outputs/summa", "reason": "SUMMA output not supported yet"})

    for o in outputs:
        o["path"] = str(Path(o["path"]).relative_to(out))
    inputs = [run / "config/realization.json", run / "config/troute.yaml", gpkgs[0], run / "forcings/forcings.nc"]
    span = period(outputs)
    rerun = copy_rerun(run, out, keep) if keep is not None else None
    if not_kept:                                # converted all the same; cng-to-ngen will say why it can't
        not_converted.append({"path": RERUN_DIR, "reason": f"not kept for a rerun: {not_kept}"})
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "tool": {"name": "ngiab-to-cng", "version": TOOL_VERSION},
        "run_id": args.run_id or run.resolve().name,
        "configuration_name": args.configuration_name,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **({"bbox": bbox} if bbox else {}),
        **({"start_datetime": span[0], "end_datetime": span[1]} if span else {}),
        "run_metadata": read_run_metadata(run / "outputs/run_metadata.txt"),
        "inputs": [{"path": str(f.relative_to(run)), "sha256": sha256(f)} for f in inputs if f.exists()],
        "outputs": outputs,
        "not_converted": not_converted,
        **({"rerun": rerun} if rerun else {}),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"outputs": len(outputs), "not_converted": len(not_converted)}))


if __name__ == "__main__":
    main()
