<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Per-device data: features.yaml and firmware.yaml

Two machine-readable files in every device folder. They are the source of
truth for what works and which firmware a phone needs;
[devices.md](devices.md) (the support matrix) is generated from them by
`tools/support-matrix.py`, and CI fails if it's stale or a file is invalid.

Both start from `devices/_template/` (`tools/new-device.sh` copies them).

## features.yaml

```yaml
schema: 1
device: oneplus-billie2          # must equal the folder name
updated: 2026-11-20              # when the statuses were last reviewed
features:
  core:                          # group (fixed list, fixed order)
    ram-boot:                    # feature id (fixed list, fixed order)
      status: works
      notes: "one line: limits, workarounds, what's missing"
      evidence: boot/android-bootimg/README.md
```

### Fields
| Field | Required | Meaning |
|---|---|---|
| `status` | yes | one of the statuses below |
| `notes` | no | one line; say what's missing or how it's worked around |
| `evidence` | no | where it was shown: a repo path (must exist), a URL, or a commit hash. **Quote hashes** that are all digits (YAML would read a number) |

### Statuses
| Status | Use when |
|---|---|
| `works` | the feature does its job for a user; small gaps go in `notes` |
| `partial` | works with a noticeable limit or a workaround (e.g. GPU with UBWC off, Wi‑Fi that needs retries) |
| `broken` | doesn't work yet: driver/DT missing, or tried and failed |
| `untested` | might work, nobody has checked |
| `n-a` | the phone doesn't have the hardware |

Rule of thumb: never `works` without evidence; a regression is `broken`
with a note saying since when.

### The catalogue
`devices/_template/features.yaml` defines the groups, the feature ids, their
order and their `title` (device files leave titles out). Every device file
must list exactly those groups and ids in the same order;
`support-matrix.py` rejects missing or unknown ones. To add a feature, add
it to the template, then to every device (as `untested` if nobody knows).

Groups and features (46): **core** ram-boot, boot-storage, usb-gadget,
cpufreq, thermal, suspend, reboot-bootloader, crash-logs · **display**
display, backlight, gpu, video-codec · **input** keys, touchscreen ·
**connectivity** wifi, bluetooth, usb-host, tethering, nfc · **audio**
speaker, earpiece, headphones, microphone · **power** battery, charging,
fast-charging · **sensors** vibrator, accelerometer, proximity,
light-sensor, compass, fingerprint, microsd, notification-led · **cameras**
camera-rear, camera-front, camera-flash · **telephony** modem, sim, sms,
mobile-data, calls, gnss · **software** desktop, waydroid, bootc-updates.

### Relation to TODO.md
`TODO.md` stays the prioritised work list (P1/P2/P3, plans, links).
`features.yaml` is the current state, one status per feature. When you
tick something in TODO.md, update features.yaml and regenerate:
```sh
tools/support-matrix.py          # needs PyYAML; on a Mac: uv run --with pyyaml tools/support-matrix.py
```
The future `fap-hwtest` suite (roadmap.md, porting tooling #7) is meant to
write these statuses from on-device checks.

## firmware.yaml

Every blob the phone needs, where it comes from, where it goes. Pointed to
by `FIRMWARE_MANIFEST` in device.env. Vendor blobs are never committed or
redistributed (LICENSING.md): this file is the plan for extracting them on
the phone itself.

```yaml
schema: 1
device: oneplus-billie2
firmware:
  - name: gpu-zap-shader
    files: ["a610_zap.mdt", "a610_zap.b00"]          # globs allowed
    source: {partition: "super (vendor_a)", path: firmware/}   # on the phone
    install: /usr/lib/firmware/qcom/sm6115/OnePlus/billie2/
    consumer: gpu_zap_shader (msm/adreno)             # DT node / driver
    redistributable: false
    package: ""                                       # distro package, if redistributable
    status: in-use                                    # in-use | planned | unused
    notes: "OnePlus-signed"
```

All keys are required (use `""` when not applicable). `redistributable` is
a boolean; a non-redistributable blob can't name a `package`. `source` with
an empty partition means it isn't on a partition (say where in `path`, e.g.
"vendor kernel source"). Example: devices/oneplus-billie2/firmware.yaml.
