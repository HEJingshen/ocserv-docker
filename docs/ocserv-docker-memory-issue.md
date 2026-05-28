# ocserv Docker 内存增长问题说明

## 一、问题表现

在 Docker 容器中运行 ocserv 时，曾观察到容器内存持续增长，并在接近 `OCSERV_MEM_LIMIT=512m` 后出现回落，随后再次增长，形成周期性波动。该过程中 VPN 连接保持可用，客户端未出现明显断线。

同一份 ocserv 配置在宿主机直接运行时未复现该内存增长行为，说明问题与容器运行环境及 ocserv worker 隔离机制的组合有关，而不是单纯由用户连接数、流量或基础配置引起。

典型表现如下：

| 现象 | 说明 |
|:--|:--|
| 容器内存持续增长 | `docker stats` 中 `ocserv` 内存使用随时间上升 |
| 到达限制后回落 | 接近 `512m` cgroup 限制后释放，再进入下一轮增长 |
| 连接不中断 | 内存回落过程中客户端连接通常保持正常 |
| 宿主机运行正常 | 同配置在非 Docker 环境中未出现相同行为 |

## 二、影响范围

该问题主要影响在 Docker 容器内启用 ocserv worker 隔离的场景。需要区分以下三类机制：

| 机制 | 控制位置 | 本项目策略 |
|:--|:--|:--|
| ocserv 编译期 seccomp 能力 | `Dockerfile` Meson 参数 `-Dseccomp` | 当前 ocserv 镜像禁用 |
| ocserv worker 隔离 | `ocserv.conf` 中 `isolate-workers` | 默认 `false` |
| Docker 运行时 seccomp profile | Docker daemon / Compose 运行时 | 保留 Docker 默认值，不设置 `seccomp=unconfined` |

本项目禁用的是 ocserv 内部 worker 的 seccomp 编译能力和 worker 隔离默认配置，不等同于关闭 Docker 容器运行时的安全边界。容器仍由 Docker 提供 namespace、capabilities、cgroup 和默认 seccomp profile 等运行时约束。

## 三、根因分析

ocserv 的 `isolate-workers` 用于为 worker 进程启用基于 seccomp 和 Linux namespace 的隔离。该设计在宿主机直接运行时可以减少 worker 进程被利用后的影响面。

在 Docker 中，容器本身已经运行在 namespace、cgroup 和 seccomp profile 之下。如果 ocserv worker 再次创建独立 namespace 并叠加 seccomp 限制，就会形成嵌套隔离结构：

```text
Docker 容器隔离
  └── ocserv 主进程
      └── ocserv worker 隔离
          ├── namespace
          └── seccomp
```

本次问题的表现与嵌套隔离后的资源清理异常一致：worker 生命周期结束或连接状态变化后，相关 namespace 或匿名内存未能按预期释放，导致 `RssAnon` 持续累积。达到 Docker cgroup 内存限制附近后，内核和进程清理行为使内存回落，随后继续进入下一轮增长。

结合对比结果，可以排除以下方向作为主要根因：

| 排查方向 | 结论 |
|:--|:--|
| 单纯 musl/glibc 差异 | 不是主要根因；同配置差异集中在 Docker 环境 |
| exporter 高频采集 | 未启用监控栈时仍可复现，非必要条件 |
| `output-buffer` 等流量参数 | 未解释宿主机与 Docker 的行为差异 |

## 四、解决方案

项目采用以下默认策略规避该问题：

1. 当前 ocserv 镜像禁用 ocserv 的 seccomp 编译能力。
2. `config/ocserv.conf.template` 默认设置 `isolate-workers = false`。
3. 不在 Compose 中设置 `security_opt: seccomp=unconfined`，保留 Docker 默认运行时 seccomp profile。

确认当前配置：

```bash
grep -n '^isolate-workers' config/ocserv.conf.template
grep -n '^isolate-workers' config/ocserv.conf
```

期望输出均为：

```text
isolate-workers = false
```

如果生成配置仍为旧值，重新渲染并重启服务：

```bash
./scripts/render-ocserv-conf.sh
docker compose restart ocserv
```

## 五、验证方法

先用 Docker 统计确认容器级内存趋势：

```bash
docker stats --no-stream ocserv
```

再查看 ocserv 当前状态和用户连接：

```bash
docker exec ocserv occtl -s /run/ocserv/occtl.socket show status
docker exec ocserv occtl -s /run/ocserv/occtl.socket show users
```

如需定位到具体进程，观察 `VmRSS`、`VmHWM` 和 `RssAnon`：

```bash
docker exec ocserv sh -c '
for p in /proc/[0-9]*; do
  comm=$(cat "$p/comm" 2>/dev/null || true)
  case "$comm" in
    ocserv*)
      echo "--- pid ${p##*/} $comm ---"
      grep -E "Name|State|VmRSS|VmHWM|VmSize|RssAnon|RssFile|Threads" "$p/status" 2>/dev/null || true
      ;;
  esac
done
'
```

修复生效后，预期结果是 `ocserv` 容器内存不再在持续流量下单调增长至 `512m` 后周期性回落；单个 `ocserv-worker` 的 `RssAnon` 也不应持续累积而不释放。

项目同时通过静态测试防止配置回退：

```bash
python3 -m unittest tests/test_static_config.py
```

该测试会检查：

- `Dockerfile` 不再包含 `libseccomp-dev`
- `Dockerfile` 不再包含 `-Dseccomp=enabled`
- 当前 ocserv 镜像使用 `-Dseccomp=disabled`
- `config/ocserv.conf.template` 默认包含 `isolate-workers = false`

## 六、安全权衡

关闭 ocserv worker 隔离会减少 ocserv 内部对 worker 进程的 syscall 约束，理论上降低了一层应用内部防护。但在本项目的 Docker 部署模型中，容器运行时仍保留默认 seccomp profile，并通过 namespace、cgroup、capabilities 和只读配置挂载限制容器边界。

当前取舍是生产稳定性优先：避免 Docker 内嵌套 namespace/seccomp 组合引发内存增长，同时保留 Docker 运行时提供的隔离能力。除非明确需要在非 Docker 环境中验证 ocserv worker 隔离，否则不建议在本项目默认容器部署中重新启用 `isolate-workers`。
