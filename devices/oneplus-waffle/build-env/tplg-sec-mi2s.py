#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Patch an AudioReach topology binary in place so that its PRIMARY_MI2S_RX
# playback graph drives SECONDARY_MI2S_RX instead (OnePlus 12: the TFA9874
# speaker amplifiers sit on LPASS I2S1). Binary, not via `alsatplg -d/-c`:
# the decoder's output does not recompile to the same file, and an in-place
# patch keeps every other graph (the WCD9395 codec DMA paths) byte-identical.
#
# Changes, all checked:
#   - names in fixed-size (44-byte) string fields: "device16." -> "device18.",
#     "Primary MI2S Playback" -> "Secondary MI2S Playback",
#     "PRIMARY_MI2S_RX" -> "SECONDARY_MI2S_RX" (only where the field's zero
#     padding has room)
#   - in the vendor tuples of the widgets of that graph:
#     AR_TKN_DAI_INDEX (1) 16 -> 18, and in the I2S module
#     AR_TKN_U32_MODULE_HW_IF_IDX (250) 0 -> 1 (I2S interface 0 = primary,
#     1 = secondary)
#   - the block index of that graph's widget and route blocks 16 -> 18
# Usage: tplg-sec-mi2s.py in.bin out.bin   (prints every changed offset)
import struct
import sys

d = bytearray(open(sys.argv[1], 'rb').read())
orig = bytes(d)
NAME = 44
TPLG_MAGIC = 0x41536f43  # 'CoSA'
TYPE_DAPM_GRAPH, TYPE_DAPM_WIDGET = 4, 5

def die(msg):
    sys.exit("tplg-sec-mi2s: " + msg)

def replace_str(old, new):
    n, i = 0, 0
    while True:
        i = d.find(old, i)
        if i < 0:
            return n
        # find the start of the 44-byte field: previous bytes are printable
        # name characters; the field ends in zero padding with room.
        end = d.find(b'\0', i)
        tail = d[i + len(old):end]
        if end - i + (len(new) - len(old)) >= NAME:
            die(f"{new!r} does not fit at {i:#x}")
        repl = new + tail
        room = d[end:end + len(repl) - (end - i)]
        if any(room):
            die(f"no zero padding after {old!r} at {i:#x}")
        d[i:i + len(repl)] = repl
        n += 1
        i += len(repl)

if struct.unpack_from('<I', d, 0)[0] != TPLG_MAGIC:
    die("not an ALSA topology file")
if b"SECONDARY_MI2S" in d or b"Secondary MI2S" in d or b"device18." in d:
    die("already patched or unexpected input")

# Block headers: index 16 is the PRIMARY_MI2S_RX graph (widgets + routes).
o = 0
blocks = []
while o < len(d):
    magic, abi, ver, typ, size, vt, psz, idx, cnt = struct.unpack_from('<9I', d, o)
    if magic != TPLG_MAGIC:
        die(f"bad block header at {o:#x}")
    blocks.append((o, typ, size, psz, idx))
    o += size + psz
mi2s = [b for b in blocks if b[4] == 16]
if sorted(b[1] for b in mi2s) != [TYPE_DAPM_GRAPH, TYPE_DAPM_WIDGET]:
    die(f"expected one widget and one graph block with index 16, got {mi2s}")

# Vendor tuple arrays (snd_soc_tplg_vendor_array: size, type, num_elems,
# then {token, value} u32 pairs for type WORD = 4) in a byte range.
def patch_tuples(lo, hi, edits, what):
    done = {k: 0 for k in edits}
    p = lo
    while p + 12 <= hi:
        size, typ, n = struct.unpack_from('<III', d, p)
        if typ == 4 and 0 < n < 64 and size == 12 + 8 * n and p + size <= hi:
            for e in range(p + 12, p + size, 8):
                tok, val = struct.unpack_from('<II', d, e)
                if (tok, val) in edits:
                    struct.pack_into('<I', d, e + 4, edits[(tok, val)])
                    done[(tok, val)] += 1
            p += size
        else:
            p += 4
    return done

def widget(name):
    i = d.find(name + b'\0')
    if i < 0 or d.find(name + b'\0', i + 1) >= 0 and d[i - 8:i - 4] != b'\x84\0\0\0':
        die(f"widget {name!r} not found")
    st = i - 8
    if struct.unpack_from('<I', d, st)[0] != 132:
        die(f"{name!r}: unexpected widget struct size")
    psz = struct.unpack_from('<I', d, st + 128)[0]
    return st + 132, st + 132 + psz

DAI16 = {(1, 16): 18}
lo, hi = widget(b"device16.logger1")
if patch_tuples(lo, hi, DAI16, "logger")[(1, 16)] != 1:
    die("logger widget: DAI index tuple not found")
lo, hi = widget(b"device16.i2s_rx1")
r = patch_tuples(lo, hi, {(1, 16): 18, (250, 0): 1}, "i2s")
if r[(1, 16)] != 1 or r[(250, 0)] != 1:
    die(f"i2s widget: {r}")
# The index-16 widget block: the mixer widget "PRIMARY_MI2S_RX Audio Mixer"
# (its kcontrols MultiMedia1/2/5 carry the stream ids, not the DAI's).
wo, _, wsize, wpsz, _ = next(b for b in mi2s if b[1] == TYPE_DAPM_WIDGET)
r = patch_tuples(wo + wsize, wo + wsize + wpsz, DAI16, "mixer")
if r[(1, 16)] != 1:
    die(f"mixer block: {r[(1, 16)]} DAI index tuples (expected 1)")

for o, typ, size, psz, idx in mi2s:
    struct.pack_into('<I', d, o + 28, 18)

n1 = replace_str(b"device16.", b"device18.")
n2 = replace_str(b"Primary MI2S Playback", b"Secondary MI2S Playback")
n3 = replace_str(b"PRIMARY_MI2S_RX", b"SECONDARY_MI2S_RX")
if not (n1 and n2 and n3):
    die(f"string replacements: {n1} {n2} {n3}")
if len(d) != len(orig):
    die("size changed")
open(sys.argv[2], 'wb').write(d)
diff = [i for i in range(len(d)) if d[i] != orig[i]]
print(f"tplg-sec-mi2s: {len(diff)} bytes changed; names: device16 x{n1}, "
      f"Primary MI2S Playback x{n2}, PRIMARY_MI2S_RX x{n3}; tuples: DAI index x3, HW_IF_IDX x1; blocks: 2")
