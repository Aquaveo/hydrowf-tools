# ngiab-to-cng

Converts a finished NGIAB run folder (from ngiab-run) into cloud-native files. It writes `<run>_cng/`,
named after the run folder so two conversions in one pipeline don't collide, in one of two formats
(`--format`, a data lego each):

- `ngen-cng` (the default): everything below.
- `teehr-timeseries`: what an evaluation reads ([design](../../docs/design/teehr-evaluation.md)), see
  [teehr-timeseries](#teehr-timeseries).

### ngen-cng

| Path | Format | Contents |
|---|---|---|
| `timeseries/catchment.parquet` | Parquet | ngen catchment output, every variable: `outputs/ngen/**/cat_output.nc` when the run has it (ngen NetCDF output, CIROH-UA/ngen#49), otherwise `outputs/ngen/cat-*.csv` |
| `timeseries/nexus.parquet` | Parquet | `outputs/ngen/nex-*_output.csv` (flow, m3 s-1) |
| `timeseries/troute.parquet` | Parquet | `outputs/troute/*.nc`, variables on (feature_id, time); `location_id` is `wb-<feature_id>` |
| `timeseries/forcings.parquet` | Parquet | `forcings/forcings.nc` (catchment averages) |
| `timeseries/{catchment,troute,forcings}.zarr` | Zarr v3, zstd | The same values as the Parquet files, as one `(location_id, time)` float32 array per variable with its `units`; chunks of up to 512 locations and about 1 MiB. Nexus flow is Parquet only (t-route's output holds the routed flow). |
| `hydrofabric/<layer>.parquet` | GeoParquet / Parquet | Every layer of the subset gpkg |
| `gridded/forcings.zarr` | Zarr v3, zstd | `forcings/raw_gridded_data.nc`, CF `grid_mapping` with NWM's LCC on a 6,370,000 m sphere; chunks up to 256 x 256 cells and about 1 MiB |
| `gridded/cog/<variable>_mean.tif`, `precip_rate_total.tif` | COG, zstd | One band each: every forcing variable's mean over the run, and the precipitation total in mm (from `precip_rate` in `mm s^-1` x the time step). A cell with a missing hour is NaN. The hourly grids are in `forcings.zarr`. |
| `run/` | as is | What a rerun needs, copied byte for byte: `config/` (realization, `troute.yaml`, the gpkg, `cat_config/`), `forcings/forcings.nc` and `partitions_*.json`. `cng-to-ngen` turns it back into a run folder. A run folder with a symlink, FIFO or other special file under `config/` or `forcings/` is refused before anything is converted (those files would be copied or read as they are); a run that converts but can't be rebuilt (e.g. a file name outside `A-Z a-z 0-9 . _ -`) gets no `run/`, and `not_converted` says why. The gpkg and forcings are also in the cloud-native files above, but those conversions don't keep every column and attribute ngen reads. |
| `manifest.json` | JSON | Manifest 0.4: `format: ngen-cng`, `run_metadata.txt`, SHA-256 of the inputs, each output with per-variable count/min/max, what was not converted, the hydrofabric's `bbox` in WGS84 degrees and the time series' `start_datetime`/`end_datetime` (UTC), and `rerun` (the files under `run/` with their SHA-256). hydrowf-ogc builds the job's STAC Item from it. |

- Time series use TEEHR's secondary timeseries schema, taken from the teehr library at image build:
  the first Docker stage installs `teehr==${TEEHR_VERSION}` (default 0.8.0) and `export_teehr_schema.py`
  writes `secondary_timeseries_schema(type="arrow")` to `/app/teehr_secondary_timeseries.arrow` (and
  `location_crosswalks_schema` to `/app/teehr_location_crosswalks.arrow`, for teehr-timeseries). teehr
  (and pyspark) are not in the final image. To use another teehr version:
  `docker build --build-arg TEEHR_VERSION=<version> ...`. Rows are sorted by
  `location_id, variable_name, value_time`. Missing values are dropped. `variable_name` is the
  model's own name (e.g. `Q_OUT`, `flow`); `teehr-timeseries` maps t-route's flow to TEEHR's names.
- Catchment units: from each variable's `units` in `cat_output.nc` (the model's BMI units; `unknown` when the model reports none).
  ngen writes no units in the catchment CSVs, so from CSVs every catchment variable gets `unknown`.
  To get the NetCDF output, set `"output": {"root": "./outputs/ngen/", "catchment": {"format": "netcdf", "grouping": "per_formulation"}}`
  in the realization (needs an ngen with CIROH-UA/ngen#49).
- Hydrofabric tables use icefabric's v2.2 schemas: `icefabric_hydrofabric.py` is vendored unchanged from
  NGWPC/icefabric at commit 9bcff38 (BSD-2-Clause, `LICENSE.icefabric`). Columns the community gpkg lacks
  (`divide-attributes.glacier_percent`) are null; `hydrolocations` has no geometry in that schema.
- SUMMA's `outputs/summa/` is listed in the manifest as not converted.
- Refused before converting, in either format: a `--configuration-name` TEEHR uses for its own data
  (`usgs_observations`, `nwm30_retrospective`). In a pipeline the run has happened by then: the name is to be
  checked when the job is submitted, in hydrowf-ogc's registry.
- Image: local `hydrowf/ngiab-to-cng:0.4.1` built from `Dockerfile`; dependencies pinned in `requirements.txt`
  (from `requirements.in` with `uv pip compile`).

### teehr-timeseries

| Path | Format | Contents |
|---|---|---|
| `timeseries/secondary.parquet` | Parquet | t-route's `flow` at every flowpath whose `flowpath-attributes.gage` is set, in TEEHR's secondary timeseries schema and names: `location_id` `ngen-<n>` (flowpath `wb-<n>`, as CIROH's ngiab-teehr names it), `variable_name` `streamflow_hourly_inst`, `unit_name` `m^3/s`, `configuration_name` from `--configuration-name` |
| `crosswalk.parquet` | Parquet | `secondary_location_id` (`ngen-<n>`) -> `primary_location_id` (`usgs-<site>`): TEEHR's location crosswalk. Where a hydrofabric lists several gages on a flowpath (`01031510,01031500`), the first |
| `manifest.json` | JSON | `format: teehr-timeseries`, the gaged flowpaths' `bbox` (WGS84) and the period, `teehr` (schema version, configuration, variable and unit names), the inputs' SHA-256 |

- One gage on several flowpaths: one series per gage (two would be pooled into its metrics). Among the
  flowpaths t-route wrote flow for, the one flowing into the gage's nexus (`toid == gage_nex_id`), else the
  first by id; the others are listed in `not_converted`. Flowpath ids other than `wb-<n>` are left out.
- Missing flow values are dropped; a gaged flowpath with none left gets no crosswalk row.
- Refused, with the reason: no `flowpath-attributes` layer or no `id`/`gage` column; no t-route netCDF; no
  `flow` variable, or one not on `(feature_id, time)`; flow in a unit it doesn't map (`m3 s-1`, `m3/s`,
  `m^3/s` are); a t-route time axis with a step other than one hour (the variable is hourly; a missing
  value is not a different step).
- A run with no gaged flowpath writes both files empty and says so in `not_converted`.
- `tests/teehr-timeseries.sh` checks it in containers, including that teehr 0.8.0 loads the output.

TODO: measure RAM on a large run; publish the image.
