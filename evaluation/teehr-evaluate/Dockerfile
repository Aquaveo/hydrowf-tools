# teehr-evaluate: teehr 0.8.0 (pyspark, a JRE) with its Spark jars fetched at build, so a step needs the
# network for USGS and NOAA's public bucket only.
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /bin/
# Spark needs a JRE; the rasterio wheel (a teehr dependency) links to the system libexpat
# libnss-wrapper: a user name for a uid the image doesn't name (entrypoint.sh)
RUN apt-get update && apt-get install -y --no-install-recommends default-jre-headless libexpat1 libnss-wrapper \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN uv pip install --system --no-cache -r requirements.txt

# teehr resolves its Spark packages (Iceberg, Sedona, hadoop-aws, ...) from Maven on every session, through
# Ivy, into SPARK_JARS_IVY. Creating one evaluation here fills that cache; later sessions resolve from it
# offline. Ivy writes a resolution file there on every start, and a pod may run as any uid: so anyone may
# write it (nothing else in this image is writable, and the container holds no secret but its read keys).
# Ivy keeps each jar twice (cache/ and the retrieved copy in jars/, 1.2 GB each): jars/ becomes hardlinks to
# cache/, which Ivy leaves alone at run time (same size and time: up to date).
ENV SPARK_JARS_IVY=/opt/ivy
COPY dedupe_jars.py /tmp/
RUN python -c "from teehr import Evaluation; Evaluation(dir_path='/tmp/warm', create_dir=True)" \
    && rm -rf /tmp/warm && python /tmp/dedupe_jars.py /opt/ivy && rm /tmp/dedupe_jars.py \
    && chmod -R a+rwX /opt/ivy

# Spark and Java want a home and a user name for the runtime uid; HOME is /tmp (an emptyDir in a pod). The
# image runs as 1000 (named here); entrypoint.sh names any other uid a pod runs it as.
ENV HOME=/tmp
RUN useradd --uid 1000 --no-create-home --home-dir /tmp teehr
USER 1000
COPY teehr_evaluate.py entrypoint.sh /app/
ENTRYPOINT ["/app/entrypoint.sh", "python", "/app/teehr_evaluate.py"]
