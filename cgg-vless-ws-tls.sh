#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · VLESS + WebSocket + TLS（Cloudflare CDN 救援方案）
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-ws-tls.sh
# 前    提：域名已解析到本机，且 80 端口可从公网访问（用于 acme.sh 验证）
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="${CONFIG_DIR}/cgg-vless.info"
# 每个节点独立保存元信息，支持多个协议节点并存
readonly NODES_DIR="${CONFIG_DIR}/nodes"
readonly NODE_TAG="vless-ws-tls"
readonly NODE_INFO="${NODES_DIR}/${NODE_TAG}.info"
readonly CERT_DIR="${CONFIG_DIR}/cert"
# AnyTLS 使用独立配置，端口冲突检测需要读取
readonly ANYTLS_CONFIG="/usr/local/etc/sing-box/config.json"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
# Cloudflare 支持的 HTTPS 端口（回源提示用）
readonly CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"
readonly DEFAULT_NODE_NAME="cgg-vless-ws"

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
DOMAIN=""
EMAIL=""
UUID=""
WS_PATH=""
NODE_NAME="${DEFAULT_NODE_NAME}"
CERT_SOURCE="auto"
LISTEN_PORT="443"
SERVER_IP=""
RUN_USER="nobody"
RUN_GROUP="nogroup"

# ------------------------------ 日志函数 --------------------------------------
log()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "脚本执行失败（行号：$LINENO，退出码：$?），请根据上方日志排查"' ERR

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
    printf '%s            cgg-vless · VLESS + WebSocket + TLS%s\n\n' "$C_MAGENTA" "$C_RESET"
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

detect_runtime_user() {
    id -u nobody >/dev/null 2>&1 || die "系统缺少 nobody 用户，无法配置 systemd 服务"
    if getent group nogroup >/dev/null 2>&1; then
        RUN_GROUP="nogroup"
    else
        RUN_GROUP="$(id -gn nobody)"
    fi
}

# ------------------------------ 依赖安装 --------------------------------------
install_deps() {
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，请确认系统为 Ubuntu / Debian"

    local missing=()
    local cmd
    for cmd in curl openssl jq socat cron; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    command -v ss >/dev/null 2>&1 || missing+=("iproute2")

    if (( ${#missing[@]} > 0 )); then
        log "安装必要依赖：${missing[*]}"
        apt-get update -y || die "apt-get update 失败，请检查网络或软件源"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" \
            || die "依赖安装失败：${missing[*]}"
    else
        log "必要依赖已存在"
    fi

    # 确保 cron 服务可用，acme.sh 依赖其自动续期
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || warn "cron 服务启动失败，证书自动续期可能受影响"

    # qrencode 仅用于二维码输出，安装失败不阻断流程
    if ! command -v qrencode >/dev/null 2>&1; then
        log "安装二维码工具 qrencode"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1; then
            warn "qrencode 安装失败，稍后将只输出 vless:// 链接"
        fi
    fi
}

check_network() {
    if ! curl -fsS --max-time 10 -o /dev/null https://github.com; then
        die "无法访问 GitHub，请检查网络、DNS 或代理设置"
    fi
}

# ------------------------------ 交互输入 --------------------------------------
validate_domain() {
    local d="$1"
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_domain() {
    local input
    if [[ ! -t 0 ]]; then
        die "当前为非交互环境，需要提供域名参数：DOMAIN=your.domain bash $0"
    fi

    while true; do
        read -r -p "请输入已解析到本机的域名： " input
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
    log "使用域名：${DOMAIN}"
}

ask_email() {
    local input
    if [[ -n "${ACME_EMAIL:-}" ]]; then
        EMAIL="$ACME_EMAIL"
        log "使用环境变量邮箱：${EMAIL}"
        return 0
    fi
    if [[ -t 0 ]]; then
        read -r -p "Let's Encrypt 通知邮箱（可回车跳过）： " input
        EMAIL="${input//[[:space:]]/}"
    fi
}

ask_node_name() {
    local input
    NODE_NAME="$DEFAULT_NODE_NAME"
    if [[ -t 0 ]]; then
        read -r -p "节点名称（显示在客户端备注，回车默认 ${DEFAULT_NODE_NAME}）：" input
        # 去掉分隔符与空白，避免破坏 vless:// 链接格式
        input="${input//[#?&%/]/}"
        input="${input// /_}"
        if [[ -n "$input" ]]; then
            NODE_NAME="$input"
        fi
    fi
    log "节点名称：${NODE_NAME}"
}

# 选择证书来源：自动申请 / 已有证书文件 / 已安装证书
ask_cert_source() {
    CERT_SOURCE="auto"
    [[ -t 0 ]] || return 0

    printf '\n选择证书来源：\n'
    printf '  1) 自动申请 Let'"'"'s Encrypt（HTTP-01，需 80 端口）\n'
    printf '  2) 使用本机已有证书文件（手动输入路径）\n'
    printf '  3) 使用已安装到 %s 的证书\n' "$CERT_DIR"

    local choice
    read -r -p "请选择 [1-3]（回车默认 1）：" choice || return 0
    case "${choice:-1}" in
        1) CERT_SOURCE="auto" ;;
        2) CERT_SOURCE="file" ;;
        3) CERT_SOURCE="existing" ;;
        *) warn "无效选项，使用自动申请"; CERT_SOURCE="auto" ;;
    esac
    log "证书来源：${CERT_SOURCE}"
}

# 检查端口是否已被其他 Xray 节点或 AnyTLS 配置占用（服务停止时 ss 无法发现）
# 输出冲突来源描述，无冲突时返回 1
port_config_conflict() {
    local port="$1" tag="$2" p at
    command -v jq >/dev/null 2>&1 || return 1

    if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            if [[ "$p" == "$port" ]]; then
                printf '其他 Xray 节点'
                return 0
            fi
        done < <(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag != $tag) | .port // empty' "$CONFIG_FILE" 2>/dev/null || true)
    fi

    if [[ -f "$ANYTLS_CONFIG" ]] && jq empty "$ANYTLS_CONFIG" >/dev/null 2>&1; then
        at="$(jq -r '.inbounds[]? | select(.type == "anytls") | .listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null | head -n 1 || true)"
        if [[ -n "$at" && "$at" == "$port" ]]; then
            printf 'AnyTLS 节点'
            return 0
        fi
    fi
    return 1
}

# 端口是否正在被监听
port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

# 判断端口是否为当前节点已配置且正在运行的端口（重装时可复用）
own_running_port() {
    local port="$1" own
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$CONFIG_FILE" ]] || return 1
    own="$(jq -r --arg tag "$NODE_TAG" '[.inbounds[]? | select(.tag == $tag)][0].port // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$own" && "$own" == "$port" ]] || return 1
    systemctl is-active --quiet xray 2>/dev/null
}

# ------------------------------ 监听端口 --------------------------------------
# 默认 443；NAT VPS 可选择服务商分配端口范围内的自定义端口
ask_listen_port() {
    [[ -t 0 ]] || { log "非交互模式：使用默认监听端口 ${LISTEN_PORT}"; return 0; }

    local choice input conflict
    printf '\n选择监听端口模式：\n'
    printf '  1) 默认 443（普通 VPS 推荐）\n'
    printf '  2) 自定义端口（NAT VPS 受限端口范围）\n'
    read -r -p "请选择 [1-2]（回车默认 1）：" choice || return 0
    case "${choice:-1}" in
        1)
            if port_in_use "$LISTEN_PORT"; then
                if own_running_port "$LISTEN_PORT"; then
                    warn "端口 ${LISTEN_PORT} 为当前节点正在使用的端口，将继续复用"
                else
                    die "端口 ${LISTEN_PORT} 已被占用，请改用自定义端口"
                fi
            fi
            if conflict="$(port_config_conflict "$LISTEN_PORT" "$NODE_TAG")"; then
                die "端口 ${LISTEN_PORT} 已被${conflict}占用，请改用自定义端口"
            fi
            log "监听端口：${LISTEN_PORT}"
            ;;
        2)
            read -r -p "请输入监听端口（1-65535）：" input || return 0
            input="${input//[[:space:]]/}"
            if [[ -z "$input" ]]; then
                if port_in_use "$LISTEN_PORT"; then
                    if own_running_port "$LISTEN_PORT"; then
                        warn "端口 ${LISTEN_PORT} 为当前节点正在使用的端口，将继续复用"
                    else
                        die "端口 ${LISTEN_PORT} 已被占用，请改用自定义端口"
                    fi
                fi
                if conflict="$(port_config_conflict "$LISTEN_PORT" "$NODE_TAG")"; then
                    die "端口 ${LISTEN_PORT} 已被${conflict}占用，请改用自定义端口"
                fi
                warn "输入为空，使用默认端口 443"
                return 0
            fi
            if [[ ! "$input" =~ ^[0-9]+$ ]] || (( 10#$input < 1 || 10#$input > 65535 )); then
                die "端口不合法：${input}"
            fi
            if port_in_use "$input"; then
                if own_running_port "$input"; then
                    warn "端口 ${input} 为当前节点正在使用的端口，将继续复用"
                else
                    die "端口 ${input} 已被占用，请更换"
                fi
            fi
            if conflict="$(port_config_conflict "$input" "$NODE_TAG")"; then
                die "端口 ${input} 已被${conflict}占用，请更换"
            fi
            LISTEN_PORT="$input"
            log "监听端口：${LISTEN_PORT}"
            printf '%s-------- NAT VPS 端口回源提示 --------%s\n' "$C_YELLOW" "$C_RESET"
            printf '  1) 端口必须在服务商分配的端口范围内，且已在服务商处完成端口映射\n'
            printf '  2) Cloudflare 支持的 HTTPS 端口：%s\n' "$CF_HTTPS_PORTS"
            if [[ " $CF_HTTPS_PORTS " == *" ${LISTEN_PORT} "* ]]; then
                printf '  3) 监听端口 %s 在 Cloudflare 支持列表内，客户端端口填 %s 即可回源\n' "$LISTEN_PORT" "$LISTEN_PORT"
            else
                printf '  3) 监听端口 %s 不在 Cloudflare 支持列表，需在 Cloudflare Origin Rules\n' "$LISTEN_PORT"
                printf '     将回源端口设为 %s，客户端端口填 443\n' "$LISTEN_PORT"
            fi
            printf '  4) 80 端口不可用申请证书时，改用 DNS-01 验证（总菜单 11 → 3）\n'
            printf '%s----------------------------------------%s\n' "$C_YELLOW" "$C_RESET"
            ;;
        *)
            warn "无效选项，使用默认 443"
            ;;
    esac
}

# ------------------------------ 端口占用 --------------------------------------
free_port_80() {
    local holders=""
    if command -v ss >/dev/null 2>&1; then
        holders="$(ss -H -ltnp 'sport = :80' 2>/dev/null || true)"
    fi

    if [[ -z "$holders" ]]; then
        log "80 端口空闲，可进行 Standalone 验证"
        return 0
    fi

    warn "检测到 80 端口被占用："
    printf '%s\n' "$holders" >&2

    [[ -t 0 ]] || die "80 端口被占用，无法使用 Standalone 模式申请证书"

    local ans svc
    read -r -p "是否临时停止占用 80 端口的 Web 服务？[y/N]：" ans
    case "$ans" in
        [Yy]*)
            for svc in nginx apache2 httpd caddy; do
                if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
                    && systemctl is-active --quiet "$svc"; then
                    systemctl stop "$svc" || warn "停止 ${svc} 失败"
                    warn "已临时停止 ${svc}，证书申请完成后请手动启动"
                fi
            done
            sleep 1
            holders="$(ss -H -ltnp 'sport = :80' 2>/dev/null || true)"
            if [[ -n "$holders" ]]; then
                die "80 端口仍被占用，请手动处理后重试"
            fi
            ;;
        *)
            die "已取消：Standalone 模式需要独占 80 端口"
            ;;
    esac
}

# 验证 Xray 二进制可执行且能正常运行
verify_xray_runtime() {
    [[ -x "$XRAY_BIN" ]] || return 1
    "$XRAY_BIN" version >/dev/null 2>&1
}

# ------------------------------ 安装 Xray -------------------------------------
ensure_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        log "检测到已安装 Xray：$("$XRAY_BIN" version 2>/dev/null | head -n 1)"
        return 0
    fi

    log "开始安装官方 Xray-core..."
    local installer rc=0
    installer="$(mktemp)"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$installer" "$INSTALL_URL"; then
        rm -f "$installer"
        die "Xray 官方安装脚本下载失败，请检查网络"
    fi
    bash "$installer" install || rc=$?
    rm -f "$installer"
    (( rc == 0 )) || die "Xray 安装失败（退出码 ${rc}）"
    [[ -x "$XRAY_BIN" ]] || die "安装完成后未找到 ${XRAY_BIN}"
    verify_xray_runtime || die "Xray 安装完成但无法运行，请按上方提示排查"
}

# ------------------------------ 证书申请 --------------------------------------
install_acme() {
    if [[ -x "$ACME_BIN" ]]; then
        log "acme.sh 已安装：$("$ACME_BIN" --version 2>/dev/null | head -n 1)"
        return 0
    fi

    log "安装 acme.sh..."
    local email_arg=""
    [[ -n "$EMAIL" ]] && email_arg="email=${EMAIL}"

    if ! curl -fsSL --retry 3 --connect-timeout 15 https://get.acme.sh | sh -s ${email_arg}; then
        die "acme.sh 安装失败，请检查网络"
    fi
    [[ -x "$ACME_BIN" ]] || die "acme.sh 安装后未找到 ${ACME_BIN}"
    log "acme.sh 安装完成"
}

issue_cert() {
    log "使用 Standalone 模式申请 Let's Encrypt 证书：${DOMAIN}"
    "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 \
        || warn "设置默认 CA 失败，将使用 acme.sh 当前默认 CA"

    local log_file rc=0
    log_file="$(mktemp)"
    "$ACME_BIN" --issue --standalone -d "$DOMAIN" --keylength ec-256 --httpport 80 2>&1 \
        | tee "$log_file" || rc=${PIPESTATUS[0]}

    if (( rc != 0 )); then
        # 按 acme.sh 输出给出针对性提示，避免笼统报错
        if grep -q 'NXDOMAIN' "$log_file" 2>/dev/null; then
            err "DNS 查询失败（NXDOMAIN）：域名未解析或记录尚未生效"
        elif grep -qE 'Connection refused|Timeout|timed out' "$log_file" 2>/dev/null; then
            err "80 端口公网不可达：请检查安全组、NAT 端口映射与防火墙"
            err "如无法开放 80 端口，请改用 DNS-01 验证（总菜单 11 → 3）"
        elif grep -q 'Invalid response' "$log_file" 2>/dev/null; then
            err "80 端口被其他服务占用或响应异常"
        fi
        rm -f "$log_file"
        die "证书申请失败，建议改用 DNS-01 验证或使用已有证书"
    fi

    rm -f "$log_file"
    log "证书申请成功"
}

install_cert() {
    install -d -m 700 -o root -g root "$CERT_DIR"

    if ! "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --key-file "${CERT_DIR}/privkey.pem" \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --reloadcmd "chown root:${RUN_GROUP} ${CERT_DIR}/privkey.pem ${CERT_DIR}/fullchain.pem 2>/dev/null; chmod 640 ${CERT_DIR}/privkey.pem; chmod 644 ${CERT_DIR}/fullchain.pem; systemctl restart xray 2>/dev/null || true"; then
        die "证书安装到 ${CERT_DIR} 失败"
    fi

    [[ -s "${CERT_DIR}/privkey.pem" ]] || die "私钥文件不存在：${CERT_DIR}/privkey.pem"
    [[ -s "${CERT_DIR}/fullchain.pem" ]] || die "证书文件不存在：${CERT_DIR}/fullchain.pem"

    # Xray 以 nobody 运行，需要授予证书目录与文件的组读取权限
    chown root:"$RUN_GROUP" "$CERT_DIR" "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" 2>/dev/null \
        || warn "证书属组调整失败，可能导致 Xray 无法读取证书"
    chmod 750 "$CERT_DIR"
    chmod 640 "${CERT_DIR}/privkey.pem"
    chmod 644 "${CERT_DIR}/fullchain.pem"
    log "证书已安装：${CERT_DIR}"
}

# 校验证书与私钥是否匹配（支持 RSA 与 EC）
cert_is_valid() {
    local cert="$1" key="$2"
    [[ -s "$cert" && -s "$key" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 0

    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1

    local cert_md5 key_md5
    cert_md5="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null || true)"
    key_md5="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null || true)"
    [[ -n "$cert_md5" && "$cert_md5" == "$key_md5" ]] || return 1
    return 0
}

# 统一修正证书目录权限，保证 nobody 可读
fix_cert_perms() {
    chown root:"$RUN_GROUP" "$CERT_DIR" "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem" 2>/dev/null \
        || warn "证书属组调整失败，可能导致 Xray 无法读取证书"
    chmod 750 "$CERT_DIR"
    chmod 640 "${CERT_DIR}/privkey.pem"
    chmod 644 "${CERT_DIR}/fullchain.pem"
}

# 使用用户指定的证书文件
use_cert_files() {
    local cert key
    [[ -t 0 ]] || die "使用自有证书时需要在交互终端输入路径"

    printf '%s提示：acme.sh 申请的证书默认在 /root/.acme.sh/<域名>_ecc/ 目录，%s\n' "$C_CYAN" "$C_RESET"
    printf '%s内含 <域名>.cer、fullchain.cer、<域名>.key 等文件，扩展名不影响导入。%s\n' "$C_CYAN" "$C_RESET"
    read -r -p "证书文件路径（.cer，如 /root/.acme.sh/xxx.xyz_ecc/fullchain.cer）：" cert || return 1
    read -r -p "私钥文件路径（.key，如 /root/.acme.sh/xxx.xyz_ecc/xxx.xyz.key）：" key || return 1
    cert="${cert/#\~/$HOME}"
    key="${key/#\~/$HOME}"

    [[ -n "$cert" && -n "$key" ]] || die "证书路径不能为空"
    [[ -f "$cert" ]] || die "证书文件不存在：${cert}"
    [[ -f "$key" ]] || die "私钥文件不存在：${key}"
    cert_is_valid "$cert" "$key" || die "证书与私钥不匹配，或文件格式无效"

    install -d -m 750 -o root -g "$RUN_GROUP" "$CERT_DIR" || die "无法创建证书目录：${CERT_DIR}"

    # 避免源文件与目标文件相同导致内容被清空
    if [[ ! "$cert" -ef "${CERT_DIR}/fullchain.pem" ]]; then
        cat "$cert" > "${CERT_DIR}/fullchain.pem" || die "复制证书失败"
    fi
    if [[ ! "$key" -ef "${CERT_DIR}/privkey.pem" ]]; then
        cat "$key" > "${CERT_DIR}/privkey.pem" || die "复制私钥失败"
    fi

    fix_cert_perms
    log "已导入自有证书：${CERT_DIR}"
}

# 使用已安装到 CERT_DIR 的证书
use_installed_cert() {
    local cert="${CERT_DIR}/fullchain.pem" key="${CERT_DIR}/privkey.pem"
    [[ -s "$cert" && -s "$key" ]] \
        || die "未找到已安装证书，请先在总菜单 11 中申请并安装到 ${CERT_DIR}"
    cert_is_valid "$cert" "$key" || die "已安装的证书与私钥不匹配，请重新安装证书"
    fix_cert_perms
    log "使用已安装证书：${CERT_DIR}"
}

# 按来源准备证书
prepare_cert() {
    case "$CERT_SOURCE" in
        auto)
            install_acme
            issue_cert
            install_cert
            ;;
        file)
            install_deps_quiet_openssl
            use_cert_files
            ;;
        existing)
            use_installed_cert
            ;;
        *)
            die "未知的证书来源：${CERT_SOURCE}"
            ;;
    esac
}

# 确保 openssl 可用（导入自有证书时需要）
install_deps_quiet_openssl() {
    command -v openssl >/dev/null 2>&1 && return 0
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssl \
        || die "openssl 安装失败，无法校验证书"
}

# ------------------------------ 参数生成 --------------------------------------
gen_uuid() {
    UUID="$("$XRAY_BIN" uuid 2>/dev/null || true)"
    if [[ -z "$UUID" ]]; then
        UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    fi
    [[ -n "$UUID" ]] || die "UUID 生成失败"
    log "UUID 生成完成"
}

gen_ws_path() {
    local rand
    rand="$(openssl rand -hex 6)"
    WS_PATH="/cgg-${rand}"
    [[ ${#WS_PATH} -ge 8 ]] || die "WS 路径生成失败"
    log "WebSocket 路径生成完成：${WS_PATH}"
}

# ------------------------------ 配置合并 --------------------------------------
# 把本模式生成的完整配置合并进现有 config.json：
# 同 tag 的 inbound 替换，其他 inbound 原样保留，避免覆盖已安装的其他节点
merge_config() {
    local new_cfg="$1"
    local tmp_cfg test_log
    # Xray 按扩展名判断配置格式，临时文件必须带 .json 后缀
    tmp_cfg="$(mktemp "${TMPDIR:-/tmp}/cgg-vless-XXXXXX.json")"

    if [[ -f "$CONFIG_FILE" ]]; then
        if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
            die "现有配置不是合法 JSON：${CONFIG_FILE}（同目录 .bak 为备份），请修复后重试"
        fi
        if ! jq --slurpfile new "$new_cfg" --arg tag "$NODE_TAG" '
            .inbounds = (((.inbounds // []) | map(select(.tag != $tag))) + [$new[0].inbounds[0]])
            | .outbounds = (.outbounds // $new[0].outbounds)
            | .log = (.log // $new[0].log)
        ' "$CONFIG_FILE" > "$tmp_cfg"; then
            rm -f "$tmp_cfg"
            die "合并 Xray 配置失败：${CONFIG_FILE}"
        fi
    else
        if ! cp -a "$new_cfg" "$tmp_cfg"; then
            rm -f "$tmp_cfg"
            die "生成 Xray 配置失败：${CONFIG_FILE}"
        fi
    fi

    test_log="$(mktemp)"
    if ! "$XRAY_BIN" run -test -config "$tmp_cfg" >"$test_log" 2>&1; then
        err "配置校验输出："
        cat "$test_log" >&2 || true
        rm -f "$test_log" "$tmp_cfg"
        die "Xray 配置校验失败，未启动服务"
    fi
    rm -f "$test_log"

    if ! install -m 640 "$tmp_cfg" "$CONFIG_FILE"; then
        rm -f "$tmp_cfg"
        die "写入配置失败：${CONFIG_FILE}"
    fi
    rm -f "$tmp_cfg"
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"
}

# ------------------------------ 配置写入 --------------------------------------
write_config() {
    install -d -m 755 -o root -g root "$CONFIG_DIR"

    # 日志目录必须由运行用户可写，否则启动时报 access.log permission denied
    install -d -m 755 "$LOG_DIR"
    touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log" || die "无法创建日志文件：${LOG_DIR}"
    chown -R "${RUN_USER}:${RUN_GROUP}" "$LOG_DIR" || die "日志目录授权失败：${LOG_DIR}"
    chmod 755 "$LOG_DIR"
    chmod 644 "${LOG_DIR}/access.log" "${LOG_DIR}/error.log"

    if [[ -f "$CONFIG_FILE" ]]; then
        local backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$backup"
        log "旧配置已备份：${backup}"
    fi

    # 先写入临时文件，再由 merge_config 合并进 config.json，保留其他节点
    local new_cfg
    new_cfg="$(mktemp)"

    cat > "$new_cfg" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-ws-tls",
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/privkey.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

    merge_config "$new_cfg"
    rm -f "$new_cfg"
    save_info
    log "配置写入并校验通过：${CONFIG_FILE}"
}

# 保存节点元信息，供管理菜单读取（名称、路径等）
save_info() {
    install -d -m 755 -o root -g root "$NODES_DIR"
    {
        printf 'MODE=ws\n'
        printf 'PORT=%s\n' "$LISTEN_PORT"
        printf 'UUID=%s\n' "$UUID"
        printf 'DOMAIN=%s\n' "$DOMAIN"
        printf 'WS_PATH=%s\n' "$WS_PATH"
        printf 'NODE_NAME=%s\n' "$NODE_NAME"
    } > "$NODE_INFO"
    chmod 600 "$NODE_INFO"

    # 兼容旧版管理菜单：继续写共享元信息文件
    cp -f "$NODE_INFO" "$INFO_FILE" 2>/dev/null || true
    chmod 600 "$INFO_FILE" 2>/dev/null || true
}

# ------------------------------ systemd 服务 ----------------------------------
write_service() {
    if [[ -f "$SERVICE_FILE" ]] && ! grep -q "cgg-vless" "$SERVICE_FILE"; then
        local backup="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$SERVICE_FILE" "$backup"
        log "旧服务文件已备份：${backup}"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless Xray Service (VLESS WS TLS)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    log "systemd 服务文件已写入：${SERVICE_FILE}"
}

start_service() {
    log "启用并启动 Xray 服务..."
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || warn "设置开机自启失败"
    systemctl restart xray || true
    sleep 1

    if ! systemctl is-active --quiet xray; then
        err "Xray 启动失败，最近日志如下："
        journalctl -u xray -n 20 --no-pager >&2 || true
        die "请根据日志排查后重试"
    fi
    log "Xray 已启动，并已设置开机自启"
}

# ------------------------------ 防火墙 ----------------------------------------
configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || warn "UFW 放行 ${LISTEN_PORT}/tcp 失败"
        ufw allow 80/tcp >/dev/null 2>&1 || warn "UFW 放行 80/tcp 失败"
        log "UFW 已放行 ${LISTEN_PORT}/tcp 与 80/tcp"
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        local p
        for p in "$LISTEN_PORT" 80; do
            if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT \
                    || warn "iptables 放行 ${p}/tcp 失败，请手动放行"
            fi
        done
        log "iptables 已放行 ${LISTEN_PORT}/tcp 与 80/tcp（如使用 firewalld 请另行放行）"
        return 0
    fi

    warn "未检测到 UFW / iptables，请手动放行 ${LISTEN_PORT}/tcp 与 80/tcp"
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
        if [[ -n "$ip" ]]; then
            warn "公网 IP 获取失败，使用本机 IP：${ip}（如在 NAT 后请手动替换）"
        fi
    fi
    printf '%s' "$ip"
}

# ------------------------------ 结果输出 --------------------------------------
print_result() {
    local link ip
    ip="${SERVER_IP:-YOUR_SERVER_IP}"

    if command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
        if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
            warn "配置文件 JSON 校验异常，请检查 ${CONFIG_FILE}"
        fi
    fi

    # CDN 场景下地址应填 CDN 优选域名/IP，此处默认输出源站 IP
    link="vless://${UUID}@${ip}:${LISTEN_PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')#${NODE_NAME}"

    printf '\n%s=============== cgg-vless WS+TLS 节点信息 ===============%s\n' "$C_CYAN" "$C_RESET"
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$LISTEN_PORT"
    printf '  域名        : %s\n' "$DOMAIN"
    printf '  UUID        : %s\n' "$UUID"
    printf '  传输协议    : ws\n'
    printf '  WS 路径     : %s\n' "$WS_PATH"
    printf '  安全类型    : tls\n'
    printf '  SNI         : %s\n' "$DOMAIN"
    printf '  证书路径    : %s\n' "$CERT_DIR"
    printf '%s========================================================%s\n\n' "$C_CYAN" "$C_RESET"
    printf '%sCloudflare CDN：请将域名代理（橙色云）开启，SSL/TLS 模式选择 Full (strict)，%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s客户端地址可改为优选 IP/域名，端口填 443 或 2053/2083/2087/2096。%s\n' "$C_YELLOW" "$C_RESET"

    # NAT 自定义端口时的回源提示
    if [[ "$LISTEN_PORT" != "443" ]]; then
        if [[ " $CF_HTTPS_PORTS " == *" ${LISTEN_PORT} "* ]]; then
            printf '%sNAT 回源：服务端监听 %s 为 Cloudflare 支持端口，客户端端口填 %s 即可回源。%s\n' \
                "$C_YELLOW" "$LISTEN_PORT" "$LISTEN_PORT" "$C_RESET"
        else
            printf '%sNAT 回源：服务端监听 %s，需在 Cloudflare Origin Rules 将回源端口设为 %s，%s\n' \
                "$C_YELLOW" "$LISTEN_PORT" "$LISTEN_PORT" "$C_RESET"
            printf '%s客户端端口填 443（或 2053/2083/2087/2096/8443）。%s\n' "$C_YELLOW" "$C_RESET"
        fi
    fi
    printf '\n'

    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    if command -v qrencode >/dev/null 2>&1; then
        printf '%s节点二维码：%s\n' "$C_GREEN" "$C_RESET"
        if ! qrencode -t ANSIUTF8 "$link" 2>/dev/null; then
            qrencode -t ANSI "$link" 2>/dev/null || warn "二维码生成失败，请直接使用上方链接"
        fi
        printf '\n'
    else
        warn "未安装 qrencode，跳过二维码输出"
    fi

    printf '%s证书续期：acme.sh 已自动添加 cron 任务，可执行 "%s --cron" 手动检查%s\n' \
        "$C_CYAN" "$ACME_BIN" "$C_RESET"
    printf '%s服务管理：systemctl {status|restart|stop} xray%s\n\n' "$C_CYAN" "$C_RESET"
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    show_banner
    check_os
    detect_runtime_user

    install_deps
    check_network

    ask_domain
    ask_email
    ask_node_name
    ask_cert_source
    ask_listen_port

    # 仅自动申请时才需要占用 80 端口
    if [[ "$CERT_SOURCE" == "auto" ]]; then
        free_port_80
    fi
    ensure_xray
    # 先准备好证书，再写配置，避免配置校验时证书文件不存在
    prepare_cert

    gen_uuid
    gen_ws_path
    write_config
    write_service
    start_service
    configure_firewall

    SERVER_IP="$(get_public_ip)"
    print_result
}

main "$@"

