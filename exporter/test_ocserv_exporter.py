#!/usr/bin/env python3
import importlib.util
import os
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


class FakeValue:
    def __init__(self):
        self.value = 0

    def get(self):
        return self.value

    def set(self, value):
        self.value = value


class FakeGauge:
    registry = []

    def __init__(self, name, documentation, labelnames=None):
        self.name = name
        self.documentation = documentation
        self.labelnames = tuple(labelnames or ())
        self._value = FakeValue()
        self._metrics = {}
        FakeGauge.registry.append(self)

    def labels(self, **kwargs):
        label = tuple(kwargs[name] for name in self.labelnames)
        if label not in self._metrics:
            self._metrics[label] = FakeGauge(self.name, self.documentation)
        return self._metrics[label]

    def set(self, value):
        self._value.set(value)

    def remove(self, *label):
        self._metrics.pop(tuple(label), None)


class FakeInfo(FakeGauge):
    def info(self, value):
        self._value.set(value)


fake_prometheus_client = types.ModuleType("prometheus_client")
fake_prometheus_client.start_http_server = lambda *args, **kwargs: None
fake_prometheus_client.Gauge = FakeGauge
fake_prometheus_client.Info = FakeInfo
sys.modules["prometheus_client"] = fake_prometheus_client


EXPORTER_PATH = Path(__file__).with_name("ocserv-exporter.py")


def load_exporter(session_detail_metrics=None):
    if session_detail_metrics is None:
        os.environ.pop("EXPORTER_ENABLE_SESSION_DETAIL_METRICS", None)
    else:
        os.environ["EXPORTER_ENABLE_SESSION_DETAIL_METRICS"] = "true" if session_detail_metrics else "false"

    FakeGauge.registry = []
    module_name = f"ocserv_exporter_under_test_{len(sys.modules)}"
    spec = importlib.util.spec_from_file_location(module_name, EXPORTER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


exporter = load_exporter(session_detail_metrics=True)


class OcservExporterTest(unittest.TestCase):
    def setUp(self):
        exporter.clear_user_metrics(clear_history=True)
        exporter.previous_total_traffic = None
        exporter.reset_session_counts()
        exporter.ocserv_rx_bytes.set(0)
        exporter.ocserv_tx_bytes.set(0)
        exporter.ocserv_rx_rate.set(0)
        exporter.ocserv_tx_rate.set(0)

    def collect_with_users(self, users, scrape_time):
        def fake_run_occtl(args):
            if args == ["show", "status"]:
                return {
                    "uptime": 3600,
                    "raw_up_since": 900,
                    "raw_rx": 999999,
                    "raw_tx": 888888,
                    "Total sessions": 20,
                    "Total authentication failures": 3,
                    "IPs in ban list": 1,
                    "Sessions handled": 5,
                    "Timed out sessions": 2,
                    "Timed out (idle) sessions": 1,
                    "Closed due to error sessions": 4,
                    "Authentication failures": 2,
                    "raw_avg_auth_time": 1,
                    "raw_max_auth_time": 4,
                    "raw_avg_session_time": 120,
                    "raw_max_session_time": 600,
                }
            if args == ["show", "users"]:
                return users
            return None

        with mock.patch.object(exporter.os.path, "exists", return_value=True):
            with mock.patch.object(exporter, "run_occtl", side_effect=fake_run_occtl):
                with mock.patch.object(exporter.time, "time", side_effect=[scrape_time, scrape_time + 0.1]):
                    exporter.collect_metrics()

    def test_same_account_same_remote_ip_uses_distinct_session_labels_and_rates(self):
        first_users = [
            {
                "ID": 11,
                "Username": "alice",
                "Remote IP": "203.0.113.10",
                "IPv4": "10.10.10.21",
                "Device": "vpns0",
                "RX": 100,
                "TX": 200,
                "raw_connected_at": 900,
            },
            {
                "ID": 12,
                "Username": "alice",
                "Remote IP": "203.0.113.10",
                "IPv4": "10.10.10.22",
                "Device": "vpns1",
                "RX": 300,
                "TX": 500,
                "raw_connected_at": 950,
            },
        ]
        second_users = [
            {**first_users[0], "RX": 150, "TX": 260},
            {**first_users[1], "RX": 360, "TX": 620},
        ]

        self.collect_with_users(first_users, 1000)
        self.collect_with_users(second_users, 1010)

        label_11 = ("alice", "11", "203.0.113.10", "10.10.10.21", "vpns0")
        label_12 = ("alice", "12", "203.0.113.10", "10.10.10.22", "vpns1")

        self.assertEqual(exporter.ocserv_active_sessions._value.get(), 2)
        self.assertEqual(exporter.ocserv_active_accounts._value.get(), 1)
        self.assertEqual(exporter.ocserv_sessions_total._value.get(), 20)
        self.assertEqual(exporter.ocserv_auth_failures_total._value.get(), 3)
        self.assertEqual(exporter.ocserv_banned_ips._value.get(), 1)
        self.assertEqual(exporter.ocserv_session_time_max._value.get(), 600)
        self.assertEqual(exporter.ocserv_user_rx._metrics[label_11]._value.get(), 150)
        self.assertEqual(exporter.ocserv_user_rx._metrics[label_12]._value.get(), 360)
        self.assertEqual(exporter.ocserv_user_rx_rate._metrics[label_11]._value.get(), 5)
        self.assertEqual(exporter.ocserv_user_rx_rate._metrics[label_12]._value.get(), 6)
        self.assertEqual(exporter.ocserv_rx_bytes._value.get(), 510)
        self.assertEqual(exporter.ocserv_tx_bytes._value.get(), 880)
        self.assertEqual(exporter.ocserv_rx_rate._value.get(), 11)
        self.assertEqual(exporter.ocserv_tx_rate._value.get(), 18)
        self.assertEqual(exporter.ocserv_stats_rx_bytes._value.get(), 999999)
        self.assertEqual(exporter.ocserv_stats_tx_bytes._value.get(), 888888)

    def test_disconnected_session_labels_and_history_are_removed(self):
        first_users = [
            {"ID": 11, "Username": "alice", "Remote IP": "203.0.113.10", "IPv4": "10.10.10.21", "Device": "vpns0"},
            {"ID": 12, "Username": "alice", "Remote IP": "203.0.113.10", "IPv4": "10.10.10.22", "Device": "vpns1"},
        ]
        second_users = [first_users[1]]

        self.collect_with_users(first_users, 1000)
        self.collect_with_users(second_users, 1010)

        label_11 = ("alice", "11", "203.0.113.10", "10.10.10.21", "vpns0")
        label_12 = ("alice", "12", "203.0.113.10", "10.10.10.22", "vpns1")

        self.assertNotIn(label_11, exporter.ocserv_user_rx._metrics)
        self.assertNotIn(label_11, exporter.previous_user_traffic)
        self.assertIn(label_12, exporter.ocserv_user_rx._metrics)
        self.assertIn(label_12, exporter.previous_user_traffic)

    def test_scrape_success_metric_is_not_exported(self):
        load_exporter(session_detail_metrics=True)
        metric_names = {metric.name for metric in FakeGauge.registry}
        self.assertNotIn("ocserv_scrape_success_total", metric_names)
        self.assertNotIn("ocserv_active_users", metric_names)

    def test_session_detail_metrics_are_disabled_by_default(self):
        disabled_exporter = load_exporter(session_detail_metrics=None)
        metric_names = {metric.name for metric in FakeGauge.registry}
        self.assertNotIn("ocserv_user_bytes_rx", metric_names)
        self.assertNotIn("ocserv_user_bytes_tx", metric_names)
        self.assertNotIn("ocserv_user_connected_seconds", metric_names)

        users_first = [
            {"ID": 11, "Username": "alice", "Remote IP": "203.0.113.10", "IPv4": "10.10.10.21", "RX": 100, "TX": 200}
        ]
        users_second = [{**users_first[0], "RX": 150, "TX": 260}]

        def collect(module, users, scrape_time):
            def fake_run_occtl(args):
                if args == ["show", "status"]:
                    return {"uptime": 3600}
                if args == ["show", "users"]:
                    return users
                return None

            with mock.patch.object(module.os.path, "exists", return_value=True):
                with mock.patch.object(module, "run_occtl", side_effect=fake_run_occtl):
                    with mock.patch.object(module.time, "time", side_effect=[scrape_time, scrape_time + 0.1]):
                        module.collect_metrics()

        collect(disabled_exporter, users_first, 1000)
        collect(disabled_exporter, users_second, 1010)

        self.assertEqual(disabled_exporter.ocserv_active_sessions._value.get(), 1)
        self.assertEqual(disabled_exporter.ocserv_active_accounts._value.get(), 1)
        self.assertEqual(disabled_exporter.ocserv_rx_bytes._value.get(), 150)
        self.assertEqual(disabled_exporter.ocserv_tx_bytes._value.get(), 260)
        self.assertEqual(disabled_exporter.ocserv_rx_rate._value.get(), 5)
        self.assertEqual(disabled_exporter.ocserv_tx_rate._value.get(), 6)
        self.assertEqual(disabled_exporter.previous_user_traffic, {})

    def test_status_raw_traffic_does_not_override_user_traffic_totals(self):
        disabled_exporter = load_exporter(session_detail_metrics=None)
        users = [
            {"ID": 11, "Username": "alice", "RX": 100, "TX": 200},
            {"ID": 12, "Username": "bob", "RX": 300, "TX": 500},
        ]

        def fake_run_occtl(args):
            if args == ["show", "status"]:
                return {"uptime": 3600, "raw_rx": 999999, "raw_tx": 888888}
            if args == ["show", "users"]:
                return users
            return None

        with mock.patch.object(disabled_exporter.os.path, "exists", return_value=True):
            with mock.patch.object(disabled_exporter, "run_occtl", side_effect=fake_run_occtl):
                with mock.patch.object(disabled_exporter.time, "time", side_effect=[1000, 1000.1]):
                    disabled_exporter.collect_metrics()

        self.assertEqual(disabled_exporter.ocserv_rx_bytes._value.get(), 400)
        self.assertEqual(disabled_exporter.ocserv_tx_bytes._value.get(), 700)
        self.assertEqual(disabled_exporter.ocserv_stats_rx_bytes._value.get(), 999999)
        self.assertEqual(disabled_exporter.ocserv_stats_tx_bytes._value.get(), 888888)

    def test_users_failure_resets_traffic_without_status_raw_fallback(self):
        disabled_exporter = load_exporter(session_detail_metrics=None)
        disabled_exporter.ocserv_rx_bytes.set(400)
        disabled_exporter.ocserv_tx_bytes.set(700)
        disabled_exporter.ocserv_rx_rate.set(40)
        disabled_exporter.ocserv_tx_rate.set(70)

        def fake_run_occtl(args):
            if args == ["show", "status"]:
                return {"uptime": 3600, "raw_rx": 999999, "raw_tx": 888888}
            if args == ["show", "users"]:
                return {"error": "not a list"}
            return None

        with mock.patch.object(disabled_exporter.os.path, "exists", return_value=True):
            with mock.patch.object(disabled_exporter, "run_occtl", side_effect=fake_run_occtl):
                with mock.patch.object(disabled_exporter.time, "time", side_effect=[1000, 1000.1]):
                    disabled_exporter.collect_metrics()

        self.assertEqual(disabled_exporter.ocserv_active_sessions._value.get(), 0)
        self.assertEqual(disabled_exporter.ocserv_active_accounts._value.get(), 0)
        self.assertEqual(disabled_exporter.ocserv_rx_bytes._value.get(), 0)
        self.assertEqual(disabled_exporter.ocserv_tx_bytes._value.get(), 0)
        self.assertEqual(disabled_exporter.ocserv_rx_rate._value.get(), 0)
        self.assertEqual(disabled_exporter.ocserv_tx_rate._value.get(), 0)
        self.assertIsNone(disabled_exporter.previous_total_traffic)
        self.assertEqual(disabled_exporter.ocserv_stats_rx_bytes._value.get(), 999999)
        self.assertEqual(disabled_exporter.ocserv_stats_tx_bytes._value.get(), 888888)

    def test_missing_status_fields_use_safe_defaults(self):
        def fake_run_occtl(args):
            if args == ["show", "status"]:
                return {"uptime": 3600}
            if args == ["show", "users"]:
                return []
            return None

        with mock.patch.object(exporter.os.path, "exists", return_value=True):
            with mock.patch.object(exporter, "run_occtl", side_effect=fake_run_occtl):
                with mock.patch.object(exporter.time, "time", side_effect=[1000, 1000.1]):
                    exporter.collect_metrics()

        self.assertEqual(exporter.ocserv_sessions_total._value.get(), 0)
        self.assertEqual(exporter.ocserv_auth_time_average._value.get(), 0)


if __name__ == "__main__":
    unittest.main()
