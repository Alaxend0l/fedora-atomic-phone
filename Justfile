# SPDX-License-Identifier: AGPL-3.0-or-later
# Entry points. Override any variable on the command line:
#   just DEVICE=oneplus-billie2 DESKTOP=phosh build
# or put them in a .env file (git-ignored).

set dotenv-load

FEDORA  := env("FAP_FEDORA", "45")
DEVICE  := env("FAP_DEVICE", "oneplus-billie2")
DESKTOP := env("FAP_DESKTOP", "phosh")
REGISTRY := env("FAP_REGISTRY", "localhost")

# Every image starts from Fedora's minimal bootc base (no desktop); the
# desktop layer installs its explicit package list (docs/decisions/0003).
BASE_IMAGE := env("FAP_BASE_IMAGE", "quay.io/fedora-ostree-desktops/base-atomic:" + FEDORA)

# Opt-in layers (layers/), space-separated, e.g. LAYERS="waydroid".
LAYERS := env("FAP_LAYERS", "")

IMAGE := REGISTRY / "fap-" + DEVICE + "-" + DESKTOP + ":" + FEDORA

# PINNED=1: build exactly the package versions and base image digest in
# lock/<device>-<desktop>.* (tools/update/, docs/updates.md). Default: newest.
PINNED := env("FAP_PINNED", "")
LOCK := DEVICE + "-" + DESKTOP
BUILD_BASE := if PINNED == "" { BASE_IMAGE } else {
        shell('. lock/"$1".images.env && echo "$BASE_IMAGE"', LOCK)
    }

# Read from the device's device.env, so devices can't disagree with the build.
BOOT_METHOD := shell('. devices/"$1"/device.env 2>/dev/null && echo "$BOOT_METHOD"', DEVICE)

default:
    @just --list

# Check that the device and desktop folders exist and the device config is complete.
check:
    tools/check-device.sh devices/{{DEVICE}}
    test -d desktops/{{DESKTOP}}
    for l in {{LAYERS}}; do test -d "layers/$l" || { echo "no layers/$l" >&2; exit 1; }; done

# Build the bootable OCI image (needs an aarch64 Linux host with podman).
build: check
    podman build \
        --platform linux/arm64 \
        --build-arg BASE_IMAGE={{BUILD_BASE}} \
        --build-arg FAP_LOCK={{ if PINNED == "" { "" } else { LOCK } }} \
        --build-arg DEVICE={{DEVICE}} \
        --build-arg DESKTOP={{DESKTOP}} \
        --build-arg BOOT_METHOD={{BOOT_METHOD}} \
        --build-arg LAYERS="{{LAYERS}}" \
        -t {{IMAGE}} .

# RAM-boot dev root (netroot + the same layers) for fastboot boot + fap.netroot=.
devroot OUT:
    boot/android-bootimg/make-devroot.sh {{DEVICE}} {{DESKTOP}} {{OUT}} {{LAYERS}}

# Turn the image into flashable disk images in ./output (needs root podman).
disk:
    tools/make-disk.sh {{IMAGE}} devices/{{DEVICE}} output

# Build U-Boot for a uboot-android device (needs a U-Boot checkout).
uboot SRC:
    boot/uboot-android/build-in-container.sh {{SRC}} devices/{{DEVICE}} output

# Flash ./output to a phone in fastboot mode, using the device's flash plan.
flash:
    tools/flash.sh devices/{{DEVICE}} output

# Pin: regenerate lock/ and show what changed (podman; docs/updates.md).
update-check *ARGS:
    tools/update/check-updates.py {{ARGS}}

# Review an update PR with the local LLM and comment on it (docs/updates.md).
update-review PR *ARGS:
    tools/update/review-pr.sh {{PR}} {{ARGS}}

# Print the resolved settings.
info:
    @echo "device={{DEVICE}} desktop={{DESKTOP}} layers={{LAYERS}} fedora={{FEDORA}} boot={{BOOT_METHOD}}"
    @echo "base={{BUILD_BASE}}"
    @echo "pinned={{ if PINNED == "" { "no (newest packages)" } else { "lock/" + LOCK } }}"
    @echo "image={{IMAGE}}"
