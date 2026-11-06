# ngiab-preprocess

Subsets the v2.2 hydrofabric upstream of a catchment or gage, builds forcings
(NWM 3.0 retrospective or AORC) and writes the ngen realization for a model.

- Image: `awiciroh/preprocessor` pinned by digest (v4.9.4), built from
  https://github.com/CIROH-UA/NGIAB_data_preprocess/blob/main/aws_tools/aws.dockerfile
- Inputs: catchment or gage ID, start and end dates, optional model, and the CONUS
  hydrofabric (`conus_nextgen.gpkg`, 4.9 GB) plus its graph (`conus_igraph_network.gpickle`)
- Output `ngen_run`: an NGIAB run folder (`config/`, `forcings/`, `metadata/`)
- Needs network access: forcings come from `s3://noaa-nwm-retrospective-3-0-pds`
  or `s3://noaa-nws-aorc-v1-1-1km` (public, us-east-1)

The hydrofabric is staged at `~/.ngiab/hydrofabric/v2.2/`, where the code reads it, and
an empty `no_update` file stops the update prompt. The runner must set HOME to the
output directory (cwltool does).

TODO: measure cores and RAM on a real run.
