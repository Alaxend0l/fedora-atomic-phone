# Notes for agents working in this repo

Read this first, then [docs/status.md](docs/status.md) (where things stand,
what was tried, what's next). Keep both up to date when you finish a piece of
work; the next agent starts from them.

## What this is
Fedora Atomic (bootc) images for phones, with adding a phone = one folder under
`devices/`. Modeled on postmarketOS's per-device packaging; Pocketblue is a
reference (not a code base, see docs/decisions/0001). First device: OnePlus
Nord N100 (`oneplus-billie2`, SM4250 "bengal").

Companion repo with the N100 research, phone tools and backups:
`/Users/alecjakopin/Develop/UBports-N100` (its own AGENTS.md). Build scratch
space outside both repos: `/Users/alecjakopin/Develop/fap-build/` (U-Boot
checkout, built images). Pocketblue reference clones:
`/Users/alecjakopin/Develop/pocketblue-upstream/` (read-only reference).

## Orientation
| Read | For |
|---|---|
| docs/architecture.md | how images are built and layered |
| boot/README.md | boot methods (`uboot-android`, `android-bootimg`, `lk2nd`) |
| docs/porting.md | adding a device |
| docs/roadmap.md | milestones + porting-tooling plan |
| docs/re-tooling.md | ranked reverse-engineering tool ideas |
| docs/decisions/ | why things are the way they are |
| devices/oneplus-billie2/README.md | N100 hardware, partitions, recovery |
| kernels/qcom-sm6115/README.md | Fedora kernel coverage for the SoC |
| boot/uboot-android/README.md | U-Boot build + the N100 boot experiments |

## Rules
**Safety (the phone is real hardware):**
- Never write `modemst1/2`, `fsg`, `fsc`, `persist`, boot-chain partitions
  (`xbl`, `abl`, `tz`, `hyp`, `rpm`, `aop`, `vbmeta`, …) or firmware
  partitions (`modem`, `dsp`, `bluetooth`). `tools/flash.sh` enforces this;
  don't work around it.
- Never relock the bootloader. Never automate EDL writes.
- Prefer `fastboot boot` (RAM only) over flashing. Before any write, have a
  verified backup and a tested restore command, and ask the user.
- Only one actor talks to the phone at a time. If you delegate research to
  subagents, tell them not to run adb/fastboot.
- A wrong regulator/boost/amp value can damage hardware: pin to vendor values.

**Work style:**
- The maintainer is an experienced developer who reviews everything; write
  code they can follow, and document as you go (docs/, READMEs, decision
  records). Say what's tested and what isn't.
- Commits: one logical change, message says why, end with the
  `Co-Authored-By: Claude …` trailer (see CONTRIBUTING.md AI policy).
  Commit when a step is done; push only when the user asks.
- Don't copy Pocketblue's code (AGPL main repo; `packages` repo unlicensed).
  Read it for lessons.

## Build environment (verified 2026-11-20)
- macOS on Apple Silicon; `podman machine` (arm64, libkrun, 6 CPU, 2 GiB,
  rootless). `just` from Homebrew.
- U-Boot builds in a **Fedora 44** container (Fedora 45's OpenSSL 4.0 lacks the
  ENGINE API U-Boot's host tools need): `just uboot <u-boot-src>` or
  `boot/uboot-android/build-in-container.sh`.
- `just DEVICE=… DESKTOP=… build` hasn't been run yet (2 GiB may be tight).
- Override `just` variables *before* the recipe: `just DEVICE=x check`.

## Phone access
Done from the UBports-N100 repo's `tools/` (adb wrappers, root helper
`psudo.sh` needs `PHONE_PIN` in the environment; ask the user for it, never
commit it). Fastboot rules learned the hard way are in
boot/uboot-android/README.md ("Testing without flashing").
