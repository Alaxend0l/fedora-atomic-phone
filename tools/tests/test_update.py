# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/update/ (docs/updates.md): version comparison, step
extraction, lock diffing, changelog slicing, the report, API parsing
against recorded fixtures, and review.py against a fake OpenAI-compatible
server. No network, no podman, no phone. Needs PyYAML.

    python3 -m unittest discover -s tools/tests
"""
import http.server
import importlib.util
import io
import json
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIX = Path(__file__).resolve().parent / "fixtures/update"
sys.path.insert(0, str(REPO / "tools/update"))
import updatelib as ul  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, REPO / "tools/update" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lock = load("lock", "lock.py")
check = load("check_updates", "check-updates.py")
review = load("review", "review.py")


def fixture(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


def pkg(name, evr, source=None, arch="aarch64", **kw):
    d = {"name": name, "evr": evr, "arch": arch,
         "source": source or "%s-%s.src.rpm" % (name, evr.split(":")[-1])}
    d.update(kw)
    return d


class Versions(unittest.TestCase):
    def test_rpmvercmp(self):
        cases = [("1.0", "1.0", 0), ("1.0", "1.1", -1), ("1.10", "1.9", 1),
                 ("1.0~rc1", "1.0", -1), ("1.0^git1", "1.0", 1), ("1.0^git1", "1.0.1", -1),
                 ("2.0a", "2.0", 1), ("1.0a", "1.0b", -1), ("1", "a", 1),
                 ("010", "10", 0), ("5.3.15", "5.3.9", 1), ("1.0~rc1", "1.0~rc2", -1)]
        for a, b, want in cases:
            with self.subTest(a=a, b=b):
                self.assertEqual(ul.rpmvercmp(a, b), want)
                self.assertEqual(ul.rpmvercmp(b, a), -want)

    def test_evrcmp(self):
        self.assertEqual(ul.evrcmp("1:1.0-1", "2.0-1"), 1)
        self.assertEqual(ul.evrcmp("710-2.fc45", "710-1.fc45"), 1)
        self.assertEqual(ul.evrcmp("7.3.4-300.fc45", "7.3.10-200.fc45"), -1)

    def test_source_names(self):
        self.assertEqual(ul.source_nvr("mesa-26.2.7-1.fc45.src.rpm"), "mesa-26.2.7-1.fc45")
        self.assertEqual(ul.source_name("linux-firmware-20261019-1.fc45.src.rpm"), "linux-firmware")


class Extract(unittest.TestCase):
    def test_containerfile_and_shell(self):
        text = """\
# dnf5 install commented-out
RUN dnf5 -y install --setopt=install_weak_deps=False \\
        a b \\
        c \\
    && dnf5 clean all
dnf5 -y remove firefox firefox-langpacks || true
dnf5 -y install "$KERNEL_PACKAGE" @kde-mobile-environment
dnf5 -y install x; dnf5 -y install y
"""
        steps = lock.extract_steps(text, "f")
        self.assertEqual([(s["action"], s["specs"], s["weak_deps"]) for s in steps], [
            ("install", ["a", "b", "c"], False),
            ("remove", ["firefox", "firefox-langpacks"], True),
            ("install", ["@kde-mobile-environment"], True),
            ("install", ["x"], True), ("install", ["y"], True)])
        self.assertEqual(steps[0]["where"], "f:2")
        self.assertEqual(steps[2]["skipped"], ["$KERNEL_PACKAGE"])

    def test_repo_targets_extract(self):
        targets = ul.load_yaml(lock.TARGETS)["targets"]
        for name, t in targets.items():
            with self.subTest(target=name):
                steps = lock.target_steps(t)
                self.assertTrue(any(s["action"] == "install" and s["specs"] for s in steps))
                for s in steps:
                    self.assertEqual(s["skipped"], [], s["where"])

    def test_bootc_sources_follow_device_env(self):
        srcs = lock.target_sources({"device": "oneplus-billie2", "desktop": "tty"})
        self.assertEqual(srcs[0], "base/build")
        self.assertEqual(srcs[-1], "devices/oneplus-billie2/build")


def make_lock(target, base, layer, removed=(), digest="sha256:a", kernel=None):
    d = {"target": target, "base": {"image": "img:45", "digest": digest, "packages": list(base)},
         "packages": list(layer), "removed": list(removed)}
    if kernel is not None:
        d["kernel_image"] = {"image": "k:45", "digest": "sha256:k", "packages": kernel}
    return d


class Diff(unittest.TestCase):
    def setUp(self):
        self.old = {"t1": make_lock("t1", [pkg("bash", "5.3-1"), pkg("gdm", "51-1")],
                                    [pkg("mesa-dri-drivers", "26.2.6-1.fc45", "mesa-26.2.6-1.fc45.src.rpm"),
                                     pkg("gone", "1-1")],
                                    removed=[pkg("gdm", "51-1")],
                                    kernel=[pkg("kernel-core", "7.3.4-300.fc45", "kernel-7.3.4-300.fc45.src.rpm")])}
        self.new = {"t1": make_lock("t1", [pkg("bash", "5.3-1"), pkg("gdm", "51-2")],
                                    [pkg("mesa-dri-drivers", "26.2.7-1.fc45", "mesa-26.2.7-1.fc45.src.rpm"),
                                     pkg("fresh", "2-1")],
                                    removed=[pkg("gdm", "51-2")], digest="sha256:b",
                                    kernel=[pkg("kernel-core", "7.3.5-300.fc45", "kernel-7.3.5-300.fc45.src.rpm")])}

    def test_diff(self):
        d = ul.diff_locks(self.old, self.new)
        by = {c["name"]: c for c in d["packages"]}
        self.assertEqual(set(by), {"mesa-dri-drivers", "gone", "fresh", "kernel-core"})
        self.assertEqual((by["mesa-dri-drivers"]["old"], by["mesa-dri-drivers"]["new"],
                          by["mesa-dri-drivers"]["change"], by["mesa-dri-drivers"]["source"]),
                         ("26.2.6-1.fc45", "26.2.7-1.fc45", "upgraded", "mesa"))
        self.assertEqual(by["gone"]["change"], "removed")
        self.assertEqual(by["fresh"]["change"], "added")
        self.assertEqual(by["kernel-core"]["change"], "upgraded")   # from kernel_image
        self.assertEqual(d["images"][0]["new"], "sha256:b")

    def test_no_change(self):
        self.assertEqual(ul.diff_locks(self.old, self.old), {"packages": [], "images": []})

    def test_installonly_versions(self):
        old = {"t": make_lock("t", [pkg("kernel-core", "7.3.3-1"), pkg("kernel-core", "7.3.4-1")], [])}
        new = {"t": make_lock("t", [pkg("kernel-core", "7.3.4-1"), pkg("kernel-core", "7.3.5-1")], [])}
        c = ul.diff_locks(old, new)["packages"][0]
        self.assertEqual((c["old"], c["new"], c["old_versions"]), ("7.3.4-1", "7.3.5-1", ["7.3.3-1", "7.3.4-1"]))

    def test_report_and_markdown(self):
        watched = ul.load_watched()
        r = check.build_report(self.old, self.new, watched)
        names = [s["source"] for s in r["sources"]]
        self.assertEqual(names[:2], ["kernel", "mesa"])          # watched first
        mesa = r["sources"][1]
        self.assertEqual(mesa["watched"], ["mesa"])
        self.assertTrue(any("noubwc" in t for t in mesa["test"]))
        self.assertTrue(mesa["recipes"][0].startswith("#"))
        md = check.render_markdown(r)
        self.assertIn("mesa", md)
        self.assertIn("26.2.6-1.fc45 → 26.2.7-1.fc45", md)
        self.assertIn("kernel guard", md)
        self.assertIn("porting-cookbook.md#gpu-renders-tile-garbage-ubwc", md)
        small = check.render_markdown(r, limit=900)
        self.assertIn("more rows cut", small)

    def test_failures_in_markdown(self):
        r = check.build_report({}, {}, [])
        r["failures"] = {"oneplus-billie2-phosh": "No match for argument: squeekboard"}
        md = check.render_markdown(r)
        self.assertIn("no longer resolve", md)
        self.assertIn("squeekboard", md)

    def test_watched_matching(self):
        w = ul.load_watched()
        hit = lambda name, src="": [e["id"] for e in ul.watched_entries({"name": name, "source": src}, w)]  # noqa: E731
        self.assertEqual(hit("mesa-vulkan-drivers", "mesa"), ["mesa"])
        self.assertEqual(hit("kernel-modules-core", "kernel"), ["kernel"])
        self.assertEqual(hit("python3-gbinder"), ["waydroid"])
        self.assertEqual(hit("atheros-firmware", "linux-firmware"), ["firmware"])
        self.assertEqual(hit("bash", "bash"), [])

    def test_watched_recipes_exist(self):
        cookbook = (REPO / ul.COOKBOOK).read_text(encoding="utf-8")
        import re
        anchors = set()
        for h in re.findall(r"^#+ (.+)$", cookbook, re.M):
            a = re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-")
            anchors.add("#" + a)
        for w in ul.load_watched():
            for r in w.get("recipe") or []:
                with self.subTest(recipe=r):
                    # Computed from a heading, or used by the cookbook's own
                    # contents list (headings with e.g. a non-breaking hyphen).
                    self.assertTrue(r in anchors or "(%s)" % r in cookbook, r)


class Changelog(unittest.TestCase):
    ENTRIES = [  # libdnf5 order: oldest first
        {"timestamp": 100, "author": "A <a@x> - 692-6", "text": "- old"},
        {"timestamp": 200, "author": "A <a@x> - 710-1", "text": "- update to 710"},
        {"timestamp": 300, "author": "B <b@x> - 710-2", "text": "- fix lesspipe"},
        {"timestamp": 400, "author": "C <c@x> - 1:711-1", "text": "- epoch bump"},
    ]

    def test_slice(self):
        got = ul.slice_changelog(self.ENTRIES, "710-1.fc45")
        self.assertEqual([e["text"] for e in got], ["- epoch bump", "- fix lesspipe"])

    def test_new_package(self):
        self.assertEqual(len(ul.slice_changelog(self.ENTRIES, None)), 4)
        self.assertEqual(len(ul.slice_changelog(self.ENTRIES, None, limit=2)), 2)

    def test_author_evr(self):
        self.assertEqual(ul.changelog_evr("Jane <j@x.org> - 26.2.7-1"), "26.2.7-1")
        self.assertIsNone(ul.changelog_evr("Jane <j@x.org>"))


class Output(unittest.TestCase):
    def test_versionlock_and_env(self):
        l = make_lock("t", [], [pkg("a", "1-1"), pkg("b", "1:2-3", arch="noarch"), pkg("a", "1-1", arch="noarch")])
        l["base"]["pinned"] = "img@sha256:a"
        toml = lock.versionlock_toml(l)
        self.assertIn("SPDX-License-Identifier", toml.splitlines()[0])
        self.assertEqual(toml.count("[[packages]]"), 2)
        self.assertIn('value = "1:2-3"', toml)
        try:
            import tomllib
        except ImportError:   # Python < 3.11
            return
        parsed = tomllib.loads(toml)
        self.assertEqual([p["name"] for p in parsed["packages"]], ["a", "b"])
        self.assertIn("BASE_IMAGE=img@sha256:a", lock.images_env(l))

    def test_committed_locks_load(self):
        locks = lock.load_locks(ul.LOCK_DIR)
        self.assertIn("netroot", locks)
        for name, l in locks.items():
            with self.subTest(lock=name):
                self.assertTrue(l["base"]["digest"].startswith("sha256:"))
                self.assertTrue((ul.LOCK_DIR / ("%s.versionlock.toml" % name)).exists())


class Parsers(unittest.TestCase):
    def test_bodhi(self):
        summary, ev = review.parse_bodhi(fixture("bodhi.json"), "less-710-2.fc45")
        self.assertEqual(summary["alias"], "FEDORA-2026-360e7c14e7")
        self.assertEqual(summary["status"], "stable")
        self.assertEqual(summary["negative"], 1)
        self.assertEqual(summary["security_bugs"], 1)
        kinds = [e["kind"] for e in ev]
        self.assertEqual(kinds[0], "bodhi")
        self.assertIn("bodhi-bug", kinds)
        self.assertTrue(any("karma -1" in e["title"] for e in ev))     # negative comments first
        self.assertFalse(any("submitted for testing" in e["text"] for e in ev))   # bot comments dropped
        self.assertTrue(review.flagged(summary))

    def test_bodhi_empty(self):
        self.assertEqual(review.parse_bodhi({"updates": []}, "x-1-1"), (None, []))

    def test_bugzilla(self):
        ev = review.parse_bugzilla(fixture("bugzilla.json"))
        self.assertTrue(ev and ev[0]["url"].startswith("https://bugzilla.redhat.com/show_bug.cgi?id="))
        kde = review.parse_bugzilla(fixture("kde.json"), base="https://bugs.kde.org")
        self.assertTrue(kde[0]["url"].startswith("https://bugs.kde.org/"))

    def test_gitlab_github(self):
        gl = review.parse_gitlab(fixture("gitlab.json")["issues"])
        self.assertIn("gitlab.freedesktop.org", gl[0]["url"])
        gh = review.parse_github(fixture("github.json"))
        self.assertTrue(any("2422" in e["title"] for e in gh))

    def test_assessment_validation(self):
        ids = {"E1", "E2"}
        a = review.parse_assessment('```json\n{"risk": "HIGH", "reasons": ['
                                    '{"text": "negative karma", "evidence": ["E2"]},'
                                    '{"text": "made up", "evidence": ["E9"]},'
                                    '"plain string citing E1"], "test_focus": ["boot"]}\n```', ids)
        self.assertEqual(a["risk"], "high")
        self.assertEqual([r["evidence"] for r in a["reasons"]], [["E2"], ["E1"]])
        self.assertEqual(a["dropped"], 1)
        bad = review.parse_assessment("I think it's fine", ids)
        self.assertEqual(bad["risk"], "unknown")


class FakeHttp(review.Http):
    """Serves recorded fixtures by URL prefix instead of the network."""
    ROUTES = [(review.BODHI, "bodhi.json"), (review.RH_BUGZILLA, "bugzilla.json"),
              (review.KDE_BUGZILLA, "kde.json"), ("https://gitlab.freedesktop.org/", "gitlab.json"),
              (review.GITHUB_SEARCH, "github.json")]

    def __init__(self):
        super().__init__(cache_dir=tempfile.mkdtemp())
        self.urls = []

    def get_json(self, url):
        self.urls.append(url)
        for prefix, name in self.ROUTES:
            if url.startswith(prefix):
                data = fixture(name)
                return data["issues"] if name == "gitlab.json" else data
        return None


class FakeLLM(http.server.BaseHTTPRequestHandler):
    requests = []
    reply = {"risk": "medium", "reasons": [
        {"text": "one negative Bodhi comment", "evidence": ["E2"]},
        {"text": "invented claim", "evidence": ["E999"]}], "test_focus": ["render a frame"]}

    def log_message(self, *a):
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send({"object": "list", "data": [{"id": "fake:1b"}]})

    def do_POST(self):
        n = int(self.headers["Content-Length"])
        FakeLLM.requests.append((self.path, self.headers.get("Authorization"),
                                 json.loads(self.rfile.read(n))))
        self._send({"choices": [{"message": {"role": "assistant",
                                             "content": json.dumps(FakeLLM.reply)}}]})


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Review(unittest.TestCase):
    REPORT = {"images": [], "sources": [
        {"source": "less", "old_nvr": "less-710-1.fc45", "new_nvr": "less-710-2.fc45",
         "targets": ["netroot"], "packages": [], "watched": [], "why": [], "test": [], "recipes": [],
         "changelog": [{"timestamp": 3, "author": "B <b@x> - 710-2", "text": "- fix lesspipe"}]},
        {"source": "mesa", "old_nvr": "mesa-26.2.6-1.fc45", "new_nvr": "mesa-26.2.7-1.fc45",
         "targets": ["installroot"], "packages": [], "watched": ["mesa"],
         "why": ["Adreno 610"], "test": ["noubwc"], "recipes": []}]}

    def setUp(self):
        FakeLLM.requests = []
        self.server = http.server.HTTPServer(("127.0.0.1", 0), FakeLLM)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = "http://127.0.0.1:%d/v1" % self.server.server_port

    def test_review_with_fake_llm(self):
        http_ = FakeHttp()
        llm = review.LLM(url=self.url, model="fake:1b", timeout=10)
        md = review.review(self.REPORT, http_, llm, ul.load_watched(), log=io.StringIO())
        # less is flagged by its Bodhi fixture (negative karma), mesa is watched.
        self.assertEqual(len(FakeLLM.requests), 2)
        path, auth, body = FakeLLM.requests[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertIsNone(auth)                                  # no API key sent
        self.assertEqual(body["model"], "fake:1b")
        self.assertEqual(body["temperature"], 0)
        self.assertIn("ONLY the evidence", body["messages"][0]["content"])
        self.assertIn("[E1] (changelog)", body["messages"][1]["content"])
        self.assertIn("**medium**", md)
        self.assertIn("one negative Bodhi comment", md)
        self.assertNotIn("invented claim", md)
        self.assertIn("1 reason(s) dropped", md)
        self.assertIn("<!-- fap-update-review -->", md)
        # Upstream searches only for the watched package, with its keywords.
        self.assertTrue(any("gitlab.freedesktop.org" in u and "freedreno" in u for u in http_.urls))
        self.assertTrue(any("component=mesa" in u for u in http_.urls))

    def test_llm_unreachable(self):
        llm = review.LLM(url="http://127.0.0.1:%d/v1" % free_port(), timeout=2)
        md = review.review(self.REPORT, FakeHttp(), llm, ul.load_watched(), log=io.StringIO())
        self.assertIn("AI summary unavailable", md)
        self.assertIn("fix lesspipe", md)           # evidence still there
        self.assertNotIn("**Risk:", md)

    def test_http_cache(self):
        hits = []

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                hits.append(self.headers.get("User-Agent"))
                body = b'{"ok": 1}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        cache = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, cache)
        h = review.Http(cache_dir=cache, min_interval=0)
        url = "http://127.0.0.1:%d/x" % srv.server_port
        self.assertEqual(h.get_json(url), {"ok": 1})
        self.assertEqual(h.get_json(url), {"ok": 1})
        self.assertEqual(len(hits), 1)                           # second from cache
        self.assertTrue(hits[0].startswith("fap-update-review/"))
        self.assertEqual(review.Http(cache_dir=cache, offline=True).get_json(url), {"ok": 1})


if __name__ == "__main__":
    unittest.main()
