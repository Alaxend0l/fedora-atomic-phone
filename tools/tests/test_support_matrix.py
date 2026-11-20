# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/support-matrix.py (needs PyYAML).

    python3 -m unittest discover -s tools/tests
"""
import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("support_matrix", REPO / "tools/support-matrix.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)


class SupportMatrix(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for d in ["tools", "devices", "boot", "docs"]:
            (self.tmp / d).mkdir()
        for f in ["new-device.sh", "check-device.sh", "support-matrix.py"]:
            shutil.copy2(REPO / "tools" / f, self.tmp / "tools" / f)
        shutil.copytree(REPO / "devices/_template", self.tmp / "devices/_template")
        for m in (REPO / "boot").iterdir():
            if m.is_dir():
                (self.tmp / "boot" / m.name).mkdir()
        subprocess.run([self.tmp / "tools/new-device.sh", "--soc", "qcom-x", "acme-road", "Acme Road"],
                       check=True, capture_output=True, env={"PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                                                            "FAP_DATE": "2026-01-02"})
        self.feat = self.tmp / "devices/acme-road/features.yaml"

    def render(self):
        return sm.render(self.tmp)

    def test_scaffold_renders(self):
        text = self.render()
        self.assertIn("`acme-road`", text)
        self.assertIn("| Acme Road |", text)
        self.assertIn("0/46", text)

    def test_template_skipped(self):
        self.assertNotIn("`_template`", self.render())

    def test_repo_devices_valid_and_doc_current(self):
        self.assertEqual(sm.main(["--check", "--root", str(REPO)]), 0)

    def edit(self, old, new, path=None):
        path = path or self.feat
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1))

    def assertInvalid(self, pattern):
        with self.assertRaisesRegex(sm.Invalid, pattern):
            self.render()

    def test_bad_status(self):
        self.edit("status: untested", "status: maybe")
        self.assertInvalid("status 'maybe'")

    def test_missing_feature(self):
        text = self.feat.read_text().splitlines(keepends=True)
        self.feat.write_text("".join(l for l in text if not l.strip().startswith("gnss:")))
        self.assertInvalid(r"missing \['gnss'\]")

    def test_unknown_feature(self):
        self.edit("    gnss:", "    teleport: {status: works}\n    gnss:")
        self.assertInvalid(r"unknown \['teleport'\]")

    def test_wrong_device_name(self):
        self.edit('device: "acme-road"', 'device: "acme-other"')
        self.assertInvalid("folder is 'acme-road'")

    def test_evidence_path_must_exist(self):
        self.edit('evidence: ""', 'evidence: "docs/nope.md"')
        self.assertInvalid("doesn't exist")

    def test_evidence_commit_and_url(self):
        self.edit('evidence: ""', 'evidence: "02fa6df"')
        self.edit('evidence: ""', 'evidence: "https://example.org/x"')
        text = self.render()
        self.assertIn("`02fa6df`", text)
        self.assertIn("[link](https://example.org/x)", text)

    def test_unquoted_numeric_hash_rejected(self):
        self.edit('evidence: ""', "evidence: 1234567")
        self.assertInvalid("quote commit hashes")

    def test_firmware_redistributable_bool(self):
        fw = self.tmp / "devices/acme-road/firmware.yaml"
        self.edit("redistributable: false", "redistributable: maybe", fw)
        self.assertInvalid("redistributable must be true or false")

    def test_check_mode(self):
        self.assertEqual(sm.main(["--check", "--root", str(self.tmp)]), 1)
        self.assertEqual(sm.main(["--root", str(self.tmp)]), 0)
        self.assertEqual(sm.main(["--check", "--root", str(self.tmp)]), 0)


if __name__ == "__main__":
    unittest.main()
