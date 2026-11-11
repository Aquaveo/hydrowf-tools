#!/usr/bin/env bash
# Copies an NGIAB run folder, calibrates the copy with ngiab-cal + ngen-cal and writes the
# calibrated model_params into its config/realization.json.
# Usage: ngiab_calibrate.sh <run dir> <output dir> <gage id> <iterations> <warmup days> <calibration ratio>
set -euo pipefail
src=$(cd "$1" && pwd); gage=${3#gage-}; iterations=$4; warmup=$5; ratio=$6

# The input may be read-only (cwltool) and the output path is fixed by the caller (an exact
# CWL glob / Argo artifact path), so copy here instead of staging with a renamed entry.
[ -e "$2" ] && { echo "ngiab_calibrate: $2 already exists" >&2; exit 1; }
cp -R "$src" "$2"
run=$(cd "$2" && pwd)

# ngiab-cal and ngen-cal use the fixed path /ngen/ngen/data (ngiab-cal __main__.py:50,
# ngiab_cal_template.yaml workdir). In this image /ngen/ngen/data -> /tmp/ngiab-data.
ln -sfn "$run" /tmp/ngiab-data

# 1. Setup: USGS obs, crosswalk, calibration/realization.json, ngen_cal_conf.yaml.
#    -g and -f avoid ngiab-cal's prompts (__main__.py:181, :303).
/opt/ngiab-cal/bin/ngiab-cal /ngen/ngen/data -g "$gage" -f -i "$iterations" -w "$warmup" --calibration_ratio "$ratio"

# 2. Calibration (DDS, KGE) then validation: /calibration/run.sh = calibrate.sh && validate.sh
/calibration/run.sh

calibrated=$run/calibration/Output/Validation_Run/realization.json
[ -f "$calibrated" ] || { echo "ngiab_calibrate: no $calibrated; calibration failed" >&2; exit 1; }

# 3. Apply: without -f ngiab-cal keeps the config and runs copy_best_params (__main__.py:328-330),
#    which copies model_params into config/realization.json (old file kept as realization._old).
/opt/ngiab-cal/bin/ngiab-cal /ngen/ngen/data -g "$gage"
grep -q '"model_params"' "$run/config/realization.json" || { echo "ngiab_calibrate: model_params not applied" >&2; exit 1; }
