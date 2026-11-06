# Temporary: upstream awiciroh/preprocessor is missing package data (no git in its build stage).
# Same base as aws_tools/aws.dockerfile, but installs the PyPI wheel. Drop once upstream is fixed.
FROM amazonlinux:2023 AS build
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /bin/
RUN dnf -y install python3.11 python3.11-devel cmake gcc gcc-c++ make geos geos-devel
WORKDIR /app
RUN uv venv -p /usr/bin/python3.11 \
    && echo "scikit-build-core<0.10" > /tmp/build-constraints.txt \
    && VIRTUAL_ENV=/app/.venv uv pip install ngiab_data_preprocess==4.9.4 \
       --build-constraint /tmp/build-constraints.txt

FROM amazonlinux:2023
RUN dnf -y install python3.11 && dnf clean all && rm -rf /var/cache/dnf
COPY --from=build /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
