#!/usr/bin/env python3
"""把 files/etc/uci-defaults 模板渲染为最终脚本（避免 sed 转义地狱）。

模板里用 __LAN_IP__ 之类的占位符，这里做纯文本替换。
"""
import argparse
import os
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--template", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--lan-ip", default="192.168.1.1")
    p.add_argument("--lan-netmask", default="255.255.255.0")
    p.add_argument("--bypass-mode", default="false")
    p.add_argument("--upstream-gateway", default="")
    p.add_argument("--dns", default="")
    p.add_argument("--hostname", default="OpenWrt")
    p.add_argument("--timezone", default="CST-8")
    p.add_argument("--root-hash", default="")
    p.add_argument("--include-docker", default="true")
    a = p.parse_args()

    if not os.path.isfile(a.template):
        sys.exit("模板不存在: %s" % a.template)

    with open(a.template, "r", encoding="utf-8") as f:
        content = f.read()

    mapping = {
        "__LAN_IP__": a.lan_ip,
        "__LAN_NETMASK__": a.lan_netmask,
        "__BYPASS_MODE__": a.bypass_mode,
        "__UPSTREAM_GATEWAY__": a.upstream_gateway,
        "__DNS_SERVERS__": a.dns,
        "__HOSTNAME__": a.hostname,
        "__TIMEZONE__": a.timezone,
        "__ROOT_HASH__": a.root_hash,
        "__INCLUDE_DOCKER__": a.include_docker,
    }
    for k, v in mapping.items():
        content = content.replace(k, v)

    leftover = [k for k in mapping if k in content]
    if leftover:
        sys.exit("模板中仍有未替换的占位符: %s" % ", ".join(leftover))

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(content)
    print("[INFO] 已生成 %s" % a.out)


if __name__ == "__main__":
    main()
