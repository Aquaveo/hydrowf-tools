#!/usr/bin/env cwl-runner
# Simulation pipeline: preprocess -> run -> cloud-native files.
cwlVersion: v1.2
class: Workflow
id: ngiab-simulation
label: NextGen simulation
doc: |
  Preprocesses a feature, runs NextGen with the preprocessor's parameters and
  converts the run to cloud-native files (<run>_cng).

inputs:
  feature: {type: string, doc: "e.g. gage-01031510"}
  start_date: string
  end_date: string
  run_name: {type: string, default: ngen-run}
  hydrofabric: File
  hydrofabric_graph: File
  configuration_name: {type: string, default: ngiab_cfe_default}

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
  run:
    run: ../nextgen/ngiab-run/ngiab-run.cwl
    in: {ngen_run: preprocess/ngen_run}
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
