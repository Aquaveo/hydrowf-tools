# ngiab-to-cng

Converts a finished NGIAB run folder (from ngiab-run) into cloud-native files. It writes `cng/`:

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
| `manifest.json` | JSON | `run_metadata.txt`, SHA-256 of the inputs, each output with per-variable count/min/max, and what was not converted |

- Time series use TEEHR's secondary timeseries schema, taken from the teehr library at image build:
  the first Docker stage installs `teehr==${TEEHR_VERSION}` (default 0.8.0) and `export_teehr_schema.py`
  writes `secondary_timeseries_schema(type="arrow")` to `/app/teehr_secondary_timeseries.arrow`. teehr
  (and pyspark) are not in the final image. To use another teehr version:
  `docker build --build-arg TEEHR_VERSION=<version> ...`. Rows are sorted by
  `location_id, variable_name, value_time`. Missing values are dropped. `variable_name` is the
  model's own name (e.g. `Q_OUT`, `flow`); mapping to TEEHR variable names is not done yet.
- Catchment units: from each variable's `units` in `cat_output.nc` (the model's BMI units; `unknown` when the model reports none).
  ngen writes no units in the catchment CSVs, so from CSVs every catchment variable gets `unknown`.
  To get the NetCDF output, set `"output": {"root": "./outputs/ngen/", "catchment": {"format": "netcdf", "grouping": "per_formulation"}}`
  in the realization (needs an ngen with CIROH-UA/ngen#49).
- Hydrofabric tables use icefabric's v2.2 schemas: `icefabric_hydrofabric.py` is vendored unchanged from
  NGWPC/icefabric at commit 9bcff38 (BSD-2-Clause, `LICENSE.icefabric`). Columns the community gpkg lacks
  (`divide-attributes.glacier_percent`) are null; `hydrolocations` has no geometry in that schema.
- SUMMA's `outputs/summa/` is listed in the manifest as not converted.
- Image: local `hydrowf/ngiab-to-cng:0.1.0` built from `Dockerfile`; dependencies pinned in `requirements.txt`
  (from `requirements.in` with `uv pip compile`).

TODO: measure RAM on a large run; publish the image.
