#!/bin/sh
# dracut pre-udev hook (see module-setup.sh). Runs in the background so it
# doesn't hold up the boot: waits for udev to load the USB controller driver,
# then exposes a CDC-ACM serial port with a shell on it.

(
    G=/sys/kernel/config/usb_gadget/fapdebug

    # The UDC appears once dwc3 and its PHY have probed (loaded by udev).
    i=0
    while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ $i -lt 120 ]; do
        sleep 1; i=$((i + 1))
    done
    udc=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -n "$udc" ] || { echo "fap-usb-debug: no USB device controller after 120 s" > /dev/kmsg; exit 0; }

    modprobe libcomposite 2>/dev/null
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
    mkdir -p "$G/strings/0x409" "$G/configs/c.1/strings/0x409" "$G/functions/acm.usb0"
    echo 0x1d6b > "$G/idVendor"      # Linux Foundation
    echo 0x0104 > "$G/idProduct"     # Multifunction Composite Gadget
    echo "fedora-atomic-phone" > "$G/strings/0x409/manufacturer"
    echo "initramfs debug shell" > "$G/strings/0x409/product"
    echo "ACM" > "$G/configs/c.1/strings/0x409/configuration"
    ln -s "$G/functions/acm.usb0" "$G/configs/c.1/"
    echo "$udc" > "$G/UDC"
    echo "fap-usb-debug: serial gadget up on $udc" > /dev/kmsg

    # Respawn a shell on the gadget's tty for as long as the initramfs lives.
    while :; do
        [ -c /dev/ttyGS0 ] && setsid sh -c 'exec sh -i </dev/ttyGS0 >/dev/ttyGS0 2>&1'
        sleep 1
    done
) &
