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
| Okta | 下载Metadata XML，ACS URL 设为 `https://your-domain/+CSCOE+/saml/sp/acs` |
| Azure AD | 使用Enterprise Application，SAML Reply URL 设为 `https://your-domain/+CSCOE+/saml/sp/acs` |
| Shibboleth | 直接使用标准SAML2元数据交换 |
| Keycloak | 创建SAML Client，导出元数据 |

## Okta SAML 配置指南

本节提供 Okta 作为 Identity Provider 的完整配置步骤。

### 前提条件

- Okta 管理员账户（或具有应用创建权限的账户）
- VPN 服务器域名（如 `vpn.example.com`）已配置 DNS 解析
- VPN 服务器 443 端口（TCP/UDP）已开放
- 已构建 SAML 版本的 ocserv Docker 镜像

### Step 1: 在 Okta 创建 SAML 应用

1. 登录 Okta Admin Console（`https://your-org.okta.com`）
2. 导航到 **Applications** → **Applications**
3. 点击 **Create App Integration**
4. 在 **Sign-in method** 中选择 **SAML 2.0**
5. 点击 **Next**

### Step 2: 配置 General Settings

| 字段 | 值 |
|:--|:--|
| **App name** | `VPN - your-domain.com`（如 `VPN - dev.hokingson.com`）|
| **App logo** | 可选，上传 VPN 图标 |
| **App visibility** | 勾选 **Display application icon to users** |

点击 **Next**。

### Step 3: 配置 SAML Settings（关键步骤）

#### A. SAML 通用设置

| 字段 | 值 | 说明 |
|:--|:--|:--|
| **Single sign-on URL** | `https://your-domain/+CSCOE+/saml/sp/acs` | ACS 端点，必须使用 AnyConnect SSO-v2 路径 |
| **Recipient URL** | `https://your-domain/+CSCOE+/saml/sp/acs` | 同 Single sign-on URL |
| **Destination URL** | `https://your-domain/+CSCOE+/saml/sp/acs` | 同 Single sign-on URL |
| **Audience URI (SP Entity ID)** | `https://your-domain` | SP Entity ID，与 SP 元数据中的 entityID 一致 |
| **Default RelayState** | 留空 | 不需要 |

> **重要**: ACS URL 必须使用 `/+CSCOE+/saml/sp/acs` 路径，这是 Cisco AnyConnect SSO-v2 协议的标准路径。不要使用其他路径（如 `/SAML2/POST`）。

#### B. 用户属性和声明（Attribute Statements）

在 **Attribute Statements (Optional)** 部分添加：

| Name | Name format | Value |
|:--|:--|:--|
| `Username` | Unspecified | `user.userName` |
| `Email` | Unspecified | `user.email` |
| `FirstName` | Unspecified | `user.firstName` |
| `LastName` | Unspecified | `user.lastName` |

#### C. Name ID 设置

| 字段 | 值 |
|:--|:--|
| **Name ID format** | `EmailAddress` |
| **Application username** | `Okta username` |
| **Update application username on** | `Create and update` |

#### D. 签名设置

| 字段 | 值 | 说明 |
|:--|:--|:--|
| **Signature Algorithm** | `RSA-SHA256` | **必须使用 SHA256**，项目拒绝 SHA-1 |
| **Assertion Signature** | `Sign assertion` | 签名断言 |
| **Response Signature** | `Sign response` | 可选，推荐启用 |
| **Digest Algorithm** | `SHA256` | **必须使用 SHA256** |
| **Assertion Encryption** | `Unencrypted` | ocserv 不需要加密断言 |
| **Enable Single Logout** | 不勾选 | SSO-v2 不使用 SAML SLO |
| **Honor Force Authentication** | 勾选 | 推荐启用 |

点击 **Next** → **Finish**。

### Step 4: 获取 Okta IdP 元数据

1. 在应用详情页，点击 **Sign On** 标签
2. 点击 **View SAML setup instructions**
3. 找到 **Identity Provider Metadata** 链接（格式为 `https://your-org.okta.com/app/xxxxx/sso/saml/metadata`）
4. 下载并保存为 `config/saml/idp-metadata.xml`：

```bash
curl -fsSL -o config/saml/idp-metadata.xml \
  "https://your-org.okta.com/app/xxxxx/sso/saml/metadata"
```

### Step 5: 生成 SP 证书和私钥

```bash
# 生成 2048 位 RSA 私钥
openssl genrsa -out config/saml/sp-key.pem 2048

# 生成 10 年有效期自签名证书，将 CN 替换为你的 VPN 域名
openssl req -new -x509 -key config/saml/sp-key.pem \
  -out config/saml/sp-cert.pem -days 3650 \
  -subj "/CN=https://your-domain"

# 设置私钥权限
chmod 600 config/saml/sp-key.pem
```

### Step 6: 创建 SP 元数据文件

创建 `config/saml/sp-metadata.xml`，替换域名和证书内容：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<EntityDescriptor xmlns="urn:oasis:names:tc:SAML:2.0:metadata"
  entityID="https://your-domain">
  <SPSSODescriptor AuthnRequestsSigned="true"
    WantAssertionsSigned="true"
    protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">
    <KeyDescriptor use="signing">
      <ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">
        <ds:X509Data>
          <ds:X509Certificate>
<!-- 插入 sp-cert.pem 的内容（去掉 BEGIN/END 行） -->
          </ds:X509Certificate>
        </ds:X509Data>
      </ds:KeyInfo>
    </KeyDescriptor>
    <AssertionConsumerService
      Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
      Location="https://your-domain/+CSCOE+/saml/sp/acs"
      index="0" isDefault="true"/>
  </SPSSODescriptor>
</EntityDescriptor>
```

自动插入证书：

```bash
CERT=$(grep -v "BEGIN\|END" config/saml/sp-cert.pem | tr -d '\n')
sed -i "s|<!-- 插入.*-->|${CERT}|" config/saml/sp-metadata.xml
```

### Step 7: 配置 ocserv SAML

创建 `config/saml/config.ini`：

```ini
sp-metadata-file = /etc/ocserv/saml/sp-metadata.xml
sp-keyfile = /etc/ocserv/saml/sp-key.pem
sp-cert = /etc/ocserv/saml/sp-cert.pem
idp-metadata-file = /etc/ocserv/saml/idp-metadata.xml
clock-skew-tolerance = 60
replay-cache-ttl = 300
```

在 `ocserv.conf` 中启用 SAML：

```conf
auth = "saml[config=/etc/ocserv/saml/config.ini]"
```

> **注意**: 确保 `default-domain` 配置正确，SSO-v2 XML 使用此值填充 URL：
> ```conf
> default-domain = your-domain
> ```

### Step 8: 分配用户

1. 在 Okta 应用详情页，点击 **Assignments** 标签
2. 点击 **Assign** → **Assign to People** 或 **Assign to Groups**
3. 选择需要 VPN 访问权限的用户或组
4. 点击 **Save and Go Back** → **Done**

### 启动服务

```bash
docker compose --profile saml up -d ocserv-saml
```

### 验证连接

1. 使用 Cisco AnyConnect 客户端连接 `https://your-domain`
2. AnyConnect 自动打开内嵌浏览器，跳转到 Okta 登录页
3. 输入 Okta 凭据完成认证
4. 认证成功后 VPN 自动连接

### 常见问题排查

| 问题 | 原因 | 解决方法 |
|:--|:--|:--|
| AnyConnect 提示 "connection attempt failed" | ACS URL 配置不正确 | 确认 Okta 和 SP 元数据中 ACS URL 为 `/+CSCOE+/saml/sp/acs` |
| Okta 报错 "The SAML assertion is invalid" | SP Entity ID 不匹配 | 确认 Okta Audience URI 与 SP 元数据 entityID 一致 |
| 认证成功但 VPN 未连接 | sso-token 流程失败 | 检查 ocserv 日志中 SAML 相关错误 |
| 签名验证失败 | SHA-1 算法被拒绝 | 确认 Okta Signature Algorithm 设为 RSA-SHA256 |
| 断言过期 | 服务器时钟偏差过大 | 增加 `clock-skew-tolerance` 值（最大 3600 秒）|
| IdP 元数据无效 | Okta 证书轮换 | 重新下载 IdP 元数据文件 |
| 用户无法看到应用 | 未分配用户 | 在 Okta Assignments 中分配用户或组 |

### Okta 参考文档

- [Okta SAML 概念](https://developer.okta.com/docs/concepts/saml/)
- [创建私有 SSO 集成](https://developer.okta.com/docs/guides/add-private-app/main/)
- [构建 SSO 集成](https://developer.okta.com/docs/guides/build-sso-integration/saml2/main/)
- [SAML 常见问题](https://developer.okta.com/docs/concepts/saml/faqs/)

### AnyConnect SSO-v2 协议

本实现使用 Cisco AnyConnect **SSO-v2** 协议，支持 AnyConnect 内嵌浏览器完成 SAML 认证：

1. AnyConnect 连接时收到 SSO-v2 XML，自动打开内嵌浏览器
2. 内嵌浏览器访问 `/+CSCOE+/saml/sp/login`，被重定向到 IdP
3. 用户在 IdP 完成认证后，浏览器 POST SAMLResponse 到 `/+CSCOE+/saml/sp/acs`
4. ACS handler 返回桥接 HTML，自动提交 SAMLResponse 到 `/+webvpn+/index.html`
5. ocserv 验证 SAMLResponse，设置 `acSamlv2Token` cookie
6. AnyConnect 读取 cookie 中的 sso-token，完成 VPN 连接

**SP 元数据中的 ACS URL 必须设为**: `https://your-domain/+CSCOE+/saml/sp/acs`

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

根据 [NIST SP 800-131A Rev. 2](https://csrc.nist.gov/pubs/sp/800/131/a/r2/final) 和 [OWASP SAML安全指南](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html) 建议，实现会自动拒绝使用SHA-1签名或摘要算法的SAML断言：

- 拒绝 `RSA-SHA1` 签名
- 拒绝 `DSA-SHA1` 签名
- 拒绝 `HMAC-SHA1` 签名
- 拒绝 XML `SignatureMethod` 或 `DigestMethod` 中的 SHA-1 算法

这提供了应用层的安全加固，即使lasso库可能有内置保护。

### 响应绑定与防重放

SAML认证仅接受 SP-initiated 响应。IdP 返回的 `Response` 和 `SubjectConfirmationData` 必须包含与本次 `AuthnRequest` ID 匹配的 `InResponseTo`，并且断言必须包含以下字段：

- `Response Destination`：必须精确匹配SP的ACS URL
- `SubjectConfirmationData Recipient`：必须精确匹配SP的ACS URL
- `SubjectConfirmationData NotOnOrAfter`：必须存在且未过期
- `Conditions NotOnOrAfter`：必须存在且未过期
- `AudienceRestriction`：必须包含SP Entity ID

认证通过后，模块会在进程内缓存已消费的 `Response ID`、`Assertion ID` 和 `InResponseTo`，拒绝有效期内重复提交的SAML响应。缓存默认根据断言过期时间失效，异常情况下使用 `replay-cache-ttl` 作为兜底TTL。

```ini
# 防重放缓存兜底时间（秒）
# 默认300秒，最大86400秒
replay-cache-ttl = 300
```

### 时钟偏差容忍配置

通过 `clock-skew-tolerance` 配置项，可以调整SAML断言时间验证的容忍度：

```ini
# 时钟偏差容忍时间（秒）
# 默认60秒，适用于大多数IdP
# 如果IdP时钟偏差较大，可增加此值
# 最大3600秒
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
