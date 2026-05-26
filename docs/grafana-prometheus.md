# Grafana + Prometheus 监控

通过 Prometheus 采集 ocserv 运行指标，Grafana 提供可视化面板，Nginx 提供 HTTPS 反向代理。

## 架构概览

```
ocserv → ocserv-exporter → Prometheus → Grafana
                                    ↑
                              Nginx (HTTPS 入口)
```

- **ocserv-exporter**：通过 ocserv Unix socket 采集活跃会话、唯一账号、流量、运行时长等指标
- **Prometheus**：定时拉取指标并存储为时序数据
- **Grafana**：读取 Prometheus 数据，展示可视化仪表盘
- **Nginx**：HTTPS 入口（8443 端口），仅通过 `/grafana/` 对外暴露 Grafana。Prometheus 保持在 Docker 网络内部，供 Grafana 查询。80 端口保留给 certbot 证书续期使用。

## 部署前准备

### 1. 申请 SSL 证书

```bash
sudo certbot certonly --standalone -d your.domain.com \
  --agree-tos --email your@email.com
```

证书默认保存在 `/etc/letsencrypt/live/your.domain.com/`，会挂载到 ocserv 和 Nginx 容器。

### 2. 配置环境变量

```bash
# 准备 ocserv 基础配置、监控目录并打开 vi .env 编辑环境变量
./scripts/prepare-monitoring-config.sh
```

脚本默认打开 `vi .env`。如果你更习惯其他编辑器，可以使用 `EDITOR=vim ./scripts/prepare-monitoring-config.sh`。

**必须修改的变量**：

| 变量 | 说明 | 示例 |
|:--|:--|:--|
| `DOMAIN` | 你的域名 | `vpn.example.com` |
| `GF_ADMIN_PASSWORD` | Grafana 管理员密码（必须设置，否则 Compose 配置阶段失败） | `your_secure_password` |

> **注意**：域名配置现在集中在 `.env` 文件中，无需手动修改 `docker-compose.monitoring.yml` 或 `nginx/conf.d/` 中的硬编码域名。Nginx 和 ocserv 使用同一套 `/etc/letsencrypt/live/${DOMAIN}` 证书，Nginx 配置会在容器启动时通过 `envsubst` 自动生成。

## 启动监控栈

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

验证各服务是否正常：

```bash
# 检查 Nginx 配置
docker exec nginx-proxy nginx -t

# 检查 Prometheus 内部健康
docker exec prometheus wget -qO- http://localhost:9090/prometheus/-/healthy

# 查看 Grafana 日志
docker logs grafana
```

## 访问地址

| 服务 | 地址 | 认证方式 |
|:--|:--|:--|
| Grafana | `https://${DOMAIN}:${MONITORING_PORT}/grafana/` | admin / `${GF_ADMIN_PASSWORD}` |

> 实际访问地址由 `.env` 文件中的 `DOMAIN` 和 `MONITORING_PORT` 变量决定。默认 `MONITORING_PORT=8443`，ocserv 使用 `${OCSERV_PORT:-443}` 端口。

## Grafana 使用指南

### 首次登录

1. 打开 `https://${DOMAIN}:${MONITORING_PORT}/grafana/`（替换为你的实际域名）
2. 用户名 `admin`，密码为 `.env` 文件中 `GF_ADMIN_PASSWORD` 的值（生产环境必须修改）
3. 登录后建议修改默认密码（Settings → Password）

### 查看仪表盘

项目已内置两块 ocserv 监控面板，登录后在 **Dashboards** 中即可看到：

- **Ocserv Overview** — 生产默认总览看板，30 秒刷新，只查询服务级和聚合指标。
- **Ocserv Sessions** — 排障明细看板，查询 `ocserv_user_*` 和用户排行；需先启用 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true`。

默认长期打开 `Ocserv Overview`。只有需要用户排行、每会话表格或连接时长时再打开 Sessions 看板。

### 添加自定义告警

1. 进入目标面板，点击指标名称 → **Edit**
2. 在右侧 **Alert** 标签中设置规则，例如：
   - `ocserv_active_sessions > 14` → 连接会话数接近上限时告警
3. 配置通知渠道（Email / Slack / Webhook 等）

### 常见问题排查

```bash
# 查看 Grafana 子路径路由日志
docker logs grafana 2>&1 | grep -i "subpath\|routing"

# 检查 Nginx 转发配置
docker exec nginx-proxy nginx -T | grep -A5 "location /grafana"

# 验证 Prometheus 数据源连通性
docker exec grafana wget -qO- http://prometheus:9090/prometheus/api/v1/status/config
```

如果 Prometheus 能访问 `http://ocserv:9100/metrics`，但 `ocserv_up` 一直为 `0`，说明故障在 exporter 到 ocserv socket 之间。先在 exporter 容器内确认运行用户和 `occtl` 输出：

```bash
docker exec ocserv-exporter id
docker exec ocserv-exporter occtl -s /run/ocserv/occtl.socket -j show status
```

`recvmsg: Connection reset by peer` 或 `Status: offline` 通常表示 exporter 没有按监控 Compose 以 root 运行。确认 `docker-compose.monitoring.yml` 中 `ocserv-exporter` 保留 `user: "0:0"`，然后重建 exporter。

### Grafana 偶发 502 排查

`/grafana/` 偶发 502 通常表示 Nginx 当时无法正常连接 Grafana 上游。优先确认 Grafana 是否因内存限制被 OOM kill：

```bash
docker inspect grafana \
  --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} RestartCount={{.RestartCount}} FinishedAt={{.State.FinishedAt}}'

docker logs --since 2h grafana | grep -Ei 'oom|out of memory|killed|panic|fatal|failed'
docker logs --since 2h nginx-proxy | grep -E ' 502 |connect\(\) failed|upstream prematurely closed|upstream timed out'
docker stats --no-stream grafana prometheus ocserv-exporter
```

判断方式：

- `OOMKilled=true` 或 `ExitCode=137`：Grafana 大概率被 OOM kill。保持默认 `GRAFANA_MEM_LIMIT=512m`，如果仍发生可提升到 `768m` 或 `1g`。
- Nginx 出现 `connect() failed (111: Connection refused)`：Grafana 当时不可用，常见于重启或 OOM。
- Nginx 出现 `upstream timed out`：更像查询慢或 Prometheus 响应慢，优先检查 Grafana 查询时间范围、Prometheus 负载和 Sessions 看板中的高基数会话面板。

修改 `.env` 中的 Grafana 资源限制后需要重建 Grafana 容器：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --force-recreate grafana
```

## Prometheus 使用指南

### 查看已采集的指标

Prometheus 默认不对公网暴露。排查时可在宿主机通过 `docker exec prometheus` 访问内部 API，或临时使用安全隧道访问 Prometheus UI。

| 指标名 | 类型 | 说明 |
|:--|:--|:--|
| `ocserv_up` | Gauge | 服务状态（1=正常，0=异常） |
| `ocserv_active_sessions` | Gauge | 当前在线会话数 |
| `ocserv_active_accounts` | Gauge | 当前唯一账号数 |
| `ocserv_uptime_seconds` | Gauge | 运行时长（秒） |
| `ocserv_start_time_seconds` | Gauge | 服务启动时间戳 |
| `ocserv_sessions_total` | Gauge | 服务启动以来处理的总会话数 |
| `ocserv_authentication_failures_total` | Gauge | 服务启动以来认证失败总数 |
| `ocserv_banned_ips` | Gauge | 当前封禁 IP 数 |
| `ocserv_stats_bytes_rx_total` | Gauge | `show status.raw_rx`，上次 stats reset 以来的累计接收字节，用于 Overview 的 Traffic Total 面板 |
| `ocserv_stats_bytes_tx_total` | Gauge | `show status.raw_tx`，上次 stats reset 以来的累计发送字节，用于 Overview 的 Traffic Total 面板 |
| `ocserv_bytes_rx_total` | Gauge | 当前在线会话累计接收字节求和，固定来自 `show users` |
| `ocserv_bytes_tx_total` | Gauge | 当前在线会话累计发送字节求和，固定来自 `show users` |
| `ocserv_bytes_rx_rate_bytes_per_second` | Gauge | 当前接收速率（字节/秒） |
| `ocserv_bytes_tx_rate_bytes_per_second` | Gauge | 当前发送速率（字节/秒） |
| `ocserv_build_info` | Info | ocserv 版本信息 |

### 常用查询语句

```
# 当前在线会话数
ocserv_active_sessions

# 当前唯一账号数
ocserv_active_accounts

# 当前接收速率（字节/秒）
ocserv_bytes_rx_rate_bytes_per_second

# 历史兼容：基于累计值计算近 1 分钟平均接收速率
rate(ocserv_bytes_rx_total[1m])

# 服务是否在线
ocserv_up
```

默认 Overview 看板只查询服务级和聚合指标，避免默认加载 `ocserv_user_*` 高基数序列。需要用户排行、每会话表格或连接时长时，设置 `EXPORTER_ENABLE_SESSION_DETAIL_METRICS=true` 并打开 Ocserv Sessions 看板。同一账号多设备同时连接时，每会话流量指标带 `session_id` 标签，因此同账号、同公网 IP 的连接也会在明细表和趋势图中分开显示。

### 指标重要性评估

| 指标 | 重要性 | 评估 |
|:--|:--|:--|
| `ocserv_up` | 关键 | 服务可用性核心指标，应保留 |
| `ocserv_active_sessions` | 关键 | 当前真实在线会话数 |
| `ocserv_active_accounts` | 高 | 区分同账号多设备场景，排障价值高 |
| `ocserv_bytes_rx/tx_rate_bytes_per_second` | 高 | 实时带宽面板核心指标 |
| `ocserv_sessions_total` / `ocserv_authentication_failures_total` / `ocserv_banned_ips` | 高 | 固定服务级指标，成本低，适合默认开启 |
| `ocserv_user_bytes_rx/tx` | 中高 | 每会话流量、排行、明细表依赖，标签基数随会话数增长，默认关闭 |
| `ocserv_user_connected_seconds` | 中高 | 连接时长排障有用，默认关闭 |
| `ocserv_scrape_duration_seconds` | 中 | 采集性能和 occtl 阻塞排查有用 |
| `ocserv_bytes_rx/tx_total` | 中 | 当前在线会话流量求和，不适合作为严格单调 Counter 使用 |
| `ocserv_uptime_seconds` | 中 | 服务运行时长辅助排障 |
| `ocserv_build_info` | 低中 | 版本定位有用，维护成本低 |
| `ocserv_user_bytes_rx/tx_rate_bytes_per_second` | 低中 | 当前明细诊断有价值，仅 Sessions 看板使用 |

### 修改采集间隔

采集实时性由三层共同决定：exporter 内部采集间隔、Prometheus 拉取间隔、Grafana 面板刷新间隔。生产默认使用 10 秒采集和 30 秒看板刷新，兼顾实时性与资源占用。

三档建议：

| 策略 | exporter / Prometheus | Grafana 刷新 | 适用场景 |
|:--|:--|:--|:--|
| 实时优先 | `5s` | `15s` | 小规模、临时排障 |
| 均衡生产 | `10s` | `30s` | 默认推荐 |
| 资源优先 | `15s` | `60s` | 在线用户较多或低配服务器 |

在 `.env` 中调整 exporter：

```env
EXPORTER_INTERVAL_SECONDS=10
OCCTL_TIMEOUT_SECONDS=2
EXPORTER_ENABLE_SESSION_DETAIL_METRICS=false
```

编辑 `monitoring/prometheus.yml`，同步调整 `scrape_interval` 和 `scrape_timeout`：

```yaml
global:
  scrape_interval: 10s      # Prometheus 拉取频率
  evaluation_interval: 30s  # 告警规则评估频率

scrape_configs:
  - job_name: "ocserv"
    scrape_timeout: 3s
```

修改 Prometheus 配置后重载 Prometheus（无需重启容器）：

```bash
docker exec prometheus wget -qO- --post-data='' http://localhost:9090/prometheus/-/reload
```

修改 `.env` 中的 exporter 间隔后需要重建或重启 exporter 容器：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --force-recreate ocserv-exporter
```

## 数据持久化

Prometheus 和 Grafana 的数据通过 Docker 卷持久化，不会因容器重建丢失：

- `prometheus_data` — Prometheus 时序数据库
- `grafana_data` — Grafana 配置、仪表盘、用户数据

## 停止监控栈

```bash
# 仅停止监控组件，保留数据
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml stop ocserv-exporter prometheus grafana nginx

# 彻底清理（包括数据）
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down -v
```

> 监控编排引用了主服务 `ocserv`，停止或清理监控栈时也要同时传入 `docker-compose.yml` 和 `docker-compose.monitoring.yml`。
