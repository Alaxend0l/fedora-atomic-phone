#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/recon/lp-parse.py against synthetic super images.

    python3 tools/tests/test_lp_parse.py
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # keep tools/recon free of __pycache__

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "lp_parse", os.path.join(HERE, "..", "recon", "lp-parse.py"))
lp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lp)

MAX_SIZE = 65536


def build_super(partitions, slot_count=2, minor=2, block_devices=None, size=1 << 20):
    """A super-partition head as AOSP's liblp writes it.
    partitions: [(name, attrs, group_index, [(sectors, start_sector), ...])]"""
    groups = [("default", 0, 0), ("qti_dynamic_partitions_a", 0, 4 << 30)]
    block_devices = block_devices or [(2048, 1, 0, 8 << 30, "super", 0)]
    ptab, etab = b"", b""
    n_ext = 0
    for name, attrs, group, exts in partitions:
        ptab += struct.pack("<36sIIII", name.encode(), attrs, n_ext, len(exts), group)
        for sectors, start in exts:
            etab += struct.pack("<QIQI", sectors, 0, start, 0)
        n_ext += len(exts)
    gtab = b"".join(struct.pack("<36sIQ", n.encode(), f, m) for n, f, m in groups)
    btab = b"".join(struct.pack("<QIIQ36sI", fls, al, ao, sz, n.encode(), fl)
                    for fls, al, ao, sz, n, fl in block_devices)
    tables = ptab + etab + gtab + btab
    descs = [(0, len(partitions), 52), (len(ptab), n_ext, 24),
             (len(ptab) + len(etab), len(groups), 48),
             (len(ptab) + len(etab) + len(gtab), len(block_devices), 64)]
    header_size = 256 if minor >= 2 else 128

    def header(hsum):
        h = struct.pack("<IHHI32sI32s", 0x414C5030, 10, minor, header_size, hsum,
                        len(tables), hashlib.sha256(tables).digest())
        for d in descs:
            h += struct.pack("<III", *d)
        if header_size == 256:
            h += struct.pack("<I", 0) + b"\0" * 124
        return h
    h = header(hashlib.sha256(header(b"\0" * 32)).digest())

    def geometry(gsum):
        return struct.pack("<II32sIII", 0x616C4467, 52, gsum, MAX_SIZE, slot_count, 4096)
    geo = geometry(hashlib.sha256(geometry(b"\0" * 32)).digest())

    img = bytearray(size)
    img[4096:4096 + 52] = geo
    img[8192:8192 + 52] = geo
    for slot in range(slot_count):
        off = 12288 + slot * MAX_SIZE
        img[off:off + len(h) + len(tables)] = h + tables
    return bytes(img)


PARTS = [
    ("system_a", 1, 1, [(2097152, 2048)]),
    ("vendor_a", 1, 1, [(1048576, 2099200)]),
    ("product_a", 1, 1, [(4096, 3147776), (8192, 4000000)]),
    ("system_b", 1, 1, []),
]


def run_main(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = lp.main(argv)
    return rc, out.getvalue(), err.getvalue()


class LpParseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "super-head.bin")
        self.write(build_super(PARTS))

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, data):
        with open(self.path, "wb") as f:
            f.write(data)

    def test_partitions(self):
        meta = lp.parse_metadata(open(self.path, "rb").read())
        names = [p["name"] for p in meta["partitions"]]
        self.assertEqual(names, ["system_a", "vendor_a", "product_a", "system_b"])
        vendor = meta["partitions"][1]
        self.assertEqual(vendor["extents"][0]["start_sector"], 2099200)
        self.assertEqual(vendor["sectors"], 1048576)
        self.assertEqual(vendor["group"], "qti_dynamic_partitions_a")
        self.assertEqual(vendor["attributes"], ["readonly"])
        self.assertEqual(meta["block_devices"][0]["name"], "super")
        self.assertEqual(meta["version"], "10.2")

    def test_partition_byte_range(self):
        rc, out, _ = run_main([self.path, "--partition", "vendor_a"])
        self.assertEqual(rc, 0)
        self.assertEqual(out.split(), [str(2099200 * 512), str(1048576 * 512)])

    def test_multi_extent_refused(self):
        rc, _, err = run_main([self.path, "--partition", "product_a"])
        self.assertEqual(rc, 1)
        self.assertIn("2 extents", err)

    def test_empty_and_unknown(self):
        self.assertEqual(run_main([self.path, "--partition", "system_b"])[0], 1)
        rc, _, err = run_main([self.path, "--partition", "odm_a"])
        self.assertEqual(rc, 1)
        self.assertIn("vendor_a", err)   # lists the names that exist

    def test_table_and_json(self):
        rc, out, _ = run_main([self.path])
        self.assertEqual(rc, 0)
        self.assertIn("vendor_a", out)
        self.assertIn("2099200", out)
        self.assertIn("(+1 extents)", out)
        rc, out, _ = run_main([self.path, "--json"])
        self.assertEqual(json.loads(out)["partitions"][2]["sectors"], 12288)

    def test_v1_0_header_and_slot1(self):
        self.write(build_super(PARTS, slot_count=3, minor=0))
        rc, out, _ = run_main([self.path, "--slot", "1", "--partition", "system_a"])
        self.assertEqual(rc, 0)
        self.assertEqual(out.split()[0], str(2048 * 512))
        self.assertEqual(run_main([self.path, "--slot", "3"])[0], 1)

    def test_corrupt_tables_detected(self):
        img = bytearray(build_super(PARTS))
        img[12288 + 256 + 3] ^= 0xFF          # inside the partition table
        self.write(bytes(img))
        rc, _, err = run_main([self.path])
        self.assertEqual(rc, 1)
        self.assertIn("tables checksum", err)

    def test_backup_geometry_used(self):
        img = bytearray(build_super(PARTS))
        img[4096 + 20] ^= 0xFF                # primary geometry checksum breaks
        self.write(bytes(img))
        rc, out, err = run_main([self.path, "--partition", "system_a"])
        self.assertEqual(rc, 0)
        self.assertIn("backup geometry", err)

    def test_not_super(self):
        self.write(b"\0" * (1 << 20))
        rc, _, err = run_main([self.path])
        self.assertEqual(rc, 1)
        self.assertIn("not a super partition", err)

    def test_short_dump(self):
        self.write(build_super(PARTS)[:12288 + 100])
        self.assertEqual(run_main([self.path])[0], 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
