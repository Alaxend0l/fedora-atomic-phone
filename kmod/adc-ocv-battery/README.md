<!-- SPDX-License-Identifier: GPL-2.0-only -->
# adc-ocv-battery

A read-only battery `power_supply` for phones whose fuel gauge has no mainline
driver yet (first user: the N100's PMI632, whose QGauge isn't in mainline).

- voltage: IIO channel `vbat` (e.g. PMIC ADC5 `vbat_sns`)
- capacity: the `monitored-battery` node's `ocv-capacity-table-0`
  (`simple-battery` binding), at 25 °C
- status: Charging/Full if the optional IIO channel `usbin` reads > 4.0 V,
  else Discharging

Approximate by design: under load or while charging the voltage differs from
open-circuit voltage. It never touches the charger. Replace with a real
fuel-gauge driver when one exists.

Build: `tools/build-kmod.sh kmod/adc-ocv-battery <kver> <outdir>`.
