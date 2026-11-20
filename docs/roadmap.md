# Roadmap

## Framework
- [x] Scaffold: layered Containerfile, device folder format, validation
- [x] Build environment: podman machine (libkrun, arm64, 6 CPU, 2 GiB) on the Mac
- [ ] Get `just build` green for
      `oneplus-billie2` + `tty`
- [ ] `just disk` produces esp.img + rootfs.img
- [ ] CI: build images on push (manual trigger for now)
- [ ] Firmware extraction at first boot (modeled on droid-juicer)
- [ ] Publish images to a registry; `bootc upgrade` from a phone

## OnePlus Nord N100 (`oneplus-billie2`)
Each step is reversible via fastboot or EDL.
1. [x] Check Fedora's kernel config for SM6115 drivers: all present in 7.3.4 (fc45), incl. the billie2 DTB (kernels/qcom-sm6115)
2. [x] Build U-Boot (`just uboot`, boot/uboot-android/): uboot.img built 2026-11-20
2b. [ ] `fastboot boot uboot.img` (RAM only) shows U-Boot on screen
3. [ ] Decide the ESP partition; extract `vendor` firmware first if it's `super`
4. [ ] First flash: Fedora tty image boots to the framebuffer console
5. [ ] SSH over USB; pstore collects crash logs
6. [ ] Phosh on the simple framebuffer (no GPU acceleration yet)
7. [ ] Touch (Ilitek SPI)
8. [ ] Wi‑Fi
9. [ ] Charging / battery reporting (PMI632, SMB1355)
10. [ ] Proper display driver (ILI9882N panel), GPU (Adreno 610)
11. [ ] Audio (WCD937x), modem, sensors
