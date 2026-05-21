#!/usr/bin/env python3
import importlib.util
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


class FakeCounter(FakeGauge):
    def inc(self):
        self._value.set(self._value.get() + 1)


class FakeInfo(FakeGauge):
    def info(self, value):
        self._value.set(value)


fake_prometheus_client = types.ModuleType("prometheus_client")
fake_prometheus_client.start_http_server = lambda *args, **kwargs: None
fake_prometheus_client.Gauge = FakeGauge
fake_prometheus_client.Counter = FakeCounter
fake_prometheus_client.Info = FakeInfo
sys.modules["prometheus_client"] = fake_prometheus_client


EXPORTER_PATH = Path(__file__).with_name("ocserv-exporter.py")
spec = importlib.util.spec_from_file_location("ocserv_exporter_under_test", EXPORTER_PATH)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class OcservExporterTest(unittest.TestCase):
    def setUp(self):
        exporter.clear_user_metrics(clear_history=True)
        exporter.reset_session_counts()
        exporter.ocserv_rx_bytes.set(0)
        exporter.ocserv_tx_bytes.set(0)
        exporter.ocserv_rx_rate.set(0)
        exporter.ocserv_tx_rate.set(0)

    def collect_with_users(self, users, scrape_time):
        def fake_run_occtl(args):
            if args == ["show", "status"]:
                return {"uptime": 3600}
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
        self.assertEqual(exporter.ocserv_user_rx._metrics[label_11]._value.get(), 150)
        self.assertEqual(exporter.ocserv_user_rx._metrics[label_12]._value.get(), 360)
        self.assertEqual(exporter.ocserv_user_rx_rate._metrics[label_11]._value.get(), 5)
        self.assertEqual(exporter.ocserv_user_rx_rate._metrics[label_12]._value.get(), 6)
        self.assertEqual(exporter.ocserv_rx_rate._value.get(), 11)

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
        metric_names = {metric.name for metric in FakeGauge.registry}
        self.assertNotIn("ocserv_scrape_success_total", metric_names)
        self.assertNotIn("ocserv_active_users", metric_names)


if __name__ == "__main__":
    unittest.main()
