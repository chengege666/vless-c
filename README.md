# cgg-vless

一键搭建 **VLESS + XTLS-Reality** / **VLESS + WebSocket + TLS** 节点的 Shell 脚本集合，适用于 Ubuntu 20.04+ 与 Debian 11+。

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


## 输出文件与路径

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/xray` | Xray 核心 |
| `/usr/local/etc/xray/config.json` | 节点配置 |
| `/usr/local/etc/xray/cgg-vless.info` | Reality 节点元信息（公钥等，权限 600） |
| `/usr/local/etc/xray/cert/` | WS+TLS 证书目录 |
| `/var/log/xray/` | 访问日志与错误日志 |
| `/etc/systemd/system/xray.service` | systemd 服务 |
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
   - DNS-01 验证（总菜单 `8` → `3`，支持 Cloudflare / 阿里云）
   - 使用本机已有证书文件（证书来源选 `2`，直接填 `.cer` / `.key` 路径）
   - 使用已安装到 `/usr/local/etc/xray/cert` 的证书（证书来源选 `3`）

分享链接默认填监听端口，套 CDN 时客户端地址改为优选 IP/域名，端口按上述方式调整。

连端口映射都没有时，直接用下方 Cloudflare Tunnel 方案。

### Cloudflare Tunnel 方案（无端口映射，网页配置）

NAT 机连端口映射都没有（或无公网 IPv4）时，可用 Cloudflare Tunnel 代替端口回源。
cloudflared 在服务器上主动与 Cloudflare 建立出站连接，无需放行任何入站端口。
全程在 Cloudflare 网页后台配置，服务器只需执行一次网页生成的安装命令。

前置条件：域名 NS 已托管在 Cloudflare。

配合脚本的步骤：

1. 正常安装 WS+TLS 节点，监听端口选 `2) 自定义端口`（仅本机回源用，填任意空闲端口），证书用 DNS-01（总菜单 `8` → `3`）
2. 登录 Cloudflare 控制台 → 左侧 **Zero Trust** → **Networks** → **Tunnels** → **Create a tunnel**，类型选 **Cloudflared**，填隧道名（如 `cgg-vless`）
3. 网页会给出一条安装命令（含 token），复制到服务器执行一次；页面出现 **Connected** 即连接成功
4. 在同一页面继续 **Public Hostname** → **Add a public hostname**：
   - Subdomain / Domain：填你的域名（如 `ws.example.com`）
   - Type：**HTTPS**
   - URL：`localhost:监听端口`
   - 展开 **Additional application settings** → **TLS** → 勾选 **No TLS Verify**
5. 保存即可，DNS 记录由 Cloudflare 自动创建并强制代理
6. 客户端参数：地址填优选 IP/域名，端口 `443`，SNI/host 填隧道域名，WS 路径不变

提示：

- 安装命令由网页生成且含密钥，仅执行一次；服务已注册 systemd 并开机自启
- 隧道主机名无需手动开橙色云，也不能关（cfargotunnel 记录强制代理）
- 防火墙无需放行监听端口，仅出站连接
- 想省掉证书：手动把 config.json 的 `tlsSettings` 移除（security 改 `none`），网页里 Type 改 **HTTP**、URL `localhost:端口`

## 修改与卸载

修改配置：

- 两种模式均可在总菜单第 `7` 项修改节点名称（仅影响分享链接备注）
- Reality：同一菜单可更换 SNI 或重置 UUID
- WS+TLS：域名变更需修改 `/usr/local/etc/xray/config.json` 后重启服务

彻底卸载：

- 总菜单第 `9` 项，输入 `yes` 确认
- 会删除 Xray 核心、配置、日志、systemd 服务与 `/opt/cgg-vless` 缓存
- **不会**删除 acme.sh 与已申请证书（`/root/.acme.sh`），如需清理用总菜单第 8 项
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
