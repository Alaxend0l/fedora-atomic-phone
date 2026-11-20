#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Build the development root filesystem that tiny-init can download into RAM
# (kernel argument fap.netroot=http://172.16.42.2:8000/netroot.tar.gz).
#
#   boot/android-bootimg/make-netroot.sh <outdir> [ssh-pubkey]
#   ssh-pubkey defaults to ~/.ssh/id_ed25519.pub (copied in at build time,
#   never committed). Writes <outdir>/netroot.tar.gz.
#
# Serve it to the phone over the USB network, e.g.:
#   python3 -m http.server --bind 172.16.42.2 --directory <outdir> 8000
set -euo pipefail

out=${1:?usage: $0 <outdir> [ssh-pubkey]}
key=${2:-$HOME/.ssh/id_ed25519.pub}
mkdir -p "$out"
out=$(realpath "$out")
here=$(cd "$(dirname "$0")" && pwd)

ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
cp -R "$here/netroot/." "$ctx/"
mkdir -p "$ctx/rootfs/root/.ssh"
install -m 600 "$key" "$ctx/rootfs/root/.ssh/authorized_keys"

# NETROOT_EXTRA_MODULES=<dir> <kver>: out-of-tree .ko files (e.g. a panel
# driver) to install as /usr/lib/modules/<kver>/extra/.
if [ -n "${NETROOT_EXTRA_MODULES:-}" ]; then
    read -r mdir mkver <<< "$NETROOT_EXTRA_MODULES"
    mkdir -p "$ctx/rootfs/usr/lib/modules/$mkver/extra"
    cp "$mdir"/*.ko "$ctx/rootfs/usr/lib/modules/$mkver/extra/"
    echo "extra modules for $mkver: $(cd "$mdir" && ls *.ko | tr '\n' ' ')"
fi

# NETROOT_EXTRA_FIRMWARE=<dir>: files to install under /usr/lib/firmware
# (keeping the directory layout), e.g. firmware extracted from the phone
# that may not be redistributed. Never commit those files.
if [ -n "${NETROOT_EXTRA_FIRMWARE:-}" ]; then
    mkdir -p "$ctx/rootfs/usr/lib/firmware"
    cp -R "$NETROOT_EXTRA_FIRMWARE"/. "$ctx/rootfs/usr/lib/firmware/"
    echo "extra firmware: $(cd "$NETROOT_EXTRA_FIRMWARE" && find . -type f | tr '\n' ' ')"
fi

# FAP_PINNED=1: exact package versions and image digests from lock/netroot.*
# (docs/updates.md). Default: newest Fedora packages.
mkdir -p "$ctx/pin"
build_args=()
if [ -n "${FAP_PINNED:-}" ]; then
    # Command substitution, not < <(…): a failure must stop the build.
    pins=$("$here/../../tools/update/pin-context.sh" netroot "$ctx/pin")
    while IFS= read -r a; do build_args+=(--build-arg "$a"); done <<< "$pins"
fi

# NETROOT_IMAGE: image tag (default localhost/fap-netroot:latest, which
# installroot/Containerfile builds FROM; use another tag for other devices).
tag=${NETROOT_IMAGE:-localhost/fap-netroot:latest}
podman build ${build_args[@]+"${build_args[@]}"} -t "$tag" "$ctx"

# Export the filesystem (not the image layers) as one tarball.
cid=$(podman create "$tag" /bin/true)
podman export "$cid" | gzip -1 > "$out/netroot.tar.gz"
podman rm "$cid" >/dev/null
ls -lh "$out/netroot.tar.gz"
