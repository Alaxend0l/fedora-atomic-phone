<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12: things that only work because something else left them on

Class of bug: the mainline DT (or ours) never claims a clock, power domain,
supply or bandwidth vote, and it works anyway because the bootloader or
another device left it on. Bootloaders leave different state in fastboot
mode than on a normal boot, and booting with `clk_ignore_unused
pd_ignore_unused` hides all of it. Example audit:
[devices/oneplus-billie2/hidden-dependencies.md](../oneplus-billie2/hidden-dependencies.md);
recipe in [docs/porting-cookbook.md](../../docs/porting-cookbook.md).

Run the audit after a **normal** boot and after a `fastboot boot`, and diff.

How to look (on the phone, as root):
```sh
mount -t debugfs none /sys/kernel/debug 2>/dev/null
# clocks that are on but have no consumer (enable count 0, hardware says on)
awk 'NR>3 && $2==0 && $9=="Y" {print $1}' /sys/kernel/debug/clk/clk_summary
# bandwidth votes per path (a GPU/UFS with no line here votes nothing)
cat /sys/kernel/debug/interconnect/interconnect_summary
# power domains: on, with no device attached?
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
# supplies the DT forgot
dmesg | grep "using dummy regulator"
# drivers still waiting for something
cat /sys/kernel/debug/devices_deferred
# regulators that are on, and who holds them
cat /sys/kernel/debug/regulator/regulator_summary
```
Check the clock column layout of `clk_summary` on your kernel first (the
`$9=="Y"` field moved between versions).

| Finding | Effect | Status |
|---|---|---|
| | | |

Dummy regulators seen and judged harmless: (list, with why).

Goal: boot without `clk_ignore_unused pd_ignore_unused` (RAM boot only)
once the rows above are handled; whatever breaks then is the next finding.
