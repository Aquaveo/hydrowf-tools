#!/usr/bin/env cwl-runner
# Ported from FlowForge: tethysapp/flowforge/consumers/templates/ngiab-teehr.yaml
# Container source: https://github.com/CIROH-UA/ngiab-teehr
cwlVersion: v1.2
class: CommandLineTool
id: ngiab-teehr
label: TEEHR evaluation
doc: |
  Evaluates a NextGen In A Box (NGIAB) run with TEEHR against USGS observations
  and the NWM 3.0 retrospective, computing RMSDR, relative bias, NSE and KGE.
  Reads the run folder's config/, hydrofabric and outputs/troute/, and writes a
  TEEHR evaluation directory (including the ngen_metrics table).

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
    dockerPull: awiciroh/ngiab-teehr:x86   # TODO: pin a version tag or digest
    dockerOutputDirectory: /cwl-output   # fixed path, so --cachedir keys repeat (cwltool otherwise picks a random one per run)
  NetworkAccess:
    networkAccess: true                     # TEEHR downloads USGS and NWM data
  InitialWorkDirRequirement:
    listing:
      # teehr_ngen.py reads the run from ./data (NGEN_OUTPUT_DIR = Path("data"))
      - entry: $(inputs.ngen_run)
        entryname: data
  ResourceRequirement:
    coresMin: 2      # placeholder: measure on a real run
    ramMin: 8192     # placeholder: TEEHR uses Spark (Java)

# /entrypoint.sh adds a passwd entry for the runtime UID, which Java needs
baseCommand: [/entrypoint.sh, python, /app/teehr_ngen.py]

arguments:
  - prefix: --data_folder_stem
    valueFrom: $(inputs.ngen_run.basename)
  - prefix: --teehr_evaluation_dir
    valueFrom: $(runtime.outdir)/teehr

inputs:
  ngen_run:
    type: Directory
    loadListing: deep_listing   # list the files, so the --cachedir key changes when the contents do
    label: NextGen run
    doc: NGIAB run folder (config/, hydrofabric, outputs/troute/) produced by ngiab-run.
    hydrowf:port: ngen.run

outputs:
  teehr_evaluation:
    type: Directory
    label: TEEHR evaluation
    doc: TEEHR evaluation directory, including the ngen_metrics table.
    outputBinding:
      glob: teehr
    hydrowf:port: teehr.evaluation

hints:
  - class: hydrowf:UI
    category: NextGen
    icon: chart
  - class: hydrowf:Publish
    output: teehr_evaluation
    target: parquet
    table: timeseries.ngen_metrics
