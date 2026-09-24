#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 编译后处理：把固件、配置清单、校验值整理到 out/ 目录
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

SOURCE_DIR="${SOURCE_DIR:-$(cat /tmp/.openselfwrt-source-dir 2>/dev/null || true)}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
OPENWRT_VERSION="${OPENWRT_VERSION:-}"
[ -n "$SOURCE_DIR" ] || die "未指定源码目录 SOURCE_DIR"
[ -d "$SOURCE_DIR" ] || die "源码目录不存在: $SOURCE_DIR"

# 单独调用时可能没带版本号，从源码的 git 分支补（分支形如 openwrt-24.10）
if [ -z "$OPENWRT_VERSION" ]; then
    OPENWRT_VERSION="$(git -C "$SOURCE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null \
        | sed -n 's/^openwrt-//p')"
    [ -n "$OPENWRT_VERSION" ] && note "从 git 分支推断版本: $OPENWRT_VERSION"
fi
[ -n "$OPENWRT_VERSION" ] || die "无法确定 OpenWrt 版本号，无法为产物加前缀"

# 所有产物统一带 openwrt-<版本>- 前缀，避免多版本产物同名互相覆盖
PFX="openwrt-$OPENWRT_VERSION"

FIRMWARE_DIR="$SOURCE_DIR/bin/targets"
[ -d "$FIRMWARE_DIR" ] || die "找不到产物目录: $FIRMWARE_DIR"

mkdir -p "$OUT_DIR/firmware"
log "整理产物 -> $OUT_DIR"

# 复制固件与 IPK 索引
mapfile -t IMGS < <(find "$FIRMWARE_DIR" -maxdepth 3 -type f \
    \( -name "*.img" -o -name "*.img.gz" -o -name "*.tar.gz" -o -name "*.vdi" -o -name "*.vmdk" -o -name "*.iso" -o -name "*.bin" \) 2>/dev/null)

if [ ${#IMGS[@]} -eq 0 ]; then
    err "没有找到任何固件镜像，编译可能只产出了 IPK"
    exit 1
fi

for f in "${IMGS[@]}"; do
    # openwrt-x86-64-generic-*.img -> openwrt-24.10-x86-64-generic-*.img
    base="$(basename "$f")"
    cp -f "$f" "$OUT_DIR/firmware/${base/#openwrt-/${PFX}-}"
done

# 构建信息（OpenWrt 原生文件名不带版本，同样加前缀）
for info in "$FIRMWARE_DIR"/*/*/config.buildinfo "$FIRMWARE_DIR"/*/*/feeds.buildinfo "$FIRMWARE_DIR"/*/*/version.buildinfo "$FIRMWARE_DIR"/*/*/profiles.json; do
    if [ -f "$info" ]; then cp -f "$info" "$OUT_DIR/${PFX}-$(basename "$info")"; fi
done

# 校验值
( cd "$OUT_DIR/firmware" && sha256sum ./* > "$OUT_DIR/${PFX}-sha256sums.txt" ) 2>/dev/null || true

# 概览信息
{
    echo "# openselfwrt 构建概览"
    echo "版本        : OpenWrt ${OPENWRT_VERSION:-unknown}"
    echo "构建时间    : $(date -u '+%F %T UTC')"
    echo "目标        : $(basename "$(dirname "$(find "$FIRMWARE_DIR" -mindepth 2 -maxdepth 2 -type d | head -1)")")/$(basename "$(find "$FIRMWARE_DIR" -mindepth 2 -maxdepth 2 -type d | head -1)")"
    echo "rootfs 大小 : $(grep -m1 '^CONFIG_TARGET_ROOTFS_PARTSIZE=' "$SOURCE_DIR/.config" | cut -d= -f2) MiB"
    echo "boot 分区   : $(grep -m1 '^CONFIG_TARGET_KERNEL_PARTSIZE=' "$SOURCE_DIR/.config" | cut -d= -f2) MiB"
    echo "格式        : $(grep -q '^CONFIG_TARGET_ROOTFS_SQUASHFS=y' "$SOURCE_DIR/.config" && echo -n 'squashfs ')$(grep -q '^CONFIG_TARGET_ROOTFS_EXT4FS=y' "$SOURCE_DIR/.config" && echo -n 'ext4 ')"
    echo "集成        : $(grep -q '^CONFIG_PACKAGE_dockerd=y' "$SOURCE_DIR/.config" && echo -n 'docker ')$(grep -qE '^CONFIG_PACKAGE_lxc=y' "$SOURCE_DIR/.config" && echo -n 'lxc ')$(grep -q '^CONFIG_PACKAGE_luci-app-store=y' "$SOURCE_DIR/.config" && echo -n 'istore ')"
    echo ""
    echo "## 产物清单"
    du -bh "$OUT_DIR/firmware"/* 2>/dev/null | sort -k2 || true
} | tee "$OUT_DIR/${PFX}-build-summary.md"

log "固件已整理到 $OUT_DIR/firmware"
