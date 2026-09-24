#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 把「路由器身份」写进固件：LAN IP、子网掩码、网关、DNS、旁路届三中全会模式、
# root 开机密码、时区、主机名、Docker/LXC 自启动等。
#
# 实现方式：在源码根目录生成 files/ 目录，OpenWrt buildroot 会在打包时把
# files/ 下的内容直接写入 rootfs；其中 etc/uci-defaults/ 脚本于首次开机执行。
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

usage() {
    cat <<'EOF'
用法: apply-defaults.sh [选项]

选项:
  -d, --dir DIR           源码目录（必填）
      --lan-ip IP         LAN 地址              (默认 192.168.1.1)
      --netmask MASK      子网掩码              (默认 255.255.255.0)
      --mode MODE         router | bypass        (默认 router)
      --gateway IP        旁路模式下的上级网关地址
      --dns LIST          DNS 地址，空格或逗号分隔
      --password PW       root 开机密码（留空=使用 OpenWrt 默认空密码）
      --hostname NAME     主机名                 (默认 OpenWrt)
      --timezone TZ       时区字符串             (默认 CST-8)
  -h, --help
EOF
}

SOURCE_DIR="${SOURCE_DIR:-}"
LAN_IP="${LAN_IP:-192.168.1.1}"
LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"
BYPASS_MODE="$(to_bool "${BYPASS_MODE:-false}")"
UPSTREAM_GATEWAY="${UPSTREAM_GATEWAY:-}"
DNS_SERVERS="$(normalize_ip_list "${DNS_SERVERS:-}")"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
HOSTNAME_NAME="${HOSTNAME_NAME:-OpenWrt}"
TZONE="${TZONE:-CST-8}"
INCLUDE_DOCKER="$(to_bool "${INCLUDE_DOCKER:-true}")"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir)      SOURCE_DIR="$2"; shift 2 ;;
        --lan-ip)      LAN_IP="$2"; shift 2 ;;
        --netmask|--lan-netmask) LAN_NETMASK="$2"; shift 2 ;;
        --mode)        BYPASS_MODE="$([ "$2" = bypass ] && echo true || echo false)"; shift 2 ;;
        --gateway)     UPSTREAM_GATEWAY="$2"; shift 2 ;;
        --dns)         DNS_SERVERS="$(normalize_ip_list "$2")"; shift 2 ;;
        --password)    ROOT_PASSWORD="$2"; shift 2 ;;
        --hostname)    HOSTNAME_NAME="$2"; shift 2 ;;
        --timezone)    TZONE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) die "未知参数: $1（用 -h 查看用法）" ;;
    esac
done

[ -n "$SOURCE_DIR" ] || die "必须指定源码目录 -d/--dir"
[ -d "$SOURCE_DIR" ] || die "源码目录不存在: $SOURCE_DIR"
[ -f "$SOURCE_DIR/Makefile" ] || die "这不像 OpenWrt 源码目录: $SOURCE_DIR"

validate_ipv4 "$LAN_IP" || die "LAN IP 非法"
validate_ipv4 "$LAN_NETMASK" || die "子网掩码非法"
validate_ip_list "$DNS_SERVERS" || die "DNS 地址非法"
if [ -n "$UPSTREAM_GATEWAY" ]; then
    validate_ipv4 "$UPSTREAM_GATEWAY" || die "上级网关地址非法"
fi
if [ "$(to_bool "$BYPASS_MODE")" = true ] && [ -z "$UPSTREAM_GATEWAY" ]; then
    warn "旁路路由模式未指定上级网关，本地域名解析/出网可能异常"
fi

log "写入固件默认参数: LAN=$LAN_IP/$LAN_NETMASK 模式=$([ "$(to_bool "$BYPASS_MODE")" = true ] && echo bypass || echo router) DNS=${DNS_SERVERS:-继承上级}"

# ---------------------------------------------------------------------------
# 1) uci-defaults 脚本
# ---------------------------------------------------------------------------
ROOT_HASH=""
if [ -n "$ROOT_PASSWORD" ]; then
    ROOT_HASH="$(hash_password "$ROOT_PASSWORD")"
    # shellcheck disable=SC2016
    case "$ROOT_HASH" in '$6$'*) ;; *) die "生成密码散列失败" ;; esac
    note "已生成 root 的 sha512crypt 散列"
fi

mkdir -p "$SOURCE_DIR/files/etc/uci-defaults"
python3 "$TOOLS_DIR/render-defaults.py" \
    --template "$REPO_ROOT/files/etc/uci-defaults/99-openselfwrt" \
    --out "$SOURCE_DIR/files/etc/uci-defaults/99-openselfwrt" \
    --lan-ip "$LAN_IP" \
    --lan-netmask "$LAN_NETMASK" \
    --bypass-mode "$(to_bool "$BYPASS_MODE")" \
    --upstream-gateway "$UPSTREAM_GATEWAY" \
    --dns "$DNS_SERVERS" \
    --hostname "$HOSTNAME_NAME" \
    --timezone "$TZONE" \
    --root-hash "$ROOT_HASH" \
    --include-docker "$INCLUDE_DOCKER"

chmod 0755 "$SOURCE_DIR/files/etc/uci-defaults/99-openselfwrt"

# ---------------------------------------------------------------------------
# 2) /etc/banner 提示信息
# ---------------------------------------------------------------------------
MODE_DESC="$([ "$(to_bool "$BYPASS_MODE")" = true ] \
    && echo '旁路由(旁路网关)模式 - 本机 DHCP 服务已关闭' \
    || echo '主路由模式 - 本机提供 DHCP / DNS')"
{
    echo "  ___                    ___       _ _     _ __       __           __"
    echo " / _ \\ _ __   ___ _ __  / __| ___ | | |___| |\\ \\     / /__ _ __|_  )"
    echo " | (_) | '_ \\ / _ \\ '_ \\ \\__ \\/ _ \\| | / __| | \\ \\ /\\ / / _ \\ '__/ /"
    echo "  \\___/| .__/ \\___/ .__/ |___/\\___/|_| \\__|_|  \\ V  V /\\___/_| /___|"
    echo "       |_|       |_|"
    echo " ---------------------------------------------------------------"
    echo " 管理地址 : https://$LAN_IP"
    echo " 网络模式 : $MODE_DESC"
    echo " 上级网关 : ${UPSTREAM_GATEWAY:-无（自身即网关）}"
    echo " DNS      : ${DNS_SERVERS:-继承上级}"
    echo " ---------------------------------------------------------------"
} > "$SOURCE_DIR/files/etc/banner.openselfwrt"

log "默认参数已注入 \$SOURCE_DIR/files/，将随固件一并烧写"
