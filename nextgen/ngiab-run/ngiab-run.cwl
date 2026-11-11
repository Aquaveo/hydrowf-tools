#!/usr/bin/env cwl-runner
# Runs NextGen in the NGIAB image (https://github.com/CIROH-UA/NGIAB-CloudInfra).
# The image's ENTRYPOINT is /ngen/HelloNGEN.sh (docker/Dockerfile:292). Its "auto" mode
# (HelloNGEN.sh:67-93) finds the gpkg and realization, builds partitions and runs
# ngen-parallel with no prompts. Same call the preprocessor's --run makes
# (NGIAB_data_preprocess __main__.py:279): <run dir> auto <procs> local
cwlVersion: v1.2
class: CommandLineTool
id: ngiab-run
label: NextGen run (NGIAB)
doc: |
  Runs the NextGen framework (ngen + t-route) on an NGIAB run folder and returns
  the same folder with outputs/ngen and outputs/troute filled in.

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
    # v2.1.0 (Oct 28 2026), amd64 + arm64
    dockerPull: awiciroh/ciroh-ngen-image@sha256:d5ee1a6c15c025f9be2f9ce140dd9cdc2e933bc30f531a41f180d45b15c8ab17
    dockerOutputDirectory: /cwl-output   # fixed path, so --cachedir keys repeat (cwltool otherwise picks a random one per run)
  InitialWorkDirRequirement:
    listing:
      # ngen writes outputs/ and partitions_*.json inside the run folder, so stage a writable copy
      - entry: $(inputs.ngen_run)
        writable: true
  ResourceRequirement:
    coresMin: 4        # placeholder; becomes the MPI process count
    ramMin: 2048       # placeholder: measure on a real run

# No baseCommand: the arguments go to the image's ENTRYPOINT (HelloNGEN.sh).
arguments:
  - $(runtime.outdir)/$(inputs.ngen_run.basename)
  - auto
  - $(runtime.cores)
  - local

inputs:
  ngen_run:
    type: Directory
    loadListing: deep_listing   # list the files, so the --cachedir key changes when the contents do
    label: NextGen run folder
    doc: From ngiab-preprocess (config/ with one *.gpkg and one *realization*.json, forcings/).
    hydrowf:port: ngen.run

outputs:
  ngen_run:
    type: Directory
    label: NextGen run folder with outputs
    outputBinding:
      glob: $(inputs.ngen_run.basename)
    hydrowf:port: ngen.run

hints:
  - class: hydrowf:UI
    category: NextGen
    icon: play
