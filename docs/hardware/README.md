# Hardware bring-up plans (OnePlus Nord N100)

Desk research written 2026-11-20 by research agents from the vendor DT dump,
vendor dmesg, the OnePlus GPL kernel and mainline v7.3. **Nothing in these
plans was run on the phone unless docs/status.md says so.** Each has an
inventory, mainline status, untested DT snippets, a test plan from least to
most risky, and risks. Read docs/status.md first for what already works.

| Area | Plan | Headline |
|---|---|---|
| Audio | [n100-audio.md](n100-audio.md) | Same design as QRB4210-RB2 (APR, LPASS macros, WCD937x); ADSP + DT nodes + AW87xxx amp driver + UCM needed. Speaker step can damage hardware. |
| Charging / USB-C | [n100-charging-usb.md](n100-charging-usb.md) | No PMI632 charger/QGauge driver. **Never bind qcom_smbx to PMI632 (writes 4.87 V float).** OTG is DT-only. |
| GPU / video / display | [n100-gpu-video-display.md](n100-gpu-video-display.md) | Adreno 610 needs only `&gpu` + zap firmware; Venus present; LCDB driver exists out of tree; 90 Hz mode computed. |
| Cameras | [n100-cameras.md](n100-cameras.md) | OV13B10, OV8856, GC02M1B, GC02K0; CAMSS/CCI nodes missing for SM6115; two sensors need drivers. |
| Sensors / misc | [n100-sensors-misc.md](n100-sensors-misc.md) | Sensors on ADSP (SSC/libssc); vibrator and LPG are DT-only; fingerprint not feasible (TZ-owned SPI). |
| Telephony / BT / GNSS | [n100-telephony-bt-gnss.md](n100-telephony-bt-gnss.md) | IPA v4.2 node portable from agatti; ModemManager over QRTR; BT WCN3988 on UART SE3; GNSS via QMI LOC. |
| Power / install | [n100-power-and-install.md](n100-power-and-install.md) | No MPM/system sleep state in mainline; phased install plan with every partition write listed and a go/no-go list. |
