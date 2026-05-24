# Fail2Ban 防护

Fail2Ban 用于保护 Grafana 登录入口免受暴力破解攻击。当同一 IP 在短时间内多次登录失败时，自动封禁该 IP。

## 工作原理

| 规则 | 值 | 说明 |
|:--|:--|:--|
| `maxretry` | 5 | 10 分钟内允许的最大失败次数 |
| `bantime` | 3600（1 小时） | 封禁持续时间 |
| `findtime` | 600（10 分钟） | 统计失败次数的时间窗口 |
| 封禁方式 | nftables | 通过防火墙规则拦截 IP |

## 安装部署

```bash
./scripts/setup-fail2ban.sh
```

脚本会自动完成：
1. 安装 Fail2Ban + nftables
2. 部署过滤器（匹配 Nginx 401/403 登录失败日志）
3. 部署监狱配置（指向 Nginx 访问日志）
4. 启动并启用 Fail2Ban 服务

## 验证状态

```bash
# 查看 nginx-auth 监狱状态
sudo fail2ban-client status nginx-auth

# 查看所有生效的监狱
sudo fail2ban-client status
```

输出示例：
```
Status for the jail: nginx-auth
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     12
|  `- File list:        /path/to/nginx/logs/access.log
`- Actions
   |- Currently banned: 1
   |- Total banned:     3
   `- Banned IP list:   203.0.113.45
```

## 测试封禁效果

模拟连续登录失败（触发 5 次后封禁）：

```bash
for i in {1..6}; do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H 'Content-Type: application/json' \
    -d '{"user":"admin","password":"wrong"}' \
    https://your.domain.com:8443/grafana/login
done
```

等待约 10 秒后检查封禁列表：

```bash
sudo fail2ban-client get nginx-auth banned
```

实时查看封禁日志：

```bash
sudo tail -f /var/log/fail2ban.log | grep nginx-auth
```

## 管理封禁

```bash
# 手动解封 IP
sudo fail2ban-client set nginx-auth unbanip 203.0.113.45

# 临时调整封禁时间（秒），无需重启
sudo fail2ban-client set nginx-auth bantime 7200
```

## 配置文件位置

| 文件 | 说明 |
|:--|:--|
| `/etc/fail2ban/filter.d/nginx-auth.conf` | 过滤器规则（匹配失败请求） |
| `/etc/fail2ban/jail.d/nginx-auth.conf` | 监狱配置（封禁参数） |
| `/var/log/fail2ban.log` | Fail2Ban 运行日志 |

## 修改配置后重载

编辑过滤器或监狱配置后，重载使其生效：

```bash
sudo fail2ban-client reload nginx-auth
```

## 测试过滤器匹配

用真实 Nginx 日志验证过滤器是否正确匹配：

```bash
sudo fail2ban-regex /path/to/nginx/logs/access.log /etc/fail2ban/filter.d/nginx-auth.conf
```

输出中 `Matched` 数量应大于 0，否则检查日志路径和规则。
