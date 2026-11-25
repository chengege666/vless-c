#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · Snell v6 节点（官方 snell-server 后端）
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-snell.sh
# 说    明：Snell 是 Surge 团队的闭源加密代理协议，本脚本安装官方 snell-server
#           二进制；配置、服务、元信息均与 Xray / sing-box 分离，可与现有节点并存
#           （端口不冲突时）。Snell v6 为纯 TCP 协议，不支持 TLS / CDN。
# ==============================================================================
set -Eeuo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly SNELL_BIN="/usr/local/bin/snell-server"
readonly SNELL_DIR="/usr/local/etc/snell"
readonly CONFIG_FILE="${SNELL_DIR}/snell-server.conf"
readonly INFO_FILE="${SNELL_DIR}/cgg-snell.info"
readonly SERVICE_NAME="cgg-snell"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly ANYTLS_CONFIG="/usr/local/etc/sing-box/config.json"
readonly RUN_USER="nobody"
readonly RUN_GROUP="nogroup"
readonly DEFAULT_NODE_NAME="cgg-snell"
readonly DEFAULT_PORT="6160"
# 官方当前 v6 服务端版本，可通过 CGG_SNELL_VERSION 覆盖
readonly SNELL_VERSION="${CGG_SNELL_VERSION:-6.0.0}"
readonly SNELL_DL_BASE="https://dl.nssurge.com/snell"

# ------------------------------ 运行期变量 ------------------------------------
PORT=""
SNELL_MODE=""
PSK=""
NODE_NAME=""
SERVER_IP=""
LISTEN_ADDR=""

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

# ------------------------------ 低内存适配 ------------------------------------
# 低配 LXC / OpenVZ 容器常把 /tmp 挂成 tmpfs：解压出来的二进制直接计入内存而非
# 磁盘，64/128MB 机器在 unzip 阶段就会被内核 OOM 杀掉。SIGKILL 无法被 trap 捕获，
# 用户看到的只是"卡住"且没有任何报错。下面两步把硬占用内存降为可回收的 page cache。

# 目录所在文件系统类型（tmpfs 即内存盘）
fs_type() {
    df -P -T "$1" 2>/dev/null | awk 'NR==2 {print $2}' || true
}

# 把临时目录固定到真实磁盘
prepare_tmpdir() {
    local cur="${TMPDIR:-/tmp}" cand
    if [[ "$(fs_type "$cur")" != "tmpfs" ]]; then
        export TMPDIR="$cur"
        return 0
    fi
    for cand in /var/tmp /root/.cache /usr/local/etc/.cgg-tmp; do
        mkdir -p "$cand" 2>/dev/null || continue
        [[ "$(fs_type "$cand")" == "tmpfs" ]] && continue
        export TMPDIR="$cand"
        warn "检测到 ${cur} 为 tmpfs（内存盘），临时目录改用 ${cand}，避免解压时耗尽内存"
        return 0
    done
    warn "未找到磁盘上的临时目录，仍使用 ${cur}；低内存机器可能在解压阶段失败"
}

# 内存偏小时尽力补一块 swap；容器不允许则只告警，不中断安装
ensure_swap() {
    local mem_kb swap_kb avail_mb size_mb=512
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ -z "$mem_kb" || "$mem_kb" -eq 0 || "$mem_kb" -ge 262144 ]]; then
        return 0
    fi
    if [[ -n "$swap_kb" && "$swap_kb" -gt 0 ]]; then
        return 0
    fi
    if [[ "${CGG_NO_SWAP:-0}" == "1" ]]; then
        return 0
    fi
    avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    if [[ -z "$avail_mb" || "$avail_mb" -lt 1024 ]]; then
        warn "根分区剩余空间不足 1GB，跳过创建 swapfile"
        return 0
    fi

    log "内存 ${mem_kb}KB 且未启用 swap，尝试创建 ${size_mb}MB swapfile..."
    local created=0
    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
            if ! dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none 2>/dev/null; then
                rm -f /swapfile || true
                warn "创建 swapfile 失败，跳过（CGG_NO_SWAP=1 可关闭此尝试）"
                return 0
            fi
        fi
        chmod 600 /swapfile 2>/dev/null || true
        created=1
    fi
    if ! mkswap /swapfile >/dev/null 2>&1 || ! swapon /swapfile 2>/dev/null; then
        if [[ "$created" == "1" ]]; then
            rm -f /swapfile || true
            warn "无法启用 swap（LXC / OpenVZ 容器通常不允许），已删除临时 swapfile"
        else
            warn "无法启用已有的 /swapfile（容器通常不允许 swap，已跳过）"
        fi
        return 0
    fi
    grep -qE '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null \
        || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    log "swap 已启用：${size_mb}MB（已写入 /etc/fstab）"
}

# 安装前提示内存余量，避免在必然失败的情况下白等
check_memory_headroom() {
    local avail_kb
    avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ -n "$avail_kb" && "$avail_kb" -gt 0 && "$avail_kb" -lt 32768 ]]; then
        warn "当前可用内存仅 $(( avail_kb / 1024 ))MB，安装过程仍可能失败"
        warn "建议先停止无关服务释放内存，或换用内存更大的机器"
    fi
}

# ------------------------------ 监听地址 --------------------------------------
# snell-server 支持多地址监听；bindv6only=0 时 [::] 可同时接收 IPv4/IPv6。
# 内核禁用 IPv6 或 bindv6only=1 时只监听 0.0.0.0，避免服务启动失败。
detect_listen_addr() {
    local dis b6
    dis="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)"
    b6="$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 1)"
    if [[ "$dis" == "0" && "$b6" == "0" ]]; then
        printf '::'
    else
        printf '0.0.0.0'
    fi
}

LISTEN_ADDR="$(detect_listen_addr 2>/dev/null || true)"
[[ -n "$LISTEN_ADDR" ]] || LISTEN_ADDR="0.0.0.0"

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
    local min=""
    case "${ID:-}" in
        ubuntu) min="20.04" ;;
        debian) min="11" ;;
        *)
            die "仅支持 Ubuntu 20.04+ / Debian 11+，当前系统：${PRETTY_NAME:-unknown}"
            ;;
    esac

    if [[ -z "${VERSION_ID:-}" ]]; then
        warn "无法读取系统版本号，跳过版本检查：${PRETTY_NAME:-${ID}}"
    elif [[ "$(printf '%s\n%s\n' "$min" "${VERSION_ID}" | sort -V | head -n 1)" != "$min" ]]; then
        die "系统版本过低：需要 ${ID} ${min} 及以上，当前为 ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
    fi

    log "当前系统：${PRETTY_NAME:-${ID} ${VERSION_ID}}"
}

install_deps() {
    local -a missing=()
    local cmd
    for cmd in curl unzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} == 0 )); then
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 \
        || die "缺少必要命令：${missing[*]}，且未找到 apt-get，请手动安装后重跑"
    log "安装依赖：${missing[*]}"
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" \
        || die "依赖安装失败：${missing[*]}"
}

check_network() {
    local arch url
    # 架构不支持时由 install_snell 给出明确报错，这里只做下载站连通性提示
    if ! arch="$(detect_arch 2>/dev/null)"; then
        return 0
    fi
    url="${SNELL_DL_BASE}/snell-server-v${SNELL_VERSION}-linux-${arch}.zip"
    if ! curl -fsS -I --max-time 10 -o /dev/null "$url" 2>/dev/null; then
        warn "官方下载站访问异常，snell-server 下载可能失败：${url}"
    fi
}

# 交互环境检查
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
        ip="$(curl -fsS6 --max-time 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "$ip" ]]; then
            warn "未取到公网 IPv4，使用 IPv6 地址：${ip}（客户端需支持 IPv6）"
        fi
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(fe80|fc[0-9a-fA-F]{2}|fd[0-9a-fA-F]{2}|127\.)' | head -n 1 || true)"
        if [[ -n "$ip" ]]; then
            warn "公网 IP 获取失败，使用本机 IP：${ip}（如在 NAT 后请手动替换）"
        fi
    fi
    printf '%s' "$ip"
}

# ------------------------------ 架构识别 --------------------------------------
# 官方 v6 仅提供 amd64 / i386 / aarch64，armv7l 无可用二进制
detect_arch() {
    local machine
    machine="$(uname -m 2>/dev/null || true)"
    case "$machine" in
        x86_64|amd64)                printf 'amd64' ;;
        aarch64|arm64)               printf 'aarch64' ;;
        i386|i486|i586|i686|x86)     printf 'i386' ;;
        *)                           return 1 ;;
    esac
}

# ------------------------------ 端口检查 --------------------------------------
port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

config_port_in_use() {
    local port="$1" cfg

    # Xray 的 inbound 全部为 TCP，需排除
    if [[ -f "$XRAY_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        while IFS= read -r cfg; do
            [[ -n "$cfg" ]] || continue
            [[ "$cfg" == "$port" ]] && return 0
        done < <(jq -r '.inbounds[]? | .port // empty' "$XRAY_CONFIG" 2>/dev/null || true)
    fi

    # AnyTLS 复用同一 sing-box 目录，其 inbound 为 TCP
    if [[ -f "$ANYTLS_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        cfg="$(jq -r '.inbounds[0].listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null || true)"
        [[ -n "$cfg" && "$cfg" == "$port" ]] && return 0
    fi

    return 1
}

# ------------------------------ 参数输入 --------------------------------------
ask_port() {
    local input
    read -r -p "监听端口（1-65535，回车默认 ${DEFAULT_PORT}）：" input
    input="${input//[[:space:]]/}"
    if [[ -z "$input" ]]; then
        PORT="$DEFAULT_PORT"
    elif [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
        PORT="$input"
    else
        die "端口不合法：${input}"
    fi

    if port_in_use "$PORT"; then
        die "端口 ${PORT} 已被占用，请先停止占用进程或换端口"
    fi
    if config_port_in_use "$PORT"; then
        die "端口 ${PORT} 已被现有 Xray / AnyTLS 配置占用，请为 Snell 选择其他端口"
    fi

    log "监听端口：${PORT}"
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

ask_mode() {
    local input
    printf '  Snell v6 流量模式（客户端与服务端必须一致）：\n'
    printf '    1) default    混淆 + AES 加密（默认，抗识别最强）\n'
    printf '    2) unshaped   仅 AES 加密，吞吐约 +10%%\n'
    printf '    3) unsafe-raw 明文转发，仅限内网 / 已有安全隧道\n'
    read -r -p "请选择 [1-3，回车默认 1]：" input
    input="${input//[[:space:]]/}"
    case "$input" in
        ""|1) SNELL_MODE="default" ;;
        2)    SNELL_MODE="unshaped" ;;
        3)
            SNELL_MODE="unsafe-raw"
            warn "unsafe-raw 不加密、不混淆，公网直接暴露时禁止使用"
            ;;
        *) die "无效选项：${input}" ;;
    esac
    log "流量模式：${SNELL_MODE}"
}

# ------------------------------ PSK 生成 --------------------------------------
gen_psk() {
    PSK="$(openssl rand -hex 32 2>/dev/null || true)"
    if [[ -z "$PSK" ]]; then
        PSK="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' || true)"
    fi
    [[ ${#PSK} -ge 12 && ${#PSK} -le 255 ]] || die "PSK 生成失败"
    log "PSK 生成完成（${#PSK} 字符）"
}

# ------------------------------ 安装 snell-server -----------------------------
install_snell() {
    # 官方二进制的 --version 输出格式/输出通道不稳定，这里只校验可执行性，
    # 版本以安装包 URL 为准，避免误判导致安装中断
    if [[ -x "$SNELL_BIN" ]] && "$SNELL_BIN" --help >/dev/null 2>&1; then
        log "检测到可用的 snell-server，直接复用：${SNELL_BIN}"
        return 0
    fi

    local arch url tmpdir zipfile new_bin
    if ! arch="$(detect_arch)"; then
        die "当前架构不支持 Snell v6（官方仅提供 amd64 / i386 / aarch64），请换机或手动编译"
    fi

    url="${SNELL_DL_BASE}/snell-server-v${SNELL_VERSION}-linux-${arch}.zip"
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cgg-snell-XXXXXX")" \
        || die "创建临时目录失败"

    log "下载 snell-server v${SNELL_VERSION}（linux-${arch}）..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${tmpdir}/snell.zip" "$url"; then
        rm -rf "$tmpdir"
        die "snell-server 下载失败：${url}"
    fi
    zipfile="${tmpdir}/snell.zip"
    if [[ ! -s "$zipfile" ]]; then
        rm -rf "$tmpdir"
        die "下载文件为空，可能被网络劫持，请重试"
    fi

    new_bin="${SNELL_BIN}.new"
    if ! unzip -p "$zipfile" snell-server > "$new_bin" 2>/dev/null; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "压缩包解压失败或未找到 snell-server"
    fi
    if [[ ! -s "$new_bin" ]]; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "压缩包中未找到 snell-server 二进制"
    fi
    chmod 755 "$new_bin" 2>/dev/null || true
    if ! "$new_bin" --help >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "下载的 snell-server 无法运行（可能架构不匹配或被篡改）"
    fi
    if ! mv -f "$new_bin" "$SNELL_BIN"; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "安装 snell-server 到 ${SNELL_BIN} 失败"
    fi
    rm -rf "$tmpdir"

    "$SNELL_BIN" --help >/dev/null 2>&1 || die "snell-server 安装后无法运行"
    log "snell-server 安装完成：${SNELL_BIN}（安装包 v${SNELL_VERSION}）"
}

# ------------------------------ 配置写入 --------------------------------------
write_config() {
    install -d -m 755 -o root -g root "$SNELL_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        local backup
        backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$backup" || warn "旧配置备份失败：${backup}"
        log "旧配置已备份：${backup}"
    fi

    local listen_value
    if [[ "$LISTEN_ADDR" == "::" ]]; then
        listen_value="[::]:${PORT}"
    else
        listen_value="0.0.0.0:${PORT}"
    fi

    # v6 服务端配置文件不再需要 version 项，mode 决定混淆与加密策略；
    # dns-ip-preference 保持缺省，避免不同小版本对默认值兼容性不一致
    cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${listen_value}
psk = ${PSK}
mode = ${SNELL_MODE}
EOF

    # snell-server 以 nobody 运行，配置含 PSK，需属组可读且限制其他用户
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || warn "无法修改配置属组：${CONFIG_FILE}"
    chmod 640 "$CONFIG_FILE"

    grep -q '^listen = ' "$CONFIG_FILE" || die "配置写入失败：缺少 listen"
    grep -q '^psk = ' "$CONFIG_FILE" || die "配置写入失败：缺少 psk"
    grep -q '^mode = ' "$CONFIG_FILE" || die "配置写入失败：缺少 mode"
    log "配置写入完成：${CONFIG_FILE}"
}

# ------------------------------ systemd 服务 ----------------------------------
write_service() {
    if [[ -f "$SERVICE_FILE" ]] && ! grep -q "cgg-snell" "$SERVICE_FILE"; then
        local backup
        backup="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$SERVICE_FILE" "$backup"
        log "旧服务文件已备份：${backup}"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless Snell v6 Service (snell-server)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SNELL_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1000000
OOMScoreAdjust=-600

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

# ------------------------------ 防火墙 ----------------------------------------
configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 || warn "UFW 放行 ${PORT}/tcp 失败"
        log "UFW 已放行端口 ${PORT}/tcp"
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT \
                || warn "ip6tables 放行端口失败，请手动放行 ${PORT}/tcp"
        fi
        log "ip6tables 已放行端口 ${PORT}/tcp"
    fi

    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT \
                || warn "iptables 放行端口失败，请手动放行 ${PORT}/tcp"
        fi
        log "iptables 已放行端口 ${PORT}/tcp（如使用 firewalld 请另行放行）"
    elif ! command -v ufw >/dev/null 2>&1; then
        warn "未检测到 UFW / iptables，请手动放行 ${PORT}/tcp"
    fi
}

# ------------------------------ 元信息 ----------------------------------------
save_info() {
    install -d -m 755 -o root -g root "$SNELL_DIR"
    {
        printf 'MODE=snell\n'
        printf 'PORT=%s\n' "$PORT"
        printf 'PSK=%s\n' "$PSK"
        printf 'SNELL_MODE=%s\n' "$SNELL_MODE"
        printf 'NODE_NAME=%s\n' "$NODE_NAME"
        printf 'PROTOCOL_VERSION=6\n'
        printf 'LISTEN=%s\n' "$LISTEN_ADDR"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# ------------------------------ 输出结果 --------------------------------------
print_result() {
    local ip
    ip="${SERVER_IP:-YOUR_SERVER_IP}"

    printf '\n%s================= cgg-vless Snell v6 节点 =================%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : Snell v6（官方 snell-server）\n'
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s/TCP\n' "$PORT"
    printf '  PSK         : %s\n' "$PSK"
    printf '  流量模式    : %s\n' "$SNELL_MODE"
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    printf '%sSnell 没有通用分享链接，请在客户端手动填写：%s\n\n' "$C_GREEN" "$C_RESET"

    printf '%sSurge：%s\n' "$C_GREEN" "$C_RESET"
    printf '  %s = snell, %s, %s, psk=%s, version=6, mode=%s\n\n' \
        "$NODE_NAME" "$ip" "$PORT" "$PSK" "$SNELL_MODE"

    printf '%sStash / mihomo（Clash Meta）YAML：%s\n' "$C_GREEN" "$C_RESET"
    printf '  - name: "%s"\n' "$NODE_NAME"
    printf '    type: snell\n'
    printf '    server: %s\n' "$ip"
    printf '    port: %s\n' "$PORT"
    printf '    psk: "%s"\n' "$PSK"
    printf '    version: 6\n'
    printf '    mode: %s\n' "$SNELL_MODE"
    printf '    udp: true\n\n'

    printf '%ssing-box outbound JSON：%s\n' "$C_GREEN" "$C_RESET"
    printf '  {\n'
    printf '    "type": "snell",\n'
    printf '    "tag": "snell-out",\n'
    printf '    "server": "%s",\n' "$ip"
    printf '    "server_port": %s,\n' "$PORT"
    printf '    "version": 6,\n'
    printf '    "psk": "%s",\n' "$PSK"
    printf '    "mode": "%s"\n' "$SNELL_MODE"
    printf '  }\n\n'

    printf '%s提示：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - Snell v6 仍处于 Beta，客户端与服务端需保持较新版本，两端 mode 必须一致\n'
    printf '  - 支持客户端：Surge（Beta）、Stash、mihomo >= 1.19.34、sing-box >= 1.14.0\n'
    printf '  - v2rayNG / NekoBox / Hiddify 不支持 Snell，无法导入\n'
    printf '  - Snell 为纯 TCP 协议，不支持 TLS / Cloudflare CDN，需客户端直连\n'
    printf '  - 无前向保密，抗主动探测能力弱于 Reality，请勿用于高风险环境\n'
    printf '  - NAT 机器需在服务商面板把外部端口 %s 映射到容器内部端口 %s\n' "$PORT" "$PORT"
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    check_os
    require_tty
    install_deps
    check_network
    prepare_tmpdir
    ensure_swap
    check_memory_headroom

    printf '\n%s========== cgg-vless · Snell v6（snell-server）==========%s\n\n' "$C_MAGENTA" "$C_RESET"
    warn "Snell v6 为闭源协议且处于 Beta，纯 TCP 无 TLS，仅建议在客户端为 Surge / Stash 时使用"

    ask_port
    ask_node_name
    ask_mode
    gen_psk

    install_snell
    write_config
    write_service
    configure_firewall
    save_info

    SERVER_IP="$(get_public_ip)"
    print_result
    log "安装完成"
}

main "$@"
