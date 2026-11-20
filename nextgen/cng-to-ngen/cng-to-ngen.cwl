#!/usr/bin/env cwl-runner
# Turns an ngiab-to-cng output back into an NGIAB run folder. Script: cng_to_ngen.py
cwlVersion: v1.2
class: CommandLineTool
id: cng-to-ngen
label: Cloud-native files back to an NGIAB run folder
doc: |
  Writes ngen-run/ from an ngiab-to-cng output (0.3.0 or later): the files its manifest lists under
  `rerun` (config/, forcings/forcings.nc, partitions_*.json), copied byte for byte and checked against
  their SHA-256, plus empty outputs/ngen and outputs/troute. ngiab-run can run the folder again.

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
    # Local image built from Dockerfile in this folder
    dockerPull: hydrowf/cng-to-ngen:0.1.0
    dockerOutputDirectory: /cwl-output   # fixed path, so --cachedir keys repeat
  ResourceRequirement:
    coresMin: 1
    ramMin: 256

# No baseCommand: the arguments go to the image's ENTRYPOINT (python /app/cng_to_ngen.py).
arguments:
  - prefix: --output
    valueFrom: $(runtime.outdir)/ngen-run

inputs:
  cng:
    type: Directory
    loadListing: deep_listing
    label: ngiab-to-cng output
    doc: From ngiab-to-cng 0.3.0 or later (manifest.json with `rerun`, run/).
    inputBinding: {position: 1}
    hydrowf:port: ngen.cng

outputs:
  ngen_run:
    type: Directory
    label: NextGen run folder, ready to run
    outputBinding:
      glob: ngen-run
    hydrowf:port: ngen.run

hints:
  - class: hydrowf:UI
    category: NextGen
    icon: refresh
