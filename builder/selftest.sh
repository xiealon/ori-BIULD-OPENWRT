#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 离线自测：不动网络、不下载源码，纯验证脚本自身是否健康
#   ./builder/selftest.sh
# 可选：SOURCE_DIR=/path/to/openwrt ./builder/selftest.sh   # 额外验证 .config 生成
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd .. && pwd)"
# shellcheck source=lib.sh
source ./lib.sh

FAILED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }

echo "== 1. 语法检查 =="
for f in "$REPO_ROOT"/builder/*.sh; do
    if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
if python3 -m py_compile "$REPO_ROOT/builder/render-defaults.py" 2>/dev/null; then
    ok "python 编译 render-defaults.py"
else
    bad "python 编译 render-defaults.py"
fi
if sh -n "$REPO_ROOT/files/etc/uci-defaults/99-openselfwrt" 2>/dev/null; then
    ok "uci-defaults 模板语法(POSIX sh)"
else
    bad "uci-defaults 模板语法"
fi

echo "== 2. 参数校验 =="
validate_ipv4 192.168.1.1 && ok "合法 IP 通过" || bad "合法 IP 被误判"
! validate_ipv4 192.168.1.256 2>/dev/null && ok "非法 IP 被拦截" || bad "非法 IP 未拦截"
! validate_ipv4 10.0.0 2>/dev/null && ok "缺段 IP 被拦截" || bad "缺段 IP 未拦截"
validate_size 1024 64 1048576 && ok "合法分区大小通过" || bad "合法分区被误判"
! validate_size 8 64 1048576 2>/dev/null && ok "过小分区被拦截" || bad "过小分区未拦截"
validate_size 32 4 2048 && ok "boot 分区 32MiB 通过" || bad "boot 分区范围错误"
[ "$(normalize_ip_list '1.1.1.1, 8.8.8.8  114.114.114.114')" = "1.1.1.1 8.8.8.8 114.114.114.114" ] \
    && ok "DNS 列表归一化" || bad "DNS 列表归一化"
[ "$(to_bool YES)" = true ] && [ "$(to_bool off)" = false ] && ok "布尔值归一化" || bad "布尔值归一化"

echo "== 3. 密码散列 =="
HASH="$(hash_password 'OpenWrt@2024')"
case "$HASH" in
    '$6$'*) ok "生成 sha512crypt 散列" ;;
    *) bad "散列格式异常: ${HASH:0:10}" ;;
esac
if command -v python3 >/dev/null 2>&1; then
python3 - "$HASH" <<'PY' 2>/dev/null
import crypt, sys
h = sys.argv[1]
ok = crypt.crypt('OpenWrt@2024', h) == h and crypt.crypt('wrong', h) != h
sys.exit(0 if ok else 1)
PY
    if [ $? -eq 0 ]; then ok "密码可校验（正确密码通过、错误密码拒绝）"; else bad "密码校验失败"; fi
fi

echo "== 4. uci-defaults 渲染 =="
TMPD="$(mktemp -d)"
if python3 "$REPO_ROOT/builder/render-defaults.py" \
        --template "$REPO_ROOT/files/etc/uci-defaults/99-openselfwrt" \
        --out "$TMPD/99-test" \
        --lan-ip 10.0.0.2 --lan-netmask 255.255.255.0 --bypass-mode true \
        --upstream-gateway 10.0.0.1 --dns "223.5.5.5 119.29.29.29" \
        --hostname TestBox --timezone CST-8 --root-hash "$HASH" \
        --include-docker true >/dev/null; then
    ok "模板渲染成功"
    grep -q "CFG_LAN_IP='10.0.0.2'" "$TMPD/99-test" && ok "LAN IP 已注入" || bad "LAN IP 未注入"
    grep -q "CFG_BYPASS_MODE='true'" "$TMPD/99-test" && ok "旁路由模式已注入" || bad "旁路由模式未注入"
    grep -q "$HASH" "$TMPD/99-test" && ok "密码散列已注入" || bad "密码散列未注入"
    grep -qE '^__[A-Z_]+__$' "$TMPD/99-test" && bad "存在未替换占位符" || ok "无残留占位符"
    sh -n "$TMPD/99-test" && ok "渲染结果语法正确" || bad "渲染结果语法错误"
else
    bad "模板渲染失败"
fi
rm -rf "$TMPD"

echo "== 5. 包清单格式 =="
for f in "$REPO_ROOT"/config/*.pkgs; do
    n=$(grep -cvE '^\s*(#|$)' "$f")
    [ "$n" -gt 0 ] && ok "$(basename "$f") 含 $n 个包" || bad "$(basename "$f") 为空"
done
n=$(grep -cvE '^\s*(#|$)' "$REPO_ROOT/config/kernel/docker-lxc.opts")
[ "$n" -gt 20 ] && ok "内核选项 $n 条" || bad "内核选项过少"

echo "== 6. Workflow =="
if command -v actionlint >/dev/null 2>&1; then
    actionlint "$REPO_ROOT/.github/workflows/build-openwrt.yml" && ok "actionlint 无告警" || bad "actionlint 发现问题"
else
    note "未安装 actionlint，跳过"
fi
python3 - <<'PY' "$REPO_ROOT"
import sys, re
root = sys.argv[1]
try:
    txt = open(root + "/.github/workflows/build-openwrt.yml").read()
    n = txt.count("      ")  # 粗略缩进计数
    inputs = txt.count("        description:")
    print(("  PASS" if inputs <= 10 else "  FAIL") + f" workflow_dispatch 输入项 {inputs} 个(上限 10)")
except Exception as e:
    print("  FAIL 读取 workflow: %s" % e)
PY

echo "== 7. 环境健壮性处理 =="
# 这几条都是实盘编译踩过的坑：root 身份、宿主 runc 污染、ccache 联网拉依赖
grep -q "FORCE_UNSAFE_CONFIGURE" "$REPO_ROOT/builder/build.sh" \
    && ok "build.sh 处理了 root 身份编译" || bad "build.sh 缺少 root 身份处理"
grep -q "runc.openselfwrt-disabled" "$REPO_ROOT/builder/build.sh" \
    && ok "build.sh 规避宿主 runc 污染" || bad "build.sh 缺少 runc 污染规避"
grep -q "restore_runc" "$REPO_ROOT/builder/build.sh" \
    && ok "build.sh 会在结束后恢复 runc" || bad "build.sh 未恢复 runc"
grep -q "CONFIG_CCACHE=n" "$REPO_ROOT/builder/genconfig.sh" \
    && ok "ccache 默认关闭" || bad "ccache 未默认关闭"
grep -q "USE_CCACHE" "$REPO_ROOT/.github/workflows/build-openwrt.yml" \
    && ok "workflow 联动 USE_CCACHE" || bad "workflow 未联动 USE_CCACHE"
grep -q "insteadOf" "$REPO_ROOT/builder/prepare.sh" \
    && ok "prepare.sh 配置了 git URL 重写(代理)" || bad "prepare.sh 缺少 git 代理重写"

echo
if [ "$FAILED" -eq 0 ]; then
    log "自测全部通过"
else
    err "自测失败 $FAILED 项"
    exit 1
fi
