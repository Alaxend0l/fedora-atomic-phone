#!/usr/bin/env bash
# Turn a built bootc image into flashable images. Runs on an aarch64 Linux host
# as root (image-builder needs privileged podman and loop devices).
#
#   tools/make-disk.sh <image> devices/<id> <outdir>
#
# Produces in <outdir>/:
#   disk.raw     whole GPT disk from image-builder (layout: the device's disk.yaml)
#   esp.img      EFI system partition, Android sparse format, for fastboot
#   rootfs.img   root filesystem, Android sparse format, for fastboot
#
# Status: untested.
set -euo pipefail

image=${1:?usage: $0 <image> devices/<id> <outdir>}
dev=${2:?usage: $0 <image> devices/<id> <outdir>}
out=${3:?usage: $0 <image> devices/<id> <outdir>}
mkdir -p "$out"

for t in podman sfdisk python3 img2simg; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

# 1. Whole disk. image-builder reads the partition layout from the image
#    itself (/usr/lib/image-builder/bootc/disk.yaml, shipped by the device).
podman run --rm --privileged \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$(realpath "$out")":/output \
    ghcr.io/osbuild/image-builder:latest \
    build --bootc-ref "$image" --output-dir /output --output-name disk raw

# 2. Cut the ESP and root partitions out of the disk image by offset, so each
#    can be flashed into a different Android partition.
sfdisk --json "$out/disk.raw" > "$out/table.json"
python3 - "$out" <<'EOF'
import json, subprocess, sys
out = sys.argv[1]
t = json.load(open(f"{out}/table.json"))["partitiontable"]
ss = t.get("sectorsize", 512)
esp_type = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
for p in t["partitions"]:
    name = "esp" if p["type"].upper() == esp_type else "rootfs"
    subprocess.run(["dd", f"if={out}/disk.raw", f"of={out}/{name}.raw",
                    f"bs={ss}", f"skip={p['start']}", f"count={p['size']}",
                    "status=none"], check=True)
    print(f"{name}: {p['size'] * ss // (1 << 20)} MiB")
EOF

# 3. fastboot handles big images best in Android sparse format.
for n in esp rootfs; do
    img2simg "$out/$n.raw" "$out/$n.img"
    rm "$out/$n.raw"
done
rm "$out/table.json"
ls -lh "$out"
