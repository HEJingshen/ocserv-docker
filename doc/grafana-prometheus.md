# Grafana + Prometheus 监控

通过 Prometheus 采集 ocserv 运行指标，Grafana 提供可视化面板，Nginx 提供 HTTPS 反向代理。

## 架构概览

```
ocserv → ocserv-exporter → Prometheus → Grafana
                                    ↑
                              Nginx (HTTPS 入口)
```

- **ocserv-exporter**：通过 ocserv Unix socket 采集活跃用户、流量、运行时长等指标
- **Prometheus**：定时拉取指标并存储为时序数据
- **Grafana**：读取 Prometheus 数据，展示可视化仪表盘
- **Nginx**：HTTPS 入口（8443 端口），通过子路径 `/grafana/` 和 `/prometheus/` 分发请求。80 端口保留给 certbot 证书续期使用。

## 部署前准备

### 1. 申请 SSL 证书

```bash
sudo certbot certonly --standalone -d your.domain.com \
  --agree-tos --email your@email.com
```

证书默认保存在 `/etc/letsencrypt/live/your.domain.com/`，已自动挂载到 Nginx 容器。

### 2. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑 .env 文件，修改以下关键配置：
vim .env
```

**必须修改的变量**：

| 变量 | 说明 | 示例 |
|:--|:--|:--|
| `DOMAIN` | 你的域名 | `vpn.example.com` |
| `GF_ADMIN_PASSWORD` | Grafana 管理员密码（建议修改默认值） | `your_secure_password` |
| `SSL_CERT_DIR` | SSL 证书目录（如果非默认路径） | `/etc/letsencrypt` |

> **注意**：域名配置现在集中在 `.env` 文件中，无需手动修改 `docker-compose.monitoring.yml` 或 `nginx/conf.d/` 中的硬编码域名。Nginx 配置会在容器启动时通过 `envsubst` 自动生成。

### 3. 生成 Prometheus 访问密码

```bash
sudo apt install apache2-utils -y
htpasswd -c nginx/.htpasswd admin
```

按提示设置密码，此密码用于访问 `/prometheus/` 路径。

## 启动监控栈

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

验证各服务是否正常：

```bash
# 检查 Nginx 配置
docker exec nginx-proxy nginx -t

# 检查 Prometheus 健康
docker exec prometheus wget -qO- http://localhost:9090/prometheus/-/healthy

# 查看 Grafana 日志
docker logs grafana
```

## 访问地址

| 服务 | 地址 | 认证方式 |
|:--|:--|:--|
| Grafana | `https://${DOMAIN}:${MONITORING_PORT}/grafana/` | admin / `${GF_ADMIN_PASSWORD}` |
| Prometheus | `https://${DOMAIN}:${MONITORING_PORT}/prometheus/` | htpasswd（步骤 3 设置） |

> 实际访问地址由 `.env` 文件中的 `DOMAIN` 和 `MONITORING_PORT` 变量决定。默认 `MONITORING_PORT=8443`，VPN 服务使用 `${OCSERV_PORT:-443}` 端口。

## Grafana 使用指南

### 首次登录

1. 打开 `https://${DOMAIN}:${MONITORING_PORT}/grafana/`（替换为你的实际域名）
2. 用户名 `admin`，密码为 `.env` 文件中 `GF_ADMIN_PASSWORD` 的值（默认 `admin123`）
3. 登录后建议修改默认密码（Settings → Password）

### 查看仪表盘

项目已内置两个 ocserv 监控面板，登录后在 **Dashboards** 中即可看到：

- **Ocserv VPN Overview** — 生产默认概览看板，15 秒刷新，保留服务状态、活跃用户、实时速率、采集错误、采集耗时和当前用户明细。
- **Ocserv VPN Details** — 低频详情看板，30 秒刷新，保留版本、运行时长、累计流量、用户趋势、排行和连接时长，适合排障和分析时打开。

默认长期打开 `Ocserv VPN Overview`。`Ocserv VPN Details` 查询更多用户级和历史趋势数据，不建议作为常驻大屏。

### 添加自定义告警

1. 进入目标面板，点击指标名称 → **Edit**
2. 在右侧 **Alert** 标签中设置规则，例如：
   - `ocserv_active_users > 14` → 连接数接近上限时告警
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
- Nginx 出现 `upstream timed out`：更像查询慢或 Prometheus 响应慢，优先检查详情看板是否长期打开、Prometheus 负载和查询时间范围。

修改 `.env` 中的 Grafana 资源限制后需要重建 Grafana 容器：

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --force-recreate grafana
```

## Prometheus 使用指南

### 查看已采集的指标

访问 `https://${DOMAIN}:${MONITORING_PORT}/prometheus/graph`（替换为你的实际域名），在查询框输入指标名称查看实时数据：

| 指标名 | 类型 | 说明 |
|:--|:--|:--|
| `ocserv_up` | Gauge | 服务状态（1=正常，0=异常） |
| `ocserv_active_users` | Gauge | 当前活跃用户数 |
| `ocserv_uptime_seconds` | Gauge | 运行时长（秒） |
| `ocserv_bytes_rx_total` | Gauge | 累计接收字节数 |
| `ocserv_bytes_tx_total` | Gauge | 累计发送字节数 |
| `ocserv_bytes_rx_rate_bytes_per_second` | Gauge | 当前接收速率（字节/秒） |
| `ocserv_bytes_tx_rate_bytes_per_second` | Gauge | 当前发送速率（字节/秒） |
| `ocserv_build_info` | Info | ocserv 版本信息 |

### 常用查询语句

```
# 当前活跃用户数
ocserv_active_users

# 当前接收速率（字节/秒）
ocserv_bytes_rx_rate_bytes_per_second

# 历史兼容：基于累计值计算近 1 分钟平均接收速率
rate(ocserv_bytes_rx_total[1m])

# 服务是否在线
ocserv_up
```

### 修改采集间隔

采集实时性由三层共同决定：exporter 内部采集间隔、Prometheus 拉取间隔、Grafana 面板刷新间隔。少于 10 个同时在线用户的生产环境建议 exporter 和 Prometheus 保持 5 秒采集，Grafana 生产概览看板使用 15 秒刷新；10-100 人建议采集和看板都使用 10-15 秒；超过 100 人建议使用 15 秒或更长。

在 `.env` 中调整 exporter：

```env
EXPORTER_INTERVAL_SECONDS=5
OCCTL_TIMEOUT_SECONDS=2
```

编辑 `monitoring/prometheus.yml`，同步调整 `scrape_interval` 和 `scrape_timeout`：

```yaml
global:
  scrape_interval: 5s       # Prometheus 拉取频率
  evaluation_interval: 15s  # 告警规则评估频率

scrape_configs:
  - job_name: "ocserv"
    scrape_timeout: 3s
```

修改 Prometheus 配置后重载 Prometheus（无需重启容器）：

```bash
docker exec prometheus wget -qO- --post-data='' http://localhost:9090/-/reload
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
docker compose -f docker-compose.monitoring.yml down

# 彻底清理（包括数据）
docker compose -f docker-compose.monitoring.yml down -v
```

> 主 VPN 服务（`docker-compose.yml`）不受影响。
