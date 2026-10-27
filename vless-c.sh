#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · 总菜单入口
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash vless-c.sh
# 说    明：统一入口，调用同目录下的三个子脚本；
#           若通过 curl 远程运行，会自动下载子脚本到 /opt/cgg-vless 再执行
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="${CONFIG_DIR}/cgg-vless.info"
# 每个节点独立保存元信息，支持多个协议节点并存
readonly NODES_DIR="${CONFIG_DIR}/nodes"
readonly TAG_REALITY="vless-reality"
readonly TAG_WS="vless-ws-tls"
readonly TAG_TUNNEL="vless-ws-tunnel"
readonly CERT_DIR="${CONFIG_DIR}/cert"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly CACHE_DIR="/opt/cgg-vless"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly REPO_RAW="${CGG_RAW_BASE:-https://raw.githubusercontent.com/chengege666/vless-c/main}"

# AnyTLS 使用独立 sing-box 后端，与 Xray 完全分离
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly SINGBOX_DIR="/usr/local/etc/sing-box"
readonly ANYTLS_CONFIG="${SINGBOX_DIR}/config.json"
readonly ANYTLS_INFO="${SINGBOX_DIR}/cgg-anytls.info"
readonly ANYTLS_SERVICE_FILE="/etc/systemd/system/cgg-anytls.service"

# Hysteria 2 复用 sing-box 二进制，配置与服务独立存放
readonly HS2_CONFIG="${SINGBOX_DIR}/hysteria2.json"
readonly HS2_INFO="${SINGBOX_DIR}/cgg-hysteria2.info"
readonly HS2_SERVICE_FILE="/etc/systemd/system/cgg-hysteria2.service"

# 子脚本文件名
readonly SCRIPT_REALITY="cgg-vless-reality.sh"
readonly SCRIPT_WS="cgg-vless-ws-tls.sh"
readonly SCRIPT_TUNNEL="cgg-vless-tunnel.sh"
readonly SCRIPT_ANYTLS="cgg-vless-anytls.sh"
readonly SCRIPT_HS2="cgg-vless-hysteria2.sh"

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

# ------------------------------ 运行期变量 ------------------------------------
SCRIPT_DIR=""
SERVER_IP=""
R_PORT=""
R_UUID=""
R_SNI=""
R_PRIVATE_KEY=""
R_PUBLIC_KEY=""
R_SHORT_ID=""

# ------------------------------ 日志函数 --------------------------------------
log()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "操作失败（行号：$LINENO，退出码：$?）"' ERR

# ------------------------------ 终端横幅 --------------------------------------
show_banner() {
    printf '%s' "$C_CYAN"
    cat <<'EOF'
  ██████╗ ██████╗  ██████╗     ██╗   ██╗██╗     ███████╗███████╗███████╗
 ██╔════╝██╔════╝ ██╔════╝     ██║   ██║██║     ██╔════╝██╔════╝██╔════╝
 ██║     ██║  ███╗██║  ███╗    ██║   ██║██║     █████╗  ███████╗███████╗
 ██║     ██║   ██║██║   ██║    ╚██╗ ██╔╝██║     ██╔══╝  ╚════██║╚════██║
 ╚██████╗╚██████╔╝╚██████╔╝     ╚████╔╝ ███████╗███████╗███████║███████║
  ╚═════╝ ╚═════╝  ╚═════╝       ╚═══╝  ╚══════╝╚══════╝╚══════╝╚══════╝
EOF
    printf '%s                    cgg-vless · 总菜单入口%s\n\n' "$C_MAGENTA" "$C_RESET"
}

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

# ------------------------------ 子脚本定位 ------------------------------------
# 本地运行时记录脚本所在目录；curl 管道运行时该值为空
resolve_script_dir() {
    local src="${BASH_SOURCE[0]:-}"
    [[ -n "$src" && -f "$src" ]] || return 0
    local dir
    dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || return 0
    SCRIPT_DIR="$dir"
}

# 返回可执行的子脚本路径：本地优先，其次下载到缓存目录
get_child_script() {
    local name="$1"

    if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${name}" ]]; then
        printf '%s' "${SCRIPT_DIR}/${name}"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || { err "缺少 curl，无法下载子脚本"; return 1; }

    mkdir -p "$CACHE_DIR" || { err "无法创建缓存目录：${CACHE_DIR}"; return 1; }
    chmod 700 "$CACHE_DIR" 2>/dev/null || true

    local dst="${CACHE_DIR}/${name}"
    local tmp="${dst}.tmp"

    # 注意：本函数通过命令替换取返回值，日志必须输出到 stderr，避免污染路径
    printf '%s[INFO]%s 下载子脚本：%s\n' "$C_GREEN" "$C_RESET" "${REPO_RAW}/${name}" >&2
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "${REPO_RAW}/${name}"; then
        rm -f "$tmp"
        err "子脚本下载失败：${name}"
        warn "可通过环境变量指定仓库地址，例如：CGG_RAW_BASE=https://cdn.jsdelivr.net/gh/用户/仓库@main bash $0"
        return 1
    fi

    # 去除可能存在的 Windows 换行符
    sed -i 's/\r$//' "$tmp" 2>/dev/null || true
    mv "$tmp" "$dst"
    chmod 755 "$dst"

    printf '%s' "$dst"
}

run_child() {
    local name="$1"
    local path
    if ! path="$(get_child_script "$name")"; then
        return 1
    fi

    log "执行子脚本：${path}"
    if ! bash "$path"; then
        err "子脚本执行失败：${name}"
        return 1
    fi
    return 0
}

# ------------------------------ 多节点辅助 ------------------------------------
# 判断 config.json 中是否存在指定 tag 的 inbound
inbound_exists() {
    local tag="$1" count
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    count="$(jq -r --arg tag "$tag" '[.inbounds[]? | select(.tag == $tag)] | length' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ "${count:-0}" -gt 0 ]]
}

# 从指定 tag 的 inbound 中取字段，path 形如 .port
inbound_get() {
    local tag="$1" path="$2"
    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -r --arg tag "$tag" "([.inbounds[]? | select(.tag == \$tag)][0])${path} // empty" "$CONFIG_FILE" 2>/dev/null || true
}

# 节点元信息文件路径
node_info_file() { printf '%s/%s.info' "$NODES_DIR" "$1"; }

# 读取节点元信息（优先 nodes/<tag>.info，旧版单节点回退共享文件）
read_node_value() {
    local tag="$1" key="$2" f mode
    f="$(node_info_file "$tag")"
    if [[ -f "$f" ]]; then
        sed -n "s/^${key}=//p" "$f" | head -n 1
        return 0
    fi
    case "$tag" in
        "$TAG_REALITY") mode="reality" ;;
        "$TAG_WS")      mode="ws" ;;
        "$TAG_TUNNEL")  mode="tunnel" ;;
        *) return 1 ;;
    esac
    if [[ -f "$INFO_FILE" ]] && [[ "$(detect_mode)" == "$mode" ]]; then
        sed -n "s/^${key}=//p" "$INFO_FILE" | head -n 1
        return 0
    fi
    return 1
}

# 更新节点元信息键值（文件不存在时返回失败）
write_node_value() {
    local tag="$1" key="$2" value="$3" f
    f="$(node_info_file "$tag")"
    [[ -f "$f" ]] || return 1
    value="${value//|/\\|}"
    value="${value//&/\\&}"
    if grep -q "^${key}=" "$f"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$f"
    else
        printf '%s=%s\n' "$key" "$value" >> "$f"
    fi
    chmod 600 "$f" 2>/dev/null || true
    return 0
}

# tag → 中文描述
tag_desc() {
    case "$1" in
        "$TAG_REALITY") printf 'VLESS + Reality' ;;
        "$TAG_WS")      printf 'VLESS + WS + TLS' ;;
        "$TAG_TUNNEL")  printf 'VLESS + WS + CF Tunnel' ;;
        *)              printf '%s' "$1" ;;
    esac
}

# 列出已安装的 Xray 节点 tag（固定顺序）
xray_node_tags() {
    local t
    for t in "$TAG_REALITY" "$TAG_WS" "$TAG_TUNNEL"; do
        if inbound_exists "$t"; then
            printf '%s\n' "$t"
        fi
    done
}

# ------------------------------ 模式检测 --------------------------------------
# 输出 reality / ws / tunnel / unknown / none（多节点时返回第一个已安装模式）
detect_mode() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf 'none'
        return 0
    fi
    command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }

    if inbound_exists "$TAG_REALITY"; then
        printf 'reality'
        return 0
    fi
    if inbound_exists "$TAG_WS"; then
        printf 'ws'
        return 0
    fi
    if inbound_exists "$TAG_TUNNEL"; then
        printf 'tunnel'
        return 0
    fi

    # 兼容旧版无 tag 配置
    local sec net
    sec="$(jq -r '.inbounds[0].streamSettings.security // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    net="$(jq -r '.inbounds[0].streamSettings.network // empty' "$CONFIG_FILE" 2>/dev/null || true)"

    if [[ "$sec" == "reality" ]]; then
        printf 'reality'
    elif [[ "$sec" == "tls" && "$net" == "ws" ]]; then
        printf 'ws'
    elif [[ "$sec" == "none" && "$net" == "ws" ]]; then
        printf 'tunnel'
    else
        printf 'unknown'
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

# ------------------------------ 二维码 ----------------------------------------
print_qr() {
    local link="$1"
    if command -v qrencode >/dev/null 2>&1; then
        printf '%s节点二维码：%s\n' "$C_GREEN" "$C_RESET"
        if ! qrencode -t ANSIUTF8 "$link" 2>/dev/null; then
            qrencode -t ANSI "$link" 2>/dev/null || warn "二维码生成失败，请直接使用上方链接"
        fi
        printf '\n'
    else
        warn "未安装 qrencode，跳过二维码输出"
    fi
}

# ------------------------------ 安装入口 --------------------------------------
install_reality() {
    if inbound_exists "$TAG_REALITY"; then
        warn "已安装 Reality 节点，继续安装将覆盖该节点（其他节点不受影响）"
        local ans
        read -r -p "确认覆盖？[y/N]：" ans
        case "$ans" in
            [Yy]*) ;;
            *) warn "已取消"; return 1 ;;
        esac
    fi
    run_child "$SCRIPT_REALITY"
}

install_ws() {
    if inbound_exists "$TAG_WS"; then
        warn "已安装 WS+TLS 节点，继续安装将覆盖该节点（其他节点不受影响）"
        local ans
        read -r -p "确认覆盖？[y/N]：" ans
        case "$ans" in
            [Yy]*) ;;
            *) warn "已取消"; return 1 ;;
        esac
    fi
    run_child "$SCRIPT_WS"
}

install_tunnel() {
    if inbound_exists "$TAG_TUNNEL"; then
        warn "已安装 CF Tunnel 节点，继续安装将覆盖该节点（其他节点不受影响）"
        local ans
        read -r -p "确认覆盖？[y/N]：" ans
        case "$ans" in
            [Yy]*) ;;
            *) warn "已取消"; return 1 ;;
        esac
    fi
    run_child "$SCRIPT_TUNNEL"
}

# AnyTLS 使用独立 sing-box 后端，不覆盖 Xray 配置，仅在端口冲突时由子脚本拦截
install_anytls() {
    run_child "$SCRIPT_ANYTLS"
}

# Hysteria 2 同样使用独立 sing-box 后端，仅在 UDP 端口冲突时由子脚本拦截
install_hysteria2() {
    run_child "$SCRIPT_HS2"
}

# ------------------------------ 元信息文件读写 --------------------------------
# 读取 INFO_FILE 中指定键的值（键不存在时输出为空）
read_info_value() {
    local key="$1"
    [[ -f "$INFO_FILE" ]] || return 1
    sed -n "s/^${key}=//p" "$INFO_FILE" | head -n 1
}

# 更新 INFO_FILE 中指定键的值（文件或键不存在时追加）
update_info_value() {
    local key="$1" value="$2"
    if [[ ! -f "$INFO_FILE" ]]; then
        install -d -m 755 -o root -g root "$CONFIG_DIR"
        printf '%s=%s\n' "$key" "$value" > "$INFO_FILE"
        chmod 600 "$INFO_FILE"
        return 0
    fi
    if grep -q "^${key}=" "$INFO_FILE"; then
        # 转义分隔符 | 与替换特殊符 &，避免破坏 sed 表达式
        value="${value//|/\\|}"
        value="${value//&/\\&}"
        sed -i "s|^${key}=.*|${key}=${value}|" "$INFO_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$INFO_FILE"
    fi
}

# AnyTLS 元信息独立存放，避免覆盖 Xray 的 INFO_FILE
read_anytls_info() {
    local key="$1"
    [[ -f "$ANYTLS_INFO" ]] || return 1
    sed -n "s/^${key}=//p" "$ANYTLS_INFO" | head -n 1
}

update_anytls_info() {
    local key="$1" value="$2"
    [[ -f "$ANYTLS_INFO" ]] || return 1
    if grep -q "^${key}=" "$ANYTLS_INFO"; then
        value="${value//|/\\|}"
        value="${value//&/\\&}"
        sed -i "s|^${key}=.*|${key}=${value}|" "$ANYTLS_INFO"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ANYTLS_INFO"
    fi
}

# Hysteria 2 元信息同样独立存放
read_hysteria2_info() {
    local key="$1"
    [[ -f "$HS2_INFO" ]] || return 1
    sed -n "s/^${key}=//p" "$HS2_INFO" | head -n 1
}

update_hysteria2_info() {
    local key="$1" value="$2"
    [[ -f "$HS2_INFO" ]] || return 1
    if grep -q "^${key}=" "$HS2_INFO"; then
        value="${value//|/\\|}"
        value="${value//&/\\&}"
        sed -i "s|^${key}=.*|${key}=${value}|" "$HS2_INFO"
    else
        printf '%s=%s\n' "$key" "$value" >> "$HS2_INFO"
    fi
}

# ------------------------------ 查看节点信息 ----------------------------------
load_reality() {
    inbound_exists "$TAG_REALITY" || return 1
    R_PORT="$(inbound_get "$TAG_REALITY" '.port')"
    R_UUID="$(inbound_get "$TAG_REALITY" '.settings.clients[0].id')"
    R_SNI="$(inbound_get "$TAG_REALITY" '.streamSettings.realitySettings.serverNames[0]')"
    R_PRIVATE_KEY="$(inbound_get "$TAG_REALITY" '.streamSettings.realitySettings.privateKey')"
    R_SHORT_ID="$(inbound_get "$TAG_REALITY" '.streamSettings.realitySettings.shortIds[0]')"

    [[ -n "$R_PORT" && -n "$R_UUID" && -n "$R_SNI" && -n "$R_PRIVATE_KEY" && -n "$R_SHORT_ID" ]] || return 1

    # 优先读取安装时保存的公钥与节点名称
    R_PUBLIC_KEY="$(read_node_value "$TAG_REALITY" PUBLIC_KEY || true)"
    R_NODE_NAME="$(read_node_value "$TAG_REALITY" NODE_NAME || true)"
    [[ -n "$R_NODE_NAME" ]] || R_NODE_NAME="cgg-vless"

    # 元信息缺失时由私钥反推公钥
    if [[ -z "$R_PUBLIC_KEY" ]]; then
        [[ -x "$XRAY_BIN" ]] || return 1
        local out=""
        out="$("$XRAY_BIN" x25519 -i "$R_PRIVATE_KEY" 2>&1 || true)"
        R_PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F: 'tolower($1) ~ /password|public/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    fi
    [[ -n "$R_PUBLIC_KEY" ]] || return 1
    return 0
}

show_info_reality() {
    local link ip node_name
    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    node_name="${R_NODE_NAME:-cgg-vless}"
    link="vless://${R_UUID}@${ip}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${R_SNI}&fp=chrome&pbk=${R_PUBLIC_KEY}&sid=${R_SHORT_ID}&type=tcp&headerType=none#${node_name}"

    printf '\n%s=============== cgg-vless Reality 节点 ===============%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : VLESS + Reality\n'
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$R_PORT"
    printf '  UUID        : %s\n' "$R_UUID"
    printf '  流控 flow   : xtls-rprx-vision\n'
    printf '  公钥 pbk    : %s\n' "$R_PUBLIC_KEY"
    printf '  ShortID     : %s\n' "$R_SHORT_ID"
    printf '  伪装域名SNI : %s\n' "$R_SNI"
    printf '%s======================================================%s\n\n' "$C_CYAN" "$C_RESET"

    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"
    print_qr "$link"
}

# 从证书中提取域名
extract_cert_domain() {
    local cert="${CERT_DIR}/fullchain.pem"
    [[ -s "$cert" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    local d
    d="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | grep -o 'DNS:[^ ,]*' | head -n 1 | cut -d: -f2 || true)"
    if [[ -z "$d" ]]; then
        d="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null \
            | grep -o 'CN *= *[^,]*' | head -n 1 | sed 's/.*= *//' || true)"
    fi
    [[ -n "$d" ]] || return 1
    printf '%s' "$d"
}

show_info_ws() {
    local port uuid path domain link ip enc_path node_name
    if ! inbound_exists "$TAG_WS"; then
        err "未找到 WS+TLS 节点配置"
        return 1
    fi
    port="$(inbound_get "$TAG_WS" '.port')"
    uuid="$(inbound_get "$TAG_WS" '.settings.clients[0].id')"
    path="$(inbound_get "$TAG_WS" '.streamSettings.wsSettings.path')"

    if [[ -z "$port" || -z "$uuid" || -z "$path" ]]; then
        err "配置读取不完整，无法生成链接"
        return 1
    fi

    # 优先使用安装时记录的域名，避免证书为泛域名时无法作为 SNI
    domain="$(read_node_value "$TAG_WS" DOMAIN || true)"
    if [[ -z "$domain" ]]; then
        domain="$(extract_cert_domain || true)"
    fi
    if [[ -z "$domain" || "$domain" == \*.* ]]; then
        warn "无法确定可用域名，请手动填写 SNI"
        domain="YOUR_DOMAIN"
    fi

    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    enc_path="$(printf '%s' "$path" | sed 's|/|%2F|g')"
    node_name="$(read_node_value "$TAG_WS" NODE_NAME || true)"
    [[ -n "$node_name" ]] || node_name="cgg-vless-ws"
    link="vless://${uuid}@${ip}:${port}?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${enc_path}#${node_name}"

    printf '\n%s============= cgg-vless WS + TLS 节点 =============%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : VLESS + WebSocket + TLS\n'
    printf '  节点名称    : %s\n' "$node_name"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$port"
    printf '  域名        : %s\n' "$domain"
    printf '  UUID        : %s\n' "$uuid"
    printf '  WS 路径     : %s\n' "$path"
    printf '  SNI         : %s\n' "$domain"
    printf '%s===================================================%s\n\n' "$C_CYAN" "$C_RESET"
    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"
    print_qr "$link"
}

# 隧道模式（VLESS + WS + CF Tunnel）节点信息
show_info_tunnel() {
    local port uuid path domain link node_name ttype latest enc_path
    if ! inbound_exists "$TAG_TUNNEL"; then
        err "未找到 CF Tunnel 节点配置"
        return 1
    fi
    port="$(inbound_get "$TAG_TUNNEL" '.port')"
    uuid="$(inbound_get "$TAG_TUNNEL" '.settings.clients[0].id')"
    path="$(inbound_get "$TAG_TUNNEL" '.streamSettings.wsSettings.path')"

    if [[ -z "$port" || -z "$uuid" || -z "$path" ]]; then
        err "配置读取不完整，无法生成链接"
        return 1
    fi

    ttype="$(read_node_value "$TAG_TUNNEL" TUNNEL_TYPE || true)"
    node_name="$(read_node_value "$TAG_TUNNEL" NODE_NAME || true)"
    [[ -n "$node_name" ]] || node_name="cgg-vless-tunnel"
    domain="$(read_node_value "$TAG_TUNNEL" TUNNEL_DOMAIN || true)"

    # 临时隧道重启后域名会变化，优先读取服务日志中的最新域名
    if [[ "$ttype" == "quick" ]]; then
        latest="$(journalctl -u cgg-quick-tunnel --no-pager -n 200 2>/dev/null \
            | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n 1 || true)"
        if [[ -n "$latest" && "${latest#https://}" != "$domain" ]]; then
            domain="${latest#https://}"
            if ! write_node_value "$TAG_TUNNEL" TUNNEL_DOMAIN "$domain"; then
                update_info_value TUNNEL_DOMAIN "$domain"
            fi
            warn "临时隧道域名已更新，客户端请重新获取"
        fi
    fi

    if [[ -z "$domain" ]]; then
        warn "尚未记录隧道域名，请在 Cloudflare 网页端完成 Public Hostname 配置"
        domain="YOUR_TUNNEL_DOMAIN"
    fi

    enc_path="$(printf '%s' "$path" | sed 's|/|%2F|g')"
    link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=${enc_path}#${node_name}"

    printf '\n%s============ cgg-vless WS + CF Tunnel 节点 ============%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : VLESS + WebSocket + CF Tunnel\n'
    printf '  隧道类型    : %s\n' "$([[ "$ttype" == "quick" ]] && printf '临时隧道（trycloudflare）' || printf '固定隧道')"
    printf '  节点名称    : %s\n' "$node_name"
    printf '  隧道域名    : %s\n' "$domain"
    printf '  端口        : 443（TLS 由 Cloudflare 边缘处理）\n'
    printf '  UUID        : %s\n' "$uuid"
    printf '  WS 路径     : %s\n' "$path"
    printf '  本地回源    : 127.0.0.1:%s\n' "$port"
    printf '  SNI         : %s\n' "$domain"
    printf '%s======================================================%s\n\n' "$C_CYAN" "$C_RESET"

    if [[ "$ttype" == "quick" ]]; then
        printf '%s临时隧道：域名每次重启都会变化，重新查看可获取最新域名；仅建议测试使用。%s\n\n' "$C_YELLOW" "$C_RESET"
    else
        printf '%s固定隧道：网页端 Public Hostname 需指向 http://localhost:%s%s\n\n' "$C_YELLOW" "$port" "$C_RESET"
    fi

    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"
    print_qr "$link"
}

show_info_anytls() {
    local port domain password node_name link ip
    if [[ ! -f "$ANYTLS_CONFIG" ]]; then
        err "未找到 AnyTLS 配置"
        return 1
    fi

    port="$(jq -r '.inbounds[0].listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null || true)"
    password="$(jq -r '.inbounds[0].users[0].password // empty' "$ANYTLS_CONFIG" 2>/dev/null || true)"
    domain="$(read_anytls_info DOMAIN || true)"
    [[ -n "$domain" ]] || domain="$(jq -r '.inbounds[0].tls.server_name // empty' "$ANYTLS_CONFIG" 2>/dev/null || true)"
    node_name="$(read_anytls_info NODE_NAME || true)"
    [[ -n "$node_name" ]] || node_name="cgg-anytls"

    if [[ -z "$port" || -z "$password" || -z "$domain" ]]; then
        err "AnyTLS 配置读取不完整，无法生成链接"
        return 1
    fi

    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    link="anytls://${password}@${ip}:${port}?security=tls&sni=${domain}&fp=chrome#${node_name}"

    printf '\n%s================= cgg-vless AnyTLS 节点 =================%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : AnyTLS + TLS（sing-box）\n'
    printf '  节点名称    : %s\n' "$node_name"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$port"
    printf '  域名 / SNI  : %s\n' "$domain"
    printf '  密码        : %s\n' "$password"
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"
    printf '%sAnyTLS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"
    print_qr "$link"

    if systemctl is-active --quiet cgg-anytls 2>/dev/null; then
        log "AnyTLS 服务状态：运行中"
    else
        warn "AnyTLS 服务状态：未运行"
    fi
    printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$ANYTLS_CONFIG" "$C_RESET"
}

show_info_hysteria2() {
    local port domain password node_name link ip
    if [[ ! -f "$HS2_CONFIG" ]]; then
        err "未找到 Hysteria 2 配置"
        return 1
    fi

    port="$(jq -r '.inbounds[0].listen_port // empty' "$HS2_CONFIG" 2>/dev/null || true)"
    password="$(jq -r '.inbounds[0].users[0].password // empty' "$HS2_CONFIG" 2>/dev/null || true)"
    domain="$(read_hysteria2_info DOMAIN || true)"
    [[ -n "$domain" ]] || domain="$(jq -r '.inbounds[0].tls.server_name // empty' "$HS2_CONFIG" 2>/dev/null || true)"
    node_name="$(read_hysteria2_info NODE_NAME || true)"
    [[ -n "$node_name" ]] || node_name="cgg-hysteria2"

    if [[ -z "$port" || -z "$password" || -z "$domain" ]]; then
        err "Hysteria 2 配置读取不完整，无法生成链接"
        return 1
    fi

    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    link="hysteria2://${password}@${ip}:${port}/?sni=${domain}&alpn=h3#${node_name}"

    printf '\n%s=============== cgg-vless Hysteria 2 节点 ===============%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : Hysteria 2（sing-box，QUIC/UDP）\n'
    printf '  节点名称    : %s\n' "$node_name"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  UDP 端口    : %s\n' "$port"
    printf '  域名 / SNI  : %s\n' "$domain"
    printf '  密码        : %s\n' "$password"
    printf '  ALPN        : h3\n'
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"
    printf '%sHysteria 2 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"
    print_qr "$link"

    if systemctl is-active --quiet cgg-hysteria2 2>/dev/null; then
        log "Hysteria 2 服务状态：运行中"
    else
        warn "Hysteria 2 服务状态：未运行"
    fi
    printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$HS2_CONFIG" "$C_RESET"
}

show_info() {
    if command -v jq >/dev/null 2>&1; then
        :
    else
        err "缺少 jq，请先安装：apt-get install -y jq"
        return 1
    fi

    local shown=0 mode
    SERVER_IP="$(get_public_ip)"

    # Xray 支持多 inbound，逐个节点输出链接
    if inbound_exists "$TAG_REALITY"; then
        if load_reality; then
            show_info_reality
            shown=1
        else
            err "Reality 配置读取失败，可能配置不完整"
        fi
    fi

    if inbound_exists "$TAG_WS"; then
        if show_info_ws; then
            shown=1
        fi
    fi

    if inbound_exists "$TAG_TUNNEL"; then
        if show_info_tunnel; then
            shown=1
        fi
    fi

    if (( shown == 1 )); then
        if systemctl is-active --quiet xray 2>/dev/null; then
            log "Xray 服务状态：运行中"
        else
            warn "Xray 服务状态：未运行"
        fi
        printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$CONFIG_FILE" "$C_RESET"
    elif [[ -f "$CONFIG_FILE" ]]; then
        mode="$(detect_mode)"
        case "$mode" in
            unknown)
                err "无法识别当前配置模式（仅支持 Reality / WS+TLS / CF Tunnel）"
                return 1
                ;;
            *)
                err "未找到有效配置"
                ;;
        esac
    fi

    # AnyTLS 与 Xray 并存时一并显示
    if [[ -f "$ANYTLS_CONFIG" ]]; then
        show_info_anytls
        shown=1
    fi

    # Hysteria 2 与 Xray / AnyTLS 并存时一并显示
    if [[ -f "$HS2_CONFIG" ]]; then
        show_info_hysteria2
        shown=1
    fi

    if (( shown == 0 )); then
        err "未找到配置，请先执行安装"
        return 1
    fi
}

# ------------------------------ 服务控制 --------------------------------------
service_action() {
    local action="$1"
    local has_xray=0 has_anytls=0 has_hs2=0 failed=0
    [[ -f "$SERVICE_FILE" ]] && has_xray=1
    [[ -f "$ANYTLS_SERVICE_FILE" ]] && has_anytls=1
    [[ -f "$HS2_SERVICE_FILE" ]] && has_hs2=1

    if (( has_xray == 0 && has_anytls == 0 && has_hs2 == 0 )); then
        err "未找到 systemd 服务，请先执行安装"
        return 1
    fi

    if (( has_xray == 1 )); then
        systemctl "$action" xray || { err "systemctl ${action} xray 失败"; failed=1; }
    fi

    # AnyTLS 使用独立 sing-box 服务，与 Xray 分别控制
    if (( has_anytls == 1 )); then
        systemctl "$action" cgg-anytls || { err "systemctl ${action} cgg-anytls 失败"; failed=1; }
    fi

    # Hysteria 2 使用独立 sing-box 服务，与 Xray / AnyTLS 分别控制
    if (( has_hs2 == 1 )); then
        systemctl "$action" cgg-hysteria2 || { err "systemctl ${action} cgg-hysteria2 失败"; failed=1; }
    fi

    sleep 1

    # Cloudflare Tunnel 服务仅在存在 Tunnel 节点时联动（固定：cloudflared；临时：cgg-quick-tunnel）
    if (( has_xray == 1 )) && inbound_exists "$TAG_TUNNEL"; then
        local tsvc
        for tsvc in cloudflared cgg-quick-tunnel; do
            if systemctl cat "$tsvc" >/dev/null 2>&1; then
                systemctl "$action" "$tsvc" >/dev/null 2>&1 || warn "systemctl ${action} ${tsvc} 失败"
            fi
        done
    fi

    if (( failed == 1 )); then
        return 1
    fi

    if [[ "$action" == "stop" ]]; then
        if (( has_anytls == 1 && has_hs2 == 1 )); then
            log "Xray / AnyTLS / Hysteria 2 已停止"
        elif (( has_anytls == 1 )); then
            log "Xray / AnyTLS 已停止"
        elif (( has_hs2 == 1 )); then
            log "Xray / Hysteria 2 已停止"
        else
            log "Xray 已停止"
        fi
        return 0
    fi

    local parts=""
    if (( has_xray == 1 )); then
        if systemctl is-active --quiet xray; then
            parts="Xray 运行中"
        else
            err "Xray ${action} 后未处于运行状态，请查看日志"
            failed=1
        fi
    fi
    if (( has_anytls == 1 )); then
        if systemctl is-active --quiet cgg-anytls; then
            parts="${parts:+${parts}，}AnyTLS 运行中"
        else
            err "AnyTLS ${action} 后未处于运行状态，请查看日志"
            failed=1
        fi
    fi
    if (( has_hs2 == 1 )); then
        if systemctl is-active --quiet cgg-hysteria2; then
            parts="${parts:+${parts}，}Hysteria 2 运行中"
        else
            err "Hysteria 2 ${action} 后未处于运行状态，请查看日志"
            failed=1
        fi
    fi
    if (( failed == 1 )); then
        return 1
    fi

    log "服务已${action}完成，当前状态：${parts}"
}

# ------------------------------ 修改 Reality 配置 -----------------------------
save_reality_info() {
    local nf
    install -d -m 755 -o root -g root "$CONFIG_DIR"
    install -d -m 755 -o root -g root "$NODES_DIR"
    nf="$(node_info_file "$TAG_REALITY")"
    {
        printf 'MODE=reality\n'
        printf 'PORT=%s\n' "$R_PORT"
        printf 'UUID=%s\n' "$R_UUID"
        printf 'SNI=%s\n' "$R_SNI"
        printf 'PUBLIC_KEY=%s\n' "$R_PUBLIC_KEY"
        printf 'SHORT_ID=%s\n' "$R_SHORT_ID"
        printf 'NODE_NAME=%s\n' "${R_NODE_NAME:-cgg-vless}"
    } > "$nf"
    chmod 600 "$nf"

    # 兼容旧版管理菜单：继续写共享元信息文件
    cp -f "$nf" "$INFO_FILE" 2>/dev/null || true
    chmod 600 "$INFO_FILE" 2>/dev/null || true
}

restart_after_change() {
    local ans
    read -r -p "配置已更新，是否立即重启 Xray 生效？[Y/n]：" ans
    case "$ans" in
        [Nn]*)
            warn "已跳过重启，请稍后手动执行：systemctl restart xray"
            ;;
        *)
            systemctl daemon-reload
            if systemctl restart xray && sleep 1 && systemctl is-active --quiet xray; then
                log "Xray 已重启生效"
            else
                err "Xray 重启失败，可使用备份配置回滚"
            fi
            ;;
    esac
}

change_sni() {
    if ! load_reality; then
        err "Reality 配置读取失败，请先执行安装"
        return 1
    fi

    local input tmp cfg_group
    read -r -p "请输入新的伪装域名（当前 ${R_SNI}）：" input
    input="${input//[[:space:]]/}"
    [[ -n "$input" ]] || { warn "输入为空，已取消"; return 1; }
    if [[ ! "$input" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
        err "域名格式不合法：${input}"
        return 1
    fi

    # Xray 按扩展名判断配置格式，临时文件必须带 .json 后缀
    tmp="$(mktemp "${TMPDIR:-/tmp}/cgg-vless-XXXXXX.json")"
    if ! jq --arg sni "$input" --arg tag "$TAG_REALITY" '
        .inbounds = [.inbounds[] | if .tag == $tag then
            .streamSettings.realitySettings.dest = ($sni + ":443")
            | .streamSettings.realitySettings.serverNames = [$sni]
        else . end]
    ' "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "生成新配置失败"
        return 1
    fi

    if ! "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "新配置校验失败，已保留原配置"
        return 1
    fi

    # 保留原配置属组，避免 Xray 以 nobody 运行时无法读取
    cfg_group="$(stat -c '%G' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$cfg_group" ]] || cfg_group="root"
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    if ! install -m 640 -o root -g "$cfg_group" "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "写入配置失败，已保留原配置"
        return 1
    fi
    rm -f "$tmp"
    chmod 640 "$CONFIG_FILE"

    R_SNI="$input"
    save_reality_info
    log "SNI 已更新为：${R_SNI}"
    restart_after_change
}

reset_uuid() {
    if ! load_reality; then
        err "Reality 配置读取失败，请先执行安装"
        return 1
    fi

    local ans tmp new_uuid cfg_group
    read -r -p "确认重置 UUID？旧 UUID 将立即失效 [y/N]：" ans
    case "$ans" in
        [Yy]*) ;;
        *) warn "已取消"; return 1 ;;
    esac

    new_uuid="$("$XRAY_BIN" uuid 2>/dev/null || true)"
    [[ -n "$new_uuid" ]] || new_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    [[ -n "$new_uuid" ]] || { err "UUID 生成失败"; return 1; }

    # Xray 按扩展名判断配置格式，临时文件必须带 .json 后缀
    tmp="$(mktemp "${TMPDIR:-/tmp}/cgg-vless-XXXXXX.json")"
    if ! jq --arg id "$new_uuid" --arg tag "$TAG_REALITY" '
        .inbounds = [.inbounds[] | if .tag == $tag then
            .settings.clients[0].id = $id
        else . end]
    ' "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "生成新配置失败"
        return 1
    fi

    if ! "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "新配置校验失败，已保留原配置"
        return 1
    fi

    # 保留原配置属组，避免 Xray 以 nobody 运行时无法读取
    cfg_group="$(stat -c '%G' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$cfg_group" ]] || cfg_group="root"
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    if ! install -m 640 -o root -g "$cfg_group" "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "写入配置失败，已保留原配置"
        return 1
    fi
    rm -f "$tmp"
    chmod 640 "$CONFIG_FILE"

    R_UUID="$new_uuid"
    save_reality_info
    log "UUID 已重置：${R_UUID}"
    restart_after_change
}

# 选择要操作的 Xray 节点，结果写入 SELECTED_TAG
select_xray_node() {
    local tags=() t choice i=1
    while IFS= read -r t; do
        [[ -n "$t" ]] && tags+=("$t")
    done < <(xray_node_tags)

    if (( ${#tags[@]} == 0 )); then
        err "未找到 Xray 节点，请先执行安装"
        return 1
    fi
    if (( ${#tags[@]} == 1 )); then
        SELECTED_TAG="${tags[0]}"
        return 0
    fi

    printf '\n请选择要操作的节点：\n'
    for t in "${tags[@]}"; do
        printf '  %d) %s\n' "$i" "$(tag_desc "$t")"
        i=$((i + 1))
    done
    read -r -p "请选择 [1-${#tags[@]}]：" choice || return 1
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( 10#$choice < 1 || 10#$choice > ${#tags[@]} )); then
        err "无效选项：${choice}"
        return 1
    fi
    SELECTED_TAG="${tags[$((10#$choice - 1))]}"
    return 0
}

# 修改节点名称（Reality / WS 均可用，多节点时先选择节点）
change_node_name() {
    local current input tag
    if ! select_xray_node; then
        return 1
    fi
    tag="$SELECTED_TAG"

    case "$tag" in
        "$TAG_REALITY")
            if ! load_reality; then
                err "Reality 配置读取失败，请先执行安装"
                return 1
            fi
            current="$R_NODE_NAME"
            ;;
        "$TAG_WS")
            current="$(read_node_value "$TAG_WS" NODE_NAME || true)"
            [[ -n "$current" ]] || current="cgg-vless-ws"
            ;;
        "$TAG_TUNNEL")
            current="$(read_node_value "$TAG_TUNNEL" NODE_NAME || true)"
            [[ -n "$current" ]] || current="cgg-vless-tunnel"
            ;;
        *)
            err "未找到有效配置，请先执行安装"
            return 1
            ;;
    esac

    read -r -p "请输入新的节点名称（当前 ${current}，回车取消）：" input
    # 去掉分隔符与空白，避免破坏 vless:// 链接格式
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    [[ -n "$input" ]] || { warn "输入为空，已取消"; return 1; }

    if ! write_node_value "$tag" NODE_NAME "$input"; then
        # 旧版单节点没有独立元信息文件，回退写入共享文件
        update_info_value NODE_NAME "$input"
    fi
    log "节点名称已更新为：${input}"

    # 名称仅影响分享链接备注，无需重启服务
    SERVER_IP="$(get_public_ip)"
    case "$tag" in
        "$TAG_REALITY")
            if load_reality; then
                show_info_reality
            fi
            ;;
        "$TAG_TUNNEL")
            show_info_tunnel
            ;;
        *)
            show_info_ws
            ;;
    esac
}

# 修改 AnyTLS 节点名称（仅影响分享链接备注，无需重启）
change_anytls_node_name() {
    local current input
    current="$(read_anytls_info NODE_NAME || true)"
    [[ -n "$current" ]] || current="cgg-anytls"

    read -r -p "请输入新的 AnyTLS 节点名称（当前 ${current}，回车取消）：" input
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    [[ -n "$input" ]] || { warn "输入为空，已取消"; return 1; }

    if ! update_anytls_info NODE_NAME "$input"; then
        err "AnyTLS 元信息文件不存在：${ANYTLS_INFO}"
        return 1
    fi
    log "AnyTLS 节点名称已更新为：${input}"

    SERVER_IP="$(get_public_ip)"
    show_info_anytls
}

# 修改 Hysteria 2 节点名称（仅影响分享链接备注，无需重启）
change_hysteria2_node_name() {
    local current input
    current="$(read_hysteria2_info NODE_NAME || true)"
    [[ -n "$current" ]] || current="cgg-hysteria2"

    read -r -p "请输入新的 Hysteria 2 节点名称（当前 ${current}，回车取消）：" input
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    [[ -n "$input" ]] || { warn "输入为空，已取消"; return 1; }

    if ! update_hysteria2_info NODE_NAME "$input"; then
        err "Hysteria 2 元信息文件不存在：${HS2_INFO}"
        return 1
    fi
    log "Hysteria 2 节点名称已更新为：${input}"

    SERVER_IP="$(get_public_ip)"
    show_info_hysteria2
}

modify_menu() {
    local choice tags title t
    tags="$(xray_node_tags)"

    local has_xray=0 has_anytls=0 has_hs2=0
    [[ -n "$tags" ]] && has_xray=1
    [[ -f "$ANYTLS_CONFIG" ]] && has_anytls=1
    [[ -f "$HS2_CONFIG" ]] && has_hs2=1

    if (( has_xray == 0 && has_anytls == 0 && has_hs2 == 0 )); then
        err "未找到有效配置，请先执行安装"
        return 1
    fi

    while true; do
        title=""
        if [[ -n "$tags" ]]; then
            while IFS= read -r t; do
                [[ -n "$t" ]] || continue
                title="${title:+${title} + }$(tag_desc "$t")"
            done <<< "$tags"
        fi
        if (( has_anytls == 1 )); then
            title="${title:+${title} + }anytls"
        fi
        if (( has_hs2 == 1 )); then
            title="${title:+${title} + }hysteria2"
        fi
        printf '\n%s-------- 修改配置（当前节点：%s）--------%s\n' "$C_CYAN" "$title" "$C_RESET"
        if (( has_xray == 1 )); then
            printf '  1) 修改节点名称\n'
            if inbound_exists "$TAG_REALITY"; then
                printf '  2) 更换伪装域名 SNI（Reality）\n'
                printf '  3) 重置 UUID（Reality）\n'
            fi
        fi
        if (( has_anytls == 1 )); then
            printf '  4) 修改 AnyTLS 节点名称\n'
        fi
        if (( has_hs2 == 1 )); then
            printf '  5) 修改 Hysteria 2 节点名称\n'
        fi
        printf '  0) 返回主菜单\n'
        if ! read -r -p "请选择：" choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1)
                if (( has_xray == 1 )); then
                    change_node_name || true
                else
                    warn "无效选项：${choice}"
                fi
                ;;
            2)
                if inbound_exists "$TAG_REALITY"; then
                    change_sni || true
                else
                    warn "未安装 Reality 节点，无法修改 SNI"
                fi
                ;;
            3)
                if inbound_exists "$TAG_REALITY"; then
                    reset_uuid || true
                else
                    warn "无效选项：${choice}"
                fi
                ;;
            4)
                if (( has_anytls == 1 )); then
                    change_anytls_node_name || true
                else
                    warn "无效选项：${choice}"
                fi
                ;;
            5)
                if (( has_hs2 == 1 )); then
                    change_hysteria2_node_name || true
                else
                    warn "无效选项：${choice}"
                fi
                ;;
            0) return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
    done
}

# ------------------------------ SSL 证书管理 (acme.sh) ------------------------
acme_ensure() {
    if [[ -x "$ACME_BIN" ]]; then
        log "acme.sh 已安装：$("$ACME_BIN" --version 2>/dev/null | head -n 1)"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || { err "缺少 curl，请先安装 curl"; return 1; }

    # acme.sh 依赖 crontab 创建自动续期任务
    if ! command -v crontab >/dev/null 2>&1; then
        command -v apt-get >/dev/null 2>&1 || { err "缺少 crontab 且无 apt-get"; return 1; }
        log "安装 cron（自动续期依赖）"
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cron \
            || { err "cron 安装失败"; return 1; }
        systemctl enable cron >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || true
    fi

    log "安装 acme.sh..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 https://get.acme.sh | sh; then
        err "acme.sh 下载或安装失败，请检查网络"
        return 1
    fi
    [[ -x "$ACME_BIN" ]] || { err "安装后未找到 ${ACME_BIN}"; return 1; }

    "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 \
        || warn "设置默认 CA 失败，将使用 acme.sh 当前默认 CA"
    log "acme.sh 安装完成"
}

# 普通域名校验
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

# 证书域名校验，兼容 *.example.com 通配符
is_cert_domain() {
    local d="$1"
    d="${d#\*.}"
    is_domain "$d"
}

# 定位 acme.sh 保存的证书目录
acme_cert_dir() {
    local domain="$1"
    [[ -d "${ACME_HOME}/${domain}_ecc" ]] && { printf '%s' "${ACME_HOME}/${domain}_ecc"; return 0; }
    [[ -d "${ACME_HOME}/${domain}" ]] && { printf '%s' "${ACME_HOME}/${domain}"; return 0; }
    return 1
}

acme_is_ecc() {
    [[ -d "${ACME_HOME}/${1}_ecc" ]]
}

# 申请证书：HTTP-01 Standalone（需要 80 端口）
cert_issue_http() {
    acme_ensure || return 1

    local domain
    read -r -p "请输入域名：" domain
    is_cert_domain "$domain" || { err "域名格式不合法：${domain}"; return 1; }

    if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; then
        warn "80 端口已被占用，Standalone 验证可能失败"
    fi

    log "开始 HTTP-01 验证申请：${domain}"
    if ! "$ACME_BIN" --issue --standalone -d "$domain" --keylength ec-256 --httpport 80; then
        err "申请失败：请确认 80 端口公网可达，或改用 DNS-01 验证"
        return 1
    fi
    log "证书申请成功：${domain}"
}

# 配置 DNS API 凭据（由 acme.sh 自动保存到 account.conf）
cert_configure_dns() {
    local provider="$1" token key secret

    case "$provider" in
        dns_cf)
            if grep -q '^CF_Token=' "${ACME_HOME}/account.conf" 2>/dev/null; then
                log "已保存 CF_Token，跳过输入"
                return 0
            fi
            read -r -s -p "Cloudflare API Token（需 Zone.DNS 编辑权限）：" token || return 1
            printf '\n'
            [[ -n "$token" ]] || { err "CF_Token 不能为空"; return 1; }
            export CF_Token="$token"
            ;;
        dns_ali)
            if grep -q '^Ali_Key=' "${ACME_HOME}/account.conf" 2>/dev/null \
                && grep -q '^Ali_Secret=' "${ACME_HOME}/account.conf" 2>/dev/null; then
                log "已保存阿里云 AccessKey，跳过输入"
                return 0
            fi
            read -r -p "请输入 AccessKey ID：" key || return 1
            read -r -s -p "请输入 AccessKey Secret：" secret || return 1
            printf '\n'
            [[ -n "$key" && -n "$secret" ]] || { err "AccessKey 不能为空"; return 1; }
            export Ali_Key="$key"
            export Ali_Secret="$secret"
            ;;
        *)
            err "暂不支持该 DNS 提供商：${provider}"
            return 1
            ;;
    esac
    return 0
}

# 申请证书：DNS-01（支持泛域名，不需要 80 端口）
cert_issue_dns() {
    acme_ensure || return 1

    local domain provider choice
    read -r -p "请输入域名（泛域名示例 *.example.com）：" domain
    is_cert_domain "$domain" || { err "域名格式不合法：${domain}"; return 1; }

    printf '  1) Cloudflare（dns_cf）\n'
    printf '  2) 阿里云（dns_ali）\n'
    read -r -p "请选择 DNS 提供商 [1-2]（回车默认 1）：" choice
    case "${choice:-1}" in
        1) provider="dns_cf" ;;
        2) provider="dns_ali" ;;
        *) err "无效选项：${choice}"; return 1 ;;
    esac

    cert_configure_dns "$provider" || return 1

    log "开始 DNS-01 验证申请：${domain}（${provider}）"
    if ! "$ACME_BIN" --issue --dns "$provider" -d "$domain" --keylength ec-256; then
        err "申请失败：请确认 API 凭据权限正确，且域名在该账号下"
        return 1
    fi
    log "证书申请成功：${domain}"
}

cert_list() {
    acme_ensure || return 1
    "$ACME_BIN" --list
}

cert_renew() {
    acme_ensure || return 1

    local domain
    read -r -p "请输入要续期的域名：" domain || return 1
    is_cert_domain "$domain" || { err "域名格式不合法：${domain}"; return 1; }
    acme_cert_dir "$domain" >/dev/null || { err "未找到该域名的证书，请先申请"; return 1; }

    if acme_is_ecc "$domain"; then
        "$ACME_BIN" --renew -d "$domain" --ecc --force || { err "续期失败"; return 1; }
    else
        "$ACME_BIN" --renew -d "$domain" --force || { err "续期失败"; return 1; }
    fi
    log "续期完成：${domain}"

    cert_install_to_xray "$domain" || true
}

# 将证书安装到 Xray 目录，供 VLESS + WS + TLS 使用
cert_install_to_xray() {
    local domain="${1:-}" group reload

    acme_ensure || return 1

    if [[ -z "$domain" ]]; then
        read -r -p "请输入证书域名：" domain
    fi
    is_cert_domain "$domain" || { err "域名格式不合法：${domain}"; return 1; }
    acme_cert_dir "$domain" >/dev/null || { err "未找到该域名的证书，请先申请"; return 1; }

    if getent group nogroup >/dev/null 2>&1; then
        group="nogroup"
    else
        group="$(id -gn nobody 2>/dev/null || echo root)"
    fi

    install -d -m 750 -o root -g "$group" "$CERT_DIR" || { err "无法创建证书目录：${CERT_DIR}"; return 1; }

    reload="chown root:${group} ${CERT_DIR}/privkey.pem ${CERT_DIR}/fullchain.pem 2>/dev/null; chmod 640 ${CERT_DIR}/privkey.pem; chmod 644 ${CERT_DIR}/fullchain.pem; systemctl restart xray 2>/dev/null || true"

    if acme_is_ecc "$domain"; then
        "$ACME_BIN" --install-cert -d "$domain" --ecc \
            --key-file "${CERT_DIR}/privkey.pem" \
            --fullchain-file "${CERT_DIR}/fullchain.pem" \
            --reloadcmd "$reload" || { err "证书安装失败"; return 1; }
    else
        "$ACME_BIN" --install-cert -d "$domain" \
            --key-file "${CERT_DIR}/privkey.pem" \
            --fullchain-file "${CERT_DIR}/fullchain.pem" \
            --reloadcmd "$reload" || { err "证书安装失败"; return 1; }
    fi

    [[ -s "${CERT_DIR}/privkey.pem" ]] || { err "私钥文件不存在"; return 1; }
    [[ -s "${CERT_DIR}/fullchain.pem" ]] || { err "证书文件不存在"; return 1; }

    chown root:"$group" "$CERT_DIR" "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" 2>/dev/null \
        || warn "证书属组调整失败"
    chmod 750 "$CERT_DIR"
    chmod 640 "${CERT_DIR}/privkey.pem"
    chmod 644 "${CERT_DIR}/fullchain.pem"

    log "证书已安装到：${CERT_DIR}"
    log "如当前为 WS+TLS 模式，安装子脚本时选择「使用已安装证书」即可复用"
}

cert_remove() {
    acme_ensure || return 1

    local domain ans
    "$ACME_BIN" --list || true
    read -r -p "请输入要删除的证书域名（输入 0 取消）：" domain
    [[ -z "$domain" || "$domain" == "0" ]] && { warn "已取消"; return 1; }

    read -r -p "确认删除 ${domain} 的证书？[y/N]：" ans
    case "$ans" in
        [Yy]*) ;;
        *) warn "已取消"; return 1 ;;
    esac

    if acme_is_ecc "$domain"; then
        "$ACME_BIN" --remove -d "$domain" --ecc >/dev/null 2>&1 || warn "acme.sh 删除记录失败"
    else
        "$ACME_BIN" --remove -d "$domain" >/dev/null 2>&1 || warn "acme.sh 删除记录失败"
    fi
    rm -rf "${ACME_HOME:?}/${domain}" "${ACME_HOME:?}/${domain}_ecc"
    log "已删除证书：${domain}"
}

# 卸载 acme.sh（含续期任务）
uninstall_acme() {
    if [[ ! -x "$ACME_BIN" ]]; then
        log "未安装 acme.sh，无需卸载"
        return 0
    fi

    local ans
    warn "即将卸载 acme.sh 及其续期任务，已签发证书到期后将无法自动续期"
    read -r -p "确认卸载 acme.sh？该操作不可恢复 [yes/N]：" ans
    if [[ "$ans" != "yes" ]]; then
        warn "已取消"
        return 1
    fi

    "$ACME_BIN" --uninstall >/dev/null 2>&1 || warn "acme.sh --uninstall 执行异常，将继续清理残留"

    if [[ -d "$ACME_HOME" ]]; then
        rm -rf "${ACME_HOME:?}" || warn "删除 ${ACME_HOME} 失败，请手动清理"
    fi

    # 安全清理可能残留的 cron 续期任务
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
    fi

    if [[ ! -d "$ACME_HOME" ]]; then
        log "acme.sh 已卸载（续期任务已移除）"
        log "已安装到 ${CERT_DIR} 的证书不受影响，如需删除请手动清理"
    else
        warn "acme.sh 目录仍存在：${ACME_HOME}，请手动删除"
    fi
}

cert_menu() {
    local choice
    while true; do
        printf '\n%s-------- SSL 证书管理 (acme.sh) --------%s\n' "$C_CYAN" "$C_RESET"
        printf '  1) 安装 / 检查 acme.sh\n'
        printf '  2) 申请证书（HTTP-01，需 80 端口）\n'
        printf '  3) 申请证书（DNS-01，Cloudflare / 阿里云）\n'
        printf '  4) 查看已申请证书\n'
        printf '  5) 手动续期\n'
        printf '  6) 安装 / 更新证书到 Xray 目录\n'
        printf '  7) 删除证书\n'
        printf '  8) 卸载 acme.sh（含续期任务）\n'
        printf '  0) 返回主菜单\n'
        if ! read -r -p "请选择 [0-8]：" choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1) acme_ensure || true ;;
            2) cert_issue_http || true ;;
            3) cert_issue_dns || true ;;
            4) cert_list || true ;;
            5) cert_renew || true ;;
            6) cert_install_to_xray || true ;;
            7) cert_remove || true ;;
            8) uninstall_acme || true ;;
            0) return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
    done
}

# ------------------------------ 卸载指定节点 ----------------------------------
# 收集可卸载节点，每行格式：类型|tag|描述
uninstall_node_choices() {
    local t
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        printf 'xray|%s|%s\n' "$t" "$(tag_desc "$t")"
    done < <(xray_node_tags)

    if [[ -f "$ANYTLS_CONFIG" ]]; then
        printf 'anytls|anytls|AnyTLS + TLS\n'
    fi
    if [[ -f "$HS2_CONFIG" ]]; then
        printf 'hysteria2|hysteria2|Hysteria 2\n'
    fi
}

# 删除 CF Tunnel 相关服务（固定与临时一并清理，保留 cloudflared 主程序）
remove_tunnel_service() {
    local ans svc
    local list=("cloudflared" "cloudflared-update" "cgg-quick-tunnel")
    local found=0 removed=0

    for svc in "${list[@]}"; do
        if systemctl cat "$svc" >/dev/null 2>&1 || [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            found=1
        fi
    done
    if (( found == 0 )); then
        warn "未找到隧道服务，跳过清理"
        return 0
    fi

    warn "将停止并删除隧道服务：${list[*]}"
    warn "若本机还有其他项目使用同名服务，请先确认"
    read -r -p "确认删除隧道服务？[y/N]：" ans
    case "$ans" in
        [Yy]*) ;;
        *) warn "已跳过隧道服务清理，请手动处理"; return 0 ;;
    esac

    for svc in "${list[@]}"; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            rm -f "/etc/systemd/system/${svc}.service"
            removed=1
        fi
    done

    if (( removed == 1 )); then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
        log "隧道服务已删除（cloudflared 主程序保留）"
    fi
    return 0
}

# 卸载单个 Xray 节点：只删除对应 inbound 与元信息，其他节点保持不变
remove_xray_node() {
    local tag="$1" tmp backup ans cfg_group remaining

    command -v jq >/dev/null 2>&1 || { err "缺少 jq，无法修改配置"; return 1; }
    [[ -x "$XRAY_BIN" ]] || { err "未找到 Xray 可执行文件：${XRAY_BIN}"; return 1; }
    if ! inbound_exists "$tag"; then
        err "未找到节点配置：$(tag_desc "$tag")"
        return 1
    fi

    read -r -p "确认卸载「$(tag_desc "$tag")」节点？该操作不可恢复 [yes/N]：" ans
    if [[ "$ans" != "yes" ]]; then
        warn "已取消"
        return 1
    fi

    backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -a "$CONFIG_FILE" "$backup"; then
        err "备份配置失败，已中止"
        return 1
    fi

    # Xray 按扩展名判断配置格式，临时文件必须带 .json 后缀
    tmp="$(mktemp "${TMPDIR:-/tmp}/cgg-vless-XXXXXX.json")"
    if ! jq --arg tag "$tag" '.inbounds = [.inbounds[]? | select(.tag != $tag)]' \
        "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "生成新配置失败，已保留原配置（备份：${backup}）"
        return 1
    fi

    if ! "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "新配置校验失败，已保留原配置（备份：${backup}）"
        return 1
    fi

    # 保留原配置的属组，避免 Xray 以 nobody 运行时无法读取
    cfg_group="root"
    cfg_group="$(stat -c '%G' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$cfg_group" ]] || cfg_group="root"
    if ! install -m 640 -o root -g "$cfg_group" "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "写入配置失败，原配置备份：${backup}"
        return 1
    fi
    rm -f "$tmp"
    chmod 640 "$CONFIG_FILE" 2>/dev/null || true

    rm -f "$(node_info_file "$tag")"
    log "已从配置中移除节点：$(tag_desc "$tag")"

    # CF Tunnel 节点需同时清理隧道服务
    if [[ "$tag" == "$TAG_TUNNEL" ]]; then
        remove_tunnel_service
    fi

    remaining="$(xray_node_tags || true)"
    if [[ -z "$remaining" ]]; then
        # 最后一个 Xray 节点：停止并移除服务，保留二进制、日志与配置文件
        systemctl stop xray >/dev/null 2>&1 || true
        systemctl disable xray >/dev/null 2>&1 || true
        if [[ -f "$SERVICE_FILE" ]]; then
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl reset-failed >/dev/null 2>&1 || true
        fi
        log "已无其他 Xray 节点，xray.service 已停止并移除（二进制、日志与配置保留）"
    else
        systemctl daemon-reload >/dev/null 2>&1 || true
        if systemctl restart xray && sleep 1 && systemctl is-active --quiet xray; then
            log "Xray 已重启，剩余节点已生效"
        else
            err "Xray 重启失败，可使用备份配置回滚：${backup}"
            return 1
        fi
    fi

    warn "防火墙放行规则未自动删除，如有需要请手动清理"
}

# 卸载 AnyTLS 节点（sing-box 后端），保留证书目录与 sing-box 主程序
remove_anytls_node() {
    local ans
    if [[ ! -f "$ANYTLS_CONFIG" ]]; then
        err "未找到 AnyTLS 配置"
        return 1
    fi

    read -r -p "确认卸载 AnyTLS 节点？该操作不可恢复 [yes/N]：" ans
    if [[ "$ans" != "yes" ]]; then
        warn "已取消"
        return 1
    fi

    systemctl stop cgg-anytls >/dev/null 2>&1 || true
    systemctl disable cgg-anytls >/dev/null 2>&1 || true
    rm -f "$ANYTLS_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    rm -f "$ANYTLS_CONFIG" "$ANYTLS_INFO"
    log "AnyTLS 节点已卸载（证书目录与 sing-box 主程序保留）"
    warn "防火墙放行规则未自动删除，如有需要请手动清理"
}

# 卸载 Hysteria 2 节点（sing-box 后端），保留证书目录与 sing-box 主程序
remove_hysteria2_node() {
    local ans
    if [[ ! -f "$HS2_CONFIG" ]]; then
        err "未找到 Hysteria 2 配置"
        return 1
    fi

    read -r -p "确认卸载 Hysteria 2 节点？该操作不可恢复 [yes/N]：" ans
    if [[ "$ans" != "yes" ]]; then
        warn "已取消"
        return 1
    fi

    systemctl stop cgg-hysteria2 >/dev/null 2>&1 || true
    systemctl disable cgg-hysteria2 >/dev/null 2>&1 || true
    rm -f "$HS2_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    rm -f "$HS2_CONFIG" "$HS2_INFO"
    log "Hysteria 2 节点已卸载（证书目录与 sing-box 主程序保留）"
    warn "防火墙放行规则未自动删除，如有需要请手动清理"
}

# 选择并卸载指定节点
uninstall_node_menu() {
    local choices=() line kind tag desc choice sel i=1

    while IFS= read -r line; do
        [[ -n "$line" ]] && choices+=("$line")
    done < <(uninstall_node_choices)

    if (( ${#choices[@]} == 0 )); then
        err "未找到可卸载的节点"
        return 1
    fi

    printf '\n%s-------- 卸载指定节点 --------%s\n' "$C_CYAN" "$C_RESET"
    for line in "${choices[@]}"; do
        IFS='|' read -r kind tag desc <<< "$line"
        printf '  %d) %s\n' "$i" "$desc"
        i=$((i + 1))
    done
    printf '  0) 返回主菜单\n'

    if ! read -r -p "请选择要卸载的节点 [0-${#choices[@]}]：" choice; then
        printf '\n'
        return 0
    fi
    if [[ "$choice" == "0" ]]; then
        return 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( 10#$choice < 1 || 10#$choice > ${#choices[@]} )); then
        warn "无效选项：${choice}"
        return 1
    fi

    sel="${choices[$((10#$choice - 1))]}"
    IFS='|' read -r kind tag desc <<< "$sel"
    case "$kind" in
        xray)      remove_xray_node "$tag" || true ;;
        anytls)    remove_anytls_node || true ;;
        hysteria2) remove_hysteria2_node || true ;;
        *)         warn "未知节点类型：${kind}" ;;
    esac
}

# ------------------------------ 彻底卸载 --------------------------------------
uninstall_all() {
    local ans
    warn "即将删除：Xray 核心、配置文件、日志、systemd 服务、Cloudflare Tunnel 服务、AnyTLS 服务、Hysteria 2 服务"
    read -r -p "确认彻底卸载？该操作不可恢复 [yes/N]：" ans
    if [[ "$ans" != "yes" ]]; then
        warn "已取消"
        return 1
    fi

    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -rf /etc/systemd/system/xray.service.d
    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true

    # 清理 Cloudflare Tunnel 服务（固定：cloudflared；临时：cgg-quick-tunnel）
    local tsvc tremoved=""
    for tsvc in cloudflared cgg-quick-tunnel; do
        if systemctl cat "$tsvc" >/dev/null 2>&1; then
            systemctl stop "$tsvc" >/dev/null 2>&1 || true
            systemctl disable "$tsvc" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${tsvc}.service"
            tremoved="1"
        fi
    done
    if [[ -n "$tremoved" ]]; then
        systemctl daemon-reload
        log "已删除 Cloudflare Tunnel 服务"
    fi
    if [[ -x /usr/local/bin/cloudflared ]]; then
        local dans
        read -r -p "是否同时删除 cloudflared 主程序？[y/N]：" dans
        case "$dans" in
            [Yy]*) rm -f /usr/local/bin/cloudflared; log "已删除 cloudflared 主程序" ;;
            *) warn "已保留 cloudflared 主程序" ;;
        esac
    fi

    # 清理 AnyTLS（sing-box 后端）
    if [[ -f "$ANYTLS_SERVICE_FILE" ]] || systemctl cat cgg-anytls >/dev/null 2>&1; then
        systemctl stop cgg-anytls >/dev/null 2>&1 || true
        systemctl disable cgg-anytls >/dev/null 2>&1 || true
        rm -f "$ANYTLS_SERVICE_FILE"
        systemctl daemon-reload
        log "已删除 AnyTLS 服务"
    fi

    # 清理 Hysteria 2（sing-box 后端）
    if [[ -f "$HS2_SERVICE_FILE" ]] || systemctl cat cgg-hysteria2 >/dev/null 2>&1; then
        systemctl stop cgg-hysteria2 >/dev/null 2>&1 || true
        systemctl disable cgg-hysteria2 >/dev/null 2>&1 || true
        rm -f "$HS2_SERVICE_FILE"
        systemctl daemon-reload
        log "已删除 Hysteria 2 服务"
    fi
    if [[ -d "$SINGBOX_DIR" ]]; then
        rm -rf "$SINGBOX_DIR"
        log "已删除 sing-box 配置目录：${SINGBOX_DIR}"
    fi
    if [[ -x "$SINGBOX_BIN" ]]; then
        local sans
        read -r -p "是否同时删除 sing-box 主程序？[y/N]：" sans
        case "$sans" in
            [Yy]*) rm -f "$SINGBOX_BIN"; log "已删除 sing-box 主程序" ;;
            *) warn "已保留 sing-box 主程序" ;;
        esac
    fi

    rm -rf "$CONFIG_DIR" "$LOG_DIR" /usr/local/share/xray
    rm -f "$XRAY_BIN"

    # 清理本菜单下载的子脚本缓存
    if [[ -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        log "已清理子脚本缓存：${CACHE_DIR}"
    fi

    log "卸载完成（防火墙放行规则未自动删除，如有需要请手动清理）"
}

# ------------------------------ TCP 窗口调优 ----------------------------------
readonly NETOPT_CONF="/etc/sysctl.d/99-cgg-vless-tcp.conf"

# 逐条应用 sysctl 配置文件，精确区分成功 / 容器限制 / 内核不支持
# 结果写入全局变量 APPLY_OK / APPLY_FAIL / APPLY_FAIL_PERM
APPLY_OK=0
APPLY_FAIL=0
APPLY_FAIL_PERM=0
apply_sysctl_file() {
    local conf="$1" line key val out
    local ok=0 fail_perm=0 fail_arg=0 fail_other=0
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        local lower got
        if out="$(sysctl -w "${key}=${val}" 2>&1)"; then
            # 回读校验：部分容器会假成功（写入被静默丢弃但返回 0）
            got="$(sysctl -n "$key" 2>/dev/null || true)"
            if [[ "$got" == "$val" ]]; then
                ok=$((ok+1))
            else
                fail_perm=$((fail_perm+1))
                warn "静默拦截：${key} 写入返回成功但值未变（容器宿主限制，重启无效）"
            fi
        else
            lower="${out,,}"
            if [[ "$lower" == *"permission denied"* || "$lower" == *"read-only"* || "$lower" == *"operation not permitted"* ]]; then
                fail_perm=$((fail_perm+1))
                warn "容器限制：${key} 写入被拒（重启无效，需服务商处理）"
            elif [[ "$lower" == *"invalid argument"* || "$lower" == *"no such file"* ]]; then
                fail_arg=$((fail_arg+1))
                warn "内核不支持：${key}，已跳过"
            else
                fail_other=$((fail_other+1))
                warn "应用失败：${key}（${out}）"
            fi
        fi
    done < "$conf"
    APPLY_OK="$ok"
    APPLY_FAIL_PERM="$fail_perm"
    APPLY_FAIL=$((fail_perm + fail_arg + fail_other))
}

enable_tcp_tune() {
    command -v sysctl >/dev/null 2>&1 || { err "未找到 sysctl，无法设置内核参数"; return 1; }

    cat > "$NETOPT_CONF" <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
EOF

    apply_sysctl_file "$NETOPT_CONF"

    printf '\n%s-------- TCP 窗口调优状态 --------%s\n' "$C_CYAN" "$C_RESET"
    printf '  应用结果    : %s 条成功，%s 条失败\n' "$APPLY_OK" "$APPLY_FAIL"
    printf '  接收缓冲上限: %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || printf '未知')"
    printf '  发送缓冲上限: %s\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || printf '未知')"
    printf '  TCP FastOpen: %s\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || printf '未知')"
    printf '%s----------------------------------%s\n' "$C_CYAN" "$C_RESET"

    if (( APPLY_FAIL == 0 )); then
        log "TCP 窗口调优已全部生效"
    elif (( APPLY_FAIL_PERM > 0 )); then
        warn "存在被容器宿主限制的参数，重启也不会生效，请联系服务商放开 /proc/sys 或更换 KVM 机器"
    else
        warn "部分参数当前内核不支持已跳过，其余参数已即时生效"
    fi
}

# ------------------------------ BBR 加速 --------------------------------------
readonly BBR_MODCONF="/etc/modules-load.d/cgg-vless-bbr.conf"
readonly BBR_CONF="/etc/sysctl.d/99-cgg-vless-bbr.conf"

enable_bbr() {
    command -v sysctl >/dev/null 2>&1 || { err "未找到 sysctl，无法设置内核参数"; return 1; }

    # 判断内核是否支持 BBR：内置内核无需 modprobe，先查可用拥塞控制算法列表
    local available
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ " $available " != *" bbr "* ]]; then
        # 列表无 bbr 时再尝试加载模块（模块化内核需要）
        if command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null; then
            available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
        fi
        if [[ " $available " != *" bbr "* ]]; then
            err "当前内核不支持 BBR（LXC / OpenVZ 容器常见，由宿主内核决定）"
            warn "仍可使用菜单 14 的 TCP 窗口调优"
            return 1
        fi
    fi

    # 模块化内核才写开机加载配置；内置内核无 modprobe 也不需要
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
        printf 'tcp_bbr\n' > "$BBR_MODCONF" 2>/dev/null || true
    fi

    cat > "$BBR_CONF" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    apply_sysctl_file "$BBR_CONF"

    printf '\n%s-------- BBR 状态 --------%s\n' "$C_CYAN" "$C_RESET"
    printf '  应用结果    : %s 条成功，%s 条失败\n' "$APPLY_OK" "$APPLY_FAIL"
    printf '  拥塞控制    : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
    printf '  队列规则    : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知')"
    printf '%s--------------------------%s\n' "$C_CYAN" "$C_RESET"

    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [[ "$cc" == "bbr" ]]; then
        log "BBR 已生效"
    elif (( APPLY_FAIL_PERM > 0 )); then
        warn "BBR 被容器宿主限制，重启也不会生效，请联系服务商放开 /proc/sys 或更换 KVM 机器"
    else
        warn "BBR 未立即生效，配置已写入，重启后自动加载"
    fi
}

# ------------------------------ 菜单 ------------------------------------------
show_menu() {
    local mode mode_desc tags t
    tags="$(xray_node_tags)"

    if [[ -n "$tags" ]]; then
        mode_desc=""
        while IFS= read -r t; do
            [[ -n "$t" ]] || continue
            mode_desc="${mode_desc:+${mode_desc} + }${C_GREEN}$(tag_desc "$t")${C_RESET}"
        done <<< "$tags"
    else
        mode="$(detect_mode)"
        case "$mode" in
            none) mode_desc="${C_YELLOW}未安装${C_RESET}" ;;
            *)    mode_desc="${C_YELLOW}未知${C_RESET}" ;;
        esac
    fi
    # AnyTLS 使用独立 sing-box 后端，可与 Xray 任意模式并存
    if [[ -f "$ANYTLS_CONFIG" ]]; then
        mode_desc="${mode_desc}${C_CYAN} + AnyTLS${C_RESET}"
    fi
    # Hysteria 2 同样使用独立 sing-box 后端
    if [[ -f "$HS2_CONFIG" ]]; then
        mode_desc="${mode_desc}${C_CYAN} + Hysteria2${C_RESET}"
    fi

    printf '%s==================== cgg-vless 总菜单 ====================%s\n' "$C_MAGENTA" "$C_RESET"
    printf '  当前节点：%b\n' "$mode_desc"
    printf '  1) 安装 VLESS-Reality 节点\n'
    printf '  2) 安装 VLESS + WS + TLS 节点（CDN）\n'
    printf '  3) 安装 VLESS + WS 隧道节点（CF Tunnel 固定/临时）\n'
    printf '  4) 安装 AnyTLS + TLS 节点（sing-box 后端）\n'
    printf '  5) 安装 Hysteria 2 节点（sing-box 后端）\n'
    printf '  6) 查看当前节点配置与连接链接\n'
    printf '  7) 启动 Xray 服务\n'
    printf '  8) 停止 Xray 服务\n'
    printf '  9) 重启 Xray 服务\n'
    printf '  10) 修改配置（节点名称 / SNI / UUID）\n'
    printf '  11) SSL 证书管理（acme.sh 申请 / 续期 / 安装）\n'
    printf '  12) 卸载指定节点（Reality / WS / Tunnel / AnyTLS / Hysteria2）\n'
    printf '  13) 一键彻底卸载\n'
    printf '  14) TCP 窗口调优（无需内核支持）\n'
    printf '  15) 开启 BBR 加速（需内核支持）\n'
    printf '  0) 退出\n'
    printf '%s==========================================================%s\n' "$C_MAGENTA" "$C_RESET"
}

main_menu() {
    require_root
    show_banner
    check_os
    resolve_script_dir

    local choice
    while true; do
        show_menu
        if ! read -r -p "请选择 [0-15]：" choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1) install_reality || true ;;
            2) install_ws || true ;;
            3) install_tunnel || true ;;
            4) install_anytls || true ;;
            5) install_hysteria2 || true ;;
            6) show_info || true ;;
            7) service_action start || true ;;
            8) service_action stop || true ;;
            9) service_action restart || true ;;
            10) modify_menu || true ;;
            11) cert_menu ;;
            12) uninstall_node_menu || true ;;
            13) uninstall_all || true ;;
            14) enable_tcp_tune || true ;;
            15) enable_bbr || true ;;
            0) log "已退出"; return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
        printf '\n'
    done
}

main_menu "$@"
