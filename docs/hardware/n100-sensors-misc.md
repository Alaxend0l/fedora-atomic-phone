# N100 sensors and small peripherals

Hardware area: sensors (accel/gyro, ALS/proximity, compass, SAR, hall),
fingerprint, vibrator, notification LED, SIM tray and microSD slot of the
OnePlus Nord N100 (billie2, SM4250 "bengal", PM6125 + PMI632).
Status as of 2026-11-20, mainline reference v7.3. Nothing in this document
has been tested on hardware under mainline yet. **[guess]** marks inferences.

## Sources

| Tag | What |
|---|---|
| VDT | vendor DT from the running UBports system: `UBports-N100/log/hw-inventory/20261120-134342/device-tree.dts` |
| RAW | same capture, `raw/` (dmesg.txt, gpio.txt, i2c.txt, spi.txt, input.txt, firmware.txt, android-props.txt) |
| OPK | OnePlus GPL kernel `OnePlusOSS/android_kernel_oneplus_sm4250` @ `oneplus/SM4250_R_11.0`: `arch/arm64/boot/dts/vendor/billie2/bengal-oem-common-qrd.dtsi`, `drivers/oneplus/input/fingerprint/egis520/et520/et520.c` |
| BLOB | sensor registry JSONs from `TheMuppets/proprietary_vendor_oneplus_billie2` @ `lineage-22.2`, `proprietary/vendor/etc/sensors/config/` (copies in `fap-build/research/sensors-misc/sensors-config/`) |
| LOS | `LineageOS/android_device_oneplus_billie2`: `proprietary-files.txt`, `device.mk` |
| ML | mainline v7.3: `arch/arm64/boot/dts/qcom/{sm6115.dtsi,pmi632.dtsi,sm4250-oneplus-billie2.dts,sm6115-fxtec-pro1x.dts,sm6115p-lenovo-j606f.dts}`, `drivers/soc/qcom/qcom_pd_mapper.c`; drivers fetched via gh api into `fap-build/research/sensors-misc/` (`pm8xxx-vibrator.c`, `leds-qcom-lpg.c`, `leds-qcom-flash.c`, `pinctrl-sm6115.c`) |
| SPEC | OnePlus spec page (oneplus.com/global/n100/specs): "Rear-mounted Fingerprint Sensor, Accelerometer, Electronic Compass, Gyroscope, Ambient Light Sensor, Proximity Sensor, SAR sensor" |

## Summary

- **No sensor sits on the AP's I2C.** The two Linux-visible I2C buses only
  carry FSA4480, PM8008, the Awinic amps and TPS61280 (RAW i2c.txt). Accel,
  gyro, compass, ALS/prox and SAR all run inside the **ADSP sensors PD**
  (Qualcomm SEE/"SSC on ADSP"). Evidence: `adsps.jsn` in the modem
  partition (the sensor_pd service-locator entry, RAW firmware.txt),
  `qcom,fastrpc-adsp-sensors-pdr` in VDT (line ~4056), dmesg
  `sensors_pdr_adsprpc`, Android services `sensors.qti` + `sscrpcd` (LOS),
  and SEE registry JSONs for bengal (BLOB).
- On mainline that means the ADSP must be running, and on top of it
  **hexagonrpcd** (to serve the registry/config files to sensorspd) +
  **libssc** + **iio-sensor-proxy with the libssc patch**. The same stack
  works on SDM845/SM8250 phones. The kernel side is already there:
  `remoteproc_adsp` + `fastrpc` (label adsp, `qcom,non-secure-domain`) in
  sm6115.dtsi, and `qcom_pd_mapper` maps `qcom,sm4250` →
  `sm6115_domains`, which include `msm/adsp/sensor_pd`.
- **Fingerprint (Egis ET520)**: SPI on QUP SE5 (GPIO 14–17), owned by
  TrustZone. Linux only sees reset, power and IRQ GPIOs; the image goes to a QSEE
  trusted app. **Not feasible on mainline**: libfprint has no Egis SPI
  driver, and the bus is fenced by TZ.
- **Vibrator**: PMI632 VIB_LDO @0x5700. Mainline supports it with
  `qcom,pmi632-vib` (pm8xxx-vibrator); the node is already in pmi632.dtsi
  (disabled). Watch out: mainline can drive up to 3.544 V and the vendor sets 3.0 V.
- **RGB LED**: PMI632 LPG + TRILED is supported (`qcom,pmi632-lpg`, already
  enabled on the Fxtec Pro1X). The vendor DT has the standard QRD tri-led
  node, but the official specs list no notification LED and LineageOS ships no
  lights HAL, so **an LED is probably not fitted [guess]**.
- **microSD**: works in mainline (`sdhc_2` enabled in
  sm4250-oneplus-billie2.dts). GPIO 88 is the **SIM/SD tray detect**, not a
  card detect. UHS-I voltage switching should work (vqmmc = L5A).
- **Hall sensor**: none (no hall in specs; the bengal hall JSON is for
  IDP/IOT only; gpio_keys has a single key).

## Inventory

| Device | Chip | Bus / address | IRQ / GPIOs | Supplies | Linux side (vendor) | Source |
|---|---|---|---|---|---|---|
| Accel + gyro | BMI160 **[likely]** (OnePlus overrides `bmi160_0.json`, the only IMU JSON they touched; the platform part comes from `bengal_qrd_bmi160_0.json`) | SSC I2C, bus_instance 2, addr 0x68 (104) | DRI irq TLMM 32 (`irq_is_chip_pin` 1) | `/pmic/client/sensor_vddio` (likely L9A 1.8 V **[guess]**) | none; ADSP only | BLOB |
| Compass | AK0991x (0x0c, I3C capable, IRQ TLMM 34) **or** MEMSIC MMC56x3x (0x30, no IRQ): both QRD JSONs ship and OnePlus overrides neither **[unknown which]** | SSC bus_instance 2 | 34 (AK) / none | sensor_vddio | none | BLOB, SPEC |
| ALS + proximity | unknown chip behind generic OnePlus `sns_alsps` driver (`alsps.json`) | SSC I2C bus_instance 1, addr 0x39 (57) | TLMM 35 (reads high, no pull: open-drain active-low IRQ **[guess]**) | sensor_vddio | none | BLOB, RAW gpio.txt |
| SAR (RF) | Semtech SX932x (`sx932x_0.json`) | SSC I2C bus_instance 1, addr 0x28 (40) | TLMM 36 | sensor_vddio | none | BLOB, SPEC |
| "v-sar" input | not a sensor: OnePlus RF-cable monitor (`drivers/misc/oneplus_rf_cable_monitor.c`), RF cable GPIOs 102/103, USB cable GPIO 86 | — | 86, 102, 103 | — | input5 "v-sar" | OPK, VDT |
| Hall | none | — | — | — | — | SPEC, BLOB |
| Fingerprint | Egis ET520 (`egistec,et520`) | SPI on QUP SE5 @0x4a94000 (GPIO 14–17), **TZ-owned** (vendor node `disabled`; pins missing from AP gpio dump; mainline billie2 already has `gpio-reserved-ranges = <14 4>`) | IRQ 97, RST 31 (out high), PWR_EN 93 (out high), FP_ID 67 (in, reads 1) | via PWR_EN GPIO | `et520.c`: GPIO/IRQ/netlink only, plus "uinput-egis" nav keys | VDT, OPK, RAW |
| Vibrator | PMI632 VIB_LDO (ERM) | SPMI USID 3, 0x5700 | — | internal LDO, vendor 3.0 V, overdrive off | `qcom,qpnp-vibrator-ldo` → `/sys/class/leds/vibrator` | VDT, RAW dmesg |
| RGB LED | PMI632 LPG ch 1–3 + TRILED @0xd000 | SPMI USID 3, LPG @0xb300 | — | — | `qcom,tri-led` red/green/blue, `qcom,pwm-lpg` 5 ch with SDAM patterns | VDT |
| Camera flash | PMI632 flash @0xd300 (`qcom,qpnp-flash-led-v2`) | SPMI USID 3 | IRQs 0xd3 0/3/4 | — | camera area, noted here only | VDT |
| SIM tray | tray-present switch (SIM + microSD share one tray) | TLMM 88 (active high, no pull; reads high) | 88 | — | `oneplus-devinfo` `sim_tray_detect` | OPK, VDT |
| SIM card presence | modem UIM1_PRESENT | TLMM 79, func1 `uim1_present` | 79 | — | modem-handled | RAW, `pinctrl-sm6115.c` |
| microSD | SDHC2 @0x4784000, 4-bit, SDR12…SDR104 | — | CD = TLMM 88 (tray) | vdd L22A 2.96 V, vdd-io L5A 1.8/2.96 V, **vdd-io-bias L7A 1.232 V** | `sdhci-msm-v5` | VDT |

### Where the SSC I2C buses are physically: open question

The SEE JSONs say "I2C bus_instance 1/2". SM6115 has a single QUPv3 wrapper
with SE0–SE5, and on this board all six are accounted for on the AP side: SE0 SPI
touch (GPIO 0–3), SE1 I2C (4–5), SE2 I2C (6–7), SE3 BT UART (8–11), SE4
debug UART (12–13), SE5 TZ fingerprint (14–17). The VDT has no
`qcom,shared-se`. So either the ADSP shares SE1/SE2 with the AP (the address
sets don't collide: SE1 has 0x08/0x09/0x0c/0x42 plus unpopulated NFC 0x28,
which collides with the SAR at 0x28, and SE2 has 0x58/0x59/0x75), or the
bengal ADSP has its own sensor I2C master on pins we can't see. The sensor IRQ
pins (TLMM 32–36) look like plain GPIOs to the AP. TLMM can route a pin's
interrupt to the ADSP, which fits `irq_is_chip_pin = 1`. **This decides whether a
direct-IIO route exists** (mainline has `bmi160`, `ak8975` (covers AK0991x)
and `sx9324`/`sx9310` IIO drivers; no MMC56x3 driver), so test step 3 below
probes for it.

## Mainline status

| Item | Kernel | DT | Userspace | Missing |
|---|---|---|---|---|
| ADSP | `qcom_q6v5_pas` (`qcom,sm6115-adsp-pas`), firmware `adsp2.mdt/.bNN` in `modem_a` | `remoteproc_adsp` in sm6115.dtsi, disabled; Pro1X/J606F/RB2 enable it | — | enable in our DT; split/convert `adsp2.*` → `adsp.mbn` (or point `firmware-name` at the .mdt) in `fap-modem-ram`. Shared prerequisite with audio. |
| fastrpc adsp | `fastrpc` (CONFIG_QCOM_FASTRPC) | child of ADSP glink edge, `qcom,non-secure-domain`, cb 3–7 | `/dev/fastrpc-adsp` | nothing in DT |
| sensor PD | in-kernel `qcom_pd_mapper`: sm4250 → `adsp_sensor_pd` | — | — | nothing |
| SEE client | — | — | hexagonrpcd (Copr: rmuxnet/pipa-support, pocketblue/sm8250), libssc (Fedora review bug 2356939; Copr `@mobility/sdm845` 0.2.2; Debian 0.3.0), iio-sensor-proxy + `Add-libssc-support` patch (Fedora ships 3.8/3.9 without it) | package all three for FAP; give hexagonrpcd a file root with `/vendor/etc/sensors/{config,sns_reg_config,hals.conf}` + a writable copy of `/mnt/vendor/persist/sensors/registry`; allow `AF_QIPCRTR` in the iio-sensor-proxy unit |
| Vibrator | `pm8xxx-vibrator` with `qcom,pmi632-vib` (Fenglin Wu series, merged 2024) | `pmi632_vib` in pmi632.dtsi, disabled | feedbackd | enable node; cap strength (see Risks) |
| RGB LED | `leds-qcom-lpg` `pmi632_lpg_data` (TRILED 0xd000, ch b300/b400/b500 with SDAM 0x48/0x56/0x64, same as vendor) | `pmi632_lpg` in pmi632.dtsi, disabled | feedbackd / sysfs | confirm the LED exists first |
| Camera flash | `leds-qcom-flash` only matches flash subtypes 0x03/0x04/0x07; PMI632 not in the binding | none | — | likely a new subtype **[guess]**; leave to the camera work |
| Fingerprint | none | — | libfprint: no Egis SPI/TZ driver | out of reach (needs QSEECOM + proprietary Egis TA protocol) |
| microSD | `sdhci-msm` | `sdhc_2` okay, cd-gpios TLMM 88 high, vmmc L22A, vqmmc L5A, `sdc2_card_det_n` pull-up | — | L7A (vendor `vdd-io-bias`) isn't referenced; not known to be needed **[guess]** |
| SIM tray | — | — | ModemManager / modem handles UIM presence | nothing; GPIO 88 is already the SD CD |

### Notes on the microSD slot

- Mainline billie2 says `cd-gpios = <&tlmm 88 GPIO_ACTIVE_HIGH>` with pull-up;
  the vendor uses active-high, no pull. The Pro1X uses `GPIO_ACTIVE_LOW` on the same pin, so
  the polarity is board-specific. Ours reads high now with the tray in.
- Because 88 is the *tray* switch, "card present" means "tray present". With
  a SIM-only tray the MMC core polls once, finds nothing and stays quiet.
  Pulling the tray removes both SIM and SD; the modem sees UIM1_PRESENT (79).
- UHS: vendor lists SDR12…SDR104 at up to 200 MHz; mainline sm6115.dtsi has the
  sdhc2 OPP table and DLL config, and L5A's range (1.648–3.056 V) covers
  1.8 V signalling, so SDR104 should negotiate. Untested: no card has been in
  the slot in either capture (status.md "SD controller up (no card)").
- The J606F needs a mystery gate GPIO 45; on the N100, GPIO 45 is an input,
  low, no pull, and nothing in VDT/OPK references it. Not needed **[guess]**.
- SD is on the roadmap as a possible root device (status.md), so verify it
  early (step 2).

## Untested DT snippets for `sm4250-oneplus-billie2-fap.dts`

Our DT header deliberately keeps LPG and the vibrator disabled. These are
the reviewed versions to add when we get to those steps.

```dts
/* Vibrator: PMI632 VIB_LDO @0x5700 (vendor: qcom,qpnp-vibrator-ldo,
 * 3.0 V, overdrive disabled). Mainline has no voltage-cap property;
 * cap the FF magnitude in userspace (see Risks). */
&pmi632_vib {
	status = "okay";
};

/* RGB status LED: only if step 1 shows the LED exists. Channel mapping
 * matches vendor tri-led (red=lpg1, green=lpg2, blue=lpg3), same as
 * sm6115-fxtec-pro1x.dts. Needs <dt-bindings/leds/common.h>. */
&pmi632_lpg {
	status = "okay";

	multi-led {
		color = <LED_COLOR_ID_RGB>;
		function = LED_FUNCTION_STATUS;
		#address-cells = <1>;
		#size-cells = <0>;

		led@1 { reg = <1>; color = <LED_COLOR_ID_RED>; };
		led@2 { reg = <2>; color = <LED_COLOR_ID_GREEN>; };
		led@3 { reg = <3>; color = <LED_COLOR_ID_BLUE>; };
	};
};

/* ADSP: needed for sensors (and audio). Firmware = modem_a image/adsp2.*
 * served the same way as the modem (fap-modem-ram); the path is ours to pick. */
&remoteproc_adsp {
	firmware-name = "qcom/sm6115/OnePlus/billie2/adsp.mbn";
	status = "okay";
};
```

No DT is needed for fingerprint (impossible), sensors (ADSP-internal), the SIM
tray or SD (already in mainline).

## Test plan (least → most risky)

All phone access is done by the main session/user, one actor at a time, as
`safety/recovery-rules.md` requires. Steps 1–3 are read-only.

1. **Read-only, on UBports (already installed).** Collect, without writing:
   `ls /sys/class/leds/` (are red/green/blue there, and does lighting
   them via the vendor sysfs show anything?); a copy of
   `/vendor/etc/sensors/` (config + `sns_reg_config` + `hals.conf`) and of
   `/mnt/vendor/persist/sensors/registry/` (copy only; **persist is an
   identity partition, never write it**); the `sensors.qti`/HAL logcat lines
   that name the probed chips (`ssc`/`sns_` tags), which settles BMI160,
   AK0991x vs MMC56x3x, and the ALS/prox part.
2. **microSD on mainline.** Insert a FAT-formatted card with the tray, boot the netroot,
   check `dmesg | grep mmc0`, the negotiated timing
   (`/sys/kernel/debug/mmc0/ios`), and do a read-only mount plus a read benchmark. Pull and reinsert the tray
   to watch CD and the modem's SIM handling. Risk: none beyond the card.
3. **Look for sensors on the AP I2C (ADSP off).** `i2cdetect -l`, then
   probe only the free address ranges of the two GENI I2C buses (skip
   0x08/0x09/0x0c PM8008, 0x42 FSA4480, 0x58/0x59/0x75 amps/boost), looking
   for 0x28/0x39/0x68/0x0c/0x30. Hits mean a direct-IIO route may exist. Risk: low (reads on
   a bus with PMIC slaves; use `-r`, exclude the known addresses).
4. **Vibrator.** Enable `pmi632_vib`, `fftest`/`fbtest` with a short rumble
   at low magnitude (≤ 0x8000), then build up. Risk: low; only motor
   stress if driven long at full scale.
5. **RGB LED** (if step 1 found one). Enable `pmi632_lpg`, write
   `brightness`/`multi_intensity`, then `pattern`. Risk: low.
6. **ADSP boot.** Enable `remoteproc_adsp` with firmware from `modem_a`
   (read-only, RAM-served like the modem). Check `remoteproc*/state`,
   `qrtr-lookup` for sensor services (SNS QMI service id 400), and that
   pd-mapper answers for `msm/adsp/sensor_pd`. Risk: medium. An ADSP crash
   is normally contained by remoteproc, but this unit has unexplained
   PS_HOLD resets, so run `tools/capture.sh` alongside.
7. **SEE stack.** Run hexagonrpcd (`-f /dev/fastrpc-adsp -d adsp -s`,
   attaching to sensorspd) with the files from step 1 under its root (default
   `/usr/share/qcom/`) and a writable registry dir; then libssc's test CLI,
   then iio-sensor-proxy + `monitor-sensor`. Expect accel, light, proximity
   and compass. Risk: medium (userspace only, but the ADSP can crash on bad
   registry data).

## Risks

- **Vibrator over-voltage:** the vendor runs the ERM at 3.0 V with overdrive
  off. Mainline maps FF magnitude linearly 1.504 → 3.544 V (8 mV steps,
  `VIB_MAX_LEVEL_mV` for drv2 parts), so full scale is ~0.5 V above vendor. Keep
  magnitude ≤ ~0xBB00 (≈ 73 %, ≈ 3.0 V) in feedbackd's profile. A DT
  property for a cap would be an upstream patch.
- **Persist partition:** the sensor registry lives on `persist` (identity
  data). Only ever copy it off; hexagonrpcd must point at a writable copy.
- **Firmware licensing:** `adsp2.*` and the sensor JSONs are OnePlus/Qualcomm
  blobs. Extract them from the phone at run time, never put them in the image (same rule as the
  modem).
- **ADSP shared with audio:** enabling it changes the audio picture too
  (the LPASS pinctrl is currently deferred). Coordinate with the audio area.
- **Unknown sensor bus topology** (above): if the ADSP really shares SE1/SE2,
  then later AP-side drivers on those buses (FSA4480, amps) must not disturb
  it **[guess]**. The vendor kernel ran both at once without visible issues.
- **Fingerprint pins:** never un-reserve GPIO 14–17 or touch QUP SE5; TZ
  owns them and an access faults (XPU) and resets the phone.
- **Tray detect:** removing the tray also pulls the SIM; hot-removal of a
  mounted SD root would be fatal for the session.
