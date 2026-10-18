#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · VLESS + XTLS-Reality 一键安装脚本
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-reality.sh
# 说    明：仅安装 VLESS + Reality，不包含 VMess / Trojan 等协议
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly DEFAULT_SNI="itunes.apple.com"

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
PORT=""
SNI=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SERVER_IP=""
RUN_USER="nobody"
RUN_GROUP="nogroup"

# ------------------------------ 日志函数 --------------------------------------
log()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 任意命令异常退出时打印行号，避免静默失败
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
    printf '%s                     cgg-vless · VLESS Reality%s\n\n' "$C_MAGENTA" "$C_RESET"
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
    for cmd in curl openssl jq; do
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

    # qrencode 仅用于二维码输出，安装失败不阻断流程
    if ! command -v qrencode >/dev/null 2>&1; then
        log "安装二维码工具 qrencode"
        apt-get update -y >/dev/null 2>&1 || true
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

# ------------------------------ 端口处理 --------------------------------------
port_in_use() {
    local p="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"
}

random_port() {
    local i p
    for i in $(seq 1 30); do
        p="$(shuf -i 10000-65000 -n 1 2>/dev/null || true)"
        if [[ -z "$p" ]]; then
            p=$(( (RANDOM % 55001) + 10000 ))
        fi
        if ! port_in_use "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    die "未找到可用端口，请手动指定"
}

ask_port() {
    local default_port input
    default_port="$(random_port)"

    if [[ ! -t 0 ]]; then
        PORT="$default_port"
        log "非交互模式：使用随机端口 ${PORT}"
        return 0
    fi

    read -r -p "监听端口（1-65535，回车使用随机端口 ${default_port}）：" input
    input="${input//[[:space:]]/}"

    if [[ -z "$input" ]]; then
        PORT="$default_port"
    elif [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
        if port_in_use "$input"; then
            die "端口 ${input} 已被占用，请更换"
        fi
        PORT="$input"
    else
        die "端口不合法：${input}"
    fi
    log "监听端口：${PORT}"
}

# ------------------------------ 域名处理 --------------------------------------
validate_domain() {
    local d="$1"
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_sni() {
    local input
    SNI="$DEFAULT_SNI"
    if [[ -t 0 ]]; then
        read -r -p "伪装域名 SNI（回车默认 ${DEFAULT_SNI}）：" input
        input="${input//[[:space:]]/}"
        if [[ -n "$input" ]]; then
            validate_domain "$input" || die "域名格式不合法：${input}"
            SNI="$input"
        fi
    fi
    log "伪装域名 SNI：${SNI}"
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
    log "Xray 安装完成：$("$XRAY_BIN" version 2>/dev/null | head -n 1)"
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

gen_keys() {
    local out=""
    if ! out="$("$XRAY_BIN" x25519 2>&1)"; then
        die "xray x25519 执行失败：${out}"
    fi

    # 旧版本输出：Private key / Public key
    # 新版本输出：PrivateKey / Password(公钥) / Hash32
    PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F: 'tolower($1) ~ /private/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F: 'tolower($1) ~ /public/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F: 'tolower($1) ~ /password/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    fi

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        die "无法解析 xray x25519 输出，请确认 Xray 版本"
    fi
    log "Reality 密钥对生成完成"
}

gen_short_id() {
    SHORT_ID="$(openssl rand -hex 8)"
    [[ ${#SHORT_ID} -eq 16 ]] || die "ShortID 生成失败"
    log "ShortID 生成完成：${SHORT_ID}"
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

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
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

    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"

    local test_log
    test_log="$(mktemp)"
    if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE" >"$test_log" 2>&1; then
        err "配置校验输出："
        cat "$test_log" >&2 || true
        rm -f "$test_log"
        die "Xray 配置校验失败，未启动服务"
    fi
    rm -f "$test_log"
    log "配置写入并校验通过：${CONFIG_FILE}"
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
Description=cgg-vless Xray Service
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
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 || warn "UFW 放行 ${PORT}/tcp 失败"
        log "UFW 已放行端口 ${PORT}/tcp"
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT \
                || warn "iptables 放行端口失败，请手动放行 ${PORT}/tcp"
        fi
        log "iptables 已放行端口 ${PORT}/tcp（如使用 firewalld 请另行放行）"
        return 0
    fi

    warn "未检测到 UFW / iptables，请手动放行 ${PORT}/tcp"
}

# ------------------------------ BBR -------------------------------------------
maybe_enable_bbr() {
    local cc ans
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

    if [[ "$cc" == "bbr" ]]; then
        log "BBR 已启用（拥塞控制算法：bbr）"
        return 0
    fi

    warn "当前拥塞控制算法：${cc}（未启用 BBR）"
    if [[ ! -t 0 ]]; then
        warn "非交互模式，跳过 BBR 设置"
        return 0
    fi

    read -r -p "是否开启 BBR 加速？[y/N]：" ans
    case "$ans" in
        [Yy]*)
            modprobe tcp_bbr >/dev/null 2>&1 || warn "无法加载 tcp_bbr 模块，可能内核不支持"
            cat > /etc/sysctl.d/99-cgg-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
            sysctl --system >/dev/null 2>&1 || true
            cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
            if [[ "$cc" == "bbr" ]]; then
                log "BBR 已开启"
            else
                warn "BBR 未生效，请检查内核是否支持"
            fi
            ;;
        *)
            log "已跳过 BBR 设置"
            ;;
    esac
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
    local link
    local ip="${SERVER_IP:-YOUR_SERVER_IP}"

    if command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
        if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
            warn "配置文件 JSON 校验异常，请检查 ${CONFIG_FILE}"
        fi
    fi

    link="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#cgg-vless"

    printf '\n%s================= cgg-vless 节点信息 =================%s\n' "$C_CYAN" "$C_RESET"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$PORT"
    printf '  UUID        : %s\n' "$UUID"
    printf '  流控 flow   : xtls-rprx-vision\n'
    printf '  公钥 pbk    : %s\n' "$PUBLIC_KEY"
    printf '  私钥 pvk    : %s\n' "$PRIVATE_KEY"
    printf '  ShortID     : %s\n' "$SHORT_ID"
    printf '  伪装域名SNI : %s\n' "$SNI"
    printf '  传输协议    : tcp\n'
    printf '  安全类型    : reality\n'
    printf '%s======================================================%s\n\n' "$C_CYAN" "$C_RESET"
    printf '%s提示：私钥仅保存在服务端，请勿泄露。%s\n\n' "$C_YELLOW" "$C_RESET"

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

    printf '%s服务管理：systemctl {status|restart|stop} xray%s\n' "$C_CYAN" "$C_RESET"
    printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$CONFIG_FILE" "$C_RESET"
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    show_banner
    check_os
    detect_runtime_user

    ask_port
    ask_sni

    install_deps
    check_network
    ensure_xray

    gen_uuid
    gen_keys
    gen_short_id

    write_config
    write_service
    start_service
    configure_firewall
    maybe_enable_bbr

    SERVER_IP="$(get_public_ip)"
    print_result
}

main "$@"
