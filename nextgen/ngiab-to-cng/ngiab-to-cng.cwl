#!/usr/bin/env cwl-runner
# Converts a finished NGIAB run folder into cloud-native files. Script: ngiab_to_cng.py
cwlVersion: v1.2
class: CommandLineTool
id: ngiab-to-cng
label: NGIAB run to cloud-native files
doc: |
  Writes a cng/ folder from an NGIAB run folder:
  - timeseries/*.parquet: catchment, nexus, t-route and forcing time series in the
    TEEHR 0.8 secondary timeseries schema; timeseries/*.zarr: the same values as
    (location_id, time) arrays
  - hydrofabric/*.parquet: the subset gpkg layers in icefabric's v2.2 schemas
    (geometry as WKB, with GeoParquet metadata)
  - gridded/forcings.zarr: forcings/raw_gridded_data.nc; gridded/cog/: one-band COGs with each
    variable's mean over the run and the precipitation total
  - manifest.json: run metadata, input hashes, outputs and what was not converted

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
    # Local image built from Dockerfile in this folder
    dockerPull: hydrowf/ngiab-to-cng:0.1.0
  ResourceRequirement:
    coresMin: 1
    ramMin: 2048       # placeholder: measure on a large run

# No baseCommand: the arguments go to the image's ENTRYPOINT (python /app/ngiab_to_cng.py).
arguments:
  - prefix: --output
    valueFrom: $(runtime.outdir)/cng

inputs:
  ngen_run:
    type: Directory
    label: NextGen run folder with outputs
    doc: From ngiab-run (config/, forcings/, outputs/ngen, outputs/troute).
    inputBinding: {position: 1}
    hydrowf:port: ngen.run
  run_id:
    type: string?
    label: Run ID (empty = run folder name)
    inputBinding: {prefix: --run-id}
  configuration_name:
    type: string
    default: ngiab
    label: TEEHR configuration name
    inputBinding: {prefix: --configuration-name}

outputs:
  cng:
    type: Directory
    label: Cloud-native run outputs
    outputBinding:
      glob: cng
    hydrowf:port: ngen.cng

hints:
  - class: hydrowf:UI
    category: NextGen
    icon: cloud
