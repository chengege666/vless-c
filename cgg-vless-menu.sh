#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · VLESS + XTLS-Reality 管理脚本（菜单版）
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-menu.sh
# 说    明：【历史脚本 · 仅保留兼容】功能已被 vless-c.sh 总菜单完全覆盖
#           （总菜单第 1 项 = Reality 安装，第 11/12/13 项 = 改配置 / 证书 / 卸载）。
#           本文件不随功能演进同步修改（新功能一律只进 vless-c.sh），
#           仅同步修复类改动（如低内存环境的流式解压）。
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly XRAY_BIN="/usr/local/bin/xray"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly INFO_FILE="${CONFIG_DIR}/cgg-vless.info"
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly LOG_DIR="/var/log/xray"
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

trap 'err "操作失败（行号：$LINENO，退出码：$?）"' ERR

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
# 但内核禁用 IPv6 时绑 :: 会直接失败，bindv6only=1 时绑 :: 会丢掉 IPv4，
# 所以不写死，按内核实际能力探测。
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
    printf '%s               cgg-vless · VLESS Reality 管理脚本%s\n\n' "$C_MAGENTA" "$C_RESET"
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
    fi

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
    elif [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
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
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        die "Xray 安装完成但无法运行（可能架构不匹配或缺少系统库），请按上方提示排查"
    fi
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
    log "ShortID 生成完成"
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

    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"
    save_info

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

# 保存节点元信息，供「查看配置」快速读取
save_info() {
    {
        printf 'PORT=%s\n' "$PORT"
        printf 'UUID=%s\n' "$UUID"
        printf 'SNI=%s\n' "$SNI"
        printf 'PUBLIC_KEY=%s\n' "$PUBLIC_KEY"
        printf 'SHORT_ID=%s\n' "$SHORT_ID"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
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

restart_service_quiet() {
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || warn "设置开机自启失败"
    systemctl restart xray || true
    sleep 1
    if ! systemctl is-active --quiet xray; then
        err "Xray 启动失败，最近日志如下："
        journalctl -u xray -n 20 --no-pager >&2 || true
        return 1
    fi
    return 0
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
        log "iptables 已放行端口 ${PORT}/tcp"
        return 0
    fi

    warn "未检测到 UFW / iptables，请手动放行 ${PORT}/tcp"
}

# ------------------------------ BBR -------------------------------------------
maybe_enable_bbr() {
    local cc ans
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    if [[ "$cc" == "bbr" ]]; then
        log "BBR 已启用"
        return 0
    fi

    warn "当前拥塞控制算法：${cc}（未启用 BBR）"
    [[ -t 0 ]] || { warn "非交互模式，跳过 BBR 设置"; return 0; }

    read -r -p "是否开启 BBR 加速？[y/N]：" ans
    case "$ans" in
        [Yy]*)
            modprobe tcp_bbr >/dev/null 2>&1 || warn "无法加载 tcp_bbr 模块，可能内核不支持"
            printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' \
                > /etc/sysctl.d/99-cgg-bbr.conf
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
            log "BBR 配置已写入"
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

# ------------------------------ 读取现有配置 ----------------------------------
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || { err "缺少 jq，请先安装 jq"; return 1; }

    PORT="$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE")"
    UUID="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONFIG_FILE")"
    SNI="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE")"
    PRIVATE_KEY="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")"
    SHORT_ID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$CONFIG_FILE")"

    [[ -n "$PORT" && -n "$UUID" && -n "$SNI" && -n "$PRIVATE_KEY" && -n "$SHORT_ID" ]] || return 1

    # 优先读取安装时保存的公钥
    PUBLIC_KEY=""
    if [[ -f "$INFO_FILE" ]]; then
        # shellcheck disable=SC1090
        PUBLIC_KEY="$(. "$INFO_FILE" >/dev/null 2>&1; printf '%s' "${PUBLIC_KEY:-}")"
    fi

    # 元信息缺失时，由私钥重新推导公钥
    if [[ -z "$PUBLIC_KEY" ]]; then
        local out=""
        out="$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>&1 || true)"
        PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F: 'tolower($1) ~ /password|public/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    fi
    [[ -n "$PUBLIC_KEY" ]] || return 1
    return 0
}

print_link() {
    local link ip
    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    link="vless://${UUID}@$(format_host "$ip"):${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality"

    printf '\n%s================= cgg-vless 节点信息 =================%s\n' "$C_CYAN" "$C_RESET"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$PORT"
    printf '  UUID        : %s\n' "$UUID"
    printf '  流控 flow   : xtls-rprx-vision\n'
    printf '  公钥 pbk    : %s\n' "$PUBLIC_KEY"
    printf '  ShortID     : %s\n' "$SHORT_ID"
    printf '  伪装域名SNI : %s\n' "$SNI"
    printf '  传输协议    : tcp\n'
    printf '  安全类型    : reality\n'
    printf '%s======================================================%s\n\n' "$C_CYAN" "$C_RESET"

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
}

# ------------------------------ 功能：查看信息 --------------------------------
show_info() {
    if ! load_config; then
        err "未找到有效配置，请先执行安装"
        return 1
    fi
    SERVER_IP="$(get_public_ip)"
    print_link

    if systemctl is-active --quiet xray 2>/dev/null; then
        log "服务状态：运行中"
    else
        warn "服务状态：未运行"
    fi
    printf '%s配置文件：%s%s\n\n' "$C_CYAN" "$CONFIG_FILE" "$C_RESET"
}

# ------------------------------ 功能：全新安装 --------------------------------
install_node() {
    log "开始全新安装 VLESS + Reality"
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

    if ! restart_service_quiet; then
        err "服务启动失败，安装未完成"
        return 1
    fi
    log "Xray 已启动，并已设置开机自启"

    configure_firewall
    maybe_enable_bbr

    SERVER_IP="$(get_public_ip)"
    print_link
}

# ------------------------------ 功能：启动/停止 --------------------------------
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
    elif systemctl is-active --quiet xray; then
        log "Xray 已${action}完成，当前状态：运行中"
    else
        err "Xray ${action} 后未处于运行状态，请查看日志"
        return 1
    fi
}

# ------------------------------ 功能：修改 SNI --------------------------------
change_sni() {
    if ! load_config; then
        err "未找到有效配置，请先执行安装"
        return 1
    fi

    local input tmp
    read -r -p "请输入新的伪装域名（当前 ${SNI}）：" input
    input="${input//[[:space:]]/}"
    [[ -n "$input" ]] || { warn "输入为空，已取消"; return 1; }
    validate_domain "$input" || { err "域名格式不合法：${input}"; return 1; }

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
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"

    SNI="$input"
    save_info
    require_restart_after_change
}

# ------------------------------ 功能：重置 UUID -------------------------------
reset_uuid() {
    if ! load_config; then
        err "未找到有效配置，请先执行安装"
        return 1
    fi

    local ans tmp
    read -r -p "确认重置 UUID？旧 UUID 将立即失效 [y/N]：" ans
    case "$ans" in
        [Yy]*) ;;
        *) warn "已取消"; return 1 ;;
    esac

    local new_uuid
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
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE"

    UUID="$new_uuid"
    save_info
    log "UUID 已重置：${UUID}"
    require_restart_after_change
}

require_restart_after_change() {
    local ans
    read -r -p "配置已更新，是否立即重启 Xray 生效？[Y/n]：" ans
    case "$ans" in
        [Nn]*)
            warn "已跳过重启，请稍后手动执行：systemctl restart xray"
            ;;
        *)
            if restart_service_quiet; then
                log "Xray 已重启生效"
            else
                err "Xray 重启失败，可使用备份配置回滚"
            fi
            ;;
    esac

    if load_config; then
        SERVER_IP="$(get_public_ip)"
        print_link
    fi
}

# ------------------------------ 功能：彻底卸载 --------------------------------
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

    log "卸载完成（防火墙放行规则未自动删除，如有需要请手动清理）"
}

# ------------------------------ 菜单 ------------------------------------------
show_menu() {
    printf '%s==================== 功能菜单 ====================%s\n' "$C_MAGENTA" "$C_RESET"
    printf '  1) 安装 VLESS-Reality 节点\n'
    printf '  2) 查看当前节点配置与连接链接\n'
    printf '  3) 启动 Xray 服务\n'
    printf '  4) 停止 Xray 服务\n'
    printf '  5) 重启 Xray 服务\n'
    printf '  6) 修改配置（更换 SNI / 重置 UUID）\n'
    printf '  7) 一键彻底卸载\n'
    printf '  0) 退出\n'
    printf '%s==================================================%s\n' "$C_MAGENTA" "$C_RESET"
}

modify_menu() {
    local choice
    while true; do
        printf '\n%s-------- 修改配置 --------%s\n' "$C_CYAN" "$C_RESET"
        printf '  1) 更换伪装域名 SNI\n'
        printf '  2) 重置 UUID\n'
        printf '  0) 返回主菜单\n'
        read -r -p "请选择 [0-2]：" choice || return 0
        case "$choice" in
            1) change_sni || true ;;
            2) reset_uuid || true ;;
            0) return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
    done
}

main_menu() {
    require_root
    show_banner
    check_os
    detect_runtime_user
    prepare_tmpdir
    ensure_swap
    check_memory_headroom

    local choice
    while true; do
        show_menu
        if ! read -r -p "请选择 [0-7]：" choice; then
            printf '\n'
            return 0
        fi
        case "$choice" in
            1) install_node || true ;;
            2) show_info || true ;;
            3) service_action start || true ;;
            4) service_action stop || true ;;
            5) service_action restart || true ;;
            6) modify_menu ;;
            7) uninstall_all || true ;;
            0) log "已退出"; return 0 ;;
            *) warn "无效选项：${choice}" ;;
        esac
        printf '\n'
    done
}

main_menu "$@"

