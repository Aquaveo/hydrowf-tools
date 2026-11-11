#!/usr/bin/env cwl-runner
# Calibrates an NGIAB run folder with ngiab-cal (https://github.com/CIROH-UA/ngiab-cal) and
# ngen-cal (https://github.com/CIROH-UA/ngen-cal, ngiab_cal branch). Script: ngiab_calibrate.sh
cwlVersion: v1.2
class: CommandLineTool
id: ngiab-calibrate
label: NextGen calibration (ngiab-cal)
doc: |
  Calibrates CFE and Noah-OWP-Modular parameters against one USGS gage (DDS search, KGE,
  one value for all catchments) and returns the run folder as <run>_calibrated, with the
  calibrated model_params in config/realization.json (the original kept as realization._old)
  and a calibration/ folder (config, observations, logs, plots, per-iteration scores).
  The realization's time range sets the periods: warm-up, then calibration and validation.
  Use at least 2 years.

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
    # Local image built from Dockerfile in this folder
    dockerPull: hydrowf/ngiab-calibrate:0.2.0
    dockerOutputDirectory: /cwl-output   # fixed path, so --cachedir keys repeat (cwltool otherwise picks a random one per run)
  NetworkAccess:
    networkAccess: true   # USGS observations
  ResourceRequirement:
    coresMin: 4           # mpi-ngen runs mpirun -n $(nproc) with partitions, each iteration
    ramMin: 4096          # placeholder: measure on a large run

# No baseCommand: the arguments go to the image's ENTRYPOINT (ngiab_calibrate.sh), which copies
# the input run folder to <run>_calibrated in the output dir and calibrates the copy.
arguments:
  - position: 1
    valueFrom: $(runtime.outdir)/$(inputs.ngen_run.basename)_calibrated

inputs:
  ngen_run:
    type: Directory
    loadListing: deep_listing   # list the files, so the --cachedir key changes when the contents do
    label: NextGen run folder (CFE + Noah-OWP-Modular)
    doc: From ngiab-preprocess with the default formulation (no model input).
    inputBinding: {position: 0}
    hydrowf:port: ngen.run
  gage:
    type: string
    label: USGS gage ID
    doc: For example 01031510 or gage-01031510. Must be in the subset's flowpath-attributes.
    inputBinding: {position: 2}
  iterations:
    type: int
    default: 100
    label: DDS iterations
    inputBinding: {position: 3}
  warmup_days:
    type: int
    default: 365
    label: Warm-up days excluded from the objective
    inputBinding: {position: 4}
  calibration_ratio:
    type: float
    default: 0.5
    label: Share of the period after warm-up used for calibration (the rest is validation)
    inputBinding: {position: 5}

outputs:
  ngen_run:
    type: Directory
    label: Calibrated NextGen run folder (<run>_calibrated)
    outputBinding:
      glob: $(inputs.ngen_run.basename)_calibrated
    hydrowf:port: ngen.run

hints:
  - class: hydrowf:UI
    category: NextGen
    icon: tune
