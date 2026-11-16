#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · AnyTLS + TLS 节点（sing-box 后端）
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 用    法：sudo bash cgg-vless-anytls.sh
# 说    明：Xray-core 不支持 AnyTLS，本脚本安装独立 sing-box 后端；
#           配置、服务、元信息均与 Xray 分离，可与现有节点并存（端口不冲突时）
# ==============================================================================
set -euo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly SINGBOX_DIR="/usr/local/etc/sing-box"
readonly CONFIG_FILE="${SINGBOX_DIR}/config.json"
readonly INFO_FILE="${SINGBOX_DIR}/cgg-anytls.info"
readonly CERT_DIR="${SINGBOX_DIR}/cert"
readonly SERVICE_NAME="cgg-anytls"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly XRAY_CERT_DIR="/usr/local/etc/xray/cert"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly RUN_USER="nobody"
readonly RUN_GROUP="nogroup"
readonly DEFAULT_NODE_NAME="cgg-anytls"
# 域名默认值：自签场景下仅作 SNI 伪装，无需真实解析
readonly DEFAULT_DOMAIN="www.bing.com"

# ------------------------------ 运行期变量 ------------------------------------
PORT=""
DOMAIN=""
PASSWORD=""
NODE_NAME=""
CERT_FILE=""
KEY_FILE=""
SERVER_IP=""
# 证书模式：reuse（复用 Xray 证书）/ manual（手动路径）/ selfsigned（自签）
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

check_network() {
    if ! curl -fsS --max-time 10 -o /dev/null https://github.com; then
        warn "GitHub 访问异常，sing-box 下载可能失败"
    fi
}

# 交互环境检查：本脚本必须交互输入域名与证书路径
require_tty() {
    if [[ ! -t 0 ]]; then
        die "本脚本需要交互输入，请在终端中直接运行"
    fi
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

# ------------------------------ 端口检查 --------------------------------------
port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

# ------------------------------ 安装 sing-box ---------------------------------
install_singbox() {
    if [[ -x "$SINGBOX_BIN" ]]; then
        log "检测到已安装 sing-box：$("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装：apt-get install -y curl"
    command -v tar >/dev/null 2>&1 || die "缺少 tar，请先安装：apt-get install -y tar"

    local arch tag ver url tmpdir new_bin
    if ! arch="$(detect_arch)"; then
        die "当前架构不支持自动安装（仅支持 x86_64 / aarch64），请手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    log "获取 sing-box 最新版本..."
    tag="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    if [[ -z "$tag" ]]; then
        die "获取 sing-box 版本失败（GitHub API 不可达），可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    ver="${tag#v}"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmpdir="$(mktemp -d)"

    log "下载 sing-box：${url}"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${tmpdir}/pkg.tar.gz" "$url"; then
        rm -rf "$tmpdir"
        die "sing-box 下载失败，可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    # 流式解压：直接把二进制写到目标位置，不展开整棵目录树。
    # 展开后的二进制约 40MB，临时目录若是 tmpfs 会直接占用内存。
    new_bin="${SINGBOX_BIN}.new"
    if ! tar -xzOf "${tmpdir}/pkg.tar.gz" --wildcards '*/sing-box' > "$new_bin" 2>/dev/null; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "sing-box 压缩包解压失败"
    fi
    if [[ ! -s "$new_bin" ]]; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "压缩包中未找到 sing-box 二进制"
    fi
    chmod 755 "$new_bin" 2>/dev/null || true
    if ! "$new_bin" version >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
        die "下载的 sing-box 无法运行（可能架构不匹配）"
    fi
    if ! mv -f "$new_bin" "$SINGBOX_BIN"; then
        rm -rf "$tmpdir"
        rm -f "$new_bin"
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
        read -r -p "证书域名 / SNI（回车默认 ${DEFAULT_DOMAIN}；CA 证书请填真实域名）：" input
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
    local input
    read -r -p "监听端口（1-65535，回车默认 443）：" input
    input="${input//[[:space:]]/}"
    if [[ -z "$input" ]]; then
        PORT="443"
    elif [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= 65535 )); then
        PORT="$input"
    else
        die "端口不合法：${input}"
    fi

    if port_in_use "$PORT"; then
        die "端口 ${PORT} 已被占用（若为 Xray WS+TLS，请先停止或换端口）"
    fi

    # Xray 配置占用同一端口时，即使服务当前停止也会冲突
    if [[ -f "$XRAY_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        local xport
        while IFS= read -r xport; do
            [[ -n "$xport" ]] || continue
            if [[ "$xport" == "$PORT" ]]; then
                die "端口 ${PORT} 已被 Xray 配置占用，请为 AnyTLS 选择其他端口"
            fi
        done < <(jq -r '.inbounds[]? | .port // empty' "$XRAY_CONFIG" 2>/dev/null || true)
    fi

    log "监听端口：${PORT}"
}

ask_node_name() {
    local input
    NODE_NAME="$DEFAULT_NODE_NAME"
    read -r -p "节点名称（显示在客户端备注，回车默认 ${DEFAULT_NODE_NAME}）：" input
    # 去掉分隔符与空白，避免破坏 anytls:// 链接格式
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    if [[ -n "$input" ]]; then
        NODE_NAME="$input"
    fi
    log "节点名称：${NODE_NAME}"
}

# ------------------------------ 证书处理 --------------------------------------
fix_key_permission() {
    local key="$1"
    chown root:"$RUN_GROUP" "$key" 2>/dev/null || warn "无法修改私钥属组：${key}"
    chmod 640 "$key" 2>/dev/null || warn "无法修改私钥权限：${key}"
}

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
    fix_key_permission "${CERT_DIR}/privkey.pem"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    CERT_MODE="manual"
    log "证书已复制到：${CERT_DIR}"
}

# 生成自签证书：客户端需开启“跳过证书验证 / allowInsecure”
setup_cert_selfsigned() {
    command -v openssl >/dev/null 2>&1 || die "缺少 openssl，无法生成自签证书，请先安装：apt-get install -y openssl"

    install -d -m 755 -o root -g root "$CERT_DIR"
    log "生成自签证书（CN=${DOMAIN}，有效期 3650 天）..."
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "${CERT_DIR}/privkey.pem" \
        -out "${CERT_DIR}/fullchain.pem" \
        -days 3650 -subj "/CN=${DOMAIN}" >/dev/null 2>&1; then
        die "自签证书生成失败"
    fi
    chmod 644 "${CERT_DIR}/fullchain.pem"
    fix_key_permission "${CERT_DIR}/privkey.pem"

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
                CERT_FILE="${XRAY_CERT_DIR}/fullchain.pem"
                KEY_FILE="${XRAY_CERT_DIR}/privkey.pem"
                CERT_MODE="reuse"
                fix_key_permission "$KEY_FILE"
                log "使用已有证书：${CERT_FILE}"
                ;;
        esac
        return 0
    fi

    warn "未检测到 ${XRAY_CERT_DIR} 下的证书"
    printf '  1) 手动输入证书文件路径（.cer / .key）\n'
    printf '  2) 生成自签证书（客户端需跳过证书验证）\n'
    printf '  3) 取消，先去总菜单第 12 项申请证书\n'
    read -r -p "请选择 [1-3]：" ans
    case "$ans" in
        1) setup_cert_manual ;;
        2) setup_cert_selfsigned ;;
        *) die "已取消：请先在总菜单第 12 项申请证书，或准备好证书文件后重跑" ;;
    esac
}

# ------------------------------ 密码生成 --------------------------------------
gen_password() {
    PASSWORD="$(openssl rand -hex 16 2>/dev/null || true)"
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' || true)"
    fi
    [[ ${#PASSWORD} -eq 32 ]] || die "AnyTLS 密码生成失败"
    log "AnyTLS 密码生成完成"
}

# ------------------------------ 配置写入 --------------------------------------
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
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "cgg",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # sing-box 以 nobody 运行，配置需属组可读（含密码，仍限制其他用户）
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || warn "无法修改配置属组：${CONFIG_FILE}"
    chmod 640 "$CONFIG_FILE"

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE"; then
        die "sing-box 配置校验失败，未启动服务"
    fi
    log "配置写入并校验通过：${CONFIG_FILE}"
}

# ------------------------------ systemd 服务 ----------------------------------
write_service() {
    if [[ -f "$SERVICE_FILE" ]] && ! grep -q "cgg-anytls" "$SERVICE_FILE"; then
        local backup="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$SERVICE_FILE" "$backup"
        log "旧服务文件已备份：${backup}"
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless AnyTLS Service (sing-box)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
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
    elif ! command -v ufw >/dev/null 2>&1; then
        warn "未检测到 UFW / iptables，请手动放行 ${PORT}/tcp"
    fi
}

# ------------------------------ 元信息 ----------------------------------------
save_info() {
    install -d -m 755 -o root -g root "$SINGBOX_DIR"
    {
        printf 'MODE=anytls\n'
        printf 'PORT=%s\n' "$PORT"
        printf 'DOMAIN=%s\n' "$DOMAIN"
        printf 'PASSWORD=%s\n' "$PASSWORD"
        printf 'NODE_NAME=%s\n' "$NODE_NAME"
        printf 'CERT_MODE=%s\n' "$CERT_MODE"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# ------------------------------ 输出结果 --------------------------------------
print_result() {
    local ip link
    ip="${SERVER_IP:-YOUR_SERVER_IP}"
    # 自签证书需客户端跳过证书验证，链接带 insecure=1
    link="anytls://${PASSWORD}@$(format_host "$ip"):${PORT}?security=tls&sni=${DOMAIN}&fp=chrome"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        link="${link}&insecure=1"
    fi
    link="${link}#${NODE_NAME}"

    printf '\n%s================= cgg-vless AnyTLS 节点 =================%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : AnyTLS + TLS（sing-box）\n'
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  端口        : %s\n' "$PORT"
    printf '  域名 / SNI  : %s\n' "$DOMAIN"
    printf '  密码        : %s\n' "$PASSWORD"
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    printf '%sAnyTLS 分享链接：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    printf '%s提示：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - 客户端需支持 AnyTLS：sing-box 系客户端直接支持；v2rayN 需切换到 sing-box 内核\n'
    printf '  - AnyTLS 为原始 TCP + TLS，无法套 Cloudflare CDN，需客户端直连\n'
    printf '  - NAT 机器需在服务商面板把外部端口 %s 映射到容器内部端口 %s\n' "$PORT" "$PORT"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        printf '  - 当前为自签证书，客户端必须开启「跳过证书验证 / allowInsecure」\n'
    fi
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    check_os
    require_tty
    check_network
    prepare_tmpdir
    ensure_swap
    check_memory_headroom

    printf '\n%s========== cgg-vless · AnyTLS + TLS（sing-box）==========%s\n\n' "$C_MAGENTA" "$C_RESET"
    warn "Xray-core 不支持 AnyTLS，本脚本将安装独立 sing-box 后端，与现有 Xray 节点并存"

    ask_domain
    ask_port
    ask_node_name
    ask_cert_source
    gen_password

    install_singbox
    write_config
    write_service
    configure_firewall
    save_info

    SERVER_IP="$(get_public_ip)"
    print_result
    log "安装完成"
}

main "$@"
