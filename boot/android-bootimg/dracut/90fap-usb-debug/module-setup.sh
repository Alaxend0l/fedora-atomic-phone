#!/bin/bash
# dracut module: USB serial debug shell in the initramfs.
#
# Sets up a USB CDC-ACM gadget as soon as a USB device controller appears and
# runs a root shell on it, so a host can reach a booting phone with no display,
# no input and no root filesystem (macOS: /dev/cu.usbmodem*, Linux:
# /dev/ttyACM*). For development images only: it's an unauthenticated root
# shell on the USB port.

check() {
    # Only when asked for explicitly (dracut --add fap-usb-debug).
    return 255
}

depends() {
    return 0
}

installkernel() {
    hostonly='' instmods libcomposite usb_f_acm u_serial configfs
}

install() {
    inst_multiple mkdir ln ls cat head sleep setsid sh dmesg mount mountpoint modprobe
    inst_hook pre-udev 90 "$moddir/fap-usb-debug.sh"
}
