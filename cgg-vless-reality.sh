#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · VLESS + XTLS-Reality 一键安装脚本
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-reality.sh
# 说    明：仅安装 VLESS + Reality，不包含 VMess / Trojan 等协议
# ==============================================================================
set -Eeuo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="${CONFIG_DIR}/cgg-vless.info"
# 每个节点独立保存元信息，支持多个协议节点并存
readonly NODES_DIR="${CONFIG_DIR}/nodes"
readonly NODE_TAG="vless-reality"
readonly NODE_INFO="${NODES_DIR}/${NODE_TAG}.info"
# AnyTLS 使用独立配置，端口冲突检测需要读取
readonly ANYTLS_CONFIG="/usr/local/etc/sing-box/config.json"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly DEFAULT_SNI="itunes.apple.com"
readonly DEFAULT_NODE_NAME="VLESS-Reality"

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
NODE_NAME="${DEFAULT_NODE_NAME}"
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SERVER_IP=""
RUN_USER="nobody"
RUN_GROUP="nogroup"
ACTION="install"
LISTEN_MODE=""

# ------------------------------ 日志函数 --------------------------------------
log()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 任意命令异常退出时打印行号，避免静默失败
trap 'err "脚本执行失败（行号：$LINENO，退出码：$?），请根据上方日志排查"' ERR

# ------------------------------ 低内存适配 ------------------------------------
# 低配 LXC / OpenVZ 容器常把 /tmp 挂成 tmpfs：解压出来的二进制直接计入内存而非
# 磁盘，64/128MB 机器在 unzip 阶段就会被内核 OOM 杀掉。SIGKILL 无法被 trap 捕获，
# 用户看到的只是"卡住"且没有任何报错。下面两步把硬占用内存降为可回收的 page cache。

# 目录所在文件系统类型（tmpfs 即内存盘）
fs_type() {
    df -P -T "$1" 2>/dev/null | awk 'NR==2 {print $2}' || true
}

# 把临时目录固定到真实磁盘；Xray 官方安装器与 mktemp 都会继承 TMPDIR
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
        # 容器不允许 swap 时把本次新建的文件删掉，避免白占磁盘
        if [[ "$created" == "1" ]]; then
            rm -f /swapfile || true
            warn "无法启用 swap（LXC / OpenVZ 容器通常不允许），已删除临时 swapfile，改由磁盘临时目录降低内存峰值"
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
# 0.0.0.0 只创建 IPv4 socket，IPv6 客户端连不进来；:: 在 bindv6only=0 时是双栈。
# 但内核禁用 IPv6 时绑 :: 会直接失败，bindv6only=1 时绑 :: 会丢掉 IPv4。
# 所以探测结果只当默认值，最终用哪种接入模式由用户选择（--listen=auto|v4|dual|v6）。
LISTEN_ADDR=""

kernel_dual_ok() {
    local dis b6
    dis="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)"
    b6="$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 1)"
    [[ "$dis" == "0" && "$b6" == "0" ]]
}

detect_listen_addr() {
    if kernel_dual_ok; then
        printf '::'
    else
        printf '0.0.0.0'
    fi
}

# 公网 IPv6 地址：仅「仅 IPv6」模式需要，取不到返回空串
public_v6() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -fsS6 --max-time 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
        [[ -n "$ip" ]] || ip="$(curl -fsS6 --max-time 5 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
        ip="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' \
            | cut -d/ -f1 | grep -vE '^(fe80|fc|fd)' | head -n 1 || true)"
    fi
    [[ "$ip" == *:* ]] || ip=""
    printf '%s' "$ip"
}

listen_mode_label() {
    case "$1" in
        v4)   printf '仅 IPv4' ;;
        dual) printf '双栈（v4 + v6）' ;;
        v6)   printf '仅 IPv6' ;;
        *)    printf '自动探测' ;;
    esac
}

# 按实际绑定地址回显，避免 auto 模式下显示成「自动探测」看不出结果
listen_addr_label() {
    case "$1" in
        '::')    printf '双栈（v4 + v6）' ;;
        '0.0.0.0') printf '仅 IPv4' ;;
        *)       printf '仅 IPv6' ;;
    esac
}

# 把接入模式落到实际监听地址；条件不满足时明确告警并回退，不让安装卡在可选优化上
apply_listen_mode() {
    local mode="$1" addr="" dis b6
    case "$mode" in
        v4)   addr='0.0.0.0' ;;
        dual) addr='::' ;;
        v6)   addr="$(public_v6)" ;;
        *)    mode='auto'; addr="$(detect_listen_addr)" ;;
    esac

    if [[ "$mode" == "dual" ]] && ! kernel_dual_ok; then
        dis="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo '?')"
        b6="$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo '?')"
        warn "内核不满足双栈条件：disable_ipv6=${dis} bindv6only=${b6}"
        warn "此时绑 :: 可能直接启动失败，或只留 IPv6 丢掉 IPv4，已回退为仅 IPv4"
        warn "确实要双栈请先执行：sysctl -w net.ipv6.bindv6only=0（并确认 disable_ipv6=0）"
        mode='v4'; addr='0.0.0.0'
    fi

    if [[ "$mode" == "v6" && -z "$addr" ]]; then
        warn "未取到公网 IPv6 地址，已回退为仅 IPv4"
        mode='v4'; addr='0.0.0.0'
    fi

    LISTEN_MODE="$mode"
    LISTEN_ADDR="$addr"
    log "接入模式：$(listen_mode_label "$mode")（listen=${LISTEN_ADDR}）"
}

ask_listen_mode() {
    local detected def choice
    detected="$(detect_listen_addr)"

    # 命令行 --listen= 已显式指定时不再询问
    if [[ -n "$LISTEN_MODE" && "$LISTEN_MODE" != "auto" ]]; then
        log "接入模式由命令行指定：$(listen_mode_label "$LISTEN_MODE")"
        apply_listen_mode "$LISTEN_MODE"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        apply_listen_mode 'auto'
        log "非交互模式：按内核探测结果选择接入模式"
        return 0
    fi

    if [[ "$detected" == "::" ]]; then def=2; else def=1; fi
    printf '\n选择接入模式（决定哪些客户端能连进来）：\n'
    printf '  1) 仅 IPv4   绑 0.0.0.0，v6 客户端连不进来，兼容性最好\n'
    printf '  2) 双栈      绑 ::，v4 与 v6 都能进，需内核支持\n'
    printf '  3) 仅 IPv6   只绑公网 v6 地址，v4 客户端连不进来\n'
    if [[ "$detected" == "::" ]]; then
        printf '  内核探测：双栈可用\n'
    else
        printf '  内核探测：仅 IPv4 可用（disable_ipv6 或 bindv6only 非 0）\n'
    fi
    read -r -p "请选择 [1-3]（回车默认 ${def}）：" choice || true

    case "${choice:-$def}" in
        1) apply_listen_mode 'v4' ;;
        3) apply_listen_mode 'v6' ;;
        *) apply_listen_mode 'dual' ;;
    esac

    if [[ "$LISTEN_MODE" == "v6" ]]; then
        warn "仅 IPv6 绑定的是具体地址 ${LISTEN_ADDR}，该地址变化后需重新切换"
    fi
}

# IPv6 地址在 URI 里必须加方括号，否则 @ 后面的冒号会被当成端口分隔符
format_host() {
    local h="$1"
    if [[ "$h" == *:* && "$h" != \[* ]]; then
        printf '[%s]' "$h"
    else
        printf '%s' "$h"
    fi
}

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
    local min=""
    case "${ID:-}" in
        ubuntu) min="20.04" ;;
        debian) min="11" ;;
        *)
            die "仅支持 Ubuntu 20.04+ / Debian 11+，当前系统：${PRETTY_NAME:-unknown}"
            ;;
    esac

    # 版本号缺失时只告警，避免精简镜像 / LXC 模板被误拦
    if [[ -z "${VERSION_ID:-}" ]]; then
        warn "无法读取系统版本号，跳过版本检查：${PRETTY_NAME:-${ID}}"
    elif [[ "$(printf '%s\n%s\n' "$min" "${VERSION_ID}" | sort -V | head -n 1)" != "$min" ]]; then
        die "系统版本过低：需要 ${ID} ${min} 及以上，当前为 ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
    fi

    log "当前系统：${PRETTY_NAME:-${ID} ${VERSION_ID}}"
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
    for cmd in curl openssl jq unzip; do
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

# 判断端口是否为当前节点已配置且正在运行的端口（重装时可复用）
own_running_port() {
    local port="$1" own
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$CONFIG_FILE" ]] || return 1
    own="$(jq -r --arg tag "$NODE_TAG" '[.inbounds[]? | select(.tag == $tag)][0].port // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$own" && "$own" == "$port" ]] || return 1
    systemctl is-active --quiet xray 2>/dev/null
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
    local default_port input conflict
    default_port="$(random_port)"

    if [[ ! -t 0 ]]; then
        if conflict="$(port_config_conflict "$default_port" "$NODE_TAG")"; then
            die "随机端口 ${default_port} 已被${conflict}占用，请手动指定端口"
        fi
        PORT="$default_port"
        log "非交互模式：使用随机端口 ${PORT}"
        return 0
    fi

    read -r -p "监听端口（1-65535，回车使用随机端口 ${default_port}）：" input
    input="${input//[[:space:]]/}"

    if [[ -z "$input" ]]; then
        if conflict="$(port_config_conflict "$default_port" "$NODE_TAG")"; then
            die "随机端口 ${default_port} 已被${conflict}占用，请手动指定端口"
        fi
        PORT="$default_port"
    elif [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
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

# 验证 Xray 二进制可执行且能正常运行
verify_xray_runtime() {
    [[ -x "$XRAY_BIN" ]] || return 1
    "$XRAY_BIN" version >/dev/null 2>&1
}

# ------------------------------ 安装 Xray -------------------------------------
ensure_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        local cur cur_ver
        cur="$("$XRAY_BIN" version 2>/dev/null | head -n 1 || true)"
        log "检测到已安装 Xray：${cur}"
        cur_ver="$(printf '%s' "$cur" | awk '{print $2}')"
        if [[ -n "$cur_ver" ]] && [[ "$(printf '%s\n%s\n' "1.8.0" "$cur_ver" | sort -V | head -n 1)" != "1.8.0" ]]; then
            warn "当前版本 ${cur_ver} 低于 1.8，Reality / xtls-rprx-vision 可能不可用，建议升级核心"
        fi
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 Xray"
    command -v unzip >/dev/null 2>&1 || die "缺少 unzip，请先安装：apt-get install -y unzip"

    local arch tag url zip entry new_bin expect actual
    case "$(uname -m)" in
        x86_64|amd64)  arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7l|armv7)  arch="arm32-v7a" ;;
        *) die "不支持的架构：$(uname -m)，请手动安装 ${XRAY_BIN} 后重跑" ;;
    esac

    log "获取 Xray 最新版本..."
    tag="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    [[ -n "$tag" ]] || die "获取 Xray 版本失败（GitHub API 不可达），请手动安装 ${XRAY_BIN} 后重跑"

    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch}.zip"
    zip="${TMPDIR:-/tmp}/Xray-linux-${arch}.zip"

    log "下载 Xray ${tag}（linux-${arch}）..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$zip" "$url"; then
        rm -f "$zip" || true
        die "Xray 下载失败，请检查网络后重试"
    fi

    # 官方 .dgst 里带 SHA256；取不到时只告警（下载仍走 HTTPS），不阻断安装
    expect="$(curl -fsSL --retry 2 --connect-timeout 15 "${url}.dgst" 2>/dev/null \
        | awk -F '= ' '/256=/ {print $2}' | head -n 1 || true)"
    if [[ -n "$expect" ]]; then
        actual="$(sha256sum "$zip" | awk '{print $1}' | sed 's/^\\//')"
        if [[ "$expect" != "$actual" ]]; then
            rm -f "$zip" || true
            die "Xray 校验失败（期望 ${expect}，实际 ${actual}），已拒绝安装"
        fi
        log "SHA256 校验通过"
    else
        warn "未取到官方校验文件，跳过 SHA256 校验"
    fi

    # 关键：流式解压直接写目标文件，不产生解压后的中间副本。
    # 官方安装器会把压缩包和整棵解压目录都放在临时目录，/tmp 为 tmpfs 时
    # 这几十 MB 全算内存占用，低内存机器会在这一步被 OOM 杀掉。
    entry="$(unzip -Z1 "$zip" 2>/dev/null | grep -E '(^|/)xray$' | head -n 1 || true)"
    if [[ -z "$entry" ]]; then
        rm -f "$zip" || true
        die "压缩包中未找到 xray 可执行文件"
    fi
    new_bin="${XRAY_BIN}.new"
    if ! unzip -p "$zip" "$entry" > "$new_bin"; then
        rm -f "$zip" "$new_bin"
        die "Xray 解压失败（可能是磁盘空间不足）"
    fi
    if ! chmod 755 "$new_bin"; then
        rm -f "$zip" "$new_bin"
        die "设置执行权限失败"
    fi
    if ! mv -f "$new_bin" "$XRAY_BIN"; then
        rm -f "$zip" "$new_bin"
        die "替换 ${XRAY_BIN} 失败"
    fi
    rm -f "$zip" || true

    [[ -x "$XRAY_BIN" ]] || die "安装完成后未找到 ${XRAY_BIN}"
    verify_xray_runtime || die "Xray 安装完成但无法运行，请按上方提示排查"
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
      "tag": "vless-reality",
      "listen": "${LISTEN_ADDR}",
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
          "minClientVer": "1.8.2",
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

    merge_config "$new_cfg"
    rm -f "$new_cfg"
    save_info
    log "配置写入并校验通过：${CONFIG_FILE}"
}

# 保存节点元信息，供管理菜单读取（名称、公钥等）
save_info() {
    install -d -m 755 -o root -g root "$NODES_DIR"
    {
        printf 'MODE=reality\n'
        printf 'PORT=%s\n' "$PORT"
        printf 'UUID=%s\n' "$UUID"
        printf 'SNI=%s\n' "$SNI"
        printf 'PUBLIC_KEY=%s\n' "$PUBLIC_KEY"
        printf 'SHORT_ID=%s\n' "$SHORT_ID"
        printf 'NODE_NAME=%s\n' "$NODE_NAME"
        printf 'LISTEN_MODE=%s\n' "${LISTEN_MODE:-auto}"
        printf 'LISTEN_ADDR=%s\n' "${LISTEN_ADDR:-0.0.0.0}"
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
OOMScoreAdjust=-600

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

    # ufw 的 allow 默认同时覆盖 v4/v6；iptables 只作用于 IPv4，IPv6 需单独放行
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
            # 逐条应用并回读，避免 sysctl --system 吞掉错误导致误判成功
            local line key val
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                key="${line%%=*}"
                val="${line#*=}"
                key="${key//[[:space:]]/}"
                val="${val//[[:space:]]/}"
                sysctl -w "${key}=${val}" >/dev/null 2>&1 \
                    || warn "应用失败：${key}（当前内核或容器可能不支持）"
            done < /etc/sysctl.d/99-cgg-bbr.conf
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
    # IPv4 优先：双栈机器上客户端大多只有 IPv4，v4 地址兼容性最好
    ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS4 --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    # 没有 IPv4 出口（纯 IPv6 机器）时退回 IPv6
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsS6 --max-time 5 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -n "$ip" ]]; then
            warn "未取到公网 IPv4，使用 IPv6 地址：${ip}（客户端需支持 IPv6）"
        fi
    fi
    if [[ -z "$ip" ]]; then
        # 排除链路本地 fe80、ULA fc00::/7、回环，避免把内网地址写进分享链接
        ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(fe80|fc[0-9a-fA-F]{2}|fd[0-9a-fA-F]{2}|127\.)' | head -n 1 || true)"
        if [[ -n "$ip" ]]; then
            warn "公网 IP 获取失败，使用本机 IP：${ip}（如在 NAT 后请手动替换）"
        fi
    fi
    printf '%s' "$ip"
}

# ------------------------------ 结果输出 --------------------------------------
print_result() {
    local link v6_hint=""
    local ip="${SERVER_IP:-YOUR_SERVER_IP}"

    # 仅 IPv6 模式下链接必须填 v6 地址；双栈模式额外提示一条 v6 接入地址
    if [[ "$LISTEN_ADDR" == *:* && "$LISTEN_ADDR" != "::" ]]; then
        ip="$LISTEN_ADDR"
    elif [[ "$LISTEN_ADDR" == "::" ]]; then
        v6_hint="$(public_v6)"
    fi

    if command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
        if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
            warn "配置文件 JSON 校验异常，请检查 ${CONFIG_FILE}"
        fi
    fi

    link="vless://${UUID}@$(format_host "$ip"):${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"

    printf '\n%s================= cgg-vless 节点信息 =================%s\n' "$C_CYAN" "$C_RESET"
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$PORT"
    printf '  接入模式    : %s（listen=%s）\n' "$(listen_addr_label "$LISTEN_ADDR")" "$LISTEN_ADDR"
    printf '  UUID        : %s\n' "$UUID"
    printf '  流控 flow   : xtls-rprx-vision\n'
    printf '  公钥 pbk    : %s\n' "$PUBLIC_KEY"
    printf '  ShortID     : %s\n' "$SHORT_ID"
    printf '  伪装域名SNI : %s\n' "$SNI"
    printf '  传输协议    : tcp\n'
    printf '  安全类型    : reality\n'
    printf '%s======================================================%s\n\n' "$C_CYAN" "$C_RESET"
    printf '%s提示：私钥仅保存在服务端，请勿泄露。%s\n\n' "$C_YELLOW" "$C_RESET"

    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    if [[ -n "$v6_hint" ]]; then
        printf '%sIPv6 同节点可用地址：%s:%s（把链接里的地址换成它即可，端口与参数不变）%s\n\n' \
            "$C_CYAN" "$(format_host "$v6_hint")" "$PORT" "$C_RESET"
    fi

    printf '%s服务管理：systemctl {status|restart|stop} xray%s\n' "$C_CYAN" "$C_RESET"
    printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$CONFIG_FILE" "$C_RESET"
}

# ------------------------------ 切换接入模式 ----------------------------------
# 只改已有节点的 listen，不动 UUID / 端口 / SNI / 密钥，客户端无需重新导入
verify_listen_addr() {
    local expect="$1" port="$2" got=""
    command -v ss >/dev/null 2>&1 || return 0
    got="$(ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" | head -n 1 || true)"
    if [[ -z "$got" ]]; then
        warn "未在 ss 中看到端口 ${port} 的监听，请检查 systemctl status xray"
        return 1
    fi
    log "实际监听：${got}"
    if [[ "$expect" == "::" ]]; then
        [[ "$got" == "*:${port}" || "$got" == "[::]:${port}" ]] \
            || warn "预期双栈 [::]:${port}，实际 ${got}，可能仍只监听 IPv4"
    elif [[ "$got" != *"${expect}:"* ]]; then
        warn "预期 ${expect}:${port}，实际 ${got}"
    fi
    return 0
}

switch_listen_mode() {
    require_root
    command -v jq >/dev/null 2>&1 || die "缺少 jq，请先安装：apt-get install -y jq"
    [[ -x "$XRAY_BIN" ]] || die "未找到 ${XRAY_BIN}，请先安装 VLESS-Reality 节点"
    [[ -f "$CONFIG_FILE" ]] || die "未找到 ${CONFIG_FILE}，请先安装 VLESS-Reality 节点"

    local cur_port cur_addr backup tmp_cfg test_out
    cur_port="$(jq -r --arg t "$NODE_TAG" '[.inbounds[]? | select(.tag == $t)][0].port // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "$cur_port" ]] || die "配置中没有 ${NODE_TAG} 节点，请先安装"
    cur_addr="$(jq -r --arg t "$NODE_TAG" '[.inbounds[]? | select(.tag == $t)][0].listen // "0.0.0.0"' "$CONFIG_FILE" 2>/dev/null || true)"
    PORT="$cur_port"

    show_banner
    printf '当前接入：listen=%s  端口=%s\n' "$cur_addr" "$PORT"

    ask_listen_mode
    if [[ "$LISTEN_ADDR" == "$cur_addr" ]]; then
        log "接入模式未变化，未做任何修改"
        return 0
    fi

    backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_FILE" "$backup" || die "备份配置失败：${CONFIG_FILE}"
    log "原配置已备份：${backup}"

    # Xray 按扩展名判断配置格式，临时文件必须带 .json 后缀
    tmp_cfg="$(mktemp "${TMPDIR:-/tmp}/cgg-listen-XXXXXX.json")"
    if ! jq --arg t "$NODE_TAG" --arg a "$LISTEN_ADDR" \
        '(.inbounds[] | select(.tag == $t) | .listen) = $a' \
        "$CONFIG_FILE" > "$tmp_cfg"; then
        rm -f "$tmp_cfg"
        die "改写 listen 失败，配置未改动"
    fi

    test_out="$(mktemp)"
    if ! "$XRAY_BIN" run -test -config "$tmp_cfg" >"$test_out" 2>&1; then
        err "配置校验输出："
        cat "$test_out" >&2 || true
        rm -f "$test_out" "$tmp_cfg"
        die "Xray 配置校验失败，未应用改动"
    fi
    rm -f "$test_out"

    if ! install -m 640 "$tmp_cfg" "$CONFIG_FILE"; then
        rm -f "$tmp_cfg"
        die "写入配置失败：${CONFIG_FILE}"
    fi
    rm -f "$tmp_cfg"
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || true

    systemctl restart xray || true
    sleep 1
    systemctl is-active --quiet xray \
        || die "Xray 重启失败，请用 journalctl -u xray -n 30 查看；配置备份：${backup}"

    # 端口没变，但切换族后 v6 放行规则可能缺失，这里补齐（只加不删）
    configure_firewall
    verify_listen_addr "$LISTEN_ADDR" "$PORT" || true

    if [[ -f "$NODE_INFO" ]]; then
        local tmp_info="${NODE_INFO}.tmp"
        if grep -vE '^(LISTEN_MODE|LISTEN_ADDR)=' "$NODE_INFO" > "$tmp_info" 2>/dev/null; then
            printf 'LISTEN_MODE=%s\nLISTEN_ADDR=%s\n' "$LISTEN_MODE" "$LISTEN_ADDR" >> "$tmp_info" \
                && mv -f "$tmp_info" "$NODE_INFO" || rm -f "$tmp_info"
        else
            rm -f "$tmp_info"
        fi
        chmod 600 "$NODE_INFO" 2>/dev/null || true
    fi

    printf '\n%s接入模式已切换：%s（listen=%s）%s\n' \
        "$C_GREEN" "$(listen_addr_label "$LISTEN_ADDR")" "$LISTEN_ADDR" "$C_RESET"
    printf 'UUID / 端口 / SNI / 密钥均未改动，客户端无需重新导入。\n\n'
}

# ------------------------------ 参数解析 --------------------------------------
usage() {
    cat <<'EOF'
用法：sudo bash cgg-vless-reality.sh [选项]

  （无参数）            安装或重建 VLESS-Reality 节点
  --listen=MODE         指定接入模式：auto（按内核探测）| v4 | dual | v6
  --switch-listen       只切换已有节点的接入模式，不重装、不改密钥
  -h, --help            显示本帮助
EOF
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --listen=*) LISTEN_MODE="${arg#*=}" ;;
            --switch-listen) ACTION="switch" ;;
            -h|--help) usage; exit 0 ;;
            *) warn "忽略未知参数：${arg}" ;;
        esac
    done
    case "$LISTEN_MODE" in
        ""|auto|v4|dual|v6) ;;
        *) die "--listen 只接受 auto / v4 / dual / v6，当前：${LISTEN_MODE}" ;;
    esac
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    parse_args "$@"

    if [[ "$ACTION" == "switch" ]]; then
        switch_listen_mode
        return 0
    fi

    require_root
    show_banner
    check_os
    detect_runtime_user
    prepare_tmpdir
    ensure_swap
    check_memory_headroom

    ask_port
    ask_sni
    ask_node_name
    ask_listen_mode

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
