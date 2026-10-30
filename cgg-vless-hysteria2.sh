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
readonly SERVICE_NAME="cgg-hysteria2"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly XRAY_CERT_DIR="/usr/local/etc/xray/cert"
readonly DEFAULT_NODE_NAME="cgg-hysteria2"
# 自签场景默认伪装 SNI
readonly DEFAULT_DOMAIN="cloud.tencent.com"
# GitHub 加速镜像（前缀式代理）；置空则完全直连 GitHub
readonly GH_MIRROR="https://cgjs.1231818.xyz/"

# ------------------------------ 运行期变量 ------------------------------------
PORT=""
DOMAIN=""
PASSWORD=""
NODE_NAME=""
CERT_FILE=""
KEY_FILE=""
SERVER_IP=""
HOP_PORTS=""
CERT_MODE=""

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

require_tty() {
    if [[ ! -t 0 ]]; then
        die "本脚本需要交互输入，请在终端中直接运行"
    fi
}

# ------------------------------ 公网 IP ---------------------------------------
is_public_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]}))
    d=$((10#${BASH_REMATCH[4]}))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    if (( a == 0 || a == 10 || a == 127 || a >= 224 )) \
        || (( a == 169 && b == 254 )) \
        || (( a == 172 && b >= 16 && b <= 31 )) \
        || (( a == 192 && b == 168 )) \
        || (( a == 100 && b >= 64 && b <= 127 )); then
        return 1
    fi
    return 0
}

get_public_ip() {
    local ip=""
    ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS4 --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [[ -n "$ip" ]] && ! is_public_ipv4 "$ip"; then
        warn "获取到的地址 ${ip} 不是公网 IPv4，分享链接将显示占位符，请手动替换为实际公网 IP"
        ip=""
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

mirror_url() {
    local url="$1"
    if [[ -n "$GH_MIRROR" ]]; then
        printf '%s%s' "${GH_MIRROR%/}/" "$url"
    else
        printf '%s' "$url"
    fi
}

# ------------------------------ 端口管理 --------------------------------------
port_in_use_udp() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
}

# 随机生成一个 20000 - 50000 之间未被占用的端口
get_random_port() {
    local p
    while true; do
        p=$((RANDOM % 30001 + 20000))
        if ! port_in_use_udp "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
}

# ------------------------------ 内核 UDP 优化 ---------------------------------
optimize_udp_buffer() {
    log "配置 Linux 内核 UDP 缓冲区大小（防止 QUIC 握手丢包）..."
    sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1 || true
    
    local sysctl_conf="/etc/sysctl.d/99-hysteria2.conf"
    if [[ ! -f "$sysctl_conf" ]]; then
        cat > "$sysctl_conf" <<EOF
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
EOF
    fi
}

# ------------------------------ 安装 sing-box ---------------------------------
install_singbox() {
    if [[ -x "$SINGBOX_BIN" ]]; then
        local cur_line cur_major=0 cur_minor=0
        cur_line="$("$SINGBOX_BIN" version 2>/dev/null | head -n 1 || true)"
        log "检测到已安装 sing-box：${cur_line}"
        if [[ "$cur_line" =~ ([0-9]+)\.([0-9]+)\.[0-9]+ ]]; then
            cur_major=$((10#${BASH_REMATCH[1]}))
            cur_minor=$((10#${BASH_REMATCH[2]}))
            if (( cur_major < 1 || (cur_major == 1 && cur_minor < 8) )); then
                die "已安装的 sing-box 版本过低，hysteria2 入站需要 1.8+；请升级或删除 ${SINGBOX_BIN} 后重跑"
            fi
        fi
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装：apt-get install -y curl"
    command -v tar >/dev/null 2>&1 || die "缺少 tar，请先安装：apt-get install -y tar"

    local arch tag ver url tmpdir extracted api_json=""
    if ! arch="$(detect_arch)"; then
        die "当前架构不支持自动安装（仅支持 x86_64 / aarch64）"
    fi

    log "获取 sing-box 最新版本..."
    if [[ -n "$GH_MIRROR" ]]; then
        log "使用加速镜像：${GH_MIRROR}"
        api_json="$(curl -fsSL --max-time 30 --retry 2 --retry-delay 2 --connect-timeout 15 \
            "$(mirror_url "https://api.github.com/repos/SagerNet/sing-box/releases/latest")" 2>/dev/null || true)"
    fi
    if [[ -z "$api_json" ]]; then
        api_json="$(curl -fsSL --max-time 30 --retry 2 --retry-delay 2 --connect-timeout 15 \
            "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null || true)"
    fi
    tag="$(printf '%s' "$api_json" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    if [[ -z "$tag" ]]; then
        die "获取 sing-box 版本失败（GitHub API 不可达），可手动下载放到 ${SINGBOX_BIN}"
    fi

    ver="${tag#v}"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmpdir="$(mktemp -d)"

    if [[ -n "$GH_MIRROR" ]]; then
        log "下载 sing-box（加速镜像）：$(mirror_url "$url")"
        if ! curl -fL --max-time 300 --retry 2 --retry-delay 2 --connect-timeout 15 \
            --progress-bar -o "${tmpdir}/pkg.tar.gz" "$(mirror_url "$url")"; then
            warn "加速镜像下载失败，回退直连 GitHub"
            rm -f "${tmpdir}/pkg.tar.gz"
        fi
    fi

    if [[ ! -s "${tmpdir}/pkg.tar.gz" ]]; then
        log "下载 sing-box：${url}"
        if ! curl -fsSL --max-time 300 --retry 2 --retry-delay 2 --connect-timeout 15 \
            -o "${tmpdir}/pkg.tar.gz" "$url"; then
            rm -rf "$tmpdir"
            die "sing-box 下载失败"
        fi
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
        read -r -p "证书域名 / SNI（自签回车默认 ${DEFAULT_DOMAIN}；使用真实 CA 证书请填真实域名）：" input
        input="${input//[[:space:]]/}"
        if [[ -z "$input" ]]; then
            input="$DEFAULT_DOMAIN"
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
    local input default_p
    command -v ss >/dev/null 2>&1 || warn "未检测到 ss，将跳过 UDP 端口占用检测"
    
    # 动态获取一个 20000-50000 的随机安全端口作为默认值
    default_p="$(get_random_port)"
    
    read -r -p "UDP 监听端口（1-65535，回车默认随机高位端口 ${default_p}；可空格分隔多个端口实现端口跳跃）：" input

    local -a ports=()
    read -r -a ports <<< "$input"

    if (( ${#ports[@]} == 0 )); then
        PORT="${default_p}"
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
            p=$((10#$p))
            case " $seen " in
                *" $p "*) die "端口重复：${p}" ;;
            esac
            seen="${seen} ${p}"
            if port_in_use_udp "$p"; then
                if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                    warn "检测到 ${SERVICE_NAME} 正在运行且占用 UDP 端口，先停止服务后继续"
                    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
                    sleep 1
                fi
                if port_in_use_udp "$p"; then
                    die "UDP 端口 ${p} 已被占用，请为 Hysteria 2 选择其他端口"
                fi
            fi
            norm+=("$p")
        done
        PORT="${norm[0]}"
        HOP_PORTS="${norm[*]:1}"
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
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    if [[ -n "$input" ]]; then
        NODE_NAME="$input"
    fi
    log "节点名称：${NODE_NAME}"
}

# ------------------------------ 证书处理 --------------------------------------
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
    chmod 600 "${CERT_DIR}/privkey.pem"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    CERT_MODE="manual"
    log "证书已复制到：${CERT_DIR}"
}

setup_cert_selfsigned() {
    command -v openssl >/dev/null 2>&1 || die "缺少 openssl，无法生成自签证书，请先安装：apt-get install -y openssl"

    install -d -m 755 -o root -g root "$CERT_DIR"
    log "生成自签证书（含 SAN 扩展，CN=${DOMAIN}，有效期 3650 天）..."
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "${CERT_DIR}/privkey.pem" \
        -out "${CERT_DIR}/fullchain.pem" \
        -days 3650 \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1; then
        die "自签证书生成失败"
    fi
    chmod 644 "${CERT_DIR}/fullchain.pem"
    chmod 600 "${CERT_DIR}/privkey.pem"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    CERT_MODE="selfsigned"
    log "自签证书已生成：${CERT_DIR}"
}

ask_cert_source() {
    local ans
    if [[ -s "${XRAY_CERT_DIR}/fullchain.pem" && -s "${XRAY_CERT_DIR}/privkey.pem" ]]; then
        log "检测到 Xray 证书目录已有证书"
        printf '  1) 复用 /usr/local/etc/xray/cert 下的证书（默认）\n'
        printf '  2) 手动输入证书文件路径（.cer / .key）\n'
        printf '  3) 生成自签证书（客户端需跳过证书验证）\n'
        read -r -p "请选择 [1-3，回车默认 1]：" ans
        case "$ans" in
            2)
                setup_cert_manual
                ;;
            3)
                setup_cert_selfsigned
                ;;
            *)
                install -d -m 755 -o root -g root "$CERT_DIR"
                cp -f "${XRAY_CERT_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem" || die "复制 Xray 证书失败"
                cp -f "${XRAY_CERT_DIR}/privkey.pem" "${CERT_DIR}/privkey.pem" || die "复制 Xray 私钥失败"
                chmod 644 "${CERT_DIR}/fullchain.pem"
                chmod 600 "${CERT_DIR}/privkey.pem"
                CERT_FILE="${CERT_DIR}/fullchain.pem"
                KEY_FILE="${CERT_DIR}/privkey.pem"
                CERT_MODE="reuse"
                log "已复制 Xray 证书到 ${CERT_DIR}"
                ;;
        esac
        return 0
    fi

    warn "未检测到 ${XRAY_CERT_DIR} 下的证书"
    printf '  1) 手动输入证书文件路径（.cer / .key）\n'
    printf '  2) 生成自签证书（客户端需跳过证书验证）\n'
    printf '  3) 取消，先去申请证书\n'
    read -r -p "请选择 [1-3，回车默认 2]：" ans
    ans="${ans:-2}"
    case "$ans" in
        1) setup_cert_manual ;;
        2) setup_cert_selfsigned ;;
        *) die "已取消安装" ;;
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
# 优化重点：
# 1. 监听 0.0.0.0 避免 IPv6 栈解析异常
# 2. 移除入站多余的 server_name 和 alpn
# 3. direct 出站增加 domain_strategy: prefer_ipv4，彻底杜绝 IPv6 路由死锁打不开网页
write_config() {
    install -d -m 755 -o root -g root "$SINGBOX_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        local backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$backup" || warn "旧配置备份失败：${backup}"
        log "旧配置已备份：${backup}"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
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
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "prefer_ipv4"
    }
  ]
}
EOF

    chmod 600 "$CONFIG_FILE"

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE"; then
        die "sing-box 配置校验失败，未启动服务"
    fi
    log "配置写入并校验通过：${CONFIG_FILE}"
}

# ------------------------------ 端口跳跃 --------------------------------------
setup_port_hopping() {
    local p

    if command -v iptables >/dev/null 2>&1 && [[ -f "$INFO_FILE" ]]; then
        local old_port="" old_hops="" cur_ports=" $PORT $HOP_PORTS "
        old_port="$(sed -n 's/^PORT=//p' "$INFO_FILE" 2>/dev/null | head -n 1 || true)"
        old_hops="$(sed -n 's/^HOP_PORTS=//p' "$INFO_FILE" 2>/dev/null | head -n 1 || true)"
        if [[ "$old_port" =~ ^[0-9]+$ ]]; then
            for p in $old_hops; do
                while iptables -t nat -C PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$old_port" 2>/dev/null; do
                    iptables -t nat -D PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$old_port" 2>/dev/null || break
                done
            done
            for p in $old_port $old_hops; do
                case "$cur_ports" in
                    *" $p "*) continue ;;
                esac
                while iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do
                    iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || break
                done
            done
            log "已清理上次安装的旧端口规则（旧端口：${old_port}${old_hops:+ ${old_hops}}）"
        fi
    fi

    [[ -n "$HOP_PORTS" ]] || return 0

    if ! command -v iptables >/dev/null 2>&1; then
        warn "未检测到 iptables，端口跳跃规则无法配置"
        return 0
    fi

    for p in $HOP_PORTS; do
        if ! iptables -t nat -C PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$PORT" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p udp --dport "$p" -j REDIRECT --to-ports "$PORT" \
                || warn "端口跳跃规则添加失败：${p} -> ${PORT}"
        fi
    done
    log "端口跳跃规则已配置：${HOP_PORTS// /, } -> ${PORT}"

    persist_iptables
}

persist_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            log "iptables 规则已持久化（netfilter-persistent）"
        else
            warn "netfilter-persistent 保存失败"
        fi
    elif [[ -f /etc/iptables/rules.v4 ]] && command -v iptables-save >/dev/null 2>&1; then
        if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            log "iptables 规则已持久化（/etc/iptables/rules.v4）"
        else
            warn "iptables-save 写入 /etc/iptables/rules.v4 失败"
        fi
    fi
}

# ------------------------------ systemd 服务 ----------------------------------
write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless Hysteria 2 Service (sing-box)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${SINGBOX_DIR}
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

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
        log "UDP 端口 ${PORT} 已成功监听"
    else
        warn "未检测到 UDP 端口 ${PORT} 监听，请执行 journalctl -u ${SERVICE_NAME} -n 50 排查"
    fi

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
        log "服务状态：运行中"
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
                    || warn "iptables 放行端口失败"
            fi
        done
        log "iptables 已放行端口 ${all_ports// /, }/udp"
        persist_iptables
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
        printf 'CERT_MODE=%s\n' "$CERT_MODE"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# ------------------------------ 输出结果 --------------------------------------
print_result() {
    local ip link extra=""
    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    
    if [[ -n "$HOP_PORTS" ]]; then
        extra="&mport=${PORT},${HOP_PORTS// /,}"
    fi
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        extra="${extra}&insecure=1"
    fi
    
    link="hysteria2://${PASSWORD}@${ip}:${PORT}/?sni=${DOMAIN}${extra}#${NODE_NAME}"

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
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    printf '%sHysteria 2 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    if command -v qrencode >/dev/null 2>&1; then
        printf '%s节点二维码：%s\n' "$C_GREEN" "$C_RESET"
        if ! qrencode -t ANSIUTF8 "$link" 2>/dev/null; then
            qrencode -t ANSI "$link" 2>/dev/null || warn "二维码生成失败，请直接使用上方链接"
        fi
        printf '\n'
    fi

    printf '%s使用提示：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - Hysteria 2 基于 UDP 协议，客户端请使用：v2rayN / sing-box / Clash.Meta(Mihomo) / Shadowrocket\n'
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        printf '  - 自签证书模式：客户端节点配置中必须开启「允许不安全证书 / 跳过证书验证(allowInsecure / skip-cert-verify)」\n'
    fi
    printf '  - 测试注意：切勿在客户端使用 TCP Ping 测速（UDP 端口不响应 TCP），请右键使用「真连接测试 (HttpPing)」或直接开启代理打开网页测试\n'
    if [[ -n "$HOP_PORTS" ]]; then
        printf '  - 若云厂商有外部安全组，请确保放行对应 UDP 端口（%s, %s）\n' "$PORT" "${HOP_PORTS// /, }"
    else
        printf '  - 若云厂商有外部安全组，请确保放行 UDP 端口：%s\n' "$PORT"
    fi
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    check_os
    require_tty
    check_network

    printf '\n%s========== cgg-vless · Hysteria 2（sing-box）==========%s\n\n' "$C_MAGENTA" "$C_RESET"

    ask_domain
    ask_port
    ask_node_name
    ask_cert_source
    gen_password

    optimize_udp_buffer
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