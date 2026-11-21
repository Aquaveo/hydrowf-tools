# teehr-evaluate

Evaluates a simulation against USGS observations with [TEEHR](https://github.com/RTIInternational/teehr)
0.8.0. It knows no model: it reads `teehr-timeseries`, which a model's own tool writes (for NextGen,
`ngiab-to-cng --format teehr-timeseries`). Design: hydrowf-core `docs/design/teehr-evaluation.md`.

```sh
teehr-evaluate <teehr-timeseries dir or s3://bucket/prefix/> --output <dir> \
  [--metrics kge,nse,relative_bias,rmsdr] [--baseline none|nwm30_retrospective] [--run-id <id>]
```

What it does:

1. Reads `manifest.json`, `crosswalk.parquet` and `timeseries/secondary.parquet` from a local folder or
   `s3://` through fsspec/s3fs. In a step that reads in place, the vended keys and the endpoint come from
   `AWS_SHARED_CREDENTIALS_FILE` and `AWS_ENDPOINT_URL` (hydrowf-core's `Reader`). Refused before any download:
   another format; a TEEHR schema other than 0.8; names other than `streamflow_hourly_inst` in `m^3/s`, in the
   manifest or the rows; a `configuration_name` missing, TEEHR's own (`usgs_observations`,
   `nwm30_retrospective`) or not the rows'; a crosswalk id other than `usgs-<site number>`, an empty secondary
   id, or a gage with several series; a missing file or column; an unknown or repeated metric.
2. Gets each gage's point from the USGS site service (Water Data API monitoring locations).
3. Fetches the gages' hourly observations over the series' period (`fetch.usgs_streamflow`, instantaneous
   values on the hour, SI). `API_USGS_PAT` raises the API's rate limit; without it the anonymous limit applies.
4. With `--baseline nwm30_retrospective`: maps each gage to its NWM reach from the `gage_id` of NOAA's public
   NWM 3.0 retrospective Zarr (anonymous) and fetches that reach's streamflow over the part of the period the
   retrospective covers (1979-02-01 to 2023-01-31).
5. Computes the metrics per gage and configuration (`add_epsilon` on, as CIROH's ngiab-teehr).

Output (under `--output`):

| Path | Contents |
|---|---|
| `metrics.parquet` | One row per (`primary_location_id`, `configuration_name`): the simulation and, with a baseline, `nwm30_retrospective`. A column per metric, named by TEEHR (`kling_gupta_efficiency`, ...) |
| `locations.parquet` | The gage points (GeoParquet, WGS84) |
| `manifest.json` | Manifest 0.2: the gages' `bbox`, the period, the input's format and tool, the metrics, the baseline (its period and each gage's reach, or why it was skipped), and `left_out`: each gage not evaluated and why (unknown to the USGS site service; no hourly observations in the period; no NWM reach) |

Metrics: `kge`, `kge_mod1`, `kge_mod2`, `nse`, `nnse`, `relative_bias`, `rmsdr`, `rmse`, `mae`, `pearson`,
`r2`, `annual_peak_relative_bias`. The default is ngiab-teehr's four.

Notes:

- Hourly observations only: a gage whose record in the period has no value on the hour (e.g. 01031510 in
  January 2020: 62 ice-affected estimates at :15) is left out. Daily means are a later option.
- The TEEHR evaluation itself (Iceberg tables, Spark state) is built in a temporary folder and not kept.

## Image

`hydrowf/teehr-evaluate:0.1.0` from `Dockerfile`; dependencies pinned in `requirements.txt` (from
`requirements.in` with `uv pip compile`).

- teehr resolves its Spark packages from Maven on every session. The image creates one evaluation at build,
  which fills Ivy's cache in `/opt/ivy` (`SPARK_JARS_IVY`), so a step needs the network for USGS and NOAA only.
  Ivy writes there on every start, so the folder is writable by any uid. `dedupe_jars.py` hardlinks the jars
  Ivy copies out of its cache, which saves 1.2 GB (the image is about 3.3 GB).
- It runs as uid 1000. Hadoop needs a user name for its uid, so `entrypoint.sh` names any other uid a pod
  runs it as through nss_wrapper (a passwd file in `$HOME`, `/tmp`), keeping `/etc/passwd` read-only.
- The root filesystem must be writable (Ivy writes in `/opt/ivy`, Spark and the evaluation in `/tmp`): a pod
  with `readOnlyRootFilesystem: true` isn't supported yet (it would need `/opt/ivy` copied to an emptyDir).
- Once the input is read, the tool drops the S3 endpoint and keys from its environment (`AWS_*`): NOAA's
  bucket is read anonymously, through obstore, which would otherwise send it to the cluster's own S3.
  Spark's UI is off, and the session stops before the evaluation's temporary folder is removed.

## Tests

`tests/evaluate.sh` (from the repository root; Docker and the internet). Offline: every refusal (metrics,
baseline, format, schema, names, configuration, crosswalk, missing files), an input with no gage, and Spark
starting from the image's jars as an unnamed uid. Online: the metrics against USGS from a local folder and with
the NWM baseline; read in place from S3 (a RustFS container, keys in a credentials file and the step's endpoint
set, as uid 4321) with the baseline, giving the same metrics; two gages in June 2024, one USGS doesn't know,
with the baseline outside its period; and January 2020, which has no hourly observations. The input is
ngiab-run's test folder through `ngiab-to-cng --format teehr-timeseries`, shifted to June 2020 (or 2024) for the
cases that need observations.

TODO: measure RAM on a large run (each input file is read into memory whole, then parsed, so that its
sha256 is of exactly what was evaluated); publish the image.
