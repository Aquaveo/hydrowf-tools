# ngen-cal (CIROH-UA/ngen-cal, branch ngiab_cal) and the ngiab-cal setup CLI (CIROH-UA/ngiab-cal),
# on the same NGIAB image as ngiab-run, plus ngiab_calibrate.sh, which replaces ngiab-cal's own
# `docker run`. Follows ngen-cal's Dockerfile, with these workarounds (drop each when fixed upstream):
# - base pinned to NGIAB v2.1.0: awiciroh/ngiab-cal v0.2.0's Noah-OWP-Modular rejects
#   stomatal_resistance_option = 4, which the preprocessor writes (CIROH-UA/ngen-cal#17)
# - /calibration venv pinned to v0.2.0's versions: ngen-cal's setup.cfg drops install_requires
#   (CIROH-UA/ngen-cal#16)
# - ngiab-cal installed from its uv.lock: it needs six, which it doesn't declare (CIROH-UA/ngiab-cal#11)
FROM awiciroh/ciroh-ngen-image@sha256:d5ee1a6c15c025f9be2f9ce140dd9cdc2e933bc30f531a41f180d45b15c8ab17
ARG NGEN_CAL_REF=dedd81830b8b462bf5ca09c41b44d26fa35bd038
ARG NGIAB_CAL_REF=4859c7676a95e61fa1a472e24f805c04c7b02a0e
RUN dnf install -y git gcc-c++ make cmake python3-devel python3-pip && dnf clean all \
 && cp /root/.cargo/bin/uv /usr/local/bin/uv

# --- ngen-cal, as in its Dockerfile ---
RUN git init -q /tmp/ngen-cal && cd /tmp/ngen-cal \
 && git fetch -q --depth 1 https://github.com/CIROH-UA/ngen-cal "$NGEN_CAL_REF" && git checkout -q FETCH_HEAD \
 && mkdir -p /calibration && cp -r ngen-cal /calibration/ngen-cal && cp mpi-ngen /dmod/bin/mpi-ngen \
 && cd / && rm -rf /tmp/ngen-cal
WORKDIR /calibration
COPY calibration-venv-pins.txt .
RUN uv venv --python /usr/bin/python3 \
 && uv pip install -r ngen-cal/requirements.txt \
 && uv pip install -e ngen-cal/python/runCalibValid/ngen_cal -e ngen-cal/python/runCalibValid/ngen_conf \
 && uv pip install numpy==1.26.0 netCDF4 "geopandas==1.*" xarray colorama rich \
 && uv pip install -r calibration-venv-pins.txt
RUN echo "/calibration/.venv/bin/python /calibration/ngen-cal/python/runCalibValid/calibration.py /ngen/ngen/data/calibration/ngen_cal_conf.yaml" > calibrate.sh \
 && echo "/calibration/.venv/bin/python /calibration/ngen-cal/python/runCalibValid/validation.py /ngen/ngen/data/calibration/Output/Validation_Run/ngen_cal_conf.yaml" > validate.sh \
 && echo "/calibration/calibrate.sh && /calibration/validate.sh" > run.sh \
 && chmod +x run.sh calibrate.sh validate.sh /dmod/bin/mpi-ngen \
 && chmod -R 777 /calibration && mkdir -p /.config /.cache && chmod -R 777 /.config /.cache
ENV VIRTUAL_ENV=/ngen/.venv/

# --- ngiab-cal setup CLI (git checkout: setuptools-scm needs .git to package its template) ---
RUN git init -q /opt/ngiab-cal-src && cd /opt/ngiab-cal-src \
 && git fetch -q --depth 1 https://github.com/CIROH-UA/ngiab-cal "$NGIAB_CAL_REF" && git checkout -q FETCH_HEAD \
 && uv export --frozen --no-dev --no-emit-project -o /tmp/ngiab-cal-req.txt \
 && uv venv --python /ngen/.venv/bin/python3 /opt/ngiab-cal \
 && uv pip install --python /opt/ngiab-cal/bin/python -r /tmp/ngiab-cal-req.txt /opt/ngiab-cal-src \
 && mkdir -p /ngen/ngen && ln -s /tmp/ngiab-data /ngen/ngen/data
# PATH stays as is: ngen embeds Python and must use /ngen/.venv (numpy 1.26.4, what it was built
# with). The ngiab-cal venv has numpy 2.x, so ngiab_calibrate.sh calls it by full path.
COPY ngiab_calibrate.sh /opt/ngiab_calibrate.sh
USER 1000:1000
ENTRYPOINT ["/opt/ngiab_calibrate.sh"]
