# Stage 1: export TEEHR's timeseries schema from the teehr library itself.
# teehr needs pyspark, so it stays in this stage; only the schema file is copied out.
FROM python:3.12-slim AS teehr-schema
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /bin/
# The rasterio wheel (a teehr dependency) links to the system libexpat
RUN apt-get update && apt-get install -y --no-install-recommends libexpat1 && rm -rf /var/lib/apt/lists/*
ARG TEEHR_VERSION=0.8.0
RUN uv pip install --system --no-cache teehr==${TEEHR_VERSION}
COPY export_teehr_schema.py /tmp/
RUN python /tmp/export_teehr_schema.py /teehr_secondary_timeseries.arrow

# Stage 2: the tool
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /bin/
# The rasterio wheel links to the system libexpat, which the slim image doesn't have
RUN apt-get update && apt-get install -y --no-install-recommends libexpat1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN uv pip install --system --no-cache -r requirements.txt
COPY --from=teehr-schema /teehr_secondary_timeseries.arrow /app/
COPY ngiab_to_cng.py icefabric_hydrofabric.py LICENSE.icefabric /app/
ENTRYPOINT ["python", "/app/ngiab_to_cng.py"]
