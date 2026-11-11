#!/usr/bin/env cwl-runner
# Calibration pipeline: preprocess -> calibrate (ngiab-cal / ngen-cal) -> run -> cloud-native files.
cwlVersion: v1.2
class: Workflow
id: ngiab-calibration
label: NextGen calibration
doc: |
  Preprocesses a gage (CFE + Noah-OWP-Modular, the only formulation ngiab-cal calibrates),
  calibrates it against the gage's USGS observations, runs it with the calibrated
  parameters and converts the run to cloud-native files (<run>_calibrated_cng).
  Use at least 2 years (warm-up + calibration + validation).

inputs:
  feature: {type: string, doc: "e.g. gage-01031510"}
  gage: {type: string, doc: "USGS gage ID used for calibration, e.g. 01031510"}
  start_date: string
  end_date: string
  run_name: {type: string, default: ngen-run}
  hydrofabric: File
  hydrofabric_graph: File
  iterations: {type: int, default: 100}
  warmup_days: {type: int, default: 365}
  calibration_ratio: {type: float, default: 0.5}
  configuration_name: {type: string, default: ngiab_cfe_calibrated}

steps:
  preprocess:
    run: ../nextgen/ngiab-preprocess/ngiab-preprocess.cwl
    in:
      feature: feature
      start_date: start_date
      end_date: end_date
      run_name: run_name
      hydrofabric: hydrofabric
      hydrofabric_graph: hydrofabric_graph
    out: [ngen_run]
  calibrate:
    run: ../nextgen/ngiab-calibrate/ngiab-calibrate.cwl
    in:
      ngen_run: preprocess/ngen_run
      gage: gage
      iterations: iterations
      warmup_days: warmup_days
      calibration_ratio: calibration_ratio
    out: [ngen_run]
  run:
    run: ../nextgen/ngiab-run/ngiab-run.cwl
    in: {ngen_run: calibrate/ngen_run}
    out: [ngen_run]
  to_cng:
    run: ../nextgen/ngiab-to-cng/ngiab-to-cng.cwl
    in:
      ngen_run: run/ngen_run
      configuration_name: configuration_name
    out: [cng]

outputs:
  ngen_run: {type: Directory, outputSource: run/ngen_run}
  cng: {type: Directory, outputSource: to_cng/cng}
