#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Runs INSIDE a Fedora container (needs python3-libdnf5); lock.py and
check-updates.py start it with podman. Reads a JSON request on stdin, writes
JSON on stdout. Never installs anything: it only resolves.

    {"cmd": "resolve", "installroot": "/tmp/root", "releasever": "45",
     "weak_deps": true,
     "steps": [{"action": "install"|"remove", "specs": ["pkg", "@group"]}]}
    -> {"packages": [...installed/upgraded...], "removed": [...],
        "base": [...already installed...], "problems": [...], "ok": bool}

    {"cmd": "changelogs", "packages": [{"name": .., "evr": .., "arch": ..}]}
    -> {"changelogs": {"name-evr.arch": [{"timestamp", "author", "text"}]}}

`installroot` holds a copy of the target image's rpmdb, so the resolution
is "what would our build steps do on top of that base image", without the
python3-libdnf5 we had to install to run this.
"""
import json
import sys

import libdnf5

ACTIONS = {
    libdnf5.transaction.TransactionItemAction_INSTALL: "install",
    libdnf5.transaction.TransactionItemAction_UPGRADE: "upgrade",
    libdnf5.transaction.TransactionItemAction_DOWNGRADE: "downgrade",
    libdnf5.transaction.TransactionItemAction_REINSTALL: "reinstall",
    libdnf5.transaction.TransactionItemAction_REMOVE: "remove",
    libdnf5.transaction.TransactionItemAction_REPLACED: "replaced",
}


def make_base(req, other_metadata=False):
    base = libdnf5.base.Base()
    base.load_config()
    cfg = base.get_config()
    if req.get("installroot"):
        cfg.installroot = req["installroot"]
        cfg.use_host_config = True
    cfg.install_weak_deps = bool(req.get("weak_deps", True))
    if other_metadata:
        cfg.get_optional_metadata_types_option().add_item(
            libdnf5.conf.Option.Priority_RUNTIME, "other")
    if req.get("releasever"):
        base.get_vars().set("releasever", str(req["releasever"]))
    base.setup()
    sack = base.get_repo_sack()
    sack.create_repos_from_system_configuration()
    # Never resolve against updates-testing etc.: only what a build gets.
    sack.load_repos()
    return base


def pkg_record(p):
    cs = p.get_checksum()
    return {
        "name": p.get_name(),
        "evr": p.get_evr(),
        "arch": p.get_arch(),
        "repo": p.get_repo_id(),
        "source": p.get_sourcerpm(),
        "checksum": "%s:%s" % (cs.get_type_str(), cs.get_checksum()),
        "size": p.get_download_size(),
        "location": p.get_location(),
    }


def resolve(req):
    base = make_base(req)
    goal = libdnf5.base.Goal(base)
    # `dnf5 remove X` also removes what depends on X; in one combined
    # transaction that needs allow_erasing.
    if any(st["action"] == "remove" for st in req["steps"]):
        goal.set_allow_erasing(True)
    for step in req["steps"]:
        settings = libdnf5.base.GoalJobSettings()
        settings.skip_unavailable = step["action"] == "remove"
        for spec in step["specs"]:
            if step["action"] == "install":
                goal.add_install(spec, settings)
            elif step["action"] == "remove":
                goal.add_remove(spec, settings)
            else:
                raise SystemExit("dnf-helper: unknown action %r" % step["action"])
    tr = goal.resolve()
    problems = list(tr.get_resolve_logs_as_strings())
    if tr.get_problems() != libdnf5.base.GoalProblem_NO_PROBLEM:
        return {"packages": [], "removed": [], "problems": problems, "ok": False}
    packages, removed = [], []
    for tp in tr.get_transaction_packages():
        action = ACTIONS.get(tp.get_action(), str(tp.get_action()))
        p = tp.get_package()
        if action in ("remove", "replaced"):
            removed.append({"name": p.get_name(), "evr": p.get_evr(),
                            "arch": p.get_arch(), "action": action})
        else:
            rec = pkg_record(p)
            if action != "install":
                rec["action"] = action
            packages.append(rec)
    installed = []
    q = libdnf5.rpm.PackageQuery(base)
    q.filter_installed()
    for p in q:
        installed.append({"name": p.get_name(), "evr": p.get_evr(),
                          "arch": p.get_arch(), "source": p.get_sourcerpm()})
    key = lambda r: (r["name"], r["arch"], r["evr"])  # noqa: E731
    return {"packages": sorted(packages, key=key), "removed": sorted(removed, key=key),
            "base": sorted(installed, key=key), "problems": problems, "ok": True}


def changelogs(req):
    base = make_base(req, other_metadata=True)
    out = {}
    for want in req["packages"]:
        q = libdnf5.rpm.PackageQuery(base)
        q.filter_name([want["name"]])
        q.filter_evr([want["evr"]])
        if want.get("arch"):
            q.filter_arch([want["arch"]])
        q.filter_available()
        entries = []
        for p in q:
            entries = [{"timestamp": c.get_timestamp(), "author": c.get_author(),
                        "text": c.get_text()} for c in p.get_changelogs()]
            break
        out["%s-%s.%s" % (want["name"], want["evr"], want.get("arch", ""))] = entries
    return {"changelogs": out}


def main():
    req = json.load(sys.stdin)
    fn = {"resolve": resolve, "changelogs": changelogs}.get(req.get("cmd"))
    if not fn:
        raise SystemExit("dnf-helper: unknown cmd %r" % req.get("cmd"))
    json.dump(fn(req), sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
