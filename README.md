# cgg-vless

一键搭建 **VLESS + XTLS-Reality** / **VLESS + WebSocket + TLS** / **VLESS + WS + Cloudflare Tunnel** 节点的 Shell 脚本集合，适用于 Ubuntu 20.04+ 与 Debian 11+。

核心统一使用官方 Xray-core，仅配置 VLESS 协议，不包含 VMess / Trojan 等多余协议。

```
  ██████╗ ██████╗  ██████╗     ██╗   ██╗██╗     ███████╗███████╗███████╗
 ██╔════╝██╔════╝ ██╔════╝     ██║   ██║██║     ██╔════╝██╔════╝██╔════╝
 ██║     ██║  ███╗██║  ███╗    ██║   ██║██║     █████╗  ███████╗███████╗
 ██║     ██║   ██║██║   ██║    ╚██╗ ██╔╝██║     ██╔══╝  ╚════██║╚════██║
 ╚██████╗╚██████╔╝╚██████╔╝     ╚████╔╝ ███████╗███████╗███████║███████║
  ╚═════╝ ╚═════╝  ╚═════╝       ╚═══╝  ╚══════╝╚══════╝╚══════╝╚══════╝
                     cgg-vless · VLESS Reality
```





## 快速开始

### 方式一：一键远程运行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chengege666/vless-c/main/vless-c.sh)
```

## 两种模式对比

| 项目 | VLESS + Reality | VLESS + WS + TLS |
|---|---|---|
| 是否需要域名 | 不需要 | 需要，并解析到本机 |
| 证书 | 不需要 | Let's Encrypt（acme.sh） |
| 默认端口 | 随机 10000-65000 | 443 |
| 传输 | tcp + reality | ws + tls |
| 流控 | xtls-rprx-vision | 无 |
| 抗封锁 | 较强，直连 | 依赖 CDN，适合 IP 已被墙 |


## VLESS + WS + CF Tunnel 模式（总菜单第 3 项）

Xray 仅监听 `127.0.0.1` 的 WS 明文（`security: none`），TLS 由 Cloudflare 边缘处理：无需域名证书，无需放行任何入站端口。

| 项目 | 固定隧道 | 临时隧道 |
|---|---|---|
| 前提 | 域名 NS 托管在 Cloudflare | 无 |
| 域名 | 固定（自己的域名） | 随机 `xxx.trycloudflare.com`，每次重启都会变化 |
| 配置方式 | 网页创建隧道取 Token → 脚本注册服务 → 网页添加 Public Hostname | 脚本全自动 |
| 用途 | 长期使用 | 临时测试 |

固定隧道网页端配置：**Zero Trust → Networks → Tunnels → Public Hostname**，Type 选 **HTTP**，URL 填 `http://localhost:本地端口`（默认 8001，必须带 `http://` 协议头），保存后 DNS 记录自动创建。

临时隧道域名重启后会变化，用总菜单第 `4` 项重新查看即可获取最新域名；仅建议测试使用。


## 输出文件与路径

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/xray` | Xray 核心 |
| `/usr/local/etc/xray/config.json` | 节点配置 |
| `/usr/local/etc/xray/cgg-vless.info` | 节点元信息（各模式共用，权限 600） |
| `/usr/local/etc/xray/cert/` | WS+TLS 证书目录 |
| `/var/log/xray/` | 访问日志与错误日志 |
| `/etc/systemd/system/xray.service` | systemd 服务 |
| `/usr/local/bin/cloudflared` | Cloudflare Tunnel 客户端（隧道模式） |
| `/etc/systemd/system/cgg-quick-tunnel.service` | 临时隧道服务（隧道模式） |
| `/etc/modules-load.d/cgg-vless-bbr.conf` | BBR 内核模块开机加载（总菜单第 12 项） |
| `/etc/sysctl.d/99-cgg-vless-bbr.conf` | BBR 拥塞控制参数（总菜单第 12 项） |
| `/etc/sysctl.d/99-cgg-vless-tcp.conf` | TCP 窗口调优参数（总菜单第 11 项） |
| `/opt/cgg-vless/` | 总菜单下载的子脚本缓存 |
| `/root/.acme.sh/` | acme.sh 及自动续期任务 |


## Cloudflare CDN 配置建议

WS+TLS 模式套 CDN 时：

1. DNS 记录开启代理（橙色云）
2. SSL/TLS 模式选择 **Full (strict)**
3. 客户端地址可改为优选 IP / 优选域名
4. 端口可用 443，或 Cloudflare 支持的 2053 / 2083 / 2087 / 2096

## NAT VPS 套 CDN 说明

NAT 机共享 IP，服务商分配受限端口范围，默认无 443/80，套 Cloudflare CDN 按以下方式处理：

1. 安装 WS+TLS 节点时，在「选择监听端口模式」选 `2) 自定义端口`，填入分配范围内的端口
2. 确认已在服务商处完成端口映射（外部端口 → 内部端口）
3. 回源方式二选一：
   - 监听端口在 Cloudflare 支持列表内（443 / 2053 / 2083 / 2087 / 2096 / 8443）→ 客户端直接用该端口连接，无需额外配置
   - 监听端口不在列表内 → 在 Cloudflare 的 **Origin Rules** 新建规则，将回源端口（Destination Port）改为监听端口，客户端端口填 443
4. 证书申请：NAT 机通常没有 80 端口，HTTP-01 会失败，改用以下方式之一：
   - DNS-01 验证（总菜单 `9` → `3`，支持 Cloudflare / 阿里云）
   - 使用本机已有证书文件（证书来源选 `2`，直接填 `.cer` / `.key` 路径）
   - 使用已安装到 `/usr/local/etc/xray/cert` 的证书（证书来源选 `3`）

分享链接默认填监听端口，套 CDN 时客户端地址改为优选 IP/域名，端口按上述方式调整。

连端口映射都没有时，直接用总菜单第 `3` 项的 CF Tunnel 模式（见上文），无需端口映射、无需证书。

## 修改与卸载

修改配置：

- 所有模式均可在总菜单第 `8` 项修改节点名称（仅影响分享链接备注）
- Reality：同一菜单可更换 SNI 或重置 UUID
- WS+TLS：域名变更需修改 `/usr/local/etc/xray/config.json` 后重启服务

彻底卸载：

- 总菜单第 `10` 项，输入 `yes` 确认
- 会删除 Xray 核心、配置、日志、systemd 服务、Cloudflare Tunnel 服务与 `/opt/cgg-vless` 缓存（cloudflared 主程序删除时单独确认）
- **不会**删除 acme.sh 与已申请证书（`/root/.acme.sh`），如需清理用总菜单第 9 项
- **不会**删除 UFW / iptables 放行规则，如需清理请手动执行：

```bash
ufw delete allow <端口>/tcp
iptables -D INPUT -p tcp --dport <端口> -j ACCEPT
```


**WS+TLS 证书申请失败**

先看 acme.sh 的具体报错分类：

| 报错关键字 | 含义 | 处理 |
|---|---|---|
| `NXDOMAIN` | 域名未解析或记录未生效 | 检查 A 记录，等待传播 |
| `Connection refused` / `Timeout` | 80 端口公网不可达 | 检查安全组、NAT 端口映射、防火墙 |
| `Invalid response` | 80 端口被其他服务占用 | 停用占用服务后重试 |


## 安全提示

- 私钥仅保存在服务端，请勿泄露
- `cgg-vless.info` 权限为 `600`，仅 root 可读
- 本脚本以 root 运行并修改系统服务，请只在自有服务器上使用
- 建议配置 SSH 密钥登录并限制 root 密码登录

## 免责声明

本项目仅供学习与个人服务器运维参考。请遵守所在国家或地区的法律法规，使用者自行承担因使用本脚本产生的一切后果。
