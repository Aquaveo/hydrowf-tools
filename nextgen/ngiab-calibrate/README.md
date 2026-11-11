# ngiab-calibrate

Calibrates an NGIAB run folder against one USGS gage with
[ngiab-cal](https://github.com/CIROH-UA/ngiab-cal) and
[ngen-cal](https://github.com/CIROH-UA/ngen-cal/tree/ngiab_cal), and returns it as
`<run>_calibrated` with the calibrated parameters in `config/realization.json`.

`ngiab_calibrate.sh` does what `ngiab-cal <run> -g <gage> --run` does, without starting Docker itself:

1. `ngiab-cal <run> -g <gage> -f -i <iterations> -w <warmup> --calibration_ratio <ratio>`: downloads the
   USGS observations and writes `calibration/` (ngen-cal config, crosswalk, realization and t-route copies).
2. `/calibration/run.sh`: ngen-cal's calibration (DDS, KGE), then validation with the best parameters.
3. `ngiab-cal <run> -g <gage>`: copies the best `model_params` into `config/realization.json`
   (the original is kept as `realization._old`).

- Calibrates CFE and Noah-OWP-Modular only (preprocess with the default formulation), with one
  value per parameter for all catchments (`strategy: uniform`). ngen applies `model_params` after
  each model's init, so they replace the per-catchment values in `config/cat_config/`.
- Needs network access (USGS) and at least 2 years: the default warm-up is 365 days, then the
  rest is split between calibration and validation (`calibration_ratio`, default 0.5).
- ngiab-cal and ngen-cal use the fixed path `/ngen/ngen/data`. In the image it is a symlink to
  `/tmp/ngiab-data`, which the script points at the staged run folder.
- Each iteration is a full ngen + t-route run with `mpirun -n $(nproc)`. 2 years of gage-01031510
  (10 catchments) take about 25 s per iteration.
- Image: local `hydrowf/ngiab-calibrate:0.1.0` built from `Dockerfile`, on the same NGIAB v2.1.0
  image as ngiab-run. It pins ngen-cal (`NGEN_CAL_REF`) and ngiab-cal (`NGIAB_CAL_REF`) by commit,
  with workarounds for CIROH-UA/ngen-cal#16 and #17 and CIROH-UA/ngiab-cal#11 (see the Dockerfile).
- ngiab-cal downloads observations with hydrotools' NWIS client, which says the USGS NWIS API
  will be shut down in early 2027.

TODO: measure RAM on a large run; publish the image; drop the workarounds when the upstream fixes are released.
