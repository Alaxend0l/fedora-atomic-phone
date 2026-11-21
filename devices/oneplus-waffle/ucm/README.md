<!-- SPDX-License-Identifier: BSD-3-Clause -->
# ALSA UCM for the OnePlus 12

`OnePlus/waffle/` goes to `/usr/share/alsa/ucm2/OnePlus/waffle/`, plus the
symlink `/usr/share/alsa/ucm2/conf.d/sm8650/OnePlus 12.conf` →
`../../OnePlus/waffle/waffle.conf` (card driver `sm8650`, card name = the
board DT's `model`). It includes alsa-ucm-conf's `codecs/wcd939x` and
`codecs/qcom-lpass` sequences, so Fedora's `alsa-ucm` must be installed.
`fap-waffle-build.sh netroot` installs both. Licence BSD-3-Clause, as
alsa-ucm-conf, so it can go upstream there.

Devices: Speaker (earpiece 0x34 = left, bottom loudspeaker 0x35 = right,
TFA9874 via SECONDARY_MI2S; capped at -12 dB with the DSP stream volume),
Headphones (WCD9395 HPH; not routed to the USB-C port yet), Mic1, Mic3,
Mic4, Mic5 (WCD9395 AMIC1/3/4/5, mapping to physical mics unknown; the
capture PCM is 2 channels only).
