#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 生成 OpenWrt .config（差异配置 -> make defconfig -> 校验）
#
# 环境变量:
#   OPENWRT_VERSION   24.10 | 25.12
#   TARGET_SUBTARGET  64 | generic | legacy    (默认 64, 即 x86_64)
#   ROOTFS_TYPE       squashfs | ext4 | both   (默认 squashfs)
#   ROOTFS_SIZE       rootfs 分区大小 MiB      (默认 1024)
#   KERNEL_PART_SIZE  boot 分区大小 MiB        (默认 32)
#   EFI_IMAGES        true|false               (默认 true)
#   VM_IMAGES         true|false 额外产出 VDI/VMDK (默认 false)
#   GZIP_IMAGES       true|false               (默认 true)
#   INCLUDE_DOCKER / INCLUDE_LXC / INCLUDE_ISTORE
#   EXTRA_PACKAGES    空格分隔的额外包名
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

usage() {
    cat <<'EOF'
用法: genconfig.sh [选项]

  -d, --dir DIR            源码目录（必填）
  -v, --version VER        24.10 | 25.12
      --target SUB         x86 子目标: 64 | generic | legacy   (默认 64)
      --rootfs-type TYPE   squashfs | ext4 | both              (默认 squashfs)
      --rootfs-size MiB    rootfs 分区大小                      (默认 1024)
      --kernel-part MiB    boot 分区大小                        (默认 32)
      --efi / --no-efi     是否生成 EFI 启动镜像                (默认 --efi)
      --vm-images          额外生成 VirtualBox VDI / VMware VMDK
      --no-gzip            不压缩镜像后缀 .gz
      --docker / --no-docker
      --lxc    / --no-lxc
      --istore / --no-istore
      --extra-packages LIST  额外包名，空格分隔
  -h, --help
EOF
}

SOURCE_DIR="${SOURCE_DIR:-}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10}"
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
INCLUDE_ISTORE="$(to_bool "${INCLUDE_ISTORE:-true}")"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
STRICT_PACKAGE_CHECK="$(to_bool "${STRICT_PACKAGE_CHECK:-false}")"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dir)            SOURCE_DIR="$2"; shift 2 ;;
        -v|--version)        OPENWRT_VERSION="$2"; shift 2 ;;
        --target)            TARGET_SUBTARGET="$2"; shift 2 ;;
        --rootfs-type)       ROOTFS_TYPE="$2"; shift 2 ;;
        --rootfs-size)       ROOTFS_SIZE="$2"; shift 2 ;;
        --kernel-part)       KERNEL_PART_SIZE="$2"; shift 2 ;;
        --efi)               EFI_IMAGES=true; shift ;;
        --no-efi)            EFI_IMAGES=false; shift ;;
        --gzip)              GZIP_IMAGES=true; shift ;;
        --no-gzip)           GZIP_IMAGES=false; shift ;;
        --vm-images)         VM_IMAGES=true; shift ;;
        --iso-images)        ISO_IMAGES=true; shift ;;
        --docker)            INCLUDE_DOCKER=true; shift ;;
        --no-docker)         INCLUDE_DOCKER=false; shift ;;
        --lxc)               INCLUDE_LXC=true; shift ;;
        --no-lxc)            INCLUDE_LXC=false; shift ;;
        --istore)            INCLUDE_ISTORE=true; shift ;;
        --no-istore)         INCLUDE_ISTORE=false; shift ;;
        --extra-packages)    EXTRA_PACKAGES="$2"; shift 2 ;;
        --strict-packages)   STRICT_PACKAGE_CHECK=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) die "未知参数: $1（用 -h 查看用法）" ;;
    esac
done

[ -n "$SOURCE_DIR" ] || die "必须指定源码目录 -d/--dir"
[ -d "$SOURCE_DIR" ] || die "源码目录不存在: $SOURCE_DIR"
validate_size "$ROOTFS_SIZE" || die "rootfs 分区大小非法"
validate_size "$KERNEL_PART_SIZE" 4 2048 || die "boot 分区大小非法(4~2048 MiB)"
case "$ROOTFS_TYPE" in squashfs|ext4|both) ;; *) die "不支持的固件格式: $ROOTFS_TYPE" ;; esac
case "$TARGET_SUBTARGET" in 64|generic|legacy) ;; *) die "不支持的 x86 子目标: $TARGET_SUBTARGET" ;; esac

cd "$SOURCE_DIR"
[ -f Makefile ] || die "这不像 OpenWrt 源码目录"
[ -f tmp/.packageinfo ] || warn "尚未执行 feeds install，缺包会被 defconfig 直接丢弃"

# ---------------------------------------------------------------------------
log "生成 .config | version=$OPENWRT_VERSION target=x86/$TARGET_SUBTARGET rootfs=$ROOTFS_TYPE ${ROOTFS_SIZE}MiB"
# ---------------------------------------------------------------------------
DIFFCONFIG="$(mktemp)"
{
    echo "### 由 openselfwrt builder 自动生成 $(date -u '+%F %T UTC') ###"

    # ---- 目标平台 ----
    echo "CONFIG_TARGET_x86=y"
    if [ "$TARGET_SUBTARGET" = "64" ]; then
        echo "CONFIG_TARGET_x86_64=y"
        echo "CONFIG_TARGET_x86_64_DEVICE_generic=y"
    else
        echo "CONFIG_TARGET_x86_${TARGET_SUBTARGET}=y"
        echo "CONFIG_TARGET_x86_${TARGET_SUBTARGET}_DEVICE_generic=y"
    fi

    # ---- 镜像格式与分区 ----
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=$KERNEL_PART_SIZE"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    case "$ROOTFS_TYPE" in
        squashfs) echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"; echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" ;;
        ext4)     echo "CONFIG_TARGET_ROOTFS_EXT4FS=y";     echo "CONFIG_TARGET_ROOTFS_SQUASHFS=n" ;;
        both)     echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y";   echo "CONFIG_TARGET_ROOTFS_EXT4FS=y" ;;
    esac
    echo "CONFIG_TARGET_ROOTFS_TARGZ=y"           # 便于塞进 Docker / PVE / LXC 模板
    echo "CONFIG_GRUB_IMAGES=y"
    [ "$EFI_IMAGES" = true ] && echo "CONFIG_GRUB_EFI_IMAGES=y" || echo "CONFIG_GRUB_EFI_IMAGES=n"
    [ "$GZIP_IMAGES" = true ] && echo "CONFIG_TARGET_IMAGES_GZIP=y" || echo "CONFIG_TARGET_IMAGES_GZIP=n"
    if [ "$VM_IMAGES" = true ]; then echo "CONFIG_VDI_IMAGES=y"; echo "CONFIG_VMDK_IMAGES=y"; fi
    if [ "$ISO_IMAGES" = true ]; then echo "CONFIG_ISO_IMAGES=y"; fi
    echo "CONFIG_TARGET_EXT4_JOURNAL=y"           # ext4 格式下启用日志

    # ---- 编译参数 ----
    echo "CONFIG_DEVEL=y"
    # ccache 默认关闭：它自身构建时用 CMake FetchContent 联网拉取依赖(xxhash 等)，
    # 一旦对应域名不可达就会中断整个编译；且一次性 CI runner 收益有限。
    # 需要加速增量构建时用 --ccache 显式打开。
    if [ "$(to_bool "${USE_CCACHE:-false}")" = true ]; then
        echo "CONFIG_CCACHE=y"
    else
        echo "CONFIG_CCACHE=n"
    fi
    echo "CONFIG_BUILD_LOG=y"
    echo "CONFIG_IB=n"
    echo "CONFIG_SDK=n"
    echo "CONFIG_AUTOREMOVE=y"
    echo "CONFIG_IMAGEOPT=y"
    echo "CONFIG_KERNEL_BUILD_USER=openselfwrt"
    echo "CONFIG_BUILD_NLS=y"
    echo "CONFIG_LUCI_LANG_zh_Hans=y"              # 让 luci-i18n-*-zh-cn 语言包可选
    # shadow-utils 的 menuconfig 里有个 `shadow-all` 开关，default y 会 select 出
    # 全部 35 个 shadow applet(login/su/passwd/chage…)，其中部分在 gcc 14 下编译失败。
    # LXC 只需要 newuidmap/newgidmap，这里显式关掉全选，只编清单里列出的子包。
    echo "CONFIG_shadow-all=n"
    # ---- 软件包清单 ----
    pkg_list "$CONF_DIR/base.pkgs" | list_to_conf
    [ "$INCLUDE_DOCKER" = true ] && pkg_list "$CONF_DIR/docker.pkgs" | list_to_conf
    if [ "$INCLUDE_LXC" = true ]; then
        # OpenWrt 的 shadow 是"整份源码 configure+make 完再按 applet 拆成多个 ipk"，
        # 所以只要选中任何一个 shadow-* 子包，源码里全部 35 个 applet 都会被编译。
        # shadow 4.19.4 在 25.12 的 gcc 14.3 下编译失败，这里按版本把整族排除掉。
        # 代价：25.12 下 LXC 非特权容器缺少 newuidmap/newgidmap（特权容器不受影响）。
        if [ "$OPENWRT_VERSION" = "25.12" ]; then
            warn "25.12 下跳过 shadow 相关包：它们在 gcc 14.3 下编译失败"
            warn "  → LXC 非特权容器将没有 newuidmap/newgidmap，特权容器不受影响"
            pkg_list "$CONF_DIR/lxc.pkgs" | grep -v '^shadow' | list_to_conf
        else
            pkg_list "$CONF_DIR/lxc.pkgs" | list_to_conf
        fi
    fi
    [ "$INCLUDE_ISTORE" = true ] && pkg_list "$CONF_DIR/istore.pkgs" | list_to_conf
    [ -n "$EXTRA_PACKAGES" ] && { for p in $EXTRA_PACKAGES; do echo "CONFIG_PACKAGE_$p=y"; done; }

    # ---- 内核特性：Docker / LXC 需要的 cgroup / namespace / netfilter ----
    while read -r sym; do
        case "$sym" in ''|'#'*) continue ;; esac
        echo "CONFIG_KERNEL_$sym=y"
    done < "$CONF_DIR/kernel/docker-lxc.opts"
} > "$DIFFCONFIG"

cp -f "$DIFFCONFIG" .config

# ---------------------------------------------------------------------------
log "make defconfig（解析依赖关系，约需 1~3 分钟）"
# ---------------------------------------------------------------------------
DEFCONF_LOG="/tmp/openselfwrt-defconfig.log"
if ! run make defconfig V=s >"$DEFCONF_LOG" 2>&1; then
    err "make defconfig 失败，关键信息如下："
    grep -Ei "error|warning" "$DEFCONF_LOG" | tail -n 30 >&2 || true
    exit 1
fi

# ---------------------------------------------------------------------------
log "校验关键配置是否落地"
# ---------------------------------------------------------------------------
check_missing=0
check_config_value() {
    local key="$1" expect="$2" got
    got="$(grep -m1 "^${key}=" .config | cut -d= -f2- || true)"
    if [ "$got" != "$expect" ]; then
        err "配置项未按预期生效: $key = '$got' (期望 '$expect')"
        check_missing=$((check_missing + 1))
    else
        printf '  OK   %s=%s\n' "$key" "$got"
    fi
}

check_config_value CONFIG_TARGET_ROOTFS_PARTSIZE "$ROOTFS_SIZE"
check_config_value CONFIG_TARGET_KERNEL_PARTSIZE "$KERNEL_PART_SIZE"
if [ "$ROOTFS_TYPE" != "both" ]; then
    case "$ROOTFS_TYPE" in
        squashfs) check_config_value CONFIG_TARGET_ROOTFS_SQUASHFS y ;;
        ext4)     check_config_value CONFIG_TARGET_ROOTFS_EXT4FS y ;;
    esac
fi

# 关键包必须存在，否则说明包名写错或该版本 feed 里没有
check_package() {
    local p="$1"
    if grep -qx "CONFIG_PACKAGE_$p=y" .config; then
        printf '  OK   包 %s 已选中\n' "$p"
    else
        warn "包未被选中(可能不存在于该版本源): $p"
        check_missing=$((check_missing + 1))
    fi
}

declare -a REQUIRED_PKGS=()
[ "$INCLUDE_DOCKER" = true ] && REQUIRED_PKGS+=(dockerd docker)
[ "$INCLUDE_LXC" = true ] && REQUIRED_PKGS+=(lxc lxc-templates)
for p in ${REQUIRED_PKGS[@]+"${REQUIRED_PKGS[@]}"}; do check_package "$p"; done

if [ "$check_missing" -ne 0 ]; then
    if [ "$STRICT_PACKAGE_CHECK" = true ]; then
        die "有 $check_missing 项未按预期生效，终止构建"
    else
        warn "有 $check_missing 项未按预期生效（非严格模式，继续构建）"
    fi
else
    log "全部关键项校验通过"
fi

OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
mkdir -p "$OUT_DIR"
# 产物统一带 openwrt-<版本>- 前缀：两个版本都构建时不会互相覆盖，
# 一起传到 GitHub Release 也不会因同名被自动改名。
PFX="openwrt-$OPENWRT_VERSION"
cp -f .config "$OUT_DIR/${PFX}-config.buildinfo.raw"
log "已生成 $(pwd)/.config"

# 输出一份精简 diffconfig，方便复现与排查
if ./scripts/diffconfig.sh > "$OUT_DIR/${PFX}-diffconfig.txt" 2>/dev/null; then
    log "已输出差异配置: $OUT_DIR/${PFX}-diffconfig.txt"
else
    warn "生成 diffconfig 失败（不影响构建）"
fi
