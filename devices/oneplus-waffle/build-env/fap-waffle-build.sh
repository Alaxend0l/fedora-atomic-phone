#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# OnePlus 12 (waffle) build environment: kernel, DTBs, debug initramfs and
# RAM-boot images for first light. Builds only; never talks to a phone.
#
#   devices/oneplus-waffle/build-env/fap-waffle-build.sh <command>...
#
#   kernel        fetch + configure + build Image and modules (KERNEL_TREE)
#   config-check  only configure (olddefconfig + fragment check); with
#                 KERNEL_TREE=fedora this is the "does our fragment work on
#                 Fedora's own 7.3.4 tree" check
#   dtb           our first-light DTBs (dts/*.dts, built in the waffle tree)
#   initramfs     static busybox + boot/android-bootimg/tiny-init + modules
#   images        uniLoader per variant, wrapped in boot images (ramboot/)
#   netroot       generic netroot tarball + this kernel's modules (optional)
#   all           kernel dtb initramfs images
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
#   JOBS           parallel jobs (default 5; the podman VM has 2 GiB, no swap)
#   STOCK_BACKUP   host dir with the phone's partition backup; only
#                  vendor_boot_a.img is read (read-only mount) for the
#                  header-v2 fallback image. Optional.
#   NETROOT_GENERIC  host path of a generic netroot.tar.gz (netroot command)
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
  [[ -n ${NETROOT_GENERIC:-} ]] && extra+=(-v "$(cd "$(dirname "$NETROOT_GENERIC")" && pwd)/$(basename "$NETROOT_GENERIC"):/netroot-generic.tar.gz:ro")
  tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)
  exec podman run --rm ${tty[@]+"${tty[@]}"} -v "$VOLUME:/work" -v "$REPO:/repo:ro" -v "$OUT:/out" \
    ${extra[@]+"${extra[@]}"} -e FAP_WAFFLE_INNER=1 -e JOBS="${JOBS:-5}" \
    -e KERNEL_TREE="${KERNEL_TREE:-waffle}" \
    "$IMAGE" bash /repo/devices/oneplus-waffle/build-env/fap-waffle-build.sh "$@"
fi

# ------------------------------------------------------------- container
say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
DEV=/repo/devices/oneplus-waffle
S=/work/stage
mkdir -p "$S" /work/src
case $KERNEL_TREE in
  waffle) K=/work/linux-waffle ;;
  fedora) K=/work/linux ;;
  *) die "KERNEL_TREE must be waffle or fedora" ;;
esac
KO=/work/out-$KERNEL_TREE
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
    echo "waffle-voice $WAFFLE_COMMIT" > "$S/kernel-source"
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

kconfig() {
  say "Config: Fedora aarch64 + kernels/qcom-sm8650/fap.config$([[ $KERNEL_TREE == waffle ]] && echo ' + waffle.config') + build.config"
  mkdir -p "$KO"
  local frags=(/repo/kernels/qcom-sm8650/fap.config)
  [[ $KERNEL_TREE == waffle ]] && frags+=("$DEV/build-env/waffle.config")
  cp /work/src/srpm/kernel-aarch64-fedora.config "$KO/.config"
  (cd "$K" && scripts/kconfig/merge_config.sh -m -O "$KO" "$KO/.config" "${frags[@]}" \
    "$DEV/build-env/build.config" >/dev/null)
  # Slim: other SoC families off. Only shortens the build and keeps the
  # Image small enough for uniLoader's layout (see UL_* above).
  local a
  for a in $(sed -n 's/^\s*config \(ARCH_[A-Z0-9_]*\)\s*$/\1/p' "$K/arch/arm64/Kconfig.platforms"); do
    [[ $a == ARCH_QCOM ]] || (cd "$K" && scripts/config --file "$KO/.config" --disable "$a")
  done
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
      [[ $want == n ]] && ! grep -q "$sym[= ]" "$KO/.config" && continue
      echo "  $sym: want $want, got $got ($(basename "$f"))"; bad=1
    done < "$f"
  done
  [[ $bad == 0 ]] || die "config fragment not applied (above)"
  echo "fragment check: ok"
  cp "$KO/.config" "$S/kernel-$KERNEL_TREE.config"
}

cmd_config_check() { fetch_srpm; fetch_tree; kconfig; }

cmd_kernel() {
  fetch_srpm; fetch_tree; kconfig
  say "Build Image + modules ($KERNEL_TREE, -j$JOBS)"
  (cd "$K" && "${MK[@]}" -j"$JOBS" Image modules)
  local kver; kver=$(cat "$KO/include/config/kernel.release")
  say "Modules install ($kver)"
  rm -rf "$S/modroot-$KERNEL_TREE"
  (cd "$K" && "${MK[@]}" INSTALL_MOD_PATH="$S/modroot-$KERNEL_TREE" INSTALL_MOD_STRIP=1 modules_install)
  rm -f "$S/modroot-$KERNEL_TREE/lib/modules/$kver/build" "$S/modroot-$KERNEL_TREE/lib/modules/$kver/source"
  cp "$KO/arch/arm64/boot/Image" "$S/Image-$KERNEL_TREE"
  echo "$kver" > "$S/kernel-release-$KERNEL_TREE"
  image_size_check "$S/Image-$KERNEL_TREE"
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

uniloader_build() {   # uniloader_build <variant>
  local v=$1 U=/work/uniloader-$1
  rm -rf "$U"
  if [[ ! -d /work/src/uniLoader/.git ]]; then
    git clone -q "$UNILOADER_URL" /work/src/uniLoader
  fi
  git -C /work/src/uniLoader fetch -q origin 2>/dev/null || true
  git -C /work/src/uniLoader checkout -q -f --detach "$UNILOADER_COMMIT"
  cp -a /work/src/uniLoader "$U"
  cp "$S/Image-waffle" "$U/blob/Image"
  cp "$S/sm8650-oneplus-waffle-fap$([[ $v == plain ]] || echo "-$v").dtb" "$U/blob/dtb"
  cp "$S/initramfs.cpio.gz" "$U/blob/ramdisk"
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
  local sz rd
  sz=$(stat -c %s "$S/uniLoader-$v.bin"); rd=$(stat -c %s "$S/initramfs.cpio.gz")
  (( UL_TEXT_BASE + sz + (4 << 20) < UL_RAMDISK_ENTRY )) || die "uniLoader-$v.bin overlaps RAMDISK_ENTRY"
  (( UL_RAMDISK_ENTRY + rd < UL_BANK_END )) || die "ramdisk leaves the bank"
  printf 'uniLoader-%s.bin: %d MiB (ends %#x; ramdisk %#x-%#x)\n' "$v" $((sz >> 20)) \
    $((UL_TEXT_BASE + sz)) "$UL_RAMDISK_ENTRY" $((UL_RAMDISK_ENTRY + rd))
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
    say "uniLoader ($v)"
    uniloader_build "$v"
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
    echo "kernel config: Fedora kernel-aarch64-fedora.config (kernel-7.3.4-300.fc45) + kernels/qcom-sm8650/fap.config + build-env/waffle.config + build-env/build.config"
    echo "uniLoader: $UNILOADER_URL $UNILOADER_COMMIT waffle_defconfig (TEXT_BASE $UL_TEXT_BASE, PAYLOAD_ENTRY $UL_PAYLOAD_ENTRY, RAMDISK_ENTRY $UL_RAMDISK_ENTRY)"
    echo "compiler: $(gcc --version | head -1)"
    echo "busybox: $(rpm -q busybox)"
    echo "boot image: header v4, os_version $OS_VERSION, os_patch_level $OS_PATCH_LEVEL"
    echo "repo: $(git -C /repo rev-parse --short HEAD 2>/dev/null || echo '?')"
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

cmd_netroot() {
  [[ -f /netroot-generic.tar.gz ]] || die "set NETROOT_GENERIC=<generic netroot.tar.gz>"
  local kver R=/work/netroot-root; kver=$(cat "$S/kernel-release-waffle")
  say "netroot: generic tarball + modules $kver"
  rm -rf "$R" && mkdir -p "$R"
  tar -xzf /netroot-generic.tar.gz -C "$R"
  mkdir -p "$R/usr/lib/modules"
  cp -a "$S/modroot-waffle/lib/modules/$kver" "$R/usr/lib/modules/"
  mkdir -p /out/netroot
  (cd "$R" && tar -czf /out/netroot/netroot.tar.gz .)
  rm -rf "$R"
  (cd /out/netroot && sha256sum netroot.tar.gz > SHA256SUMS && ls -l)
}

[[ $# -ge 1 ]] || die "usage: fap-waffle-build.sh kernel|config-check|dtb|initramfs|images|netroot|all|shell"
for c in "$@"; do
  case $c in
    kernel) cmd_kernel ;;
    config-check) cmd_config_check ;;
    dtb) cmd_dtb ;;
    initramfs) cmd_initramfs ;;
    images) cmd_images ;;
    netroot) cmd_netroot ;;
    all) cmd_kernel; cmd_dtb; cmd_initramfs; cmd_images ;;
    shell) exec bash ;;
    *) die "unknown command $c" ;;
  esac
done
