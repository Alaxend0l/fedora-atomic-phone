<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# OnePlus 12: telephony and GNSS (bring-up notes, 2026-11-20)

Status: **built, not yet tested on the phone**. The build output's TEL.md
(fap-build/waffle/tel/) is this file plus the image checksums.

> **Do not rely on this phone for emergency calls.** Call audio doesn't work
> (below), VoLTE/IMS isn't supported, and in LTE/5G-only networks (all of the
> US) a voice call can't even be placed without IMS. Never use an emergency
> number as a test.

## What changed (branch oneplus12-tel)
| Piece | Where |
|---|---|
| The modem starts at boot: `fap-efs-ram` (EFS RAM copies to /run/fap-efs) → `fap-tqftpserv` → `fap-rmtfs` (`rmtfs -r -o /run/fap-efs -s`: read-only, starts the modem) → ModemManager (drop-in `After=fap-rmtfs`). QRTR/pd-mapper/ipa/rmnet modules via modules-load.d. All units are skipped on a root without `/usr/lib/fap-efs` | netroot/usr/lib/systemd/system/, netroot/etc/modules-load.d/fap-waffle.conf |
| `fap-modem-ram` now just restarts those units and waits for `running` | netroot/usr/libexec/fap-modem-ram |
| Packages: ModemManager (1.24.2, QRTR on by default), libqmi-utils (qmicli), NetworkManager-wwan, mobile-broadband-provider-info, spacebar, plasma-dialer, callaudiod, geoclue2, geoclue2-demos | build-env/fap-waffle-build.sh `NETROOT_PKGS_TEL`; libqmi-utils also in packages |
| `FAP_WAFFLE_VOLUME` picks the podman build volume (parallel work) | build-env/fap-waffle-build.sh |

No kernel or DT changes: the v7 kernel already has `QCOM_IPA=m`, `RMNET=m`,
`QRTR(_SMD)=m`, `QCOM_PD_MAPPER=m`; DaDDevil's board DT already enables
`&ipa` (`qcom,sm8650-ipa` → driver's `qcom,sm8550-ipa`, IPA v5.5,
`qcom,gsi-loader = "self"`, `ipa_fw_mem`), and our DT points it at the unit's
`ipa_fws.mdt` (in the netroot from modem_a).

## Safety rules for testing
- EFS stays RAM-only: `rmtfs -r` on copies. Fedora's `rmtfs.service` stays
  masked. Never write modemst1/2, fsg, fsc, persist; never change the IMEI or
  modem NV.
- Off limits: `qmicli --dms-set-*`, `--dms-activate-*`, `--pdc-*` (MCFG
  load/activate), `--nas-set-*`, `--uim-change-pin`/`--uim-*-pin` beyond one
  correct PIN entry (3 wrong = PUK), `mmcli --factory-reset`, any DIAG/QPST tool.
- `qmicli --dms-get-ids`, `mmcli -m 0` (equipment id), `mmcli -i 0` (ICCID,
  IMSI), the phone number: never paste into git, logs, or issues; redact.
- lpac: read-only commands only (below).
- No emergency numbers. Cellular tests with a SIM the user owns.

## Test commands (as root over `tools/fap-dev ssh`), expected results
Boot: `fap-build/waffle/tel/README` (same procedure as plasma-netroot-gpu).

### 1. Modem at boot (no SIM needed)
```sh
systemctl status fap-efs-ram fap-tqftpserv fap-rmtfs --no-pager
for r in /sys/class/remoteproc/*; do echo "$r $(cat $r/firmware) $(cat $r/state)"; done
qrtr-lookup | head -40
```
Expect: three units active, modem remoteproc `running` without running
fap-modem-ram, QRTR services incl. 1 WDS, 2 DMS, 3 NAS, 5 WMS, 9 VOICE,
11 UIM, 16 LOC on the modem node.
Stop if: the modem goes `crashed`/restarts in a loop (`dmesg | grep -i
remoteproc`), or rmtfs logs a write to a partition (it can't: `-o
/run/fap-efs`; anything else means stop).

### 2. QMI read-only (no SIM needed)
```sh
qmicli -d qrtr://0 --dms-get-revision
qmicli -d qrtr://0 --dms-get-operating-mode
qmicli -d qrtr://0 --uim-get-card-status
qmicli -d qrtr://0 --nas-get-system-selection-preference
```
(Node 0 is the modem's QRTR node on SM8650; if not, take the node id from
`qrtr-lookup`.) Expect: firmware revision, `online`/`low-power`, card status
listing slot(s): `present` (physical SIM or eUICC) or `absent`.

### 3. ModemManager (detection without SIM, status with SIM)
```sh
systemctl status ModemManager --no-pager
mmcli -L
mmcli -m 0
journalctl -b -u ModemManager | grep -iE 'qrtr|qcom-soc|ipa|error' | head -40
```
Expect: `/org/freedesktop/ModemManager1/Modem/0 [QUALCOMM INCORPORATED]
...`, plugin `qcom-soc`, primary port `qrtr0`, ports include `rmnet_ipa0
(net)` if IPA is up. Without a SIM: state `failed`, reason `sim-missing`
(or `esim-without-profiles` if only an empty eUICC is visible); SMS, voice
and location then aren't exported (MM's normal behaviour).
Stop if: `mmcli -L` lists nothing after 60 s → check `journalctl -u
ModemManager` for the QRTR node and `qrtr-lookup`; that's a finding, not a
reason to try write commands.

### 4. SIM / eSIM
```sh
mmcli -m 0 | grep -iA4 sim
mmcli -i 0            # ICCID/IMSI: don't paste
```
eSIM: the unit has an eUICC behind a SIM2/eSIM switch. OnePlus's kernel
drives it (`oplus,oplus-gpio`: esim-en = PM8550VS_G GPIO6, esim-det =
PM8550 GPIO11, sim2-det = PM8550VS_C GPIO5; vendor DT
`waffle-22825-pineapple-overlay.dts`, 22877 not checked). Our kernel
doesn't touch these pins, so whether the modem sees the eUICC depends on
what the bootloader leaves. **Don't toggle these GPIOs** (gpioset etc.)
without a reviewed plan.
lpac (eSIM profile tool) is **not packaged in Fedora** and not in this
image. Next step: build it from source (github.com/estkme-group/lpac,
pinned tag, `-DLPAC_WITH_APDU_QMI_QRTR=ON`; deps libcurl, libqmi-glib,
libqrtr-glib). Read-only use only:
```sh
LPAC_APDU=qmi_qrtr lpac chip info       # EID, eUICC info
LPAC_APDU=qmi_qrtr lpac profile list    # installed profiles, which is enabled
```
Never: `profile enable/disable/delete/download`, `notification process/
remove`, `chip purge`, `chip defaultsmdp`. An enable/disable switch changes
which SIM the modem uses and sends notifications to the operator.

### 5. Mobile data (needs a SIM with data)
```sh
lsmod | grep -E '^(ipa|rmnet)'; dmesg | grep -i ipa | head -30
ip -br link | grep -E 'rmnet|qmap'
nmcli device                      # the modem appears with type gsm
nmcli connection add type gsm ifname '*' con-name mobile apn <APN>
nmcli connection up mobile
ip -br addr; ping -c3 -I <rmnet/qmap if> 9.9.9.9
```
Or in Plasma: Settings → Cellular network (APN from
mobile-broadband-provider-info), quick-settings Mobile data toggle.
Expect: `ipa ... IPA v5.5 ... firmware loaded` and `rmnet_ipa0` after the
modem is running; NM brings up a bearer on an rmnet link with an IP.
Stop if: IPA probe faults crash the modem in a loop or the AP resets
(RAM boot: nothing lost; note it, don't retry blindly). Without IPA, MM can
still do SMS/calls; data is the only casualty.

### 6. SMS (needs a SIM)
Spacebar (app list), or:
```sh
mmcli -m 0 --messaging-status
mmcli -m 0 --messaging-list-sms
mmcli -m 0 --messaging-create-sms="text='fap test',number='<own number>'"
mmcli -s <N> --send
```
Expect: received SMS show in Spacebar/`list-sms`; sending to one's own
number round-trips. SMS over IMS (LTE-only networks) won't work: no IMS.

### 7. Calls: signalling only (needs a SIM and a 2G/3G network or IMS)
plasma-dialer, or:
```sh
mmcli -m 0 --voice-list-calls
mmcli -m 0 --voice-create-call="number=<own voicemail/second phone>"
mmcli -o <N> --start ; mmcli -o <N> --hangup
```
Only with the user's agreement, never emergency numbers. Expect: the call
rings the other phone (no audio either way). In the US (no 2G/3G) the call
fails without IMS: expected, not a bug in our setup.

### 8. GPS (MM path needs a SIM; qmicli path doesn't)
```sh
mmcli -m 0 --location-status
mmcli -m 0 --location-enable-gps-nmea --location-enable-gps-raw
mmcli -m 0 --location-get          # outdoors, cold start: minutes
# without a SIM (MM modem 'failed'): QMI LOC directly
qmicli -d qrtr://0 --loc-start --loc-follow-nmea     # Ctrl-C, then:
qmicli -d qrtr://0 --loc-stop
```
GeoClue (as user phone, in the Plasma session):
```sh
/usr/libexec/geoclue-2.0/demos/agent &
/usr/libexec/geoclue-2.0/demos/where-am-i -a 8 -t 300
```
Expect: NMEA sentences, a fix outdoors after a cold start (no XTRA/A-GPS
yet); where-am-i prints latitude/longitude from the `modem-gps` source
(enabled in Fedora's geoclue.conf). Location data is personal: don't
commit it.
Stop if: `--loc-start` errors repeatedly with the modem crashing (memshare
has no mainline service; note the dmesg/remoteproc lines).

## Calls: audio and VoLTE (not done)
- **Call audio**: DaDDevil's tree carries hostless AudioReach voice graph
  support (`sound/soc/qcom/qdsp6/q6apm-vcpm-cal.c`, VCPM roles in
  `audioreach.c`; from the giulia/oboev work). Missing for waffle:
  1. a topology with the voice sub-graphs (MAILBOX_TX/RX, vocoder
     placeholders); Fedora's generic SM8650 topology has none; the giulia
     project builds its own;
  2. VCPM calibration tables built from **this** handset's ACDB
     (vendor/etc/acdbdata in our vendor copy); the kernel pins
     `qcom/sm8650/oneplus/giulia/vcpm-cal-400{c,d}.bin` by name and
     SHA-256, so waffle needs its own table entries (kernel patch);
  3. an output: the earpiece and speakers are TFA9874 amps without a
     driver (audio work, oneplus12-hw), and the USB-C analog headset path
     (wcd939x-usbss, i2c3) is still off. Only a wired headset or
     Bluetooth HFP would be left;
  4. UCM `Voice Call` verb + callaudiod switching it.
  Order: speaker/earpiece amp → voice topology + waffle VCPM tables → UCM
  verb → test with callaudiod/plasma-dialer.
- **VoLTE/IMS: unsupported.** The modem's IMS stack would need the right
  MCFG profile selected (QMI PDC) plus IMS settings (QMI IMSA/IMSS); that's
  persistent modem configuration, which we don't touch. Calls therefore
  need a 2G/3G network; SMS over IMS doesn't work either.

## Next steps
1. Test 1–8 above on the phone; record in features.yaml.
2. lpac from source (read-only eSIM listing).
3. XTRA/A-GPS (`mmcli --location-inject-assistance-data`) for faster fixes.
4. Call audio as listed; VoLTE stays research.
5. Real install: decide the EFS policy (RAM copies vs. writable rmtfs on
   the real partitions) with the user before anything else.
