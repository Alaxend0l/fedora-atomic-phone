# SPDX-License-Identifier: AGPL-3.0-or-later
"""Shared code for the update pipeline (docs/updates.md): RPM version
comparison, lockfile loading and diffing, changelog slicing, and matching
packages against tools/update/watched-packages.yaml.

Plain functions without I/O where possible, so tools/tests can test them.
Works on Python >= 3.9 (macOS's /usr/bin/python3). Needs PyYAML only for
the functions that read YAML.
"""
import fnmatch
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LOCK_DIR = REPO / "lock"
WATCHED = REPO / "tools/update/watched-packages.yaml"
COOKBOOK = "docs/porting-cookbook.md"


def load_yaml(path):
    try:
        import yaml
    except ImportError:  # pragma: no cover
        sys.exit("needs PyYAML (dnf install python3-pyyaml, apt install "
                 "python3-yaml, or: uv run --with pyyaml <script>)")
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------- versions

def _segments(s):
    return re.findall(r"~|\^|[0-9]+|[A-Za-z]+", s)


def rpmvercmp(a, b):
    """rpm's version comparison (rpmvercmp.c): -1, 0 or 1. Handles ~ (sorts
    before anything) and ^ (sorts after the base, before a longer version)."""
    if a == b:
        return 0
    sa, sb = _segments(a), _segments(b)
    i = 0
    while True:
        x = sa[i] if i < len(sa) else None
        y = sb[i] if i < len(sb) else None
        i += 1
        if x == "~" or y == "~":
            if x != y:
                return -1 if x == "~" else 1
            continue
        if x == "^" or y == "^":
            if x == y:
                continue
            if x is None:
                return -1
            if y is None:
                return 1
            return 1 if x != "^" else -1
        if x is None or y is None:
            if x is None and y is None:
                return 0
            return -1 if x is None else 1
        xd, yd = x.isdigit(), y.isdigit()
        if xd != yd:
            return 1 if xd else -1          # numbers are newer than letters
        if xd:
            x, y = int(x), int(y)
        if x != y:
            return 1 if x > y else -1


def split_evr(evr):
    """'1:2.3-4.fc45' -> (1, '2.3', '4.fc45'); missing epoch is 0."""
    epoch = 0
    if ":" in evr:
        e, evr = evr.split(":", 1)
        epoch = int(e or 0)
    if "-" in evr:
        v, r = evr.rsplit("-", 1)
    else:
        v, r = evr, ""
    return epoch, v, r


def evrcmp(a, b):
    ea, va, ra = split_evr(a)
    eb, vb, rb = split_evr(b)
    if ea != eb:
        return 1 if ea > eb else -1
    c = rpmvercmp(va, vb)
    if c or not ra or not rb:
        return c
    return rpmvercmp(ra, rb)


def source_nvr(sourcerpm):
    """'mesa-26.2.1-1.fc45.src.rpm' -> 'mesa-26.2.1-1.fc45'."""
    return re.sub(r"\.src\.rpm$", "", sourcerpm or "")


def source_name(sourcerpm):
    """'mesa-26.2.1-1.fc45.src.rpm' -> 'mesa'."""
    nvr = source_nvr(sourcerpm)
    parts = nvr.rsplit("-", 2)
    return parts[0] if len(parts) == 3 else nvr


# ---------------------------------------------------------------- lockfiles

def lock_packages(lock):
    """Every package a lock says the image ends up with: the base image's
    packages, minus what our steps remove or replace, plus what they install.
    Returns {(name, arch): [entry, ...]} (several entries for installonly
    packages such as kernel-core)."""
    out = {}
    removed = {(r["name"], r["arch"]) for r in lock.get("removed") or []}
    layer = {(p["name"], p["arch"]) for p in lock.get("packages") or []}
    for p in (lock.get("base") or {}).get("packages") or []:
        key = (p["name"], p["arch"])
        if key in removed or key in layer:
            continue
        out.setdefault(key, []).append(dict(p, origin="base"))
    for p in lock.get("packages") or []:
        out.setdefault((p["name"], p["arch"]), []).append(dict(p, origin="layer"))
    # netroot-style images copy /usr/lib/modules from another image: its
    # kernel is part of what we ship.
    for p in (lock.get("kernel_image") or {}).get("packages") or []:
        out.setdefault((p["name"], p["arch"]), []).append(dict(p, origin="kernel_image"))
    return out


def _evrs(entries):
    return sorted({e["evr"] for e in entries}, key=_EvrKey)


class _EvrKey:
    def __init__(self, evr):
        self.evr = evr

    def __lt__(self, other):
        return evrcmp(self.evr, other.evr) < 0


def diff_locks(old_locks, new_locks):
    """Diff two {target: lock} maps.

    Returns {"packages": [...], "images": [...]}; one package entry per
    (name, arch) whose version set changed in any target, with the targets
    it changed in, the old and new versions, and old/new source RPM."""
    changes = {}
    images = []
    for target in sorted(set(old_locks) | set(new_locks)):
        old = old_locks.get(target) or {}
        new = new_locks.get(target) or {}
        for kind in ("base", "kernel_image"):
            ob, nb = old.get(kind) or {}, new.get(kind) or {}
            if ob.get("digest") != nb.get("digest") and (ob or nb):
                images.append({
                    "target": target, "kind": kind,
                    "image": nb.get("image") or ob.get("image"),
                    "old": ob.get("digest"), "new": nb.get("digest"),
                    "old_version": ob.get("version"), "new_version": nb.get("version"),
                })
        op, np_ = lock_packages(old), lock_packages(new)
        for key in set(op) | set(np_):
            oe, ne = op.get(key, []), np_.get(key, [])
            ov, nv = _evrs(oe), _evrs(ne)
            if ov == nv:
                continue
            name, arch = key
            c = changes.setdefault((name, arch, tuple(ov), tuple(nv)), {
                "name": name, "arch": arch,
                "old": ov[-1] if ov else None, "new": nv[-1] if nv else None,
                "old_versions": ov, "new_versions": nv,
                "old_source": (oe[-1].get("source") if oe else None),
                "new_source": (ne[-1].get("source") if ne else None),
                "targets": [],
            })
            c["targets"].append(target)
    pkgs = []
    for c in changes.values():
        if c["old"] is None:
            c["change"] = "added"
        elif c["new"] is None:
            c["change"] = "removed"
        elif evrcmp(c["new"], c["old"]) > 0:
            c["change"] = "upgraded"
        else:
            c["change"] = "downgraded"
        c["source"] = source_name(c["new_source"] or c["old_source"])
        pkgs.append(c)
    pkgs.sort(key=lambda c: (c["source"], c["name"], c["arch"], c["targets"]))
    return {"packages": pkgs, "images": images}


def group_by_source(packages):
    """Group package changes by source package and source NVR change:
    {(source, old_nvr, new_nvr): [change, ...]}, which is what Bodhi and
    changelogs are keyed by."""
    groups = {}
    for c in packages:
        key = (c["source"], source_nvr(c["old_source"]), source_nvr(c["new_source"]))
        groups.setdefault(key, []).append(c)
    return groups


# ---------------------------------------------------------------- changelogs

_AUTHOR_EVR = re.compile(r"\s-\s*((?:\d+:)?[^\s<>]+-[^\s<>]+)\s*$")


def changelog_evr(author):
    """The version at the end of a changelog header, if any:
    'Jane <j@x.org> - 1.2-3' -> '1.2-3'."""
    m = _AUTHOR_EVR.search(author or "")
    return m.group(1) if m else None


def slice_changelog(entries, old_evr, limit=30):
    """Changelog entries newer than old_evr, newest first.

    entries: [{"timestamp": int, "author": str, "text": str}] in any order
    (libdnf5 gives them oldest first). Stops at the first entry whose
    version is <= old_evr; entries without a version are kept until then.
    With old_evr None (new package) returns the newest `limit` entries."""
    out = []
    for e in sorted(entries, key=lambda e: e.get("timestamp", 0), reverse=True):
        v = changelog_evr(e.get("author"))
        if old_evr and v:
            # Changelog versions usually lack the epoch and the dist tag.
            _, ov, orel = split_evr(old_evr)
            _, ev, erel = split_evr(v)
            orel = re.sub(r"\.fc\d+.*$", "", orel)
            erel = re.sub(r"\.fc\d+.*$", "", erel)
            c = rpmvercmp(ev, ov) or (rpmvercmp(erel, orel) if erel and orel else 0)
            if c <= 0:
                break
        out.append(e)
        if len(out) >= limit:
            break
    return out


# ---------------------------------------------------------------- watched

def load_watched(path=WATCHED):
    data = load_yaml(path) or {}
    return data.get("watched") or []


def watched_entries(change, watched):
    """The watched-packages.yaml entries that match a change (by binary or
    source package name, fnmatch globs)."""
    names = {change["name"], change.get("source") or ""}
    hits = []
    for w in watched:
        if any(fnmatch.fnmatchcase(n, g) for g in w.get("match") or [] for n in names if n):
            hits.append(w)
    return hits
