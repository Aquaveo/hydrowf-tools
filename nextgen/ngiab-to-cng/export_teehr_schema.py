#!/usr/bin/env python3
"""Write TEEHR's secondary timeseries and location crosswalk Arrow schemas to files, so ngiab_to_cng.py can
use them without installing teehr (which needs pyspark). Run at image build time (see Dockerfile).

    export_teehr_schema.py <secondary timeseries schema file> <location crosswalk schema file>
"""
import sys

import pyarrow as pa
import teehr
from teehr.models.pandera_dataframe_schemas import location_crosswalks_schema, secondary_timeseries_schema

for build, path in ((secondary_timeseries_schema, sys.argv[1]), (location_crosswalks_schema, sys.argv[2])):
    schema = build(type="arrow").with_metadata({"teehr_version": teehr.__version__})
    with pa.OSFile(path, "wb") as f:
        f.write(schema.serialize())
    print(f"teehr {teehr.__version__}: wrote {path}\n{schema}")
