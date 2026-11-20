#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# OnePlus 12 (waffle) build environment: kernel, DTBs, debug initramfs and
# RAM-boot images for first light. Builds only; never talks to a phone.
#
#   devices/oneplus-waffle/build-env/fap-waffle-build.sh <command>...
#
#   kernel        fetch + configure + build Image and modules (KERNEL_TREE).
#                 Default config is SLIM: arm64 defconfig, other SoC
#                 platforms off, + our fragments (first light; quick).
#   kernel --full Fedora's whole aarch64 config + our fragments (what a
#                 packaged kernel would use; hours in a small podman VM)
#   config-check  only configure (olddefconfig + fragment check); takes
#                 --full too. KERNEL_TREE=fedora config-check --full is the
#                 "does our fragment work on Fedora's own 7.3.4 tree" check
#   dtb           our first-light DTBs (dts/*.dts, built in the waffle tree)
#   initramfs     static busybox + boot/android-bootimg/tiny-init + modules
#   images        uniLoader per variant, wrapped in boot images (ramboot/)
#   netroot       generic netroot tarball + this kernel's modules (optional)
#   gpu-firmware  only the Adreno 750 firmware set (Fedora SQE/GMU + the
#                 unit's zap shader) as OUT/gpu-firmware/waffle-gpu-firmware.tar.gz,
#                 to unpack into any root (e.g. the Plasma root); local only
#   all           kernel dtb initramfs images
#   bisect        crash-bisect variants in OUT/bisect (needs 'all' and
#                 '--daddevil kernel' first): v1 = DaDDevil's own recipe
#                 (his waffle_defconfig + his unmodified board DTB, stock
#                 uniLoader), v2 = our plain image with uniLoader's
#                 self-relocation made overlap-safe (BISECT.md there)
#   --daddevil    with kernel/config-check: DaDDevil's waffle_defconfig as is
#                 (no fragments), stage files *-waffle-daddevil
#   shell         a shell in the build container
#
# Runs on the host (macOS or Linux, podman) and re-executes itself inside
# localhost/fap-waffle-build (built from ./Containerfile when missing, or with
# REBUILD_IMAGE=1). State lives in the case-sensitive podman volume
# "waffle-build" (/work; macOS's file system is case-insensitive, Linux trees
# aren't): sources in /work/src, kernel trees /work/linux-waffle and
# /work/linux (Fedora), build dirs /work/out-<tree>, intermediate files
# /work/stage. Outputs go to OUT (default ~/Develop/fap-build/waffle).
#
# Environment:
#   OUT            output directory on the host
#   KERNEL_TREE    waffle (default): DaDDevil/linux waffle-voice @ WAFFLE_COMMIT,
#                  the first-light kernel (board DT + panel/touch drivers);
#                  fedora: Fedora's kernel-7.3.4-300.fc45 src.rpm (tier 2, the
#                  long-term path; no waffle board DT in it, so kernel only)
#   JOBS           parallel jobs (default: nproc in the container)
#   STOCK_BACKUP   host dir with the phone's partition backup; only
#                  vendor_boot_a.img is read (read-only mount) for the
#                  header-v2 fallback image. Optional.
#   FAP_OFFLINE    1 (default): kernel/config-check/dtb/initramfs/images/all/
#                  bisect run with --network=none (sources must already be in
#                  the volume, at the pinned commits); 0 allows the network
#                  (first fetch). netroot/shell always get the network.
#   NETROOT_GENERIC  host path of a generic netroot.tar.gz (netroot command):
#                  make-netroot.sh's, or a dev root from
#                  boot/android-bootimg/make-devroot.sh oneplus-waffle <desktop>
#   NETROOT_OUTDIR subdirectory of OUT for the netroot command's tarball
#                  (default netroot; e.g. plasma-netroot for a dev root)
#   PHONE_BACKUP   host dir with this unit's partition dumps (netroot command,
#                  optional, read-only mount): modem_a.img (DSP/modem firmware)
#                  and modemst1/modemst2/fsg/fsc (EFS copies for rmtfs -r)
#                  go into the netroot tarball, which therefore must stay
#                  local (it carries the unit's IMEI data and OEM firmware).
#                  v7: also bluetooth_a.img (BT patch + NVM files).
#   VENDOR_FILES   host dir of this unit's /vendor + /odm copy
#                  (OnePlus12/backup/vendor-files-20261120: tree/ +
#                  phone-manifest.sha256), read-only (netroot, gpu-firmware):
#                  GPU zap shader and Iris firmware, checked against the
#                  phone-side manifest. OEM firmware: outputs stay local.
set -euo pipefail

IMAGE=localhost/fap-waffle-build
VOLUME=waffle-build

# Pinned sources
WAFFLE_URL=https://github.com/DaDDevil/linux
WAFFLE_COMMIT=9359fc748607247425fe0e8f0e4592fcbd3a72a4   # waffle-voice, 2026-11-20 (v7.4-rc3 + 51)
UNILOADER_URL=https://github.com/ivoszbg/uniLoader
UNILOADER_COMMIT=0bd1dd1b55420bebf6ddf24a4e46b16372ae53fb # master 2026-11-13 (waffle board since f14ee108c9)
FEDORA_SRPM=https://kojipkgs.fedoraproject.org/packages/kernel/7.3.4/300.fc45/src/kernel-7.3.4-300.fc45.src.rpm
FEDORA_SRPM_SHA256=b600e1aa5eb710ae5db4e9a35b98bd171dec94ef2992997fa3526d6bfe44488b

# Unit facts (OnePlus12/log/2026-11-20-recon.md; stock boot_a.img read with
# unpack_bootimg/avbtool: header v4, LineageOS 23.2 on OxygenOS 16 firmware).
OS_VERSION=16.0.0
OS_PATCH_LEVEL=2026-06
# uniLoader waffle_defconfig (DaDDevil): linked at 0xa8010000, copies the
# kernel to 0xa3200000 and the ramdisk to 0xb6f95000. All three sit in the
# board DT's free bank 0xa3180000-0xd4e23000 (no reserved-memory in it).
UL_TEXT_BASE=0xa8010000
UL_PAYLOAD_ENTRY=0xa3200000
UL_RAMDISK_ENTRY=0xb6f95000
UL_BANK_END=0xd4e23000
VARIANTS="plain netroot"

if [[ -z ${FAP_WAFFLE_INNER:-} ]]; then
  HERE=$(cd "$(dirname "$0")/.." && pwd)        # devices/oneplus-waffle
  REPO=$(cd "$HERE/../.." && pwd)
  OUT=${OUT:-$HOME/Develop/fap-build/waffle}
  mkdir -p "$OUT"
  if [[ ${REBUILD_IMAGE:-0} == 1 ]] || ! podman image exists "$IMAGE"; then
    podman build -t "$IMAGE" -f "$HERE/build-env/Containerfile" "$HERE/build-env"
  fi
  podman volume exists "$VOLUME" || podman volume create "$VOLUME" >/dev/null
  extra=()
  if [[ -n ${STOCK_BACKUP:-} ]]; then
    [[ -f $STOCK_BACKUP/vendor_boot_a.img ]] || { echo "no $STOCK_BACKUP/vendor_boot_a.img" >&2; exit 1; }
    extra+=(-v "$STOCK_BACKUP/vendor_boot_a.img:/stock/vendor_boot_a.img:ro")
  fi
  if [[ -n ${PHONE_BACKUP:-} ]]; then
    [[ -f $PHONE_BACKUP/modem_a.img ]] || { echo "no $PHONE_BACKUP/modem_a.img" >&2; exit 1; }
    extra+=(-v "$(cd "$PHONE_BACKUP" && pwd):/backup:ro")
  fi
  if [[ -n ${VENDOR_FILES:-} ]]; then
    [[ -f $VENDOR_FILES/phone-manifest.sha256 && -d $VENDOR_FILES/tree/vendor/firmware ]] ||
      { echo "VENDOR_FILES needs tree/ and phone-manifest.sha256" >&2; exit 1; }
    extra+=(-v "$(cd "$VENDOR_FILES" && pwd):/vendor-files:ro")
  fi
  [[ -n ${NETROOT_GENERIC:-} ]] && extra+=(-v "$(cd "$(dirname "$NETROOT_GENERIC")" && pwd)/$(basename "$NETROOT_GENERIC"):/netroot-generic.tar.gz:ro")
  tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)
  net=(--network=none)
  for c in "$@"; do
    case $c in kernel|config-check|dtb|initramfs|images|all|bisect|--full|--daddevil) ;; *) net=() ;; esac
  done
  [[ ${FAP_OFFLINE:-1} == 0 ]] && net=()
  extra+=(${net[@]+"${net[@]}"})
  exec podman run --rm ${tty[@]+"${tty[@]}"} -v "$VOLUME:/work" -v "$REPO:/repo:ro" -v "$OUT:/out" \
    ${extra[@]+"${extra[@]}"} -e FAP_WAFFLE_INNER=1 -e JOBS="${JOBS:-}" \
    -e KERNEL_TREE="${KERNEL_TREE:-waffle}" -e NETROOT_OUTDIR="${NETROOT_OUTDIR:-netroot}" \
    "$IMAGE" bash /repo/devices/oneplus-waffle/build-env/fap-waffle-build.sh "$@"
fi

# ------------------------------------------------------------- container
say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
DEV=/repo/devices/oneplus-waffle
JOBS=${JOBS:-$(nproc)}
S=/work/stage
mkdir -p "$S" /work/src
case $KERNEL_TREE in
  waffle) K=/work/linux-waffle ;;
  fedora) K=/work/linux ;;
  *) die "KERNEL_TREE must be waffle or fedora" ;;
esac
# --full anywhere on the command line selects Fedora's whole config,
# --daddevil the waffle tree's own waffle_defconfig (bisect variant 1).
CONFIG_MODE=slim
args=()
for a in "$@"; do
  case $a in
    --full) CONFIG_MODE=full ;;
    --daddevil) CONFIG_MODE=daddevil ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
KO=/work/out-$KERNEL_TREE-$CONFIG_MODE
# Stage name of the kernel outputs: daddevil builds must not replace ours.
KT=$KERNEL_TREE; [[ $CONFIG_MODE == daddevil ]] && KT=$KERNEL_TREE-daddevil
[[ $CONFIG_MODE == daddevil && $KERNEL_TREE != waffle ]] && die "--daddevil needs KERNEL_TREE=waffle"
MK=(make -s ARCH=arm64 O="$KO")

fetch_srpm() {   # Fedora's src.rpm: config for both trees, source for 'fedora'
  local r=/work/src/kernel-7.3.4-300.fc45.src.rpm
  [[ -f $r ]] || curl -sfL -o "$r" "$FEDORA_SRPM"
  echo "$FEDORA_SRPM_SHA256  $r" | sha256sum -c --quiet - || die "src.rpm checksum"
  if [[ ! -f /work/src/srpm/kernel-aarch64-fedora.config ]]; then
    mkdir -p /work/src/srpm && (cd /work/src/srpm && rpm2cpio "$r" | cpio -idm --quiet)
  fi
}

fetch_tree() {
  if [[ $KERNEL_TREE == waffle ]]; then
    if [[ ! -d $K/.git ]]; then
      git init -q "$K" && git -C "$K" remote add origin "$WAFFLE_URL"
    fi
    if [[ $(git -C "$K" rev-parse -q --verify HEAD 2>/dev/null) != "$WAFFLE_COMMIT" ]]; then
      git -C "$K" fetch -q --depth 1 origin "$WAFFLE_COMMIT" 2>/dev/null ||
        git -C "$K" fetch -q --depth 1 origin waffle-voice
      git -C "$K" checkout -q -f --detach FETCH_HEAD
    fi
    [[ $(git -C "$K" rev-parse HEAD) == "$WAFFLE_COMMIT" ]] || die "waffle-voice moved: not at $WAFFLE_COMMIT"
    apply_patches
    echo "waffle-voice $WAFFLE_COMMIT + kernels/qcom-sm8650/patches ($(grep -cv '^#' "$PATCHES/series") patches)" > "$S/kernel-source"
  else
    if [[ ! -d $K/.fap-prepared ]]; then
      rm -rf "$K" && mkdir -p "$K"
      tar -xJf /work/src/srpm/linux-7.3.4.tar.xz -C "$K" --strip-components=1
      (cd "$K" && patch -p1 -s < /work/src/srpm/patch-7.3-redhat.patch)
      [[ -s /work/src/srpm/linux-kernel-test.patch ]] && (cd "$K" && patch -p1 -s < /work/src/srpm/linux-kernel-test.patch)
      cp /work/src/srpm/Makefile.rhelver "$K/"
      mkdir "$K/.fap-prepared"
    fi
    echo "Fedora kernel-7.3.4-300.fc45.src.rpm (linux-7.3.4 + patch-7.3-redhat.patch)" > "$S/kernel-source"
  fi
}

# Our kernel patches (kernels/qcom-sm8650/patches/series, each with an
# Upstream-Status line), applied to the pinned waffle-voice checkout. The
# tracked files are reset to the pinned commit first (only files that
# differ are rewritten, so make rebuilds just those), then every patch must
# apply cleanly.
PATCHES=/repo/kernels/qcom-sm8650/patches
apply_patches() {
  git -C "$K" reset -q --hard "$WAFFLE_COMMIT"
  local p
  while read -r p; do
    [[ -z $p || $p == \#* ]] && continue
    grep -q '^Upstream-Status: ' "$PATCHES/$p" || die "$p has no Upstream-Status line"
    git -C "$K" apply --whitespace=nowarn "$PATCHES/$p" || die "patch does not apply: $p"
    echo "applied: $p"
  done < "$PATCHES/series"
}

kconfig() {
  if [[ $CONFIG_MODE == daddevil ]]; then
    say "Config (daddevil): the tree's arch/arm64/configs/waffle_defconfig, unchanged"
    mkdir -p "$KO"
    (cd "$K" && make -s ARCH=arm64 O="$KO" waffle_defconfig >/dev/null)
    cp "$KO/.config" "$S/kernel-$KT.config"
    echo "$CONFIG_MODE" > "$S/kernel-config-mode-$KT"
    return
  fi
  local base="arm64 defconfig"; [[ $CONFIG_MODE == full ]] && base="Fedora kernel-aarch64-fedora.config"
  say "Config ($CONFIG_MODE): $base + kernels/qcom-sm8650/fap.config$([[ $KERNEL_TREE == waffle ]] && echo ' + waffle.config') + build.config"
  mkdir -p "$KO"
  local frags=(/repo/kernels/qcom-sm8650/fap.config)
  [[ $KERNEL_TREE == waffle ]] && frags+=("$DEV/build-env/waffle.config")
  if [[ $CONFIG_MODE == full ]]; then
    cp /work/src/srpm/kernel-aarch64-fedora.config "$KO/.config"
  else
    (cd "$K" && make -s ARCH=arm64 O="$KO" defconfig >/dev/null)
  fi
  (cd "$K" && scripts/kconfig/merge_config.sh -m -O "$KO" "$KO/.config" "${frags[@]}" \
    "$DEV/build-env/build.config" >/dev/null)
  # Other SoC platforms off (both modes): shortens the build and keeps the
  # Image small enough for uniLoader's layout (see UL_* above).
  local a
  local plats=()
  for a in $(sed -nE 's/^\s*(menu)?config (ARCH_[A-Z0-9_]+)\s*$/\2/p' "$K/arch/arm64/Kconfig.platforms"); do
    [[ $a == ARCH_QCOM ]] || plats+=(--disable "$a")
  done
  (( ${#plats[@]} > 20 )) || die "found no platform list in Kconfig.platforms"
  (cd "$K" && scripts/config --file "$KO/.config" "${plats[@]}")
  (cd "$K" && "${MK[@]}" olddefconfig)
  # Every fragment line must have survived (=m may have become =y).
  local f line sym want got bad=0
  for f in "${frags[@]}" "$DEV/build-env/build.config"; do
    while IFS= read -r line; do
      case $line in
        CONFIG_*=*) sym=${line%%=*}; want=${line#*=} ;;
        "# CONFIG_"*" is not set") sym=${line#\# }; sym=${sym%% *}; want=n ;;
        *) continue ;;
      esac
      got=$(grep -E "^$sym=" "$KO/.config" | cut -d= -f2- || true)
      [[ -z $got ]] && got=n
      if [[ $want == "$got" || ( $want == m && $got == y ) ]]; then continue; fi
      # Option absent in this tree (e.g. DEBUG_INFO_* variants): fine for "n".
      [[ $want == n ]] && ! grep -q "${sym}[= ]" "$KO/.config" && continue
      echo "  $sym: want $want, got $got ($(basename "$f"))"; bad=1
    done < "$f"
  done
  [[ $bad == 0 ]] || die "config fragment not applied (above)"
  echo "fragment check: ok"
  cp "$KO/.config" "$S/kernel-$KERNEL_TREE.config"
  echo "$CONFIG_MODE" > "$S/kernel-config-mode-$KERNEL_TREE"
}

need_srpm() {   # Fedora's config (full mode) or Fedora's source tree
  [[ $CONFIG_MODE == full || $KERNEL_TREE == fedora ]] && fetch_srpm || true
}

cmd_config_check() { need_srpm; fetch_tree; kconfig; }

cmd_kernel() {
  need_srpm; fetch_tree; kconfig
  say "Build Image + modules ($KERNEL_TREE, -j$JOBS)"
  (cd "$K" && "${MK[@]}" -j"$JOBS" Image modules)
  local kver; kver=$(cat "$KO/include/config/kernel.release")
  say "Modules install ($kver)"
  rm -rf "$S/modroot-$KT"
  (cd "$K" && "${MK[@]}" INSTALL_MOD_PATH="$S/modroot-$KT" INSTALL_MOD_STRIP=1 modules_install)
  rm -f "$S/modroot-$KT/lib/modules/$kver/build" "$S/modroot-$KT/lib/modules/$kver/source"
  cp "$KO/arch/arm64/boot/Image" "$S/Image-$KT"
  echo "$kver" > "$S/kernel-release-$KT"
  image_size_check "$S/Image-$KT"
}

image_size_check() {   # the kernel's image_size (incl. BSS) must end below uniLoader
  local isz room
  isz=$(od -An -t u8 -j 16 -N 8 "$1" | tr -d ' ')
  room=$((UL_TEXT_BASE - UL_PAYLOAD_ENTRY))
  printf 'Image file %d MiB, image_size %d MiB, room below uniLoader %d MiB\n' \
    $(( $(stat -c %s "$1") >> 20 )) $((isz >> 20)) $((room >> 20))
  (( isz + (2 << 20) <= room )) || die "kernel image_size too big for uniLoader's layout (needs PAYLOAD_ENTRY moved)"
}

DTS_NAMES="sm8650-oneplus-waffle-fap sm8650-oneplus-waffle-fap-netroot"
cmd_dtb() {
  [[ $KERNEL_TREE == waffle ]] || die "dtb needs KERNEL_TREE=waffle (the board DT lives there)"
  fetch_tree
  say "First-light DTBs (our dts/ on DaDDevil's board DT, $WAFFLE_COMMIT)"
  local D=$K/arch/arm64/boot/dts/qcom n OD=/work/out-dtb
  cp "$DEV"/dts/*.dts "$DEV"/dts/*.dtsi "$D/"
  for n in $DTS_NAMES; do
    grep -q "^dtb-\$(CONFIG_ARCH_QCOM)	+= $n.dtb" "$D/Makefile" ||
      printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= %s.dtb\n' "$n" >> "$D/Makefile"
  done
  mkdir -p "$OD"
  # A separate defconfig build dir: only dtc runs, so this works while a
  # kernel build is going on in $KO.
  [[ -f $OD/.config ]] || (cd "$K" && make -s ARCH=arm64 O="$OD" defconfig >/dev/null)
  for n in $DTS_NAMES; do
    (cd "$K" && make -s ARCH=arm64 O="$OD" "qcom/$n.dtb")
    cp "$OD/arch/arm64/boot/dts/qcom/$n.dtb" "$S/$n.dtb"
    echo "$n.dtb: bootargs: $(fdtget "$S/$n.dtb" /chosen bootargs)"
    echo "  memory: $(fdtget -t x "$S/$n.dtb" /memory@a0000000 reg | wc -w) cells; usb dr_mode $(fdtget "$S/$n.dtb" /soc@0/usb@a600000 dr_mode)"
    fdtget "$S/$n.dtb" /chosen/framebuffer@d5100000 compatible >/dev/null || die "no framebuffer node"
  done
  # Restore the tree's Makefile and drop our files (keeps the checkout clean).
  git -C "$K" checkout -q -- arch/arm64/boot/dts/qcom/Makefile
  for n in "$DEV"/dts/*.dts "$DEV"/dts/*.dtsi; do rm -f "$D/$(basename "$n")"; done
}

RAMBOOT_MODULES="pm8941-pwrkey gpio_keys rtc-pm8xxx qcom-pon"
cmd_initramfs() {
  [[ -f $S/kernel-release-waffle ]] || die "run 'kernel' first"
  local kver R=$S/initramfs M m ko
  kver=$(cat "$S/kernel-release-waffle")
  M=$S/modroot-waffle
  say "Debug initramfs: static busybox + tiny-init + $RAMBOOT_MODULES"
  rm -rf "$R" && mkdir -p "$R"/{bin,etc,lib/modules,dev,proc,sys,tmp,run}
  cp /usr/sbin/busybox "$R/bin/busybox"
  file -L "$R/bin/busybox" | grep -q 'statically linked' || die "busybox is not static"
  for m in $(/usr/sbin/busybox --list); do [[ -e $R/bin/$m ]] || ln -s busybox "$R/bin/$m"; done
  install -m 755 /repo/boot/android-bootimg/tiny-init "$R/init"
  : > "$R/etc/modules.order"
  # Same mechanism as make-ramboot.sh: dependency order from modprobe.
  for m in $RAMBOOT_MODULES; do
    modprobe -d "$M" -S "$kver" --show-depends "$m" | awk '/^insmod /{print $2}'
  done | awk '!seen[$0]++' | while read -r ko; do
    cp "$ko" "$R/lib/modules/"
    echo "/lib/modules/$(basename "$ko")" >> "$R/etc/modules.order"
  done
  echo "modules: $(tr '\n' ' ' < "$R/etc/modules.order")"
  (cd "$R" && find . | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0 | gzip -9n) > "$S/initramfs.cpio.gz"
  ls -l "$S/initramfs.cpio.gz"
}

# uniLoader's arch/aarch64/reloc.S copies itself (with the embedded kernel,
# ~33 MiB) from where ABL put it to TEXT_BASE with a forward 16-byte loop.
# If ABL's load address is below TEXT_BASE by less than the image size
# (e.g. 0xa8000000 vs 0xa8010000), the source is overwritten before it is
# read: kernel, DTB, strings and driver table become copies of the first
# 64 KiB and uniLoader dies before it draws anything. This patch copies
# backwards in that case (memmove) and invalidates the I-cache before the
# jump; nothing else changes. Used by bisect variant 2.
reloc_safe_patch() {   # reloc_safe_patch <uniLoader tree>
  python3 - "$1/arch/aarch64/reloc.S" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	beq	_entry
	ldr	x6,  _rel_stack_size

_copy:
	ldp	x2, x3, [x4], #16
	stp	x2, x3, [x5], #16
	subs	x6, x6, #16
	b.ne	_copy
	ldr	x5, _rel_stack_base

_entry:
	br	x5
"""
new = """	beq	_entry
	ldr	x6,  _rel_stack_size
	b.hi	_copy			/* src above dst: forward copy is safe */
	add	x4, x4, x6		/* src below dst: copy backwards */
	add	x7, x5, x6
_copy_back:
	ldp	x2, x3, [x4, #-16]!
	stp	x2, x3, [x7, #-16]!
	subs	x6, x6, #16
	b.ne	_copy_back
	b	_copied

_copy:
	ldp	x2, x3, [x4], #16
	stp	x2, x3, [x5], #16
	subs	x6, x6, #16
	b.ne	_copy
_copied:
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	ldr	x5, _rel_stack_base

_entry:
	br	x5
"""
assert s.count(old) == 1, "reloc.S changed upstream"
open(p, "w").write(s.replace(old, new))
PY
}

# uniloader_build <name> [<Image> <dtb> <ramdisk> [reloc-safe]]: empty or
# missing inputs default to the first-light inputs of <name> (plain|netroot).
uniloader_build() {
  local v=$1 U=/work/uniloader-$1
  local img=${2:-} dtb=${3:-} rd=${4:-}
  [[ -n $img ]] || img=$S/Image-waffle
  [[ -n $dtb ]] || dtb=$S/sm8650-oneplus-waffle-fap$([[ $v == plain ]] || echo "-$v").dtb
  [[ -n $rd ]] || rd=$S/initramfs.cpio.gz
  rm -rf "$U"
  if [[ ! -d /work/src/uniLoader/.git ]]; then
    git clone -q "$UNILOADER_URL" /work/src/uniLoader
  fi
  git -C /work/src/uniLoader fetch -q origin 2>/dev/null || true
  git -C /work/src/uniLoader checkout -q -f --detach "$UNILOADER_COMMIT"
  cp -a /work/src/uniLoader "$U"
  [[ ${5:-} == reloc-safe ]] && reloc_safe_patch "$U"
  cp "$img" "$U/blob/Image"
  cp "$dtb" "$U/blob/dtb"
  cp "$rd" "$U/blob/ramdisk"
  (cd "$U" && make -s ARCH=aarch64 waffle_defconfig >/dev/null)
  grep -qx "CONFIG_TEXT_BASE=$UL_TEXT_BASE" "$U/.config" || die "uniLoader TEXT_BASE changed"
  grep -qx "CONFIG_PAYLOAD_ENTRY=$UL_PAYLOAD_ENTRY" "$U/.config" || die "uniLoader PAYLOAD_ENTRY changed"
  grep -qx "CONFIG_RAMDISK_ENTRY=$UL_RAMDISK_ENTRY" "$U/.config" || die "uniLoader RAMDISK_ENTRY changed"
  (cd "$U" && make -s ARCH=aarch64 -j"$JOBS")
  cp "$U/uniLoader.bin" "$S/uniLoader-$v.bin" 2>/dev/null || cp "$U"/uniLoader "$S/uniLoader-$v.bin"
  [[ "$(dd if="$S/uniLoader-$v.bin" bs=1 skip=56 count=4 status=none)" == "ARMd" ]] ||
    die "uniLoader-$v.bin has no arm64 Image header"
  # Layout: uniLoader + its blobs from TEXT_BASE, the ramdisk copy above it,
  # all inside the free bank.
  local sz rds isz
  sz=$(stat -c %s "$S/uniLoader-$v.bin"); rds=$(stat -c %s "$rd")
  isz=$(od -An -t u8 -j 16 -N 8 "$S/uniLoader-$v.bin" | tr -d ' ')   # incl. BSS + stack
  (( UL_TEXT_BASE + isz + (4 << 20) < UL_RAMDISK_ENTRY )) || die "uniLoader-$v.bin overlaps RAMDISK_ENTRY"
  (( UL_RAMDISK_ENTRY + rds < UL_BANK_END )) || die "ramdisk leaves the bank"
  printf 'uniLoader-%s.bin: file %#x, image_size %#x (ends %#x; ramdisk %#x-%#x)\n' "$v" "$sz" "$isz" \
    $((UL_TEXT_BASE + isz)) "$UL_RAMDISK_ENTRY" $((UL_RAMDISK_ENTRY + rds))
}

cmd_images() {
  local f v I=$S/images
  for f in Image-waffle initramfs.cpio.gz sm8650-oneplus-waffle-fap.dtb sm8650-oneplus-waffle-fap-netroot.dtb; do
    [[ -f $S/$f ]] || die "missing $S/$f: run kernel, dtb and initramfs first"
  done
  image_size_check "$S/Image-waffle"
  rm -rf "$I" && mkdir -p "$I"/ramboot "$I"/parts
  : | cpio -o -H newc --quiet > "$S/empty.cpio"
  for v in $VARIANTS; do
    say "uniLoader ($v, overlap-safe relocation)"
    # reloc-safe: without it uniLoader corrupts itself on this ABL (bisect
    # 2026-11-20: v1/stock uniLoader froze, v2/reloc-safe booted).
    uniloader_build "$v" "" "" "" reloc-safe
    local sfx=""; [[ $v == plain ]] || sfx=-$v
    # (A) header v4, as stock boot_a: kernel only, empty cmdline, stock
    # os_version/patch level. ABL takes the stock DTB (vendor_boot) + dtbo +
    # ramdisks from flash as for a normal boot; uniLoader ignores all of it.
    mkbootimg --header_version 4 --kernel "$S/uniLoader-$v.bin" --cmdline '' \
      --os_version "$OS_VERSION" --os_patch_level "$OS_PATCH_LEVEL" \
      --output "$I/ramboot/waffle-uniloader-v4$sfx.img"
    # (B) header v2 fallback with the stock DTBs in its DTB section (only
    # with STOCK_BACKUP; the file then contains OnePlus's DTB: keep it local).
    if [[ -f /stock/vendor_boot_a.img ]]; then
      stock_v2 "$v" "$I/ramboot/waffle-uniloader-v2-stockdtb$sfx.img"
    fi
    cp "$S/uniLoader-$v.bin" "$I/parts/"
  done
  cp "$S/Image-waffle" "$I/parts/Image"
  cp "$S"/sm8650-oneplus-waffle-fap*.dtb "$S/initramfs.cpio.gz" "$I/parts/"
  cp "$S/kernel-waffle.config" "$I/parts/kernel.config"
  local kver; kver=$(cat "$S/kernel-release-waffle")
  tar -C "$S/modroot-waffle" -czf "$I/parts/modules-$kver.tar.gz" lib/modules

  say "Check: unpack every boot image"
  for f in "$I"/ramboot/*.img; do
    unpack_bootimg --boot_img "$f" --out /tmp/unpack | grep -E "header version|kernel_size|os version|os patch" | tr '\n' ' '
    echo " <- $(basename "$f")"
  done

  say "Copy out"
  rm -rf /out/ramboot /out/parts
  rm -f /out/SHA256SUMS /out/BUILDINFO
  cp -r "$I"/ramboot "$I"/parts /out/
  {
    echo "kernel: $(cat "$S/kernel-source") ($kver)"
    if [[ $(cat "$S/kernel-config-mode-waffle") == full ]]; then
      echo "kernel config (full): Fedora kernel-aarch64-fedora.config (kernel-7.3.4-300.fc45) + kernels/qcom-sm8650/fap.config + build-env/waffle.config + build-env/build.config, other SoC platforms off"
    else
      echo "kernel config (slim): arm64 defconfig, other SoC platforms off, + kernels/qcom-sm8650/fap.config + build-env/waffle.config + build-env/build.config"
    fi
    echo "uniLoader: $UNILOADER_URL $UNILOADER_COMMIT waffle_defconfig (TEXT_BASE $UL_TEXT_BASE, PAYLOAD_ENTRY $UL_PAYLOAD_ENTRY, RAMDISK_ENTRY $UL_RAMDISK_ENTRY)"
    echo "compiler: $(gcc --version | head -1)"
    echo "busybox: $(rpm -q busybox)"
    echo "boot image: header v4, os_version $OS_VERSION, os_patch_level $OS_PATCH_LEVEL"
    echo "repo: $(git -c safe.directory='*' -C /repo rev-parse --short HEAD 2>/dev/null || echo '?')"
  } > /out/BUILDINFO
  (cd /out && find ramboot parts -type f | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
  cat /out/BUILDINFO
  (cd /out && ls -l ramboot parts)
}

stock_v2() {   # stock_v2 <variant> <out.img>: uniLoader + stock vendor_boot DTBs, header v2
  local v=$1 o=$2 T=/tmp/stock-vb
  rm -rf "$T" && unpack_bootimg --boot_img /stock/vendor_boot_a.img --out "$T" >/dev/null
  [[ -s $T/dtb ]] || die "stock vendor_boot has no DTB"
  # Addresses from the stock vendor_boot header (v2 has them in boot.img).
  local info; info=$(unpack_bootimg --boot_img /stock/vendor_boot_a.img --out "$T" --format mkbootimg)
  local base kofs rofs tofs dofs
  base=$(sed -n 's/.*--base \([^ ]*\).*/\1/p' <<< "$info")
  kofs=$(sed -n 's/.*--kernel_offset \([^ ]*\).*/\1/p' <<< "$info")
  rofs=$(sed -n 's/.*--ramdisk_offset \([^ ]*\).*/\1/p' <<< "$info")
  tofs=$(sed -n 's/.*--tags_offset \([^ ]*\).*/\1/p' <<< "$info")
  dofs=$(sed -n 's/.*--dtb_offset \([^ ]*\).*/\1/p' <<< "$info")
  mkbootimg --header_version 2 --pagesize 4096 --base "${base:-0}" --kernel_offset "${kofs:-0x8000}" \
    --ramdisk_offset "${rofs:-0x1000000}" --tags_offset "${tofs:-0x100}" --dtb_offset "${dofs:-0x1f00000}" \
    --kernel "$S/uniLoader-$v.bin" --ramdisk "$S/empty.cpio" --dtb "$T/dtb" --cmdline '' \
    --os_version "$OS_VERSION" --os_patch_level "$OS_PATCH_LEVEL" --output "$o"
}

# DSP/modem firmware from the unit's modem_a partition (vfat, read with
# mtools from the read-only backup image; nothing is mounted) and EFS copies.
NETROOT_FW_GLOBS="adsp.* adsp_dtb.* cdsp.* cdsp_dtb.* modem.* modem_dtb.* ipa_fws.* modem_pr modem_oem"
netroot_phone_files() {   # netroot_phone_files <root>
  local R=$1 F=$1/usr/lib/firmware/qcom/sm8650/oneplus/waffle M=/work/stage/fw-modem g
  command -v mcopy >/dev/null || dnf -y -q install mtools >/dev/null
  rm -rf "$M" && mkdir -p "$M" "$F"
  MTOOLS_SKIP_CHECK=1 mcopy -s -n -i /backup/modem_a.img ::/image "$M/"
  (cd "$M/image" && for g in $NETROOT_FW_GLOBS; do cp -a $g "$F/"; done)
  for g in adsp.mdt adsp_dtb.mdt cdsp.mdt cdsp_dtb.mdt modem.mdt modem_dtb.mdt ipa_fws.mdt; do
    [[ -f $F/$g ]] || die "modem_a.img has no image/$g"
  done
  echo "firmware: $(du -sh "$F" | cut -f1) in /usr/lib/firmware/qcom/sm8650/oneplus/waffle"
  mkdir -p "$R/usr/lib/fap-efs"
  local p
  for p in modemst1:modem_fs1 modemst2:modem_fs2 fsg:modem_fsg fsc:modem_fsc; do
    [[ -f /backup/${p%%:*}.img ]] || die "no ${p%%:*}.img in PHONE_BACKUP"
    install -m 600 "/backup/${p%%:*}.img" "$R/usr/lib/fap-efs/${p##*:}"
  done
  echo "EFS copies: $(ls "$R/usr/lib/fap-efs" | tr '\n' ' ')"
}

# v6: Fedora packages for audio tests, the USB DHCP server and time sync, the AudioReach
# topology for the sound card and our UCM config. Everything comes from
# Fedora 45's repositories (signature-checked rpms); nothing from the phone.
# chrony: v5's netroot had none, so the clock stayed wrong after boot (no
# RTC time the kernel trusts); it syncs once Wi-Fi is up.
NETROOT_PKGS="alsa-utils alsa-ucm alsa-ucm-utils dnsmasq chrony"
# v7: GPU userspace + test tools, Bluetooth, haptics (fftest) and V4L2 tools.
NETROOT_PKGS_V7="mesa-dri-drivers mesa-vulkan-drivers egl-utils kmscube glmark2 vulkan-tools bluez linuxconsoletools v4l-utils"
# The card is driver "sm8650", name "OnePlus 12" (board DT model), so q6apm
# asks for qcom/sm8650/OnePlus 12-tplg.bin. Its back ends are SM8650-QRD's
# (RX_CODEC_DMA_RX_0, TX_CODEC_DMA_TX_3); qcom-firmware's SM8650-QRD/MTP/HDK
# topologies are all symlinks to this one generic file.
TPLG_SRC=usr/lib/firmware/qcom/kaanapali/Kaanapali-MTP-tplg.bin.xz
TPLG_NAME="qcom/sm8650/OnePlus 12-tplg.bin.xz"
netroot_audio_dhcp() {   # netroot_audio_dhcp <root>
  local R=$1 P=/work/stage/netroot-rpms
  say "netroot: $NETROOT_PKGS (Fedora 45) + AudioReach topology + UCM"
  dnf5 -y -q --installroot="$R" --use-host-config --releasever=45 \
    --setopt=install_weak_deps=False install $NETROOT_PKGS $NETROOT_PKGS_V7
  dnf5 -y -q --installroot="$R" --use-host-config --releasever=45 clean all >/dev/null
  qcom_firmware_rpm "$P" "./$TPLG_SRC"
  [[ -s $P/$TPLG_SRC ]] || die "qcom-firmware has no $TPLG_SRC"
  install -D -m 644 "$P/$TPLG_SRC" "$R/usr/lib/firmware/$TPLG_NAME"
  echo "topology: $(basename "$P"/qcom-firmware-*.rpm) $TPLG_SRC -> /usr/lib/firmware/$TPLG_NAME ($(sha256sum < "$P/$TPLG_SRC" | cut -c1-16)…)"
  mkdir -p "$R/usr/share/alsa/ucm2/conf.d/sm8650"
  cp -a "$DEV/ucm/OnePlus" "$R/usr/share/alsa/ucm2/"
  ln -sf ../../OnePlus/waffle/waffle.conf "$R/usr/share/alsa/ucm2/conf.d/sm8650/OnePlus 12.conf"
  [[ -f $R/usr/share/alsa/ucm2/codecs/wcd939x/init.conf ]] || die "alsa-ucm lacks codecs/wcd939x"
  [[ -x $R/usr/sbin/dnsmasq ]] || die "no dnsmasq in the netroot"
  # (chrony's preset scriptlet usually does this already; no systemctl here)
  mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/chronyd.service "$R/etc/systemd/system/multi-user.target.wants/chronyd.service"
  rm -rf "$P"
}

# Fedora's qcom-firmware rpm (signature-checked), unpacking only the given
# paths into <dir>: qcom_firmware_rpm <dir> <./path>...
qcom_firmware_rpm() {
  local P=$1; shift
  rm -rf "$P" && mkdir -p "$P"
  (cd "$P" && dnf5 -q --releasever=45 download qcom-firmware >/dev/null)
  rpmkeys -K "$P"/qcom-firmware-*.rpm | grep -q 'digests signatures OK' || die "qcom-firmware rpm signature"
  (cd "$P" && rpm2cpio qcom-firmware-*.rpm | cpio -idm --quiet "$@")
  echo "qcom-firmware: $(basename "$P"/qcom-firmware-*.rpm)"
}

# v7 GPU firmware (Adreno 750, msm "gen70900"), reusable for any root:
# gpu_firmware <root>. SQE + GMU from Fedora (paths the driver asks for:
# qcom/gen70900_sqe.fw, qcom/gmu_gen70900.bin; .xz is fine, FW_LOADER_COMPRESS
# is on); zap shader from the unit's /vendor/firmware (OnePlus-signed), at
# the DT's firmware-name. Mesa (freedreno/turnip) comes from the root's own
# packages (mesa-dri-drivers, mesa-vulkan-drivers); no LIBGL_ALWAYS_SOFTWARE.
GPU_FW_FEDORA="usr/lib/firmware/qcom/gen70900_sqe.fw.xz usr/lib/firmware/qcom/gmu_gen70900.bin.xz"
GPU_ZAP=vendor/firmware/gen70900_zap.mbn
WAFFLE_FW=usr/lib/firmware/qcom/sm8650/oneplus/waffle
gpu_firmware() {   # gpu_firmware <root>
  local R=$1 P=/work/stage/gpu-rpm f paths=()
  [[ -d /vendor-files ]] || die "set VENDOR_FILES (for $GPU_ZAP)"
  for f in $GPU_FW_FEDORA; do paths+=("./$f"); done
  qcom_firmware_rpm "$P" "${paths[@]}"
  for f in $GPU_FW_FEDORA; do
    [[ -s $P/$f ]] || die "qcom-firmware has no $f"
    install -D -m 644 "$P/$f" "$R/$f"
  done
  vendor_file "$GPU_ZAP" "$R/$WAFFLE_FW/gen70900_zap.mbn"
  rm -rf "$P"
  echo "GPU firmware: $GPU_FW_FEDORA (Fedora) + $WAFFLE_FW/gen70900_zap.mbn (unit)"
}

# vendor_file <vendor/... path> <dest>: one file from the unit's vendor copy,
# checked against the phone-side manifest (sha256 taken on the phone).
vendor_file() {
  local want got
  want=$(awk -v f="$1" '$2 == f {print $1}' /vendor-files/phone-manifest.sha256)
  [[ -n $want ]] || die "$1 not in phone-manifest.sha256"
  got=$(sha256sum < "/vendor-files/tree/$1" | cut -d' ' -f1)
  [[ $got == "$want" ]] || die "$1: sha256 $got, manifest says $want"
  install -D -m 644 "/vendor-files/tree/$1" "$2"
}

# v7 Bluetooth firmware from the unit's bluetooth_a partition (vfat, read
# with mtools from the read-only image): image/hmtbtfw*.tlv, hmtnv*. Into
# /usr/lib/firmware/updates/qca, which the firmware loader searches before
# /usr/lib/firmware, so they win over Fedora's generic atheros-firmware
# copies without replacing them.
netroot_bt_firmware() {   # netroot_bt_firmware <root>
  local R=$1 M=/work/stage/fw-bt D=$1/usr/lib/firmware/updates/qca
  [[ -f /backup/bluetooth_a.img ]] || die "no bluetooth_a.img in PHONE_BACKUP"
  command -v mcopy >/dev/null || dnf -y -q install mtools >/dev/null
  rm -rf "$M" && mkdir -p "$M" "$D"
  MTOOLS_SKIP_CHECK=1 mcopy -s -n -i /backup/bluetooth_a.img ::/image "$M/"
  cp -a "$M"/image/hmtbtfw* "$M"/image/hmtnv* "$D/"
  [[ -f $D/hmtbtfw20.tlv && -f $D/hmtnv20.bin ]] || die "bluetooth_a has no hmtbtfw20.tlv/hmtnv20.bin"
  echo "BT firmware: $(ls "$D" | wc -l) files in /usr/lib/firmware/updates/qca (bluetooth_a)"
  rm -rf "$M"
  # bluez's preset usually enables it already; make sure (no systemctl here).
  mkdir -p "$R/etc/systemd/system/bluetooth.target.wants"
  ln -sf /usr/lib/systemd/system/bluetooth.service "$R/etc/systemd/system/bluetooth.target.wants/bluetooth.service"
  ln -sf /usr/lib/systemd/system/bluetooth.service "$R/etc/systemd/system/dbus-org.bluez.service"
}

cmd_gpu_firmware() {
  local R=/work/gpu-fw-root
  rm -rf "$R" && mkdir -p "$R"
  gpu_firmware "$R"
  mkdir -p /out/gpu-firmware
  (cd "$R" && tar -czf /out/gpu-firmware/waffle-gpu-firmware.tar.gz usr)
  printf '%s\n' "SENSITIVE: contains OnePlus firmware from this unit's /vendor (gen70900_zap.mbn). Local only; never commit or upload." \
    > /out/gpu-firmware/SENSITIVE-README.txt
  rm -rf "$R"
  (cd /out/gpu-firmware && sha256sum waffle-gpu-firmware.tar.gz > SHA256SUMS && cat SHA256SUMS && tar -tzvf waffle-gpu-firmware.tar.gz)
}

cmd_netroot() {
  [[ -f /netroot-generic.tar.gz ]] || die "set NETROOT_GENERIC=<generic netroot.tar.gz>"
  local kver R=/work/netroot-root D=/out/$NETROOT_OUTDIR; kver=$(cat "$S/kernel-release-waffle")
  say "netroot: generic tarball + modules $kver -> $D"
  rm -rf "$R" && mkdir -p "$R"
  tar -xzf /netroot-generic.tar.gz -C "$R"
  # Only this kernel's modules: the generic root carries Fedora's (from the
  # netroot's KERNEL_IMAGE), which can't load into our kernel.
  rm -rf "$R/usr/lib/modules" && mkdir -p "$R/usr/lib/modules"
  cp -a "$S/modroot-waffle/lib/modules/$kver" "$R/usr/lib/modules/"
  # Waffle overlay (replaces the N100 fap-modem-ram of the generic tarball).
  cp -a "$DEV/netroot/." "$R/"
  netroot_audio_dhcp "$R"
  if [[ -d /backup ]]; then
    netroot_phone_files "$R"
    netroot_bt_firmware "$R"
  else
    echo "no PHONE_BACKUP: netroot without DSP/BT firmware and EFS copies"
  fi
  if [[ -d /vendor-files ]]; then
    gpu_firmware "$R"
    vendor_file vendor/firmware/vpu33_4v.mbn "$R/$WAFFLE_FW/vpu33_4v.mbn"
    echo "Iris firmware: $WAFFLE_FW/vpu33_4v.mbn (unit)"
  else
    echo "no VENDOR_FILES: netroot without GPU zap shader and Iris firmware"
  fi
  echo "unpacked: $(du -sxm "$R" | cut -f1) MiB (tiny-init tmpfs: fap.netroot_size= in the netroot DT)"
  mkdir -p "$D"
  (cd "$R" && tar -czf "$D/netroot.tar.gz" .)
  rm -rf "$R"
  (cd "$D" && sha256sum netroot.tar.gz > SHA256SUMS && ls -l)
}

# Crash bisect (first RAM boot ended in crashdump 900e with no uniLoader or
# kernel text). Each variant changes one thing; see OUT/bisect/BISECT.md.
cmd_bisect() {
  local B=$S/bisect f
  for f in Image-waffle Image-waffle-daddevil initramfs/init sm8650-oneplus-waffle-fap.dtb; do
    [[ -e $S/$f ]] || die "missing $S/$f: run 'all' and '--daddevil kernel' first"
  done
  rm -rf "$B" && mkdir -p "$B"
  # v1: DaDDevil's recipe. His board DTB exactly as the tree builds it (his
  # memory map, his bootargs: root=PARTUUID of his unit, rootwait), his
  # waffle_defconfig kernel, stock uniLoader waffle_defconfig. Ramdisk: our
  # busybox + tiny-init without modules (theirs wouldn't match his kernel).
  say "bisect v1: DaDDevil recipe"
  (cd "$K" && make -s ARCH=arm64 O=/work/out-dtb qcom/sm8650-oneplus-waffle.dtb)
  cp /work/out-dtb/arch/arm64/boot/dts/qcom/sm8650-oneplus-waffle.dtb "$B/board.dtb"
  echo "board DTB bootargs: $(fdtget "$B/board.dtb" /chosen bootargs)"
  rm -rf "$B/rd" && cp -a "$S/initramfs" "$B/rd" && rm -f "$B/rd/lib/modules/"* && : > "$B/rd/etc/modules.order"
  (cd "$B/rd" && find . | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0 | gzip -9n) > "$B/initramfs-nomod.cpio.gz"
  image_size_check "$S/Image-waffle-daddevil"
  uniloader_build bisect-v1 "$S/Image-waffle-daddevil" "$B/board.dtb" "$B/initramfs-nomod.cpio.gz"
  # v2: our first image (plain), only uniLoader's relocation made overlap-safe.
  say "bisect v2: our plain image, overlap-safe uniLoader relocation"
  uniloader_build bisect-v2 "$S/Image-waffle" "$S/sm8650-oneplus-waffle-fap.dtb" "$S/initramfs.cpio.gz" reloc-safe
  mkdir -p /out/bisect
  local v n
  for v in v1 v2; do
    case $v in v1) n=waffle-bisect-v1-daddevil.img ;; v2) n=waffle-bisect-v2-relocsafe.img ;; esac
    mkbootimg --header_version 4 --kernel "$S/uniLoader-bisect-$v.bin" --cmdline '' \
      --os_version "$OS_VERSION" --os_patch_level "$OS_PATCH_LEVEL" --output "/out/bisect/$n"
    unpack_bootimg --boot_img "/out/bisect/$n" --out /tmp/unpack | grep -E "header version|kernel_size" | tr '\n' ' '
    echo " <- $n"
    cp "$S/uniLoader-bisect-$v.bin" "/out/bisect/uniLoader-bisect-$v.bin"
  done
  cp "$S/kernel-waffle-daddevil.config" /out/bisect/kernel-daddevil.config
  (cd /out/bisect && sha256sum waffle-bisect-*.img uniLoader-bisect-*.bin kernel-daddevil.config > SHA256SUMS && cat SHA256SUMS)
}

[[ $# -ge 1 ]] || die "usage: fap-waffle-build.sh [--full|--daddevil] kernel|config-check|dtb|initramfs|images|netroot|gpu-firmware|all|bisect|shell"
for c in "$@"; do
  case $c in
    kernel) cmd_kernel ;;
    config-check) cmd_config_check ;;
    dtb) cmd_dtb ;;
    initramfs) cmd_initramfs ;;
    images) cmd_images ;;
    netroot) cmd_netroot ;;
    gpu-firmware) cmd_gpu_firmware ;;
    all) cmd_kernel; cmd_dtb; cmd_initramfs; cmd_images ;;
    bisect) cmd_bisect ;;
    shell) exec bash ;;
    *) die "unknown command $c" ;;
  esac
done
