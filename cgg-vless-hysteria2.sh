#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · Hysteria 2 节点（sing-box 后端）
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-hysteria2.sh
# 说    明：Xray-core 不支持 Hysteria 2，本脚本复用 sing-box 后端；
#           配置、服务、元信息均与 Xray / AnyTLS 分离，可与现有节点并存
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly SINGBOX_DIR="/usr/local/etc/sing-box"
readonly CONFIG_FILE="${SINGBOX_DIR}/hysteria2.json"
readonly INFO_FILE="${SINGBOX_DIR}/cgg-hysteria2.info"
readonly CERT_DIR="${SINGBOX_DIR}/cert-hysteria2"
readonly ANYTLS_CONFIG="${SINGBOX_DIR}/config.json"
readonly SERVICE_NAME="cgg-hysteria2"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly XRAY_CERT_DIR="/usr/local/etc/xray/cert"
readonly RUN_USER="nobody"
readonly RUN_GROUP="nogroup"
readonly DEFAULT_NODE_NAME="cgg-hysteria2"

# ------------------------------ 运行期变量 ------------------------------------
PORT=""
DOMAIN=""
PASSWORD=""
NODE_NAME=""
CERT_FILE=""
KEY_FILE=""
SERVER_IP=""
HOP_PORTS=""

# ------------------------------ 颜色定义 --------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'
    C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[1;36m'
    C_MAGENTA=$'\033[1;35m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_MAGENTA=""
    C_RESET=""
fi

# ------------------------------ 日志函数 --------------------------------------
log()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "操作失败（行号：$LINENO，退出码：$?）"' ERR

# ------------------------------ 环境检查 --------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 权限运行：sudo bash $0"
    fi
}

check_os() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，无法识别系统版本"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian)
            log "当前系统：${PRETTY_NAME:-${ID}}"
            ;;
        *)
            die "仅支持 Ubuntu / Debian，当前系统：${PRETTY_NAME:-unknown}"
            ;;
    esac
}

check_network() {
    if ! curl -fsS --max-time 10 -o /dev/null https://github.com; then
        warn "GitHub 访问异常，sing-box 下载可能失败"
    fi
}

# 交互环境检查：本脚本必须交互输入域名与证书路径
require_tty() {
    if [[ ! -t 0 ]]; then
        die "本脚本需要交互输入，请在终端中直接运行"
    fi
}

# ------------------------------ 公网 IP ---------------------------------------
get_public_ip() {
    local ip=""
    ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS4 --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    printf '%s' "$ip"
}

# ------------------------------ 架构识别 --------------------------------------
detect_arch() {
    local machine
    machine="$(uname -m 2>/dev/null || true)"
    case "$machine" in
        x86_64|amd64)   printf 'amd64' ;;
        aarch64|arm64)  printf 'arm64' ;;
        *)              return 1 ;;
    esac
}

# ------------------------------ 端口检查 --------------------------------------
# Hysteria 2 基于 QUIC/UDP，端口冲突检测必须针对 UDP
port_in_use_udp() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
}

# ------------------------------ 安装 sing-box ---------------------------------
install_singbox() {
    if [[ -x "$SINGBOX_BIN" ]]; then
        log "检测到已安装 sing-box：$("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装：apt-get install -y curl"
    command -v tar >/dev/null 2>&1 || die "缺少 tar，请先安装：apt-get install -y tar"

    local arch tag ver url tmpdir extracted
    if ! arch="$(detect_arch)"; then
        die "当前架构不支持自动安装（仅支持 x86_64 / aarch64），请手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    log "获取 sing-box 最新版本..."
    tag="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    if [[ -z "$tag" ]]; then
        die "获取 sing-box 版本失败（GitHub API 不可达），可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    ver="${tag#v}"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmpdir="$(mktemp -d)"

    log "下载 sing-box：${url}"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${tmpdir}/pkg.tar.gz" "$url"; then
        rm -rf "$tmpdir"
        die "sing-box 下载失败，可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    if ! tar -xzf "${tmpdir}/pkg.tar.gz" -C "$tmpdir"; then
        rm -rf "$tmpdir"
        die "sing-box 压缩包解压失败"
    fi

    extracted="$(find "$tmpdir" -type f -name sing-box 2>/dev/null | head -n 1 || true)"
    if [[ -z "$extracted" ]]; then
        rm -rf "$tmpdir"
        die "压缩包中未找到 sing-box 二进制"
    fi

    if ! install -m 755 "$extracted" "$SINGBOX_BIN"; then
        rm -rf "$tmpdir"
        die "安装 sing-box 到 ${SINGBOX_BIN} 失败"
    fi
    rm -rf "$tmpdir"

    "$SINGBOX_BIN" version >/dev/null 2>&1 || die "sing-box 安装后无法运行"
    log "sing-box 安装完成：$("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
}

# ------------------------------ 参数输入 --------------------------------------
validate_domain() {
    local d="$1"
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_domain() {
    local input
    while true; do
        read -r -p "证书域名 / SNI（如 hy2.example.com）：" input
        input="${input//[[:space:]]/}"
        if [[ -z "$input" ]]; then
            warn "域名不能为空"
            continue
        fi
        if ! validate_domain "$input"; then
            warn "域名格式不合法：${input}"
            continue
        fi
        DOMAIN="$input"
        break
    done
    log "证书域名 / SNI：${DOMAIN}"
}

ask_port() {
    local input
    read -r -p "UDP 监听端口（1-65535，回车默认 443；可空格分隔多个端口实现端口跳跃，第一个为主监听端口，其余为跳跃端口）：" input

    # 按空白切分；纯空格输入等价于空输入（herestring 自带换行，read 必然返回 0）
    local -a ports=()
    read -r -a ports <<< "$input"

    if (( ${#ports[@]} == 0 )); then
        PORT="443"
        HOP_PORTS=""
    else
        if (( ${#ports[@]} > 20 )); then
            die "端口数量过多（${#ports[@]} 个，最多支持 20 个）"
        fi
        local p seen=""
        local -a norm=()
        for p in "${ports[@]}"; do
            if [[ ! "$p" =~ ^[0-9]+$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then
                die "端口不合法：${p}"
            fi
            # 去掉前导零（如 0443 -> 443），避免写入 JSON / iptables 时格式非法
            p=$((10#$p))
            case " $seen " in
                *" $p "*) die "端口重复：${p}" ;;
            esac
            seen="${seen} ${p}"
            if port_in_use_udp "$p"; then
                die "UDP 端口 ${p} 已被占用，请为 Hysteria 2 选择其他端口"
            fi
            norm+=("$p")
        done
        # 第一个端口为主监听端口（写入 listen_port），其余为跳跃端口
        PORT="${norm[0]}"
        HOP_PORTS="${norm[*]:1}"
    fi

    # AnyTLS 为 TCP，同号端口本质可共存，仅提示避免误判
    if [[ -f "$ANYTLS_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        local aport
        aport="$(jq -r '.inbounds[0].listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null || true)"
        if [[ -n "$aport" && "$aport" == "$PORT" ]]; then
            warn "端口 ${PORT} 与 AnyTLS 相同：TCP/UDP 可共存，若客户端异常请改用其他端口"
        fi
    fi

    if [[ -n "$HOP_PORTS" ]]; then
        log "UDP 监听端口：${PORT}（端口跳跃：${HOP_PORTS// /, }）"
    else
        log "UDP 监听端口：${PORT}"
    fi
}

ask_node_name() {
    local input
    NODE_NAME="$DEFAULT_NODE_NAME"
    read -r -p "节点名称（显示在客户端备注，回车默认 ${DEFAULT_NODE_NAME}）：" input
    # 去掉分隔符与空白，避免破坏 hysteria2:// 链接格式
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    if [[ -n "$input" ]]; then
        NODE_NAME="$input"
    fi
    log "节点名称：${NODE_NAME}"
}

# ------------------------------ 证书处理 --------------------------------------
fix_key_permission() {
    local key="$1"
    chown root:"$RUN_GROUP" "$key" 2>/dev/null || warn "无法修改私钥属组：${key}"
    chmod 640 "$key" 2>/dev/null || warn "无法修改私钥权限：${key}"
}

setup_cert_manual() {
    local cert key
    read -r -p "证书文件路径（.cer / fullchain.cer / .pem）：" cert
    cert="${cert/#\~/$HOME}"
    [[ -n "$cert" ]] || die "证书路径不能为空"
    [[ -s "$cert" ]] || die "证书文件不存在或为空：${cert}"

    read -r -p "私钥文件路径（.key）：" key
    key="${key/#\~/$HOME}"
    [[ -n "$key" ]] || die "私钥路径不能为空"
    [[ -s "$key" ]] || die "私钥文件不存在或为空：${key}"

    install -d -m 755 -o root -g root "$CERT_DIR"
    cp -f "$cert" "${CERT_DIR}/fullchain.pem" || die "复制证书失败"
    cp -f "$key" "${CERT_DIR}/privkey.pem" || die "复制私钥失败"
    chmod 644 "${CERT_DIR}/fullchain.pem"
    fix_key_permission "${CERT_DIR}/privkey.pem"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    log "证书已复制到：${CERT_DIR}"
}

ask_cert_source() {
    local ans
    if [[ -s "${XRAY_CERT_DIR}/fullchain.pem" && -s "${XRAY_CERT_DIR}/privkey.pem" ]]; then
        log "检测到 Xray 证书目录已有证书"
        read -r -p "直接复用 /usr/local/etc/xray/cert 下的证书？[Y/n]：" ans
        case "$ans" in
            [Nn]*)
                setup_cert_manual
                ;;
            *)
                CERT_FILE="${XRAY_CERT_DIR}/fullchain.pem"
                KEY_FILE="${XRAY_CERT_DIR}/privkey.pem"
                fix_key_permission "$KEY_FILE"
                log "使用已有证书：${CERT_FILE}"
                ;;
        esac
        return 0
    fi

    warn "未检测到 ${XRAY_CERT_DIR} 下的证书"
    printf '  1) 手动输入证书文件路径（.cer / .key）\n'
    printf '  2) 取消，先去总菜单第 11 项申请证书\n'
    read -r -p "请选择 [1-2]：" ans
    case "$ans" in
        1) setup_cert_manual ;;
        *) die "已取消：请先在总菜单第 11 项申请证书，或准备好证书文件后重跑" ;;
    esac
}

# ------------------------------ 密码生成 --------------------------------------
gen_password() {
    PASSWORD="$(openssl rand -hex 16 2>/dev/null || true)"
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' || true)"
    fi
    [[ ${#PASSWORD} -eq 32 ]] || die "Hysteria 2 密码生成失败"
    log "Hysteria 2 密码生成完成"
}

# ------------------------------ 配置写入 --------------------------------------
write_config() {
    install -d -m 755 -o root -g root "$SINGBOX_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        local backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$backup" || warn "旧配置备份失败：${backup}"
        log "旧配置已备份：${backup}"
    fi

    # ALPN 固定 h3，与官方 Hysteria 2 默认值一致；UDP 转发由 QUIC 原生承载
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "cgg",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # sing-box 以 nobody 运行，配置需属组可读（含密码，仍限制其他用户）
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || warn "无法修改配置属组：${CONFIG_FILE}"
    chmod 640 "$CONFIG_FILE"

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE"; then
        die "sing-box 配置校验失败，未启动服务（请确认 sing-box 版本支持 hysteria2）"
    fi
    log "配置写入并校验通过：${CONFIG_FILE}"
}

# ------------------------------ 端口跳跃 --------------------------------------
# sing-box 服务端不支持原生多端口监听，采用业界标准做法：
# 主端口正常监听，跳跃端口通过 iptables REDIRECT 转发到主端口，
# 客户端依据分享链接中的 mport 参数随机选口、自动切换
setup_port_hopping() {
    [[ -n "$HOP_PORTS" ]] || return 0

    if ! command -v iptables >/dev/null 2>&1; then
        warn "未检测到 iptables，端口跳跃规则无法配置，请手动将端口 ${HOP_PORTS// /, } 转发到 ${PORT}/udp"
        return 0
    fi

    local p
    for p in $HOP_PORTS; do
        if ! iptables -t nat -C PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$PORT" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$PORT" \
                || warn "端口跳跃规则添加失败：${p} -> ${PORT}"
        fi
    done
    log "端口跳跃规则已配置：${HOP_PORTS// /, } -> ${PORT}"

    # 持久化：优先 netfilter-persistent，其次 /etc/iptables/rules.v4；都不可用则警告
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            log "iptables 规则已持久化（netfilter-persistent）"
        else
            warn "netfilter-persistent 保存失败，重启后端口跳跃规则将丢失"
        fi
    elif [[ -f /etc/iptables/rules.v4 ]] && command -v iptables-save >/dev/null 2>&1; then
        if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            log "iptables 规则已持久化（/etc/iptables/rules.v4）"
        else
            warn "iptables-save 写入 /etc/iptables/rules.v4 失败，重启后端口跳跃规则将丢失"
        fi
    else
        warn "未安装 iptables-persistent，重启后端口跳跃规则将丢失；可执行 apt-get install -y iptables-persistent 后重跑"
    fi
}

# ------------------------------ systemd 服务 ----------------------------------
write_service() {
    if [[ -f "$SERVICE_FILE" ]] && ! grep -q "cgg-hysteria2" "$SERVICE_FILE"; then
        local backup="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$SERVICE_FILE" "$backup"
        log "旧服务文件已备份：${backup}"
    fi

    # Restart=on-failure 负责进程级异常重连；QUIC 连接复用与超时由 sing-box 内部处理
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless Hysteria 2 Service (sing-box)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "设置开机自启失败"

    log "启动 ${SERVICE_NAME} 服务..."
    if ! systemctl restart "$SERVICE_NAME"; then
        err "服务启动失败，最近日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || true
        return 1
    fi

    sleep 1
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务未处于运行状态，最近日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || true
        return 1
    fi
    log "${SERVICE_NAME} 已启动"
}

# ------------------------------ 运行状态校验 ----------------------------------
verify_runtime() {
    local listening=0
    if command -v ss >/dev/null 2>&1; then
        if ss -H -lun "sport = :${PORT}" 2>/dev/null | grep -q .; then
            listening=1
        fi
    fi

    if (( listening == 1 )); then
        log "UDP 端口 ${PORT} 已监听"
    else
        warn "未检测到 UDP 端口 ${PORT} 监听，请执行 journalctl -u ${SERVICE_NAME} -n 50 排查"
    fi

    # 跳跃端口不直接监听（经 REDIRECT 转发），仅校验 iptables 规则是否生效
    if [[ -n "$HOP_PORTS" ]] && command -v iptables >/dev/null 2>&1; then
        local p missing=0
        for p in $HOP_PORTS; do
            if ! iptables -t nat -C PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$PORT" 2>/dev/null; then
                warn "端口跳跃规则未生效：${p} -> ${PORT}"
                missing=1
            fi
        done
        if (( missing == 0 )); then
            log "端口跳跃规则已全部生效：${HOP_PORTS// /, }"
        fi
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "服务状态：运行中（异常退出将自动重连）"
    else
        warn "服务状态：未运行"
    fi
}

# ------------------------------ 防火墙 ----------------------------------------
configure_firewall() {
    local all_ports="$PORT${HOP_PORTS:+ ${HOP_PORTS}}"
    local p

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in $all_ports; do
            ufw allow "${p}/udp" >/dev/null 2>&1 || warn "UFW 放行 ${p}/udp 失败"
        done
        log "UFW 已放行端口 ${all_ports// /, }/udp"
    fi

    if command -v iptables >/dev/null 2>&1; then
        for p in $all_ports; do
            if ! iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p udp --dport "$p" -j ACCEPT \
                    || warn "iptables 放行端口失败，请手动放行 ${p}/udp"
            fi
        done
        log "iptables 已放行端口 ${all_ports// /, }/udp（如使用 firewalld 请另行放行）"
    elif ! command -v ufw >/dev/null 2>&1; then
        warn "未检测到 UFW / iptables，请手动放行 ${all_ports// /, }/udp"
    fi
}

# ------------------------------ 元信息 ----------------------------------------
save_info() {
    install -d -m 755 -o root -g root "$SINGBOX_DIR"
    {
        printf 'MODE=hysteria2\n'
        printf 'PORT=%s\n' "$PORT"
        printf 'DOMAIN=%s\n' "$DOMAIN"
        printf 'PASSWORD=%s\n' "$PASSWORD"
        printf 'NODE_NAME=%s\n' "$NODE_NAME"
        printf 'HOP_PORTS=%s\n' "$HOP_PORTS"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# ------------------------------ 输出结果 --------------------------------------
print_result() {
    local ip link extra=""
    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    # 端口跳跃按 Hysteria 2 URI 规范写入 mport，客户端据此随机选口、自动切换
    if [[ -n "$HOP_PORTS" ]]; then
        extra="&mport=${PORT},${HOP_PORTS// /,}"
    fi
    link="hysteria2://${PASSWORD}@${ip}:${PORT}/?sni=${DOMAIN}&alpn=h3${extra}#${NODE_NAME}"

    printf '\n%s=============== cgg-vless Hysteria 2 节点 ===============%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : Hysteria 2（sing-box，QUIC/UDP）\n'
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  地址 (IP)   : %s\n' "$ip"
    if [[ -n "$HOP_PORTS" ]]; then
        printf '  UDP 端口    : %s（跳跃端口：%s）\n' "$PORT" "${HOP_PORTS// /, }"
    else
        printf '  UDP 端口    : %s\n' "$PORT"
    fi
    printf '  域名 / SNI  : %s\n' "$DOMAIN"
    printf '  密码        : %s\n' "$PASSWORD"
    printf '  ALPN        : h3\n'
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    printf '%sHysteria 2 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    if command -v qrencode >/dev/null 2>&1; then
        printf '%s节点二维码：%s\n' "$C_GREEN" "$C_RESET"
        if ! qrencode -t ANSIUTF8 "$link" 2>/dev/null; then
            qrencode -t ANSI "$link" 2>/dev/null || warn "二维码生成失败，请直接使用上方链接"
        fi
        printf '\n'
    else
        warn "未安装 qrencode，跳过二维码输出"
    fi

    printf '%s提示：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - Hysteria 2 基于 QUIC/UDP，客户端需支持：sing-box / mihomo(Clash.Meta) / 官方 Hysteria 2\n'
    printf '  - 无法套 Cloudflare CDN，必须客户端直连\n'
    printf '  - NAT 机器需在服务商面板把 UDP 外部端口 %s 映射到容器内部端口 %s\n' "$PORT" "$PORT"
    printf '  - 证书域名需与 SNI 一致，否则客户端会校验证书失败\n'
    if [[ -n "$HOP_PORTS" ]]; then
        printf '  - 端口跳跃：云服务商安全组需放行跳跃端口的 UDP 流量（%s），客户端将随机选口连接\n' "${HOP_PORTS// /, }"
    fi
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    check_os
    require_tty
    check_network

    printf '\n%s========== cgg-vless · Hysteria 2（sing-box）==========%s\n\n' "$C_MAGENTA" "$C_RESET"
    warn "Xray-core 不支持 Hysteria 2，本脚本复用 sing-box 后端，配置与服务独立，不影响现有节点"

    ask_domain
    ask_port
    ask_node_name
    ask_cert_source
    gen_password

    install_singbox
    write_config
    write_service
    setup_port_hopping
    verify_runtime
    configure_firewall
    save_info

    SERVER_IP="$(get_public_ip)"
    print_result
    log "安装完成"
}

main "$@"
