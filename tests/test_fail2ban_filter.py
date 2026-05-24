#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
FILTER_FILE = ROOT_DIR / "fail2ban" / "filter.d" / "nginx-auth.conf"


def load_failregexes():
    regexes = []
    collecting = False
    for line in FILTER_FILE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("failregex"):
            collecting = True
            pattern = stripped.split("=", 1)[1].strip()
        elif collecting and (line.startswith(" ") or line.startswith("\t")):
            pattern = stripped
        else:
            collecting = False
            continue

        if pattern:
            regexes.append(re.compile(pattern.replace("<HOST>", r"(?P<host>\d+\.\d+\.\d+\.\d+)")))
    return regexes


class Fail2BanFilterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.regexes = load_failregexes()

    def assert_matches(self, line):
        self.assertTrue(any(regex.search(line) for regex in self.regexes), line)

    def assert_not_matches(self, line):
        self.assertFalse(any(regex.search(line) for regex in self.regexes), line)

    def test_grafana_login_failures_match(self):
        self.assert_matches('203.0.113.10 - - [24/May/2026:12:00:00 +0000] "POST /grafana/login HTTP/1.1" 401 42')
        self.assert_matches('203.0.113.10 - - [24/May/2026:12:00:01 +0000] "POST /grafana/api/login HTTP/1.1" 403 42')

    def test_prometheus_is_not_part_of_public_auth_filter(self):
        self.assert_not_matches('203.0.113.10 - - [24/May/2026:12:00:02 +0000] "GET /prometheus/graph HTTP/1.1" 401 42')

    def test_static_and_successful_requests_do_not_match(self):
        self.assert_not_matches('203.0.113.10 - - [24/May/2026:12:00:03 +0000] "GET /grafana/public/build/app.js HTTP/1.1" 404 42')
        self.assert_not_matches('203.0.113.10 - - [24/May/2026:12:00:04 +0000] "POST /grafana/login HTTP/1.1" 200 42')


if __name__ == "__main__":
    unittest.main()
