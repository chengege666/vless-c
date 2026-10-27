#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · VLESS + WebSocket + Cloudflare Tunnel
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-tunnel.sh
# 说    明：Xray 仅在 127.0.0.1 监听 WS 明文（security: none），
#           TLS 由 Cloudflare 边缘承担；无需域名证书，无需放行入站端口。
#   固定隧道：网页创建隧道取 Token → cloudflared service install，域名固定
#   临时隧道：quick tunnel（trycloudflare.com），域名随机且每次重启都会变化
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="${CONFIG_DIR}/cgg-vless.info"
# 每个节点独立保存元信息，支持多个协议节点并存
readonly NODES_DIR="${CONFIG_DIR}/nodes"
readonly NODE_TAG="vless-ws-tunnel"
readonly NODE_INFO="${NODES_DIR}/${NODE_TAG}.info"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly CFDD_BIN="/usr/local/bin/cloudflared"
readonly CFDD_URL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
readonly QUICK_SERVICE="cgg-quick-tunnel"
readonly DEFAULT_LOCAL_PORT="8001"
readonly DEFAULT_NODE_NAME="cgg-vless-tunnel"

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
TUNNEL_TYPE="fixed"
LOCAL_PORT="${DEFAULT_LOCAL_PORT}"
UUID=""
WS_PATH=""
NODE_NAME="${DEFAULT_NODE_NAME}"
TUNNEL_DOMAIN=""
CF_TOKEN="${CF_TUNNEL_TOKEN:-}"
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
    printf '%s         cgg-vless · VLESS + WS + Cloudflare Tunnel%s\n\n' "$C_MAGENTA" "$C_RESET"
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

ask_tunnel_type() {
    # 环境变量 CF_TUNNEL_TOKEN 存在时自动使用固定隧道，便于无人值守安装
    if [[ -n "$CF_TOKEN" ]]; then
        TUNNEL_TYPE="fixed"
        log "检测到环境变量 CF_TUNNEL_TOKEN，使用固定隧道模式"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "当前为非交互环境，请提供隧道 Token：CF_TUNNEL_TOKEN=xxx bash $0"
    fi

    printf '\n选择隧道类型：\n'
    printf '  1) 固定隧道（域名固定，需域名 NS 托管在 Cloudflare）\n'
    printf '  2) 临时隧道（无需账号域名，域名随机且每次重启都会变化，仅测试用）\n'
    local choice
    read -r -p "请选择 [1-2]（回车默认 1）：" choice
    case "${choice:-1}" in
        1) TUNNEL_TYPE="fixed" ;;
        2) TUNNEL_TYPE="quick" ;;
        *) warn "无效选项，使用固定隧道"; TUNNEL_TYPE="fixed" ;;
    esac
    log "隧道类型：${TUNNEL_TYPE}"
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

ask_local_port() {
    [[ -t 0 ]] || { log "非交互模式：使用默认本地端口 ${LOCAL_PORT}"; return 0; }

    local input
    read -r -p "Xray 本地监听端口（仅 127.0.0.1 回源用，回车默认 ${DEFAULT_LOCAL_PORT}）：" input || return 0
    input="${input//[[:space:]]/}"
    if [[ -z "$input" ]]; then
        log "本地端口：${LOCAL_PORT}"
        return 0
    fi
    if [[ ! "$input" =~ ^[0-9]+$ ]] || (( 10#$input < 1 || 10#$input > 65535 )); then
        die "端口不合法：${input}"
    fi
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${input}" 2>/dev/null | grep -q .; then
        die "端口 ${input} 已被占用，请更换"
    fi
    LOCAL_PORT="$input"
    log "本地端口：${LOCAL_PORT}"
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
}

# ------------------------------ 安装 cloudflared ------------------------------
ensure_cloudflared() {
    if [[ -x "$CFDD_BIN" ]]; then
        log "检测到已安装 cloudflared：$("$CFDD_BIN" --version 2>/dev/null | head -n 1)"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) die "暂不支持的架构：$(uname -m)，请手动安装 cloudflared 到 ${CFDD_BIN}" ;;
    esac

    log "下载 cloudflared（${arch}）..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$CFDD_BIN" "${CFDD_URL_BASE}/cloudflared-linux-${arch}"; then
        rm -f "$CFDD_BIN"
        die "cloudflared 下载失败；网络受限时可手动下载后放置到 ${CFDD_BIN} 并 chmod +x，再重跑本脚本"
    fi
    chmod +x "$CFDD_BIN"
    [[ -x "$CFDD_BIN" ]] || die "cloudflared 安装异常"
    log "cloudflared 安装完成：$("$CFDD_BIN" --version 2>/dev/null | head -n 1)"
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
    tmp_cfg="$(mktemp)"

    if [[ -f "$CONFIG_FILE" ]] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
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
      "tag": "vless-ws-tunnel",
      "listen": "127.0.0.1",
      "port": ${LOCAL_PORT},
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
        "security": "none",
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

# 保存节点元信息，供管理菜单读取（隧道类型、域名等）
save_info() {
    install -d -m 755 -o root -g root "$NODES_DIR"
    {
        printf 'MODE=tunnel\n'
        printf 'TUNNEL_TYPE=%s\n' "$TUNNEL_TYPE"
        printf 'LOCAL_PORT=%s\n' "$LOCAL_PORT"
        printf 'UUID=%s\n' "$UUID"
        printf 'WS_PATH=%s\n' "$WS_PATH"
        printf 'TUNNEL_DOMAIN=%s\n' "$TUNNEL_DOMAIN"
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
Description=cgg-vless Xray Service (VLESS WS Tunnel)
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

# ------------------------------ 固定隧道 --------------------------------------
setup_fixed_tunnel() {
    printf '\n%s-------- 固定隧道配置提示 --------%s\n' "$C_CYAN" "$C_RESET"
    printf '  1) 登录 Cloudflare 控制台 → Zero Trust → Networks → Tunnels\n'
    printf '  2) Create a tunnel → 类型选 Cloudflared → 填写隧道名\n'
    printf '  3) 复制网页给出的 Token（安装命令 eyJ 开头的一长串）\n'
    printf '%s----------------------------------%s\n' "$C_CYAN" "$C_RESET"

    if [[ -z "$CF_TOKEN" ]]; then
        [[ -t 0 ]] || die "固定隧道需要 Token：CF_TUNNEL_TOKEN=xxx bash $0"
        read -r -s -p "粘贴隧道 Token（输入内容不回显，回车确认）：" CF_TOKEN
        printf '\n'
    fi
    [[ -n "$CF_TOKEN" ]] || die "Token 不能为空"

    # 重装场景：先清理旧服务与残留文件（含 cloudflared-update.service）再注册，
    # 否则 service install 会报 "already installed" 而失败
    if systemctl cat cloudflared >/dev/null 2>&1 || [[ -f /etc/systemd/system/cloudflared-update.service ]]; then
        warn "检测到旧 cloudflared 服务残留，将先停止并清理（若本机还有其他项目在用 cloudflared 隧道，请先确认）"
        if [[ -x "$CFDD_BIN" ]]; then
            "$CFDD_BIN" service uninstall >/dev/null 2>&1 || true
        fi
        systemctl stop cloudflared cloudflared-update >/dev/null 2>&1 || true
        systemctl disable cloudflared cloudflared-update >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/cloudflared.service /etc/systemd/system/cloudflared-update.service
        systemctl daemon-reload
        log "旧服务清理完成"
    fi

    log "注册 cloudflared 服务..."
    if ! "$CFDD_BIN" service install "$CF_TOKEN"; then
        die "cloudflared 服务注册失败，请确认 Token 正确后重试"
    fi

    sleep 2
    if systemctl is-active --quiet cloudflared; then
        log "cloudflared 服务运行中，连接器状态可在网页查看"
    else
        warn "cloudflared 服务未运行，请稍后执行：systemctl status cloudflared"
    fi

    printf '\n%s请在网页端完成 Public Hostname 配置（本机侧已就绪）：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  Public Hostname → Add a public hostname\n'
    printf '    Subdomain / Domain : 你的域名\n'
    printf '    Type               : HTTP\n'
    printf '    URL                : http://localhost:%s\n' "$LOCAL_PORT"
    printf '%s保存后 DNS 记录自动创建并强制代理。%s\n' "$C_YELLOW" "$C_RESET"

    if [[ -t 0 ]]; then
        local input
        read -r -p "请输入网页端配置的隧道域名（如 ws.example.com，回车可跳过）：" input || return 0
        input="${input//[[:space:]]/}"
        if [[ -n "$input" ]]; then
            validate_domain "$input" || die "域名格式不合法：${input}"
            TUNNEL_DOMAIN="$input"
            save_info
        fi
    fi
}

# ------------------------------ 临时隧道 --------------------------------------
# 从服务日志提取最新的 trycloudflare.com 域名
quick_tunnel_url() {
    journalctl -u "$QUICK_SERVICE" --no-pager -n 200 2>/dev/null \
        | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n 1 || true
}

setup_quick_tunnel() {
    local unit_file="/etc/systemd/system/${QUICK_SERVICE}.service"
    log "写入临时隧道服务：${unit_file}"

    cat > "$unit_file" <<EOF
[Unit]
Description=cgg-vless Quick Tunnel (trycloudflare)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${CFDD_BIN} tunnel --no-autoupdate --url http://127.0.0.1:${LOCAL_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unit_file"

    systemctl daemon-reload
    systemctl enable "${QUICK_SERVICE}" >/dev/null 2>&1 || warn "设置开机自启失败"
    systemctl restart "${QUICK_SERVICE}"
    log "临时隧道服务已启动，等待分配域名（最长约 60 秒）..."

    local i url=""
    for i in $(seq 1 30); do
        url="$(quick_tunnel_url)"
        [[ -n "$url" ]] && break
        sleep 2
    done

    if [[ -z "$url" ]]; then
        err "未获取到临时隧道域名，最近日志如下："
        journalctl -u "$QUICK_SERVICE" -n 20 --no-pager >&2 || true
        die "请根据日志排查后重试"
    fi

    TUNNEL_DOMAIN="${url#https://}"
    save_info
    log "临时隧道域名：${TUNNEL_DOMAIN}"
}

# ------------------------------ 结果输出 --------------------------------------
print_result() {
    local link enc_path

    if [[ -z "$TUNNEL_DOMAIN" ]]; then
        warn "尚未记录隧道域名，链接中域名为占位符，配置好后请在总菜单 6 中重新查看"
        TUNNEL_DOMAIN="YOUR_TUNNEL_DOMAIN"
    fi

    enc_path="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"
    link="vless://${UUID}@${TUNNEL_DOMAIN}:443?encryption=none&security=tls&sni=${TUNNEL_DOMAIN}&fp=chrome&type=ws&host=${TUNNEL_DOMAIN}&path=${enc_path}#${NODE_NAME}"

    printf '\n%s============ cgg-vless WS + CF Tunnel 节点信息 ============%s\n' "$C_CYAN" "$C_RESET"
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  隧道类型    : %s\n' "$([[ "$TUNNEL_TYPE" == "quick" ]] && printf '临时隧道（trycloudflare）' || printf '固定隧道')"
    printf '  隧道域名    : %s\n' "$TUNNEL_DOMAIN"
    printf '  客户端端口  : 443（TLS 由 Cloudflare 边缘处理）\n'
    printf '  UUID        : %s\n' "$UUID"
    printf '  传输协议    : ws\n'
    printf '  WS 路径     : %s\n' "$WS_PATH"
    printf '  本地回源    : 127.0.0.1:%s\n' "$LOCAL_PORT"
    printf '  SNI         : %s\n' "$TUNNEL_DOMAIN"
    printf '%s==========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    if [[ "$TUNNEL_TYPE" == "quick" ]]; then
        printf '%s临时隧道：域名每次重启都会变化，总菜单 6 重新查看可获取最新域名；仅建议测试使用。%s\n' "$C_YELLOW" "$C_RESET"
    else
        printf '%s固定隧道：如尚未在网页端配置，请按上方提示添加 Public Hostname（Type: HTTP → URL: http://localhost:%s，需带 http:// 协议头）。%s\n' "$C_YELLOW" "$LOCAL_PORT" "$C_RESET"
    fi
    printf '%s防火墙无需放行任何入站端口，Xray 仅监听 127.0.0.1。%s\n\n' "$C_YELLOW" "$C_RESET"

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
    if [[ "$TUNNEL_TYPE" == "quick" ]]; then
        printf '%s隧道服务：%s（日志：journalctl -u %s -n 50）%s\n\n' "$C_CYAN" "$QUICK_SERVICE" "$QUICK_SERVICE" "$C_RESET"
    else
        printf '%s隧道服务：systemctl status cloudflared%s\n\n' "$C_CYAN" "$C_RESET"
    fi
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    show_banner
    check_os
    detect_runtime_user

    install_deps
    check_network

    ask_tunnel_type
    ask_node_name
    ask_local_port

    ensure_xray
    gen_uuid
    gen_ws_path
    write_config
    write_service
    start_service

    ensure_cloudflared
    if [[ "$TUNNEL_TYPE" == "quick" ]]; then
        setup_quick_tunnel
    else
        setup_fixed_tunnel
    fi

    print_result
}

main "$@"
