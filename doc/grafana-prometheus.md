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

项目已内置 ocserv 监控面板，登录后在 **Dashboards** 中即可看到：

- **活跃用户数** — 当前连接的 VPN 客户端数量
- **上下行流量** — 累计收发字节数
- **服务运行时长** — ocserv 进程持续运行时间
- **版本信息** — ocserv 构建版本

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

编辑 `monitoring/prometheus.yml`，调整 `scrape_interval`：

```yaml
global:
  scrape_interval: 15s    # 采集频率
  evaluation_interval: 15s  # 告警规则评估频率
```

修改后重载 Prometheus（无需重启容器）：

```bash
docker exec prometheus wget -qO- --post-data='' http://localhost:9090/-/reload
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
