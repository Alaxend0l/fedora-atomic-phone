<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# N100: telephony, Bluetooth, GNSS (and the Wi‑Fi/BT MAC question)

Research notes, 2026-11-20. Nothing here has been run on the phone. Marks:
**[fact]** read from a cited file/source, **[guess]** inferred, to be verified
by the test plan. Mainline = Linux v7.3 (Fedora 45 kernel 7.3.4).

Abbreviations: VS = vendor DT dump
`UBports-N100/log/hw-inventory/20261120-134342/device-tree.dts`, RAW = the
`raw/` folder next to it, ML = `fap-build/linux` (v7.3 sparse checkout).

## 1. Inventory

| Block | What the N100 has | Evidence |
|---|---|---|
| Modem | MPSS on SM4250, firmware in `modem_a` (`image/modem.*`, `modem_pr/`), EFS in `modemst1/2`, `fsg`, `fsc` | RAW/firmware.txt, partitions.txt; already boots on mainline (docs/status.md) |
| SIM | BE2015 is single-SIM: `persist.radio.multisim.config=ssss` (vendor default prop says `dsds` for other SKUs) | RAW/android-props.txt, vendor-build.prop [fact] |
| Data path | IPA **v4.2**: VS `qcom,ipa@0x5800000` has `qcom,ipa-hw-ver = <0x10>`; 0x10 = 16 = `IPA_HW_v4_2` in the OnePlus kernel's `include/uapi/linux/msm_ipa.h` | VS l.5927, OnePlusOSS SM4250_R_11.0 [fact] |
| IPA firmware | `ipa_fws.{mdt,b00-b04,elf}` and an identical-size `scuba_ipa_fws.*` (scuba = QCM2290) in **/vendor/firmware**, i.e. inside `super`, not in `modem_a` | RAW/firmware.txt [fact] |
| Stock data | `rmnet_ipa0` + `rmnet_data0..10` (rmnet over IPA), QMI via `qcrild` | RAW/net.txt, android-props [fact] |
| IMS/VoLTE | stock runs `imsqmidaemon`, `imsdatadaemon`, `ims_rtp_daemon` (userspace IMS + modem IMS) | android-props [fact] |
| Wi‑Fi + BT chip | Qualcomm "cherokee" family (`vendor.qcom.bluetooth.soc=cherokee`). BT firmware version `BTFM.CHE.2.1.5-00254-QCACHROMZ-1`. linux-firmware: `apbtfw11.tlv` (= WCN3988 ROM 1.1) is `BTFM.CHE.2.1.5.c5`, `crbtfw21.tlv` (WCN3990) is `BTFM.CHE.2.1.3`. So **WCN3988** (as on the bengal reference QRB4210 RB2) | android-props, vendor-build.prop, linux-firmware WHENCE [fact]; chip = **[guess, strong]** |
| BT transport | HS-UART **QUP0 SE3 @ 0x4a8c000** (`qcom,msm-geni-serial-hs`, `qcom,wakeup-byte = 0xfd`), pins gpio8 CTS, gpio9 RTS, gpio10 TX, gpio11 RX, wake IRQ on TLMM gpio11 | VS l.9909ff, l.11008 [fact] |
| BT power | VS `bt_wcn3990`: `qca,bt-vdd-io` = **L9A** (1.7–1.9 V), `-core` = **L17A** (1.304 V), `-pa` = **L23A** (3.0–3.3 V), `-xtal` = **L16A** (1.7–1.9 V). No reset/enable GPIO, no sw-ctrl GPIO ("bt-reset-gpio not provided" in dmesg) | VS l.698, RAW/dmesg.txt [fact] |
| Wi‑Fi power | icnss: cx-mx L8A, xo L16A, rfa L17A, ch0 L23A (already in our DT) | VS l.5566 [fact] |
| BT audio | SCO via SLIMbus (`btfmslim_slave` under `slim@a5c0000`), stock A2DP offload to ADSP | VS l.669, vendor-build.prop [fact] |
| BT firmware on phone | `bluetooth_a` (sde5) mounted at `/vendor/bt_firmware`; its `image/` was unreadable to the inventory (mode 0550, uid 1002) so file names are unknown | RAW/firmware.txt [fact] |
| GNSS | inside the modem (QMI LOC), stock `loc_launcher`, `gnss_service`. memshare client "GPS" has size 0 (no boot-time buffer); DIAG client gets 5 MB on request | VS l.629, RAW/dmesg l.534 [fact] |
| Wi‑Fi MAC | `/vendor/firmware/wlan/qca_cld/wlan_mac.bin` -> `/mnt/vendor/persist/wlan_mac.bin`, truncated every boot by `init.oem.rc`, filled (sometimes) by OnePlus's `oneplus_wifi_service`. persist has `wlan_mac.bin` and `WCNSS_qcom_cfg.ini`, **no** `bluetooth/.bt_nv.bin` | log/2026-11-20-wifi-diagnosis.md; file names grepped in the local persist backup (no values read) [fact] |

## 2. Mainline and userspace status

### 2.1 Control plane (SIM, SMS, calls, signalling): ready in principle
- QRTR, rmtfs (RAM copies, `-r`), tqftpserv, in-kernel pd-mapper: working
  (`boot/android-bootimg/netroot/rootfs/usr/libexec/fap-modem-ram`).
- ModemManager talks QMI directly over QRTR (libqmi QRTR backend since 1.26,
  MM QRTR modem support since 1.18). MM's `qcom-soc` plugin pairs QRTR
  control with the `ipa` net driver. Without IPA, MM should still create the
  modem for SIM/SMS/voice signalling; **[guess]** whether MM exports a modem
  with no net port on QRTR at all (it did on msm8916 bam-dmux only after the
  net port appeared). Test 6 answers this; `qmicli -d qrtr://0` works either way.
- SIM detect: owned by the modem's UIM driver (no AP GPIO in VS) **[guess]**;
  visible as QMI UIM card status / MM `sim` object.
- Netroot today has `qrtr-lookup`/`qrtr-cfg` but **no** `ModemManager`,
  `libqmi-utils` (`qmicli`), `rmnet.ko`. Add `ModemManager libqmi-utils`
  to the netroot Containerfile; check `rmnet` is in `kernel-modules(-extra)`.

### 2.2 Mobile data (IPA): driver ready, SoC DT missing
- Mainline `drivers/net/ipa` supports v3.1, 3.5.1, **4.2**, 4.5, 4.7, 4.9,
  4.11, 5.0, 5.2, 5.5 (`drivers/net/ipa/data/`). Fedora builds `ipa.ko`
  (present in our netroot).
- **SM6115 has no IPA node** in ML `sm6115.dtsi`. But QCM2290/Agatti (same
  IPA v4.2, same "scuba" firmware family) got one: binding
  `qcom,qcm2290-ipa` + fallback `qcom,sc7180-ipa` (net-next 4320f1f111c5) and
  `agatti.dtsi` `ipa@5840000` (9c633eec3778, Bjorn, 2026-05-13), by Wojciech
  Slenska; no board enables it in v7.3. Agatti's addresses equal the N100's
  vendor values: IPA regs 0x5840000 (= vendor ipa-base 0x5800000 + v4.x
  0x40000 offset), GSI 0x5804000, SPI 257/259, SMMU SID 0x140, smp2p entry
  "ipa" on the modem edge. A `qcom,sm6115-ipa` compatible would need a
  one-line binding patch (upstreamable).
- Data then flows rmnet (QMAP) over `rmnet_ipa0`; MM creates rmnet links via
  netlink. `qmi_wwan` is irrelevant here (that is for USB modems).
- AP must load `ipa_fws` (stock: PIL on the AP), so `qcom,gsi-loader =
  "self"` + `memory-region = <&pil_ipa_fw_mem>` (sm6115.dtsi already has
  `pil_ipa_fw_mem` @0x56100000 and `pil_ipa_gsi_mem`). Firmware must be
  extracted from `super`/vendor (see re-tooling fw-manifest).

### 2.3 Call audio: not available yet
- Mainline qdsp6 has q6afe/q6asm/q6adm/q6routing/AudioReach, **no q6voice**
  (`sound/soc/qcom/qdsp6/` in v7.3). Voice call audio on close-to-mainline
  phones uses the out-of-tree q6voice series (q6mvm/q6cvs/q6cvp + a voice
  DAI; msm8916-mainline, sdm845/sdm670 trees) plus the `q6voiced` daemon that
  opens the voice PCM when a call starts. A 2026 postmarketOS "q6voice
  project" aims to upstream it (not verified, site not fetched).
- Prerequisite: N100 ADSP audio itself (q6afe + rouleur/WCD937x codec +
  LPASS pinctrl), which doesn't work yet (see fap-build/research/audio).
  Order: audio playback -> q6voice port to SM6115 -> MM call -> q6voiced.
- Calls without VoLTE need 2G/3G. Metro/T-Mobile US has no 2G/3G voice left;
  in most of the EU 2G still exists **[guess, location-dependent]**. VoLTE on
  mainline means the modem's own IMS stack selected through MCFG
  (`modem_pr/mcfg`), driven by QMI PDC/IMSA; works for some carriers on
  sdm845 ports **[guess]**. Treat VoLTE as a research project.

### 2.4 Bluetooth: everything is in mainline
- `hci_uart` + `btqca` modules and `qca/apbtfw1x.tlv`, `apnv1x.bin`,
  `crbtfw21.tlv` etc. are in our netroot (Fedora linux-firmware) [fact].
- `hci_qca` (v7.3) matches `qcom,wcn3988-bt`, `qcom,wcn3990-bt`,
  `qcom,wcn3950-bt` ... For WCN39xx without `enable-gpios` it tries a pwrseq
  provider and, if none, **drives the regulators itself** (legacy path) — fits
  the N100, which has no BT_EN GPIO. Supplies `vddio vddxo vddrf vddch0`.
- Firmware names (btqca.c): WCN3988 -> `qca/apbtfw%02x.tlv` + `qca/apnv%02x.bin`
  (rom_ver from soc_ver); WCN3990 -> `crbtfw/crnv`. DT `firmware-name =
  "<nvm>", "<rampatch>"` can point at the phone's own files instead.
- The BT controller runs its own firmware from the host over UART: **BT does
  not need the modem** (unlike Wi‑Fi). Shared rails L16/L17/L23 with Wi‑Fi.
- SCO/HFP audio: stock routes over SLIMbus (no mainline btfm driver). HFP
  over HCI may or may not be configurable on this firmware **[guess]**;
  A2DP works over HCI with software SBC/AAC in PipeWire.
- Reference board: ML `qrb4210-rb2.dts` (`&uart3` + `wcn3988-pmu` with the
  same L9A/L16A/L17A/L23A, `max-speed = <3200000>`, alias `serial1 = &uart3`,
  `uart3_default`/`uart3_sleep` pinctrl in the board file).

### 2.5 GNSS
- No Qualcomm GNSS driver in mainline (`drivers/gnss/`: mtk, serial, sirf,
  ubx, usb only). The GNSS engine is in the modem behind QMI LOC.
- Path 1 (recommended): ModemManager location over QMI LOC
  (`mmcli -m 0 --location-enable-gps-nmea --location-enable-gps-raw`), A-GPS
  via `--location-inject-assistance-data` (XTRA), and geoclue2's
  `[modem-gps]` source (Fedora geoclue2 is built with MM support **[guess]**).
- Path 2: `gnss-share` (postmarketOS, QMI LOC -> NMEA socket, used on
  sdm845) **[guess, not checked]**.
- Possible blocker: stock has a memshare QMI service (`qcom,memshare`);
  mainline has none (an RFC was never merged **[guess]**). The GPS client is
  size 0 and DIAG is on request, so GNSS likely works without it; if the
  modem logs memshare QMI requests that go unanswered, that's the reason.

## 3. The MAC address question (Wi‑Fi and BT)

What we know:
1. Ubuntu Touch (qcacld) wanted `wlan_mac.bin` from persist; OnePlus
   `init.oem.rc` empties it each boot and `oneplus_wifi_service` refills it
   only sometimes. Otherwise qcacld uses a default MAC whose first two bytes
   change per boot (c4:c6, 98:9a, cc:ce, d0:d0 + `12:7f:03:00`) and is
   sometimes multicast, which made Wi‑Fi fail (wifi-diagnosis log).
2. That bug **does not carry over to mainline**: ath10k_snoc doesn't read
   `wlan_mac.bin`. `ath10k_core` calls `device_get_mac_address()` (DT
   `local-mac-address`/`mac-address`) and otherwise takes what the firmware
   reports. Our mainline run noted "MAC random" (docs/status.md).
3. persist has no BT address file; stock BT HAL most likely reads the BD
   address from modem NV (NV 447 BD_ADDR) and Wi‑Fi from NV 4678 or from
   OnePlus's service **[guess]**. The factory MACs may also live in OnePlus's
   `param`/`reserve*` partitions **[guess]**. Values are identity data: never
   commit them, never write them back.

How to read the factory values safely (read-only QMI):
- `qmicli -d qrtr://0 --dms-get-mac-address=wlan` and `=bt` (QMI DMS 0x005C
  "Get MAC Address"; confirm the option exists with `qmicli --help-dms`).
  Pure read; DMS has no write for it.

How to provide MACs without touching identity partitions:
- **Wi‑Fi**: preferred: patch `local-mac-address` into the DTB at boot (our
  `make-ramboot.sh`/U-Boot `fdt set`), value from a file in `/etc` or a
  derived address. Simplest now: a systemd `.link` file / NetworkManager
  `wifi.cloned-mac-address=stable` (no kernel involvement). DT placeholder:
  `&wifi { local-mac-address = [00 00 00 00 00 00]; };` (ath10k ignores an
  all-zero address, so the placeholder is harmless until filled).
- **BT**: hci_qca sets `HCI_QUIRK_USE_BDADDR_PROPERTY` when the controller
  reports the NVM's default address. Then BlueZ wants `local-bd-address` in
  DT (filled by the bootloader) or marks the controller *unconfigured*; set
  it at boot with `btmgmt public-addr <addr>` (sends the vendor
  `EDL_WRITE_BD_ADDR` command: controller RAM only, gone on power-off).
  pmOS's `bootmac` tool does both Wi‑Fi and BT this way.
- Derived address (if no factory value is found): locally administered
  unicast (first octet `x2/x6/xA/xE`), from a hash of
  `/sys/devices/soc0/serial_number` or `/etc/machine-id`. Using the factory
  value is fine too as long as it is only *read*.

## 4. Untested DT snippets (for `devices/oneplus-billie2/dts/…-fap.dts`)

Bluetooth (modelled on qrb4210-rb2, without PMU since VS has no sw-ctrl):
```dts
/ { aliases { serial1 = &uart3; }; };

&tlmm {
	uart3_default: uart3-default-state {
		cts-pins { pins = "gpio8";  function = "qup3"; drive-strength = <2>; bias-bus-hold; };
		rts-pins { pins = "gpio9";  function = "qup3"; drive-strength = <2>; bias-disable; };
		tx-pins  { pins = "gpio10"; function = "qup3"; drive-strength = <2>; bias-disable; };
		rx-pins  { pins = "gpio11"; function = "qup3"; drive-strength = <2>; bias-pull-up; };
	};
	/* uart3_sleep: copy from qrb4210-rb2.dts (gpio function, same biases) */
};

&uart3 {
	interrupts-extended = <&intc GIC_SPI 330 IRQ_TYPE_LEVEL_HIGH>,
			      <&tlmm 11 IRQ_TYPE_EDGE_FALLING>;
	pinctrl-0 = <&uart3_default>;
	pinctrl-names = "default";
	status = "okay";

	bluetooth {
		compatible = "qcom,wcn3988-bt";	/* fall back to wcn3990-bt if the SoC id says so */
		vddio-supply = <&vreg_l9a>;
		vddxo-supply = <&vreg_l16a>;
		vddrf-supply = <&vreg_l17a>;
		vddch0-supply = <&vreg_l23a>;
		max-speed = <3200000>;
		/* local-bd-address = [00 00 00 00 00 00];  filled at boot */
	};
};
```
Labels checked: ML `sm4250-oneplus-billie2.dts` defines `vreg_l9a`
(1.8–2.0 V), `vreg_l16a` (1.704–1.904 V), `vreg_l17a` (1.152–1.304 V),
`vreg_l23a` (3.296–3.304 V): compatible with the VS levels. `&gpi_dma0` may
be needed for the GENI UART.

IPA (SoC-level; copy of agatti, sm6115 interconnect IDs; would go upstream
in `sm6115.dtsi`):
```dts
&{/smp2p-mpss} {
	ipa_smp2p_out: ipa-ap-to-modem {
		qcom,entry-name = "ipa";
		#qcom,smem-state-cells = <1>;
	};
	ipa_smp2p_in: ipa-modem-to-ap {
		qcom,entry-name = "ipa";
		interrupt-controller;
		#interrupt-cells = <2>;
	};
};

&soc {
	ipa: ipa@5840000 {
		compatible = "qcom,qcm2290-ipa", "qcom,sc7180-ipa"; /* upstream: add qcom,sm6115-ipa */
		iommus = <&apps_smmu 0x140 0x0>;
		reg = <0x0 0x05840000 0x0 0x7000>,
		      <0x0 0x05847000 0x0 0x2000>,
		      <0x0 0x05804000 0x0 0x2c000>;
		reg-names = "ipa-reg", "ipa-shared", "gsi";
		interrupts-extended = <&intc GIC_SPI 257 IRQ_TYPE_EDGE_RISING>,
				      <&intc GIC_SPI 259 IRQ_TYPE_LEVEL_HIGH>,
				      <&ipa_smp2p_in 0 IRQ_TYPE_EDGE_RISING>,
				      <&ipa_smp2p_in 1 IRQ_TYPE_EDGE_RISING>;
		interrupt-names = "ipa", "gsi", "ipa-clock-query", "ipa-setup-ready";
		clocks = <&rpmcc RPM_SMD_IPA_CLK>;
		clock-names = "core";
		interconnects = <&system_noc MASTER_IPA RPM_ALWAYS_TAG &bimc SLAVE_EBI_CH0 RPM_ALWAYS_TAG>,
				<&system_noc MASTER_IPA RPM_ALWAYS_TAG &system_noc SLAVE_OCIMEM RPM_ALWAYS_TAG>,
				<&bimc MASTER_AMPSS_M0 RPM_ACTIVE_TAG &config_noc SLAVE_IPA_CFG RPM_ACTIVE_TAG>;
		interconnect-names = "memory", "imem", "config";
		qcom,smem-states = <&ipa_smp2p_out 0>, <&ipa_smp2p_out 1>;
		qcom,smem-state-names = "ipa-clock-enabled-valid", "ipa-clock-enabled";
		qcom,gsi-loader = "self";
		memory-region = <&pil_ipa_fw_mem>;
		firmware-name = "qcom/sm6115/OnePlus/billie2/ipa_fws.mdt";
		status = "okay";
	};
};
```
Unknowns: whether the `smp2p-mpss` node path is addressable like that
(otherwise edit a local copy of the dtsi); the `ipa-shared` window
(agatti's value, VS doesn't list it separately); whether `SLAVE_OCIMEM` is
the right "imem" target on sm6115.

## 5. Firmware locations

| File | On the phone | linux-firmware | Note |
|---|---|---|---|
| modem.mdt/.bNN, modem_pr/ | `modem_a:/image/` | no | served at run time by fap-modem-ram |
| wlanmdsp.mbn, bdwlan.* | `modem_a:/image/` | generic ath10k | board data is the Wi‑Fi area |
| ipa_fws.mdt/.bNN | vendor (`super`) `/vendor/firmware/` | no | signed; AP loads it; extract read-only from `super` (lpunpack) |
| apbtfw11.tlv, apnv11.bin (guess) | `bluetooth_a:/image/` (names unverified) | yes (`qca/`) | prefer linux-firmware rampatch; consider phone's NVM (board RF tuning) via `firmware-name` |
| GNSS | inside modem image | — | XTRA data downloaded by MM/geoclue |

## 6. Test plan (least to most risky)

All steps on the RAM-booted netroot, one actor on the phone (the main
session, not subagents). Nothing writes any partition.
1. **Offline**: extract `ipa_fws.*` from a read-only copy of `super`
   (vendor) on the Mac; list `bluetooth_a` contents from a read-only image
   (`dd` of `bluetooth_a` -> loop mount on Linux). Record sha256 in the
   fw-manifest. No phone change.
2. **Inventory MAC behaviour on mainline**: `ip -br link` for wlan0 over 3
   boots; is it stable, is it the `xx:xx:12:7f:03:00` pattern?
3. **qrtr-lookup** after `fap-modem-ram`: list QMI services (DMS 2, NAS 3,
   WMS 5, UIM 11, LOC 16, VOICE 9, WDS 1, PDC 36...). Read-only.
4. **qmicli read-only queries** (`-d qrtr://0`): `--dms-get-ids` (prints
   IMEI: don't paste it anywhere), `--dms-get-mac-address=wlan|bt`,
   `--uim-get-card-status`, `--nas-get-signal-strength`,
   `--nas-get-serving-system`. Radio stays as the modem chose (it may already
   register; that is ordinary phone behaviour).
5. **Bluetooth DT** (snippet §4): RAM-boot, `dmesg | grep -i qca` for SoC id
   / ROM version / firmware names, `bluetoothctl show`, `scan on`. If the
   controller is unconfigured: `btmgmt public-addr` with a locally
   administered address. Pair a speaker (A2DP via PipeWire).
6. **ModemManager** (add to netroot): `mmcli -L`, `mmcli -m 0`, SIM
   unlock, `mmcli -m 0 --messaging-list-sms`, receive an SMS, then send one.
7. **GNSS**: `mmcli -m 0 --location-enable-gps-nmea`, outdoors, watch
   `--location-get`; then XTRA injection; then geoclue.
8. **IPA DT** (snippet §4) with `ipa_fws` served from `/run/fap-firmware`:
   `dmesg | grep ipa`, `rmnet_ipa0` appears, MM `--simple-connect apn=…`,
   ping over cellular. Risk: IPA bring-up faults can crash the modem
   (recoverable: reboot) or the AP (hard reset; RAM boot, so nothing lost).
9. **Voice call signalling** (no audio): `mmcli -m 0
   --voice-create-call number=<own voicemail>` then `--start`, hang up.
   Only after the user agrees; never test with emergency numbers.
10. **Call audio**: after ADSP audio works, port q6voice; out-of-tree kernel.

## 7. SAFETY

Identity data:
- IMEI, RF calibration, NV items (incl. likely MACs/BD address) live in
  modem EFS: `modemst1`, `modemst2`, `fsg` (golden copy), `fsc`. `persist`
  holds `wlan_mac.bin`, sensor/DRM data. **Never write these partitions**,
  never enable Fedora's `rmtfs.service` (it would let the modem write
  `modemst*` directly; it is masked in the netroot). Keep `rmtfs -r` with
  RAM copies until the user decides the EFS policy for real installs.
- Backups exist (UBports-N100/backup/identity-2026-11-20, SHA256SUMS,
  git-ignored). Values from them (IMEI, MAC, BD address) never go into git,
  docs, logs, or issue reports; redact `qmicli --dms-get-ids` output.
- QMI commands that change modem state persistently are off limits without
  the user: anything `--dms-set-*`, `--dms-activate-*`, `--nas-set-*` with
  persistent options, `--pdc-*` config load/activate, `--uim-*` PIN changes
  (3 wrong PINs = PUK; 10 wrong PUKs = dead SIM), any NV/EFS write, any
  QPST/DIAG tool. Even with `rmtfs -r` (writes vanish at reboot), the modem
  can behave differently within the session.
- `tools/flash.sh` already protects `modem`, `dsp`, `bluetooth`,
  `bt_firmware`; IPA firmware lives in `super` (protected by never flashing
  `super`).
- BT `btmgmt public-addr` and DT `local-*-address` only touch RAM. Do not use
  vendor tools that "program" a MAC/BD address into NV.

Radio use:
- The modem uses its real RF calibration (EFS copies), so transmission is
  within spec; still, run cellular tests with a SIM the user owns, at home,
  not near medical equipment, and not while the phone is ignoring thermals
  (thermal zones are up; watch them).
- **No emergency calls as tests** and **don't rely on this phone for
  emergency calls**: without IMS/VoLTE, calls in 4G-only networks fail
  silently (US especially).
- Wi‑Fi regulatory domain: set it (`iw reg set <CC>`); ath10k honours the
  firmware/board domain, the vendor ships `wlan_eu.bin`/`wlan_usa.bin` (Metro
  hardware with EU firmware: pick the domain of the country of use).
- The random hard resets seen on Ubuntu Touch are unexplained; a reset during
  an IPA/modem test is not evidence of damage, but log it in `log/resets.csv`.

## Sources
- VS / RAW / summary.md: `UBports-N100/log/hw-inventory/20261120-134342/`
- `UBports-N100/log/2026-11-20-wifi-diagnosis.md`, `port/wlan-mac-fix/`
- ML v7.3: `arch/arm64/boot/dts/qcom/{sm6115.dtsi,qrb4210-rb2.dts,sm4250-oneplus-billie2.dts}`,
  `include/dt-bindings/interconnect/qcom,sm6115.h`
- torvalds/linux v7.3 via gh api: `drivers/net/ipa/data/`, `agatti.dtsi`,
  `Documentation/devicetree/bindings/net/qcom,ipa.yaml`,
  `drivers/bluetooth/{hci_qca.c,btqca.c,btqca.h}`, `drivers/gnss/`,
  `sound/soc/qcom/qdsp6/`, `drivers/net/wireless/ath/ath10k/core.c`
- OnePlusOSS/android_kernel_oneplus_sm4250 @ oneplus/SM4250_R_11.0:
  `include/uapi/linux/msm_ipa.h` (enum ipa_hw_type)
- IPA on qcm2290: https://patchew.org/linux/20260310112309.79261-1-wojciech.slenska@gmail.com
  and https://lkml.iu.edu/hypermail/linux/kernel/2605.1/11522.html
- linux-firmware WHENCE (gitlab.com/kernel-firmware/linux-firmware), qca/ section
- ModemManager 1.22 / 1.18 announcements (lists.freedesktop.org
  modemmanager-devel 2023-10 and 2021-09); libqmi NEWS 1.26 (QRTR backend)
- q6voice: lore.kernel.org/linux-arm-msm (Gerhold, apq8016_sbc QDSP6
  routing, 2021); sdm670-mainline tags on gitlab.com (q6voice commits)
- Our state: `fedora-atomic-phone/docs/status.md`,
  `devices/oneplus-billie2/dts/sm4250-oneplus-billie2-fap.dts`,
  `boot/android-bootimg/netroot/` (netroot tarball contents checked)
