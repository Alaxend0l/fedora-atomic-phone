<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# N100: things that only work because something else left them on

Audit of 2026-11-20 after Plasma Mobile was GPU-bound and USB failed on
normal boots. Class of bug: mainline DT (or our board DT) never claims a
clock, power domain, supply or bandwidth vote; it works anyway because the
bootloader (ABL) or another device left it on. ABL leaves different state in
fastboot mode than on a normal boot, and we boot with
`clk_ignore_unused pd_ignore_unused`, which hides all of it.

How to look (on the phone, as root):
- unclaimed clocks: `awk 'NR>3 && $2==0 && $9=="Y" {print $1}' /sys/kernel/debug/clk/clk_summary`
- bandwidth votes: `/sys/kernel/debug/interconnect/interconnect_summary`
- power domains: `/sys/kernel/debug/pm_genpd/pm_genpd_summary`
- supplies: `dmesg | grep "using dummy regulator"`
- per-boot snapshot + benchmark: `/var/log/fap-boot-state/` (fap-boot-state.service)

| Finding | Effect | Status |
|---|---|---|
| GPU node has no `interconnects`, OPPs no `opp-peak-kBps` (mainline sm6115.dtsi) | GPU never votes DDR bandwidth; EBI stays at the display's ~0.8 GB/s; Plasma GPU-bound at 600 MHz | fixed in board DT (agatti values); verified: GPU votes 3.88 GB/s at 600 MHz, EBI peak ~4 GB/s |
| USB: HS-only wiring without `qcom,select-utmi-as-pipe-clk` | DWC3 needs a PIPE clock; only present after fastboot mode (USB3 PHY pipe clock left on); normal boot: "failed to enable ep0out", no USB | fixed in board DT; verified: gadget enumerates after a normal boot |
| UFS has no bandwidth vote; SM6115 RPM interconnect driver has no UFS node | UFS relies on others' DDR votes; 381 MB/s (Gear 3, 1 lane; ~580 MB/s raw max) | needs a driver change (icc-rpm sm6115 node for UFS); not urgent |
| `gcc_gpu_iref_clk` on but unclaimed | GPU may misbehave once `clk_ignore_unused` is dropped | check against agatti's GPU clock list before dropping it |
| display: `gcc_disp_throttle_core_clk`, `gcc_disp_gpll0_clk_src`, `disp_cc_sleep_clk` unclaimed | display may break without `clk_ignore_unused` | same |
| CPU thermal zones have no cooling maps (see docs/hardware/n100-power-and-install.md) | passive trips do nothing; only the 110 °C critical shutdown acts | to add (cpufreq cooling maps) |
| UBWC parameters GPU vs display mismatch | tile garbage; worked around with `FD_MESA_DEBUG=noubwc` (costs bandwidth) | open |
| Wi-Fi MAC random each boot (`ath10k: invalid MAC address`) | new MAC per boot (DHCP leases, router lists) | open: DT `local-mac-address` from the factory value |
| Modem started very early at boot stalls ("DOG detects stalled initialization") | no Wi-Fi until the retry | worked around: fap-modem-ram retries. Likely cause (2026-11-20 log): `qrtr: failed to announce new service` at 25 s, then `failed while handling packet from 0:-2` and the watchdog at 65 s: rmtfs/tqftpserv announce before the modem's QRTR node is up, so the modem never learns of them. Fix idea: start the services, wait for the modem node (qrtr-lookup shows node 0 services), re-announce (restart) |

Dummy regulators seen and judged harmless: GPU vdd/vddcx (power via GPU
power domains, as on agatti), Wi-Fi vdd-3.3-ch1 (second chain unused), DSI
refgen (optional).

Goal: boot without `clk_ignore_unused pd_ignore_unused` (RAM boot only)
once the rows above are handled; whatever breaks then is the next finding.
