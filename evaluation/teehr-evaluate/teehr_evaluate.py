#!/usr/bin/env python3
"""Evaluate a simulation's time series against USGS observations with TEEHR.

Reads a teehr-timeseries directory (any model's tool can write one; this repository's docs/design/teehr-evaluation.md):
  manifest.json                    format teehr-timeseries, and `teehr`: schema version and names
  timeseries/secondary.parquet     the simulated series, in TEEHR's secondary timeseries schema
  crosswalk.parquet                secondary_location_id -> primary_location_id (usgs-<site>)
from a local path or s3:// (fsspec: in a step that reads in place, the vended keys and endpoint come from
AWS_SHARED_CREDENTIALS_FILE and AWS_ENDPOINT_URL).

Gets each gage's point from the USGS site service, fetches its hourly observations over the series' period
(USGS Water Data API; API_USGS_PAT raises the rate limit), optionally the NWM 3.0 retrospective at the same
gages (NOAA's public Zarr, whose gage_id gives the gage's NWM reach), and computes the chosen metrics per gage
and configuration.

Output layout (under --output):
  metrics.parquet      one row per (primary_location_id, configuration_name), a column per metric
  locations.parquet    the gage points (GeoParquet, WGS84)
  manifest.json        manifest 0.2: bbox of the gages, period, the metrics, the baseline, gages left out and why
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import fsspec
import geopandas as gpd
import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

TOOL_VERSION = "0.1.1"          # 0.1.1: a repeated metric is dropped, not refused
MANIFEST_VERSION = "0.2"                        # bbox (WGS84) and start/end_datetime, for the job's STAC Item
INPUT_FORMAT = "teehr-timeseries"
INPUT_SCHEMA = "teehr.secondary_timeseries@0.8."     # the teehr minor version this tool is built with
VARIABLE, UNIT = "streamflow_hourly_inst", "m^3/s"
USGS_PREFIX, NWM_PREFIX = "usgs-", "nwm30-"
# Short names -> teehr.DeterministicMetrics classes. The registry's `metrics` pattern lists exactly these.
METRICS = {
    "kge": "KlingGuptaEfficiency", "kge_mod1": "KlingGuptaEfficiencyMod1", "kge_mod2": "KlingGuptaEfficiencyMod2",
    "nse": "NashSutcliffeEfficiency", "nnse": "NormalizedNashSutcliffeEfficiency",
    "relative_bias": "RelativeBias", "rmsdr": "RootMeanStandardDeviationRatio", "rmse": "RootMeanSquareError",
    "mae": "MeanAbsoluteError", "pearson": "PearsonCorrelation", "r2": "Rsquared",
    "annual_peak_relative_bias": "AnnualPeakRelativeBias",
}
BASELINES = ("none", "nwm30_retrospective")
RESERVED_CONFIGURATIONS = ("usgs_observations", "nwm30_retrospective")   # what TEEHR's fetches add
NWM30_ZARR = "s3://noaa-nwm-retrospective-3-0-pds/CONUS/zarr/chrtout.zarr"
NWM30_PERIOD = (pd.Timestamp("1979-02-01 01:00"), pd.Timestamp("2023-01-31 23:00"))   # teehr's own limits
USGS_BATCH = 100                                # sites per monitoring-locations request


def parse_metrics(text: str) -> list[str]:
    """`kge,nse,...` -> the names, in order, each once (a repeat is dropped: the registry's pattern can't refuse
    it, and refusing here would fail a run only after its simulation). Refuses an unknown or empty name."""
    names = [n.strip() for n in text.split(",")]
    unknown = [n for n in names if n not in METRICS]
    if unknown:
        raise SystemExit(f"--metrics {text!r}: give names from {', '.join(METRICS)} "
                         f"(unknown: {', '.join(map(repr, unknown))})")
    return list(dict.fromkeys(names))


def read_input(url: str) -> tuple[dict, pd.DataFrame, pd.DataFrame, list[dict]]:
    """The teehr-timeseries directory at `url`: its manifest, crosswalk, secondary series and the files' sha256.
    Refuses another format, a TEEHR schema version, names or a configuration this tool can't evaluate, a
    malformed crosswalk, and a missing file."""
    fs, root = fsspec.core.url_to_fs(url.rstrip("/"))
    hashes = []

    def read(rel: str):
        try:
            data = fs.cat_file(f"{root}/{rel}")
        except FileNotFoundError:
            raise SystemExit(f"{url}: no {rel}: not a {INPUT_FORMAT} directory") from None
        hashes.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest()})
        return json.loads(data) if rel.endswith(".json") else pq.read_table(pa.BufferReader(data)).to_pandas()

    manifest = read("manifest.json")
    teehr = manifest.get("teehr") if isinstance(manifest.get("teehr"), dict) else {}
    if manifest.get("format") != INPUT_FORMAT:
        raise SystemExit(f"{url}: format {manifest.get('format')!r}, not {INPUT_FORMAT}")
    if not str(teehr.get("schema", "")).startswith(INPUT_SCHEMA):
        raise SystemExit(f"{url}: TEEHR schema {teehr.get('schema')!r}; this tool reads {INPUT_SCHEMA}*")
    if (teehr.get("variable_name"), teehr.get("unit_name")) != (VARIABLE, UNIT):
        raise SystemExit(f"{url}: variable {teehr.get('variable_name')!r} in {teehr.get('unit_name')!r}; "
                         f"this tool evaluates {VARIABLE} in {UNIT}")
    configuration = teehr.get("configuration_name")
    if not isinstance(configuration, str) or not configuration or configuration in RESERVED_CONFIGURATIONS:
        raise SystemExit(f"{url}: configuration_name {configuration!r}: give one, other than "
                         f"{', '.join(RESERVED_CONFIGURATIONS)} (TEEHR's own)")
    secondary, crosswalk = read("timeseries/secondary.parquet"), read("crosswalk.parquet")
    needed = {"location_id", "value_time", "value", "variable_name", "unit_name", "configuration_name"}
    if not needed <= set(secondary.columns):
        raise SystemExit(f"{url}: timeseries/secondary.parquet lacks {sorted(needed - set(secondary.columns))}")
    odd = secondary[(secondary["variable_name"] != VARIABLE) | (secondary["unit_name"] != UNIT)]
    if len(odd):
        raise SystemExit(f"{url}: {len(odd)} rows aren't {VARIABLE} in {UNIT}, as the manifest says")
    if set(secondary["configuration_name"]) - {configuration}:
        raise SystemExit(f"{url}: rows of configuration {sorted(set(secondary['configuration_name']))}, "
                         f"not only the manifest's {configuration!r}")
    columns = ["primary_location_id", "secondary_location_id"]
    if not set(columns) <= set(crosswalk.columns):
        raise SystemExit(f"{url}: crosswalk.parquet lacks {sorted(set(columns) - set(crosswalk.columns))}")
    crosswalk = crosswalk[columns]
    primary = crosswalk["primary_location_id"]
    if not primary.map(lambda v: isinstance(v, str) and re.fullmatch(rf"{USGS_PREFIX}\d+", v) is not None).all():
        raise SystemExit(f"{url}: crosswalk primary_location_id must be {USGS_PREFIX}<site number>")
    if not crosswalk["secondary_location_id"].map(lambda v: isinstance(v, str) and v != "").all():
        raise SystemExit(f"{url}: crosswalk secondary_location_id must be a location id")
    repeated = sorted(set(primary[primary.duplicated()]))
    if repeated:                                # two series under one gage would be pooled into its metrics
        raise SystemExit(f"{url}: crosswalk gives these gages several series: {', '.join(repeated[:5])}")
    return manifest, crosswalk, secondary, hashes


def forget_input_credentials() -> None:
    """After the input is read, drop the S3 endpoint and keys a step that reads in place gets (hydrowf-core's
    Reader): NOAA's public bucket is read anonymously through obstore, which would otherwise send it to our S3
    endpoint, and Spark has no use for our keys."""
    for name in list(os.environ):
        if name.startswith("AWS_") or name == "CPL_AWS_CREDENTIALS_FILE":
            del os.environ[name]
    # teehr's Spark setup asks botocore for credentials; with none left it would try the node's metadata role
    os.environ["AWS_EC2_METADATA_DISABLED"] = "true"


def gage_points(sites: list[str]) -> gpd.GeoDataFrame:
    """The USGS site service's points for these site numbers, as TEEHR locations (id usgs-<site>, name,
    geometry in WGS84). A site the service doesn't know, or gives no point for, is absent."""
    from dataretrieval import waterdata
    frames = []
    for i in range(0, len(sites), USGS_BATCH):
        df, _ = waterdata.get_monitoring_locations(
            monitoring_location_id=[f"USGS-{s}" for s in sites[i:i + USGS_BATCH]])
        if len(df):
            frames.append(df.to_crs("EPSG:4326"))
    if not frames:
        return no_points()
    df = pd.concat(frames, ignore_index=True)
    df = df[df.geometry.notna() & ~df.geometry.is_empty]
    return gpd.GeoDataFrame({"id": USGS_PREFIX + df["monitoring_location_id"].str.removeprefix("USGS-"),
                             "name": df["monitoring_location_name"]}, geometry=df.geometry.values, crs="EPSG:4326")


def no_points() -> gpd.GeoDataFrame:
    return gpd.GeoDataFrame({"id": pd.Series(dtype=str), "name": pd.Series(dtype=str)}, geometry=[], crs="EPSG:4326")


def nwm_crosswalk(sites: list[str]) -> pd.DataFrame:
    """usgs-<site> -> nwm30-<feature_id> from the NWM 3.0 retrospective Zarr's gage_id (anonymous, public).
    A site no NWM reach carries is absent."""
    import xarray as xr
    from teehr.fetching.nwm.retrospective_points import public_zarr_store
    ds = xr.open_zarr(public_zarr_store(NWM30_ZARR), consolidated=True)
    gage = ds["gage_id"].values
    gage = np.char.strip(np.char.decode(gage) if gage.dtype.kind == "S" else gage.astype(str))
    wanted = np.isin(gage, sites)
    return pd.DataFrame({"primary_location_id": USGS_PREFIX + gage[wanted],
                         "secondary_location_id": NWM_PREFIX + ds["feature_id"].values[wanted].astype(str)})


def utc(t: pd.Timestamp) -> str:
    """TEEHR's times have no zone and are UTC."""
    return (t.tz_localize("UTC") if t.tzinfo is None else t.tz_convert("UTC")).isoformat()


def add_baseline(ev, gages: list[str], start: pd.Timestamp, end: pd.Timestamp) -> tuple[dict, list[dict]]:
    """Loads the NWM 3.0 retrospective at these gages (usgs-<site>) over the part of start..end it covers.
    Returns what the baseline did (its period and each gage's reach, or why it was skipped) and the gages it
    has no reach for."""
    b_start, b_end = max(start, NWM30_PERIOD[0]), min(end, NWM30_PERIOD[1])
    if b_start > b_end:
        return {"name": "nwm30_retrospective", "skipped": "the period is outside the NWM 3.0 retrospective "
                f"({NWM30_PERIOD[0]} to {NWM30_PERIOD[1]})"}, []
    nwm = nwm_crosswalk(sorted(g.removeprefix(USGS_PREFIX) for g in gages))
    left_out = [{"gage": g, "reason": "no NWM 3.0 reach carries this gage: no baseline"}
                for g in sorted(set(gages) - set(nwm["primary_location_id"]))]
    if nwm.empty:
        return {"name": "nwm30_retrospective", "skipped": "no gage is on an NWM 3.0 reach"}, left_out
    ev.location_crosswalks.load_dataframe(nwm)
    ev.fetch.nwm_retrospective_points(nwm_version="nwm30", variable_name="streamflow",
                                      start_date=b_start, end_date=b_end)
    reaches = dict(zip(nwm["primary_location_id"], nwm["secondary_location_id"]))
    return {"name": "nwm30_retrospective", "period": [utc(b_start), utc(b_end)], "reaches": reaches}, left_out


def evaluate(secondary: pd.DataFrame, crosswalk: pd.DataFrame, points: gpd.GeoDataFrame, configuration: str,
             metrics: list[str], baseline: str, work: Path) -> tuple[pd.DataFrame, dict, list[dict]]:
    """Runs the TEEHR evaluation: the metrics table, what the baseline did, and gages left out."""
    from teehr import Configuration, DeterministicMetrics, Evaluation
    from teehr.evaluation.spark_session_utils import create_spark_session
    start, end = secondary["value_time"].min(), secondary["value_time"].max()
    spark = create_spark_session(update_configs={"spark.ui.enabled": "false"})   # no open port in the pod
    try:
        ev = Evaluation(dir_path=work, create_dir=True, spark=spark)
        ev.locations.load_dataframe(points[["id", "name", "geometry"]])
        ev.configurations.add(Configuration(name=configuration, timeseries_type="secondary",
                                            description="the simulation evaluated (teehr-timeseries input)"))
        ev.location_crosswalks.load_dataframe(crosswalk)
        ev.secondary_timeseries.load_dataframe(secondary)
        ev.fetch.usgs_streamflow(start_date=start, end_date=end, service="iv")
        gages = sorted(set(crosswalk["primary_location_id"]))
        info, left_out = (add_baseline(ev, gages, start, end) if baseline == "nwm30_retrospective"
                          else ({"name": "none"}, []))
        observed = set(ev.primary_timeseries.distinct_values("location_id"))
        left_out += [{"gage": g, "reason": "USGS has no hourly observations in the period"}
                     for g in gages if g not in observed]
        chosen = []
        for name in metrics:
            metric = getattr(DeterministicMetrics, METRICS[name])()
            metric.add_epsilon = True           # as CIROH's ngiab-teehr: a zero observation doesn't divide by 0
            chosen.append(metric)
        table = (ev.joined_timeseries_view()
                 .aggregate(group_by=["primary_location_id", "configuration_name"], metrics=chosen)
                 .order_by(["primary_location_id", "configuration_name"])
                 .to_pandas())
    finally:
        spark.stop()                            # before its folder is removed
    return table, info, left_out


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("timeseries", help="a teehr-timeseries directory: a local path or s3://bucket/prefix/")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--metrics", default="kge,nse,relative_bias,rmsdr", help=f"from: {', '.join(METRICS)}")
    p.add_argument("--baseline", choices=BASELINES, default="none")
    p.add_argument("--run-id", default=None)
    args = p.parse_args()

    metrics = parse_metrics(args.metrics)
    manifest, crosswalk, secondary, input_hashes = read_input(args.timeseries)
    forget_input_credentials()
    configuration = manifest["teehr"]["configuration_name"]
    crosswalk = crosswalk[crosswalk["secondary_location_id"].isin(secondary["location_id"])]
    sites = sorted(crosswalk["primary_location_id"].str.removeprefix(USGS_PREFIX).unique())
    points = gage_points(sites) if sites else no_points()
    left_out = [{"gage": f"{USGS_PREFIX}{s}", "reason": "the USGS site service doesn't know this site"}
                for s in sites if f"{USGS_PREFIX}{s}" not in set(points["id"])]
    crosswalk = crosswalk[crosswalk["primary_location_id"].isin(points["id"])]
    secondary = secondary[secondary["location_id"].isin(crosswalk["secondary_location_id"])]

    args.output.mkdir(parents=True, exist_ok=True)
    baseline = {"name": args.baseline}
    if crosswalk.empty:
        table = pd.DataFrame({"primary_location_id": pd.Series(dtype=str),
                              "configuration_name": pd.Series(dtype=str)})
        not_evaluated = "no gage with simulated values that the USGS site service knows"
    else:
        with tempfile.TemporaryDirectory(prefix="teehr-") as work:
            table, baseline, more = evaluate(secondary, crosswalk, points, configuration, metrics, args.baseline,
                                             Path(work) / "evaluation")
        left_out += more
        not_evaluated = None
    table.to_parquet(args.output / "metrics.parquet", index=False)
    points.to_parquet(args.output / "locations.parquet", index=False)

    start, end = (secondary["value_time"].min(), secondary["value_time"].max()) if len(secondary) else (None, None)
    out = {
        "manifest_version": MANIFEST_VERSION,
        "tool": {"name": "teehr-evaluate", "version": TOOL_VERSION},
        "run_id": args.run_id,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **({"bbox": [float(v) for v in points.total_bounds]} if len(points) else {}),
        **({"start_datetime": utc(start), "end_datetime": utc(end)} if start is not None else {}),
        "input": {k: manifest.get(k) for k in ("format", "tool", "run_id", "configuration_name")},
        "inputs": input_hashes,
        "teehr": {"version": __import__("teehr").__version__, "configuration_name": configuration,
                  "metrics": metrics, "baseline": baseline},
        "outputs": [{"path": "metrics.parquet", "format": "parquet", "rows": len(table)},
                    {"path": "locations.parquet", "format": "geoparquet", "rows": len(points)}],
        "left_out": left_out,
        **({"not_evaluated": not_evaluated} if not_evaluated else {}),
    }
    (args.output / "manifest.json").write_text(json.dumps(out, indent=2, default=str) + "\n")
    print(json.dumps({"gages": len(points), "rows": len(table), "left_out": len(left_out)}))


if __name__ == "__main__":
    main()
