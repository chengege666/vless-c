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
readonly CERT_DIR="${CONFIG_DIR}/cert"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly CACHE_DIR="/opt/cgg-vless"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly REPO_RAW="${CGG_RAW_BASE:-https://raw.githubusercontent.com/chengege666/vless-c/main}"

# 子脚本文件名
readonly SCRIPT_REALITY="cgg-vless-reality.sh"
readonly SCRIPT_WS="cgg-vless-ws-tls.sh"

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

# ------------------------------ 模式检测 --------------------------------------
# 输出 reality / ws / unknown / none
detect_mode() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        printf 'none'
        return 0
    fi
    command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }

    local sec net
    sec="$(jq -r '.inbounds[0].streamSettings.security // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    net="$(jq -r '.inbounds[0].streamSettings.network // empty' "$CONFIG_FILE" 2>/dev/null || true)"

    if [[ "$sec" == "reality" ]]; then
        printf 'reality'
    elif [[ "$sec" == "tls" && "$net" == "ws" ]]; then
        printf 'ws'
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
    local cur
    cur="$(detect_mode)"
    if [[ "$cur" == "ws" ]]; then
        warn "当前为 VLESS + WS + TLS 模式，继续安装 Reality 会覆盖现有配置"
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
    local cur
    cur="$(detect_mode)"
    if [[ "$cur" != "none" && "$cur" != "unknown" ]]; then
        warn "当前为 ${cur} 模式，继续安装 WS+TLS 会覆盖现有配置"
        local ans
        read -r -p "确认覆盖？[y/N]：" ans
        case "$ans" in
            [Yy]*) ;;
            *) warn "已取消"; return 1 ;;
        esac
    fi
    run_child "$SCRIPT_WS"
}

# ------------------------------ 查看节点信息 ----------------------------------
load_reality() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    R_PORT="$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE")"
    R_UUID="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE")"
    R_SNI="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE")"
    R_PRIVATE_KEY="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")"
    R_SHORT_ID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$CONFIG_FILE")"

    [[ -n "$R_PORT" && -n "$R_UUID" && -n "$R_SNI" && -n "$R_PRIVATE_KEY" && -n "$R_SHORT_ID" ]] || return 1

    # 优先读取安装时保存的公钥与节点名称
    R_PUBLIC_KEY=""
    R_NODE_NAME=""
    if [[ -f "$INFO_FILE" ]]; then
        R_PUBLIC_KEY="$(read_info_value PUBLIC_KEY || true)"
        R_NODE_NAME="$(read_info_value NODE_NAME || true)"
    fi
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
    local link ip
    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    link="vless://${R_UUID}@${ip}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${R_SNI}&fp=chrome&pbk=${R_PUBLIC_KEY}&sid=${R_SHORT_ID}&type=tcp&headerType=none#cgg-vless"

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
    local port uuid path domain link ip enc_path
    port="$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE")"
    uuid="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE")"
    path="$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$CONFIG_FILE")"

    if [[ -z "$port" || -z "$uuid" || -z "$path" ]]; then
        err "配置读取不完整，无法生成链接"
        return 1
    fi

    # 优先使用安装时记录的域名，避免证书为泛域名时无法作为 SNI
    domain="$(read_info_value DOMAIN || true)"
    if [[ -z "$domain" ]]; then
        domain="$(extract_cert_domain || true)"
    fi
    if [[ -z "$domain" || "$domain" == \*.* ]]; then
        warn "无法确定可用域名，请手动填写 SNI"
        domain="YOUR_DOMAIN"
    fi

    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    enc_path="$(printf '%s' "$path" | sed 's|/|%2F|g')"
    node_name="$(read_info_value NODE_NAME || true)"
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
    printf '%sCDN 场景：客户端地址可改为优选 IP/域名，建议端口 443 或 2053/2083/2087/2096。%s\n\n' \
        "$C_YELLOW" "$C_RESET"

    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"
    print_qr "$link"
}

show_info() {
    if command -v jq >/dev/null 2>&1; then
        :
    else
        err "缺少 jq，请先安装：apt-get install -y jq"
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "未找到配置，请先执行安装"
        return 1
    fi

    SERVER_IP="$(get_public_ip)"

    local mode
    mode="$(detect_mode)"
    case "$mode" in
        reality)
            if ! load_reality; then
                err "Reality 配置读取失败，可能配置不完整"
                return 1
            fi
            show_info_reality
            ;;
        ws)
            show_info_ws
            ;;
        unknown)
            err "无法识别当前配置模式（仅支持 Reality / WS+TLS）"
            return 1
            ;;
        *)
            err "未找到有效配置"
            return 1
            ;;
    esac

    if systemctl is-active --quiet xray 2>/dev/null; then
        log "服务状态：运行中"
    else
        warn "服务状态：未运行"
    fi
    printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$CONFIG_FILE" "$C_RESET"
}

# ------------------------------ 服务控制 --------------------------------------
service_action() {
    local action="$1"
    if [[ ! -f "$SERVICE_FILE" ]]; then
        err "未找到 systemd 服务，请先执行安装"
        return 1
    fi

    systemctl "$action" xray || { err "systemctl ${action} xray 失败"; return 1; }
    sleep 1

    if [[ "$action" == "stop" ]]; then
        log "Xray 已停止"
        return 0
    fi

    if systemctl is-active --quiet xray; then
        log "Xray 已${action}完成，当前状态：运行中"
    else
        err "Xray ${action} 后未处于运行状态，请查看日志"
        return 1
    fi
}

# ------------------------------ 修改 Reality 配置 -----------------------------
save_reality_info() {
    install -d -m 755 -o root -g root "$CONFIG_DIR"
    {
        printf 'PORT=%s\n' "$R_PORT"
        printf 'UUID=%s\n' "$R_UUID"
        printf 'SNI=%s\n' "$R_SNI"
        printf 'PUBLIC_KEY=%s\n' "$R_PUBLIC_KEY"
        printf 'SHORT_ID=%s\n' "$R_SHORT_ID"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
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

    local input tmp
    read -r -p "请输入新的伪装域名（当前 ${R_SNI}）：" input
    input="${input//[[:space:]]/}"
    [[ -n "$input" ]] || { warn "输入为空，已取消"; return 1; }
    if [[ ! "$input" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
        err "域名格式不合法：${input}"
        return 1
    fi

    tmp="$(mktemp)"
    if ! jq --arg sni "$input" '
        .inbounds[0].streamSettings.realitySettings.dest = ($sni + ":443")
        | .inbounds[0].streamSettings.realitySettings.serverNames = [$sni]
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

    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$tmp" "$CONFIG_FILE"
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

    local ans tmp new_uuid
    read -r -p "确认重置 UUID？旧 UUID 将立即失效 [y/N]：" ans
    case "$ans" in
        [Yy]*) ;;
        *) warn "已取消"; return 1 ;;
    esac

    new_uuid="$("$XRAY_BIN" uuid 2>/dev/null || true)"
    [[ -n "$new_uuid" ]] || new_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    [[ -n "$new_uuid" ]] || { err "UUID 生成失败"; return 1; }

    tmp="$(mktemp)"
    if ! jq --arg id "$new_uuid" '.inbounds[0].settings.clients[0].id = $id' \
        "$CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        err "生成新配置失败"
        return 1
    fi

    if ! "$XRAY_BIN" run -test -config "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        err "新配置校验失败，已保留原配置"
        return 1
    fi

    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$tmp" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"

    R_UUID="$new_uuid"
    save_reality_info
    log "UUID 已重置：${R_UUID}"
    restart_after_change
}

# 修改节点名称（Reality / WS 均可用）
change_node_name() {
    local mode current input
    mode="$(detect_mode)"

    case "$mode" in
        reality)
            if ! load_reality; then
                err "Reality 配置读取失败，请先执行安装"
                return 1
            fi
            current="$R_NODE_NAME"
            ;;
        ws)
            current="$(read_info_value NODE_NAME || true)"
            [[ -n "$current" ]] || current="cgg-vless-ws"
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

    update_info_node_name "$input"
    log "节点名称已更新为：${input}"

    # 名称仅影响分享链接备注，无需重启服务
    SERVER_IP="$(get_public_ip)"
    if [[ "$mode" == "reality" ]]; then
        if load_reality; then
            show_info_reality
        fi
    else
        show_info_ws
    fi
}

modify_menu() {
    local mode choice
    mode="$(detect_mode)"

    if [[ "$mode" != "reality" && "$mode" != "ws" ]]; then
        err "未找到有效配置，请先执行安装"
        return 1
    fi

    while true; do
        printf '\n%s-------- 修改配置（当前模式：%s）--------%s\n' "$C_CYAN" "$mode" "$C_RESET"
        printf '  1) 修改节点名称\n'
        if [[ "$mode" == "reality" ]]; then
            printf '  2) 更换伪装域名 SNI\n'
            printf '  3) 重置 UUID\n'
        fi
        printf '  0) 返回主菜单\n'
        if ! read -r -p "请选择：" choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1) change_node_name || true ;;
            2)
                if [[ "$mode" == "reality" ]]; then
                    change_sni || true
                else
                    warn "WS+TLS 模式不支持修改 SNI"
                fi
                ;;
            3)
                if [[ "$mode" == "reality" ]]; then
                    reset_uuid || true
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
        printf '  0) 返回主菜单\n'
        if ! read -r -p "请选择 [0-7]：" choice; then
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
            0) return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
    done
}

# ------------------------------ 彻底卸载 --------------------------------------
uninstall_all() {
    local ans
    warn "即将删除：Xray 核心、配置文件、日志、systemd 服务"
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

    rm -rf "$CONFIG_DIR" "$LOG_DIR" /usr/local/share/xray
    rm -f "$XRAY_BIN"

    # 清理本菜单下载的子脚本缓存
    if [[ -d "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        log "已清理子脚本缓存：${CACHE_DIR}"
    fi

    log "卸载完成（防火墙放行规则未自动删除，如有需要请手动清理）"
}

# ------------------------------ 菜单 ------------------------------------------
show_menu() {
    local mode mode_desc
    mode="$(detect_mode)"
    case "$mode" in
        reality) mode_desc="${C_GREEN}VLESS + Reality${C_RESET}" ;;
        ws)      mode_desc="${C_GREEN}VLESS + WS + TLS${C_RESET}" ;;
        none)    mode_desc="${C_YELLOW}未安装${C_RESET}" ;;
        *)       mode_desc="${C_YELLOW}未知${C_RESET}" ;;
    esac

    printf '%s==================== cgg-vless 总菜单 ====================%s\n' "$C_MAGENTA" "$C_RESET"
    printf '  当前模式：%b\n' "$mode_desc"
    printf '  1) 安装 VLESS-Reality 节点\n'
    printf '  2) 安装 VLESS + WS + TLS 节点（CDN）\n'
    printf '  3) 查看当前节点配置与连接链接\n'
    printf '  4) 启动 Xray 服务\n'
    printf '  5) 停止 Xray 服务\n'
    printf '  6) 重启 Xray 服务\n'
    printf '  7) 修改配置（节点名称 / SNI / UUID）\n'
    printf '  8) 一键彻底卸载\n'
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
        if ! read -r -p "请选择 [0-9]：" choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1) install_reality || true ;;
            2) install_ws || true ;;
            3) show_info || true ;;
            4) service_action start || true ;;
            5) service_action stop || true ;;
            6) service_action restart || true ;;
            7) modify_menu || true ;;
            8) cert_menu ;;
            9) uninstall_all || true ;;
            0) log "已退出"; return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
        printf '\n'
    done
}

main_menu "$@"
