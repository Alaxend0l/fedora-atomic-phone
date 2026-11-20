#!/usr/bin/env python3
"""List the kernel modules that drive a device tree's enabled nodes.

    tools/dt-modules.py <board.dts> <modules.alias>

Reads a decompiled DT (dtc -I dtb -O dts) and a kernel's modules.alias, and
prints one line per enabled node whose compatible matches a module. Nodes
without a match are either built into the kernel or have no driver. Use it to
pick a device's RAMBOOT_DRIVERS and to spot hardware with no driver yet.
Matching is approximate (OF aliases are glob patterns; this compares the
compatible string only).
"""
import re
import sys

dts_path, alias_path = sys.argv[1], sys.argv[2]
dts = open(dts_path).read()

modules_for = {}
for line in open(alias_path):
    if not line.startswith("alias of:"):
        continue
    _, pattern, module = line.split(" ", 2)
    m = re.search(r"C([^*]+?)(?:C\*|\*|$)", pattern)
    if m:
        modules_for.setdefault(m.group(1), set()).add(module.strip())

# Innermost node bodies are enough to read compatible + status.
seen = {}
for name, body in re.findall(r"([\w,.@-]+) \{([^{}]*)", dts):
    if 'status = "disabled"' in body:
        continue
    m = re.search(r"compatible = ([^;]+);", body)
    if not m:
        continue
    compatibles = re.findall(r'"([^"]+)"', m.group(1))
    mods = set()
    for c in compatibles:
        mods |= modules_for.get(c, set())
    seen.setdefault(compatibles[0], (name, sorted(mods)))

for compatible, (node, mods) in sorted(seen.items()):
    print(f"{compatible:45} {node[:30]:30} -> {' '.join(mods) if mods else '(built-in or none)'}")
