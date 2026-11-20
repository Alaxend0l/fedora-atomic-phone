#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Parse the logical-partition (LP) metadata of an Android dynamic `super`
partition, from a dump of its first bytes (1 MiB is plenty).

    lp-parse.py <super-head.bin>                    table of partitions
    lp-parse.py <super-head.bin> --json             the same as JSON
    lp-parse.py <super-head.bin> --partition vendor_a
                                                    "<byte offset> <byte size>"
                                                    for losetup -o/--sizelimit

Get the dump read-only, e.g. on a phone running our Linux:
    dd if=/dev/disk/by-partlabel/super bs=1M count=1 > super-head.bin
(tools/recon/extract-from-super.sh does this and the mount for you.)

Format (AOSP system/core/fs_mgr/liblp/include/liblp/metadata_format.h):
  4096   geometry (magic "gDla"), backup copy at 8192
  12288  metadata slot 0: header (magic "0PLA"), then the tables
         (partitions, extents, groups, block devices); slot n at
         12288 + n * metadata_max_size
Extent sectors are 512 bytes, relative to the start of the block device they
name (normally `super` itself). Checksums (SHA-256) are verified.
Python 3.9+, standard library only.
"""
import argparse
import hashlib
import json
import struct
import sys

SECTOR = 512
GEOMETRY_OFFSET = 4096
GEOMETRY_SIZE = 4096
METADATA_OFFSET = GEOMETRY_OFFSET + 2 * GEOMETRY_SIZE   # 12288

GEOMETRY_MAGIC = 0x616C4467   # "gDla"
HEADER_MAGIC = 0x414C5030     # "0PLA"
TARGET_LINEAR, TARGET_ZERO = 0, 1

# struct formats, little-endian
GEOMETRY_FMT = "<II32sIII"                        # 52 bytes
HEADER_V1_0_FMT = "<IHHI32sI32s" + "III" * 4      # 128 bytes
PARTITION_FMT = "<36sIIII"                        # 52
EXTENT_FMT = "<QIQI"                              # 24
GROUP_FMT = "<36sIQ"                              # 48
BLOCK_DEVICE_FMT = "<QIIQ36sI"                    # 64

PARTITION_ATTRS = {1: "readonly", 2: "slot-suffixed", 4: "updated", 8: "disabled"}
HEADER_FLAGS = {1: "virtual-ab", 2: "overlays-active"}


class LpError(Exception):
    pass


def cstr(b):
    return b.split(b"\0", 1)[0].decode("ascii", "replace")


def flag_names(value, names):
    return [n for bit, n in names.items() if value & bit] + (
        ["0x%x" % (value & ~sum(names))] if value & ~sum(names) else [])


def parse_geometry(data, offset=GEOMETRY_OFFSET):
    if len(data) < offset + struct.calcsize(GEOMETRY_FMT):
        raise LpError("dump too short for the geometry at %d" % offset)
    magic, struct_size, checksum, max_size, slot_count, block_size = \
        struct.unpack_from(GEOMETRY_FMT, data, offset)
    if magic != GEOMETRY_MAGIC:
        raise LpError("no LP geometry magic at %d (not a super partition?)" % offset)
    raw = bytearray(data[offset:offset + struct_size])
    raw[8:40] = b"\0" * 32
    if hashlib.sha256(raw).digest() != checksum:
        raise LpError("geometry checksum mismatch at %d" % offset)
    return {"metadata_max_size": max_size, "metadata_slot_count": slot_count,
            "logical_block_size": block_size}


def parse_metadata(data, slot=0):
    try:
        geo = parse_geometry(data)
    except LpError as e:
        print("warning: %s; trying the backup geometry" % e, file=sys.stderr)
        geo = parse_geometry(data, GEOMETRY_OFFSET + GEOMETRY_SIZE)
    if not 0 <= slot < geo["metadata_slot_count"]:
        raise LpError("slot %d out of range (metadata has %d)" % (slot, geo["metadata_slot_count"]))
    off = METADATA_OFFSET + slot * geo["metadata_max_size"]
    if len(data) < off + struct.calcsize(HEADER_V1_0_FMT):
        raise LpError("dump too short for metadata slot %d at %d" % (slot, off))

    f = struct.unpack_from(HEADER_V1_0_FMT, data, off)
    magic, major, minor, header_size, header_sum, tables_size, tables_sum = f[:7]
    descs = [f[7 + 3 * i:10 + 3 * i] for i in range(4)]   # (offset, count, entry_size)
    if magic != HEADER_MAGIC:
        raise LpError("no LP header magic at %d" % off)
    if major != 10:
        raise LpError("unsupported LP metadata version %d.%d" % (major, minor))
    flags = struct.unpack_from("<I", data, off + 128)[0] if header_size >= 132 else 0

    header = bytearray(data[off:off + header_size])
    header[12:44] = b"\0" * 32
    if hashlib.sha256(header).digest() != header_sum:
        raise LpError("metadata header checksum mismatch (slot %d)" % slot)
    tables_off = off + header_size
    tables = data[tables_off:tables_off + tables_size]
    if len(tables) < tables_size:
        raise LpError("dump too short: tables end at %d" % (tables_off + tables_size))
    if hashlib.sha256(tables).digest() != tables_sum:
        raise LpError("metadata tables checksum mismatch (slot %d)" % slot)

    def table(i, fmt):
        t_off, count, entry_size = descs[i]
        if entry_size < struct.calcsize(fmt):
            raise LpError("table %d entries too small (%d bytes)" % (i, entry_size))
        if t_off + count * entry_size > tables_size:
            raise LpError("table %d runs past the tables area" % i)
        return [struct.unpack_from(fmt, tables, t_off + n * entry_size) for n in range(count)]

    extents = [{"sectors": n, "type": "linear" if t == TARGET_LINEAR else "zero" if t == TARGET_ZERO else t,
                "start_sector": d, "block_device": s}
               for n, t, d, s in table(1, EXTENT_FMT)]
    groups = [{"name": cstr(n), "flags": fl, "maximum_size": m} for n, fl, m in table(2, GROUP_FMT)]
    block_devices = [{"first_logical_sector": fls, "alignment": al, "alignment_offset": ao,
                      "size": sz, "name": cstr(n), "flags": fl}
                     for fls, al, ao, sz, n, fl in table(3, BLOCK_DEVICE_FMT)]
    partitions = []
    for name, attrs, first, count, group in table(0, PARTITION_FMT):
        if first + count > len(extents):
            raise LpError("partition %s points past the extent table" % cstr(name))
        exts = extents[first:first + count]
        partitions.append({
            "name": cstr(name),
            "attributes": flag_names(attrs, PARTITION_ATTRS),
            "group": groups[group]["name"] if group < len(groups) else group,
            "sectors": sum(e["sectors"] for e in exts),
            "extents": exts,
        })
    return {"version": "%d.%d" % (major, minor), "slot": slot, "geometry": geo,
            "flags": flag_names(flags, HEADER_FLAGS), "block_devices": block_devices,
            "groups": groups, "partitions": partitions}


def byte_range(meta, name):
    """(offset, size) in bytes of a partition that is one linear extent on
    block device 0, as losetup -o/--sizelimit want it."""
    for p in meta["partitions"]:
        if p["name"] == name:
            exts = p["extents"]
            if not exts:
                raise LpError("%s is empty (no extents)" % name)
            if len(exts) != 1:
                raise LpError("%s has %d extents; a single loop device can't map it "
                              "(use dmsetup, see --json)" % (name, len(exts)))
            e = exts[0]
            if e["type"] != "linear" or e["block_device"] != 0:
                raise LpError("%s is not a linear extent on the first block device" % name)
            return e["start_sector"] * SECTOR, e["sectors"] * SECTOR
    raise LpError("no partition named %s (names: %s)" % (
        name, " ".join(p["name"] for p in meta["partitions"])))


def print_table(meta, out=None):
    out = out or sys.stdout
    geo = meta["geometry"]
    print("LP metadata %s, slot %d of %d, max size %d, block size %d%s" % (
        meta["version"], meta["slot"], geo["metadata_slot_count"], geo["metadata_max_size"],
        geo["logical_block_size"],
        ", flags " + ",".join(meta["flags"]) if meta["flags"] else ""), file=out)
    for b in meta["block_devices"]:
        print("block device %s: %d bytes, first logical sector %d" % (
            b["name"], b["size"], b["first_logical_sector"]), file=out)
    print(file=out)
    print("%-24s %-26s %22s %12s %10s  %s" % (
        "partition", "group", "start sector", "sectors", "MiB", "attributes"), file=out)
    for p in meta["partitions"]:
        exts = p["extents"]
        start = str(exts[0]["start_sector"]) if exts else "-"
        if len(exts) > 1:
            start += " (+%d extents)" % (len(exts) - 1)
        print("%-24s %-26s %22s %12d %10.1f  %s" % (
            p["name"], p["group"], start, p["sectors"], p["sectors"] * SECTOR / 2**20,
            ",".join(p["attributes"])), file=out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dump", help="the first bytes of a super partition (1 MiB is plenty)")
    ap.add_argument("--slot", type=int, default=0, help="metadata slot (default 0)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--json", action="store_true", help="print everything as JSON")
    g.add_argument("--partition", metavar="NAME",
                   help='print "<byte offset> <byte size>" of one partition')
    args = ap.parse_args(argv)
    with open(args.dump, "rb") as fh:
        data = fh.read()
    try:
        meta = parse_metadata(data, args.slot)
        if args.partition:
            print("%d %d" % byte_range(meta, args.partition))
        elif args.json:
            json.dump(meta, sys.stdout, indent=2)
            print()
        else:
            print_table(meta)
    except LpError as e:
        print("lp-parse: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
