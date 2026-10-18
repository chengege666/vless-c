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

## 功能特性

- 使用官方脚本安装最新 Xray-core
- 自动生成 UUID、Reality 密钥对、ShortID、高位随机端口
- 伪装域名 SNI 默认 `itunes.apple.com`，支持自定义
- 自动写入 systemd 服务，设置开机自启
- 自动放行 UFW / iptables 端口
- 检测并可选开启 BBR 加速
- 输出完整节点参数、`vless://` 分享链接与终端二维码
- 配置写入前执行 `xray run -test` 校验，校验失败不启动服务
- 所有覆盖写入前自动备份为 `*.bak.时间戳`

## 文件说明

| 文件 | 说明 |
|---|---|
| [vless-c.sh](vless-c.sh) | **总菜单入口**，统一管理两种模式 |
| [cgg-vless-reality.sh](cgg-vless-reality.sh) | 纯 VLESS + Reality 一键安装 |
| [cgg-vless-ws-tls.sh](cgg-vless-ws-tls.sh) | VLESS + WS + TLS 一键安装（acme.sh 申请证书，可套 Cloudflare CDN） |
| [cgg-vless-menu.sh](cgg-vless-menu.sh) | 早期独立的 Reality 管理菜单 |

> `vless-c.sh` 与 `cgg-vless-menu.sh` 功能有重叠，推荐使用 `vless-c.sh`。

## 快速开始

### 方式一：一键远程运行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chengege666/vless-c/main/vless-c.sh)
```

GitHub Raw 访问受限时使用 jsDelivr：

```bash
CGG_RAW_BASE=https://cdn.jsdelivr.net/gh/chengege666/vless-c@main \
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/chengege666/vless-c@main/vless-c.sh)
```

### 方式二：上传后本地运行

```bash
chmod +x *.sh
sudo bash vless-c.sh
```

### 单独运行某个脚本

```bash
# Reality
bash <(curl -fsSL https://raw.githubusercontent.com/chengege666/vless-c/main/cgg-vless-reality.sh)

# WS + TLS（需要域名已解析到本机，80 端口公网可达）
bash <(curl -fsSL https://raw.githubusercontent.com/chengege666/vless-c/main/cgg-vless-ws-tls.sh)
```

## 总菜单

```
==================== cgg-vless 总菜单 ====================
  当前模式：VLESS + Reality / VLESS + WS + TLS / 未安装
  1) 安装 VLESS-Reality 节点
  2) 安装 VLESS + WS + TLS 节点（CDN）
  3) 查看当前节点配置与连接链接
  4) 启动 Xray 服务
  5) 停止 Xray 服务
  6) 重启 Xray 服务
  7) 修改配置（节点名称 / SNI / UUID）
  8) SSL 证书管理（acme.sh 申请 / 续期 / 安装）
  9) 一键彻底卸载
  0) 退出
==========================================================
```

- 菜单会自动识别当前模式并显示在顶部
- Reality 与 WS+TLS 共用同一份配置与服务，**同一时间只能存在一种模式**
- 切换模式时会提示将覆盖现有配置，需确认
- 第 7 项中「节点名称」两种模式都可用，SNI / UUID 仅 Reality 可用

## SSL 证书管理

总菜单第 8 项提供独立的 acme.sh 证书管理，适合 80 端口不可用（NAT、只映射高位端口、云防火墙限制）的场景：

```
-------- SSL 证书管理 (acme.sh) --------
  1) 安装 / 检查 acme.sh
  2) 申请证书（HTTP-01，需 80 端口）
  3) 申请证书（DNS-01，Cloudflare / 阿里云）
  4) 查看已申请证书
  5) 手动续期
  6) 安装 / 更新证书到 Xray 目录
  7) 删除证书
  0) 返回主菜单
```

DNS-01 说明：

- 不需要开放 80 端口，支持 `*.example.com` 泛域名
- Cloudflare：需创建 API Token，权限为 **Zone → DNS → Edit**，并限制到对应域名
- 阿里云：需 AccessKey ID / Secret，账号需具备 DNS 解析权限
- 凭据由 acme.sh 自动保存到 `/root/.acme.sh/account.conf`，续期时复用
- 申请完成后选第 6 项安装到 `/usr/local/etc/xray/cert/`，再安装 WS+TLS 节点时选择「使用已安装证书」

WS+TLS 安装时新增证书来源选择：

```
选择证书来源：
  1) 自动申请 Let's Encrypt（HTTP-01，需 80 端口）
  2) 使用本机已有证书文件（手动输入路径）
  3) 使用已安装到 /usr/local/etc/xray/cert 的证书
```

选项 2 会校验证书与私钥是否匹配（OpenSSL 比对公钥指纹），并自动修正属组与权限。

## 两种模式对比

| 项目 | VLESS + Reality | VLESS + WS + TLS |
|---|---|---|
| 是否需要域名 | 不需要 | 需要，并解析到本机 |
| 证书 | 不需要 | Let's Encrypt（acme.sh） |
| 默认端口 | 随机 10000-65000 | 443 |
| 传输 | tcp + reality | ws + tls |
| 流控 | xtls-rprx-vision | 无 |
| 抗封锁 | 较强，直连 | 依赖 CDN，适合 IP 已被墙 |

## 安装前置条件

- root 权限（`sudo`）
- 系统为 Ubuntu 20.04+ 或 Debian 11+
- 可访问 GitHub（安装 Xray-core 与下载子脚本）
- 自动安装的依赖：`curl`、`openssl`、`jq`、`iproute2`、`socat`、`cron`、`qrencode`
  - `qrencode` 安装失败不阻断流程，仅跳过二维码
- WS+TLS 模式额外要求：
  - 域名 A 记录已指向本机公网 IP
  - 80 端口可从公网访问（acme.sh Standalone 验证）
  - 80 端口被 nginx/apache2/httpd/caddy 占用时，脚本会询问是否临时停止

## 安装过程说明

Reality 流程：

1. 检查 root、系统版本、运行用户
2. 询问端口（回车使用随机端口）与 SNI
3. 安装依赖、检测网络、安装 Xray-core
4. 生成 UUID、X25519 密钥对、ShortID
5. 写入配置并校验
6. 写入 systemd 服务，启动并设置开机自启
7. 放行防火墙端口
8. 询问是否开启 BBR
9. 输出节点参数、分享链接、二维码

WS+TLS 流程：

1. 安装依赖（含 socat、cron）
2. 询问域名与通知邮箱
3. 检查 80 端口占用，必要时临时停止 Web 服务
4. 安装 Xray-core 与 acme.sh，申请并安装证书
5. 生成 UUID 与随机 WS 路径
6. 写入配置、启动服务、放行端口
7. 输出节点参数、分享链接、二维码

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

服务管理：

```bash
systemctl status xray
systemctl restart xray
systemctl stop xray
journalctl -u xray -n 50 --no-pager
```

配置文件校验：

```bash
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

## Cloudflare CDN 配置建议

WS+TLS 模式套 CDN 时：

1. DNS 记录开启代理（橙色云）
2. SSL/TLS 模式选择 **Full (strict)**
3. 客户端地址可改为优选 IP / 优选域名
4. 端口可用 443，或 Cloudflare 支持的 2053 / 2083 / 2087 / 2096

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

## 回滚方式

脚本在覆盖前会生成备份：

```bash
# 查看备份
ls -l /usr/local/etc/xray/config.json.bak.*
ls -l /etc/systemd/system/xray.service.bak.*

# 回滚配置
cp -a /usr/local/etc/xray/config.json.bak.<时间戳> /usr/local/etc/xray/config.json
systemctl restart xray
```

## 常见问题

**提示 `$'\r': command not found`**

脚本带了 Windows 换行符，执行：

```bash
sed -i 's/\r$//' vless-c.sh
```

**提示无法访问 GitHub**

检查 DNS 与网络；`vless-c.sh` 可用 `CGG_RAW_BASE` 指向 jsDelivr 等镜像。

**Xray 启动失败**

```bash
journalctl -u xray -n 50 --no-pager
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

**WS+TLS 证书申请失败**

先看 acme.sh 的具体报错分类：

| 报错关键字 | 含义 | 处理 |
|---|---|---|
| `NXDOMAIN` | 域名未解析或记录未生效 | 检查 A 记录，等待传播 |
| `Connection refused` / `Timeout` | 80 端口公网不可达 | 检查安全组、NAT 端口映射、防火墙 |
| `Invalid response` | 80 端口被其他服务占用 | 停用占用服务后重试 |

自查命令：

```bash
dig +short 你的域名
ss -lntp 'sport = :80'
```

80 端口无法开放时，改用 DNS-01 验证（总菜单 `8` → `3`），无需 80 端口。

**Reality 客户端连不上**

- 客户端 `pbk` 必须是公钥，不是私钥
- `sni` 必须与服务端 `serverNames` 一致
- `sid` 必须与服务端 `shortIds` 一致
- `flow` 使用 `xtls-rprx-vision`
- 确认端口已在云厂商安全组放行

**二维码没有输出**

```bash
apt-get install -y qrencode
```

## 依赖版本说明

脚本兼容 `xray x25519` 的新旧两种输出格式：

- 旧版：`Private key` / `Public key`
- 新版（v25.3.6+）：`PrivateKey` / `Password`（即公钥）/ `Hash32`

## 安全提示

- 私钥仅保存在服务端，请勿泄露
- `cgg-vless.info` 权限为 `600`，仅 root 可读
- 本脚本以 root 运行并修改系统服务，请只在自有服务器上使用
- 建议配置 SSH 密钥登录并限制 root 密码登录

## 免责声明

本项目仅供学习与个人服务器运维参考。请遵守所在国家或地区的法律法规，使用者自行承担因使用本脚本产生的一切后果。
