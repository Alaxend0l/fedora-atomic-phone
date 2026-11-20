# SPDX-License-Identifier: AGPL-3.0-or-later
# Builds one bootable image for one (device, desktop) pair.
#
# Each stage runs a folder's `build` script inside the image being built:
#   base/ → desktops/$DESKTOP/ → boot/$BOOT_METHOD/ → devices/$DEVICE/ → finalize
# The folders are bind-mounted, so nothing from the repo itself ends up in the
# image unless a build script copies it in.
#
# Build args (set by the Justfile):
#   BASE_IMAGE  Fedora Atomic image to start from
#   DEVICE      folder name under devices/
#   DESKTOP     folder name under desktops/
#   BOOT_METHOD folder name under boot/ (from the device's device.env)
#   FAP_LOCK    lock target to pin packages to (lock/<FAP_LOCK>.*), empty =
#               newest packages (default). `just PINNED=1 build` sets it and
#               BASE_IMAGE by digest; see docs/updates.md.

ARG BASE_IMAGE

FROM scratch AS ctx
COPY base /base
COPY desktops /desktops
COPY boot /boot
COPY devices /devices
COPY tools/image /tools
COPY lock /lock

FROM ${BASE_IMAGE}

ARG DEVICE
ARG DESKTOP
ARG BOOT_METHOD
ARG FAP_LOCK=""

# Make the selection visible to every build script.
ENV FAP_DEVICE=${DEVICE} FAP_DESKTOP=${DESKTOP} FAP_BOOT_METHOD=${BOOT_METHOD}

# Pinned builds only: lock dnf5 to the versions in lock/$FAP_LOCK.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/tools/pin-packages "${FAP_LOCK}"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/base

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/desktops/${DESKTOP}

# Boot method support (e.g. the boot-partition sync tool for android-bootimg).
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/boot/${BOOT_METHOD}

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,target=/var/cache \
    /ctx/tools/run-layer /ctx/devices/${DEVICE}

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/tools/finalize

# Catch common bootc mistakes (e.g. content in /var, missing kernel).
RUN bootc container lint
