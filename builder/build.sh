#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 一键入口：准备源码 -> 注入默认参数 -> 生成 .config -> 编译 -> 整理产物
#
# 既可被 GitHub Actions 调用，也可直接在任意 Linux 服务器上跑：
#   ./builder/build.sh -v 24.10 --rootfs-type squashfs --rootfs-size 1024 \
#                      --lan-ip 192.168.10.1 --mode bypass --gateway 192.168.10.1 \
#                      --dns "223.5.5.5,119.29.29.29" --password "12345678"
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

# ---------- 默认值（均可用同名环境变量覆盖） ----------
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10}"
SOURCE_DIR="${SOURCE_DIR:-}"
WORKDIR="${WORKDIR:-$PWD}"
BUILD_JOBS="${BUILD_JOBS:-}"
FEED_MIRROR="${FEED_MIRROR:-github}"
GH_PROXY="${GH_PROXY:-}"
INCLUDE_ISTORE="$(to_bool "${INCLUDE_ISTORE:-true}")"
TARGET_SUBTARGET="${TARGET_SUBTARGET:-64}"
ROOTFS_TYPE="${ROOTFS_TYPE:-squashfs}"
ROOTFS_SIZE="${ROOTFS_SIZE:-1024}"
KERNEL_PART_SIZE="${KERNEL_PART_SIZE:-32}"
EFI_IMAGES="$(to_bool "${EFI_IMAGES:-true}")"
GZIP_IMAGES="$(to_bool "${GZIP_IMAGES:-true}")"
VM_IMAGES="$(to_bool "${VM_IMAGES:-false}")"
ISO_IMAGES="$(to_bool "${ISO_IMAGES:-false}")"
INCLUDE_DOCKER="$(to_bool "${INCLUDE_DOCKER:-true}")"
INCLUDE_LXC="$(to_bool "${INCLUDE_LXC:-true}")"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
STRICT_PACKAGE_CHECK="$(to_bool "${STRICT_PACKAGE_CHECK:-false}")"
USE_CCACHE="$(to_bool "${USE_CCACHE:-false}")"
LAN_IP="${LAN_IP:-192.168.1.1}"
LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"
BYPASS_MODE="$(to_bool "${BYPASS_MODE:-false}")"
UPSTREAM_GATEWAY="${UPSTREAM_GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
HOSTNAME_NAME="${HOSTNAME_NAME:-OpenWrt}"
TZONE="${TZONE:-CST-8}"
SKIP_PREPARE="$(to_bool "${SKIP_PREPARE:-false}")"
SKIP_BUILD="$(to_bool "${SKIP_BUILD:-false}")"
VERBOSE="$(to_bool "${VERBOSE:-false}")"

usage() {
    cat <<'EOF'
用法: build.sh [选项]

基础:
  -v, --version VER           24.10 | 25.12            (默认 24.10)
  -d, --dir DIR               源码目录                 (默认 ./openwrt-<version>)
      --target SUB            x86 子目标: 64 | generic | legacy (默认 64)
      --jobs N                并行编译线程数           (默认 CPU 核心数+1)
      --gh-proxy URL          GitHub 加速前缀，例如 https://gh-proxy.com
      --feed-mirror KIND      github | official        (默认 github)
      --skip-prepare          源码已存在且 feeds 已就绪时可跳过
      --skip-build            只做配置与校验，不执行 make

固件形态:
      --rootfs-type TYPE      squashfs | ext4 | both   (默认 squashfs)
      --rootfs-size MiB       rootfs 分区大小          (默认 1024)
      --kernel-part MiB       boot 分区大小            (默认 32)
      --no-efi                不生成 EFI 启动镜像
      --no-gzip               镜像不加 .gz 压缩
      --vm-images             额外产出 VDI / VMDK 虚拟机磁盘
      --iso-images            额外产出 ISO

集成组件:
      --no-docker             不集成 Docker
      --no-lxc                不集成 LXC
      --istore / --no-istore  是否集成 iStore 商店     (默认集成)
      --extra-packages LIST   额外包名，空格分隔

网络与账户:
      --lan-ip IP             LAN 地址                 (默认 192.168.1.1)
      --netmask MASK          子网掩码                 (默认 255.255.255.0)
      --mode MODE             router | bypass          (默认 router)
      --gateway IP            旁路由模式下的上级网关
      --dns LIST              DNS 地址，逗号/空格分隔
      --password PW           root 开机密码（留空=空密码）
      --hostname NAME         主机名                   (默认 OpenWrt)
      --timezone TZ           时区                     (默认 CST-8)

调试:
      --ccache                启用 ccache 加速（默认关闭，见下方说明）
      --no-ccache             关闭 ccache
      --strict-packages       关键包缺失时直接失败
  -V, --verbose               编译时输出详细日志

说明:
  默认关闭 ccache 是因为它自身构建会通过 CMake FetchContent 联网拉依赖，
  网络受限环境下会中断编译；需要反复增量构建时再显式 --ccache 打开。
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)     OPENWRT_VERSION="$2"; shift 2 ;;
        -d|--dir)         SOURCE_DIR="$2"; shift 2 ;;
        --target)         TARGET_SUBTARGET="$2"; shift 2 ;;
        --jobs)           BUILD_JOBS="$2"; shift 2 ;;
        --workdir)        WORKDIR="$2"; shift 2 ;;
        --gh-proxy)       GH_PROXY="$2"; shift 2 ;;
        --feed-mirror)    FEED_MIRROR="$2"; shift 2 ;;
        --rootfs-type)    ROOTFS_TYPE="$2"; shift 2 ;;
        --rootfs-size)    ROOTFS_SIZE="$2"; shift 2 ;;
        --kernel-part)    KERNEL_PART_SIZE="$2"; shift 2 ;;
        --no-efi)         EFI_IMAGES=false; shift ;;
        --no-gzip)        GZIP_IMAGES=false; shift ;;
        --vm-images)      VM_IMAGES=true; shift ;;
        --iso-images)     ISO_IMAGES=true; shift ;;
        --docker)         INCLUDE_DOCKER=true; shift ;;
        --no-docker)      INCLUDE_DOCKER=false; shift ;;
        --lxc)            INCLUDE_LXC=true; shift ;;
        --no-lxc)         INCLUDE_LXC=false; shift ;;
        --istore)         INCLUDE_ISTORE=true; shift ;;
        --no-istore)      INCLUDE_ISTORE=false; shift ;;
        --extra-packages) EXTRA_PACKAGES="$2"; shift 2 ;;
        --ccache)         USE_CCACHE=true; shift ;;
        --no-ccache)      USE_CCACHE=false; shift ;;
        --strict-packages) STRICT_PACKAGE_CHECK=true; shift ;;
        --lan-ip)         LAN_IP="$2"; shift 2 ;;
        --netmask)        LAN_NETMASK="$2"; shift 2 ;;
        --mode)           case "$2" in bypass) BYPASS_MODE=true ;; router) BYPASS_MODE=false ;; *) die "--mode 只能是 router 或 bypass" ;; esac; shift 2 ;;
        --gateway)        UPSTREAM_GATEWAY="$2"; shift 2 ;;
        --dns)            DNS_SERVERS="$2"; shift 2 ;;
        --password)       ROOT_PASSWORD="$2"; shift 2 ;;
        --hostname)       HOSTNAME_NAME="$2"; shift 2 ;;
        --timezone)       TZONE="$2"; shift 2 ;;
        --skip-prepare)   SKIP_PREPARE=true; shift ;;
        --skip-build)     SKIP_BUILD=true; shift ;;
        -V|--verbose)     VERBOSE=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "未知参数: $1（用 -h 查看用法）" ;;
    esac
done

# ---------- 参数归一化与校验 ----------
OPENWRT_VERSION="${OPENWRT_VERSION#v}"
case "$OPENWRT_VERSION" in 24.10|25.12) ;; *) die "暂不支持的版本: $OPENWRT_VERSION（仅 24.10 / 25.12）" ;; esac
DNS_SERVERS="$(normalize_ip_list "$DNS_SERVERS")"
validate_ipv4 "$LAN_IP" || die "LAN IP 非法"
validate_ip_list "$DNS_SERVERS" || die "DNS 非法"
[ -n "$UPSTREAM_GATEWAY" ] && { validate_ipv4 "$UPSTREAM_GATEWAY" || die "上级网关非法"; }
validate_size "$ROOTFS_SIZE" || die "rootfs 大小非法"
validate_size "$KERNEL_PART_SIZE" 4 2048 || die "boot 分区大小非法(4~2048 MiB)"
[ -z "$SOURCE_DIR" ] && SOURCE_DIR="$WORKDIR/openwrt-$OPENWRT_VERSION"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
mkdir -p "$OUT_DIR"
BUILD_JOBS="${BUILD_JOBS:-$(( $(nproc) > 8 ? 8 : $(nproc) ))}"
is_int "$BUILD_JOBS" || die "--jobs 必须是整数"

export OPENWRT_VERSION SOURCE_DIR OPENWRT_ROOT="$REPO_ROOT"

echo "===================================================================="
log "openselfwrt builder"
printf '  版本        : OpenWrt %s (x86/%s)\n' "$OPENWRT_VERSION" "$TARGET_SUBTARGET"
printf '  固件格式    : %s，rootfs %s MiB，boot %s MiB\n' "$ROOTFS_TYPE" "$ROOTFS_SIZE" "$KERNEL_PART_SIZE"
printf '  EFI/GZIP    : %s / %s\n' "$EFI_IMAGES" "$GZIP_IMAGES"
printf '  集成组件    : docker=%s lxc=%s istore=%s\n' "$INCLUDE_DOCKER" "$INCLUDE_LXC" "$INCLUDE_ISTORE"
printf '  网络        : %s/%s  模式=%s  网关=%s\n' "$LAN_IP" "$LAN_NETMASK" \
    "$([ "$(to_bool "$BYPASS_MODE")" = true ] && echo bypass || echo router)" "${UPSTREAM_GATEWAY:-自身}"
printf '  DNS         : %s\n' "${DNS_SERVERS:-继承上级}"
printf '  root 密码   : %s\n' "$([ -n "$ROOT_PASSWORD" ] && echo '已设置(开机即用)' || echo '空密码(OpenWrt 默认)')"
printf '  并行线程    : %s   ccache=%s\n' "$BUILD_JOBS" "$USE_CCACHE"
echo "===================================================================="

# ---------- 1. 源码与 feeds ----------
# 子脚本统一从环境变量读取配置，避免命令行赋值与参数展开顺序踩坑
export OPENWRT_VERSION FEED_MIRROR GH_PROXY INCLUDE_ISTORE \
       TARGET_SUBTARGET ROOTFS_TYPE ROOTFS_SIZE KERNEL_PART_SIZE \
       EFI_IMAGES GZIP_IMAGES VM_IMAGES ISO_IMAGES \
       INCLUDE_DOCKER INCLUDE_LXC EXTRA_PACKAGES USE_CCACHE STRICT_PACKAGE_CHECK \
       LAN_IP LAN_NETMASK BYPASS_MODE UPSTREAM_GATEWAY DNS_SERVERS \
       ROOT_PASSWORD HOSTNAME_NAME TZONE OUT_DIR

if [ "$SKIP_PREPARE" = true ]; then
    note "跳过源码准备(--skip-prepare)"
else
    bash "$TOOLS_DIR/prepare.sh" --dir "$SOURCE_DIR" --version "$OPENWRT_VERSION"
fi
SOURCE_ABS="$(cd "$SOURCE_DIR" && pwd)"
export SOURCE_DIR="$SOURCE_ABS"

# ---------- 2. 注入网络/账户默认值 ----------
bash "$TOOLS_DIR/apply-defaults.sh" --dir "$SOURCE_ABS"

# ---------- 3. 生成 .config ----------
bash "$TOOLS_DIR/genconfig.sh" --dir "$SOURCE_ABS"

if [ "$SKIP_BUILD" = true ]; then
    note "只生成配置，跳过编译(--skip-build)"
    exit 0
fi

# ---------- 4. 编译 ----------
# OpenWrt buildroot 的诸多宿主工具使用 autotools，以 root 身份配置时会报
#   "configure: error: you should not run configure as root"
# GitHub 托管 runner 是非 root 用户(uid 1001)，不会触发；但本地 root 环境或
# 以 root 运行的自托管 runner 必须绕过该检查，否则 tools/tar 第一步就失败。
if [ "$(id -u)" = 0 ] && [ "${FORCE_UNSAFE_CONFIGURE:-}" != "1" ]; then
    warn "检测到以 root 身份编译，自动设置 FORCE_UNSAFE_CONFIGURE=1 以绕过 autotools 的 root 检查"
    warn "（这不是官方推荐做法：条件允许时请改用普通用户编译）"
fi
if [ "$(id -u)" = 0 ]; then
    FORCE_UNSAFE_CONFIGURE=1
    export FORCE_UNSAFE_CONFIGURE
fi

# 宿主环境污染规避：docker 的构建脚本 hack/make/binary-daemon 一旦检测到
# /usr/local/bin/runc 存在，就会把 containerd/ctr/rootlesskit 等"嵌套可执行文件"
# 一并拷进产物目录；只要其中任意一个不存在，就会执行 `cp "" 目录/` 而失败。
# 自托管 runner 或容器内编译时常踩这个坑，这里自动识别并临时移走。
RUNC_MOVED=""
restore_runc() {
    if [ -n "$RUNC_MOVED" ] && [ -f /usr/local/bin/runc.openselfwrt-disabled ]; then
        mv -f /usr/local/bin/runc.openselfwrt-disabled /usr/local/bin/runc
        note "已恢复 /usr/local/bin/runc"
    fi
}
trap restore_runc EXIT
if [ -x /usr/local/bin/runc ]; then
    for b in containerd containerd-shim-runc-v2 ctr runc docker-init rootlesskit \
             rootlesskit-docker-proxy dockerd-rootless.sh dockerd-rootless-setuptool.sh; do
        if ! command -v "$b" >/dev/null 2>&1; then
            warn "宿主存在 /usr/local/bin/runc，但缺少 '$b'，dockerd 构建脚本会因此 cp 空路径而失败"
            warn "临时移走 /usr/local/bin/runc（编译结束后自动恢复）"
            mv -f /usr/local/bin/runc /usr/local/bin/runc.openselfwrt-disabled
            RUNC_MOVED=1
            break
        fi
    done
fi

log "开始编译，这步最耗时（Actions 上限 6 小时，本机视 CPU 而定）"
cd "$SOURCE_ABS"
MAKE_LOG="$OUT_DIR/build.log"
mkdir -p "$OUT_DIR"
{
    echo "# openselfwrt build $(date -u '+%F %T UTC')"
    echo "# version=$OPENWRT_VERSION rootfs=$ROOTFS_TYPE/${ROOTFS_SIZE}MiB jobs=$BUILD_JOBS"
} > "$MAKE_LOG"

set +e
if [ "$VERBOSE" = true ]; then
    make -j"$BUILD_JOBS" V=s 2>&1 | tee -a "$MAKE_LOG"
else
    make -j"$BUILD_JOBS" 2>&1 | tee -a "$MAKE_LOG"
fi
MAKE_RC=${PIPESTATUS[0]:-$?}
set -e

if [ "$MAKE_RC" -ne 0 ]; then
    err "编译失败(退出码 $MAKE_RC)。最后一次失败目标的关键日志："
    grep -nE "^(make|ERROR|Error|WARNING: skipping|Collected errors)" "$MAKE_LOG" | tail -n 40 >&2 || true
    echo "--------------------------------------------------------------------" >&2
    if grep -qi "no space left" "$MAKE_LOG"; then
        err "疑似磁盘空间不足，CI 环境请先清理 runner 或减小分区/包数量"
    fi
    if grep -qiE "failed to download|Resolve layman error|Connection timed out" "$MAKE_LOG"; then
        err "疑似下载源码包失败，可在 Actions 里重跑一次"
    fi
    if grep -qi "you should not run configure as root" "$MAKE_LOG"; then
        err "宿主工具拒绝以 root 运行 configure，请确认 FORCE_UNSAFE_CONFIGURE=1 已导出"
    fi
    exit "$MAKE_RC"
fi
log "编译完成"

# ---------- 5. 整理产物 ----------
bash "$TOOLS_DIR/postbuild.sh"
