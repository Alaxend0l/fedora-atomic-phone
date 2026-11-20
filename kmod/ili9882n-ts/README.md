# ili9882n-ts

SPI touchscreen driver for the Ilitek ILI9882N TDDI (touch side), written from
the protocol in the OnePlus Nord N100 GPL kernel
(`drivers/input/touchscreen/oneplus_touchscreen/ilitek/ilitek9882n`,
Ilitek driver 3.0.2.0). Minimal: firmware host-download + multitouch.

Tested 2026-11-20 on the N100 (kernel 7.3.4): firmware 0x842d0c00 uploads,
CRCs verified by the chip's DMA engine, 10-finger MT protocol B, raw range
0..2047 on both axes; cold boot works.

## Things that matter (learned the hard way)
- **No flash**: the firmware lives in IRAM and must be uploaded after every
  power-on of the panel.
- **Ordering**: upload *after* the panel is initialised and its DSI video
  stream is running, and *without* pulsing the touch reset pin (the panel's
  reset already reset the chip). Otherwise the firmware runs (it answers the
  version command) but never reports touches; INT pulses every ~4.5 s and
  reads return ACK 0xff. Hence the driver is a DRM panel follower (`panel`
  phandle in DT) and uploads 200 ms after `panel_prepared()`.
- After leaving ICE mode, a 9×0xa3 dummy write wakes the SPI PLL before the
  first command.
- Reads outside ICE mode: one full-duplex transfer, `0x83` + 2 extra bytes,
  byte 1 must be ACK `0xa3`.

## Firmware
An "ILI" image: 256-byte header + payload (block map at [129..131], block
ranges at 132+6i, fixed IRAM addresses at 4+4i). The N100's TXD panel uses
the vendor kernel's `FW_20221_ILI9882N_TXD[]` array from
`drivers/input/touchscreen/touch.h` (127744 bytes). Install it as
`/usr/lib/firmware/ilitek/oneplus-billie2-ili9882n-txd.bin`. Not
redistributable by us: extract it, never commit it. (The phone's
`/vendor/firmware/tp/20221/FW_NF_ILI9881H_TXD.bin` is the same firmware in
Ilitek's extended Intel HEX; a hex→ILI converter is still TODO.)

Module parameter `hw_reset` (default 1) applies only without a panel link.

Build: `tools/build-kmod.sh kmod/ili9882n-ts <kver> <outdir>`.
Upstreaming: needs a DT binding (`ilitek,ili9882n-ts`), removal of the
version-query debug print, and probably runtime PM.
