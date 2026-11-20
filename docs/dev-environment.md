# Development environment

Images are aarch64. Build on aarch64 to avoid emulation.

## On an Apple Silicon Mac
Apple Silicon is aarch64, so a Linux VM runs natively.

**Option A: podman machine** (simplest for `just build`):
```sh
brew install podman just
podman machine init --cpus 6 --memory 8192 --disk-size 100 --rootful
podman machine start
```
Building works inside it. `just disk` (image-builder) needs privileged
containers and loop devices; the rootful machine provides both, but verify on
first use.

**Option B: a Fedora VM** (UTM or Lima) when you want a full Linux userspace
(U-Boot builds, `mkbootimg`, `img2simg`, kernel work):
```sh
sudo dnf install podman just git make gcc bison flex openssl-devel \
    android-tools dtc python3 util-linux
```
`android-tools` provides `fastboot`, `adb`, `mkbootimg`, `img2simg`.
USB passthrough of a phone into a VM is often unreliable, especially in EDL
mode; run `fastboot`/`adb`/`qdl` on the Mac itself (Homebrew `android-platform-tools`).

## On the phone side
- `fastboot`, `adb` (Homebrew: `android-platform-tools`)
- `qdl` for EDL recovery (Linaro; built in `../qdl/build/qdl` on this machine)

## Kernel work
Clone mainline and the U-Boot tree inside the Fedora VM. Keep sources out of
this repo; reference them by path.
