#!/usr/bin/env bash
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

podman build -t localhost/fap-netroot:latest "$ctx"

# Export the filesystem (not the image layers) as one tarball.
cid=$(podman create localhost/fap-netroot:latest /bin/true)
podman export "$cid" | gzip -1 > "$out/netroot.tar.gz"
podman rm "$cid" >/dev/null
ls -lh "$out/netroot.tar.gz"
