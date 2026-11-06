# ngiab-teehr

Evaluates an NGIAB run with TEEHR against USGS observations and the NWM 3.0
retrospective (RMSDR, relative bias, NSE, KGE).

- Image: `awiciroh/ngiab-teehr` (source: https://github.com/CIROH-UA/ngiab-teehr)
- Input `ngen_run`: an NGIAB run folder with `config/`, the hydrofabric and `outputs/troute/`
- Output `teehr_evaluation`: the TEEHR evaluation directory, including `ngen_metrics`
- Needs network access (downloads USGS and NWM data)

TODO: pin the image tag and measure cores and RAM on a real run.
