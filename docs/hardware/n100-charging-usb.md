# N100 charging, fuel gauge and USB-C: bring-up plan

Status: **research only, nothing here has been run on the phone** (2026-11-20).
Everything below comes from the vendor DT and dmesg captured under Ubuntu
Touch, the OnePlus GPL kernel, and mainline v7.3. Unverified inferences are
marked **(guess)**. Read the [Safety](#7-safety) section before doing any step
that writes a PMIC register.

## 1. Where we are

- Mainline v7.3 has **no charger driver and no fuel-gauge driver for PMI632**.
  The charger hardware still charges on its own, using whatever ABL/OTP left
  in the registers (see 2.4). Our only battery reporting is
  `kmod/adc-ocv-battery`: it is read-only and estimates capacity from voltage
  with an OCV table.
- USB runs in peripheral mode only (`dr_mode = "peripheral"`, role switch
  deleted in `devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts`). The
  PMI632 Type-C and VBUS nodes are present but disabled.
- Mainline already supports PMI632 **Type-C** (`qcom,pmi632-typec`) and
  **VBUS/OTG** (`qcom,pmi632-vbus-reg`). They are used on the
  `sm6115-fxtec-pro1x` and `qrb4210-rb2` boards. That makes host/OTG the
  easiest real feature to add. Charging control and the fuel gauge need new
  driver code.

## 2. Hardware inventory

### 2.1 PMI632 (SPMI SID 2; SID 3 holds the LPG, vibrator, LCDB and flash)
Source: vendor DT `log/hw-inventory/20261120-134342/device-tree.dts` lines
4518–5096 (`qcom,pmi632@2`). Interrupt cells are `<sid periph irq flags>`, with
vendor flags 1 = rising and 3 = both edges.

| Block | Base | Vendor compatible | Interrupts (index: name) |
|---|---|---|---|
| CHGR | 0x1000 | qcom,qpnp-smb5 | 0 chgr-error, 1 chg-state-change, 2 step-chg-state-change, 3/4 step-chg-soc-update-*, 5 fg-fvcal-qualified, 6 vph-alarm, 7 vph-drop-prechg |
| DCDC (incl. OTG boost) | 0x1100 | ″ | 0 otg-fail, 1 otg-oc-disable-sw, 2 otg-oc-hiccup, 3 bsm-active, 4 high-duty-cycle, 5 input-current-limiting, 6 concurrent-mode-disable, 7 switcher-power-ok |
| BATIF | 0x1200 | ″ | 0 bat-temp, 1 all-chnl-conv-done, 2 bat-ov, 3 bat-low, 4 bat-therm-or-id-missing, 5 bat-terminal-missing, 6 buck-oc, 7 vph-ov |
| USBIN | 0x1300 | ″ | 0 usbin-collapse, 1 usbin-vashdn, 2 usbin-uv, 3 usbin-ov, 4 usbin-plugin, 5 usbin-revi-change, 6 usbin-src-change, 7 usbin-icl-change |
| (no DCIN) | 0x1400 | — | PMI632 has no DC input (qpnp-smb5.c: "PMI632 does not have DC peripheral") |
| TYPEC | 0x1500 | ″ | same 8 as mainline `pmi632.dtsi` |
| MISC | 0x1600 | ″ | 0 wdog-snarl, 1 wdog-bark, 2 aicl-fail, 3 aicl-done, 4 smb-en, 5 imp-trigger, 6 temp-change, 7 temp-change-smb |
| SCHGM flash | 0xa600 | ″ | 2 flash-state-change, 5 ilim1-s1, 6 ilim2-s2, 7 vreg-ok |
| ADC5 (lite) | 0x3100 (cal 0x3700) | qcom,spmi-adc5-lite | — (mainline: `qcom,spmi-adc5`, works today) |
| ADC_TM | 0x3500 | | |
| Temp alarm | 0x2400 | | (mainline driver works today) |
| QGauge | 0x4800 | qcom,qpnp-qg | 0 qg-batt-missing, 1 qg-vbat-low, 2 qg-vbat-empty, 3 qg-fifo-done, 4 qg-good-ocv |
| QG SDAM | 0xb100 | (qg-sdam) | QG's persistent state: SOC, OCV, cycle counts |
| PBS client 3 / SDAM 7 | 0x7400 / 0xb600 | | used by the LPG (already in pmi632.dtsi) |
| GPIO | 0xc000 | | see 2.3 |

PMIC revision: `PMI632 v2.0` (dmesg 3.704). QG subtype 3 = `QG_ADC_IBAT_5A`
(dmesg 4.843, qg-reg.h).

### 2.2 ADC5 channels the charger/gauge use (vendor DT, `pmi632_vadc`)
| Ch | Name | Mainline `qcom-spmi-adc5.c` | Notes |
|---|---|---|---|
| 0x83 | vph_pwr | yes | |
| 0x84 | vbat_sns | yes | our kmod uses it |
| 0x07 | usb_in_i_uv | yes | input current |
| 0x08 | usb_in_v_div_16 | yes | our kmod uses it for "charging" |
| 0x09 | chg_temp | yes | |
| 0x06 | die_temp | yes | |
| 0x4b | bat_id (100 kΩ PU) | yes | ~30 kΩ on this unit means the Desay profile |
| **0x2a** | **bat_therm_30k** (ratiometric, settle 200 µs) | **no** | **the channel QG uses for battery temperature** |
| 0x4a / 0x6a | bat_therm (100k / 400k PU) | no | defined by the vendor but not used |
| 0x52 | usb_temp1 (GPIO1, 100k PU) | yes (`gpio1_100k_pu`) | USB connector NTC |
| 0x55 | usb_temp2 (GPIO4_100K_PU code) | yes (`gpio4_100k_pu`) | 2nd connector NTC. Which pin it is on is unclear: pinctrl puts the ADC on PMI632 gpio6 **(guess)** |
| 0xa5 | i_parallel | no | SMB1355 current sense |

Battery thermistor: 10 kΩ NTC, β = 3380 (`qcom,battery-therm-kohm = 10`,
`qcom,battery-beta = 0xd34`), read through a 30 kΩ internal pull-up. The
OnePlus QG code also adds a current-dependent offset to the voltage before the
table lookup (`qg-util.c`, `g_oneplus_qg_ibta * 6`). How large that offset is
has not been checked **(guess: ground-drop compensation, small)**.

### 2.3 PMI632 GPIOs (vendor pinctrl)
| GPIO | Use | Mainline handling |
|---|---|---|
| 1 | conn_therm / usb_temp1 ADC input (hi-Z) | leave hi-Z |
| 2 | `smb_en`, func1 output: SMB1355 enable, driven by the charger HW | **don't touch** |
| 3 | skin1_therm (hi-Z) | |
| 4 | **`qcom,dischg-gpio`**: VBUS discharge for OnePlus connector-overheat protection. Normal state is `output-low` | **must stay low/unconfigured** |
| 6 | gpio6_adc (hi-Z). The vendor also has a `disp_pins` state on it | |
| 7, 8 | pmi632_sense (hi-Z) | |

### 2.4 Other chips in the charge path
- **SMB1355 parallel charger** on I2C QUP SE1 (`i2c@4a84000`, the bus is
  `i2c-0` under Android), address **0x0c**. IRQ is TLMM gpio 105. Vendor
  peripherals 0x10/0x12/0x13/0x16. It is physically present: dmesg shows
  `SMB1355 v1.1 ... pl_mode=USBIN-USBIN batfet_mode=NON-STACKED_BATFET`.
  The vendor sets `qcom,sec-charger-config = <2>`, but during the capture the
  parallel supply showed `ONLINE=0 CHARGING_ENABLED=0 INPUT_SUSPEND=1`.
  **Mainline has no driver. Keep it that way:** a single 3 A path is enough at
  5 V.
- Same bus: PM8008 at 0x08/0x09 (camera LDOs, not charging) and **FSA4480**
  at 0x42 (USB-C analog audio/SBU switch; mainline has
  `drivers/usb/typec/mux/fsa4480.c`; that work belongs to audio and is out of
  scope here).
- No OPPO/OnePlus I2C charger, charge pump or fuel-gauge chip was found.
  `charger_pump_support` in the DT is a touchscreen flag. The `[ONEPLUS_CHG]`
  logic is pure software on top of SMB5 (`drivers/power/oneplus/oneplus_charger.c`).
  There is no Warp/VOOC on this phone (`FASTCHARGER=0`).

### 2.5 Battery and the vendor's charging parameters
Profile in use: `4797575_Huaqin_QL1839_Desay_5000mAH_PMI632_averaged_MasterSlave_Sep28th2020`
(batt-id 30 kΩ; the alternative is Coslight at 19 kΩ, ±15 %).
`max-voltage-uv = 4435000`, `fg-cc-cv-threshold-uv = 4440000`,
`fastchg-current-ma = 3500`, charge_full_design 5058000 µAh. QG reported an
ESR of about 97 mΩ (`POWER_SUPPLY_RESISTANCE=97000`).

What the vendor actually programmed (dmesg 4.84–5.04 s, `smblib_*_charge_param`):

| Register (abs.) | Meaning | Before kernel (ABL/OTP) | Vendor value | Encoding (PMI632 only) |
|---|---|---|---|---|
| 0x1070 FLOAT_VOLTAGE_CFG | float voltage | 0x50 = 4.400 V | **0x53 = 4.430 V** (requested 4.435) | 3.600 V + n·10 mV |
| 0x1061 FAST_CHARGE_CURRENT_CFG | FCC | ? | **0x3c = 3.0 A** (requested 3.5, clamped to HW max) | n·50 mA, max 3.0 A |
| 0x1370 USBIN_CURRENT_LIMIT_CFG | ICL | 0x14 = 1.0 A | 0x28 = 2.0 A on DCP. SDP 500 mA, CDP 1.5 A | n·50 mA, max 3.0 A |
| 0x1152 DCDC_OTG_CURRENT_LIMIT_CFG | OTG limit | | 0x02 = 1.0 A | 500 mA + n·250 mA, max 1.0 A |
| 0x1150 DCDC_FSW_SEL | buck frequency | | 600 kHz | |
| 0x10a2 FAST_CHARGE_SAFETY_TIMER | HW safety timer | | 0x02 = 768 min | |
| 0x1090 JEITA_EN_CFG | HW JEITA | | soft-limit bits [3:0] cleared (SW JEITA). **Bit 4 hard limit not touched** | |
| 0x1653 / 0x1651 | watchdog | | bite 8 s, **bite disables charging**, snarl 8 s, bark 64 s, enabled on plug-in | |
| 0x1153 DCDC_OTG_CFG | OTG enable source | | bit 1 = 0 (software control) | |

OnePlus software JEITA bands (DT `qcom,*_bat_decidegc`; the code negates the
cold values: `oneplus_charger.c` 1711–1750). Boundaries are lower bounds with
anti-shake hysteresis:

| Battery temp | Zone | Float (sw target) | Fast-charge current |
|---|---|---|---|
| < −19 °C | "removed" | stop | stop |
| −19 … −2 °C | LOW_TEMP | stop | stop |
| −2 … 0 °C | COLD | 3.980 V | 350 mA |
| 0 … 5 °C | LITTLE_COLD | 4.435 V | 700 mA (QC/PD: 2100/1200 split by voltage **(guess)**) |
| 5 … 12 °C | COOL | 4.435 V | 3000 mA (high) / 2100 mA (low) |
| 12 … 16 °C | LITTLE_COOL | 4.435 V | 3000 mA |
| 16 … 45 °C | NORMAL | 4.435 V | 3500 mA (HW gives 3000) |
| 45 … 50 °C | WARM | **4.130 V** | 1450 mA (550 with LED/screen on) |
| > 50 °C | HIGH_TEMP | stop | stop |

Other vendor limits: termination 250 mA (sw, `default_iterm` 260, QG 350);
recharge at vbat −100 mV or SOC 98 %; battery overvoltage stop at
`vbatt_hv_thr` 4.500 V (SMB1355 OV 4.485 V); input OVP in software at 10.0 V
(recovers at 9.7 V), UV 3.4 V; max charge time 72000 s (20 h); charger and SMB
die temperature max 80.0 °C with HW die-temp mitigation; connector
over-temperature at 60 °C or a 45 °C rise rule (`op,*-protect-*`); thermal
mitigation FCC steps 3.4/3.0/2.8/2.65/2.6/2.2 A; QC 2.0 HVDCP 9 V/2 A allowed
(`qcom,qc_9v2a_support`); PD not supported on PMI632; `vbatt-cutoff` 3.390 V,
power-off 3.300 V.

### 2.6 USB
The vendor DT has dwc3 at 0x4e00000, `maximum-speed = "high-speed"`,
`dr_mode = "otg"`, role from the SMB5 extcon, and only a QUSB2 PHY
(`usb-phy = <qusb_phy0 …>`). **USB 2.0 only, no SS lanes** (consistent with
our `phys = <&usb_hsphy>` override). Type-C CC is handled by PMI632 TYPEC
(0x1500). VBUS for OTG comes from the PMI632 buck running in reverse (DCDC
0x1140 CMD_OTG).

## 3. What mainline (v7.3) has
| Function | Mainline | Path |
|---|---|---|
| ADC, temp alarm, GPIO, SDAM, PBS | yes, already enabled in our DT | `arch/arm64/boot/dts/qcom/pmi632.dtsi` |
| Type-C port (CC, orientation, roles; no PD) | **yes**, `qcom,pmi632-typec` | `drivers/usb/typec/tcpm/qcom/qcom_pmic_typec*.c` (pdphy stub for PMI632) |
| VBUS/OTG boost | **yes**, `qcom,pmi632-vbus-reg` → pm8150b data | `drivers/regulator/qcom_usb_vbus-regulator.c` |
| dwc3 role switch | yes (`usb-role-switch` in `sm6115.dtsi`) | |
| Reference boards | PMI632 Type-C + VBUS + dwc3 HS endpoint | `sm6115-fxtec-pro1x.dts`, `qrb4210-rb2.dts`, `sdm632-fairphone-fp3.dts` |
| SMB2 charger (pmi8998, pm660) | yes, **not PMI632** | `drivers/power/supply/qcom_smbx.c` |
| SMB5 / PMI632 charger | **no** | — |
| QGauge | **no** | — |
| SMB1355 | no | — |
| bat_therm_30k_pu ADC channel | **no** (only defined in `dt-bindings/iio/qcom,spmi-vadc.h`) | `drivers/iio/adc/qcom-spmi-adc5.c` table lacks 0x2a/0x4a |

Upstream efforts found:
- Casey Connolly, "[PATCH 00/11] power: supply: pmi8998 charger improvements
  and smb5 support" (v1, 2025-06-19). It renamed the driver to `qcom_smbx`,
  which was merged. The SMB5 (pm8150b) patch is **not in v7.3** (the driver
  only matches pmi8998/pm660). In the thread, Luca Weiss said he would look at
  PMI632 (Fairphone 3). No PMI632 follow-up was found. A
  "qcom_smbx: allow disabling charging" patch is under discussion (2026-04).
- PMI8998 Type-C/role-switch series (2026-05). It doesn't apply to us, but
  shows the OTG register layout matches pm8150b SMB5.
- David Heidelberg, "Qualcomm 3rd gen fuel gauge support" (RFC, 2025-11).
  That is the PMI8998 FG gen3 with an SRAM-based algorithm. **QGauge is a
  different design** (raw V/I FIFOs and SDAM, with SOC computed in software).
  No mainline QG work was found.

## 4. What's missing (in order of usefulness)
1. Charging status from charger registers instead of USB voltage. 2. Battery
current and temperature, which safe software JEITA and a gauge both need.
3. A PMI632 SMB5 driver with a watchdog. 4. A coulomb-counting gauge. 5. OTG,
which is DT only.

## 5. Plan

### (a) Charging status: read-only, no writes
Extend `kmod/adc-ocv-battery` (or add a sibling `pmi632-smb5-ro`) to take the
parent SPMI regmap (`dev_get_regmap(pdev->dev.parent, NULL)`, as
`qcom_usb_vbus-regulator.c` does) and **only call `regmap_read`/`regmap_bulk_read`**:

| Read | Gives |
|---|---|
| 0x1006 bits[2:0] | 0 inhibit, 1 trickle, 2 pre, 3 full-on, 4 taper, 5 terminated, 6 pause, 7 disabled → `status`, `charge_type` |
| 0x1007 | bit 1 BAT_OV error → `health` |
| 0x100d | soft/hard hot/cold bits → `health` (HW view of temperature) |
| 0x110b POWER_PATH_STATUS | USBIN present / power-path source (vendor reads 0x95 when plugged) |
| 0x1107 / 0x1106 | ICL in use / max (×50 mA) → `input_current_limit` |
| 0x1070, 0x1061, 0x1370 | FV/FCC/ICL as configured → expose read-only, and log them once at probe |
| 0x1307 / 0x1308 | APSD done / result (SDP/CDP/DCP/…) → `usb_type` |
| 0x1606–0x160a | die/skin/connector/SMB temperature status bits |
| 0x1042, 0x1051, 0x1090, 0x10a2, 0x1651, 0x1653 | charge enable, CFG2, JEITA enable, safety timer, watchdog: **log at probe** so we know which state ABL left us in |

QG measurements, also read-only:
`0x48c0/0x48c1` LAST_ADC_V (µV = raw·194.637), `0x48c2/0x48c3` LAST_ADC_I
(signed 16-bit. µA = raw·152.588 for subtype 3, `qg_iraw_to_ua`), status
`0x4808` (bit 7 QG_OK, bit 0 battery present). The vendor sets the
`BURST_AVG_HOLD` bit (0x4842) before reading the burst average. For a strictly
read-only first pass, use LAST_ADC_* without the hold and accept the
occasional torn read (read twice, compare). Don't write QG registers yet.

Untested DT addition (the driver doesn't exist yet. The node lives inside the
existing `pmic@2`, which has no label, so it is re-opened by path):

```dts
&spmi_bus {
	pmic@2 {
		/* read-only status; driver: kmod/pmi632-smb5-ro (to write) */
		charger-status@1000 {
			compatible = "fap,pmi632-smb5-ro";
			reg = <0x1000>, <0x4800>;      /* CHGR block, QG block */
			io-channels = <&pmi632_adc ADC5_VBAT_SNS>,
				      <&pmi632_adc ADC5_USB_IN_V_16>,
				      <&pmi632_adc ADC5_USB_IN_I>,
				      <&pmi632_adc ADC5_CHG_TEMP>;
			io-channel-names = "vbat", "usbin_v", "usbin_i", "chg_temp";
			monitored-battery = <&battery>;
		};

		/* QG SDAM: vendor's last SOC/OCV/cycle count, read-only */
		nvram@b100 {
			compatible = "qcom,spmi-sdam";
			reg = <0xb100>;
			read-only;
			#address-cells = <1>;
			#size-cells = <1>;
			ranges = <0 0xb100 0x100>;
			qg_sdam_soc: soc@47 { reg = <0x47 0x1>; };
			qg_sdam_ocv: ocv@4c { reg = <0x4c 0x4>; };
			qg_sdam_cycles: cycles@58 { reg = <0x58 0x10>; };
		};
	};
};
```

Battery temperature: add `[ADC5_BAT_THERM_30K_PU] = ADC5_CHAN_TEMP("bat_therm_30k_pu", 0, SCALE_HW_CALIB_DEFAULT)`
to `adc5_chans_pmic` (a local kernel patch). Then add a ratiometric channel
in the DT and convert in our kmod: with V = processed µV and a 1.875 V full
scale, R = 30 kΩ·V/(1.875 V − V), then T from β 3380 and R25 = 10 kΩ
**(guess: confirm the full-scale value in `qcom-vadc-common.c` and sanity-check
against room temperature, which the vendor read as 29.6 °C)**.

```dts
&pmi632_adc {
	channel@2a {
		reg = <ADC5_BAT_THERM_30K_PU>;
		qcom,ratiometric;
		qcom,hw-settle-time = <200>;
		qcom,pre-scaling = <1 1>;
		label = "bat_therm_30k";
	};
	channel@52 { reg = <ADC5_GPIO1_100K_PU>; qcom,ratiometric;
		qcom,hw-settle-time = <200>; qcom,pre-scaling = <1 1>; label = "usb_temp1"; };
	channel@55 { reg = <ADC5_GPIO4_100K_PU>; qcom,ratiometric;
		qcom,hw-settle-time = <200>; qcom,pre-scaling = <1 1>; label = "usb_temp2"; };
};
```

### (b) Real charging control
Do **not** reuse `qcom_smbx.c` as it is: its encodings are SMB2 (float
3.4875 V + n·7.5 mV, current n·25 mA, Type-C at 0x1358). On PMI632, its
4.435 V write becomes 0x7f, which would mean **4.87 V**, and its "1 A" FCC
becomes 2 A. Two options:
1. Rebase Casey's SMB5 patch (lore, 2025-06) and add a PMI632 variant: no
   DCIN, no PD, FCC/ICL max 3 A, OTG 0.5–1 A, iterm limits. The PMI632 values
   are in `qpnp-smb5.c` `smb5_pmi632_params`. This is the upstreamable route.
2. A small `fap,pmi632-charger` out-of-tree driver that writes exactly the
   registers in the table in 2.5 and nothing else, to bridge the gap.

Either way, the driver's first version must:
- program **FV = 0x50 (4.40 V)** first. Only move to 0x53 (4.43 V, the vendor
  value) after a review.
- cap **FCC at 1.0 A (0x14)** at first (as qcom_smbx does on OnePlus 6), then
  2.0 A, then 3.0 A only after the thermal tests.
- set ICL from APSD: SDP 500 mA, CDP 1.5 A, DCP ≤ 2.0 A. **Keep HVDCP/QC
  disabled** (5 V only) and leave PD off.
- enable the **HW watchdog with bite → charging disabled** and pet it from a
  delayed work. If the kernel dies, charging stops.
- keep the HW JEITA **hard** limit on. Either implement the vendor bands in
  software from `bat_therm_30k` (table in 2.5), or turn on the HW soft limits
  (0x1090 bits 0–3 and thresholds at 0x1094…). The vendor never programmed HW
  thresholds, so their defaults are unknown **(read them first in step 3)**.
- keep the 768-minute safety timer and leave SMB1355, PMI632 GPIO2 and GPIO4
  untouched.

Untested DT (binding to be written):

```dts
&spmi_bus {
	pmic@2 {
		pmi632_charger: charger@1000 {
			compatible = "qcom,pmi632-charger";
			reg = <0x1000>;
			interrupts = <0x2 0x13 0x4 IRQ_TYPE_EDGE_BOTH>,   /* usbin-plugin */
				     <0x2 0x12 0x2 IRQ_TYPE_EDGE_BOTH>,   /* bat-ov */
				     <0x2 0x10 0x1 IRQ_TYPE_EDGE_RISING>, /* chg-state-change */
				     <0x2 0x16 0x1 IRQ_TYPE_EDGE_RISING>; /* wdog-bark */
			interrupt-names = "usb-plugin", "bat-ov", "chg-state-change", "wdog-bark";
			io-channels = <&pmi632_adc ADC5_USB_IN_I>, <&pmi632_adc ADC5_USB_IN_V_16>;
			io-channel-names = "usbin_i", "usbin_v";
			monitored-battery = <&battery>;
		};
	};
};

&battery {   /* existing node in our board DT */
	constant-charge-voltage-max-microvolt = <4400000>;  /* step 1; vendor 4430000 */
	constant-charge-current-max-microamp = <1000000>;   /* step 1; vendor 3000000 */
	charge-term-current-microamp = <250000>;
	operating-range-celsius = <0 45>;                    /* tighter than vendor's -2..50 */
};
```

### (c) A real fuel gauge
Smallest path: in the kmod, integrate QG current (LAST_ADC_I or the burst
average, once we write the hold bit) for coulomb counting. Correct with the
OCV table while resting (|I| < 25 mA for more than 1 min; the vendor's S3
entry/exit is 25/38 mA) and use V + I·97 mΩ for IR compensation. Seed it from
the QG SDAM SOC/OCV that Android/UT left behind. Expose `current_now`,
`charge_now`, `charge_full` and `capacity`.
The full QG algorithm (`qg-soc.c`, `qg-profile-lib.c`, FIFOs, ESR, learning)
is a bigger port. Track it as upstream work. QG writes (FIFO length, S3
thresholds, VBAT_LOW/EMPTY at 0x484b/0x484c) affect only measurement, not
charging, but still need a review.

### (d) USB host/OTG
DT only. It mirrors `sm6115-fxtec-pro1x.dts`, but HS only (no QMP/SS port):

```dts
/* stage 1: sink + device only, VBUS boost never enabled */
&pmi632_typec {
	status = "okay";
	connector {
		compatible = "usb-c-connector";
		power-role = "sink";
		data-role = "device";
		self-powered;
		typec-power-opmode = "default";
		pd-disable;
		ports {
			#address-cells = <1>;
			#size-cells = <0>;
			port@0 {
				reg = <0>;
				pmi632_hs_in: endpoint { remote-endpoint = <&usb_dwc3_hs>; };
			};
		};
	};
};
&usb_dwc3 {
	dr_mode = "otg";            /* replaces "peripheral"; drop the /delete-property/ */
	usb-role-switch;
	maximum-speed = "high-speed";
	phys = <&usb_hsphy>;
	phy-names = "usb2-phy";
};
&usb_dwc3_hs { remote-endpoint = <&pmi632_hs_in>; };

/* stage 2: dual role with VBUS */
&pmi632_vbus {
	regulator-min-microamp = <500000>;
	regulator-max-microamp = <1000000>;
	status = "okay";
};
/* in connector: power-role = "dual"; data-role = "dual"; vbus-supply = <&pmi632_vbus>; */
```

Notes: `sm6115.dtsi` also has `port@1` → QMP SS on `usb_dwc3`. Because our
board has no SS PHY, delete that endpoint or leave it unconnected. The
billie2 also needs `dwc3_qcom_legacy` (nested layout). The mainline vbus
regulator uses pm8150b's current table (0.5/1.0/1.5… A) on PMI632, whose
register steps are 0.5/0.75/1.0 A. 1 A requested therefore gives selector 1,
i.e. **750 mA** on PMI632 **(guess from reading both sources)**. That errs on
the safe side. Without a charger driver, the vbus regulator writes
`OTG_CFG` (0x1153, software source), which is the same as the vendor.

## 6. Test plan (least to most risky)
Before each step, boot with `fastboot boot` (RAM only). Run a capture
(`tools/capture.sh`) and log results in `docs/status.md`. The USB shell is our
only console, so a USB-C step that breaks it means holding Power and
rebooting to the last good image.

1. **Passive baseline (no change).** With the current image, log
   `vbat_sns`, `usb_in_v`, `usb_in_i`, `chg_temp` every 30 s for 2 h on the
   Mac's USB, then on a 5 V wall charger. Does the phone charge at all under
   mainline with ABL defaults? (`vbat` rising, `usb_in_i` > 0.)
   **(guess: yes at ≤ 1 A ICL / FV 4.40 V. If the vendor watchdog is still
   armed after a warm reboot from UT, a bite may have stopped charging.)**
2. **Read-only status module (a).** Load it, then dump and save every
   register in the (a) table plus QG V/I. Compare FV/FCC/ICL/JEITA/WD/timer
   with section 2.5. Hand-check QG V against `vbat_sns` (±20 mV) and the
   QG I sign while plugged and unplugged.
3. **Read the HW JEITA thresholds** (0x1094–0x10a1) and BATIF config
   (0x1282, 0x1286) read-only, and convert them with the vendor's ADC scaling.
   These are our hardware backstop. Document them.
4. **ADC5 bat_therm_30k patch.** Read-only. Check against the vendor reading
   at the same ambient (≈ 25–30 °C), then warm the phone by hand and confirm
   the value rises. The connector NTCs too.
5. **Fuel gauge in the kmod (c).** Still read-only for the charger. Run a
   full discharge from 100 % to 15 % and compare against wall-clock and UT
   history.
6. **Type-C stage 1 (sink/device).** It writes TYPEC config only. Check that
   the USB network shell survives replugging both cable orientations, and
   check `/sys/class/typec/port0`.
7. **Type-C stage 2 (OTG, VBUS boost ≤ 1 A).** Battery > 50 %, use a
   **powered hub or a USB stick only**, never a charger or host on the other
   end. Measure `vph_pwr`, `chg_temp` and the OTG fault IRQs. *Human review
   before running.*
8. **Charger driver at FV 4.40 V / FCC 1.0 A / ICL 500 mA**, on the bench,
   battery 30–80 %, phone on a non-flammable surface, someone watching. Log
   vbat, QG I, bat temp, chg_temp and status every 10 s. Pull the cable the
   moment bat temp > 40 °C or vbat > 4.42 V. *Human review of the exact
   register writes before running.*
9. **Charge to termination** at those limits: check taper, termination at
   ~250 mA, recharge and the watchdog. Then unload the driver while charging
   and confirm the bite stops charging within about 8 s. *Human review.*
10. **Raise to vendor values**: FV 0x53 (4.43 V), FCC 2.0 A then 3.0 A, ICL
    2.0 A on DCP, with software JEITA bands active. Run one step per session
    and repeat the thermal checks of step 8. *Human review for each step.*

## 7. Safety
Charging a Li-ion cell with wrong parameters can swell it, shorten its life or
start a fire. Rules:

- **Steps 7–10 require a human to review the exact register writes (address,
  mask, value) beforehand,** and someone must be present during the run.
  Write each value in this doc next to its decoded meaning.
- **Never bind `qcom,pmi8998-charger`/`qcom,pm660-charger` (qcom_smbx) to
  PMI632.** The encodings differ: its FV write would be 4.87 V.
- Values that must match the vendor (or be lower):
  - Float voltage 0x1070 ≤ **0x53 (4.430 V)**. Never above 4.435 V
    (profile max). Start at 0x50. WARM zone 4.130 V, COLD 3.980 V.
  - FCC 0x1061 ≤ **0x3c (3.0 A)** and per JEITA band (2.5). Start at 1.0 A.
  - ICL 0x1370 ≤ 0x28 (2.0 A) for DCP, 500 mA SDP, 1.5 A CDP. 5 V only:
    HVDCP (USBIN_OPTIONS_1_CFG 0x1362 HVDCP enable bit) **off**.
  - Charging only between 0 °C and 45 °C at first (the vendor allows −2…50
    with reduced values). Stop at > 50 °C or < −2 °C in any case.
  - Battery overvoltage: stop at vbat ≥ 4.50 V (vendor `vbatt_hv_thr`);
    our test abort is 4.42 V.
  - Termination ≥ 250 mA. Recharge threshold vbat −100 mV.
  - Safety timer 0x10a2 = 768 min (never disabled); software limit 20 h.
  - Watchdog 0x1653: bite 8 s **with BITE_WDOG_DISABLE_CHARGING**; 0x1651
    enabled on plug-in. Never write 0 to these while a writable charger
    driver is loaded (qcom_smbx does that for SMB2: don't copy it).
  - JEITA_EN_CFG 0x1090 bit 4 (hard limit) **must stay set**.
  - Die-temp/connector-temp HW mitigation stays on. Connector > 60 °C →
    stop.
  - OTG current limit 0x1152 ≤ 0x02 (1.0 A).
- **Never touch:** SMB1355 (I2C 0x0c) and PMI632 GPIO2 (SMB_EN); PMI632 GPIO4
  (VBUS discharge, which shorts VBUS); SHIP_MODE 0x1240 (cuts the battery FET:
  the phone looks dead until plugged in); CHGR_CFG2 0x1051 charge-enable
  source/polarity bits; PMI632 PON (0x800); anything on SID 3 for this work.
- The battery is a used 5000 mAh cell (QG SOH reported 60 %, which is
  suspicious **(guess: learning artifact)**). Look at it for swelling before
  charger tests. Stop if the back cover bulges or the cell is warm while idle.
- One actor on the phone. Subagents never run adb/fastboot.

## 8. Sources
- Vendor DT and logs: `UBports-N100/log/hw-inventory/20261120-134342/`
  (`device-tree.dts`, `raw/dmesg.txt`, `raw/power-supply.txt`, `raw/i2c.txt`,
  `raw/interrupts.txt`).
- OnePlus GPL kernel, branch `oneplus/SM4250_R_11.0`:
  `drivers/power/supply/qcom/{qpnp-smb5.c,smb5-lib.c,smb5-reg.h,qg-reg.h,qg-util.c,qg-defs.h,smb1355-charger.c}`,
  `drivers/power/oneplus/oneplus_charger.c` (copies in
  `fap-build/research/charging/op/`).
- Mainline v7.3 (`fap-build/linux`): `arch/arm64/boot/dts/qcom/{pmi632.dtsi,sm6115.dtsi,sm6115-fxtec-pro1x.dts,qrb4210-rb2.dts}`,
  `drivers/power/supply/qcom_smbx.c`, `drivers/usb/typec/tcpm/qcom/`,
  `drivers/regulator/qcom_usb_vbus-regulator.c`, `drivers/iio/adc/qcom-spmi-adc5.c`,
  `include/dt-bindings/iio/qcom,spmi-vadc.h`.
- SMB5 series: https://patchew.org/linux/20250619-smb2-smb5-support-v1-0-ac5dec51b6e1@linaro.org ,
  PMI632 remark: https://lkml.indiana.edu/hypermail/linux/kernel/2506.2/07607.html
- PMI8998 FG RFC: https://lkml.iu.edu/2511.3/01492.html
- PMI8998 Type-C series: https://lkml.rescloud.iu.edu/2605.2/04006.html
