#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]


class StaticConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dockerfile = (ROOT_DIR / "Dockerfile").read_text(encoding="utf-8")
        cls.exporter_dockerfile = (ROOT_DIR / "exporter" / "Dockerfile").read_text(encoding="utf-8")
        cls.ocserv_template = (ROOT_DIR / "config" / "ocserv.conf.template").read_text(encoding="utf-8")

    def test_ocserv_seccomp_build_support_is_disabled(self):
        self.assertNotIn("libseccomp-dev", self.dockerfile)
        self.assertNotIn("-Dseccomp=enabled", self.dockerfile)
        self.assertEqual(2, self.dockerfile.count("-Dseccomp=disabled"))

    def test_worker_isolation_defaults_to_disabled(self):
        enabled_pattern = re.compile(r"^[ \t]*isolate-workers[ \t]*=[ \t]*true[ \t]*$", re.MULTILINE)
        disabled_pattern = re.compile(r"^[ \t]*isolate-workers[ \t]*=[ \t]*false[ \t]*$", re.MULTILINE)

        self.assertIsNone(enabled_pattern.search(self.ocserv_template))
        self.assertIsNotNone(disabled_pattern.search(self.ocserv_template))

    def test_self_managed_alpine_rootfs_is_not_used(self):
        combined = "\n".join([self.dockerfile, self.exporter_dockerfile])

        self.assertIn("ARG ALPINE_IMAGE=alpine:3.23.4", self.dockerfile)
        self.assertIn("ARG ALPINE_IMAGE=alpine:3.23.4", self.exporter_dockerfile)
        for old_token in (
            "alpine-" + "rootfs",
            "ALPINE_" + "MINIROOTFS_SHA256",
            "ALPINE_" + "ARCH",
            "ALPINE_" + "PATCH_VERSION",
            "alpine-" + "mini" + "rootfs",
        ):
            self.assertNotIn(old_token, combined)


if __name__ == "__main__":
    unittest.main()
