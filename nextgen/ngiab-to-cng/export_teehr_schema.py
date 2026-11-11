#!/usr/bin/env python3
"""Write TEEHR's secondary timeseries Arrow schema to a file, so ngiab_to_cng.py can use it
without installing teehr (which needs pyspark). Run at image build time (see Dockerfile)."""
import sys

import pyarrow as pa
import teehr
from teehr.models.pandera_dataframe_schemas import secondary_timeseries_schema

schema = secondary_timeseries_schema(type="arrow").with_metadata({"teehr_version": teehr.__version__})
with pa.OSFile(sys.argv[1], "wb") as f:
    f.write(schema.serialize())
print(f"teehr {teehr.__version__}: wrote {sys.argv[1]}\n{schema}")
