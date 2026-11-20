# cng-to-ngen

Turns an ngiab-to-cng output (0.3.0 or later) back into an NGIAB run folder that ngiab-run can run
again, for example to rerun a job whose native run folder is gone.

ngiab-to-cng keeps what a rerun needs under `run/`, copied byte for byte, and lists each file with its
SHA-256 in `manifest.json` (`rerun`). This tool copies those files back, checks every hash, and creates
the empty `outputs/ngen` and `outputs/troute`. Nothing is converted: the cloud-native files (GeoParquet,
Zarr) don't keep every column and attribute ngen reads, so the rerun uses the original files.

| Path | Contents |
|---|---|
| `config/` | `realization.json`, `troute.yaml`, the subset gpkg, `cat_config/` |
| `forcings/forcings.nc` | the catchment forcings ngen reads |
| `partitions_*.json` | the MPI partitions |
| `outputs/ngen/`, `outputs/troute/` | empty, for the rerun |

- Refuses an output without `rerun` (ngiab-to-cng before 0.3.0, or a run it couldn't keep: see the
  manifest's `not_converted`), a path that isn't a plain relative path or is listed twice or would be a
  folder of another, a missing or symlinked file, a file that doesn't match its hash, and an output
  folder that isn't new or empty. A refused rebuild leaves no partial folder behind.
- Image: local `hydrowf/cng-to-ngen:0.1.0` built from `Dockerfile` (Python's standard library only).
- `tests/round-trip.sh` proves the round trip: the test run folder -> ngiab-to-cng -> cng-to-ngen ->
  ngiab-run gives identical t-route flow to ngiab-run on the original folder, and checks every refusal
  gives its reason.
