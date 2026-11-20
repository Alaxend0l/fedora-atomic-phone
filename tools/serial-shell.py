#!/usr/bin/env python3
"""Run commands on a phone's USB serial debug shell (the ramboot initramfs's
CDC-ACM gadget, see boot/android-bootimg/tiny-init) and print the output.

    tools/serial-shell.py [--dev /dev/cu.usbmodem101] [--wait 2] 'cmd' ['cmd' ...]

Each command is sent with a newline; output is collected for --wait seconds.
No pyserial needed (termios only). macOS: /dev/cu.usbmodem*; Linux: /dev/ttyACM*.
"""
import argparse, glob, os, select, sys, termios, time

p = argparse.ArgumentParser()
p.add_argument("--dev", default=None)
p.add_argument("--wait", type=float, default=2.0)
p.add_argument("cmds", nargs="+")
args = p.parse_args()

dev = args.dev or next(iter(sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))), None)
if not dev:
    sys.exit("no USB serial device found")

fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[0] = attrs[1] = attrs[3] = 0          # raw: no input/output/local processing
attrs[2] |= termios.CREAD | termios.CLOCAL
termios.tcsetattr(fd, termios.TCSANOW, attrs)

for cmd in args.cmds:
    os.write(fd, (cmd + "\n").encode())
    out, end = b"", time.time() + args.wait
    while time.time() < end:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                out += os.read(fd, 65536)
            except BlockingIOError:
                pass
    sys.stdout.write(out.decode(errors="replace"))
os.close(fd)
