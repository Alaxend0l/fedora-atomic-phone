<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12: feature checklist

Status as of 2026-11-20. What works lives in [features.yaml](features.yaml);
this is the work list. **P1** daily use, **P2** nice to have, **P3** later.
Legend: [x] done · [~] partly / workaround · [ ] not started

## First light (RAM only, nothing written)
- [x] Read-only backup of all partitions except userdata/super (144 entries)
- [x] Stock boot layout read from the backup (README.md "Boot chain")
- [x] Kernel (waffle-voice + Fedora config + fap.config), first-light DT, initramfs, uniLoader images built
- [ ] **P1** `fastboot boot` the stock boot_a.img once (proves RAM boot on this ABL)
- [ ] **P1** `fastboot boot ramboot/waffle-uniloader-v4.img`: uniLoader log on screen, kernel log, USB gadget
- [ ] **P1** Crash logs: ramoops at 0x85000000, read from the next RAM boot
- [ ] **P1** netroot variant, `ssh root@172.16.42.1`
- [ ] P1 Ask DaDDevil to license `sm8650-oneplus-waffle.dts` (needed before we commit or upstream anything derived)
- [ ] P1 File the Fedora config request (PINCTRL_SM8650, INTERCONNECT_QCOM_SM8650, SM_DISPCC_8550, ...)
- [ ] P2 Boot without `clk_ignore_unused pd_ignore_unused regulator_ignore_unused` ([hidden-dependencies.md](hidden-dependencies.md))
- [ ] P2 USB SuperSpeed (QMP combo PHY needs TYPEC built in or a module in the initramfs)
- [ ] P2 Use ABL's `/memory` instead of the hard-coded 16 GB map (uniLoader passes only its own DTB)

## Then (dossier porting-plan.md, phases 3-5)
- [ ] P1 Panel (panel-boe-aa545, MDSS on; Iris7 left in bypass), touch (S3910)
- [ ] P1 Battery/charging via ADSP + pmic-glink (never set charger values ourselves)
- [ ] P1 Wi‑Fi (ath12k, 0x1107 board data), GPU (OnePlus-signed zap)
- [ ] P2 Audio (WCD9395 + TFA9874), haptics, alert slider
- [ ] P3 Modem, cameras, sensors (SSC)
