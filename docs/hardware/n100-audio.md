<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# N100 audio: hardware inventory and mainline bring-up plan

Status: **research only, nothing tested on mainline** (written 2026-11-20).
Everything below marked *untested* or *guess* needs verifying on the phone.
Sources: vendor DT dumped from the running phone
(`UBports-N100/log/hw-inventory/20261120-134342/device-tree.dts`, "VDT:line"),
vendor-kernel dmesg (`…/raw/dmesg.txt`, "dmesg:line"), mainline v7.3
(`fap-build/linux`, plus a sparse clone of `sound/`, `drivers/soundwire`,
`drivers/pinctrl/qcom` in `fap-build/research/audio/linux`), the LineageOS
billie2 kernel and device trees (cloned in `fap-build/research/audio/{lin,dev}`).

## 1. Summary

- Same audio design as Qualcomm's QRB4210-RB2 board: **APR** ADSP (not GPR or
  AudioReach), LPASS **rx/tx/va macros** ("bolero" v5 in vendor terms),
  **SoundWire** to a **WCD937x** codec, and **analog** amplifiers on the
  codec's AUX and EAR outputs instead of WSA smart amps.
- Mainline v7.3 has every SoC-side driver: q6 APR DAIs, LPI pinctrl, rx/tx/va
  macros with `sm6115` compatibles, SoundWire v1.6, wcd937x, the `sm8250.c`
  machine driver with `qcom,qrb4210-rb2-sndcard`. What's missing:
  1. **DT nodes** for the macros and SoundWire in `sm6115.dtsi`. Linaro posted
     them (Alexey Klimov, "qrb4210-rb2: add wsa audio playback and capture
     support", v3, 2025-05-22) but they weren't merged by v7.3 or current master.
     We carry them in our board DT (§5).
  2. **Fedora kernel config:** `CONFIG_SND_SOC_SM8250` and
     `CONFIG_SM_LPASSCC_6115` are **not set**. Fedora's
     `kernel-aarch64-fedora.config` (f45 branch) has `SND_SOC_QDSP6`,
     `QCOM_APR`, the LPASS macros, `SND_SOC_WCD937X_SDW`, `SOUNDWIRE_QCOM`,
     `PINCTRL_SM4250_LPASS_LPI` and `TYPEC_MUX_FSA4480` as modules. So we build
     `snd-soc-sm8250.ko` out of tree (like `kmod/panel-ili9882n`).
  3. **No driver for the AW87529/AW87359 amps.** Mainline `aw87390.c` is a
     different chip (ID 0x76/0xc1, ACF firmware). We need a small new driver
     (§6). Until it exists: headphones, earpiece-less mic capture, and amp
     tests through `i2cset`.
  4. **UCM:** nothing upstream for `sm4250`; we write our own, built from
     alsa-ucm-conf's `codecs/wcd937x` and `codecs/qcom-lpass` pieces (§8).
- **Why `a7c0000.pinctrl` stays deferred:** `lpass_tlmm` in `sm6115.dtsi:822-833`
  takes its clock from `<&q6afecc LPASS_HW_DCODEC_VOTE …>` (line 827), and
  `q6afecc` sits inside `remoteproc_adsp` → glink-edge → APR → AFE service
  (`sm6115.dtsi:2772-2833`). `remoteproc_adsp` is `status = "disabled"`
  (line 2795) and our board DT doesn't enable it, so the clock provider is
  never registered and the LPI driver defers forever. Even with ADSP enabled,
  it probes only **after** the ADSP has booted and its audio PD
  (`msm/adsp/audio_pd`) is up: the q6afe clocks are an APR service on the
  DSP. Not a bug. (The vendor kernel's LPI driver depends on the ADSP the
  same way: "lpi_gpio_read: ADSP is down due to SSR", dmesg:4090.)
  Cosmetic option until audio work starts: `&lpass_tlmm { status = "disabled"; };`.

## 2. Hardware inventory (vendor DT + vendor dmesg)

| Part | Details | Source |
|---|---|---|
| ADSP | `ab00000.qcom,lpass`, PAS id 1, carveout 0x53800000 + 0x2800000 (same as mainline `pil_adsp_mem`). Firmware **`adsp2.mdt`** + `adsp2.b00…b31` (the vendor picks "adsp2" via the `adsp_variant` qfprom cell) | dmesg:3796-3804, VDT:378, firmware.txt |
| DSP protocol | APR (`apr_audio_svc` glink channel, "Q6 is Up") | dmesg:3957, 4079 |
| Audio PD | `msm/adsp/audio_pd`, service `avs/audio` (mainline in-kernel pd-mapper has it for sm4250/sm6115: `drivers/soc/qcom/qcom_pd_mapper.c:541-548,653`) | dmesg:4069 |
| Codec | **WCD937x** (`qcom,wcd937x-codec`; `qcom,split-codec`). Rouleur (PM2250 codec) modules are also loaded but no DT node uses them | VDT:12581-12609 |
| Codec reset | **TLMM GPIO 92**, output-high = out of reset, 16 mA (mainline: `reset-gpios = <&tlmm 92 GPIO_ACTIVE_LOW>`) | VDT:17345-17350 → VDT:9845 |
| Codec supplies | vdd-rxtx, vdd-px: **PM6125 L9A** 1.8 V; vdd-buck: **PM6125 L14A** 1.8 V (on demand); no mic-bias supply listed | VDT:12595-12603, 1425, 1530 |
| Mic bias | MICBIAS1 1.8 V, **MICBIAS2 2.7 V** (headset mic, OnePlus overlay), MICBIAS3 1.8 V; headset mic max threshold 2550 mV | VDT:12604-12606; `billie2/audio/bengal-oem-audio-overlay.dtsi` |
| MBHC | `msm-mbhc-hphl-swh = 1`, `msm-mbhc-gnd-swh = 1` → in mainline leave out both `qcom,*-jack-type-normally-closed` properties (absent = swh true, `sound/soc/codecs/wcd-mbhc-v2.c:1460-1468`). Real 3.5 mm jack | VDT:12627-12628 |
| RX SoundWire | master id 2, regs 0xa610000, IRQ SPI 297 (0x129), 5 ports; slave `wcd937x-rx` (SDW id …0224) | VDT:12538-12568 |
| TX SoundWire | VA master (id 3), 0xa740000, IRQs SPI 296 + 79, 3 ports; slave `wcd937x-tx` (…0223). Vendor probe failed here with -28 (dmesg:4109), unrelated to mainline | VDT:12497-12531 |
| RX macro | 0xa600000 | VDT:12533 |
| TX macro | 0xa620000 (no SWR GPIOs) | VDT:12571 |
| VA macro | 0xa730000, DMIC rate 600 kHz | VDT:12492 |
| LPI pins | SWR TX clk/data: LPI GPIO 0/1/2; SWR RX clk/data: 3/4/5 (func1, 10 mA, bus-hold on data); DMIC clk 6 and 8 defined, **not used** by any mixer path | VDT:14565-14725, 14741-14818 |
| Speaker amp | **Awinic AW87529** (class K, boost), I2C **QUP SE2 (0x4a88000, mainline `i2c2`) addr 0x58**, reset/enable **TLMM GPIO 96** (active high). Fed from WCD937x **AUX**. Chip ID reg 0x00 = 0x59 (verified on this unit, dmesg:2825) | VDT:11298-11302, `bengal-oem-audio-overlay.dtsi` |
| Earpiece amp | **Awinic AW87359**, same bus, addr **0x59**, no GPIO (enabled by register 0x01 only). Fed from WCD937x **EAR**. Chip ID 0x59 (dmesg:2829). Android also uses it for a second speaker channel through the earpiece ("dspk" mode) | VDT:11293-11296, mixer paths below |
| TI TPS61280 | Boost converter on the same bus, 0x75, enable GPIO 54 (high). Vendor driver writes 0x01=0x05, 0x02=0x0b, 0x03=0x1d at boot (dmesg:831-843). **Role unknown (guess: system/battery boost, not audio). Leave alone.** | VDT:11304-11310 |
| SIA8109 amps | `si,sia81xx` nodes on GPIO 96 (one-wire). Second-source amp for other units; on this unit the AW87529 answers on I2C, so **don't describe sia81xx** (its one-wire pulses on GPIO 96 would hit the AW87529's reset pin) | VDT:17309-17340 |
| FSA4480 | USB-C analog audio switch, I2C QUP SE1 (0x4a84000, mainline `i2c1`) addr 0x42, bound on vendor kernel. Not needed for the 3.5 mm jack; later | VDT:11042-11046, i2c.txt |
| WSA881x | two `wsa881x-i2c-codec` nodes, **disabled** (not fitted) | VDT:11191-11210 |

Microphones and routes, from Android's `mixer_paths_qrd.xml` (LineageOS
`android_device_oneplus_billie2`, branch lineage-22.2,
`audio/mixer_paths_qrd.xml`):

| Function | Path | Lines |
|---|---|---|
| Main mic | AMIC1 → ADC1 (`ADC1_MIXER Switch`) → SWR_MIC0 → TX DEC2 → TX_CDC_DMA_TX_3 | 2983-2989 |
| Headset mic | AMIC2 → `ADC2 MUX`=INP2 → SWR_MIC4 → TX DEC0 → TX_CDC_DMA_TX_4 | 2991-3000 |
| Second mic | AMIC3 → `ADC2 MUX`=INP3 → SWR_MIC4 → TX DEC2 | 3002-3009 |
| Loudspeaker | RX1 → `RX INT2_1 MIX1 INP0` → AUX (`AUX_RDAC Switch`, `RX HPH Mode`=CLS_AB) → AW87529 ("Ext_Speaker_Amp_spkmode") ; plus RX0 → INT0 → `RDAC3_MUX`=RX1 → EAR → AW87359 "dspk" (stereo via earpiece). Digital volume 78 | 3047-3065 |
| Earpiece | RX0 → INT0 → EAR (`EAR_RDAC Switch`, `RDAC3_MUX`=RX1, `RX_EAR Mode`=ON) → AW87359 "drcv" | 3171-3180 |
| Headphones | RX0/RX1 → INT0/INT1 → HPHL/HPHR (`HPHL_RDAC`/`HPHR_RDAC Switch`), compander on, volume 82 | 3274-3290 |

`RX_EAR Mode` (vendor rx-macro control) doesn't exist in mainline
`lpass-rx-macro.c`; the EAR path may need a mainline fix (*guess*, check at step 7).

## 3. Firmware

| File | Where on the phone | Use |
|---|---|---|
| `adsp2.mdt`, `adsp2.b00`-`b31` (no `.b11`) | **`modem_a` partition, `image/`** (the vendor's `/vendor/firmware_mnt/image`). Already bind-mounted read-only by `fap-modem-ram` at `/run/fap-firmware/qcom/sm6115/OnePlus/billie2/` | ADSP. Load as `qcom/sm6115/OnePlus/billie2/adsp2.mdt` (the mdt loader handles split `.bNN`). Not redistributable |
| `adspr.jsn`, `adsps.jsn`, `adspua.jsn` | same | for the userspace pd-mapper; not needed with the kernel's `qcom_pd_mapper` |
| `aw87529_kspk.bin` (42 B), `aw87529_{drcv,hvload,expvdd,hph,hphkspk}.bin`, `aw87359_{drcv,dspk,abspk,abrcv}.bin` (44 B) | `vendor` logical partition (in `super`), `/vendor/firmware/` | register/value byte pairs written by the vendor amp drivers. Their contents are already in dmesg:3315-3548 (table §6); copy the files read-only to double-check |
| `/vendor/dsp/adsp/*` (`dsp_a` partition) | | fastrpc skeleton libraries (sensors etc.), not needed for audio |

No topology file is needed: that's an AudioReach/GPR thing; the APR path uses
the DSP's built-in defaults. ACDB calibration (Android's HAL pushes it through
`/dev/msm_audio_cal`) has no mainline equivalent; audio works without it on
other APR devices, maybe with less tuning (EQ/protection).

## 4. Kernel modules

Fedora 45 (`kernel-aarch64-fedora.config`, f45 branch, fetched 2026-11-20):
`QCOM_Q6V5_PAS`, `QCOM_APR`, `SND_SOC_QDSP6`, `SND_SOC_LPASS_{RX,TX,VA}_MACRO`,
`SND_SOC_WCD937X_SDW`, `SOUNDWIRE_QCOM`, `PINCTRL_SM4250_LPASS_LPI`,
`TYPEC_MUX_FSA4480` are `=m`. **Missing:**

| Option | Source | Plan |
|---|---|---|
| `SND_SOC_SM8250` (`snd-soc-sm8250`) | `sound/soc/qcom/sm8250.c` (one file; needs `snd-soc-qcom-common` and `snd-soc-qcom-sdw`, which Fedora builds because `SND_SOC_SC8280XP=m` selects them; verify with `modinfo`) | out-of-tree module `kmod/snd-soc-sm8250` from the v7.3 file; ask Fedora to enable it |
| `SM_LPASSCC_6115` (`lpasscc-sm6115`) | `drivers/clk/qcom/lpasscc-sm6115.c` (resets for the SoundWire CGCR, compatibles `qcom,sm6115-lpassaudiocc` / `qcom,sm6115-lpasscc`) | optional: `qcom.c:1588` gets the reset with `devm_reset_control_get_optional_exclusive`. Start without the `resets` properties; add the module if SoundWire won't enumerate |
| AW87529/AW87359 | none | new driver, §6 |

## 5. DT additions for our board DT (all *untested*)

Goes into `devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts`. The
SoC nodes are adapted from Linaro's v3 patch 07/12 (sm6115 LPASS devices) and
08/12 (sm4250 SWR pins); the codec from 09/12 (RB2 wcd937x). Changes from the
patch: va-macro takes only `qcom,sm6115-lpass-va-macro` (v7.3 binding,
`qcom,lpass-va-macro.yaml:17,108`), `resets` dropped (see §4), N100 GPIOs and
supplies. Port parameters are RB2's (same SoC and codec; the vendor's port
counts match: RX 5, TX 3).

```dts
/* SoC part: belongs in sm6115.dtsi upstream; carried here until merged. */
&soc {
	rxmacro: codec@a600000 {
		compatible = "qcom,sm6115-lpass-rx-macro";
		reg = <0x0 0x0a600000 0x0 0x1000>;
		clocks = <&q6afecc LPASS_CLK_ID_RX_CORE_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&q6afecc LPASS_CLK_ID_RX_CORE_NPL_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&q6afecc LPASS_HW_DCODEC_VOTE LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&vamacro>;
		clock-names = "mclk", "npl", "dcodec", "fsgen";
		assigned-clocks = <&q6afecc LPASS_CLK_ID_RX_CORE_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
				  <&q6afecc LPASS_CLK_ID_RX_CORE_NPL_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>;
		assigned-clock-rates = <22579200>, <22579200>;
		#clock-cells = <0>;
		clock-output-names = "mclk";
		#sound-dai-cells = <1>;
	};

	swr1: soundwire@a610000 {
		compatible = "qcom,soundwire-v1.6.0";
		reg = <0x0 0x0a610000 0x0 0x2000>;
		interrupts = <GIC_SPI 297 IRQ_TYPE_LEVEL_HIGH>;
		clocks = <&rxmacro>;
		clock-names = "iface";
		label = "RX";
		qcom,din-ports = <0>;
		qcom,dout-ports = <5>;
		qcom,ports-sinterval-low =	/bits/ 8 <0x03 0x1f 0x1f 0x07 0x00>;
		qcom,ports-offset1 =		/bits/ 8 <0x00 0x00 0x0b 0x01 0x00>;
		qcom,ports-offset2 =		/bits/ 8 <0x00 0x00 0x0b 0x00 0x00>;
		qcom,ports-hstart =		/bits/ 8 <0xff 0x03 0xff 0xff 0xff>;
		qcom,ports-hstop =		/bits/ 8 <0xff 0x06 0xff 0xff 0xff>;
		qcom,ports-word-length =	/bits/ 8 <0x01 0x07 0x04 0xff 0xff>;
		qcom,ports-block-pack-mode =	/bits/ 8 <0xff 0x00 0x01 0xff 0xff>;
		qcom,ports-block-group-count =	/bits/ 8 <0xff 0xff 0xff 0xff 0x00>;
		qcom,ports-lane-control =	/bits/ 8 <0x01 0x00 0x00 0x00 0x00>;
		pinctrl-0 = <&lpass_rx_swr_active>;
		pinctrl-names = "default";
		#sound-dai-cells = <1>;
		#address-cells = <2>;
		#size-cells = <0>;

		wcd937x_rx: codec@0,4 {
			compatible = "sdw20217010a00";
			reg = <0 4>;
			qcom,rx-port-mapping = <1 2 3 4 5>;
		};
	};

	txmacro: codec@a620000 {
		compatible = "qcom,sm6115-lpass-tx-macro";
		reg = <0x0 0x0a620000 0x0 0x1000>;
		clocks = <&q6afecc LPASS_CLK_ID_TX_CORE_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&q6afecc LPASS_CLK_ID_TX_CORE_NPL_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&q6afecc LPASS_HW_DCODEC_VOTE LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&vamacro>;
		clock-names = "mclk", "npl", "dcodec", "fsgen";
		assigned-clocks = <&q6afecc LPASS_CLK_ID_TX_CORE_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
				  <&q6afecc LPASS_CLK_ID_TX_CORE_NPL_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>;
		assigned-clock-rates = <19200000>, <19200000>;
		#clock-cells = <0>;
		clock-output-names = "mclk";
		#sound-dai-cells = <1>;
	};

	vamacro: codec@a730000 {
		compatible = "qcom,sm6115-lpass-va-macro";
		reg = <0x0 0x0a730000 0x0 0x1000>;
		clocks = <&q6afecc LPASS_CLK_ID_TX_CORE_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&q6afecc LPASS_HW_DCODEC_VOTE LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
			 <&q6afecc LPASS_CLK_ID_TX_CORE_NPL_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>;
		clock-names = "mclk", "dcodec", "npl";
		assigned-clocks = <&q6afecc LPASS_CLK_ID_TX_CORE_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>,
				  <&q6afecc LPASS_CLK_ID_TX_CORE_NPL_MCLK LPASS_CLK_ATTRIBUTE_COUPLE_NO>;
		assigned-clock-rates = <19200000>, <19200000>;
		#clock-cells = <0>;
		clock-output-names = "fsgen";
		#sound-dai-cells = <1>;
	};

	swr0: soundwire@a740000 {
		compatible = "qcom,soundwire-v1.6.0";
		reg = <0x0 0x0a740000 0x0 0x2000>;
		interrupts = <GIC_SPI 296 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 79 IRQ_TYPE_LEVEL_HIGH>;
		clocks = <&txmacro>;
		clock-names = "iface";
		label = "VA_TX";
		qcom,din-ports = <3>;
		qcom,dout-ports = <0>;
		qcom,ports-sinterval-low =	/bits/ 8 <0x03 0x03 0x03>;
		qcom,ports-offset1 =		/bits/ 8 <0x01 0x02 0x01>;
		qcom,ports-offset2 =		/bits/ 8 <0x00 0x00 0x00>;
		qcom,ports-hstart =		/bits/ 8 <0xff 0xff 0xff>;
		qcom,ports-hstop =		/bits/ 8 <0xff 0xff 0xff>;
		qcom,ports-word-length =	/bits/ 8 <0xff 0xff 0xff>;
		qcom,ports-block-pack-mode =	/bits/ 8 <0xff 0xff 0xff>;
		qcom,ports-block-group-count =	/bits/ 8 <0xff 0xff 0xff>;
		qcom,ports-lane-control =	/bits/ 8 <0x00 0x00 0x00>;
		pinctrl-0 = <&lpass_tx_swr_active>;
		pinctrl-names = "default";
		#sound-dai-cells = <1>;
		#address-cells = <2>;
		#size-cells = <0>;

		wcd937x_tx: codec@0,3 {
			compatible = "sdw20217010a00";
			reg = <0 3>;
			qcom,tx-port-mapping = <1 1 2 3>;
		};
	};
};

&lpass_tlmm {	/* SWR pins: vendor VDT:14565-14725 = Linaro patch 08/12 */
	lpass_tx_swr_active: lpass-tx-swr-active-state {
		clk-pins { pins = "gpio0"; function = "swr_tx_clk";
			   drive-strength = <10>; slew-rate = <3>; bias-disable; };
		data-pins { pins = "gpio1", "gpio2"; function = "swr_tx_data";
			    drive-strength = <10>; slew-rate = <3>; bias-bus-hold; };
	};
	lpass_rx_swr_active: lpass-rx-swr-active-state {
		clk-pins { pins = "gpio3"; function = "swr_rx_clk";
			   drive-strength = <10>; slew-rate = <3>; bias-disable; };
		data-pins { pins = "gpio4", "gpio5"; function = "swr_rx_data";
			    drive-strength = <10>; slew-rate = <3>; bias-bus-hold; };
	};
};

&remoteproc_adsp {
	firmware-name = "qcom/sm6115/OnePlus/billie2/adsp2.mdt";
	status = "okay";
};

/ {
	/* guess: VDD_MIC_BIAS comes from the battery rail; the driver wants a supply */
	vph_pwr: regulator-vph-pwr {
		compatible = "regulator-fixed";
		regulator-name = "vph_pwr";
		regulator-min-microvolt = <3700000>;
		regulator-max-microvolt = <3700000>;
		regulator-always-on;
		regulator-boot-on;
	};

	wcd937x: audio-codec {
		compatible = "qcom,wcd9370-codec";	/* driver reads the chip ID and handles 9375 too */
		pinctrl-0 = <&wcd_reset_n>;
		pinctrl-names = "default";
		reset-gpios = <&tlmm 92 GPIO_ACTIVE_LOW>;
		vdd-buck-supply = <&vreg_l14a>;
		vdd-rxtx-supply = <&vreg_l9a>;
		vdd-px-supply = <&vreg_l9a>;
		vdd-mic-bias-supply = <&vph_pwr>;
		qcom,micbias1-microvolt = <1800000>;
		qcom,micbias2-microvolt = <2700000>;
		qcom,micbias3-microvolt = <1800000>;
		qcom,micbias4-microvolt = <1800000>;
		/* RB2 values; vendor values not extracted (guess) */
		qcom,mbhc-buttons-vthreshold-microvolt = <75000 150000 237000 500000 500000 500000 500000 500000>;
		qcom,rx-device = <&wcd937x_rx>;
		qcom,tx-device = <&wcd937x_tx>;
		#sound-dai-cells = <1>;
	};

	sound {
		compatible = "qcom,qrb4210-rb2-sndcard";	/* driver_name "sm4250" */
		model = "OnePlus-Nord-N100";
		audio-routing = "IN1_HPHL", "HPHL_OUT",
				"IN2_HPHR", "HPHR_OUT",
				"IN3_AUX", "AUX_OUT",
				"AMIC1", "MIC BIAS1",
				"AMIC2", "MIC BIAS2",
				"AMIC3", "MIC BIAS3",
				"TX SWR_ADC0", "ADC1_OUTPUT",
				"TX SWR_ADC1", "ADC2_OUTPUT";
				/* + amp routes once the driver exists (§6) */

		mm1-dai-link { link-name = "MultiMedia1";
			cpu { sound-dai = <&q6asmdai MSM_FRONTEND_DAI_MULTIMEDIA1>; }; };
		mm2-dai-link { link-name = "MultiMedia2";
			cpu { sound-dai = <&q6asmdai MSM_FRONTEND_DAI_MULTIMEDIA2>; }; };

		wcd-playback-dai-link {
			link-name = "WCD Playback";
			cpu { sound-dai = <&q6afedai RX_CODEC_DMA_RX_0>; };
			platform { sound-dai = <&q6routing>; };
			codec { sound-dai = <&wcd937x 0>, <&swr1 0>, <&rxmacro 0>; };
		};

		wcd-capture-dai-link {
			link-name = "WCD Capture";
			cpu { sound-dai = <&q6afedai TX_CODEC_DMA_TX_3>; };
			platform { sound-dai = <&q6routing>; };
			codec { sound-dai = <&wcd937x 1>, <&swr0 0>, <&txmacro 0>; };
		};
	};
};

&tlmm {
	wcd_reset_n: wcd-reset-n-state {	/* vendor VDT:9845 */
		pins = "gpio92";
		function = "gpio";
		drive-strength = <16>;
		output-high;
	};
};
```

Notes: `vreg_l9a` (1.8-2.0 V) and `vreg_l14a` (1.704-1.904 V) are already
in mainline `sm4250-oneplus-billie2.dts:114,139`. The TX widget names
(`TX SWR_ADC0/1`) and DAI indices follow `qcm6490-idp.dts:855-910`; check
dmesg for "no source/sink widget" and fix. The headset-mic route via
`TX_CODEC_DMA_TX_4` (vendor) may need its own link later.

## 6. Speaker and earpiece amps (new driver)

Vendor drivers: LineageOS `android_kernel_oneplus_sm4250` (branch
lineage-22.2), `techpack/audio/asoc/codecs/aw87529.{c,h}` and
`aw87359.{c,h}`; mixer controls in `techpack/audio/asoc/bengal.c:2882-3033`.

Sequences, as the vendor driver does them:
- **AW87529 on** (`aw87529.c:123-139,186-213`): GPIO 96 low, 2 ms, high,
  2 ms; write 0x64=0x2C; then the byte pairs from `aw87529_kspk.bin`.
  **Off** (`aw87529.c:336-345`): 0x01=0x00, then GPIO 96 low.
- **AW87359 on**: no GPIO; write the pairs of `aw87359_drcv.bin` (earpiece)
  or `aw87359_dspk.bin` (speaker mode). **Off:** 0x01=0x00.
- The `.bin` files override the defaults compiled into the `.h` files, and
  differ from them, so use the **.bin values** as loaded on this phone:

| Mode | Register writes (in order, hex; last write enables) | dmesg |
|---|---|---|
| AW87529 kspk | 69=a5 69=a5 02=09 03=f0 04=11 05=0c 06=55 07=72 08=0b 09=08 0a=4b 60=16 61=20 62=01 63=0b 64=c5 65=a4 66=78 67=c4 68=90 **01=f0** | 3411-3433 |
| AW87359 drcv | 70=80 01=00 01=00 02=00 03=08 04=05 05=00 06=0f 07=4e 08=09 09=08 0a=4b 61=bb 62=80 63=29 64=58 65=cd 66=80 67=2f 68=07 69=db **01=0d** | 3315-3338 |
| AW87359 dspk | 70=80 01=00 01=00 02=0c 03=06 04=05 05=0c 06=0f 07=6e 08=09 09=08 0a=4b 61=bb 62=80 63=29 64=58 65=cd 66=3c 67=2f 68=07 69=db **01=0d** | 3363-3386 |

(AW87529's dump starts with 69=a5 twice where the `.h` default has 69=80,
69=a5; *possibly* a print artifact. `hexdump` the real `.bin` before use.)

Driver plan (*proposal*): one I2C ASoC component driver `awinic,aw87529` /
`awinic,aw87359`, register sequence picked by compatible (or a
`awinic,mode`-style property), a DAPM `INPUT("IN")` → `PGA_E` (sequence on
POST_PMU, off on PRE_PMD) → `OUTPUT("OUT")`, optional `reset-gpios`; check
chip ID 0x59 at probe and refuse otherwise. Model on the mainline
`aw87390.c` "anbernic,rgds-amp" variant (`aw87390.c:310-470`), which does the
same thing with a fixed register list. Board DT, *untested*:

```dts
&i2c2 {
	status = "okay";
	speaker_amp: amplifier@58 {
		compatible = "awinic,aw87529";		/* new binding */
		reg = <0x58>;
		reset-gpios = <&tlmm 96 GPIO_ACTIVE_HIGH>;	/* high = running */
		sound-name-prefix = "Speaker Amp";
	};
	earpiece_amp: amplifier@59 {
		compatible = "awinic,aw87359";		/* new binding */
		reg = <0x59>;
		sound-name-prefix = "Earpiece Amp";
	};
	/* tps61280@75: not described; leave it as the bootloader left it */
};
/* in &sound: aux-devs = <&speaker_amp>, <&earpiece_amp>;  (common.c:221)
 * routing: "Speaker Amp IN", "AUX", "Earpiece Amp IN", "EAR" */
```

## 7. Test plan (least to most risky)

One actor on the phone; whoever runs this owns it. Netroot (RAM-booted) only;
nothing here writes storage. Do the steps in order and stop at the first
failure. Record each in `docs/status.md`.

1. **Offline prep (no phone).** Add §5's SoC/ADSP part only (not the
   codec/sound nodes yet), build the DTB (`tools/build-dtb.sh`), check
   `dtbs_check`/dtc warnings. Build `kmod/snd-soc-sm8250` against 7.3.4.
2. **Read-only I2C check** (needs `i2c2` enabled in DT, no amp nodes;
   `modprobe i2c-dev`, `i2c-tools`). Find the bus: `ls -l
   /sys/bus/i2c/devices/` → the adapter under `4a88000.i2c`. Then
   `i2cget -y <bus> 0x59 0x00` → expect `0x59` (AW87359). The AW87529 (0x58)
   may stay silent while GPIO 96 is low; don't toggle it yet. Do **not** use
   `i2cdetect` write-probing. *Risk: none.*
3. **ADSP alone.** `fap-modem-ram` first (it mounts `modem_a` and sets the
   firmware path), then `echo start > /sys/class/remoteproc/<adsp>/state`
   (the PAS driver auto-boots at probe, before the firmware is mounted, so
   expect one failed attempt in dmesg). Expect: state `running`, glink
   `apr_audio_svc`, `q6afe`/`q6asm`/`q6adm` probe, **`a7c0000.pinctrl`
   leaves the deferred list** (`cat /sys/kernel/debug/devices_deferred`).
   *Risk: low (a DSP crash is recovered by the kernel; worst case reboot).*
4. **Macros + SoundWire + codec, no `sound` node.** Add `wcd937x` and the
   SWR nodes. Expect: rx/tx/va macros probe, SoundWire enumerates two slaves
   (`/sys/bus/soundwire/devices/sdw:0:0217:010a:00:{3,4}` or similar), the
   wcd937x reads its chip ID (dmesg has no "unknown chip id", see
   `wcd937x.c:2510-2514`). If enumeration fails, add `lpasscc-sm6115` and
   the `resets` from Linaro's patch. *Risk: low (the codec is reset-held
   until probe; supplies are the vendor 1.8 V values).*
5. **Sound card.** Add `sound` + `snd-soc-sm8250.ko`. Expect `aplay -l` to
   show card `OnePlus-Nord-N100` (driver `sm4250`), no DAPM routing errors.
   *Risk: none (no output path enabled).*
6. **Headphones and jack.** Wired headphones **not on your ears**. Plug in;
   `amixer -c0 contents | grep -i jack` / `evtest` should show the jack
   event. Set the headphone path (UCM `codecs/wcd937x/HeadphoneEnableSeq.conf`
   + `codecs/qcom-lpass/rx-macro/HeadphoneEnableSeq.conf`), plus
   `RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1` = 1, `RX_RX0/RX1 Digital
   Volume` = 40 (≈ -44 dB; 84 = 0 dB), then `speaker-test -c2 -t sine -l1`.
   Raise slowly. *Risk: hearing if worn; none for the hardware.*
7. **Microphones.** Main mic: `TX DEC2 MUX`=SWR_MIC, `TX SMIC MUX2`=SWR_MIC0,
   `TX_AIF1_CAP Mixer DEC2`=1, `ADC1_MIXER Switch`=1, `ADC1 Switch`=1,
   `MultiMedia2 Mixer TX_CODEC_DMA_TX_3`=1; `arecord -D hw:0,1 -f S16_LE -r
   48000 -c1 -d5`. Then AMIC3 (`ADC2 MUX`=INP3) and the headset mic
   (`ADC2 MUX`=INP2, micbias 2.7 V). *Risk: none.*
8. **Earpiece (AW87359, rcv mode).** Only after the amp driver exists, or
   manually: route RX0 → EAR (`EAR_RDAC Switch`=1, `RDAC3_MUX`=RX1, volume
   40), start a quiet sine, **then** write the `drcv` row from §6 with
   `i2cset -y <bus> 0x59 <reg> <val>` and stop with `0x01=0x00`. Ear away
   from the phone. *Risk: medium: wrong gain could overdrive the small
   earpiece; use only the vendor values.*
9. **Loudspeaker (AW87529).** ⚠️ **Highest risk.** Class-K amp with a boost
   converter: a wrong boost/gain/power-limit register can **burn the speaker
   or stress the battery rail**. Use only the vendor `kspk` sequence (§6),
   verified against the real `aw87529_kspk.bin`. Order: route RX1 → AUX
   (`RX INT2_1 MIX1 INP0`=RX1, `AUX_RDAC Switch`=1, `RX HPH Mode`=CLS_AB,
   `RX_RX2 Digital Volume`=40) and play a quiet sine; then GPIO 96 high
   (`gpioset`), 2 ms, 0x64=0x2C, the kspk pairs, 0x01=0xf0 last. Run ≤10 s,
   then 0x01=0x00 and GPIO 96 low; touch-check the phone for heat. Raise
   volume in small steps, never above the vendor's 78. Never leave the amp
   enabled with no stream (the driver's DAPM event fixes that later).
10. **Amp driver + DAPM**, then UCM (§8) and PipeWire/WirePlumber. Repeat 8
    and 9 through the driver.
11. **Later / out of scope:** stereo via earpiece (dspk), FSA4480 for USB-C
    headsets (needs PMI632 Type-C, which our DT keeps disabled), voice calls
    (modem ↔ ADSP path, needs q6voice, not in mainline), HDMI/DP (none).

## 8. UCM

Card driver name `sm4250`, so alsa-ucm-conf looks for
`ucm2/conf.d/sm4250/<model>.conf`; none exists (alsa-ucm-conf master has
`sm8250`, `qcm6490`, etc., not `sm4250`). Ship in our image, *sketch*:

```
# /usr/share/alsa/ucm2/conf.d/sm4250/OnePlus-Nord-N100.conf
Syntax 6
SectionUseCase."HiFi" { File "/OnePlus/billie2/HiFi.conf" Comment "Default" }
BootSequence [ cset "name='RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1"
               cset "name='MultiMedia2 Mixer TX_CODEC_DMA_TX_3' 1" ]
```

`HiFi.conf`: devices **Headphones** (include `/codecs/wcd937x/Headphone*Seq.conf`
and `/codecs/qcom-lpass/rx-macro/Headphone*Seq.conf`; `JackControl
"Headphone Jack"`), **Speaker** (§2 loudspeaker controls + "Speaker Amp"
switch from our driver; `JackHWMute "Headphones"`), **Earpiece** (EAR path),
**Mic1** (AMIC1 controls from step 7), **Headset mic** (include
`/codecs/wcd937x/HeadphoneMicEnableSeq.conf` + tx-macro equivalent; it
already uses `ADC2 MUX` INP2 = the N100's AMIC2). Model on
`ucm2/Qualcomm/qcm6490/QCM6490-IDP/HiFi.conf` (a WCD9370 + rx/tx-macro board).
Upstream the result to alsa-ucm-conf once it works.

## 9. Risks and open questions

- **Speaker damage (step 9):** the only step that can hurt hardware. Vendor
  values only, low volume, short runs, amp off when idle.
- **GPIO 96** is shared in the vendor DT by AW87529 reset and the SIA8109
  one-wire pin. Describe only the AW87529. Another N100 unit might carry
  SIA8109 amps instead (*guess* from the vendor DT; check the chip ID first).
- **TPS61280 (0x75, GPIO 54):** unknown role; never write it.
- **vdd-mic-bias as a dummy fixed regulator:** *guess*; the vendor DT lists no
  such supply. If mic bias is weak, look for the real rail.
- **`RX_EAR Mode`** missing in mainline rx-macro: EAR output may be quiet or
  wrong class until fixed (step 8 will tell).
- **No ACDB:** no OEM EQ or speaker protection. Keep speaker volume moderate.
- **ADSP firmware** comes from `modem_a` at run time (not redistributable),
  same as the modem.
- **Upstream status** may change: re-check sm6115.dtsi for the LPASS nodes
  (Linaro series) and `SND_SOC_SM8250` in Fedora before carrying copies.

## Sources

- Vendor DT/dmesg/firmware listings: `UBports-N100/log/hw-inventory/20261120-134342/`.
- OnePlus overlay: github.com/OnePlusOSS/android_kernel_oneplus_sm4250
  (oneplus/SM4250_R_11.0) `arch/arm64/boot/dts/vendor/billie2/audio/bengal-oem-audio-overlay.dtsi`.
- Vendor audio drivers: github.com/LineageOS/android_kernel_oneplus_sm4250
  (lineage-22.2) `techpack/audio/asoc/{bengal.c,codecs/aw87529.*,codecs/aw87359.*}`.
- Mixer paths: github.com/LineageOS/android_device_oneplus_billie2
  (lineage-22.2) `audio/mixer_paths_qrd.xml`.
- Linaro series v3 (2025-05-22): https://patchew.org/linux/20250522-rb2._5Faudio._5Fv3-v3-0-9eeb08cab9dc@linaro.org
  (patch 07 sm6115 LPASS, 08 sm4250 pins, 09 RB2 wcd937x, 11 RB2 AUX speaker).
- Mainline v7.3: `arch/arm64/boot/dts/qcom/{sm6115.dtsi,sm4250.dtsi,qrb4210-rb2.dts,qcm6490-idp.dts}`,
  `sound/soc/qcom/sm8250.c:207-215`, `sound/soc/qcom/common.c:198-221`,
  `sound/soc/codecs/{wcd937x.c,lpass-*-macro.c,aw87390.c}`,
  `drivers/soundwire/qcom.c:1588,1832-1840`, `drivers/pinctrl/qcom/pinctrl-sm4250-lpass-lpi.c`,
  `drivers/remoteproc/qcom_q6v5_pas.c:982-990,1878`.
- Fedora config: https://src.fedoraproject.org/rpms/kernel/raw/f45/f/kernel-aarch64-fedora.config
- alsa-ucm-conf: github.com/alsa-project/alsa-ucm-conf (`ucm2/codecs/wcd937x`, `ucm2/codecs/qcom-lpass`, `ucm2/Qualcomm/qcm6490`).
- Context (vendor kernel, not mainline): `UBports-N100/port/bugreports/audio-no-soundcard-gfp-abi.md`.
