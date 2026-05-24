# ocserv-docker

[![Build & Pull](https://github.com/GentleKingson/ocserv-docker/actions/workflows/docker-build.yml/badge.svg)](https://github.com/GentleKingson/ocserv-docker/actions/workflows/docker-build.yml)
[![Docker Image Version](https://img.shields.io/docker/v/kingsonho/ocserv?sort=semver)](https://hub.docker.com/r/kingsonho/ocserv/tags)

基于 Docker 的 OpenConnect Server（ocserv），支持 **多架构**（amd64 / arm64），内置 **s6-overlay 进程管理**，可选 **Prometheus + Grafana 监控栈**。

完整部署文档见 [docs/README.md](docs/README.md)，架构说明见 [docs/project-architecture.md](docs/project-architecture.md)。

## 许可证

[GPL-2.0-or-later](https://www.gnu.org/licenses/gpl-2.0.html)
