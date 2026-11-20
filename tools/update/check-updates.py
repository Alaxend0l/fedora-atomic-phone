#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""What would change if we re-locked today? Regenerates the lockfiles and
diffs them against lock/ (docs/updates.md).

    tools/update/check-updates.py                  regenerate into a temp dir, report
    tools/update/check-updates.py --write          ... and update lock/ in place
    tools/update/check-updates.py --old A --new B  only diff two lock dirs (no podman)
    tools/update/check-updates.py --changelogs     add RPM changelogs (podman, fedora:45)

Outputs (default: Markdown on stdout):
    --json FILE      machine-readable report (input of review.py)
    --markdown FILE  report for a PR body / humans

Report rows are per *source* package (what Fedora builds and Bodhi ships):
old NVR -> new NVR, binary packages, targets, and whether it's on
tools/update/watched-packages.yaml (what to test, cookbook recipe).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import updatelib as ul  # noqa: E402

PR_BODY_LIMIT = 60000          # GitHub caps PR bodies at 65536 characters
CHANGELOG_IMAGE = "registry.fedoraproject.org/fedora:45"


def lockmod():
    import importlib.util
    spec = importlib.util.spec_from_file_location("lock", ul.REPO / "tools/update/lock.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build_report(old_locks, new_locks, watched):
    """The report as plain data: {"images": [...], "sources": [...]}."""
    diff = ul.diff_locks(old_locks, new_locks)
    sources = []
    for (src, old_nvr, new_nvr), changes in sorted(ul.group_by_source(diff["packages"]).items()):
        hits = {}
        for c in changes:
            for w in ul.watched_entries(c, watched):
                hits[w["id"]] = w
        kinds = sorted({c["change"] for c in changes})
        sources.append({
            "source": src,
            "old_nvr": old_nvr or None,
            "new_nvr": new_nvr or None,
            "change": kinds[0] if len(kinds) == 1 else "mixed",
            "targets": sorted({t for c in changes for t in c["targets"]}),
            "packages": [{k: c[k] for k in ("name", "arch", "old", "new", "change", "targets")}
                         for c in changes],
            "watched": sorted(hits),
            "why": [hits[k].get("why", "") for k in sorted(hits)],
            "test": [t for k in sorted(hits) for t in hits[k].get("test") or []],
            "recipes": [r for k in sorted(hits) for r in hits[k].get("recipe") or []],
        })
    # Watched first, then by name.
    sources.sort(key=lambda s: (not s["watched"], s["source"]))
    return {"images": diff["images"], "sources": sources}


def add_changelogs(report, helper_image=CHANGELOG_IMAGE):
    """Fill source["changelog"] (entries newer than the old version) for
    upgraded sources, via dnf-helper.py in a fedora container."""
    lock = lockmod()
    wanted, pick = [], {}
    for s in report["sources"]:
        ups = [p for p in s["packages"] if p["new"] and p["old"]]
        if not ups:
            continue
        p = next((p for p in ups if p["name"] == s["source"]), ups[0])
        pick[s["source"], s["new_nvr"]] = p
        wanted.append({"name": p["name"], "evr": p["new"], "arch": p["arch"]})
    if not wanted:
        return report
    subprocess.run([lock.PODMAN, "pull", "-q", helper_image], check=True, stdout=subprocess.DEVNULL)
    res = lock.helper(helper_image, {"cmd": "changelogs", "packages": wanted})["changelogs"]
    for s in report["sources"]:
        p = pick.get((s["source"], s["new_nvr"]))
        if p:
            entries = res.get("%s-%s.%s" % (p["name"], p["new"], p["arch"])) or []
            s["changelog"] = ul.slice_changelog(entries, p["old"])
    return report


def cookbook_url(anchor):
    """Absolute link in GitHub Actions (PR bodies don't resolve relative
    links), repo path otherwise."""
    server, repo = os.environ.get("GITHUB_SERVER_URL"), os.environ.get("GITHUB_REPOSITORY")
    base = "%s/%s/blob/main/" % (server, repo) if server and repo else ""
    return base + ul.COOKBOOK + anchor


def _vers(s):
    old = (s["old_nvr"] or "").replace(s["source"] + "-", "", 1) or "–"
    new = (s["new_nvr"] or "").replace(s["source"] + "-", "", 1) or "–"
    return old, new


def render_markdown(report, limit=PR_BODY_LIMIT):
    srcs = report["sources"]
    watched = [s for s in srcs if s["watched"]]
    out = ["## Fedora package updates", ""]
    fails = report.get("failures") or {}
    if fails:
        out += ["### :x: Targets that no longer resolve (old lock kept)", ""]
        for t, problems in sorted(fails.items()):
            out += ["**%s**" % t, "", "```", problems.strip()[:3000], "```", ""]
    if not srcs and not report["images"]:
        return "\n".join(out + ["No package changes: lock/ is current.", ""])
    out.append("%d source packages changed (%d watched), %d base image digests changed. "
               "Lockfiles: `lock/` (tools/update/, docs/updates.md)."
               % (len(srcs), len(watched), len(report["images"])))
    out.append("")
    if report["images"]:
        out += ["### Base images", "", "| target | image | old → new |", "|---|---|---|"]
        for i in report["images"]:
            o = "%s %s" % ((i["old"] or "–")[:19], i.get("old_version") or "")
            n = "%s %s" % ((i["new"] or "–")[:19], i.get("new_version") or "")
            out.append("| %s | `%s` (%s) | %s → %s |" % (i["target"], i["image"], i["kind"], o.strip(), n.strip()))
        out.append("")
    if watched:
        out += ["### Watched packages: test before merging", ""]
        for s in watched:
            o, n = _vers(s)
            out.append("- **%s** %s → %s (%s; %s)" % (s["source"], o, n, ", ".join(s["watched"]),
                                                     ", ".join(s["targets"])))
            for w in s["why"]:
                out.append("  - why: %s" % w)
            for r in s["recipes"]:
                out.append("  - recipe: [%s](%s)" % (r.lstrip("#"), cookbook_url(r)))
            for t in s["test"]:
                out.append("  - [ ] %s" % t)
        out.append("")
    if any(s["source"] == "kernel" for s in srcs):
        out += ["Kernel changed: the CI `kmods` and `dtbs` jobs on this branch are the "
                "compile-time kernel guard; boot it from RAM before merging.", ""]
    out += ["### All changes", "", "| source | old → new | binaries | targets | watched |",
            "|---|---|---|---|---|"]
    rows = []
    for s in srcs:
        o, n = _vers(s)
        names = sorted({p["name"] for p in s["packages"]})
        bins = ", ".join(names[:6]) + (" +%d" % (len(names) - 6) if len(names) > 6 else "")
        rows.append("| %s | %s → %s | %s | %s | %s |" % (s["source"], o, n, bins, ", ".join(s["targets"]),
                                                    ", ".join(s["watched"]) or "–"))
    text = "\n".join(out)
    for i, r in enumerate(rows):
        if len(text) + len(r) > limit - 200:
            text += "\n\n… %d more rows cut (PR body limit); full list: `check-updates.py --json`." % (len(rows) - i)
            break
        text += "\n" + r
    text += "\n\nRisk review with the local LLM: `tools/update/review-pr.sh <this PR>` (docs/updates.md).\n"
    return text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--write", action="store_true", help="update lock/ in place")
    ap.add_argument("--old", type=Path, help="old lock dir (diff only)")
    ap.add_argument("--new", type=Path, help="new lock dir (diff only)")
    ap.add_argument("--target", action="append", help="only these lock targets")
    ap.add_argument("--changelogs", action="store_true", help="add RPM changelogs (podman)")
    ap.add_argument("--prune-images", action="store_true", help="passed to lock.py (CI)")
    ap.add_argument("--json", type=Path, help="write the JSON report here")
    ap.add_argument("--markdown", type=Path, help="write the Markdown report here")
    args = ap.parse_args(argv)
    lock = lockmod()
    if bool(args.old) != bool(args.new):
        ap.error("--old and --new go together")
    failures = {}
    if args.old:
        old, new = lock.load_locks(args.old), lock.load_locks(args.new)
    else:
        old = lock.load_locks(ul.LOCK_DIR)
        out = ul.LOCK_DIR if args.write else Path(tempfile.mkdtemp(prefix="fap-lock-"))
        largs = ["--out", str(out)] + [a for t in args.target or [] for a in ("--target", t)]
        if args.prune_images:
            largs.append("--prune-images")
        fail_file = Path(tempfile.mkdtemp(prefix="fap-lock-fail-")) / "failures.json"
        largs += ["--failures", str(fail_file)]
        lock.main(largs)
        failures = json.loads(fail_file.read_text(encoding="utf-8")) if fail_file.exists() else {}
        new = lock.load_locks(out)
    if args.target:
        old = {k: v for k, v in old.items() if k in args.target}
        new = {k: v for k, v in new.items() if k in args.target}
    report = build_report(old, new, ul.load_watched())
    report["failures"] = failures
    if args.changelogs:
        add_changelogs(report)
    md = render_markdown(report)
    if args.json:
        args.json.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.write_text(md, encoding="utf-8")
    if not args.json and not args.markdown:
        sys.stdout.write(md)
    print("check-updates: %d source packages changed, %d watched, %d targets unresolvable"
          % (len(report["sources"]), sum(1 for s in report["sources"] if s["watched"]), len(failures)),
          file=sys.stderr)
    # Unresolvable targets are reported (and fail the run) after the report
    # is written, so the PR still shows them.
    return 3 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
