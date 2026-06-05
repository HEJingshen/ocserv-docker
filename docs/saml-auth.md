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
auth = "saml2[config=/etc/ocserv/saml/config.ini]"
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

> **注意**：配置字段名称为 `sp-metadata-file`、`idp-metadata-file`，而非 `saml2-sp-metadata-file`。配置通过独立的INI文件方式，在ocserv.conf中使用 `auth = "saml2[config=...]"` 指定路径。

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

1. **xmlsec API兼容性**：lasso需要与xmlsec 1.3.x API兼容的补丁，已在Dockerfile.saml中应用
2. **gcc-15编译**：lasso 2.9.0需要gcc-15兼容补丁
3. **OpenSSL 3.x**：lasso的某些EVP API在OpenSSL 3.x中有变化

## 参考资源

- [lasso官方文档](https://lasso.entrouvert.org/)
- [ocserv SAML文档](https://www.infradead.org/ocserv/README-oidc.html)
- [CVE-2025-47151详情](https://nvd.nist.gov/vuln/detail/CVE-2025-47151)
- [Debian lasso安全追踪](https://security-tracker.debian.org/tracker/source-package/lasso)

## 贡献

欢迎提交SAML相关的问题报告、配置示例和改进建议。