# N100 (billie2) cameras and flash LED

Status: **research only, nothing tested on mainline** (2026-11-20).
Scope: the four camera modules, the CCI/CSIPHY/MCLK wiring, the PM8008 camera
PMIC, the PMI632 flash LED, and what mainline v7.3 + libcamera already have.

Tags: **[DT]** = read from the vendor device tree dumped from the running phone,
**[dmesg]** = vendor kernel log, **[blob]** = vendor camera blob names,
**[src]** = mainline/vendor source, **[guess]** = not verified.

## Sources
- Vendor DT: `UBports-N100/log/hw-inventory/20261120-134342/device-tree.dts`
  (CCI node `qcom,cci0` at line ~16396, sensors ~16643, flash LED ~5218,
  PM8008 ~11040, camera-flash ~17534).
- Vendor dmesg: `.../raw/dmesg.txt` (CAM-SENSOR probe lines at 25-27 s).
- Vendor blobs list: `TheMuppets/proprietary_vendor_oneplus_billie2`
  `billie2-vendor.mk` (`com.qti.sensormodule.soda_*.bin`; "soda" is the
  Qualcomm-side project name). Sensor-module bins downloaded to
  `fap-build/research/cameras/blobs/` (only strings checked, format not decoded).
- Chip IDs cross-checked against MediaTek `kd_imgsensor.h`
  (MotorolaMobilityLLC/kernel-mtk): `OV13B10 0x560d42`, `OV8856 0x885A`,
  `GC02M1(B) 0x02E0`, `GC02K0 0x2385`.
- Mainline: local sparse tree `fap-build/linux` (v7.3) for DTS; drivers fetched
  with `gh api …?ref=v7.3` into `fap-build/research/cameras/src/`.
- Downstream flash driver: OnePlusOSS `android_kernel_oneplus_sm4250`
  `drivers/leds/leds-qpnp-flash-v2.c` (branch `oneplus/SM4250_R_11.0`).
- lore.kernel.org was behind a bot check from here, so mailing-list status
  comes from web search and lkml mirrors only; see "Open questions".

## Inventory

The vendor DT does not name sensors (CamX keeps that in userspace). The mapping
below joins the DT slots with the dmesg probe lines and the blob names:

```
CAM-SENSOR: Probe success,slot:0,slave_addr:0x6c,sensor_id:0xd42
CAM-SENSOR: Probe success,slot:2,slave_addr:0x20,sensor_id:0x885a
CAM-SENSOR: Probe success,slot:1,slave_addr:0x6e,sensor_id:0x2e0
CAM-SENSOR: Probe success,slot:3,slave_addr:0x6e,sensor_id:0x2385
```
(slave_addr is the 8-bit form, so 0x6c means 7-bit 0x36.)

| | Rear main | Rear depth | Front | Rear macro |
|---|---|---|---|---|
| Vendor slot (`cam-sensorN`) | 0 | 1 | 2 | 3 |
| Sensor | **OmniVision OV13B10** 13 MP | **GalaxyCore GC02M1B** 2 MP mono | **OmniVision OV8856** 8 MP | **GalaxyCore GC02K0** 2 MP (chip ID 0x2385 = GC2385 family) |
| Module (blob) | `soda_qt_ov13b10_rear` (Q-Tech) | `soda_cxt_gc02m1b_depth` | `soda_st_ov8856_front` | `soda_cxt_gc02k0_macro` |
| Chip ID read [dmesg] | 0x0d42 (low 16 bits of 0x560d42) | 0x02e0 | 0x885a | 0x2385 |
| I2C addr (7-bit) | 0x36 | 0x37 | 0x10 | 0x37 |
| CCI master (bus) | 0 (GPIO 22/23) | 1 (GPIO 29/30) | 1 (GPIO 29/30) | 0 (GPIO 22/23) |
| CSIPHY | 0 | **2** | 1 | **2** |
| Lanes | 4 [guess; 2 also supported by the driver] | 1 [guess] | 4 or 2 [guess] | 1 [guess] |
| MCLK | MCLK0, GPIO 20 | MCLK3, GPIO 28 | MCLK1, GPIO 21 | MCLK2, GPIO 27 |
| MCLK rate (vendor) | 24 MHz | 24 MHz | 24 MHz | 24 MHz |
| Reset GPIO | 65 | 18 | 19 | 24 |
| DOVDD 1.8 V | PM8008 L6 | L6 | L6 | L6 |
| AVDD 2.8 V | PM8008 **L3** | L5 | L5 | L5 |
| DVDD | PM8008 L1, 1.2 V | (internal) | PM8008 L2, 1.05-1.2 V | (internal) |
| AF (VAF 2.8 V) | actuator0, PM8008 L4, CCI master 0, model unknown | — | — (fixed focus) | — |
| EEPROM/OTP | eeprom0 on master 0 (`com.qti.eeprom.truly_cmb433`), addr unknown | eeprom1 node | eeprom2 node | eeprom3 node |
| Flash | `camera-flash@0` (PMI632 flash0/torch0) | — | — | `camera-flash@1` (same LED) |
| Orientation [DT] | yaw 180 (back), roll 90 | back, roll 90 | yaw 0 (front), roll 270 | back, roll 90 |

Notes:
- `actuator1` (master 1, VAF = L5) exists in the DT but no sensor references it.
  The eeprom1-3 nodes are likely just the sensors' own OTP. [guess]
- No OIS node.
- Supplies and GPIOs come from each `cam-sensorN` node's `cam_*-supply`,
  `gpios` and `gpio-req-tbl-label` (for example `CAMIF_MCLK0`, `CAM_RESET0`).
  Phandles were resolved by hand: 0x2ed..0x2f2 = PM8008 L1..L6.
- MCLK pins use the `cam_mclk` function, CCI pins use `cci_i2c`. This matches
  `agatti.dtsi` pin for pin, and `pinctrl-sm6115.c` has both functions.

### Shared blocks [DT]
| Block | Vendor | Mainline equivalent |
|---|---|---|
| CCI | `qcom,cci-v1.2` @ 0x5c1b000, IRQ 206, 2 masters, `cci_0_clk` 37.5 MHz | `agatti.dtsi` `cci@5c1b000` (`qcom,qcm2290-cci`): same reg, IRQ and clock rate |
| CSIPHY0/1/2 | `csiphy-v2.0.1` @ 0x5c52000 / 0x5c53000 / 0x5c54000, IRQ 72/73/74 | agatti has csiphy0/1 only; **csiphy2 is SM6115-only** |
| CSID / TFE | `csid530` ×3, TFE0/1/2 @ 0x5c6e000/0x5c75000/0x5c7c000 | qcm2290 camss: 2 CSID + 2 VFE (TFE). Vendor dmesg: "TFE:2 is not supported" (fused off on SM4250?) |
| CSIPHY supply | `mipi-csi-vdd` = PM6125 L18 (1.2 V) | `vdd-csiphy-1p2` = `vreg_l18a`; a 1p8 supply is required by the qcm2290 binding, rail unknown [guess: L9A/L13A] |
| GDSC | `gcc_camss_top_gdsc` | `GCC_CAMSS_TOP_GDSC` (gcc-sm6115) |
| Camera PMIC | PM8008 at I2C 0x08/0x09 on QUP SE1 (`i2c@4a84000` = mainline `&i2c1`), IRQ GPIO 25, reset/enable GPIO 26, L1/L2 input = PM6125 S6 | `qcom,pm8008` + `qcom-pm8008-regulator.c` in mainline; RB1 (`qrb2210-rb1.dts`) wires it identically (GPIO 25 IRQ, GPIO 26 reset) |
| Flash LED | PMI632 `qcom,qpnp-flash-led-v2` @ 0xd300 on USID 3, 2 flash + 2 torch nodes, max 1500 mA flash / 500 mA torch | **not supported** (see below) |

## Mainline status (v7.3)

| Piece | Status | Path / note |
|---|---|---|
| CAMSS for SM6115 | **No node in `sm6115.dtsi`**, no `qcom,sm6115-camss` in `camss.c`. Agatti/QCM2290 support exists (`qcm2290_resources`, CAMSS_2290, VFE/CSID 340, csiphy-3ph-1-0). Registers, clocks, IRQs, IOMMU SIDs (0x400/0x800/0x820/0x840) and interconnects (`mmrt_virt`/`mmnrt_virt`) match `sm6115.dtsi` | `drivers/media/platform/qcom/camss/camss.c:5556`, `arch/arm64/boot/dts/qcom/agatti.dtsi:1848-1985` |
| CCI | Driver `qcom,msm8996-cci` compatible; node missing in sm6115.dtsi | copy from agatti.dtsi |
| CSIPHY2 | Missing from qcm2290 resources; needed for the depth and macro cameras | small `camss.c` patch + new `qcom,sm6115-camss` binding |
| PM8008 | Driver + binding present | RB1 DT as template |
| OV13B10 | Driver exists but has **only an ACPI match table, no `of_match_table`, no DT binding**. It already handles DT-style resources (fwnode endpoint, 2/4 lanes, `dovdd/avdd/dvdd`, `reset` GPIO, clock). **MCLK must be 19.2 MHz** (probe fails otherwise); link freq 560 MHz | `drivers/media/i2c/ov13b10.c` (needs ~5-line OF patch + `ovti,ov13b10.yaml`) |
| OV8856 | Driver + binding `ovti,ov8856.yaml`; used on DB845c (`sdm845-db845c-navigation-mezzanine.dtso`). Wants 19.2 MHz xvclk (only warns otherwise), link freq 360 MHz (4-lane) or 720/360 | ready |
| GC02M1(B) | **No mainline driver.** Templates: Rockchip BSP `gc02m2.c` (same register family, chip ID 0x02f0, 1 lane, 24 MHz), an out-of-tree `gc02m1.c` (github ethersloth/c20e-rk3562-linux), Samsung `is-cis-gc02m1.c` | new driver |
| GC02K0 / GC2385 | **No mainline driver.** Rockchip BSP `gc2385.c` (chip ID 0x2385, regs 0xf0/0xf1, 1 lane, 24 MHz, 328 MHz link) | new driver |
| AF actuator | Model unknown; mainline has `dw9714`, `dw9719`, `ak7375`, etc. | find it with an I2C scan on CCI master 0 |
| Flash LED | `leds-qcom-flash.c` supports only flash module subtypes 0x03 (PMI8998/PM660L), 0x04 (PM8150) and 0x07 (4-ch). The binding has no PMI632. Downstream treats PMI632 ("bharger") differently: the charger must enable flash power (`POWER_SUPPLY_PROP_FLASH_ACTIVE`), vreg_ok polling, extra headroom, ≤3 channels. **No PMI632 charger driver in mainline** | `drivers/leds/flash/leds-qcom-flash.c:875-911`; downstream `leds-qpnp-flash-v2.c:1238,1540,1700` |
| libcamera | Simple pipeline handler lists `qcom-camss` with `swIspAllowed = true`, so the soft ISP (debayer, AWB/AGC) works with CAMSS raw output. `camera_sensor_properties.cpp` and `camera_sensor_helper.cpp` have **no entries for ov13b10, ov8856, gc02m1 or gc2385**: streaming works, but AGC gain mapping and the unit-cell size use defaults (patches needed). Latest tag v0.8.0 | `src/libcamera/pipeline/simple/simple.cpp:267` |

Order of usefulness: main (OV13B10) and front (OV8856) need only DT work plus a
tiny OV13B10 OF patch, and both sit on CSIPHY0/1, which the qcm2290 resources
already cover. Depth and macro need new drivers **and** CSIPHY2.

## Untested DT snippets

For `devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts`. Assumes
`camss` and `cci` nodes were copied from `agatti.dtsi` into a local
sm6115 include, with `compatible = "qcom,qcm2290-camss"` as a stopgap
(2 PHYs) [guess: QCM2290 and SM6115 share the Spectra 340 TFE IP; addresses match].
GPIO polarity: reset lines assumed active-low [guess]. The billie2 DTs have
no `vph_pwr` fixed regulator yet; one has to be added (as in `qrb2210-rb1.dts`).

```dts
#include <dt-bindings/clock/qcom,gcc-sm6115.h>

&i2c1 {
	clock-frequency = <400000>;
	status = "okay";

	pm8008: pmic@8 {
		compatible = "qcom,pm8008";
		reg = <0x8>;
		interrupts-extended = <&tlmm 25 IRQ_TYPE_EDGE_RISING>;
		reset-gpios = <&tlmm 26 GPIO_ACTIVE_LOW>;
		vdd-l1-l2-supply = <&vreg_s6a>;     /* vendor: pm6125_s6 */
		vdd-l3-l4-supply = <&vph_pwr>;      /* [guess] */
		vdd-l5-supply = <&vph_pwr>;         /* [guess] */
		vdd-l6-supply = <&vph_pwr>;         /* [guess] */
		vdd-l7-supply = <&vph_pwr>;         /* [guess] */
		gpio-controller;
		#gpio-cells = <2>;
		gpio-ranges = <&pm8008 0 0 2>;
		interrupt-controller;
		#interrupt-cells = <2>;
		#thermal-sensor-cells = <0>;

		regulators {
			vreg_l1p: ldo1 { regulator-name = "cam_main_dvdd";  /* 1.2 V */
				regulator-min-microvolt = <1200000>; regulator-max-microvolt = <1200000>; };
			vreg_l2p: ldo2 { regulator-name = "cam_front_dvdd"; /* 1.05-1.2 V */
				regulator-min-microvolt = <1200000>; regulator-max-microvolt = <1200000>; };
			vreg_l3p: ldo3 { regulator-name = "cam_main_avdd";  /* 2.8 V */
				regulator-min-microvolt = <2800000>; regulator-max-microvolt = <2800000>; };
			vreg_l4p: ldo4 { regulator-name = "cam_main_vaf";   /* 2.8 V */
				regulator-min-microvolt = <2800000>; regulator-max-microvolt = <2800000>; };
			vreg_l5p: ldo5 { regulator-name = "cam_avdd";       /* 2.8 V */
				regulator-min-microvolt = <2800000>; regulator-max-microvolt = <2800000>; };
			vreg_l6p: ldo6 { regulator-name = "cam_dovdd";      /* 1.8 V */
				regulator-min-microvolt = <1800000>; regulator-max-microvolt = <1800000>; };
			vreg_l7p: ldo7 { regulator-name = "vreg_l7p";       /* 3.3 V, always-on in vendor; consumer unknown */
				regulator-min-microvolt = <3304000>; regulator-max-microvolt = <3304000>;
				regulator-always-on; };
		};
	};
};

&camss {
	vdd-csiphy-1p2-supply = <&vreg_l18a>;
	vdd-csiphy-1p8-supply = <&vreg_l9a>;    /* [guess] verify against the schematic/vendor regulators */
	status = "okay";

	ports {
		port@0 { csiphy0_ep: endpoint {
			data-lanes = <0 1 2 3>; remote-endpoint = <&ov13b10_ep>; }; };
		port@1 { csiphy1_ep: endpoint {
			data-lanes = <0 1 2 3>; remote-endpoint = <&ov8856_ep>; }; };
	};
};

&cci { status = "okay"; };

&cci_i2c0 {
	camera@36 {                      /* rear main, needs the OF patch */
		compatible = "ovti,ov13b10";
		reg = <0x36>;
		clocks = <&gcc GCC_CAMSS_MCLK0_CLK>;
		assigned-clocks = <&gcc GCC_CAMSS_MCLK0_CLK>;
		assigned-clock-rates = <19200000>;     /* driver rejects 24 MHz */
		pinctrl-0 = <&mclk0_default>;
		pinctrl-names = "default";
		reset-gpios = <&tlmm 65 GPIO_ACTIVE_LOW>;
		dovdd-supply = <&vreg_l6p>;
		avdd-supply = <&vreg_l3p>;
		dvdd-supply = <&vreg_l1p>;
		rotation = <90>;                       /* [guess] from roll 90 */
		orientation = <1>;                     /* back */
		port { ov13b10_ep: endpoint {
			data-lanes = <1 2 3 4>;
			link-frequencies = /bits/ 64 <560000000>;
			remote-endpoint = <&csiphy0_ep>; }; };
	};
};

&cci_i2c1 {
	camera@10 {                      /* front */
		compatible = "ovti,ov8856";
		reg = <0x10>;
		clocks = <&gcc GCC_CAMSS_MCLK1_CLK>;
		clock-names = "xvclk";
		assigned-clocks = <&gcc GCC_CAMSS_MCLK1_CLK>;
		assigned-clock-rates = <19200000>;
		pinctrl-0 = <&mclk1_default>;
		pinctrl-names = "default";
		reset-gpios = <&tlmm 19 GPIO_ACTIVE_LOW>;
		dovdd-supply = <&vreg_l6p>;
		avdd-supply = <&vreg_l5p>;
		dvdd-supply = <&vreg_l2p>;
		rotation = <270>;                      /* [guess] */
		orientation = <0>;                     /* front */
		port { ov8856_ep: endpoint {
			data-lanes = <1 2 3 4>;            /* try <1 2> if no frames */
			link-frequencies = /bits/ 64 <360000000>;
			remote-endpoint = <&csiphy1_ep>; }; };
	};
	/* camera@37: GC02M1B depth (MCLK3, reset 18, AVDD L5) -> CSIPHY2, no driver yet */
};
/* &cci_i2c0 camera@37: GC02K0 macro (MCLK2, reset 24, AVDD L5) -> CSIPHY2, no driver yet */
```

Also needed: `cci0_default`/`cci1_default`/`mclk0..3_default` pin states
(copy from `agatti.dtsi:605-645`, same GPIOs), plus the `cci`/`camss` nodes
with `GCC_*` clocks from `qcom,gcc-sm6115.h` (all names used by agatti exist
there) and `power-domains = <&gcc GCC_CAMSS_TOP_GDSC>`.

OV13B10 OF patch (sketch, untested):
```c
static const struct of_device_id ov13b10_of_match[] = {
	{ .compatible = "ovti,ov13b10" },
	{ }
};
MODULE_DEVICE_TABLE(of, ov13b10_of_match);
/* .driver.of_match_table = ov13b10_of_match, */
```

## Test plan (numbered; each step needs the user's go-ahead, one actor on the phone)

All of these are RAM boots (`fastboot boot`) of a test DTB/kernel, so nothing is
written to the phone. The UBports `boot_a` stays as the fallback.

1. **CCI + PM8008 probe, chip IDs.** Enable `i2c1` + PM8008, `cci`, and only
   the OV8856 node (it has a DT driver). Expected: `/sys/bus/i2c/devices/` shows
   two `Qualcomm-CCI` adapters; `ov8856` probes and reads 0x300a = `0x00885a`
   (a mismatch prints "chip id mismatch"). Check `regulator_summary` that
   L2P/L5P/L6P came on.
2. **Chip IDs for the other three.** Apply the OV13B10 OF patch and add the
   node: the driver reads 0x300a = `0x560d42`. For the two GalaxyCore sensors,
   until drivers exist, build a ~60-line throwaway "power stub" module that
   takes clock/regulators/reset from a DT node and powers the sensor on. Then
   `i2cdetect -y -r <cci1>` should show 0x37 (+0x10), and
   `i2ctransfer -y <bus> w1@0x37 0xf0 r2` should return `02 e0` (depth, master 1)
   or `23 85` (macro, master 0). GalaxyCore uses 8-bit register addresses; on
   OmniVision use `w2@0x36 0x30 0x0a r3` → `56 0d 42`.
3. **Find the AF actuator and EEPROM.** With the main sensor powered (VAF L4P
   on), run `i2cdetect` on CCI master 0. Expect a VCM driver (often 0x0c) and an
   EEPROM (often 0x50-0x57); identify the VCM by its ID registers.
4. **CSIPHY/CSID test pattern.** `media-ctl -p`; route
   `msm_csid0 → msm_vfe0_rdi0` with the OV13B10's test pattern
   (`v4l2-ctl -c test_pattern=1`) and capture RAW10 with `yavta` or
   `v4l2-ctl --stream-mmap`. This proves CSIPHY0 lanes and the 19.2 MHz/560 MHz
   setup.
5. **Real frames, main and front.** Same as step 4 without the test pattern;
   also try 2 lanes if 4 gives CSID errors (lane count is a guess).
6. **libcamera.** `cam -l`, `cam -c1 --capture=10 --file=frame#.ppm`,
   then `qcam` / GNOME Snapshot via PipeWire. Expect the soft ISP to work, with
   gains a bit off until sensor helpers are added.
7. **CSIPHY2.** Add a `qcom,sm6115-camss` resource set with the third
   CSIPHY (and maybe a third CSID/TFE if TFE2 really exists); port the GC02K0
   driver from Rockchip `gc2385.c` and GC02M1B from `gc02m2.c` /
   out-of-tree `gc02m1.c`; test both on port@2 (they share the PHY).
8. **Flash LED (read-only first).** Read PMI632 USID 3 regs 0xd304/0xd305
   (type/subtype) through `/sys/kernel/debug/regmap/` to learn the flash module
   subtype. Only then decide between extending `leds-qcom-flash` and writing a
   new driver. Torch at ≤100 mA first. The flash path probably needs the PMI632
   charger to supply flash power ("bharger"), which has no mainline driver.

## Risks
- **Power sequencing on PM8008**: wrong voltages could damage sensors. Use the
  vendor values exactly (DOVDD 1.8, AVDD 2.8, DVDD 1.2/1.05-1.2, VAF 2.8). Never
  set L1/L2 above 1.2 V.
- **MCLK 19.2 vs 24 MHz**: the vendor runs every sensor at 24 MHz; the mainline
  OmniVision drivers expect 19.2 MHz (their PLL tables assume it). GCC can make
  19.2 MHz from XO. The GalaxyCore templates assume 24 MHz, which is fine.
- **Lane counts unknown**: the vendor sensor-module bins hold `laneAssign`, but
  the CHX binary format was not decoded. They can be decoded later from
  `research/cameras/blobs/`.
- **CSIPHY2 shared** by depth and macro: only one can stream at a time.
  Two endpoints on one camss port is an untested setup.
- **SM6115 vs QCM2290 camss**: reusing the qcm2290 compatible is a hack.
  Upstream needs a proper `qcom,sm6115-camss` binding (3 PHYs, possibly 3 TFEs).
  Vendor dmesg says TFE2 is unsupported on this chip.
- **Flash**: PMI632 flash may need charger cooperation; misconfiguring
  current/headroom could overheat the LED. Limits: flash 1500 mA max
  (1000 mA default), torch 500 mA max (300 mA default) [DT]. Only one physical LED is
  expected; flash1/torch1 are probably unpopulated [guess].
- PM8008 L7P (3.3 V) is always-on in the vendor DT for an unknown consumer.
  Keep it always-on.
- Reset polarity and orientation/rotation values are guesses.

## Open questions
- Is there a SM6115 CAMSS or PMI632 flash series on linux-media/linux-leds?
  Web search found none (only sm6150 camss, Jan 2026). Re-check on lore from
  a browser.
- Which PM6125 rail feeds the CSIPHY 1.8 V input (vendor lists only L18A 1.2 V)?
- Exact actuator and EEPROM parts and addresses (test step 3).
