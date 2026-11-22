#!/usr/bin/env cwl-runner
# Evaluates a teehr-timeseries directory with TEEHR against USGS observations. Script: teehr_evaluate.py
cwlVersion: v1.2
class: CommandLineTool
id: teehr-evaluate
label: TEEHR evaluation against USGS observations
doc: |
  Reads a teehr-timeseries directory (any model's tool writes one; ngiab-to-cng --format teehr-timeseries
  for NextGen): the simulated series, a crosswalk to USGS gages and a manifest. Gets each gage's point from
  the USGS site service and its hourly observations, optionally the NWM 3.0 retrospective at the same gages
  (NOAA's public bucket), and writes evaluation/: metrics.parquet (a row per gage and configuration),
  locations.parquet (the gages) and manifest.json.

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
    # Local image built from Dockerfile in this folder
    dockerPull: hydrowf/teehr-evaluate:0.1.1
    dockerOutputDirectory: /cwl-output   # fixed path, so --cachedir keys repeat
  NetworkAccess:
    networkAccess: true                  # USGS and NOAA's public bucket
  ResourceRequirement:
    coresMin: 2
    ramMin: 4096       # Spark (Java); placeholder: measure on a large run

# No baseCommand: the arguments go to the image's ENTRYPOINT (/app/entrypoint.sh, then teehr_evaluate.py).
arguments:
  - prefix: --output
    valueFrom: $(runtime.outdir)/evaluation

inputs:
  timeseries:
    type: Directory
    loadListing: deep_listing
    label: teehr-timeseries directory
    doc: manifest.json (format teehr-timeseries), timeseries/secondary.parquet, crosswalk.parquet.
    inputBinding: {position: 1}
    hydrowf:port: teehr.timeseries
  metrics:
    type: string
    default: kge,nse,relative_bias,rmsdr
    label: Metrics
    doc: Comma-separated, from kge, kge_mod1, kge_mod2, nse, nnse, relative_bias, rmsdr, rmse, mae, pearson, r2, annual_peak_relative_bias.
    inputBinding: {prefix: --metrics}
  baseline:
    type:
      type: enum
      symbols: [none, nwm30_retrospective]
    default: none
    label: Baseline
    doc: nwm30_retrospective also evaluates the NWM 3.0 retrospective at the same gages (1979-02 to 2023-01).
    inputBinding: {prefix: --baseline}

outputs:
  evaluation:
    type: Directory
    label: TEEHR metrics
    outputBinding:
      glob: evaluation
    hydrowf:port: teehr.metrics

hints:
  - class: hydrowf:UI
    category: Evaluation
    icon: chart
