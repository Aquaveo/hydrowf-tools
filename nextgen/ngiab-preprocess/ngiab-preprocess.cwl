#!/usr/bin/env cwl-runner
# Wraps the `cli` entry point of https://github.com/CIROH-UA/NGIAB_data_preprocess
# (modules/ngiab_data_cli/__main__.py). Subset, forcings and realization only;
# running NextGen is a separate tool (ngiab-run), so --run/--eval/--vis are not exposed.
cwlVersion: v1.2
class: CommandLineTool
id: ngiab-preprocess
label: NGIAB data preprocess
doc: |
  Subsets the v2.2 hydrofabric upstream of a catchment or gage, builds forcings
  (NWM 3.0 retrospective or AORC) and writes an ngen realization for the chosen
  model. The output is an NGIAB run folder (config/, forcings/, metadata/).

$namespaces:
  hydrowf: https://github.com/Aquaveo/hydrowf-tools/tree/main/hints#

requirements:
  DockerRequirement:
      # Built from ./Dockerfile: Aquaveo/NGIAB_data_preprocess@02c4145 (upstream 4088447 + NGIAB_data_preprocess#273
    # run-relative SNOW17/SAC-SMA paths + #275 SNOW17 raim coupling). `cli` is on PATH.
    dockerPull: hydrowf/ngiab-preprocess:4.9.5.dev2-02c4145
  NetworkAccess:
    networkAccess: true          # forcings read s3://noaa-nwm-retrospective-3-0-pds or s3://noaa-nws-aorc-v1-1-1km
  InitialWorkDirRequirement:
    # cwltool sets HOME to the output dir. FilePaths reads the hydrofabric from the fixed
    # path ~/.ngiab/hydrofabric/v2.2/ (data_processing/file_paths.py:15), so stage it there.
    # `no_update` stops validate_hydrofabric() from prompting (source_validation.py:192).
    listing:
      - entry: $(inputs.hydrofabric)
        entryname: .ngiab/hydrofabric/v2.2/conus_nextgen.gpkg
      - entry: $(inputs.hydrofabric_graph)
        entryname: .ngiab/hydrofabric/v2.2/conus_igraph_network.gpickle
      - entry: ""
        entryname: .ngiab/hydrofabric/v2.2/no_update
  ResourceRequirement:
    coresMin: 4        # placeholder: forcings use dask
    ramMin: 16384      # placeholder: measure on a real run

baseCommand: [cli]

arguments:
  # Writing ~/.ngiab/preprocessor first means validate_output_dir() never prompts
  # (__main__.py:156, source_validation.py:263).
  - prefix: --output_root
    valueFrom: $(runtime.outdir)
  # An absolute -o path is used as is (file_paths.py:71).
  - prefix: -o
    valueFrom: $(runtime.outdir)/$(inputs.run_name)
  - -s
  - -f
  - -r

inputs:
  feature:
    type: string
    label: Catchment or gage
    doc: A catchment ID (cat-5173) or a gage ID (gage-01646500); the prefix picks the mode.
    inputBinding: {prefix: -i}
  start_date:
    type: string
    label: Start (YYYY-MM-DD or "YYYY-MM-DD HH:MM")
    inputBinding: {prefix: --start_date}
  end_date:
    type: string
    label: End (YYYY-MM-DD or "YYYY-MM-DD HH:MM")
    inputBinding: {prefix: --end_date}
  model:
    type:
      - "null"
      - type: enum
        symbols: [lstm, lstm_rust, dhbv2, dhbv2_daily, summa, snow17, sacsma]
    label: Model (empty = CFE + NOAH-OWP)
    doc: Each value maps to the CLI flag of the same name (arguments.py:124-160).
    inputBinding: {valueFrom: --$(self)}
  source:
    type:
      type: enum
      symbols: [nwm, aorc]
    default: nwm
    label: Forcing source
    inputBinding: {prefix: --source}
  subset_type:
    type:
      type: enum
      symbols: [nexus, catchment]
    default: nexus
    label: Subset by
    inputBinding: {prefix: --subset_type}
  nwm_gw:
    type: boolean
    default: false
    label: Initial groundwater from NWM retrospective (CFE)
    inputBinding: {prefix: --nwm_gw}
  precip_max_gap:
    type: int
    default: 6
    label: Longest precipitation gap to interpolate (time steps)
    inputBinding: {prefix: --precip_max_gap}
  run_name:
    type: string
    default: ngen-run
    label: Run folder name
  hydrofabric:
    type: File
    label: CONUS hydrofabric v2.2 (conus_nextgen.gpkg)
    doc: The community hydrofabric, or an icefabric v2.2 export with the same layers.
  hydrofabric_graph:
    type: File
    label: Hydrofabric network graph (conus_igraph_network.gpickle)

outputs:
  ngen_run:
    type: Directory
    label: NextGen run folder
    outputBinding:
      glob: $(inputs.run_name)
    hydrowf:port: ngen.run

hints:
  - class: hydrowf:UI
    category: NextGen
    icon: database
