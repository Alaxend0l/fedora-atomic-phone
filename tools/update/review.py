#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Risk review of a package update with a LOCAL LLM (docs/updates.md).

    tools/update/review.py updates.json [--out review.md]

Input: check-updates.py --json. For each changed source package it gathers
public evidence:
  (a) the RPM changelog since our old version (in the JSON, from
      check-updates.py --changelogs),
  (b) Fedora Bodhi: the update for the new build (karma, comments, bugs),
  (c) Red Hat Bugzilla: recent Fedora bugs for the component,
  (d) upstream trackers for watched packages (gitlab.freedesktop.org,
      bugs.kde.org, GitHub), filtered by watched-packages.yaml keywords,
then asks an OpenAI-compatible endpoint (Ollama) for a per-package risk
level with reasons that must cite the evidence IDs, and writes Markdown.

Environment:
  FAP_LLM_URL      default http://localhost:11434/v1 (Ollama)
  FAP_LLM_MODEL    default qwen2.5:14b
  FAP_LLM_TIMEOUT  seconds per request, default 300
  FAP_CACHE        HTTP cache dir, default ~/.cache/fap-update
No API key is sent. If the endpoint isn't reachable, the report has the
evidence without the AI summary. Only public data goes in or out: package
names/versions to the public APIs, public evidence to the local model.

Scope (keeps a weekly run short): Bodhi for every upgraded source package;
Bugzilla, upstream and the LLM for watched packages and for anything Bodhi
flags (negative karma, security bugs, not yet stable). --all reviews all.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import updatelib as ul  # noqa: E402

USER_AGENT = "fap-update-review/1 (Fedora Atomic phone images; tools/update/review.py)"
BODHI = "https://bodhi.fedoraproject.org/updates/"
RH_BUGZILLA = "https://bugzilla.redhat.com/rest/bug"
KDE_BUGZILLA = "https://bugs.kde.org/rest/bug"
GITLAB = "https://gitlab.freedesktop.org/api/v4/projects/%s/issues"
GITHUB_SEARCH = "https://api.github.com/search/issues"
RISKS = ("low", "medium", "high")
MAX_EVIDENCE_CHARS = 7000      # small local models have small contexts


# ------------------------------------------------------------------ HTTP

class Http:
    """GET JSON with a file cache, a user agent, per-host pacing and
    backoff on 429/5xx. Public APIs only; never sends credentials."""

    def __init__(self, cache_dir=None, ttl=12 * 3600, min_interval=1.0, timeout=30, offline=False):
        self.cache = Path(cache_dir or os.environ.get("FAP_CACHE") or Path.home() / ".cache/fap-update")
        self.ttl, self.min_interval, self.timeout, self.offline = ttl, min_interval, timeout, offline
        self.last = {}
        self.errors = []

    def _path(self, url):
        return self.cache / "http" / (hashlib.sha256(url.encode()).hexdigest() + ".json")

    def get_json(self, url):
        p = self._path(url)
        if p.exists() and (self.offline or time.time() - p.stat().st_mtime < self.ttl):
            return json.loads(p.read_text(encoding="utf-8"))
        if self.offline:
            return None
        host = urllib.parse.urlsplit(url).netloc
        for attempt in range(4):
            wait = self.last.get(host, 0) + self.min_interval - time.time()
            if wait > 0:
                time.sleep(wait)
            self.last[host] = time.time()
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                                       "Accept": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    data = json.loads(r.read().decode("utf-8"))
                break
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                    time.sleep(min(60, int(e.headers.get("Retry-After") or 5 * 2 ** attempt)))
                    continue
                self.errors.append("%s: HTTP %s" % (url, e.code))
                return None
            except (urllib.error.URLError, OSError, ValueError) as e:
                self.errors.append("%s: %s" % (url, e))
                return None
        else:
            return None
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(data), encoding="utf-8")
        return data


# ------------------------------------------------------------------ parsers

def _short(text, n=400):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 1] + "…"


def parse_bodhi(data, nvr):
    """Bodhi /updates/?builds=<nvr> -> (summary dict or None, evidence)."""
    ups = (data or {}).get("updates") or []
    if not ups:
        return None, []
    u = ups[0]
    url = u.get("url") or "https://bodhi.fedoraproject.org/updates/%s" % u.get("alias")
    summary = {
        "alias": u.get("alias"), "status": u.get("status"), "type": u.get("type"),
        "severity": u.get("severity"), "karma": u.get("karma"),
        "stable_karma": u.get("stable_karma"), "gating": u.get("test_gating_status"),
        "url": url, "negative": 0, "security_bugs": 0,
    }
    ev = [{"kind": "bodhi", "url": url,
           "title": "Bodhi %s for %s" % (u.get("alias"), nvr),
           "text": "status %s, type %s, severity %s, karma %s (stable at %s), gating %s. Notes: %s"
                   % (u.get("status"), u.get("type"), u.get("severity"), u.get("karma"),
                      u.get("stable_karma"), u.get("test_gating_status"), _short(u.get("notes"), 500))}]
    comments = [c for c in u.get("comments") or []
                if (c.get("user") or {}).get("name") != "bodhi" and (c.get("text") or c.get("karma"))]
    neg = [c for c in comments if (c.get("karma") or 0) < 0]
    summary["negative"] = len(neg)
    shown = neg + [c for c in comments if c not in neg and (c.get("text") or "").strip()]
    for c in shown[:6]:
        ev.append({"kind": "bodhi-comment", "url": url,
                   "title": "Bodhi comment, karma %+d, %s" % (c.get("karma") or 0, (c.get("timestamp") or "")[:10]),
                   "text": _short(c.get("text"), 400)})
    for b in u.get("bugs") or []:
        if b.get("security"):
            summary["security_bugs"] += 1
        ev.append({"kind": "bodhi-bug",
                   "url": "https://bugzilla.redhat.com/show_bug.cgi?id=%s" % b.get("bug_id"),
                   "title": "Bug %s fixed by this update%s" % (b.get("bug_id"), " (security)" if b.get("security") else ""),
                   "text": _short(b.get("title"), 300)})
    return summary, ev


def parse_bugzilla(data, base="https://bugzilla.redhat.com"):
    ev = []
    for b in (data or {}).get("bugs") or []:
        status = b.get("status", "")
        if b.get("resolution"):
            status += "/" + b["resolution"]
        ev.append({"kind": "bugzilla", "url": "%s/show_bug.cgi?id=%s" % (base, b.get("id")),
                   "title": "Bug %s [%s, %s, changed %s]" % (b.get("id"), status, b.get("severity", "?"),
                                                             (b.get("last_change_time") or "")[:10]),
                   "text": _short(b.get("summary"), 300)})
    return ev


def parse_gitlab(data):
    return [{"kind": "upstream", "url": i.get("web_url"),
             "title": "Upstream issue #%s [%s, updated %s] %s" % (i.get("iid"), i.get("state"),
                                                                  (i.get("updated_at") or "")[:10],
                                                                  ",".join(i.get("labels") or [])),
             "text": _short(i.get("title"), 300)} for i in data or [] if isinstance(i, dict)]


def parse_github(data):
    return [{"kind": "upstream", "url": i.get("html_url"),
             "title": "Upstream issue #%s [%s, updated %s]" % (i.get("number"), i.get("state"),
                                                               (i.get("updated_at") or "")[:10]),
             "text": _short(i.get("title"), 300)} for i in (data or {}).get("items") or []]


# ------------------------------------------------------------------ gathering

def since_date(days):
    return time.strftime("%Y-%m-%d", time.gmtime(time.time() - days * 86400))


def gather(source, http, watched_by_id, deep, days=90):
    """Evidence for one source package, numbered E1.. ."""
    ev = []
    for e in source.get("changelog") or []:
        ev.append({"kind": "changelog", "url": None,
                   "title": "Changelog: %s" % _short(e.get("author"), 120),
                   "text": _short(e.get("text"), 600)})
    bodhi = None
    if source.get("new_nvr"):
        url = BODHI + "?" + urllib.parse.urlencode({"builds": source["new_nvr"]})
        bodhi, bev = parse_bodhi(http.get_json(url), source["new_nvr"])
        ev += bev
    if deep:
        q = {"product": "Fedora", "component": source["source"], "version": "45",
             "last_change_time": since_date(days), "order": "changeddate DESC", "limit": "10",
             "include_fields": "id,summary,status,resolution,severity,last_change_time"}
        ev += parse_bugzilla(http.get_json(RH_BUGZILLA + "?" + urllib.parse.urlencode(q)))
        for wid in source.get("watched") or []:
            w = watched_by_id.get(wid) or {}
            up = w.get("upstream") or {}
            for kw in (w.get("keywords") or [])[:4]:
                for proj in up.get("gitlab") or []:
                    u = GITLAB % urllib.parse.quote(proj, safe="") + "?" + urllib.parse.urlencode(
                        {"search": kw, "in": "title", "updated_after": since_date(days), "order_by": "updated_at",
                         "per_page": "5", "state": "opened"})
                    ev += parse_gitlab(http.get_json(u))
                for prod in up.get("kde") or []:
                    u = KDE_BUGZILLA + "?" + urllib.parse.urlencode(
                        {"product": prod, "quicksearch": kw, "last_change_time": since_date(days),
                         "limit": "5", "include_fields": "id,summary,status,resolution,severity,last_change_time"})
                    ev += parse_bugzilla(http.get_json(u), base="https://bugs.kde.org")
                for repo in up.get("github") or []:
                    u = GITHUB_SEARCH + "?" + urllib.parse.urlencode(
                        {"q": 'repo:%s is:issue "%s" updated:>=%s' % (repo, kw, since_date(days)),
                         "per_page": "5", "sort": "updated"})
                    ev += parse_github(http.get_json(u))
    seen, uniq = set(), []
    for e in ev:
        k = (e["kind"], e["url"], e["title"], e["text"])
        if k not in seen:
            seen.add(k)
            uniq.append(e)
    for i, e in enumerate(uniq, 1):
        e["id"] = "E%d" % i
    return bodhi, uniq


def flagged(bodhi):
    return bool(bodhi) and (bodhi["negative"] > 0 or bodhi["security_bugs"] > 0
                            or bodhi["status"] not in ("stable", None))


# ------------------------------------------------------------------ LLM

SYSTEM_PROMPT = """You review Fedora package updates for a phone operating \
system image (Fedora Atomic on a Qualcomm SM4250 phone, Adreno 610 GPU, \
Plasma Mobile). Decide how risky it is to ship the update.

Rules:
- Use ONLY the evidence given. Do not use outside knowledge about bugs, \
versions or fixes. If the evidence doesn't support a claim, don't make it.
- Every reason cites evidence IDs in its "evidence" list, e.g. ["E2","E5"].
- high = evidence of regressions, crashes or breakage relevant to our use \
(our workaround/driver, the "why we care" text), negative karma, or an \
unresolved security problem; medium = large or behaviour-changing update \
touching what we care about, or thin evidence for a watched package; \
low = routine fixes with no negative signals.
- Say when evidence is thin. Be brief.

Answer with JSON only, no prose around it:
{"risk": "low|medium|high", "reasons": [{"text": "...", "evidence": ["E1"]}], \
"test_focus": ["..."]}"""


def build_prompt(source, evidence, max_chars=MAX_EVIDENCE_CHARS):
    o = source.get("old_nvr") or "(new)"
    n = source.get("new_nvr") or "(removed)"
    lines = ["Package: %s" % source["source"], "Update: %s -> %s" % (o, n),
             "Images: %s" % ", ".join(source.get("targets") or [])]
    if source.get("why"):
        lines.append("Why we care: %s" % " / ".join(source["why"]))
    if source.get("test"):
        lines.append("What we test: %s" % " / ".join(source["test"]))
    lines += ["", "Evidence:"]
    used = sum(len(l) for l in lines)
    for e in evidence:
        line = "[%s] (%s) %s: %s" % (e["id"], e["kind"], e["title"], e["text"])
        if used + len(line) > max_chars:
            lines.append("(%d more evidence items omitted for length)" % (len(evidence) - evidence.index(e)))
            break
        lines.append(line)
        used += len(line)
    if not evidence:
        lines.append("(none found)")
    return "\n".join(lines)


class LLM:
    def __init__(self, url=None, model=None, timeout=None):
        self.url = (url or os.environ.get("FAP_LLM_URL") or "http://localhost:11434/v1").rstrip("/")
        self.model = model or os.environ.get("FAP_LLM_MODEL") or "qwen2.5:14b"
        self.timeout = float(timeout or os.environ.get("FAP_LLM_TIMEOUT") or 300)

    def _post(self, path, body, timeout):
        req = urllib.request.Request(self.url + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))

    def available(self):
        try:
            with urllib.request.urlopen(self.url + "/models", timeout=5) as r:
                json.loads(r.read().decode("utf-8"))
            return True, None
        except (urllib.error.URLError, OSError, ValueError) as e:
            return False, str(e)

    def chat(self, system, user):
        body = {"model": self.model, "temperature": 0,
                "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": system},
                             {"role": "user", "content": user}]}
        data = self._post("/chat/completions", body, self.timeout)
        return data["choices"][0]["message"]["content"]


def parse_assessment(text, evidence_ids):
    """Validate the model's JSON. Reasons citing no known evidence ID are
    dropped (counted in "dropped"); an unknown risk becomes "unknown"."""
    text = (text or "").strip()
    m = re.search(r"\{.*\}", text, re.S)
    try:
        data = json.loads(m.group(0) if m else text)
    except ValueError:
        return {"risk": "unknown", "reasons": [], "test_focus": [], "dropped": 0,
                "error": "model did not return JSON", "raw": _short(text, 500)}
    risk = str(data.get("risk", "")).lower().strip()
    reasons, dropped = [], 0
    for r in data.get("reasons") or []:
        if isinstance(r, str):
            r = {"text": r, "evidence": re.findall(r"E\d+", r)}
        cites = [c for c in (r.get("evidence") or []) if c in evidence_ids]
        cites += [c for c in re.findall(r"E\d+", r.get("text", "")) if c in evidence_ids and c not in cites]
        if cites:
            reasons.append({"text": str(r.get("text", "")).strip(), "evidence": cites})
        else:
            dropped += 1
    return {"risk": risk if risk in RISKS else "unknown", "reasons": reasons,
            "test_focus": [str(t) for t in data.get("test_focus") or []][:5], "dropped": dropped}


def assess(llm, source, evidence):
    ids = {e["id"] for e in evidence}
    prompt = build_prompt(source, evidence)
    last = None
    for _ in range(2):                       # one retry on unusable output
        try:
            a = parse_assessment(llm.chat(SYSTEM_PROMPT, prompt), ids)
        except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError) as e:
            return {"risk": "unknown", "reasons": [], "test_focus": [], "dropped": 0,
                    "error": "LLM request failed: %s" % e}
        if a["risk"] != "unknown":
            return a
        last = a
    return last


# ------------------------------------------------------------------ output

def render(results, llm_note, http_errors, model):
    out = ["## Update risk review", "",
           "Generated by `tools/update/review.py` with a local model (%s). %s" % (model, llm_note),
           "The AI only saw the evidence listed below (public data); reasons that cite no evidence "
           "are dropped. It is a reading aid, not a test: watched packages still need the tests "
           "in the PR description.", ""]
    rated = [r for r in results if r.get("assessment")]
    if rated:
        out += ["| package | update | risk | watched |", "|---|---|---|---|"]
        order = {"high": 0, "medium": 1, "unknown": 2, "low": 3}
        for r in sorted(rated, key=lambda r: (order.get(r["assessment"]["risk"], 2), r["source"]["source"])):
            s = r["source"]
            out.append("| %s | %s → %s | **%s** | %s |" % (s["source"], s.get("old_nvr") or "–",
                                                         s.get("new_nvr") or "–", r["assessment"]["risk"],
                                                         ", ".join(s.get("watched") or []) or "–"))
        out.append("")
    for r in results:
        s, a, ev, b = r["source"], r.get("assessment"), r["evidence"], r.get("bodhi")
        if not (a or s.get("watched") or (b and flagged(b))):
            continue
        out.append("### %s %s → %s" % (s["source"], s.get("old_nvr") or "–", s.get("new_nvr") or "–"))
        if a:
            out.append("**Risk: %s**%s" % (a["risk"], " (%s)" % a["error"] if a.get("error") else ""))
            byid = {e["id"]: e for e in ev}
            for reason in a["reasons"]:
                refs = ", ".join("[%s](%s)" % (c, byid[c]["url"]) if byid[c].get("url") else c
                                 for c in reason["evidence"])
                out.append("- %s (%s)" % (reason["text"], refs))
            if a.get("dropped"):
                out.append("- _%d reason(s) dropped: no valid evidence cited_" % a["dropped"])
            for t in a.get("test_focus") or []:
                out.append("- test: %s" % t)
        else:
            out.append("_No AI assessment._")
        if ev:
            out += ["", "<details><summary>Evidence (%d)</summary>" % len(ev), ""]
            for e in ev:
                link = " [link](%s)" % e["url"] if e.get("url") else ""
                out.append("- **%s** %s: %s%s" % (e["id"], e["title"], e["text"], link))
            out += ["", "</details>"]
        out.append("")
    quiet = [r for r in results if not (r.get("assessment") or r["source"].get("watched")
                                        or (r.get("bodhi") and flagged(r["bodhi"])))]
    if quiet:
        out.append("### Other updates (no watched package, no Bodhi warning signs)")
        out.append("")
        for r in quiet:
            s, b = r["source"], r.get("bodhi")
            tag = "Bodhi %s, karma %s" % (b["status"], b["karma"]) if b else "no Bodhi update found"
            out.append("- %s %s → %s (%s)" % (s["source"], s.get("old_nvr") or "–", s.get("new_nvr") or "–", tag))
        out.append("")
    if http_errors:
        out += ["<details><summary>%d request(s) failed</summary>" % len(http_errors), ""]
        out += ["- %s" % e for e in http_errors[:20]]
        out += ["", "</details>", ""]
    out.append("<!-- fap-update-review -->")
    return "\n".join(out) + "\n"


def review(report, http, llm, watched, review_all=False, max_sources=80, log=sys.stderr):
    ok, why = llm.available() if llm else (False, "disabled (--no-llm)")
    llm_note = ("Endpoint %s reachable." % llm.url) if ok else (
        "**AI summary unavailable** (%s): evidence only." % why)
    watched_by_id = {w["id"]: w for w in watched}
    results = []
    for s in report["sources"][:max_sources]:
        deep = review_all or bool(s.get("watched"))
        bodhi, ev = gather(s, http, watched_by_id, deep)
        if not deep and flagged(bodhi):
            bodhi, ev = gather(s, http, watched_by_id, True)
        r = {"source": s, "bodhi": bodhi, "evidence": ev}
        if ok and (deep or flagged(bodhi)):
            print("review: asking %s about %s (%d evidence items)" % (llm.model, s["source"], len(ev)), file=log)
            r["assessment"] = assess(llm, s, ev)
        results.append(r)
    return render(results, llm_note, http.errors, llm.model if llm else "none")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("report", type=Path, help="check-updates.py --json output")
    ap.add_argument("--out", type=Path, help="write Markdown here (default stdout)")
    ap.add_argument("--all", action="store_true", help="deep review + LLM for every package")
    ap.add_argument("--no-llm", action="store_true", help="evidence only")
    ap.add_argument("--offline", action="store_true", help="use only cached HTTP responses")
    ap.add_argument("--max-sources", type=int, default=80)
    args = ap.parse_args(argv)
    report = json.loads(args.report.read_text(encoding="utf-8"))
    md = review(report, Http(offline=args.offline), None if args.no_llm else LLM(),
                ul.load_watched(), review_all=args.all, max_sources=args.max_sources)
    if args.out:
        args.out.write_text(md, encoding="utf-8")
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
