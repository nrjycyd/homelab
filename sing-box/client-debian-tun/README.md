# sing-box client-debian — TUN 透明代理配置（模板）

## 概述

- **名称**: `client-debian`（与手机端 `client-mobile` 配对，同是 sing-box 客户端，按部署环境区分）
- **版本**: sing-box **1.14.0**（官方版）
- **部署位置**: Debian 13（家庭网关 VM）
- **模式**: **tun** 透明代理（Linux 推荐方案，`auto_redirect` 优于 tproxy）

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
sing-box tun-in（auto_route + auto_redirect，nftables 由 sing-box 管理）
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
| `03_inbounds.json` | **tun-in（新增，替代 redirect/tproxy）+ mixed:8888 / socks:7891 / fake-in:6666** |
| `04_outbound.json` | selector + Hysteria2×2 + VLESS(XTLS) + GH + direct + block |
| `05_route.json` | rule-sets + 路由规则 + `final`；**无 `default_mark`（与 auto_redirect 冲突）** |
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

> 9887 / 9888（redirect / tproxy）已删除，交由 tun-in 接管。

## tun-in 字段说明

| 字段 | 值 | 说明 |
|:-----|:---|:-----|
| `interface_name` | `sing-box-tun` | 虚拟设备名 |
| `address` | `172.19.0.1/30` + v6 | 避免与网关网段冲突 |
| `mtu` | `1500` | 网关环境标准 MTU |
| `dns_mode` | `disabled` | DNS 已由 SmartDNS→fake-in 链路处理，tun 不再劫持 DNS |
| `auto_route` | `true` | 自动接管路由 |
| `auto_redirect` | `true` | nftables 接管（Linux 推荐，性能优于 tproxy） |
| `strict_route` | `true` | 严格路由 |
| `stack` | `mixed` | system TCP + gvisor UDP（默认）；游戏/UDP 场景保留 gvisor UDP 处理 |

## DNS 分流设计

- **fakeip-dns** 配置 `inet4_range: 28.0.0.0/8` + `inet6_range: f2b0::/18`
  - A 查询 → fake v4 `28.x`；AAAA 查询 → fake v6 `f2b0::`
- 国外域名（geolocation-!cn）→ fakeip → 主路由按 fake 段路由回 sing-box
- 国内域名 → local-dns 拿真实国内 IP → 直连
- 兜底 `evaluate` realip：先 remote-dns 解析，响应国内 IP 改走 local-dns，其余走代理
- 自定义规则：cusdom-proxy / cusdom-direct / cusdom-reject

## 部署

> ⚠️ **前置**：网关 VM 需开启 IPv4 + IPv6 转发，否则主路由转发进来的流量无法进入 tun：
> ```bash
> cat > /etc/sysctl.d/99-singbox-tun.conf << 'EOF'
> net.ipv4.ip_forward=1
> net.ipv6.conf.all.forwarding=1
> net.ipv6.conf.ens192.accept_ra=2
> EOF
> sysctl --system
> ```
> ⚠️ `accept_ra=2` 必须在开启转发后显式设置（否则 v6 默认路由会丢失）
> 若此前使用 tproxy/redirect，需停用旧机制（auto_redirect 自管 nftables）：
> ```bash
> systemctl stop nftables && systemctl disable nftables
> systemctl stop singbox_tproxy && systemctl disable singbox_tproxy
> ```

```bash
# 1. 拷贝配置
scp *.json root@<gateway-ip>:/usr/local/etc/sing-box/conf/

# 2. 校验
cd /usr/local/etc/sing-box && sing-box check -C conf

# 3. 重启
systemctl restart sing-box && systemctl is-active sing-box
```

## 填写占位符（04_outbound.json / 05_route.json）

| 占位符 | 含义 |
|:-----|:-----|
| `<node-1>` / `<node-2>` / `<node-3>` | 代理节点 tag（Hysteria2×2 + VLESS） |
| `<node-x-ip>` / `<gh-server-domain>` | 服务器地址 |
| `<sni-x>` | TLS SNI |
| `<uuid>` / `<password-x>` / `<obfs-password-x>` | 凭据 |
| `<cert-path-x>` | 自签证书路径 |
| `<reject-domain>` / `<proxy-domain-x>` / `<direct-domain>` | cusdom 自定义域名 |
| `<home-cidr-with-prefix>` | GH 特判网段（如 `10.0.1.0/24`） |