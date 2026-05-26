#!/usr/bin/env python3
"""ocserv Prometheus Exporter - 通过 occtl 采集指标"""
import json
import subprocess
import os
import time
import socket
import sys
import re
from prometheus_client import start_http_server, Gauge, Info

SOCKET_PATH = os.getenv("OCSERV_SOCKET", "/run/ocserv/occtl.socket")
METRICS_PORT = int(os.getenv("METRICS_PORT", "9100"))
METRICS_HOST = os.getenv("METRICS_HOST", "0.0.0.0")
OCSERV_VERSION = "unknown"
MIN_COLLECTION_INTERVAL_SECONDS = 5.0


def read_bool_env(name, default=False):
    """Read a boolean environment variable."""
    raw_value = os.getenv(name)
    if raw_value is None or raw_value == "":
        return default

    normalized = raw_value.strip().lower()
    if normalized in ("1", "true", "yes", "on"):
        return True
    if normalized in ("0", "false", "no", "off"):
        return False

    print(f"❌ Invalid {name}: {raw_value!r}. Expected true/false.")
    sys.exit(1)


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
SESSION_DETAIL_METRICS_ENABLED = read_bool_env("EXPORTER_ENABLE_SESSION_DETAIL_METRICS", False)

# ==========================================
# 服务级别指标
# ==========================================
ocserv_up = Gauge("ocserv_up", "Ocserv service status (1=up, 0=down)")
ocserv_active_sessions = Gauge("ocserv_active_sessions", "Number of active VPN sessions")
ocserv_active_accounts = Gauge("ocserv_active_accounts", "Number of distinct active VPN accounts")
ocserv_uptime = Gauge("ocserv_uptime_seconds", "Ocserv main process uptime")
ocserv_info = Info("ocserv_build", "Ocserv version info")
ocserv_start_time = Gauge("ocserv_start_time_seconds", "Ocserv start time since Unix epoch in seconds")
ocserv_sessions_total = Gauge("ocserv_sessions_total", "Total number of sessions handled since server start")
ocserv_auth_failures_total = Gauge(
    "ocserv_authentication_failures_total",
    "Total number of authentication failures since server start",
)
ocserv_banned_ips = Gauge("ocserv_banned_ips", "Number of IP addresses currently in the ocserv ban list")
ocserv_stats_sessions_handled_total = Gauge(
    "ocserv_stats_sessions_handled_total",
    "Number of sessions handled since the last ocserv stats reset",
)
ocserv_stats_timed_out_sessions_total = Gauge(
    "ocserv_stats_timed_out_sessions_total",
    "Number of timed out sessions since the last ocserv stats reset",
)
ocserv_stats_timed_out_idle_sessions_total = Gauge(
    "ocserv_stats_timed_out_idle_sessions_total",
    "Number of idle timed out sessions since the last ocserv stats reset",
)
ocserv_stats_closed_error_sessions_total = Gauge(
    "ocserv_stats_closed_error_sessions_total",
    "Number of sessions closed due to errors since the last ocserv stats reset",
)
ocserv_stats_auth_failures_total = Gauge(
    "ocserv_stats_authentication_failures_total",
    "Number of authentication failures since the last ocserv stats reset",
)
ocserv_stats_rx_bytes = Gauge(
    "ocserv_stats_bytes_rx_total",
    "Total bytes received from clients since the last ocserv stats reset",
)
ocserv_stats_tx_bytes = Gauge(
    "ocserv_stats_bytes_tx_total",
    "Total bytes sent to clients since the last ocserv stats reset",
)
ocserv_auth_time_average = Gauge(
    "ocserv_auth_time_average_seconds",
    "Average authentication time since the last ocserv stats reset",
)
ocserv_auth_time_max = Gauge(
    "ocserv_auth_time_max_seconds",
    "Maximum authentication time since the last ocserv stats reset",
)
ocserv_session_time_average = Gauge(
    "ocserv_session_time_average_seconds",
    "Average session time since the last ocserv stats reset",
)
ocserv_session_time_max = Gauge(
    "ocserv_session_time_max_seconds",
    "Maximum session time since the last ocserv stats reset",
)

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
USER_LABELS = ["username", "session_id", "ip", "vpn_ip", "device"]

ocserv_user_rx = None
ocserv_user_tx = None
ocserv_user_rx_rate = None
ocserv_user_tx_rate = None
ocserv_user_connected = None

if SESSION_DETAIL_METRICS_ENABLED:
    ocserv_user_rx = Gauge("ocserv_user_bytes_rx", "Bytes received per VPN session", USER_LABELS)
    ocserv_user_tx = Gauge("ocserv_user_bytes_tx", "Bytes sent per VPN session", USER_LABELS)
    ocserv_user_rx_rate = Gauge(
        "ocserv_user_bytes_rx_rate_bytes_per_second",
        "Current receive traffic rate per VPN session in bytes per second",
        USER_LABELS,
    )
    ocserv_user_tx_rate = Gauge(
        "ocserv_user_bytes_tx_rate_bytes_per_second",
        "Current transmit traffic rate per VPN session in bytes per second",
        USER_LABELS,
    )
    ocserv_user_connected = Gauge("ocserv_user_connected_seconds", "VPN session connection duration in seconds", USER_LABELS)

previous_user_traffic = {}
previous_total_traffic = None

# ==========================================
# 调试指标
# ==========================================
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


def parse_number(value):
    """Parse occtl numeric values defensively."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0


def status_value(status, key):
    """Return a numeric status value with a safe default."""
    return parse_number(status.get(key, 0))


def calculate_rate(current_value, previous_value, elapsed_seconds):
    """Calculate a non-negative byte rate, treating counter drops as resets."""
    if previous_value is None or elapsed_seconds <= 0 or current_value < previous_value:
        return 0
    return (current_value - previous_value) / elapsed_seconds


def metric_label_value(value, default="unknown"):
    """Return a stable Prometheus label value."""
    if value is None or value == "":
        return default
    return str(value)


def get_session_id(user):
    """Return a session identifier that stays unique for concurrent logins."""
    for key in ("ID", "Full session", "Session"):
        value = user.get(key)
        if value is not None and value != "":
            return str(value)

    username = metric_label_value(user.get("Username"))
    ip = metric_label_value(user.get("Remote IP"))
    vpn_ip = metric_label_value(user.get("IPv4") or user.get("IP"))
    device = metric_label_value(user.get("Device"))
    connected_at = metric_label_value(user.get("raw_connected_at"), "0")
    return f"{username}:{ip}:{vpn_ip}:{device}:{connected_at}"


def get_user_label_values(user):
    """Build the complete label tuple for per-session metrics."""
    username = metric_label_value(user.get("Username"))
    session_id = get_session_id(user)
    ip = metric_label_value(user.get("Remote IP"))
    vpn_ip = metric_label_value(user.get("IPv4") or user.get("IP"))
    device = metric_label_value(user.get("Device"))
    return (username, session_id, ip, vpn_ip, device)


def reset_session_counts():
    """Reset all active session/account counters."""
    ocserv_active_sessions.set(0)
    ocserv_active_accounts.set(0)


def reset_status_metrics():
    """Reset status metrics that should not stay stale when occtl fails."""
    ocserv_uptime.set(0)
    ocserv_start_time.set(0)
    ocserv_sessions_total.set(0)
    ocserv_auth_failures_total.set(0)
    ocserv_banned_ips.set(0)
    ocserv_stats_sessions_handled_total.set(0)
    ocserv_stats_timed_out_sessions_total.set(0)
    ocserv_stats_timed_out_idle_sessions_total.set(0)
    ocserv_stats_closed_error_sessions_total.set(0)
    ocserv_stats_auth_failures_total.set(0)
    ocserv_stats_rx_bytes.set(0)
    ocserv_stats_tx_bytes.set(0)
    ocserv_auth_time_average.set(0)
    ocserv_auth_time_max.set(0)
    ocserv_session_time_average.set(0)
    ocserv_session_time_max.set(0)


def clear_user_metrics(clear_history=False):
    """Remove all per-user metric labels and optionally reset stored samples."""
    global previous_user_traffic

    if not SESSION_DETAIL_METRICS_ENABLED:
        previous_user_traffic = {}
        return

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
    global previous_user_traffic, previous_total_traffic

    scrape_time = time.time()
    start_time = scrape_time

    # Check if socket exists
    if not os.path.exists(SOCKET_PATH):
        print(f"❌ Socket file not found: {SOCKET_PATH}")
        ocserv_up.set(0)
        reset_session_counts()
        reset_status_metrics()
        ocserv_rx_bytes.set(0)
        ocserv_tx_bytes.set(0)
        ocserv_rx_rate.set(0)
        ocserv_tx_rate.set(0)
        previous_total_traffic = None
        clear_user_metrics(clear_history=True)
        return

    status = run_occtl(["show", "status"])
    users = run_occtl(["show", "users"])

    if not status:
        ocserv_up.set(0)
        # 服务不可用时重置所有流量指标
        reset_session_counts()
        reset_status_metrics()
        ocserv_rx_bytes.set(0)
        ocserv_tx_bytes.set(0)
        ocserv_rx_rate.set(0)
        ocserv_tx_rate.set(0)
        previous_total_traffic = None
        clear_user_metrics(clear_history=True)
        return

    # 服务状态
    ocserv_up.set(1)
    ocserv_uptime.set(status.get("uptime", 0))
    ocserv_info.info({"version": OCSERV_VERSION})
    ocserv_start_time.set(status_value(status, "raw_up_since"))
    ocserv_sessions_total.set(status_value(status, "Total sessions"))
    ocserv_auth_failures_total.set(status_value(status, "Total authentication failures"))
    ocserv_banned_ips.set(status_value(status, "IPs in ban list"))
    ocserv_stats_sessions_handled_total.set(status_value(status, "Sessions handled"))
    ocserv_stats_timed_out_sessions_total.set(status_value(status, "Timed out sessions"))
    ocserv_stats_timed_out_idle_sessions_total.set(status_value(status, "Timed out (idle) sessions"))
    ocserv_stats_closed_error_sessions_total.set(status_value(status, "Closed due to error sessions"))
    ocserv_stats_auth_failures_total.set(status_value(status, "Authentication failures"))
    ocserv_stats_rx_bytes.set(status_value(status, "raw_rx"))
    ocserv_stats_tx_bytes.set(status_value(status, "raw_tx"))
    ocserv_auth_time_average.set(status_value(status, "raw_avg_auth_time"))
    ocserv_auth_time_max.set(status_value(status, "raw_max_auth_time"))
    ocserv_session_time_average.set(status_value(status, "raw_avg_session_time"))
    ocserv_session_time_max.set(status_value(status, "raw_max_session_time"))

    # 用户统计
    if isinstance(users, list):
        active_sessions = len(users)
        active_accounts = len({metric_label_value(u.get("Username")) for u in users})
        ocserv_active_sessions.set(active_sessions)
        ocserv_active_accounts.set(active_accounts)

        # 总流量和实时速率
        rx_total, tx_total = 0, 0
        rx_rate_total, tx_rate_total = 0, 0

        # 收集旧的 label 组合，用于清理已断开用户
        old_rx_labels = set()
        old_tx_labels = set()
        old_rx_rate_labels = set()
        old_tx_rate_labels = set()
        old_conn_labels = set()
        if SESSION_DETAIL_METRICS_ENABLED:
            old_rx_labels = set(ocserv_user_rx._metrics.keys())
            old_tx_labels = set(ocserv_user_tx._metrics.keys())
            old_rx_rate_labels = set(ocserv_user_rx_rate._metrics.keys())
            old_tx_rate_labels = set(ocserv_user_tx_rate._metrics.keys())
            old_conn_labels = set(ocserv_user_connected._metrics.keys())
        current_labels = set()

        for u in users:
            label = get_user_label_values(u)
            user_rx = parse_bytes(u.get("RX", "0"))
            user_tx = parse_bytes(u.get("TX", "0"))
            current_labels.add(label)

            rx_total += user_rx
            tx_total += user_tx

            if SESSION_DETAIL_METRICS_ENABLED:
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
                label_kwargs = dict(zip(USER_LABELS, label))
                ocserv_user_rx.labels(**label_kwargs).set(user_rx)
                ocserv_user_tx.labels(**label_kwargs).set(user_tx)
                ocserv_user_rx_rate.labels(**label_kwargs).set(user_rx_rate)
                ocserv_user_tx_rate.labels(**label_kwargs).set(user_tx_rate)

                # 连接时长
                connected_at = u.get("raw_connected_at", 0)
                if connected_at:
                    connected_seconds = scrape_time - connected_at
                    ocserv_user_connected.labels(**label_kwargs).set(connected_seconds)

        if SESSION_DETAIL_METRICS_ENABLED:
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
        else:
            previous_user_traffic = {}

        if previous_total_traffic:
            elapsed = scrape_time - previous_total_traffic["timestamp"]
            rx_rate_total = calculate_rate(rx_total, previous_total_traffic["rx"], elapsed)
            tx_rate_total = calculate_rate(tx_total, previous_total_traffic["tx"], elapsed)
        else:
            rx_rate_total = 0
            tx_rate_total = 0

        previous_total_traffic = {
            "rx": rx_total,
            "tx": tx_total,
            "timestamp": scrape_time,
        }

        # Traffic Total/Rate intentionally use current active sessions from show users.
        ocserv_rx_bytes.set(rx_total)
        ocserv_tx_bytes.set(tx_total)
        ocserv_rx_rate.set(rx_rate_total)
        ocserv_tx_rate.set(tx_rate_total)
    else:
        reset_session_counts()
        ocserv_rx_bytes.set(0)
        ocserv_tx_bytes.set(0)
        ocserv_rx_rate.set(0)
        ocserv_tx_rate.set(0)
        previous_total_traffic = None
        clear_user_metrics(clear_history=True)

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
    print(f"   Session detail metrics: {SESSION_DETAIL_METRICS_ENABLED}")
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
