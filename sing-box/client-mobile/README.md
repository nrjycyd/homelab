# sing-box client-mobile — 手机端透明代理配置

## 概述

- **名称**: `client-mobile`（与网关端 `client-debian` 配对，同是 sing-box 客户端，按部署环境区分）
- **版本**: sing-box **1.14.0**
- **适用客户端**: SFA（Android）/ SFI（iOS）通用
- **模式**: TUN 虚拟网卡接管全局流量，无需 root/越狱

## 文件清单

| 文件 | 说明 |
|:-----|:-----|
| `sing-box-mobile-config-1.14.0.json` | 基础版正式配置（不含回家节点） |
| `sing-box-mobile-gh-config-1.14.0.json` | 基础版 **+ 回家节点**（gh） |
| `sing-box-mobile-template.json` | 基础版脱敏可填写模板 |
| `sing-box-mobile-gh-template.json` | 回家版脱敏可填写模板 |
| `README.md` | 本文件 |

> gh 版 = 基础版 + 回家相关内容（`gh` 选择器、`<gh-1>` / `<gh-2>` 节点、`speed-gh` 测速、`10.0.0.0/24` + `10.0.1.0/24` 路由），其余部分两份保持一致，便于 diff 维护。

## 架构

```
手机全局流量
   │
   ▼
TUN(tun-in) ──► sniff / hijack-dns
   │               │
   │               ▼
   │          DNS 模块（瀑布流分流）
   │               ├─ 国内域 / 自定义直连 → local-dns（系统 DNS）→ 直连
   │               ├─ 国外域 / 自定义代理 → remote-dns（DoH dns.google，走代理）
   │               └─ 兜底 → remote-dns 带 ECS 解析，命中 geoip-cn 则直连，否则代理
   ▼
路由规则（与 DNS 同瀑布流）
   ├─ 10.0.0.0/24、10.0.1.0/24 → gh（回家，仅 gh 版）
   ├─ 国内 IP → direct
   └─ 其余 → select（默认 <node-2>）
```

### DNS 服务器

| tag | 类型 | 用途 |
|:----|:-----|:-----|
| `ali-dns` | DoQ `223.5.5.5:853` | 引导解析：`remote-dns` 域名、各 outbound 服务器域名的默认解析（`route.default_domain_resolver`） |
| `local-dns` | `local` | 手机系统 DNS（iOS/Android 当前网络 DHCP DNS；在家即网关 DNS），国内/直连域名解析 |
| `remote-dns` | DoH `dns.google` | 国外域名解析，`detour: proxy` 走代理，防泄漏 |

## 分流设计（DNS 与路由规则同瀑布流，首条命中即停）

| 序号 | 规则 | 动作 |
|:---:|:-----|:-----|
| 1 | 局域网 (geosite-private) | 本地 DNS / 直连 |
| 2a | cusdom-reject | NXDOMAIN / 拦截 |
| 2b | cusdom-proxy | 走代理 DNS（禁 AAAA）/ 代理 |
| 2c | cusdom-direct | 本地 DNS / 直连 |
| 3 | 广告 (category-ads-all) | NXDOMAIN / 拦截 |
| 4 | apple-cn | 本地 DNS / 直连 |
| 5 | google-cn | 本地 DNS / 直连 |
| 6 | geolocation-!cn | 走代理 DNS（禁 AAAA）/ 代理 |
| 7 | 国内域 (cn) | 本地 DNS / 直连 |
| 8 | 兜底 realip | 解析后国内 IP 直连，否则代理 |

- **禁 v6**：顶部拦截 SOA/PTR/HTTPS/SVCB，非国内路径 2b/6 拦截 AAAA 记录 → 天然禁 v6
- **防 DNS 泄漏**：公共 DNS（1.1.1.1 / 8.8.8.8 等）走代理；阿里 DNS 直连；拒 DoT / UDP443 / STUN

## 部署

1. 在 SFA / SFI 导入所需配置：
   - 不需要回家：`sing-box-mobile-config-1.14.0.json`
   - 需要回家：`sing-box-mobile-gh-config-1.14.0.json`
2. 授权 VPN 连接即可，全自动分流

> 配置含 `//` 注释（sing-box 支持）。若某客户端导入报 JSON 解析错误，请改用无注释版本（去掉注释行后导入即可）。

## 模板填写

从模板生成配置时，逐项替换所有 `<...>` 占位符。占位符命名规则：

- `node-*`：普通代理节点（基础版）；`gh-*`：回家节点（仅 gh 版）
- 模板开头附有说明注释，删除不需要的块（如无 obfs / 无内联证书）后即为可用配置

### 代理节点（`<node-1>` / `<node-2>` / `<node-3>`）

| 占位符 | 含义 |
|:-----|:-----|
| `<node-1>` / `<node-2>` / `<node-3>` | 节点 tag（出现在选择器 `outbounds` 里，需与节点定义一致） |
| `<node-1-server>` / `<node-2-server>` / `<node-3-server>` | 服务器地址（IP 或域名） |
| `<node-1-sni>` / `<node-2-sni>` / `<node-3-sni>` | TLS `server_name`（SNI） |
| `<node-1-password>` / `<node-2-password>` | Hysteria2 密码 |
| `<node-1-obfs-password>` / `<node-2-obfs-password>` | Hysteria2 obfs（salamander）密码；无 obfs 则删除 `obfs` 块 |
| `<node-3-uuid>` | VLESS UUID |
| `<node-1-cert>` / `<node-2-cert>` | 内联证书 PEM；不校验证书可删除 `certificate` 块 |

### 回家节点（`<gh-1>` / `<gh-2>`，仅 gh 版）

| 占位符 | 含义 |
|:-----|:-----|
| `<gh-1>` / `<gh-2>` | 回家节点 tag（`gh` 选择器默认 `<gh-1>`） |
| `<gh-1-server>` / `<gh-2-server>` | 回家服务器域名/地址（纯 IPv6，只有 AAAA 记录） |
| `<gh-1-sni>` / `<gh-2-sni>` | TLS `server_name`（SNI） |
| `<gh-1-password>` / `<gh-2-password>` | Hysteria2 密码 |
| `<gh-1-cert>` / `<gh-2-cert>` | 内联证书 PEM |

### 自定义域名与其它

| 占位符 | 含义 |
|:-----|:-----|
| `<reject-domain>` | cusdom-reject 自定义拒绝域名 |
| `<proxy-domain>` | cusdom-proxy 自定义代理域名 |
| `<direct-domain>` | cusdom-direct 自定义直连域名 |
| `<direct-domain-suffix-1>` / `<direct-domain-suffix-2>` | cusdom-direct 自定义直连域名后缀 |
| `<client-subnet-cidr>` | 兜底 realip 解析的 EDNS Client Subnet（填自己所在网段；不需要可删除 `client_subnet`） |

### 模板中的示例值（非占位符，按需修改）

| 字段 | 示例 | 说明 |
|:-----|:-----|:-----|
| `server_ports` | `["30000:50000"]` | Hysteria2 端口跳跃范围（`<node-1>` / `<node-2>`） |
| `server_port` | `17567` / `17569` | 回家节点端口（`<gh-1>` / `<gh-2>`），JSON 数字无法用占位符 |
| `up_mbps` / `down_mbps` | `50` / `100` | Hysteria2 带宽上限 |
| `mtu` | `9000` | TUN MTU |
| rule-set `url` | MetaCubeX/meta-rules-dat | 分流规则集来源 |

## 节点

- `<node-1>`：Hysteria2 + obfs salamander + 内联自签证书
- `<node-2>`：Hysteria2 + obfs salamander + 内联自签证书，`proxy` 选择器默认
- `<node-3>`：VLESS + XTLS Vision（uTLS chrome）
- `<gh-1>` / `<gh-2>`：回家用 Hysteria2，`domain_resolver` 为 `local-dns` + `ipv6_only`
- `speed-proxy` / `speed-direct` / `speed-gh`：仅测速查看延迟，不参与路由决策

## 回家节点（gh）注意事项

- 回家域名**只有 AAAA 记录**，必须显式设置 `domain_resolver` 且策略含 IPv6（模板为 `local-dns` + `ipv6_only`）；否则会继承 `route.default_domain_resolver` 的 `ipv4_only`，解析不到地址导致连不上。
- 手机当前网络必须支持 IPv6，否则回家节点不可用。
- `gh` 选择器默认 `<gh-1>`，可在客户端手动切换。
- 服务端 TLS 证书若更换，需同步更新内联 `certificate`，否则校验失败。
