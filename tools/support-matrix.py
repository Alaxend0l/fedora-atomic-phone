#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Validate every devices/*/features.yaml (and firmware.yaml) and generate
docs/devices.md, the support matrix across devices.

    tools/support-matrix.py            write docs/devices.md
    tools/support-matrix.py --check    exit 1 if docs/devices.md is out of date
                                       or a device file is invalid

The feature catalogue (groups, ids, order, titles) is
devices/_template/features.yaml; every device must list exactly those
features. Schema: docs/features.md. Needs PyYAML (Fedora: python3-pyyaml;
elsewhere: `uv run --with pyyaml tools/support-matrix.py`).
"""
import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("support-matrix: needs PyYAML (dnf install python3-pyyaml, "
             "or: uv run --with pyyaml tools/support-matrix.py)")

STATUSES = ["works", "partial", "broken", "untested", "n-a"]
FIRMWARE_STATUSES = ["in-use", "planned", "unused"]
FIRMWARE_KEYS = ["name", "files", "source", "install", "consumer",
                 "redistributable", "package", "status", "notes"]
COMMIT = re.compile(r"^[0-9a-f]{7,40}$")
URL = re.compile(r"^https?://")
ENV_LINE = re.compile(r'^([A-Z][A-Z0-9_]*)="?([^"#]*?)"?\s*(?:#.*)?$')


class Invalid(Exception):
    pass


def read_env(path):
    """Read KEY="value" lines of a device.env (no shell evaluation)."""
    env = {}
    for line in path.read_text().splitlines():
        m = ENV_LINE.match(line.strip())
        if m:
            env[m.group(1)] = m.group(2).strip()
    return env


def load_yaml(path):
    try:
        return yaml.safe_load(path.read_text())
    except yaml.YAMLError as e:
        raise Invalid(f"{path}: not valid YAML: {e}")


def catalogue(root):
    """[(group, [(id, title), ...]), ...] from the template, in file order."""
    path = root / "devices/_template/features.yaml"
    data = load_yaml(path)
    groups = []
    for group, feats in data["features"].items():
        items = []
        for fid, entry in feats.items():
            if not entry.get("title"):
                raise Invalid(f"{path}: {group}.{fid} has no title")
            items.append((fid, entry["title"]))
        groups.append((group, items))
    return groups


def check_evidence(root, where, ev):
    if not isinstance(ev, str):
        raise Invalid(f"{where}: evidence must be a string (quote commit hashes)")
    if not ev or URL.match(ev) or COMMIT.match(ev):
        return
    if not (root / ev.split("#")[0]).exists():
        raise Invalid(f"{where}: evidence path {ev!r} doesn't exist "
                      "(use a repo path, a URL or a commit hash)")


def load_features(root, devdir, cat):
    path = devdir / "features.yaml"
    data = load_yaml(path)
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise Invalid(f"{path}: needs `schema: 1`")
    if data.get("device") != devdir.name:
        raise Invalid(f"{path}: device is {data.get('device')!r}, folder is {devdir.name!r}")
    feats = data.get("features") or {}
    want_groups = [g for g, _ in cat]
    if list(feats) != want_groups:
        raise Invalid(f"{path}: groups must be {want_groups} in that order, got {list(feats)}")
    out = {}
    for group, items in cat:
        have = feats[group] or {}
        want = [fid for fid, _ in items]
        missing = [f for f in want if f not in have]
        extra = [f for f in have if f not in want]
        if missing or extra:
            raise Invalid(f"{path}: group {group}: missing {missing}, unknown {extra} "
                          "(new features go into devices/_template/features.yaml first)")
        for fid in want:
            where = f"{path}: {group}.{fid}"
            e = have[fid]
            if not isinstance(e, dict):
                raise Invalid(f"{where}: must be a mapping")
            unknown = set(e) - {"status", "notes", "evidence", "title"}
            if unknown:
                raise Invalid(f"{where}: unknown keys {sorted(unknown)}")
            if e.get("status") not in STATUSES:
                raise Invalid(f"{where}: status {e.get('status')!r} not in {STATUSES}")
            notes = e.get("notes", "")
            if not isinstance(notes, str):
                raise Invalid(f"{where}: notes must be a string")
            ev = e.get("evidence", "")
            check_evidence(root, where, ev)
            out[fid] = {"status": e["status"], "notes": notes, "evidence": ev}
    return data.get("updated", ""), out


def check_firmware(root, devdir, env):
    name = env.get("FIRMWARE_MANIFEST") or "firmware.yaml"
    path = devdir / name
    if not path.exists():
        if env.get("FIRMWARE_MANIFEST"):
            raise Invalid(f"{devdir}/device.env: FIRMWARE_MANIFEST {name} doesn't exist")
        return
    data = load_yaml(path)
    if not isinstance(data, dict) or data.get("schema") != 1 or data.get("device") != devdir.name:
        raise Invalid(f"{path}: needs `schema: 1` and `device: {devdir.name}`")
    for i, e in enumerate(data.get("firmware") or []):
        where = f"{path}: entry {i} ({e.get('name', '?')})"
        missing = [k for k in FIRMWARE_KEYS if k not in e]
        if missing:
            raise Invalid(f"{where}: missing keys {missing}")
        if not isinstance(e["redistributable"], bool):
            raise Invalid(f"{where}: redistributable must be true or false")
        if e["status"] not in FIRMWARE_STATUSES:
            raise Invalid(f"{where}: status must be one of {FIRMWARE_STATUSES}")
        if not isinstance(e["source"], dict) or set(e["source"]) != {"partition", "path"}:
            raise Invalid(f"{where}: source must be {{partition, path}}")
        if e["redistributable"] is False and e["package"]:
            raise Invalid(f"{where}: a non-redistributable blob can't come from a package")


def devices(root):
    return sorted(d for d in (root / "devices").iterdir()
                  if d.is_dir() and not d.name.startswith(("_", "."))
                  and (d / "features.yaml").exists())


def evidence_md(ev):
    if not ev:
        return ""
    if URL.match(ev):
        return f"[link]({ev})"
    if COMMIT.match(ev):
        return f"`{ev}`"
    return f"[{ev.split('/')[-1]}](../{ev})"


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ")


def render(root):
    cat = catalogue(root)
    devs = []
    for d in devices(root):
        env = read_env(d / "device.env")
        updated, feats = load_features(root, d, cat)
        check_firmware(root, d, env)
        devs.append((d.name, env, updated, feats))

    total = sum(len(items) for _, items in cat)
    L = ["<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->",
         "<!-- Generated by tools/support-matrix.py from devices/*/features.yaml. Don't edit. -->",
         "# Supported devices", "",
         "What works on each phone. Generated from each device's `features.yaml`",
         "(schema: [features.md](features.md)); edit those, then run",
         "`tools/support-matrix.py`. CI fails if this file is out of date.", "",
         "Status: **works** · **partial** (works with limits or a workaround) ·",
         "**broken** (doesn't work yet) · **untested** · **n-a** (hardware not present)", "",
         "## Devices", "",
         "| Device | Name | SoC | Status | Boot method | Maintainer | Works | Updated |",
         "|---|---|---|---|---|---|---|---|"]
    for name, env, updated, feats in devs:
        works = sum(1 for f in feats.values() if f["status"] == "works")
        partial = sum(1 for f in feats.values() if f["status"] == "partial")
        L.append(f"| [`{name}`](../devices/{name}/README.md) | {cell(env.get('DEVICE_NAME', ''))} "
                 f"| {env.get('DEVICE_SOC', '')} | {env.get('DEVICE_STATUS', '')} "
                 f"| {env.get('BOOT_METHOD', '')} | {cell(env.get('DEVICE_MAINTAINER', ''))} "
                 f"| {works}/{total} (+{partial} partial) | {updated} |")

    L += ["", "## Feature matrix", "",
          "| Group | Feature | " + " | ".join(f"`{n}`" for n, *_ in devs) + " |",
          "|---|---|" + "---|" * len(devs)]
    for group, items in cat:
        for fid, title in items:
            L.append(f"| {group} | {cell(title)} | "
                     + " | ".join(feats[fid]["status"] for _, _, _, feats in devs) + " |")

    for name, env, updated, feats in devs:
        L += ["", f"## {env.get('DEVICE_NAME', name)} (`{name}`)", "",
              f"From [devices/{name}/features.yaml](../devices/{name}/features.yaml), updated {updated}.", "",
              "| Feature | Status | Notes | Evidence |", "|---|---|---|---|"]
        for group, items in cat:
            for fid, title in items:
                f = feats[fid]
                L.append(f"| {cell(title)} | {f['status']} | {cell(f['notes'])} "
                         f"| {evidence_md(f['evidence'])} |")
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="fail if docs/devices.md is stale")
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args(argv)
    out = args.root / "docs/devices.md"
    try:
        text = render(args.root)
    except Invalid as e:
        print(f"support-matrix: {e}", file=sys.stderr)
        return 1
    if args.check:
        if not out.exists() or out.read_text() != text:
            print("support-matrix: docs/devices.md is out of date; run tools/support-matrix.py",
                  file=sys.stderr)
            return 1
        print("docs/devices.md is up to date")
        return 0
    out.write_text(text)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
