#!/usr/bin/env python3
"""ocserv Prometheus Exporter - 通过 occtl 采集指标"""
import json
import subprocess
import os
import time
import socket
import sys
import re
from prometheus_client import start_http_server, Gauge, Counter, Info

SOCKET_PATH = os.getenv("OCSERV_SOCKET", "/var/run/occtl.socket")
METRICS_PORT = int(os.getenv("METRICS_PORT", "9100"))
METRICS_HOST = os.getenv("METRICS_HOST", "0.0.0.0")
OCSERV_VERSION = "unknown"
MIN_COLLECTION_INTERVAL_SECONDS = 5.0


def read_float_env(name, default, min_value=None):
    """Read a numeric environment variable with optional minimum clamping."""
    raw_value = os.getenv(name)
    if raw_value is None or raw_value == "":
        return default

    try:
        value = float(raw_value)
    except ValueError:
        print(f"❌ Invalid {name}: {raw_value!r}. Expected a number.")
        sys.exit(1)

    if value <= 0:
        print(f"❌ Invalid {name}: {raw_value!r}. Expected a positive number.")
        sys.exit(1)

    if min_value is not None and value < min_value:
        print(f"⚠️ {name}={value:g}s is below the supported minimum; using {min_value:g}s")
        return min_value

    return value


COLLECTION_INTERVAL_SECONDS = read_float_env(
    "EXPORTER_INTERVAL_SECONDS",
    15.0,
    min_value=MIN_COLLECTION_INTERVAL_SECONDS,
)
OCCTL_TIMEOUT_SECONDS = read_float_env("OCCTL_TIMEOUT_SECONDS", 5.0)

# ==========================================
# 服务级别指标
# ==========================================
ocserv_up = Gauge("ocserv_up", "Ocserv service status (1=up, 0=down)")
ocserv_active_users = Gauge("ocserv_active_users", "Number of active VPN users")
ocserv_uptime = Gauge("ocserv_uptime_seconds", "Ocserv main process uptime")
ocserv_info = Info("ocserv_build", "Ocserv version info")

# ==========================================
# 流量指标 (使用 Gauge 因为 occtl 返回累计值)
# ==========================================
ocserv_rx_bytes = Gauge("ocserv_bytes_rx_total", "Total bytes received from clients")
ocserv_tx_bytes = Gauge("ocserv_bytes_tx_total", "Total bytes sent to clients")
ocserv_rx_rate = Gauge(
    "ocserv_bytes_rx_rate_bytes_per_second",
    "Current receive traffic rate from clients in bytes per second",
)
ocserv_tx_rate = Gauge(
    "ocserv_bytes_tx_rate_bytes_per_second",
    "Current transmit traffic rate to clients in bytes per second",
)

# ==========================================
# 用户详情指标 (带标签)
# ==========================================
ocserv_user_rx = Gauge("ocserv_user_bytes_rx", "Bytes received per user", ["username", "ip"])
ocserv_user_tx = Gauge("ocserv_user_bytes_tx", "Bytes sent per user", ["username", "ip"])
ocserv_user_rx_rate = Gauge(
    "ocserv_user_bytes_rx_rate_bytes_per_second",
    "Current receive traffic rate per user in bytes per second",
    ["username", "ip"],
)
ocserv_user_tx_rate = Gauge(
    "ocserv_user_bytes_tx_rate_bytes_per_second",
    "Current transmit traffic rate per user in bytes per second",
    ["username", "ip"],
)
ocserv_user_connected = Gauge("ocserv_user_connected_seconds", "User connection duration in seconds", ["username", "ip"])

previous_user_traffic = {}

# ==========================================
# 调试指标
# ==========================================
ocserv_scrape_success = Counter("ocserv_scrape_success_total", "Number of successful metric scrapes")
ocserv_scrape_errors = Counter("ocserv_scrape_errors_total", "Number of failed metric scrapes")
ocserv_scrape_duration = Gauge("ocserv_scrape_duration_seconds", "Duration of last scrape in seconds")


def check_port_available(host, port):
    """Check if port is available for binding."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind((host, port))
            return True
    except OSError as e:
        print(f"❌ Port {port} is not available: {e}")
        return False


def run_occtl(args):
    """Execute occtl command and return JSON output."""
    try:
        cmd = ["occtl", "-s", SOCKET_PATH, "-j"] + args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=OCCTL_TIMEOUT_SECONDS)
        if result.returncode == 0:
            return json.loads(result.stdout)
        else:
            print(f"⚠️ occtl returned non-zero: {result.returncode}, stderr: {result.stderr}")
    except subprocess.TimeoutExpired:
        print(f"⚠️ occtl timeout for args: {args}")
    except json.JSONDecodeError as e:
        print(f"⚠️ occtl JSON parse error: {e}")
    except FileNotFoundError:
        print(f"⚠️ occtl binary not found")
    except Exception as e:
        print(f"⚠️ occtl error: {e}")
    return None


def get_version():
    """Get ocserv version from occtl --version."""
    try:
        result = subprocess.run(["occtl", "--version"], capture_output=True, text=True, timeout=OCCTL_TIMEOUT_SECONDS)
        output = result.stdout + result.stderr
        match = re.search(r"(\d+\.\d+[\.\d]*)", output)
        if match:
            return match.group(1)
    except Exception as e:
        print(f"Failed to get version: {e}")
    return "unknown"


def parse_bytes(value):
    """Parse occtl byte counters defensively."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def calculate_rate(current_value, previous_value, elapsed_seconds):
    """Calculate a non-negative byte rate, treating counter drops as resets."""
    if previous_value is None or elapsed_seconds <= 0 or current_value < previous_value:
        return 0
    return (current_value - previous_value) / elapsed_seconds


def clear_user_metrics(clear_history=False):
    """Remove all per-user metric labels and optionally reset stored samples."""
    global previous_user_traffic

    for metric in (
        ocserv_user_rx,
        ocserv_user_tx,
        ocserv_user_rx_rate,
        ocserv_user_tx_rate,
        ocserv_user_connected,
    ):
        for label in list(metric._metrics.keys()):
            metric.remove(*label)

    if clear_history:
        previous_user_traffic = {}


def collect_metrics():
    """Collect all metrics from ocserv."""
    global previous_user_traffic

    scrape_time = time.time()
    start_time = scrape_time

    # Check if socket exists
    if not os.path.exists(SOCKET_PATH):
        print(f"❌ Socket file not found: {SOCKET_PATH}")
        ocserv_up.set(0)
        ocserv_active_users.set(0)
        ocserv_rx_bytes.set(0)
        ocserv_tx_bytes.set(0)
        ocserv_rx_rate.set(0)
        ocserv_tx_rate.set(0)
        clear_user_metrics(clear_history=True)
        ocserv_scrape_errors.inc()
        return

    status = run_occtl(["show", "status"])
    users = run_occtl(["show", "users"])

    if not status:
        ocserv_up.set(0)
        ocserv_scrape_errors.inc()
        # 服务不可用时重置所有流量指标
        ocserv_active_users.set(0)
        ocserv_rx_bytes.set(0)
        ocserv_tx_bytes.set(0)
        ocserv_rx_rate.set(0)
        ocserv_tx_rate.set(0)
        clear_user_metrics(clear_history=True)
        return

    # 服务状态
    ocserv_up.set(1)
    ocserv_uptime.set(status.get("uptime", 0))
    ocserv_info.info({"version": OCSERV_VERSION})

    # 用户统计
    if users and isinstance(users, list):
        ocserv_active_users.set(len(users))

        # 总流量和实时速率
        rx_total, tx_total = 0, 0
        rx_rate_total, tx_rate_total = 0, 0

        # 收集旧的 label 组合，用于清理已断开用户
        old_rx_labels = set(ocserv_user_rx._metrics.keys())
        old_tx_labels = set(ocserv_user_tx._metrics.keys())
        old_rx_rate_labels = set(ocserv_user_rx_rate._metrics.keys())
        old_tx_rate_labels = set(ocserv_user_tx_rate._metrics.keys())
        old_conn_labels = set(ocserv_user_connected._metrics.keys())
        current_labels = set()

        for u in users:
            username = u.get("Username", "unknown")
            ip = u.get("Remote IP", "unknown")
            user_rx = parse_bytes(u.get("RX", "0"))
            user_tx = parse_bytes(u.get("TX", "0"))
            label = (username, ip)
            current_labels.add(label)

            rx_total += user_rx
            tx_total += user_tx

            previous = previous_user_traffic.get(label)
            if previous:
                elapsed = scrape_time - previous["timestamp"]
                user_rx_rate = calculate_rate(user_rx, previous["rx"], elapsed)
                user_tx_rate = calculate_rate(user_tx, previous["tx"], elapsed)
            else:
                user_rx_rate = 0
                user_tx_rate = 0

            rx_rate_total += user_rx_rate
            tx_rate_total += user_tx_rate
            previous_user_traffic[label] = {
                "rx": user_rx,
                "tx": user_tx,
                "timestamp": scrape_time,
            }

            # 用户详情指标
            ocserv_user_rx.labels(username=username, ip=ip).set(user_rx)
            ocserv_user_tx.labels(username=username, ip=ip).set(user_tx)
            ocserv_user_rx_rate.labels(username=username, ip=ip).set(user_rx_rate)
            ocserv_user_tx_rate.labels(username=username, ip=ip).set(user_tx_rate)

            # 连接时长
            connected_at = u.get("raw_connected_at", 0)
            if connected_at:
                connected_seconds = scrape_time - connected_at
                ocserv_user_connected.labels(username=username, ip=ip).set(connected_seconds)

        # 清理已断开用户的旧 label 组合
        for label in old_rx_labels - current_labels:
            ocserv_user_rx.remove(*label)
        for label in old_tx_labels - current_labels:
            ocserv_user_tx.remove(*label)
        for label in old_rx_rate_labels - current_labels:
            ocserv_user_rx_rate.remove(*label)
        for label in old_tx_rate_labels - current_labels:
            ocserv_user_tx_rate.remove(*label)
        for label in old_conn_labels - current_labels:
            ocserv_user_connected.remove(*label)
        for label in set(previous_user_traffic.keys()) - current_labels:
            previous_user_traffic.pop(label, None)

        # 更新总流量和实时速率
        ocserv_rx_bytes.set(rx_total)
        ocserv_tx_bytes.set(tx_total)
        ocserv_rx_rate.set(rx_rate_total)
        ocserv_tx_rate.set(tx_rate_total)
    else:
        ocserv_active_users.set(0)
        ocserv_rx_bytes.set(0)
        ocserv_tx_bytes.set(0)
        ocserv_rx_rate.set(0)
        ocserv_tx_rate.set(0)
        clear_user_metrics(clear_history=True)

    # 记录采集成功
    ocserv_scrape_success.inc()
    duration = time.time() - start_time
    ocserv_scrape_duration.set(duration)


def main():
    """Main entry point."""
    global OCSERV_VERSION
    OCSERV_VERSION = get_version()
    print(f"🚀 Starting ocserv exporter on {METRICS_HOST}:{METRICS_PORT}")
    print(f"   Ocserv version: {OCSERV_VERSION}")
    print(f"   Socket path: {SOCKET_PATH}")
    print(f"   Collection interval: {COLLECTION_INTERVAL_SECONDS:g}s")
    print(f"   occtl timeout: {OCCTL_TIMEOUT_SECONDS:g}s")
    print(f"   Python version: {sys.version}")

    # Check if socket exists before starting
    if os.path.exists(SOCKET_PATH):
        print(f"✅ Socket file found: {SOCKET_PATH}")
    else:
        print(f"⚠️ Socket file not found: {SOCKET_PATH} (will retry during collection)")

    # Check port availability
    if not check_port_available(METRICS_HOST, METRICS_PORT):
        print(f"❌ Cannot bind to port {METRICS_PORT}. Exiting.")
        sys.exit(1)

    print(f"✅ Port {METRICS_PORT} is available")

    # Start HTTP server with error handling
    try:
        start_http_server(METRICS_PORT, addr=METRICS_HOST)
        print(f"✅ HTTP server started successfully on {METRICS_HOST}:{METRICS_PORT}")
    except OSError as e:
        print(f"❌ Failed to start HTTP server: {e}")
        print(f"   This might be a port conflict or permission issue")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Unexpected error starting HTTP server: {e}")
        sys.exit(1)

    # Main collection loop
    print(f"🔄 Starting metrics collection loop (interval: {COLLECTION_INTERVAL_SECONDS:g}s)")
    while True:
        try:
            collect_metrics()
        except Exception as e:
            print(f"❌ Collection error: {e}")
        time.sleep(COLLECTION_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
