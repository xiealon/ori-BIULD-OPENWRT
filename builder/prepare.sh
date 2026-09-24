#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 拉取 OpenWrt 源码 + 软件源(feeds)，可选接入 iStore 源
#
# 环境变量（均可通过参数覆盖）:
#   OPENWRT_VERSION   24.10 | 25.12        （默认 24.10）
#   SOURCE_DIR        源码目录             （默认 ./openwrt-<version>）
#   SOURCE_URL        openwrt 主源码 git 地址
#   FEED_MIRROR       github | official   （默认 github，CI 上更快）
#   GH_PROXY          形如 https://gh-proxy.com ，给 GitHub 地址加前缀
#   INCLUDE_ISTORE    true | false        （默认 false）
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

usage() {
    cat <<'EOF'
用法: prepare.sh [选项]

选项:
  -v, --version VER       OpenWrt 版本: 24.10 或 25.12   (默认 24.10)
  -d, --dir DIR           源码存放目录                    (默认 openwrt-<version>)
      --source-url URL    自定义源码仓库地址
      --feed-mirror KIND  github | official               (默认 github)
      --gh-proxy URL      为所有 GitHub 请求加代理前缀
      --istore / --no-istore   是否集成 iStore 软件源的 luci-app-store
      --skip-feeds        只拉源码，不更新 feeds（调试用）
  -h, --help
EOF
}

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10}"
SOURCE_URL="${SOURCE_URL:-https://github.com/openwrt/openwrt.git}"
FEED_MIRROR="${FEED_MIRROR:-github}"
GH_PROXY="${GH_PROXY:-}"
INCLUDE_ISTORE="$(to_bool "${INCLUDE_ISTORE:-false}")"
SKIP_FEEDS="$(to_bool "${SKIP_FEEDS:-false}")"
SOURCE_DIR="${SOURCE_DIR:-}"
UPDATE_SOURCE="true"

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)      OPENWRT_VERSION="$2"; shift 2 ;;
        -d|--dir)          SOURCE_DIR="$2"; shift 2 ;;
        --source-url)      SOURCE_URL="$2"; shift 2 ;;
        --feed-mirror)     FEED_MIRROR="$2"; shift 2 ;;
        --gh-proxy)        GH_PROXY="$2"; shift 2 ;;
        --istore)          INCLUDE_ISTORE=true; shift ;;
        --no-istore)       INCLUDE_ISTORE=false; shift ;;
        --skip-feeds)      SKIP_FEEDS=true; shift ;;
        --no-update-source) UPDATE_SOURCE="false"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) die "未知参数: $1（用 -h 查看用法）" ;;
    esac
done

case "$OPENWRT_VERSION" in
    24.10|25.12) ;;
    *) die "暂不支持的版本: $OPENWRT_VERSION（仅支持 24.10 / 25.12）" ;;
esac
[ -z "$SOURCE_DIR" ] && SOURCE_DIR="openwrt-$OPENWRT_VERSION"
GH_PROXY="${GH_PROXY%/}"

require git
BRANCH="openwrt-$OPENWRT_VERSION"
REPO_URL="$SOURCE_URL"
if [ -n "$GH_PROXY" ]; then
    case "$REPO_URL" in
        https://github.com/*) REPO_URL="${GH_PROXY}/${REPO_URL}" ;;
    esac
    # 光给 feeds.conf 加前缀还不够：编译期有些包(典型是 docker/dockerd)会直接
    # git ls-remote GitHub 仓库来校验版本，网络受限时会中断编译。
    # 用 git 的 URL 重写把这类访问也一并走代理。
    git config --global "url.${GH_PROXY}/https://github.com/.insteadOf" "https://github.com/"
    note "已配置 git URL 重写: https://github.com/ -> ${GH_PROXY}/https://github.com/"
fi

# ---------------------------------------------------------------------------
log "准备 OpenWrt $OPENWRT_VERSION 源码 -> $SOURCE_DIR"
# ---------------------------------------------------------------------------
if [ -d "$SOURCE_DIR/.git" ]; then
    if [ "$UPDATE_SOURCE" = "true" ]; then
        log "目录已存在，切换到 $BRANCH 分支"
        run git -C "$SOURCE_DIR" fetch --depth 1 origin "$BRANCH"
        run git -C "$SOURCE_DIR" checkout -f FETCH_HEAD
    else
        note "复用已有源码目录（--no-update-source）"
    fi
else
    mkdir -p "$SOURCE_DIR"
    run git init -q "$SOURCE_DIR"
    run git -C "$SOURCE_DIR" remote add origin "$REPO_URL"
    log "浅克隆 $BRANCH（--depth 1）"
    run git -C "$SOURCE_DIR" fetch --depth 1 origin "$BRANCH"
    run git -C "$SOURCE_DIR" checkout -f FETCH_HEAD
fi
[ -f "$SOURCE_DIR/feeds.conf.default" ] || die "源码不完整: 缺少 feeds.conf.default"

# 供后续脚本读取源码真实路径
SOURCE_ABS_PATH="$(cd "$SOURCE_DIR" && pwd)"
printf '%s' "$SOURCE_ABS_PATH" > /tmp/.openselfwrt-source-dir
note "源码绝对路径: $SOURCE_ABS_PATH"

# ---------------------------------------------------------------------------
log "生成 feeds.conf（mirror=$FEED_MIRROR, istore=$INCLUDE_ISTORE）"
# ---------------------------------------------------------------------------
FEEDS_FILE="$SOURCE_DIR/feeds.conf"
cp -f "$SOURCE_DIR/feeds.conf.default" "$FEEDS_FILE"

if [ "$FEED_MIRROR" = "github" ]; then
    # git.openwrt.org 在某些网络里很慢，GitHub 上是官方镜像，分支名一致
    sed -i -e 's|https://git\.openwrt\.org/feed/|https://github.com/openwrt/|g' \
           -e 's|https://git\.openwrt\.org/project/|https://github.com/openwrt/|g' \
           "$FEEDS_FILE"
fi

if [ "$INCLUDE_ISTORE" = true ]; then
    grep -q "linkease/istore" "$FEEDS_FILE" || \
        echo "src-git istore https://github.com/linkease/istore;main" >> "$FEEDS_FILE"
fi

if [ -n "$GH_PROXY" ]; then
    sed -i "s|https://github\.com/|${GH_PROXY}/https://github.com/|g" "$FEEDS_FILE"
fi
sed -i 's|^src-git-full |src-git |g' "$FEEDS_FILE"   # 统一用浅层 feeds，加快克隆
note "feeds.conf 内容:"; sed 's/^/  | /' "$FEEDS_FILE"

if [ "$SKIP_FEEDS" = true ]; then
    note "跳过 feeds 更新（--skip-feeds）"
    exit 0
fi

# ---------------------------------------------------------------------------
log "更新并安装 feeds（首次较慢，CI 上建议开启缓存）"
# ---------------------------------------------------------------------------
cd "$SOURCE_DIR"
run ./scripts/feeds update -a
run ./scripts/feeds install -a

if [ "$INCLUDE_ISTORE" = true ]; then
    [ -f "feeds/istore.index" ] || die "iStore 源更新失败，请检查网络或 GH_PROXY 配置"
    run ./scripts/feeds install -d y -p istore luci-app-store
    grep -q "luci-app-store" tmp/.packageinfo 2>/dev/null \
        || warn "未能在 feeds 中找到 luci-app-store，后续如遇缺包属正常（该 feed 可能暂不支持 $OPENWRT_VERSION）"
fi

log "源码准备完成"
