# Temporary: upstream awiciroh/preprocessor is missing package data (no git in its build stage).
# Same base as aws_tools/aws.dockerfile, but installs from git so open upstream fixes can be pinned.
# Aquaveo/NGIAB_data_preprocess@02c4145 (branch hydrowf-combined): upstream main 4088447 (has #270, dhbv2_daily
# template typo) plus NGIAB_data_preprocess#273 (run-relative SNOW17/SAC-SMA parameter paths) and #275 (SNOW17
# rain plus melt into CFE and SAC-SMA). git is needed: setuptools-scm
# collects the package data (templates) from git. Installed from git the version reads 0.0.0 (upstream
# only sets it in its PyPI publish workflow); the image tag carries it instead.
FROM amazonlinux:2023 AS build
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /bin/
RUN dnf -y install python3.11 python3.11-devel cmake gcc gcc-c++ make geos geos-devel git
WORKDIR /app
ARG NGIAB_PREPROCESS_REF=02c4145a7edcda97fb4cbefb4f92996c5bfd3f40
RUN uv venv -p /usr/bin/python3.11 \
    && echo "scikit-build-core<0.10" > /tmp/build-constraints.txt \
    && VIRTUAL_ENV=/app/.venv uv pip install \
       "ngiab_data_preprocess @ git+https://github.com/Aquaveo/NGIAB_data_preprocess@${NGIAB_PREPROCESS_REF}" \
       --build-constraint /tmp/build-constraints.txt

FROM amazonlinux:2023
RUN dnf -y install python3.11 && dnf clean all && rm -rf /var/cache/dnf
COPY --from=build /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
