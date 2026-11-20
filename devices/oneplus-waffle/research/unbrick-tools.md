<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12 unbrick tools (and what works from a Mac)

Desk research, 2026-11-20. **Nothing here is tested by us.** Every
third-party loader and tool named below is an untrusted binary; treat it
like the N100's MSM packages (verify hashes, run in a VM where possible).
**[src]** = a source says so, **[guess]** = inference. Raw notes and URLs:
`fap-build/research/oneplus12/notes/boot-unbrick.md`; fetched pages in
`fap-build/research/oneplus12/raw/`.

## Brick levels
| Level | Symptom | Way back |
|---|---|---|
| 0. Our kernel doesn't boot | reboots / hangs / 900E | nothing to do if we used `fastboot boot` (RAM); hold Power ~15 s, phone returns to Android or fastboot |
| 1. Bad `boot`/`vendor_boot`/`dtbo`/`init_boot` on one slot | bootloops to fastboot | bootloader fastboot: re-flash stock images from the matching OTA (`payload-dumper-go`), or `fastboot --set-active=<other>` |
| 2. Bad `super`/`vbmeta`/`recovery` | bootloop, maybe no fastbootd | bootloader fastboot + stock images; LineageOS-style flow |
| 3. Firmware partitions damaged (`abl`, `xbl*`, `tz`, `uefi`, …) or **ARB downgrade** | black screen, USB shows **05c6:9008** (EDL) or 900E (crashdump) | **EDL with an OPLUS-authorised loader** (below). Only path |
| 4. EDL loader refused (Sahara verify fails) | 9008, every tool fails at Sahara | unresolved for at least one EU unit [src: XDA 4786173]; paid "authorised" service or OnePlus service centre |
| 5. Identity lost (`persist`, `ocdt`, `modemst1/2`, `fsg`, `fsc`) | no IMEI / no modem | only from **your own backup** |

## Getting into each mode
| Mode | How | USB id |
|---|---|---|
| Bootloader fastboot | power off, hold **Vol Up + Vol Down + Power** [src: LineageOS waffle wiki `download_boot`]; or `adb reboot bootloader` | 18d1:d00d (standard, guess) |
| fastbootd (userspace) | from recovery "Enter fastboot" or `fastboot reboot fastboot` | same ids, `is-userspace: yes` |
| EDL (Qualcomm 9008) | power off, hold **Vol Up + Vol Down**, plug USB [src: XDA 4786173, 4790901]. Port may drop after ~5 s; one person needed 15–20 tries; may first show **900E "Diagnostic"** (Windows then needs the 9008 driver forced). Works with a locked bootloader. No test points published | 05c6:9008 |
| Crashdump | after a fatal error (ios-waffle hit it repeatedly during experiments) | 05c6:900e |
| Exit EDL/crashdump | hold Power (+ Vol Up) 10–15 s | |

## Official tooling: not available to us
- **No public MSM Download Tool for the OnePlus 12.** OnePlus/OPPO's
  service tool ("OPlus Flash Tool", e.g. v5.6.44 "for_Sales") requires an
  **authorised service-centre account**; the auth-capture trick that worked
  for the OnePlus 11 / Open never got 8 Gen 3 data [src: XDA 4653536].
- Service centres flash with that tool; one Indian OnePlus 12 with an ARB
  brick was revived this way after first being quoted a board swap
  [src: XDA 4777032].
- Paid remote "authorised EDL" services exist (mgunlock.com, ncunlock;
  XDA user mvikrant97 did 76+ by mid 2024) [src: XDA 4653536,
  <https://mgunlock.com/product/oneplus-12-unbrick-service/>]. They need
  Windows + remote desktop.

## Unofficial EDL (leaked OPLUS-signed loader)
- Loader set ("8g3"): `OPPO_SM8650_New_Chimera_V1.0.21.melf` (firehose) +
  `OPPO_8Gen3_Digest.elf` + `OPPO_8Gen3_Sign.bin` [src: XDA 4786173].
  The **old set fails on ARB=1 phones** ("Failed to send programmer" /
  Sahara verify); an **updated set** attached to XDA 4790901 and
  OplusEdlTool's built-in "SM8650 (8 gen3 NEW)" loader work on ARB=1
  [src: 4790901]. Forum claim: the ARB bump was meant to revoke leaked
  loaders, so future ARB bumps may kill these again [guess, community].
- **OPLUS "VIP" handshake** (why stock Qualcomm tools fail): send the signed
  Digest.elf raw, then `<verify value="ping" EnableVip="1"/>`, then
  Sign.bin (256 B padded to 4096); afterwards every read/write/erase must
  carry `label="<partition>"`, else "label cannot be null"
  [src: bkerler/edl PR #829]. Older equivalent: Qualcomm `fh_loader
  --signeddigests=Digest.mbn --testvipimpact` [src: bkerler/edl issue #605].
- ROMs: EDL ("rawprogram/patch XML") packages of OxygenOS builds circulate,
  e.g. CPH2583 16.0.3.500 / 16.0.5.702; successful ARB=1 recoveries used
  those. **Untick `persist`** when flashing [src: 4790901].

## Tools
| Tool | Platform | OPLUS VIP | Notes |
|---|---|---|---|
| **bkerler/edl** + **PR #829** (fork `2loch-ness6/edl`) | Python + pyusb; **macOS documented** (`brew install libusb`) | **yes (PR)** | tested on OnePlus 12 CPH2581 on 15.0.0.863: GPT of all LUNs, reads ~8 MB/s, writes ~38 MB/s; enforces the digest's permission flags [src: <https://github.com/bkerler/edl/pull/829>]. **The realistic native-Mac path.** Unmerged: pin the commit |
| linux-msm/**qdl** | `brew install qdl`, native | Qualcomm's standard VIP (`--vip-table-path`, tables signed for the device key, `docs/vip.md`) | not OPLUS's label scheme → **likely fails** without patches [guess] |
| OplusEdlTool v2 (salokrwhite) | Windows (.NET/Avalonia), open source | yes | used in successful OP12 ARB=1 recoveries [src: 4790901, <https://github.com/salokrwhite/OplusEdlTool>] |
| OplusEdlTool v3 | Windows, closed | yes | phones home ("verifying"), broke overnight for users [src: 4790901]. Avoid |
| zhlhlf/oplus-9008-tool, snowwolf725/OPlus_EDL_Toolkit (fh_loader GUI), DeepSmartTool | Windows | yes | listed in XDA 4786217 |
| Mark332 "Fastboot unbrick tool" | Windows | n/a (fastboot) | drives an EDL ROM's rawprogram XML over **fastboot/fastbootd**; level 1–2 only; AV flags it [src: XDA 4653452] |
| `payload-dumper-go` (ssut) | macOS native | n/a | extracts images from OxygenOS full OTA `payload.bin` |
| Bartixxx32/Oneplus-antirollchecker | Python | n/a | reads the ARB value from `xbl_config` in an OTA (HTTP range requests, no full download) [src: repo; read-only copy in `fap-build/research/oneplus12/arbchk/`, **not executed**] |

## From a Mac
1. **fastboot/adb**: native (`brew install android-platform-tools`). Covers
   levels 0–2.
2. **EDL**: `bkerler/edl` + PR #829 natively (libusb) is the only open,
   Mac-native path with OPLUS VIP support [src for the code; untested by us
   and by anyone on macOS as far as we found].
3. **Windows tools** (OplusEdlTool, fh_loader GUIs, paid services): a
   Windows ARM VM (UTM/Parallels) with USB passthrough. The EDL port's ~5 s
   timeout and re-enumeration (900E → 9008) may make passthrough flaky
   [guess]; an x86 Windows PC is the safer fallback. CrossOver/Wine: USB
   access to raw devices is not supported in practice [guess, as found for
   the Pixel 8].

## Pre-flight checklist (do once, before the first write of any kind)
1. Note `fastboot getvar all` (product, slot, unlocked, version-bootloader).
   ARB is **not** shown there on recent OPLUS builds [src: XDA 4776403];
   determine it from the installed OxygenOS version: **ARB = 1 from
   16.0.3.500 on** [src: antirollchecker README] (see boot-and-flashing.md).
2. Download the **exact full OTA** of the installed build (Oxygen Updater /
   XDA build repo) and extract it with `payload-dumper-go`; keep SHA256SUMS.
   Check ARB of that OTA with the checker's method.
3. Get an **EDL ROM of a build ≥ the phone's ARB level** (and the same
   region) plus the updated loader set; record hashes.
4. With bootloader unlocked and a RAM-booted Linux (or edl + PR #829 in
   read mode): **back up `persist`, `ocdt`, `modemst1`, `modemst2`, `fsg`,
   `fsc`**, plus `abl`, `xbl*`, `uefi`, `dtbo`, `vendor_boot`, `boot`,
   `init_boot` of both slots, to `backup/` (git-ignored, as on the N100).
   A PJD110 lost its IMEI during EDL work [src: 4790901].
5. **Test** the EDL path read-only (`edl printgpt` / read one small
   partition) before ever needing it.
