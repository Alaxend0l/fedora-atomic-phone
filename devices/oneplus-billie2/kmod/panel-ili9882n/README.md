# panel-ili9882n

DRM panel driver for the OnePlus Nord N100's ILI9882N (720x1600, DSI video,
4 lanes). Generated with
[linux-mdss-dsi-panel-driver-generator](https://github.com/msm8916-mainline/linux-mdss-dsi-panel-driver-generator)
(`--dumb-dcs`, because the ILI page-switched init writes reuse DCS opcodes)
from the vendor DT node `qcom,mdss_dsi_ili9882n_90hz_video`, then edited:
compatible `oneplus,billie2-ili9882n`, backlight starts at 345 of 2047.

No regulator handling: the LCDB rails have no mainline driver and the
bootloader leaves them on. The 90 Hz mode isn't exposed yet (vendor timings
are the 60 Hz mode with a long VFP).

Build: `tools/build-kmod.sh devices/oneplus-billie2/kmod/panel-ili9882n <kver> <outdir>`.
Tested 2026-11-20 on the N100 (Fedora 45 kernel 7.3.4): panel probes, MSM DRM
drives it, backlight works.

Goal: upstream as a mainline panel driver (and drop this directory).
