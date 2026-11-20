<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 0001: Own framework, Pocketblue as reference

Date: 2026-11-20. Status: accepted.

## Context
[Pocketblue](https://github.com/pocketblue/pocketblue) already builds Fedora
Atomic images for phones (OnePlus 6/6T, Poco F1, Xiaomi Pad 5/6). We want the
same, with adding a phone as easy as in postmarketOS, starting with the
OnePlus Nord N100, which Pocketblue doesn't support.

Measured on 2026-11-20 (pocketblue@893fece): the build pipeline is ~390
lines, all device folders ~970 lines, CI ~550 lines of YAML. The `packages`
repo holds 41 RPM specs (~1,900 lines). The hardware work (kernels, device
trees, U-Boot) comes from upstream projects either way.

## Decision
Write our own small framework on the same standard tools (bootc,
image-builder, COPR, U-Boot). Read Pocketblue for phone-specific lessons; don't
copy its code.

## Reasons
- The pipeline is small; owning it lets us shape the device format for
  contributors (declarative `device.env`, validation, one folder per phone).
- Licensing: the main Pocketblue repo is AGPL-3.0; `pocketblue/packages` has
  no license file, so its specs can't be reused without permission.
- Pocketblue requires contributors to review and disclose LLM use and won't
  support questions referencing AI output. This project is developed with AI
  assistance (reviewed by the maintainer), so keeping it separate avoids
  friction. Upstreaming N100 support to them later stays possible, under
  their rules.
- The N100 work (SM6115 kernel, U-Boot image, firmware handling) is the same
  either way.

## Consequences
- We maintain our own CI and packages.
- Lessons to re-derive or learn from Pocketblue: ESP placement per device,
  4096-byte sectors on UFS, DTB in the ESP, firmware extraction at boot,
  starting remoteprocs, keeping the audio DSP driver out of the initramfs.
