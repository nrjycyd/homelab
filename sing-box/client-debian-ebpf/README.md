# sing-box client-debian — eBPF 透明代理配置（模板）

## 概述

- **名称**: `client-debian`（与手机端 `client-mobile` 配对，同是 sing-box 客户端，按部署环境区分）
- **版本**: sing-box **1.14.0-reF1nd.1**（reF1nd R 核，`with_ebpf`）
- **部署位置**: Debian 13（家庭网关 VM）
- **模式**: **ebpf shared** 透明代理（TC 挂下游接口拦截转发流量）
- **项目**: [reF1nd/sing-box](https://github.com/reF1nd/sing-box) · [reF1nd/sing-box-releases](https://github.com/reF1nd/sing-box-releases) · [官方文档](https://sing-box.sagernet.org/)

## 架构

```
SmartDNS
   │  国外域名 DNS 查询
   ▼
sing-box fake-in :6666 ──► hijack-dns ──► DNS 模块（fakeip 分流）
   │
主路由规则（28.0.0.0/8 fakeip 段 + 精选 IP）
   │
   ▼
sing-box ebpf-in（TC ingress 挂下游接口，内核直接接管）
   │
   ▼
sing-box ──► 节点（Hysteria2 / VLESS）──► 国外出口
```

## 文件清单（conf 目录，前缀升序合并）

| 文件 | 说明 |
|:-----|:-----|
| `00_log.json` | 日志（level `error`，生产级别） |
| `01_experimental.json` | cache_file（持久化 fakeip 映射） |
| `02_dns.json` | DNS 服务器 + 分流规则（核心） |
| `03_inbounds.json` | **ebpf-in（shared）+ mixed:8888 / socks:7891 / fake-in:6666** |
| `04_outbound.json` | selector + Hysteria2×2 + VLESS(XTLS) + GH + direct + block |
| `05_route.json` | rule-sets + 路由规则 + `final` |
| `06_http_clients.json` | 共享下载通道 rule-set-download（走代理） |
| `07_services.json` | sing-box API :9091 + 官方 Dashboard |
| `sing-box.service` | systemd 单元 |

## 端口

| 端口 | 用途 |
|:-----|:-----|
| 6666 | fake-in：SmartDNS 转发国外域名查询入口 |
| 8888 | HTTP/SOCKS5 混合代理（手动指定代理） |
| 7891 | 纯 SOCKS5 |
| 9091 | sing-box API + Dashboard |

> ebpf 入站无固定监听端口，内部监听端口和重定向地址前缀由 sing-box 自动分配。

## ebpf-in 字段说明（v1.14.0-reF1nd.1 schema）

| 字段 | 值 | 说明 |
|:-----|:---|:-----|
| `mode` | `shared` | TC 拦截下游接口转发流量 |
| `network` | `["tcp", "udp"]` | 双协议 |
| `udp_timeout` | `5m` | UDP 会话超时 |
| `bypass_rule_set` | `[]` | 无 CIDR 绕过（主路由已分流） |
| `shared.dns_mode` | `off` | DNS 走 SmartDNS→fake-in，ebpf 不拦 53 |
| `shared.interface` | `<lan-interface>` | 必填，流量入口接口 |
| `shared.ipv6` | `true` | 拦截 IPv6（旧版 `ipv6_mode` 改为 bool） |
| `shared.bypass_private_address` | `true` | 绕过私网目标 |
| `shared.include_source_cidr` | LAN 网段 | 只处理 LAN 来源 |
| `shared.advanced.tc_priority` | `1` | TC filter 优先级 |

> **schema 变更提醒**（相对 beta.17）：`dns_mode` 移入 `shared`；`ipv6_mode` → `ipv6`(bool)；`state_capacity` 已移除；`dns_mode` 值 `respect_bypass` → `respect_policy`。

## DNS 分流设计

- **fakeip-dns** 配置 `inet4_range: 28.0.0.0/8` + `inet6_range: f2b0::/18`（A→fake v4，AAAA→fake v6）
- 国外域名（geolocation-!cn）→ fakeip → 主路由按 fake 段路由回 sing-box
- 国内域名 → local-dns 拿真实国内 IP → 直连
- 兜底 `evaluate` realip：先 remote-dns 解析，响应国内 IP 改走 local-dns，其余走代理
- 自定义规则：cusdom-proxy / cusdom-direct / cusdom-reject

## 部署

> ⚠️ **前置**：R 核需 `with_ebpf` 构建；ebpf shared 需 root + 内核支持（先用 `tools ebpf status` 探测）。**不需要 ip_forward**（TC ingress 重定向到本机内部端口，不走内核转发路径）。

```bash
# 0. 备份
cp -r /usr/local/etc/sing-box /usr/local/etc/sing-box.bak.$(date +%Y%m%d)
cp /usr/local/bin/sing-box /usr/local/bin/sing-box.bak.$(date +%Y%m%d)

# 1. 内核能力探测（必须 supported）
sing-box tools ebpf status --mode all --interface <lan-interface> --json

# 2. 拷贝配置
scp *.json root@<gateway-ip>:/usr/local/etc/sing-box/conf/

# 3. 校验
cd /usr/local/etc/sing-box && sing-box check -C conf

# 4. 清理旧拦截机制（若从 tun 切来：删 tun 设备 + auto_redirect 的 nftables 表）
nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box
ip link del sing-box-tun 2>/dev/null

# 5. 重启
systemctl restart sing-box && systemctl is-active sing-box
```

## systemd 权限

ebpf 加载需要 `CAP_BPF` + `CAP_SYS_ADMIN`（与 tun/tproxy 的最大差异）：

```ini
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_BPF CAP_SYS_ADMIN
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_BPF CAP_SYS_ADMIN
```

## 填写占位符（03_inbounds / 04_outbound / 05_route）

| 占位符 | 含义 |
|:-----|:-----|
| `<lan-interface>` | ebpf shared 流量入口接口（如 `ens192` / `br-lan`） |
| `<node-1>` / `<node-2>` / `<node-3>` | 代理节点 tag（Hysteria2×2 + VLESS） |
| `<node-x-ip>` / `<gh-server-domain>` | 服务器地址 |
| `<sni-x>` | TLS SNI |
| `<uuid>` / `<password-x>` / `<obfs-password-x>` | 凭据 |
| `<cert-path-x>` | 自签证书路径 |
| `<reject-domain>` / `<proxy-domain-x>` / `<direct-domain>` | cusdom 自定义域名 |
| `<home-cidr-with-prefix>` | GH 特判网段（如 `10.0.1.0/24`） |