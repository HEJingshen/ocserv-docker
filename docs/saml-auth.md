# SAML 2.0认证支持

## 概述

ocserv-docker 支持通过 SAML 2.0 协议进行身份认证，使用 liblasso 库实现与 Identity Provider (IdP) 的集成。SAML（Security Assertion Markup Language）是一种基于XML的开源标准，用于在身份提供者和服务提供者之间交换认证和授权数据。

## 镜像说明

SAML认证支持的镜像通过 `Dockerfile.saml` 构建，与标准镜像的区别：

| 特性 | 标准镜像 (`Dockerfile`) | SAML镜像 (`Dockerfile.saml`) |
|:--|:--|:--|
| 认证方式 | PAM、GSSAPI、RADIUS、OTP、plain | PAM、GSSAPI、RADIUS、OTP、plain + **SAML 2.0** |
| 镜像标签 | `${VERSION}`, `latest` | `${VERSION}-saml`, `latest-saml` |
| 额外依赖 | 无 | liblasso, libxml2, libxslt, xmlsec |
| 构建要求 | 仅需ocserv源码 | 需ocserv + lasso源码 |

## 安全版本说明

### lasso 2.9.0 安全修复

当前SAML镜像使用 **lasso 2.9.0**，包含以下重要安全修复：

| CVE | CVSS评分 | 漏洞类型 | 影响 |
|:--|:--|:--|:--|
| CVE-2025-47151 | **9.8 Critical** | Type Confusion | 任意代码执行 |
| CVE-2025-46404 | 7.5 High | Null Pointer Dereference | DoS（拒绝服务） |
| CVE-2025-46705 | 7.5 High | Assertion处理错误 | DoS |
| CVE-2025-46784 | 7.5 High | 内存消耗 | DoS |

**CVE-2025-47151详情**：
- 漏洞位置：`lasso_node_impl_init_from_xml` 功能
- 攻击向量：远程发送恶意SAML响应
- CVSS 3.1向量：`AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H`
- 影响：攻击者可无需认证远程执行任意代码
- Red Hat评级：**Critical**

> ⚠️ **重要**：此前使用的lasso 2.8.2存在上述严重漏洞，强烈建议使用lasso 2.9.0构建SAML镜像。

## 构建步骤

### 准备源码

SAML构建需要两个源码包：

```bash
OCSERV_VERSION="$(cat VERSION)"
mkdir -p src

# 下载ocserv源码
curl -fsSL -o "src/ocserv-${OCSERV_VERSION}.tar.xz" \
  "https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz"

# 下载lasso 2.9.0（包含安全修复）
curl -fsSL -o src/lasso-2.9.0.tar.gz \
  https://deb.debian.org/debian/pool/main/l/lasso/lasso_2.9.0.orig.tar.gz
```

### 本地构建

```bash
docker buildx build \
  --build-arg OCSERV_VERSION="${OCSERV_VERSION}" \
  -f Dockerfile.saml \
  -t "ocserv:${OCSERV_VERSION}-saml" .
```

### CI/CD构建

GitHub Actions workflow会自动构建SAML镜像变体：
- 触发条件：`Dockerfile.saml`文件变更
- 标签：`${VERSION}-saml`, `latest-saml`
- lasso源码由workflow自动下载

## 配置示例

### ocserv.conf SAML配置

ocserv的SAML认证使用独立的INI配置文件方式：

**ocserv.conf 配置：**
```conf
# 启用SAML认证，指定配置文件路径
auth = "saml[config=/etc/ocserv/saml/config.ini]"
```

**SAML配置文件 /etc/ocserv/saml/config.ini：**
```ini
# 服务提供者(SP)元数据文件路径
sp-metadata-file = /etc/ocserv/saml/sp-metadata.xml

# 服务提供者私钥
sp-keyfile = /etc/ocserv/saml/sp-key.pem

# 服务提供者证书
sp-cert = /etc/ocserv/saml/sp-cert.pem

# 身份提供者(IdP)元数据文件路径
idp-metadata-file = /etc/ocserv/saml/idp-metadata.xml

# 身份提供者证书（可选）
idp-cert = /etc/ocserv/saml/idp-cert.pem
```

> **注意**：配置字段名称为 `sp-metadata-file`、`idp-metadata-file`，而非 `saml2-sp-metadata-file`。配置通过独立的INI文件方式，在ocserv.conf中使用 `auth = "saml[config=...]"` 指定路径。

### IdP集成

支持的主要Identity Provider：

| IdP | 配置要点 |
|:--|:--|
| Okta | 下载Metadata XML，配置Assertion Consumer Service URL |
| Azure AD | 使用Enterprise Application，配置SAML Reply URL |
| Shibboleth | 直接使用标准SAML2元数据交换 |
| Keycloak | 创建SAML Client，导出元数据 |

## 验证

### 验证lasso库集成

```bash
docker run --rm ocserv:${VERSION}-saml ldd /usr/sbin/ocserv | grep lasso
# 输出应包含：liblasso.so => /usr/lib/liblasso.so
```

### 验证镜像特性

```bash
docker inspect ocserv:${VERSION}-saml | jq '.[0].Config.Labels'
# 输出应包含："org.opencontainers.image.auth.features": "SAML2.0,PAM,GSSAPI,RADIUS,OTP"
```

## 已知问题

1. **xmlsec API兼容性**：lasso 2.9.0 已包含 xmlsec 1.3.x API 兼容修复
2. **gcc-15编译**：lasso 2.9.0 已包含 GCC 15 编译兼容修复
3. **OpenSSL 3.x**：lasso 的某些 EVP API 在 OpenSSL 3.x 中有变化

## 参考资源

- [lasso官方文档](https://lasso.entrouvert.org/)
- [ocserv SAML文档](https://www.infradead.org/ocserv/README-oidc.html)
- [CVE-2025-47151详情](https://nvd.nist.gov/vuln/detail/CVE-2025-47151)
- [Debian lasso安全追踪](https://security-tracker.debian.org/tracker/source-package/lasso)

## 贡献

欢迎提交SAML相关的问题报告、配置示例和改进建议。

## 安全增强功能

当前SAML实现包含以下安全增强功能：

### SHA-1签名算法拒绝

根据 [NIST SP 800-131A Rev. 2](https://csrc.nist.gov/pubs/sp/800/131/a/r2/final) 和 [OWASP SAML安全指南](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html) 建议，实现会自动拒绝使用SHA-1签名算法的SAML断言：

- 拒绝 `RSA-SHA1` 签名
- 拒绝 `DSA-SHA1` 签名
- 拒绝 `HMAC-SHA1` 签名

这提供了应用层的安全加固，即使lasso库可能有内置保护。

### 时钟偏差容忍配置

通过 `clock-skew-tolerance` 配置项，可以调整SAML断言时间验证的容忍度：

```ini
# 时钟偏差容忍时间（秒）
# 默认60秒，适用于大多数IdP
# 如果IdP时钟偏差较大，可增加此值
clock-skew-tolerance = 60
```

**适用场景**：
- IdP服务器时钟与SP有较大偏差
- 跨地域部署导致的时间同步问题
- 高延迟网络环境

### 资源管理

实现正确遵循lasso库生命周期：
- `lasso_init()` 返回值检查，确保初始化成功
- `lasso_shutdown()` 在服务关闭时调用，释放所有资源

### 文件安全

SP元数据文件使用安全方式存储：
- 存储位置：`/run/ocserv/`（tmpfs挂载）
- 使用 `O_NOFOLLOW` 和 `O_EXCL` 标志防止symlink攻击
- 避免使用 `/tmp` 目录的安全风险

## 配置验证脚本

项目包含配置验证脚本 `scripts/validate-saml-config.sh`，用于检查配置完整性：

```bash
# 运行配置验证
docker run --rm -v ./config/saml:/etc/ocserv/saml ocserv:${VERSION}-saml \
  /scripts/validate-saml-config.sh /etc/ocserv/saml/config.ini
```

验证内容包括：
- 配置文件是否存在
- 必需字段是否配置
- 元数据/证书文件是否存在
- XML基本结构验证
