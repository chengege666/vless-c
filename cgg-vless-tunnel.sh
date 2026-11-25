#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · VLESS + WebSocket + Cloudflare Tunnel
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-tunnel.sh
# 说    明：Xray 仅在 127.0.0.1 监听 WS 明文（security: none），
#           TLS 由 Cloudflare 边缘承担；无需域名证书，无需放行入站端口。
#   固定隧道：网页创建隧道取 Token → cloudflared service install，域名固定
#   固定隧道复用：沿用本机已有 cloudflared 服务，不重装、不清理
#   临时隧道：quick tunnel（trycloudflare.com），域名随机且每次重启都会变化
# ==============================================================================
set -Eeuo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="${CONFIG_DIR}/cgg-vless.info"
# 每个节点独立保存元信息，支持多个协议节点并存
readonly NODES_DIR="${CONFIG_DIR}/nodes"
readonly NODE_TAG="vless-ws-tunnel"
readonly NODE_INFO="${NODES_DIR}/${NODE_TAG}.info"
# AnyTLS 使用独立配置，端口冲突检测需要读取
readonly ANYTLS_CONFIG="/usr/local/etc/sing-box/config.json"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
readonly CFDD_BIN="/usr/local/bin/cloudflared"
readonly CFDD_URL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
readonly CFDD_CONFIG_FILE="/etc/cloudflared/config.yml"
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
# 固定隧道子模式：0=新建独立隧道，1=复用本机已有隧道
TUNNEL_REUSE="0"
SERVER_IP=""
RUN_USER="nobody"
RUN_GROUP="nogroup"

# ------------------------------ 日志函数 --------------------------------------
log()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

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

# ------------------------------ 交互输入 --------------------------------------
validate_domain() {
    local d="$1"
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_tunnel_type() {
    local choice fixed_choice
    # 环境变量 CF_TUNNEL_TOKEN 存在时自动使用固定隧道，便于无人值守安装
    if [[ -n "$CF_TOKEN" ]]; then
        TUNNEL_TYPE="fixed"
        TUNNEL_REUSE="0"
        log "检测到环境变量 CF_TUNNEL_TOKEN，使用固定隧道模式（新建独立隧道）"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "当前为非交互环境，请提供隧道 Token：CF_TUNNEL_TOKEN=xxx bash $0"
    fi

    printf '\n选择隧道类型：\n'
    printf '  1) 固定隧道（域名固定，需域名 NS 托管在 Cloudflare）\n'
    printf '  2) 临时隧道（无需账号域名，域名随机且每次重启都会变化，仅测试用）\n'
    read -r -p "请选择 [1-2]（回车默认 1）：" choice || true
    case "${choice:-1}" in
        1) TUNNEL_TYPE="fixed" ;;
        2) TUNNEL_TYPE="quick" ;;
        *) warn "无效选项，使用固定隧道"; TUNNEL_TYPE="fixed" ;;
    esac

    TUNNEL_REUSE="0"
    if [[ "$TUNNEL_TYPE" == "fixed" ]]; then
        printf '\n固定隧道模式：\n'
        printf '  1) 新建独立隧道（网页创建后粘贴 Token，回车默认）\n'
        printf '  2) 复用本机已有隧道（沿用现有 cloudflared 服务与配置，不重装不清理）\n'
        read -r -p "请选择 [1-2]（回车默认 1）：" fixed_choice || true
        case "${fixed_choice:-1}" in
            1) TUNNEL_REUSE="0" ;;
            2) TUNNEL_REUSE="1" ;;
            *) warn "无效选项，使用新建独立隧道"; TUNNEL_REUSE="0" ;;
        esac
    fi

    if [[ "$TUNNEL_TYPE" == "fixed" ]]; then
        if [[ "$TUNNEL_REUSE" == "1" ]]; then
            log "隧道类型：固定隧道（复用已有隧道）"
        else
            log "隧道类型：固定隧道（新建独立隧道）"
        fi
    else
        log "隧道类型：临时隧道"
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

ask_local_port() {
    local input conflict

    if [[ ! -t 0 ]]; then
        if port_in_use "$LOCAL_PORT"; then
            if own_running_port "$LOCAL_PORT"; then
                warn "本地端口 ${LOCAL_PORT} 为当前节点正在使用的端口，将继续复用"
            else
                die "本地端口 ${LOCAL_PORT} 已被占用，请手动指定其他端口"
            fi
        fi
        if conflict="$(port_config_conflict "$LOCAL_PORT" "$NODE_TAG")"; then
            die "本地端口 ${LOCAL_PORT} 已被${conflict}占用，请手动指定其他端口"
        fi
        log "非交互模式：使用默认本地端口 ${LOCAL_PORT}"
        return 0
    fi

    read -r -p "Xray 本地监听端口（仅 127.0.0.1 回源用，回车默认 ${DEFAULT_LOCAL_PORT}）：" input || return 0
    input="${input//[[:space:]]/}"
    if [[ -z "$input" ]]; then
        if port_in_use "$LOCAL_PORT"; then
            if own_running_port "$LOCAL_PORT"; then
                warn "本地端口 ${LOCAL_PORT} 为当前节点正在使用的端口，将继续复用"
            else
                die "本地端口 ${LOCAL_PORT} 已被占用，请手动指定其他端口"
            fi
        fi
        if conflict="$(port_config_conflict "$LOCAL_PORT" "$NODE_TAG")"; then
            die "本地端口 ${LOCAL_PORT} 已被${conflict}占用，请手动指定其他端口"
        fi
        log "本地端口：${LOCAL_PORT}"
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
    LOCAL_PORT="$input"
    log "本地端口：${LOCAL_PORT}"
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
    log "Xray 安装完成：$("$XRAY_BIN" version 2>/dev/null | head -n 1)"
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
        printf 'TUNNEL_REUSE=%s\n' "$TUNNEL_REUSE"
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

# 清理固定隧道与临时隧道的残留服务，避免切换类型后旧隧道继续运行
cleanup_tunnel_services() {
    local svc found=0

    for svc in cloudflared cloudflared-update cgg-quick-tunnel; do
        if systemctl cat "$svc" >/dev/null 2>&1 || [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            found=1
        fi
    done
    if (( found == 0 )); then
        return 0
    fi

    warn "检测到旧隧道服务残留，将先停止并清理（若本机还有其他项目在用 cloudflared 隧道，请先确认）"
    if [[ -x "$CFDD_BIN" ]]; then
        "$CFDD_BIN" service uninstall >/dev/null 2>&1 || true
    fi
    for svc in cloudflared cloudflared-update cgg-quick-tunnel; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    systemctl daemon-reload
    log "旧隧道服务清理完成"
}

# ------------------------------ 固定隧道 --------------------------------------
# 复用本机已有隧道：不重装、不清理现有 cloudflared 服务，只校验回源是否指向本机端口
setup_fixed_tunnel_reuse() {
    local svc="" svc_found=0 input

    printf '\n%s-------- 复用已有隧道检查 --------%s\n' "$C_CYAN" "$C_RESET"

    [[ -x "$CFDD_BIN" ]] || die "未找到 cloudflared：${CFDD_BIN}，无法复用已有隧道"

    for svc in cloudflared cloudflared-update; do
        if systemctl cat "$svc" >/dev/null 2>&1 || [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            svc_found=1
            break
        fi
    done
    if (( svc_found == 0 )); then
        die "未检测到已有的 cloudflared 服务，无法复用；请改选“新建独立隧道”"
    fi

    if systemctl is-active --quiet "$svc"; then
        log "已有隧道服务运行中：${svc}（未做任何改动）"
    else
        warn "已有隧道服务 ${svc} 未运行，请确认：systemctl status ${svc}"
    fi

    if [[ -f "$CFDD_CONFIG_FILE" ]]; then
        if grep -q "http://localhost:${LOCAL_PORT}" "$CFDD_CONFIG_FILE" 2>/dev/null \
            || grep -q "http://127.0.0.1:${LOCAL_PORT}" "$CFDD_CONFIG_FILE" 2>/dev/null; then
            log "现有配置已包含回源：http://localhost:${LOCAL_PORT}"
        else
            warn "现有配置 ${CFDD_CONFIG_FILE} 未指向本机端口 ${LOCAL_PORT}"
            printf '%s请在该文件的 ingress 中补一条（放在 http_status:404 之前）：%s\n' "$C_YELLOW" "$C_RESET"
            printf '  - hostname: 你的域名\n'
            printf '    service: http://localhost:%s\n' "$LOCAL_PORT"
            printf '%s修改后执行 systemctl restart %s。%s\n' "$C_YELLOW" "$svc" "$C_RESET"
        fi
    else
        warn "未找到 ${CFDD_CONFIG_FILE}（Token 托管的隧道在网页端配置回源）"
        printf '%s请在 Cloudflare 控制台 → 该隧道 → Public Hostname 中确认：%s\n' "$C_YELLOW" "$C_RESET"
        printf '    Type : HTTP\n'
        printf '    URL  : http://localhost:%s\n' "$LOCAL_PORT"
    fi

    if [[ -t 0 ]]; then
        read -r -p "请输入该隧道已配置的域名（如 ws.example.com，回车可跳过）：" input || return 0
        input="${input//[[:space:]]/}"
        if [[ -n "$input" ]]; then
            validate_domain "$input" || die "域名格式不合法：${input}"
            TUNNEL_DOMAIN="$input"
            save_info
        fi
    fi
}

setup_fixed_tunnel() {
    # 复用模式走独立分支，避免清理并覆盖本机已有的 cloudflared 服务
    if [[ "$TUNNEL_REUSE" == "1" ]]; then
        setup_fixed_tunnel_reuse
        return 0
    fi

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

    # 重装或从临时隧道切换时先清理旧服务，否则 service install 会报 "already installed"
    cleanup_tunnel_services

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

    # 重装或从固定隧道切换时先清理旧服务，避免旧隧道继续运行
    cleanup_tunnel_services

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
    local link enc_path tunnel_label

    if [[ -z "$TUNNEL_DOMAIN" ]]; then
        warn "尚未记录隧道域名，链接中域名为占位符，配置好后请在总菜单 8 中重新查看"
        TUNNEL_DOMAIN="YOUR_TUNNEL_DOMAIN"
    fi

    if [[ "$TUNNEL_TYPE" == "quick" ]]; then
        tunnel_label="临时隧道（trycloudflare）"
    elif [[ "$TUNNEL_REUSE" == "1" ]]; then
        tunnel_label="固定隧道（复用已有隧道）"
    else
        tunnel_label="固定隧道（新建独立隧道）"
    fi

    enc_path="$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')"
    link="vless://${UUID}@${TUNNEL_DOMAIN}:443?encryption=none&security=tls&sni=${TUNNEL_DOMAIN}&fp=chrome&type=ws&host=${TUNNEL_DOMAIN}&path=${enc_path}#${NODE_NAME}"

    printf '\n%s============ cgg-vless WS + CF Tunnel 节点信息 ============%s\n' "$C_CYAN" "$C_RESET"
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  隧道类型    : %s\n' "$tunnel_label"
    printf '  隧道域名    : %s\n' "$TUNNEL_DOMAIN"
    printf '  客户端端口  : 443（TLS 由 Cloudflare 边缘处理）\n'
    printf '  UUID        : %s\n' "$UUID"
    printf '  传输协议    : ws\n'
    printf '  WS 路径     : %s\n' "$WS_PATH"
    printf '  本地回源    : 127.0.0.1:%s\n' "$LOCAL_PORT"
    printf '  SNI         : %s\n' "$TUNNEL_DOMAIN"
    printf '%s==========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    if [[ "$TUNNEL_TYPE" == "quick" ]]; then
        printf '%s临时隧道：域名每次重启都会变化，总菜单 8 重新查看可获取最新域名；仅建议测试使用。%s\n' "$C_YELLOW" "$C_RESET"
    else
        printf '%s固定隧道：如尚未在网页端配置，请按上方提示添加 Public Hostname（Type: HTTP → URL: http://localhost:%s，需带 http:// 协议头）。%s\n' "$C_YELLOW" "$LOCAL_PORT" "$C_RESET"
    fi
    printf '%s防火墙无需放行任何入站端口，Xray 仅监听 127.0.0.1。%s\n\n' "$C_YELLOW" "$C_RESET"

    printf '%sVLESS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    printf '%s服务管理：systemctl {status|restart|stop} xray%s\n' "$C_CYAN" "$C_RESET"
    if [[ "$TUNNEL_TYPE" == "quick" ]]; then
        printf '%s隧道服务：%s（日志：journalctl -u %s -n 50）%s\n\n' "$C_CYAN" "$QUICK_SERVICE" "$QUICK_SERVICE" "$C_RESET"
    elif [[ "$TUNNEL_REUSE" == "1" ]]; then
        printf '%s隧道服务：systemctl status cloudflared（复用模式，脚本未改动该服务）%s\n\n' "$C_CYAN" "$C_RESET"
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
    prepare_tmpdir
    ensure_swap
    check_memory_headroom

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
