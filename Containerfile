# Builds one bootable image for one (device, desktop) pair.
#
# Each stage runs a folder's `build` script inside the image being built:
#   base/build → desktops/$DESKTOP/build → devices/$DEVICE/build → tools/finalize
# The folders are bind-mounted, so nothing from the repo itself ends up in the
# image unless a build script copies it in.
#
# Build args (set by the Justfile):
#   BASE_IMAGE  Fedora Atomic image to start from
#   DEVICE      folder name under devices/
#   DESKTOP     folder name under desktops/

ARG BASE_IMAGE

FROM scratch AS ctx
COPY base /base
COPY desktops /desktops
COPY devices /devices
COPY tools/image /tools

FROM ${BASE_IMAGE}

ARG DEVICE
ARG DESKTOP

# Make the selection visible to every build script.
ENV FAP_DEVICE=${DEVICE} FAP_DESKTOP=${DESKTOP}

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/base

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/desktops/${DESKTOP}

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/devices/${DEVICE}

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/tools/finalize

# Catch common bootc mistakes (e.g. content in /var, missing kernel).
RUN bootc container lint
