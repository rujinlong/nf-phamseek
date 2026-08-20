# =============================================================================
# phamseek runtime image  —  docker.io/jinlongru/nf-phamseek
# -----------------------------------------------------------------------------
# The image carries TOOLS ONLY. It does not carry the pipeline source and it
# does not carry reference databases.
#
#   * pipeline source  — Nextflow stages it itself, from the revision you asked
#                        for. Baking it in would let the image tag and the
#                        pipeline revision drift apart silently.
#   * databases        — kraken2 index and host reference are tens of GB, they
#                        version on their own schedule, and a database update
#                        must never require a new image. They are passed with
#                        --db_dir and mounted read-only at run time.
#
# Built from the committed lockfile: `pixi install --locked` refuses to build if
# pixi.lock does not match pixi.toml, so the container, `-profile pixi` and the
# offline bundle all resolve to the same solved environment.
#
# This installs the whole `default` environment, including the tools reserved
# for the v0.2 assembly tier (flye, geNomad, CheckV) and Nextflow itself. That
# costs disk (~5 GB) and buys one property worth more than the disk: there is
# exactly one solved environment in this repository, so "the container has a
# different build of samtools" is not a failure mode that exists here.
#
# Build (from the repository root, context = repository root):
#     docker buildx build -f docker/Dockerfile -t jinlongru/nf-phamseek:dev .
# Both architectures are built natively in CI; see .github/workflows/docker.yml.
# =============================================================================

FROM ghcr.io/prefix-dev/pixi:0.73.0@sha256:66ae514a4421ca06587291beb037e5151b1b280a4f54eed82f57e9b70b94d5ca

LABEL org.opencontainers.image.title="nf-phamseek" \
      org.opencontainers.image.description="Phage detection in low-biomass clinical Oxford Nanopore metagenomes" \
      org.opencontainers.image.source="https://github.com/rujinlong/nf-phamseek" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.authors="Jinlong Ru <jinlong.ru@tum.de>"

WORKDIR /opt/phamseek

COPY pixi.toml pixi.lock ./

# The rattler cache mount keeps the downloaded packages out of the image layer:
# unpacked they are ~5 GB, the tarballs another ~2 GB, and only the first number
# has to ship.
RUN --mount=type=cache,target=/root/.cache/rattler \
    pixi install --locked

# Nextflow does not activate anything. It writes a `.command.sh` and runs it, so
# every tool must resolve from PATH alone — which is why these are ENV and not
# an ENTRYPOINT script. JAVA_HOME and GSETTINGS_SCHEMA_DIR are normally set by
# the environment's own activate.d hooks, which nothing here will run.
ENV PIXI_PROJECT_MANIFEST=/opt/phamseek/pixi.toml \
    CONDA_PREFIX=/opt/phamseek/.pixi/envs/default \
    PATH=/opt/phamseek/.pixi/envs/default/bin:$PATH \
    JAVA_HOME=/opt/phamseek/.pixi/envs/default/lib/jvm \
    GSETTINGS_SCHEMA_DIR=/opt/phamseek/.pixi/envs/default/share/glib-2.0/schemas \
    PYTHONNOUSERSITE=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# Smoke test under a stripped environment, because that is how `.command.sh`
# runs: no login shell, no activation, nothing inherited from the host.
#
# `ps` is asserted because Nextflow's trace observer calls it for per-task
# resource metrics. It comes from the Ubuntu base, not from the pixi
# environment, so it is exactly the kind of thing a base-image bump breaks
# quietly — the pipeline still runs, and every trace row is empty.
RUN env -i HOME=/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        JAVA_HOME=/opt/phamseek/.pixi/envs/default/lib/jvm \
        PATH=/opt/phamseek/.pixi/envs/default/bin:/usr/bin:/bin \
    bash -c 'set -eu; \
             chopper --version; \
             nanoq --version; \
             kraken2 --version | head -1; \
             command -v kraken2-inspect > /dev/null; \
             bracken -v 2>&1 | head -1; \
             minimap2 --version; \
             samtools --version | head -1; \
             pigz --version; \
             python3 --version; \
             command -v ps > /dev/null || { echo "ps is missing: Nextflow trace metrics would be empty" >&2; exit 1; }'

# The pixi base image sets an entrypoint that wraps the command. Nextflow
# executes its own `.command.sh`, so nothing may prefix it.
ENTRYPOINT []
CMD ["/bin/bash"]

WORKDIR /
