#!/usr/bin/env bash
# ==============================================================================
# cgg-vless · Hysteria 2 节点（sing-box 后端）
# 适用系统：Ubuntu 20.04+ / Debian 11+（x86_64 / ARM64）
# 用    法：sudo bash cgg-vless-hysteria2.sh
# 说    明：Xray-core 不支持 Hysteria 2，本脚本复用 sing-box 后端；
#           配置、服务、元信息均与 Xray / AnyTLS 分离，可与现有节点并存
# 规范依据：
#   - Hysteria 2 URI 官方规范 https://v2.hysteria.network/docs/developers/URI-Scheme/
#     端口跳跃使用 URI 端口字段的多端口格式（如 :443,20000-30000），
#     不使用非官方的 mport / alpn / allowInsecure 参数
#   - sing-box hysteria2 入站 https://sing-box.sagernet.org/configuration/inbound/hysteria2/
# ==============================================================================
set -Eeuo pipefail

# ------------------------------ 基础常量 --------------------------------------
readonly SINGBOX_BIN="/usr/local/bin/sing-box"
readonly SINGBOX_DIR="/usr/local/etc/sing-box"
readonly CONFIG_FILE="${SINGBOX_DIR}/hysteria2.json"
readonly INFO_FILE="${SINGBOX_DIR}/cgg-hysteria2.info"
readonly CERT_DIR="${SINGBOX_DIR}/cert-hysteria2"
readonly ANYTLS_CONFIG="${SINGBOX_DIR}/config.json"
readonly SERVICE_NAME="cgg-hysteria2"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly HOP_SCRIPT="${SINGBOX_DIR}/port-hopping.sh"
readonly HOP_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}-hop.service"
readonly XRAY_CERT_DIR="/usr/local/etc/xray/cert"
readonly RUN_USER="nobody"
readonly RUN_GROUP="nogroup"
readonly DEFAULT_NODE_NAME="cgg-hysteria2"
readonly DEFAULT_DOMAIN="cloud.tencent.com"
# 服务文件与防火墙规则的归属标记，用于识别“是否本脚本创建”，禁止误删他人规则
readonly SERVICE_MARKER="cgg-hysteria2"
readonly FW_COMMENT="cgg-hysteria2"
# hysteria2 入站自 sing-box 1.2.0 起支持
readonly MIN_SINGBOX_VERSION="1.2.0"

# ------------------------------ 运行期变量 ------------------------------------
PORT=""
DOMAIN=""
PASSWORD=""
NODE_NAME=""
CERT_FILE=""
KEY_FILE=""
SERVER_IP=""
IP_UNCONFIRMED=0            # 公网地址未能自动确认、由用户手动填写或占位
CERT_SOURCE=""              # selfsign / xray / manual
HOP_PORTS=()                # 端口跳跃项（单个端口或 起始-结束）
HOP_SPEC=""                 # URI 端口字段追加部分，逗号分隔
CFG_BACKUP=""               # 本次运行生成的旧配置备份，供回滚
SVC_BACKUP=""               # 本次运行生成的旧服务文件备份，供回滚
declare -a _TMP_DIRS=()     # 已登记的临时目录，退出时统一清理

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

# ------------------------------ 临时目录与陷阱 --------------------------------
mk_tmpdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/cgg-hy2.XXXXXX")" || die "无法创建临时目录"
    _TMP_DIRS+=("$d")
    printf '%s' "$d"
}

cleanup_tmpdirs() {
    local d
    for d in "${_TMP_DIRS[@]:-}"; do
        if [[ -n "$d" && -d "$d" ]]; then
            rm -rf -- "$d" || true
        fi
    done
    return 0
}

on_exit() {
    local rc=$?
    cleanup_tmpdirs || true
    return "$rc"
}

trap 'err "操作失败（行号：$LINENO，退出码：$?）"' ERR
trap 'warn "收到中断信号，正在清理..."; exit 130' INT TERM
trap on_exit EXIT

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

# 安装前检查必要依赖：缺少任何一项都直接影响安装结果或安全校验
check_dependencies() {
    local missing=()
    local dep
    for dep in curl tar openssl awk sed grep sort; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if (( ${#missing[@]} > 0 )); then
        die "缺少必要命令：${missing[*]}，请先执行：apt-get install -y ${missing[*]}"
    fi
    # 端口占用检测至少需要一个工具
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        die "缺少 ss（iproute2）与 netstat（net-tools），无法进行 UDP 端口冲突检测，请先安装：apt-get install -y iproute2"
    fi
}

check_network() {
    if ! curl -fsS --max-time 10 -o /dev/null https://github.com; then
        warn "GitHub 访问异常，sing-box 下载可能失败"
    fi
}

# 交互环境检查：本脚本必须交互输入端口与节点名称
require_tty() {
    if [[ ! -t 0 ]]; then
        die "本脚本需要交互输入，请在终端中直接运行"
    fi
}

# ------------------------------ IPv4 与公网 IP --------------------------------
is_ipv4() {
    local ip="$1" o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1="$((10#${BASH_REMATCH[1]}))"; o2="$((10#${BASH_REMATCH[2]}))"
    o3="$((10#${BASH_REMATCH[3]}))"; o4="$((10#${BASH_REMATCH[4]}))"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 ))
}

# 内网 / 保留 / 链路本地 / CGNAT 地址不能作为对外分享地址
is_private_ipv4() {
    local ip="$1" o1 o2
    is_ipv4 "$ip" || return 0
    o1="${ip%%.*}"
    o2="${ip#*.}"; o2="${o2%%.*}"
    case "$o1" in
        0|10|127) return 0 ;;
        100) (( o2 >= 64 && o2 <= 127 )) && return 0 ;;   # CGNAT 100.64.0.0/10
        169) (( o2 == 254 )) && return 0 ;;               # 链路本地
        172) (( o2 >= 16 && o2 <= 31 )) && return 0 ;;    # RFC1918
        192) (( o2 == 168 )) && return 0 ;;               # RFC1918
        198) (( o2 >= 18 && o2 <= 19 )) && return 0 ;;    # 基准测试
        224|225|226|227|228|229|230|231) return 0 ;;      # 组播
        232|233|234|235|236|237|238|239) return 0 ;;      # 组播
        240|241|242|243|244|245|246|247) return 0 ;;      # 保留
        248|249|250|251|252|253) return 0 ;;              # 保留
        254|255) return 0 ;;                              # 保留/广播
    esac
    return 1
}

# 仅接受严格 IPv4 格式且为公网地址的结果，杜绝 IPv6 / 内网误判
get_public_ip() {
    local ip="" src
    for src in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip" \
        "https://ipinfo.io/ip"
    do
        ip="$(curl -fsS4 --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]' || true)"
        if is_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# 公网地址获取失败时允许手动填写 IPv4 或域名；均不可确认时使用占位并明确警告
ask_server_addr() {
    local input
    if SERVER_IP="$(get_public_ip)"; then
        log "公网 IPv4：${SERVER_IP}"
        return 0
    fi
    warn "无法自动确认公网 IPv4 地址"
    while true; do
        read -r -p "请手动输入公网 IPv4 或域名（回车 = 使用占位符 YOUR_SERVER_IP，稍后自行替换）：" input
        input="${input//[[:space:]]/}"
        if [[ -z "$input" ]]; then
            SERVER_IP="YOUR_SERVER_IP"
            IP_UNCONFIRMED=1
            warn "分享链接中的服务器地址未确认，使用前必须替换为真实公网地址"
            return 0
        fi
        if is_ipv4 "$input" && is_private_ipv4 "$input"; then
            warn "${input} 是内网/保留地址，不能作为公网分享地址"
            continue
        fi
        if is_ipv4 "$input" || validate_domain "$input"; then
            SERVER_IP="$input"
            IP_UNCONFIRMED=1
            log "使用手动填写的地址：${SERVER_IP}（未经自动确认）"
            return 0
        fi
        warn "格式不合法（需为 IPv4 或域名）：${input}"
    done
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

# ------------------------------ UDP 端口占用 ----------------------------------
# 一次性列出全部监听中的 UDP 端口（IPv4/IPv6 均计入，保守判占用）
listen_udp_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lun 2>/dev/null | awk '{print $4}' \
            | sed -E 's/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lun 2>/dev/null | awk 'NR>2 {print $4}' \
            | sed -E 's/.*[.:]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -un
    fi
}

# 判断区间 [s,e] 是否与任一监听端口冲突；输出冲突端口号
port_range_conflict() {
    local s="$1" e="$2" p
    while read -r p; do
        [[ -n "$p" ]] || continue
        if (( p >= s && p <= e )); then
            printf '%s' "$p"
            return 0
        fi
    done < <(listen_udp_ports)
    return 1
}

# ------------------------------ sing-box 版本 ---------------------------------
singbox_installed_version() {
    "$SINGBOX_BIN" version 2>/dev/null | head -n 1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

# 版本比较：$1 >= $2 时返回 0（仅比较 major.minor.patch 数值）
version_ge() {
    local av bv i
    local -a ap bp
    IFS=. read -r -a ap <<< "$1"
    IFS=. read -r -a bp <<< "$2"
    for i in 0 1 2; do
        av="${ap[$i]:-0}"; bv="${bp[$i]:-0}"
        av="${av//[!0-9]/}"; bv="${bv//[!0-9]/}"
        av=$((10#${av:-0})); bv=$((10#${bv:-0}))
        (( av > bv )) && return 0
        (( av < bv )) && return 1
    done
    return 0
}

singbox_supports_hysteria2() {
    local v
    v="$(singbox_installed_version)"
    [[ -n "$v" ]] || return 1
    version_ge "$v" "$MIN_SINGBOX_VERSION"
}

# ------------------------------ 安装 sing-box ---------------------------------
# 从官方 GitHub Release 下载，并优先使用 GitHub API 提供的 sha256 digest 校验；
# 已安装时只复用、绝不覆盖（AnyTLS 等服务可能共用同一二进制）
install_singbox() {
    if [[ -x "$SINGBOX_BIN" ]]; then
        local cur
        cur="$(singbox_installed_version)"
        if ! singbox_supports_hysteria2; then
            die "已安装的 sing-box 版本 ${cur:-未知} 不支持 hysteria2 入站（需 >= ${MIN_SINGBOX_VERSION}）。为避免破坏共用该二进制的其他服务，本脚本不会自动覆盖，请手动升级 ${SINGBOX_BIN} 后重跑"
        fi
        log "检测到已安装 sing-box：$("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
        return 0
    fi

    local arch tag url digest asset ver tmpdir extracted actual flat ans
    local api_ok=1
    if ! arch="$(detect_arch)"; then
        die "当前架构不支持自动安装（仅支持 x86_64 / aarch64），请手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    log "获取 sing-box 最新版本..."
    tmpdir="$(mk_tmpdir)"
    tag=""; url=""; digest=""
    if ! curl -fsSL --retry 3 --connect-timeout 15 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        -o "${tmpdir}/release.json"; then
        # API 不可达时，通过 releases/latest 的重定向地址解析最新版本号
        warn "GitHub API 请求失败，尝试通过重定向解析最新版本..."
        api_ok=0
        tag="$(curl -fsSLI -o /dev/null --max-time 15 \
            -w '%{url_effective}' \
            https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
            | sed 's#.*/tag/##' || true)"
        if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            rm -rf "$tmpdir"
            die "获取 sing-box 版本信息失败（GitHub API 与重定向均不可达），可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
        fi
    fi

    # 解析 tag：优先 jq / python3；正则回退时 GitHub API 可能返回带缩进的多行 JSON，
    # 需先压平为单行再匹配，并容忍冒号两侧空格
    if (( api_ok == 1 )); then
        if command -v jq >/dev/null 2>&1; then
            tag="$(jq -r '.tag_name // empty' "${tmpdir}/release.json" 2>/dev/null || true)"
        elif command -v python3 >/dev/null 2>&1; then
            tag="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("tag_name",""))' "${tmpdir}/release.json" 2>/dev/null || true)"
        fi
        if [[ -z "$tag" ]]; then
            flat="$(tr -d '[:space:]' < "${tmpdir}/release.json" 2>/dev/null || true)"
            tag="$(printf '%s' "$flat" \
                | grep -o '"tag_name":"[^"]*"' | head -n 1 | sed 's/.*:"//;s/"$//' || true)"
        fi
        if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            local snippet
            snippet="$(head -c 160 "${tmpdir}/release.json" 2>/dev/null | tr -d '\r\n' || true)"
            rm -rf "$tmpdir"
            die "解析 sing-box 版本信息失败（GitHub API 返回异常，响应开头：${snippet:-空响应}），可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
        fi
    fi

    ver="${tag#v}"
    asset="sing-box-${ver}-linux-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset}"

    # digest 解析：jq / python3 优先；正则回退用压平后的单行 + grep -P 非贪婪匹配
    if (( api_ok == 1 )); then
        if command -v jq >/dev/null 2>&1; then
            digest="$(jq -r --arg n "$asset" '.assets[]?|select(.name==$n)|.digest // empty' "${tmpdir}/release.json" 2>/dev/null || true)"
        elif command -v python3 >/dev/null 2>&1; then
            digest="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for a in d.get("assets",[]):
    if a.get("name")==sys.argv[2]:
        print(a.get("digest") or "");break' "${tmpdir}/release.json" "$asset" 2>/dev/null || true)"
        else
            flat="${flat:-$(tr -d '[:space:]' < "${tmpdir}/release.json" 2>/dev/null || true)}"
            digest="$(printf '%s' "$flat" \
                | grep -oP "\"name\":\"$asset\".{0,3000}?\"digest\":\"sha256:[0-9a-f]+\"" 2>/dev/null \
                | grep -o 'sha256:[0-9a-f]*' | head -n 1 || true)"
        fi
        digest="${digest#sha256:}"
    fi

    # 无法获得官方摘要时必须显式征得用户同意，不得静默跳过完整性校验
    if [[ -z "$digest" ]]; then
        warn "无法从 GitHub API 获取 ${asset} 的官方 SHA256 摘要"
        warn "跳过完整性校验存在下载文件被篡改的风险"
        read -r -p "是否在不进行 SHA256 校验的情况下继续下载？[y/N]：" ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            rm -rf "$tmpdir"
            die "用户取消：请安装 jq（apt-get install -y jq）后重跑，或手动下载 sing-box 放到 ${SINGBOX_BIN}"
        fi
    fi

    log "下载 sing-box：${url}"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${tmpdir}/${asset}" "$url"; then
        rm -rf "$tmpdir"
        die "sing-box 下载失败，可手动下载 sing-box 放到 ${SINGBOX_BIN} 后重跑"
    fi

    # 官方 SHA256 完整性校验（仅在取得官方摘要时执行）
    if [[ -n "$digest" ]]; then
        actual="$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')"
        if [[ "${actual,,}" != "${digest,,}" ]]; then
            rm -rf "$tmpdir"
            die "sing-box 下载文件 SHA256 校验不通过（期望 ${digest}，实际 ${actual}），已拒绝安装"
        fi
        log "SHA256 校验通过"
    else
        warn "已按用户确认跳过 SHA256 校验"
    fi

    if ! tar -xzf "${tmpdir}/${asset}" -C "$tmpdir"; then
        rm -rf "$tmpdir"
        die "sing-box 压缩包解压失败"
    fi

    extracted="$(find "$tmpdir" -type f -name sing-box 2>/dev/null | head -n 1 || true)"
    if [[ -z "$extracted" ]]; then
        rm -rf "$tmpdir"
        die "压缩包中未找到 sing-box 二进制"
    fi

    if ! "$extracted" version >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        die "下载的 sing-box 无法运行（可能架构不匹配或系统库不兼容）"
    fi

    if ! install -m 755 "$extracted" "$SINGBOX_BIN"; then
        rm -rf "$tmpdir"
        die "安装 sing-box 到 ${SINGBOX_BIN} 失败"
    fi
    rm -rf "$tmpdir"
    _TMP_DIRS=("${_TMP_DIRS[@]//$tmpdir/}")

    "$SINGBOX_BIN" version >/dev/null 2>&1 || die "sing-box 安装后无法运行"
    if ! singbox_supports_hysteria2; then
        die "安装后的 sing-box 版本仍不支持 hysteria2，请检查版本：$("$SINGBOX_BIN" version 2>/dev/null | head -n 1)"
    fi
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
        read -r -p "证书域名 / SNI（自签回车默认 ${DEFAULT_DOMAIN}）：" input
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

# 校验单个端口或端口范围，成功时输出归一化值
normalize_port_token() {
    local t="$1"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        (( 10#$t >= 1 && 10#$t <= 65535 )) || return 1
        printf '%d\n' "$((10#$t))"
        return 0
    fi
    if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local s="$((10#${BASH_REMATCH[1]}))"
        local e="$((10#${BASH_REMATCH[2]}))"
        (( s >= 1 && s <= 65535 && e >= 1 && e <= 65535 )) || return 1
        (( s < e )) || return 1
        printf '%d-%d\n' "$s" "$e"
        return 0
    fi
    return 1
}

# 将端口项展开为区间 “start end”，单端口输出 “p p”
port_item_to_range() {
    local item="$1"
    if [[ "$item" == *-* ]]; then
        printf '%s %s\n' "${item%%-*}" "${item##*-}"
    else
        printf '%s %s\n' "$item" "$item"
    fi
}

# 检查跳跃项列表：重复端口、范围交叉重叠，违规直接终止
check_hop_overlaps() {
    local -a items=("$@")
    local -a ranges=()
    local item s e
    declare -A seen_single=()
    for item in "${items[@]}"; do
        if [[ "$item" != *-* ]]; then
            [[ -z "${seen_single[$item]:-}" ]] || die "端口跳跃存在重复端口：${item}"
            seen_single["$item"]=1
        fi
        read -r s e <<< "$(port_item_to_range "$item")"
        ranges+=("$(printf '%05d %05d %s' "$s" "$e" "$item")")
    done
    # 排序后检查相邻区间是否交叉（含端点）
    local prev_e="" prev_item=""
    while read -r s e item; do
        s="$((10#$s))"; e="$((10#$e))"
        if [[ -n "$prev_item" ]] && (( s <= prev_e )); then
            die "端口跳跃区间重叠：${prev_item} 与 ${item}"
        fi
        prev_item="$item"
        prev_e="$e"
    done < <(printf '%s\n' "${ranges[@]}" | sort)
}

ask_port() {
    local input token norm item s e p
    local -a tokens=() norm_tokens=()

    HOP_PORTS=()
    HOP_SPEC=""

    read -r -p "UDP 监听端口（回车默认 443；端口跳跃输入多个，空格分隔，第一个为主端口，支持 起始-结束 范围）：" input
    input="${input//$'\t'/ }"
    read -r -a tokens <<< "$input"

    for token in "${tokens[@]}"; do
        [[ -n "$token" ]] || continue
        norm="$(normalize_port_token "$token")" || die "端口不合法：${token}（支持 1-65535 内的单个端口或 起始-结束 范围）"
        norm_tokens+=("$norm")
    done

    if (( ${#norm_tokens[@]} == 0 )); then
        PORT="443"
    else
        PORT="${norm_tokens[0]}"
        if [[ "$PORT" == *-* ]]; then
            die "第一个端口必须是主监听端口（单个端口），不能是范围：${PORT}"
        fi
    fi

    # 跳跃项：禁止与主端口相同 / 被跳跃范围包含
    for item in "${norm_tokens[@]:1}"; do
        if [[ "$item" == *-* ]]; then
            s="${item%%-*}"
            e="${item##*-}"
            if (( 10#$PORT >= 10#$s && 10#$PORT <= 10#$e )); then
                die "端口跳跃范围 ${item} 包含主端口 ${PORT}，请去掉主端口"
            fi
        elif [[ "$item" == "$PORT" ]]; then
            die "端口跳跃端口不能与主端口相同：${item}"
        fi
        HOP_PORTS+=("$item")
    done

    # 跳跃项之间：重复端口与范围交叉检测
    if (( ${#HOP_PORTS[@]} > 0 )); then
        check_hop_overlaps "${HOP_PORTS[@]}"
        HOP_SPEC="$(printf '%s,' "${HOP_PORTS[@]}")"
        HOP_SPEC="${HOP_SPEC%,}"
    fi

    # UDP 占用检测：主端口 + 全部跳跃区间（含范围逐点比对）
    read -r s e <<< "$(port_item_to_range "$PORT")"
    if p="$(port_range_conflict "$s" "$e")"; then
        die "UDP 端口 ${PORT} 已被占用（监听端口 ${p}），请为 Hysteria 2 选择其他端口"
    fi
    for item in "${HOP_PORTS[@]}"; do
        read -r s e <<< "$(port_item_to_range "$item")"
        if p="$(port_range_conflict "$s" "$e")"; then
            die "端口跳跃 ${item} 与已监听 UDP 端口 ${p} 冲突，REDIRECT 会中断该服务，请调整"
        fi
    done

    # AnyTLS 为 TCP，同号端口本质可共存，仅提示避免误判
    if [[ -f "$ANYTLS_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        local aport
        aport="$(jq -r '.inbounds[0].listen_port // empty' "$ANYTLS_CONFIG" 2>/dev/null || true)"
        if [[ -n "$aport" && "$aport" == "$PORT" ]]; then
            warn "端口 ${PORT} 与 AnyTLS 相同：TCP/UDP 可共存，若客户端异常请改用其他端口"
        fi
    fi

    log "UDP 监听端口：${PORT}"
    if [[ -n "$HOP_SPEC" ]]; then
        log "端口跳跃：${HOP_SPEC} -> ${PORT}/udp"
    fi
}

ask_node_name() {
    local input
    NODE_NAME="$DEFAULT_NODE_NAME"
    read -r -p "节点名称（显示在客户端备注，回车默认 ${DEFAULT_NODE_NAME}）：" input
    # 去掉分隔符与空白，避免破坏 hysteria2:// 链接格式（URI Fragment 仍会做百分号编码）
    input="${input//[#?&%/]/}"
    input="${input// /_}"
    if [[ -n "$input" ]]; then
        NODE_NAME="$input"
    fi
    log "节点名称：${NODE_NAME}"
}

# ------------------------------ 证书处理 --------------------------------------
# 仅作用于本脚本管理目录内的文件，绝不修改 Xray 原始证书
fix_key_permission() {
    local key="$1"
    chown root:"$RUN_GROUP" "$key" 2>/dev/null || die "无法修改私钥属组：${key}"
    chmod 640 "$key" 2>/dev/null || die "无法修改私钥权限：${key}"
}

# 校验证书可解析、未过期、且与私钥匹配
verify_cert_pair() {
    local cert="$1" key="$2" cert_pub key_pub
    cert_pub="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)" \
        || die "证书解析失败（非 PEM 证书或已损坏）：${cert}"
    if ! openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1; then
        die "证书已过期或将在 24 小时内过期：${cert}，请更换证书"
    fi
    key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null)" \
        || die "私钥解析失败（非 PEM 私钥或已损坏）：${key}"
    [[ "$cert_pub" == "$key_pub" ]] || die "证书与私钥不匹配：${cert} / ${key}"
    log "证书与私钥匹配校验通过"
}

# 使用 sing-box 自带生成器生成自签证书（与 233boy 写法一致，默认 456 个月）
gen_self_signed_cert() {
    install -d -m 755 -o root -g root "$CERT_DIR"

    # 与 233boy 一致：证书已存在时直接复用，避免重跑安装后客户端 pin 失效
    if [[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]]; then
        CERT_FILE="${CERT_DIR}/fullchain.pem"
        KEY_FILE="${CERT_DIR}/privkey.pem"
        verify_cert_pair "$CERT_FILE" "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        fix_key_permission "$KEY_FILE"
        log "复用已有证书：${CERT_DIR}"
        CERT_SOURCE="selfsign"
        return 0
    fi

    # sing-box 的 generate tls-keypair 参数是 server_name，PEM 直接输出到 stdout
    local tmpdir tmp err
    tmpdir="$(mk_tmpdir)"
    tmp="${tmpdir}/tls.pem"
    err="${tmpdir}/err.log"

    if ! "$SINGBOX_BIN" generate tls-keypair "$DOMAIN" -m 456 >"$tmp" 2>"$err" \
        || ! grep -q 'BEGIN CERTIFICATE' "$tmp" 2>/dev/null; then
        : > "$tmp"
        # 兼容不支持 -m 参数的旧版本
        if ! "$SINGBOX_BIN" generate tls-keypair "$DOMAIN" >"$tmp" 2>"$err" \
            || ! grep -q 'BEGIN CERTIFICATE' "$tmp" 2>/dev/null; then
            local reason
            reason="$(head -n 3 "$err" 2>/dev/null | tr '\n' ' ' || true)"
            rm -rf "$tmpdir"
            die "sing-box 自签证书生成失败（版本：$("$SINGBOX_BIN" version 2>/dev/null | head -n 1)），原因：${reason:-未知}"
        fi
    fi

    awk '/BEGIN.*PRIVATE KEY/,/END.*PRIVATE KEY/' "$tmp" > "${tmpdir}/privkey.pem"
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$tmp" > "${tmpdir}/fullchain.pem"
    [[ -s "${tmpdir}/privkey.pem" && -s "${tmpdir}/fullchain.pem" ]] \
        || die "自签证书拆分失败：${CERT_DIR}"

    # 拆分结果校验通过后才落盘，失败时临时目录由 trap 清理，不留半成品
    verify_cert_pair "${tmpdir}/fullchain.pem" "${tmpdir}/privkey.pem"
    install -m 640 -o root -g "$RUN_GROUP" "${tmpdir}/privkey.pem" "${CERT_DIR}/privkey.pem" || die "写入私钥失败"
    install -m 644 -o root -g root "${tmpdir}/fullchain.pem" "${CERT_DIR}/fullchain.pem" || die "写入证书失败"
    rm -rf "$tmpdir"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    CERT_SOURCE="selfsign"
    log "已生成 sing-box 自签证书（456 个月）：${CERT_DIR}"
}

ask_cert_source() {
    local ans
    printf '\n证书来源：\n'
    printf '  1) sing-box 自签（推荐，无需真实域名，回车默认）\n'
    if [[ -s "${XRAY_CERT_DIR}/fullchain.pem" && -s "${XRAY_CERT_DIR}/privkey.pem" ]]; then
        printf '  2) 复用 Xray 证书：%s\n' "$XRAY_CERT_DIR"
    else
        printf '  2) 复用 Xray 证书（未检测到 Xray 证书）\n'
    fi
    printf '  3) 手动输入 .cer / .key 路径\n'
    read -r -p "请选择 [1-3]（回车 = 1）：" ans
    case "$ans" in
        ""|1)
            gen_self_signed_cert
            ;;
        2)
            reuse_xray_cert
            ;;
        3)
            setup_cert_manual
            ;;
        *)
            die "无效选择：${ans}"
            ;;
    esac
}

# 复用 Xray 证书：只读源文件、复制到 Hysteria 2 独立目录后再调权限，
# 禁止修改 Xray 原始证书/私钥的内容、属组或权限
reuse_xray_cert() {
    local src_cert="${XRAY_CERT_DIR}/fullchain.pem" src_key="${XRAY_CERT_DIR}/privkey.pem"
    [[ -s "$src_cert" && -s "$src_key" ]] || die "未检测到 Xray 证书：${XRAY_CERT_DIR}"

    install -d -m 755 -o root -g root "$CERT_DIR"
    cp -f "$src_cert" "${CERT_DIR}/fullchain.pem" || die "复制 Xray 证书失败"
    cp -f "$src_key" "${CERT_DIR}/privkey.pem" || die "复制 Xray 私钥失败"

    verify_cert_pair "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"
    chmod 644 "${CERT_DIR}/fullchain.pem"
    fix_key_permission "${CERT_DIR}/privkey.pem"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    CERT_SOURCE="xray"
    log "已复制 Xray 证书到 Hysteria 2 独立目录（原文件未改动）：${CERT_DIR}"
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

    verify_cert_pair "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"
    chmod 644 "${CERT_DIR}/fullchain.pem"
    fix_key_permission "${CERT_DIR}/privkey.pem"

    CERT_FILE="${CERT_DIR}/fullchain.pem"
    KEY_FILE="${CERT_DIR}/privkey.pem"
    CERT_SOURCE="manual"
    log "证书已复制到：${CERT_DIR}"
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

# ------------------------------ 编码与转义 ------------------------------------
# RFC 3986 百分号编码（unreserved 之外的全部字节编码）
urlencode() {
    local s="$1" out="" i c o
    LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9.~_-]) out+="$c" ;;
            *)
                o="$(printf '%d' "'$c")"
                out+="$(printf '%%%02X' "$o")"
                ;;
        esac
    done
    printf '%s' "$out"
}

# JSON 字符串转义（反斜杠、双引号、控制字符），防止配置内容被破坏
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# 证书 SHA-256 指纹（小写十六进制、无冒号），每次输出链接时重新计算
cert_fingerprint() {
    local cert="$1" pin=""
    if [[ -f "$cert" ]]; then
        pin="$(openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null \
            | sed 's/.*=//;s/://g' | tr 'A-F' 'a-f' || true)"
    fi
    printf '%s' "$pin"
}

# ------------------------------ 配置写入 --------------------------------------
# 临时文件生成 -> sing-box check 校验 -> 原子替换正式配置
write_config() {
    install -d -m 755 -o root -g root "$SINGBOX_DIR"

    local e_pass e_domain tmp_cfg
    e_pass="$(json_escape "$PASSWORD")"
    e_domain="$(json_escape "$DOMAIN")"
    tmp_cfg="${CONFIG_FILE}.tmp.$$"

    # ALPN 固定 h3，与官方 Hysteria 2 默认值一致；UDP 转发由 QUIC 原生承载
    cat > "$tmp_cfg" <<EOF
{
  "log": {
    "level": "warn",
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
          "password": "${e_pass}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${e_domain}",
        "alpn": [
          "h3"
        ],
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

    if ! "$SINGBOX_BIN" check -c "$tmp_cfg"; then
        rm -f "$tmp_cfg"
        die "sing-box 配置校验失败，正式配置未改动（请确认 sing-box 版本支持 hysteria2）"
    fi

    # 校验通过后备份并原子替换
    if [[ -f "$CONFIG_FILE" ]]; then
        CFG_BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$CFG_BACKUP" || die "旧配置备份失败：${CFG_BACKUP}"
        log "旧配置已备份：${CFG_BACKUP}"
    fi
    mv -f "$tmp_cfg" "$CONFIG_FILE"
    CFG_REPLACED=1

    # sing-box 以 nobody 运行，配置需属组可读（含密码，仍限制其他用户）
    chown root:"$RUN_GROUP" "$CONFIG_FILE" 2>/dev/null || warn "无法修改配置属组：${CONFIG_FILE}"
    chmod 640 "$CONFIG_FILE"
    log "配置写入并校验通过：${CONFIG_FILE}"
}

# ------------------------------ 回滚 ------------------------------------------
# 服务启动失败时恢复本次运行前的配置与服务文件
rollback() {
    local restored=0
    if [[ -n "$CFG_BACKUP" && -f "$CFG_BACKUP" ]]; then
        cp -a "$CFG_BACKUP" "$CONFIG_FILE" && restored=1
    elif [[ "$CFG_REPLACED" -eq 1 ]]; then
        rm -f "$CONFIG_FILE" && restored=1
    fi
    if [[ -n "$SVC_BACKUP" && -f "$SVC_BACKUP" ]]; then
        cp -a "$SVC_BACKUP" "$SERVICE_FILE" && restored=1
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if (( restored == 1 )); then
        if systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
            log "已回滚并恢复旧版服务"
        else
            warn "回滚后旧服务未能自动恢复，请手动检查 systemctl status ${SERVICE_NAME}"
        fi
    fi
}

# ------------------------------ systemd 服务 ----------------------------------
# 同名服务文件若非本脚本创建，必须先备份并征得用户确认后才可覆盖
guard_foreign_service_file() {
    local svc_file="$1" svc_label="$2" ans
    [[ -f "$svc_file" ]] || return 0
    if grep -q "$SERVICE_MARKER" "$svc_file" 2>/dev/null; then
        return 0
    fi
    local backup
    backup="${svc_file}.foreign.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$svc_file" "$backup"
    warn "检测到同名服务文件不是本脚本创建：${svc_file}"
    warn "已备份到：${backup}"
    read -r -p "是否覆盖该服务文件以继续安装 ${svc_label}？[y/N]：" ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "用户取消覆盖外部服务文件，安装终止（备份：${backup}）"
}

write_service() {
    guard_foreign_service_file "$SERVICE_FILE" "$SERVICE_NAME"

    if [[ -f "$SERVICE_FILE" ]]; then
        SVC_BACKUP="${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$SERVICE_FILE" "$SVC_BACKUP" || warn "旧服务文件备份失败：${SVC_BACKUP}"
    fi

    # Restart=on-failure 负责进程级异常重连；QUIC 连接复用与超时由 sing-box 内部处理
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless Hysteria 2 Service (sing-box)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
TimeoutStartSec=30
LimitNOFILE=1000000
OOMScoreAdjust=-600

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    if ! systemctl daemon-reload; then
        rollback
        die "systemd 重载失败"
    fi
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "设置开机自启失败"

    log "启动 ${SERVICE_NAME} 服务..."
    if ! systemctl restart "$SERVICE_NAME"; then
        err "服务启动失败，最近日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || true
        rollback
        die "Hysteria 2 服务启动失败，已尝试回滚"
    fi

    # 等待服务进入 active，最长约 10 秒
    local i
    for (( i = 0; i < 20; i++ )); do
        systemctl is-active --quiet "$SERVICE_NAME" && break
        sleep 0.5
    done
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务未处于运行状态，最近日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || true
        rollback
        die "Hysteria 2 服务未能进入运行状态，已尝试回滚"
    fi
    log "${SERVICE_NAME} 已启动"
}

# ------------------------------ 运行状态校验 ----------------------------------
verify_runtime() {
    local listening=-1 i
    for (( i = 0; i < 5; i++ )); do
        if port_range_conflict "$PORT" "$PORT" >/dev/null 2>&1; then
            listening=1
            break
        fi
        sleep 1
    done

    if (( listening == 1 )); then
        log "UDP 端口 ${PORT} 已监听"
    else
        err "未检测到 UDP 端口 ${PORT} 监听，最近日志："
        journalctl -u "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || true
        rollback
        die "Hysteria 2 服务未在 ${PORT}/udp 建立监听，已尝试回滚"
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "服务状态：运行中（异常退出将自动重连）"
    else
        warn "服务状态：未运行"
    fi
}

# ------------------------------ 防火墙 ----------------------------------------
# 仅追加本脚本自己的规则（带 cgg-hysteria2 注释标记），绝不清空或覆盖现有规则。
# 端口跳跃的 REDIRECT 发生在 nat PREROUTING，进入 INPUT 时目的端口已是主端口，
# 因此只需放行主端口；云厂商安全组需另行放行全部跳跃端口（见结尾提示）。
configure_firewall() {
    local ufw_active=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_active=1
        if ufw status 2>/dev/null | grep -qE "^${PORT}/udp\s+ALLOW"; then
            log "UFW 已存在端口规则，跳过：${PORT}/udp"
        elif ufw allow "${PORT}/udp" >/dev/null 2>&1; then
            log "UFW 已放行端口 ${PORT}/udp"
        else
            warn "UFW 放行 ${PORT}/udp 失败，请手动执行：ufw allow ${PORT}/udp"
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        # 优先带注释标记；个别内核缺 comment 模块时退化为无注释规则
        if iptables -C INPUT -p udp --dport "$PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; then
            log "iptables 已存在端口规则，跳过：${PORT}/udp"
        elif iptables -I INPUT -p udp --dport "$PORT" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; then
            log "iptables 已放行端口 ${PORT}/udp"
        elif iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            log "iptables 已存在端口规则（无注释），跳过：${PORT}/udp"
        elif iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null; then
            warn "iptables comment 模块不可用，已添加无注释规则：${PORT}/udp"
        else
            warn "iptables 放行端口失败（容器环境可能无 iptables 权限），请手动放行 ${PORT}/udp"
        fi
    elif command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -q "comment \\\"${FW_COMMENT}\\\""; then
            log "nftables 已存在本脚本规则，跳过：${PORT}/udp"
        elif nft list chain inet filter input >/dev/null 2>&1; then
            if nft add rule inet filter input udp dport "$PORT" comment "\"${FW_COMMENT}\"" accept 2>/dev/null; then
                log "nftables 已放行端口 ${PORT}/udp"
            else
                warn "nftables 放行端口失败，请手动放行 ${PORT}/udp"
            fi
        else
            warn "未找到 inet filter input 链，请手动放行 ${PORT}/udp"
        fi
    elif (( ufw_active == 0 )); then
        warn "未检测到 UFW / iptables / nftables，请手动放行 ${PORT}/udp"
    fi
}

# ------------------------------ 端口跳跃 --------------------------------------
# 主端口不变，用 nat REDIRECT 把跳跃端口（UDP）转发到主端口。
# 说明：REDIRECT 对 UDP/QUIC 目的地址转换有效（官方 hy2 服务端跳跃同理），
#       但 sing-box 仅监听 IPv4（0.0.0.0），跳跃规则只覆盖 IPv4；IPv6 客户端
#       需直连主端口。非特权 LXC/OpenVZ 容器通常无 nat 表权限，将明确报错。
hop_backend() {
    if command -v iptables >/dev/null 2>&1 && iptables -t nat -S PREROUTING >/dev/null 2>&1; then
        printf 'iptables'
    elif command -v nft >/dev/null 2>&1; then
        printf 'nft'
    else
        return 1
    fi
}

install_port_hopping() {
    # 未配置跳跃端口：清理可能残留的旧规则与服务
    if (( ${#HOP_PORTS[@]} == 0 )); then
        if [[ -f "$HOP_SCRIPT" ]]; then
            if [[ -f "$HOP_SERVICE_FILE" ]]; then
                systemctl disable --now "${SERVICE_NAME}-hop" >/dev/null 2>&1 || true
                rm -f "$HOP_SERVICE_FILE"
            else
                bash "$HOP_SCRIPT" stop >/dev/null 2>&1 || true
            fi
            rm -f "$HOP_SCRIPT"
            systemctl daemon-reload >/dev/null 2>&1 || true
            log "已清理旧的端口跳跃配置"
        fi
        return 0
    fi

    install -d -m 755 -o root -g root "$SINGBOX_DIR"

    # 跳跃项已通过严格校验（仅数字与连字符），嵌入脚本无注入风险
    local hop_array_lit
    hop_array_lit="$(printf "'%s' " "${HOP_PORTS[@]}")"

    guard_foreign_service_file "$HOP_SERVICE_FILE" "${SERVICE_NAME}-hop"

    cat > "$HOP_SCRIPT" <<EOF
#!/usr/bin/env bash
# 由 cgg-vless-hysteria2.sh 自动生成，请勿手工修改
set -Eeuo pipefail

PORT='${PORT}'
HOP_PORTS=(${hop_array_lit})
COMMENT='cgg-hysteria2-hop'

to_ipt_dport() {
    case "\$1" in
        *-*) printf '%s\n' "\${1/-/:}" ;;
        *)   printf '%s\n' "\$1" ;;
    esac
}

# 删除本脚本创建过的全部旧跳跃规则（按注释标记识别，绝不触碰他人规则）
purge_ipt_rules() {
    local line
    while IFS= read -r line; do
        [[ -n "\$line" ]] || continue
        # -S 输出含引号，需 eval 还原为参数列表；行内容仅来自本脚本注释标记规则
        eval "iptables -t nat -D \${line#-A }" 2>/dev/null || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "\$COMMENT" || true)
}

start_ipt() {
    local item dport
    purge_ipt_rules
    for item in "\${HOP_PORTS[@]}"; do
        dport="\$(to_ipt_dport "\$item")"
        if ! iptables -t nat -A PREROUTING -p udp --dport "\$dport" \\
            -m comment --comment "\$COMMENT" -j REDIRECT --to-ports "\$PORT"; then
            echo "[ERROR] iptables 跳跃规则添加失败：\${item}/udp -> \${PORT}（容器环境可能无 nat 表权限）" >&2
            return 1
        fi
        if ! iptables -t nat -C PREROUTING -p udp --dport "\$dport" \\
            -m comment --comment "\$COMMENT" -j REDIRECT --to-ports "\$PORT" 2>/dev/null; then
            echo "[ERROR] iptables 跳跃规则回读校验失败：\${item}/udp -> \${PORT}" >&2
            return 1
        fi
    done
}

start_nft() {
    local item
    nft list table inet cgg-hop >/dev/null 2>&1 || nft add table inet cgg-hop
    nft list chain inet cgg-hop prerouting >/dev/null 2>&1 \\
        || nft add chain inet cgg-hop prerouting '{ type nat hook prerouting priority dstnat ; policy accept ; }'
    nft flush chain inet cgg-hop prerouting
    for item in "\${HOP_PORTS[@]}"; do
        if ! nft add rule inet cgg-hop prerouting udp dport "\$item" redirect to :"\$PORT"; then
            echo "[ERROR] nftables 跳跃规则添加失败：\${item}/udp -> \${PORT}" >&2
            return 1
        fi
    done
    for item in "\${HOP_PORTS[@]}"; do
        if ! nft -s list chain inet cgg-hop prerouting 2>/dev/null | grep -Fq "udp dport \$item"; then
            echo "[ERROR] nftables 跳跃规则回读校验失败：\${item}/udp -> \${PORT}" >&2
            return 1
        fi
    done
}

start_rules() {
    if command -v iptables >/dev/null 2>&1 && iptables -t nat -S PREROUTING >/dev/null 2>&1; then
        start_ipt
        return 0
    fi
    if command -v nft >/dev/null 2>&1; then
        start_nft
        return 0
    fi
    echo "[ERROR] 未检测到可用的 iptables / nftables，端口跳跃无法生效" >&2
    return 1
}

stop_ipt() {
    purge_ipt_rules
}

stop_rules() {
    if command -v iptables >/dev/null 2>&1; then
        stop_ipt
    fi
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet cgg-hop 2>/dev/null || true
    fi
}

case "\${1:-start}" in
    start) start_rules ;;
    stop)  stop_rules ;;
    *)     echo "用法: \$0 {start|stop}" >&2; exit 2 ;;
esac
EOF

    chmod 755 "$HOP_SCRIPT"

    cat > "$HOP_SERVICE_FILE" <<EOF
[Unit]
Description=cgg-vless Hysteria2 port hopping
Documentation=https://v2.hysteria.network
After=network-online.target
Wants=network-online.target
Before=${SERVICE_NAME}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${HOP_SCRIPT} start
ExecStop=/bin/bash ${HOP_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$HOP_SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}-hop" >/dev/null 2>&1 \
        || warn "设置端口跳跃开机自启失败"

    if ! systemctl restart "${SERVICE_NAME}-hop"; then
        bash "$HOP_SCRIPT" stop >/dev/null 2>&1 || true
        die "端口跳跃规则应用失败（服务执行返回非零），请检查内核是否支持 iptables nat / nftables（容器环境通常受限）"
    fi

    # 不能只看 systemd 状态，必须回读内核中实际 NAT 规则
    local backend item dport
    if ! backend="$(hop_backend)"; then
        bash "$HOP_SCRIPT" stop >/dev/null 2>&1 || true
        die "端口跳跃规则无法验证：iptables / nftables 均不可用"
    fi
    for item in "${HOP_PORTS[@]}"; do
        if [[ "$backend" == "iptables" ]]; then
            dport="${item/-/:}"
            if ! iptables -t nat -C PREROUTING -p udp --dport "$dport" \
                -m comment --comment "cgg-hysteria2-hop" -j REDIRECT --to-ports "$PORT" 2>/dev/null; then
                bash "$HOP_SCRIPT" stop >/dev/null 2>&1 || true
                die "端口跳跃规则未生效（内核回读失败）：${item}/udp -> ${PORT}"
            fi
        else
            if ! nft -s list chain inet cgg-hop prerouting 2>/dev/null | grep -Fq "udp dport $item"; then
                bash "$HOP_SCRIPT" stop >/dev/null 2>&1 || true
                die "端口跳跃规则未生效（内核回读失败）：${item}/udp -> ${PORT}"
            fi
        fi
    done

    log "端口跳跃已生效并经内核规则回读确认：${HOP_SPEC} -> ${PORT}/udp"
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
        printf 'HOP=%s\n' "$HOP_SPEC"
        printf 'SERVER_IP=%s\n' "$SERVER_IP"
        printf 'CERT_SOURCE=%s\n' "$CERT_SOURCE"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# ------------------------------ 输出结果 --------------------------------------
print_result() {
    local ip link pin portspec host
    ip="${SERVER_IP:-YOUR_SERVER_IP}"

    # IPv6 地址在 URI 中必须加方括号（本服务仅监听 IPv4，正常不会出现）
    if [[ "$ip" == *:* ]]; then
        host="[${ip}]"
    else
        host="$ip"
    fi

    # 官方 URI 规范：端口字段支持「多端口地址格式」，如 :123,5000-6000
    portspec="${PORT}"
    if [[ -n "$HOP_SPEC" ]]; then
        portspec="${PORT},${HOP_SPEC}"
    fi

    # 指纹每次基于当前证书重新计算，证书更新后自动反映最新值
    pin="$(cert_fingerprint "$CERT_FILE")"

    link="hysteria2://$(urlencode "$PASSWORD")@${host}:${portspec}/?sni=$(urlencode "$DOMAIN")&insecure=1"
    if [[ -n "$pin" ]]; then
        link+="&pinSHA256=${pin}"
    else
        warn "未能计算证书 SHA-256 指纹，分享链接不含 pinSHA256"
    fi
    link+="#$(urlencode "$NODE_NAME")"

    printf '\n%s=============== cgg-vless Hysteria 2 节点 ===============%s\n' "$C_CYAN" "$C_RESET"
    printf '  模式        : Hysteria 2（sing-box，QUIC/UDP）\n'
    printf '  节点名称    : %s\n' "$NODE_NAME"
    printf '  地址 (IP)   : %s\n' "$ip"
    printf '  UDP 端口    : %s\n' "$PORT"
    if [[ -n "$HOP_SPEC" ]]; then
        printf '  端口跳跃    : %s\n' "$HOP_SPEC"
    fi
    printf '  域名 / SNI  : %s\n' "$DOMAIN"
    printf '  密码        : %s\n' "$PASSWORD"
    printf '  ALPN        : h3（协议固定值，URI 不携带）\n'
    if [[ -n "${pin:-}" ]]; then
        printf '  证书指纹    : %s\n' "$pin"
    fi
    printf '%s=========================================================%s\n\n' "$C_CYAN" "$C_RESET"

    if (( IP_UNCONFIRMED == 1 )); then
        printf '%s警告：服务器地址未经自动确认，请核对后再分发链接%s\n\n' "$C_YELLOW" "$C_RESET"
    fi
    printf '%sHysteria 2 分享链接（官方 URI 规范）：%s\n%s\n\n' "$C_GREEN" "$C_RESET" "$link"

    printf '%s提示：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  - Hysteria 2 基于 QUIC/UDP，客户端需支持：sing-box / mihomo(Clash.Meta) / 官方 Hysteria 2\n'
    printf '  - 无法套 Cloudflare CDN，必须客户端直连\n'
    printf '  - NAT 机器需在服务商面板把 UDP 外部端口 %s 映射到容器内部端口 %s\n' "$PORT" "$PORT"
    if [[ -n "$HOP_SPEC" ]]; then
        printf '  - 端口跳跃需在服务商安全组放行 UDP %s,%s（跳跃规则仅覆盖 IPv4）\n' "$PORT" "$HOP_SPEC"
        printf '  - 跳跃端口按官方 URI 多端口格式写入链接；若客户端不支持该格式，\n'
        printf '    请手动填写主端口 %s，并在客户端“端口跳跃/多端口”栏填入：%s\n' "$PORT" "$HOP_SPEC"
    fi
    printf '  - 自签证书需客户端开启“跳过证书验证（insecure）”，或用 pinSHA256 固定证书指纹\n'
    printf '  - 重跑本脚本会重新生成密码，旧链接立即作废，请以最后一次输出为准\n'
}

# ------------------------------ 主流程 ----------------------------------------
main() {
    require_root
    check_os
    require_tty
    check_dependencies
    check_network

    printf '\n%s========== cgg-vless · Hysteria 2（sing-box）==========%s\n\n' "$C_MAGENTA" "$C_RESET"
    warn "Xray-core 不支持 Hysteria 2，本脚本复用 sing-box 后端，配置与服务独立，不影响现有节点"

    ask_domain
    ask_port
    ask_node_name

    # 自签证书依赖 sing-box，必须先安装
    install_singbox

    ask_cert_source
    gen_password

    write_config
    write_service
    verify_runtime
    configure_firewall
    install_port_hopping

    ask_server_addr
    save_info
    print_result
    log "安装完成"
}

main "$@"
