# Step 4: TEEHR evaluation

Status: **implemented** (2026-11-21). Moved here from hydrowf-core (`docs/design/`, where it was merged
as 4927989), beside the tools it designs. Builds on step 3, hydrowf-core
`docs/design/formats-and-data-inputs.md` ("the core design" below): tool-declared formats (its Part A),
data legos as inputs (its Part B) and reading in place (its Part D). Decided before this draft
(2026-11-20): a generic `teehr-timeseries` data lego and a generic `teehr-evaluate` tool; metrics are a
pipeline input with defaults (a string with a pattern until a multi-choice port type exists); gage points
come from the USGS site service. Decided 2026-11-21 (section 7): the NWM 3.0 retrospective as an
optional baseline now; ngen location ids `ngen-<n>`; no USGS key on kind, a Secret on EKS; hourly
observations only.

Since then: ngiab-to-cng 0.4.1 refuses a configuration name TEEHR uses for its own data, teehr-evaluate
0.1.1 drops a repeated metric, and hydrowf-ogc's `ngiab-evaluation@0.2.0` and `teehr-evaluation@0.2.0`
run them; `ngiab-evaluation@0.2.0` requires a configuration name starting with `ngiab`, so TEEHR's own
names are refused when the job is submitted. The sections below describe the first versions.

## 1. Goals

1. **A simulation's time series can be evaluated against observations with TEEHR**, and the metrics are
   a job output like any other (files, a STAC Item, read keys).
2. **The evaluation knows nothing about ngen.** `teehr-evaluate` reads `teehr-timeseries`, a format any
   model's tool can write. ngen is one writer: ngiab-to-cng writes it as a second format.
3. **The simulated series are read in place** with the step's vended keys (the core design's Part D), not
   staged: from a caller's job output, or from the step before (its D.7).

Non-goals: USGS daily means for gages without instantaneous data; variables other than streamflow; a
TEEHR warehouse that keeps evaluations across jobs; the TEEHR-Cloud warehouse; the metrics in a UI.

The domain-agnostic test holds: a new model gets evaluated by writing `teehr-timeseries`, with registry
entries only.

## 2. What TEEHR 0.8.0 needs (checked in a container)

| What | Finding |
|---|---|
| Spark jars | Every `Evaluation(...)` resolves Maven packages (Sedona, Iceberg, hadoop-aws, sqlite-jdbc). Offline, with no cache, it fails (`JAVA_GATEWAY_EXITED`). Creating one evaluation at image build fills Ivy's cache (`/tmp/.ivy2.5.2`), and later runs then work with `--network none`. |
| Non-root | The cache must be writable by the runtime user: Ivy writes a resolution file on every start (as uid 1000 against a root-owned cache: `FileOutputStream.open0` fails). Build it under a path the image `chown`s, or pass the jars with `add_jars` instead of packages. |
| Domain tables | A new evaluation already has variable `streamflow_hourly_inst` and unit `m^3/s`; no configurations. |
| USGS observations | `ev.fetch.usgs_streamflow(start_date, end_date, service="iv")` fetches every location whose id is `usgs-%`, through the USGS Water Data API (`dataretrieval.waterdata`); `API_USGS_PAT` raises the rate limit and is optional. So **the gage points must be in the locations table first**, with geometry. |
| Loading | `secondary_timeseries.load_dataframe(df)`, `location_crosswalks.load_dataframe(df)`, `locations.load_dataframe(gdf)`; `configurations.add(Configuration(...))`. |
| Metrics | `DeterministicMetrics` has 32 (KGE and its two variants, NSE, relative bias, RMSE, RMSDR, Pearson, ...). |
| S3 | `create_spark_session` takes `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`, `aws_region`, `update_configs`: Spark itself could read the Parquet in place. |
| TEEHR-Cloud warehouse | `ev.download.*` (`api.teehr.rtiamanzi.org`) answers `401 Unauthorized` without a key: not usable without an account from RTI. |
| NWM 3.0 retrospective | `fetch.nwm_retrospective_points(nwm_version="nwm30", ...)` reads NOAA's public Zarr (`s3://noaa-nwm-retrospective-3-0-pds/CONUS/zarr/chrtout.zarr`, anonymous) for the `nwm30-<feature_id>` ids in the crosswalk table; 1979-02-01 01:00 to 2023-01-31 23:00. |
| Gage to NWM reach | The same Zarr has a `gage_id` per `feature_id` (8,660 set of 2,776,734): `01031510` is `nwm30-1722933`. Reading the coordinate takes about 8 s, anonymously. |

CIROH's ngiab-teehr (teehr 0.6.2) is the reference: it takes the crosswalk from the gpkg's
`flowpath-attributes.gage` (`wb-2658` <-> `01031510`), names ids `ngen-2658` and `usgs-01031510`, uses
`streamflow_hourly_inst` in `m^3/s`, and computes RMSDR, relative bias, NSE and KGE (each with
`add_epsilon`). It downloads observations, the NWM crosswalk and the NWM retrospective from the TEEHR-Cloud
warehouse; we fetch observations from USGS and the NWM data from NOAA's public bucket.

## 3. Part A: the `teehr-timeseries` data lego

A directory, so any tool can write it without TEEHR installed:

```
manifest.json                     manifest 0.2 (bbox of the gages, period), plus the fields below
timeseries/secondary.parquet      TEEHR secondary_timeseries schema (the tool's teehr version)
crosswalk.parquet                 secondary_location_id, primary_location_id (usgs-<site>)
```

- Rows use TEEHR's names: `variable_name` from TEEHR's variables (`streamflow_hourly_inst`), `unit_name`
  from its units (`m^3/s`), and one `configuration_name` (the pipeline's input, as today).
- Location ids are `<prefix>-<id>` (ngen: `ngen-2658` for flowpath `wb-2658`, as ngiab-teehr names them);
  the crosswalk names each simulated location's gage. Only crosswalked
  locations are written: the file holds what can be evaluated, not the whole network.
- `manifest.json` adds `{teehr: {schema: "teehr.secondary_timeseries@<version>", configuration_name,
  variable_name, unit_name}}`, so a reader checks the version and names before reading the Parquet.
- Data lego `teehr-timeseries@1.0.0`, `storage: {driver: stac, format: other}` (as `ngen-cng`).

### ngiab-to-cng 0.4.0

Output `cng` gets `formats: [ngen-cng, teehr-timeseries]` and `--format "{cng_format}"`. For
`teehr-timeseries` it writes t-route's routed flow (`troute_rows`: `flow`, in the unit of t-route's netCDF
`units` attribute; the writer maps it to `m^3/s` and refuses one it doesn't know) at the
flowpaths whose `flowpath-attributes.gage` is set, renamed to TEEHR's names, and the crosswalk from that
column (the first gage where a hydrofabric lists several, as ngiab-teehr does). A run with no gage in
its subset writes no rows and says so in `not_converted`. `ngen-cng` is unchanged.

A pipeline that wants both formats runs the tool twice (one step each); converting is minutes beside a
NextGen run.

## 4. Part B: the `teehr-evaluate` tool

```yaml
- kind: tool
  id: teehr-evaluate
  version: 0.1.0
  args: ["{timeseries}", --metrics, "{metrics}", --output, "{workdir}/evaluation", --run-id, "{run}"]
  inputs:
    - {name: timeseries, type: dataset, data: teehr-timeseries}      # read in place (core design Part D)
    - {name: metrics, type: string, default: "kge,nse,relative_bias,rmsdr",
       pattern: '<metric>(,<metric>)*'}                              # <metric>: the names in 4.1
    - {name: baseline, type: enum, symbols: [none, nwm30_retrospective], default: none}
  outputs:
    - {name: evaluation, type: directory, data: teehr-metrics, path: evaluation}
  network: true                                                      # USGS
  cpu: 2
  ram_mb: 4096                                                       # Spark; measure on a real run
```

What it does:

1. Reads `manifest.json`, `crosswalk.parquet` and `timeseries/secondary.parquet` from the dataset URL
   with the step's keys (pyarrow's S3 filesystem with the session token; the files are small next to a
   Zarr, and Spark's S3A setup stays out of the tool). Refuses a TEEHR schema version it wasn't built
   for, and names it doesn't know.
2. Gets each crosswalked gage's point from the USGS site service (Water Data API monitoring
   locations), and loads them as `usgs-<site>` locations. A site USGS doesn't know is left out and
   listed in the manifest.
3. Loads the crosswalk, adds the configuration, loads the secondary series.
4. `fetch.usgs_streamflow` over the manifest's period (`iv`, hourly, SI). A gage with no hourly data
   in the period is left out and listed.
5. With `baseline: nwm30_retrospective`: reads the public Zarr's `gage_id` coordinate, adds a
   `usgs-<site>` -> `nwm30-<feature_id>` crosswalk row per gage, and runs
   `fetch.nwm_retrospective_points(nwm_version="nwm30", variable_name="streamflow", ...)` over the
   period. A period outside 1979-02-01 to 2023-01-31 (all or part) keeps what overlaps; none overlapping
   means no baseline, and the manifest says why. A gage the Zarr doesn't list has no baseline row.
6. Computes the chosen metrics grouped by `primary_location_id, configuration_name` (`add_epsilon` on,
   as ngiab-teehr) over the joined timeseries: one row per gage for the simulation and, with a
   baseline, one for `nwm30_retrospective`.
7. Writes `metrics.parquet`, `locations.parquet` (the gage points, GeoParquet) and `manifest.json`
   (manifest 0.2: bbox of the gages, period; the metrics, the baseline, sites left out and why, teehr
   version).

The TEEHR evaluation folder itself (Iceberg tables, Spark state) stays in the pod: it isn't an output.

### 4.1 Metrics input

Short names, mapped to `DeterministicMetrics` in the tool: `kge`, `kge_mod1`, `kge_mod2`, `nse`,
`nnse`, `relative_bias`, `rmsdr`, `rmse`, `mae`, `pearson`, `r2`, `annual_peak_relative_bias`. The
pattern lists exactly these, so a wrong name is refused at submission. Default: ngiab-teehr's four.

### 4.2 Image

`hydrowf-tools nextgen/../teehr-evaluate` (generic: a new folder beside `nextgen/`, e.g. `evaluation/`):
python 3.12 slim, a JRE, `teehr==0.8.0` pinned, and the Spark jars fetched at build into a cache the
runtime user owns, so the step needs the network for USGS and NOAA's bucket only. Built and scanned by the tools CI like
the others; pinned by digest in the registry.

## 5. Part C: pipelines and /ogc

- `teehr-timeseries@1.0.0`, `teehr-metrics@1.0.0` (stac, other), `ngiab-to-cng@0.4.0`, `teehr-evaluate@0.1.0`
  in hydrowf-ogc's registry.
- `ngiab-evaluation@0.1.0`: preprocess, run, `to-teehr` (ngiab-to-cng, format `teehr-timeseries`),
  evaluate. Inputs as `ngiab-simulation` plus `metrics` and `baseline`.
- `teehr-evaluation@0.1.0`: evaluate only, its `timeseries` input a caller's own job output (core design 3.3),
  so an existing run is evaluated without rerunning it.
- /ogc needs nothing new: the outputs get STAC Items from their manifests (step 2 of the core
  design), and the evaluation step reads in place through the vendor (its D.4, PR 7b).

## 6. Security notes

- The tool reaches USGS and NOAA's public bucket (anonymously) only; it gets read keys for its one
  dataset input (core design Part D), never write keys.
- `API_USGS_PAT`: none on kind (anonymous rate limit); on EKS a cluster Secret the tool's env reads
  (not a pipeline input, not logged).
- The metrics pattern and the baseline enum are the only caller-given values; both are closed lists.

## 7. Decisions (2026-11-21)

1. **NWM 3.0 retrospective as an optional baseline, now** (`baseline`, default `none`), from NOAA's
   public bucket, not the TEEHR-Cloud warehouse (which needs an account).
2. **ngen location ids are `ngen-<n>`**, as ngiab-teehr names them, so its results and ours line up.
3. **`API_USGS_PAT`**: none on kind; a Secret on EKS.
4. **Hourly observations only**; daily means (`service="dv"`) later.

## 8. Work breakdown

| PR | Repo | Contents | Depends on |
|---|---|---|---|
| 1 | hydrowf-core | this design | |
| 2 | hydrowf-tools | ngiab-to-cng 0.4.0: `--format`, `teehr-timeseries` writer, tests | 1 |
| 3 | hydrowf-tools | teehr-evaluate 0.1.0: image (jars prefetched, non-root), tool, tests against a fixture; a USGS run marked for the network | 1 |
| 4 | hydrowf-ogc | registry: the two data legos, the two tools, the two pipelines; run end to end on kind | 2, 3 |

Each PR: tests first, gates, an independent review where it changes a public API or touches security.
