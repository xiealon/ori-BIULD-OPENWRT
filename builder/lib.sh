#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 公共函数库：所有构建脚本统一 source 本文件
# ---------------------------------------------------------------------------
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/builder"
CONF_DIR="$REPO_ROOT/config"
readonly REPO_ROOT TOOLS_DIR CONF_DIR

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_NOTE=""
else
    C_RESET="\033[0m"; C_INFO="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_NOTE="\033[36m"
fi

log()  { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$*" >&2; }
err()  { printf "${C_ERR}[ERR ]${C_RESET} %s\n" "$*" >&2; }
note() { printf "${C_NOTE}[NOTE]${C_RESET} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

# 打印将要执行的命令，便于 Actions 日志排错
run() { printf '+ %s\n' "$*"; "$@"; }

require() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "缺少依赖命令: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# 参数校验
# ---------------------------------------------------------------------------
to_bool() {
    # 把 "true/false/yes/no/1/0/on/off" 统一成 true|false
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|yes|y|1|on)  echo true ;;
        false|no|n|0|off|"") echo false ;;
        *) die "无法识别的布尔值: '$1' (可用: true/false/yes/no/1/0)" ;;
    esac
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

validate_ipv4() {
    local ip="${1:-}" o IFS='.'
    # shellcheck disable=SC2086
    read -r -a o <<< "$ip"
    [ "${#o[@]}" -eq 4 ] || { err "非法 IPv4 地址: '$ip'"; return 1; }
    for x in "${o[@]}"; do
        is_int "$x" || { err "非法 IPv4 地址: '$ip'"; return 1; }
        [ "$x" -ge 0 ] && [ "$x" -le 255 ] || { err "非法 IPv4 地址: '$ip'"; return 1; }
    done
}

validate_ip_list() {
    local list="${1:-}" item
    [ -z "$list" ] && return 0
    for item in $list; do
        validate_ipv4 "$item" || return 1
    done
}

validate_size() {
    # $1=值 $2=最小值(默认64) $3=最大值(默认1048576)
    local s="${1:-}" min="${2:-64}" max="${3:-1048576}"
    is_int "$s" || { err "分区大小必须是整数(MiB): '$s'"; return 1; }
    if [ "$s" -lt "$min" ] || [ "$s" -gt "$max" ]; then
        err "分区大小超出合理范围($min~$max MiB): '$s'"
        return 1
    fi
}

# 把 "1.1.1.1, 8.8.8.8  114.114.114.114" 归一成 "1.1.1.1 8.8.8.8 114.114.114.114"
normalize_ip_list() {
    printf '%s' "${1:-}" | tr ',;|' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# ---------------------------------------------------------------------------
# 主机名 / 固件名
# ---------------------------------------------------------------------------
stamp() { date -u +"%Y%m%d-%H%M"; }

# 生成 OpenWrt root 用户的 sha512crypt 密码串($6$...)
hash_password() {
    local pw="$1" out=""
    if command -v openssl >/dev/null 2>&1; then
        # openssl 1.1+/3.x 均支持 -6 (sha512crypt)
        out="$(openssl passwd -6 "$pw" 2>/dev/null || true)"
    fi
    if [ -z "$out" ] && command -v python3 >/dev/null 2>&1; then
        out="$(python3 - "$pw" <<'PY' 2>/dev/null || true
import sys
try:
    import crypt, secrets, string
    salt = '$6$' + ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
    sys.stdout.write(crypt.crypt(sys.argv[1], salt))
except Exception:
    sys.exit(1)
PY
)"
    fi
    if [ -z "$out" ] && command -v mkpasswd >/dev/null 2>&1; then
        out="$(mkpasswd -m sha512crypt "$pw" 2>/dev/null || true)"
    fi
    [ -n "$out" ] || die "无法生成 sha512 密码散列，请安装 openssl 或 python3"
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 包清单处理：config/*.pkgs -> diffconfig 行
# ---------------------------------------------------------------------------
# 读取 pkgs 文件：忽略空行与 # 注释行；每行一个包名，形如 "name" 或 "name=y" / "name=m"
pkg_list() {
    local f="$1"
    [ -f "$f" ] || return 0
    grep -Ev '^\s*(#|$)' "$f" | awk '{print $1}' || true
}

list_to_conf() {
    # stdin: 包名清单 -> stdout: CONFIG_PACKAGE_<name>=y
    while read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            CONFIG_*) printf '%s\n' "$p" ;;
            *=*)      printf 'CONFIG_PACKAGE_%s\n' "$p" ;;
            *)        printf 'CONFIG_PACKAGE_%s=y\n' "$p" ;;
        esac
    done
}

require_file() { [ -f "$1" ] || die "找不到文件: $1"; [ -s "$1" ] || die "文件为空: $1"; }
