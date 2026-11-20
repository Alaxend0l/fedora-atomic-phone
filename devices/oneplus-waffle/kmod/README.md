<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Out-of-tree kernel modules for OnePlus 12

One directory per module, each with a `Makefile` (`obj-m += <name>.o`), the
source (first line `// SPDX-License-Identifier: GPL-2.0-only`) and a
README.md: what it drives, where the protocol/values come from, how it was
tested, and what upstreaming needs. Modules useful beyond this phone belong
in the top-level `kmod/` instead.

Build against a Fedora kernel:
```sh
tools/build-kmod.sh devices/oneplus-waffle/kmod/<module> <kver> out/kmod
```
CI builds every module here against the newest Fedora kernel-devel.

Generated panel drivers (lmdpdg) go here too; see
devices/oneplus-billie2/kmod/panel-ili9882n/ and docs/porting-cookbook.md.
