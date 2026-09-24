# openselfwrt builder

用 GitHub Actions 编译**属于你自己的 OpenWrt x86_64 固件**：可选 24.10 / 25.12 版本、自选 rootfs 空间与镜像格式，出厂就内置 Docker、LXC 与 iStore 软件商店，并预置好 LAN 地址、网关、DNS、旁路由模式和开机密码。

不需要本地 20G 磁盘和几小时等待 —— 点几下就能拿到成品固件。

## 能做什么

| 能力 | 说明 |
| --- | --- |
| 版本 | OpenWrt **24.10**（kernel 6.6）与 **25.12**（kernel 6.12，apk 包管理器），另有 x86 子目标 `64` / `generic` / `legacy` |
| 固件格式 | `squashfs`（自带重置机制，推荐） / `ext4`（可直接 dd 扩容） / `both`（一次产出两套） |
| rootfs 大小 | 自选 MiB，默认 1024，支持 256 ~ 1048576，写入 `CONFIG_TARGET_ROOTFS_PARTSIZE` |
| boot 分区 | 默认 32 MiB（`CONFIG_TARGET_KERNEL_PARTSIZE`） |
| Docker | 官方 feed 的 `dockerd` + `docker` CLI + `docker-compose` + `containerd` + `runc`，附 LUCI 容器管理界面 |
| LXC | 官方 feed 的 `lxc`(6.0.x) 全家桶 + `luci-app-lxc` |
| iStore | 通过 `linkease/istore` feed 集成 `luci-app-store` 软件商店 |
| 内核 | 自动追加 Docker/LXC 需要的 cgroup、namespace、netfilter、overlay 等 ~90 个内核选项 |
| 网络预设 | LAN IP、子网掩码、主路由/旁路由模式、上级网关、DNS |
| 账户 | root 开机密码（sha512crypt 写入 `/etc/shadow`，非明文） |

## 快速开始（GitHub Actions）

1. **Fork / 上传**本仓库到你自己的 GitHub。
2. 打开仓库 → `Actions` → 左侧选 **Build OpenWrt x86 Firmware** → 右上角 **Run workflow**。
3. 按需填参数（`workflow_dispatch` 受 GitHub 限制最多 10 个输入，其余走 `extra_flags`）：

   | 输入 | 默认 | 说明 |
   | --- | --- | --- |
   | `openwrt_version` | `24.10` | **`24.10`**（推荐，稳定）或 `25.12`（预览，kernel 6.12 + apk） |
   | `rootfs_type` | `squashfs` | `squashfs` / `ext4` / `both`（一次出两套） |
   | `rootfs_size` | `1024` | rootfs 分区 MiB（256~1048576 均可输在这三个之外的要改 workflow） |
   | `mode` | `router` | `bypass` = 旁路由，自动关 DHCP / DHCPv6 / RA |
   | `lan_ip` | `192.168.1.1` | 出厂管理地址（掩码固定 255.255.255.0，要改见下方 flags） |
   | `upstream_gateway` | `192.168.1.1` | 旁路由模式下的上级网关（主路由 IP） |
   | `dns_servers` | `223.5.5.5,119.29.29.29` | 写进 `network.lan.dns` 与 dnsmasq 转发上游 |
   | `root_password` | `password` | 开机即用；留空 = OpenWrt 默认空密码 |
   | `publish_release` | `true` | 自动发 Release 并上传固件 |

   其余开关填在 **`extra_flags`**（原样传给 `builder/build.sh`，空格分隔、不要加引号）：

   ```text
   --target legacy            # x86 子目标：64(默认) / generic / legacy
   --kernel-part 64           # boot 分区 MiB，默认 32
   --hostname MyRouter        # 主机名
   --netmask 255.255.240.0    # 自定义掩码
   --no-efi                   # 不生成 EFI 镜像（纯 Legacy BIOS）
   --no-gzip                  # 不压缩 .gz
   --vm-images                # 额外产出 VDI / VMDK
   --no-docker --no-lxc --no-istore   # 关掉某个集成组件
   --extra-packages luci-theme-argon curl rsync
   ```

4. 等待 1.5~4 小时（取决于 runner 负载），完成后在 **Artifacts** 或 **Releases** 里下载：
   - `openwrt-24.10-x86-64-generic-squashfs-combined-efi.img.gz` —— 物理机/虚拟机整机镜像（UEFI）
   - `openwrt-24.10-x86-64-generic-squashfs-combined.img.gz` —— Legacy BIOS 镜像
   - `openwrt-24.10-x86-64-generic-rootfs.tar.gz` —— Docker / PVE LXC 模板素材
   - `openwrt-24.10-sha256sums.txt`、`openwrt-24.10-config.buildinfo.raw`、`openwrt-24.10-diffconfig.txt` —— 校验与复现用

> **产物一律带 `openwrt-<版本>-` 前缀。** 因为 24.10 和 25.12 编出来的文件名天生一模一样（都是 `openwrt-x86-64-generic-...`），不带前缀的话两个版本放一起会互相覆盖，传到 GitHub Release 也会被自动改成 `xxx (1)` 这种名字。加了前缀后，多版本产物可以放心混放在同一个 Release 里。

> runner 有 **6 小时**上限。三件套全开 + x86_64 通常够用；若超时，关掉 iStore 或减小 rootfs 重试。

## 本地也能跑（不依赖 GitHub）

任意装好编译依赖的 Linux：

```bash
# Ubuntu / Debian 依赖
sudo apt update && sudo apt install -y --no-install-recommends $(./builder/deps-debian.txt)

# 一条命令出固件：25.12 + squashfs 2G + 三件套 + 旁路网关，root 密码 12345678
./builder/build.sh \
  --version 25.12 --rootfs-type squashfs --rootfs-size 2048 \
  --lan-ip 192.168.5.2 --netmask 255.255.255.0 \
  --mode bypass --gateway 192.168.5.1 \
  --dns "223.5.5.5,119.29.29.29" \
  --password "12345678" --hostname OpenWrt-Docker

# 只要配置不要-image（几秒验证参数是否合法）
SOURCE_DIR=./openwrt-24.10 ./builder/build.sh -v 24.10 --skip-prepare --skip-build --strict-packages
```

产物统一落在仓库根目录的 `out/`：`out/firmware/` 镜像、`out/build-summary.md` 概览、`out/sha256sums.txt` 校验值。

网络不通 GitHub 时可以给它套个加速前缀（对 pull/clone 同样生效）：

```bash
GH_PROXY=https://gh-proxy.com FEED_MIRROR=github ./builder/build.sh -v 24.10
```

## 目录结构

```
.
├── .github/workflows/build-openwrt.yml   # Actions：参数输入 → 编译 → 上传 Release
├── builder/                              # 构建引擎（bash + 一个 python 渲染器）
│   ├── build.sh            # 总入口，串起下面 4 个步骤
│   ├── prepare.sh          # 拉源码 / feeds / iStore 源
│   ├── genconfig.sh        # 生成 .config + make defconfig + 结果校验
│   ├── apply-defaults.sh   # 注入 IP/DNS/旁路由/密码到 files/
│   ├── render-defaults.py  # 模板渲染（占位符替换）
│   ├── postbuild.sh        # 整理产物、算 sha256、写概览
│   └── lib.sh              # 日志、校验、密码散列
├── config/
│   ├── base.pkgs docker.pkgs lxc.pkgs istore.pkgs   # 包清单，想加减软件包改这里
│   └── kernel/docker-lxc.opts                       # 容器所需内核选项
└── files/etc/uci-defaults/99-openselfwrt            # 首次开机执行的 UCI 脚本模板
```

**想加软件**：往 `config/*.pkgs` 里加包名（一行一个，`#` 注释）。包名不存在时只会告警不会中断，想要严格模式加 `--strict-packages`。

## 网络模式怎么选

| | `router`（默认） | `bypass`（旁路由） |
| --- | --- | --- |
| 本机身份 | 出口网关 | 内网的一台 hostserver，不做出网 NAT |
| DHCP | 本机下发，客户端 DNS 下发为 `--dns` 指定值 | 关闭 DHCP / DHCPv6 / RA，避免和主路由打架 |
| 典型用法 | 直接当主路由拨号（此时 wan 口自行在 LUCI 配 PPPoE） | 主路由拨号，旁路由跑 Docker/插件；需要上网的设备把网关指到这里 |
| 需要注意 | 记得改 IP 避免和光猫冲突 | `--gateway` 必须填主路由 IP，否则本机自身解析会失败 |

两种模式都会把 `--dns` 写进 `network.lan.dns` 和 dnsmasq 的转发上游，避免兜到运营商 DNS。

## 改动后先验一下

任何对 `builder/` 或 `config/` 的修改，都可以先用离线自测跑一遍（不联网、不下载源码，约 2 秒）：

```bash
./builder/selftest.sh
```

它检查：脚本语法、uci-defaults 模板渲染、IP/分区参数防御、密码散列可校验性、包清单非空、workflow 输入项不超过 GitHub 的 10 个上限、actionlint 告警。

## 版本怎么选

**默认就是 24.10，别轻易改。**

| | 24.10（推荐） | 25.12（预览） |
| --- | --- | --- |
| 内核 | 6.6 | 6.12 |
| 包管理器 | opkg | apk |
| 稳定性 | ✅ 完整验证通过 | ⚠️ 上游滚动更新，包随时可能编不过 |
| iStore | ✅ 支持 | ⚠️ 跟进较慢 |
| LXC 非特权容器 | ✅ newuidmap/newgidmap 齐全 | ❌ 缺 newuidmap/newgidmap |

25.12 之所以有最后一行的差别：OpenWrt 的 `shadow` 包是**整份源码 configure + make 完再按 applet 拆成多个 ipk**，只要选中任何一个 `shadow-*` 子包，源码里全部 35 个 applet 都会被编译；而 shadow 4.19.4 在 25.12 的 gcc 14.3 下编不过。所以 `genconfig.sh` 在检测到 25.12 时会把整个 shadow 族剔除：

```
被剔除：shadow-utils  shadow-newuidmap  shadow-newgidmap
```

**特权 LXC 容器完全不受影响**，只有非特权容器（把宿主机 UID 映射进容器）会缺这俩工具。

> 切版本的能力完整保留 —— `.github/workflows/build-openwrt.yml` 里的 `options: ['24.10', '25.12']` 和 `-v/--version` 参数都能用，只是默认落在更稳的那一档。等上游修好 shadow，删掉 `genconfig.sh` 里那段版本判断即可恢复。

## 用 diffconfig 复现一次构建

`config/diffconfig-24.10.txt` / `config/diffconfig-25.12.txt` 是 OpenWrt 官方 `scripts/diffconfig.sh` 的输出，**只记录与默认值不同的项**（几百行），不是完整 `.config`（上万行）。两种用法：

**A. 想脱离 builder 复现同样的固件**（在 OpenWrt 源码根目录执行）：

```bash
cp /path/to/diffconfig-24.10.txt .config
./scripts/feeds update -a && ./scripts/feeds install -a
make defconfig          # 把精简配置展开成完整配置
make -j"$(nproc)"
```

**B. 当配置存档提交进你自己的仓库**：它体积小、可读、好 review；OpenWrt 升级后默认值变了也不会冲突，比直接提交完整 `.config` 好维护得多。

想改预置内容时，改 `config/*.pkgs` 或 `files/etc/uci-defaults/99-openselfwrt` 里的参数重新构建即可，不必手改 diffconfig。

## 常见问题

**squashfs 还是 ext4？**
想要「重置固件」按钮和更强的容错选 squashfs；想直接 dd / resize2fs 扩分区、往根目录猛写数据选 ext4。实际装机推荐 squashfs + 大 rootfs。

**rootfs 多大合适？**
Docker 镜像一个 100~800MB 起跳。跑容器建议 ≥1024 MiB，打算塞多个镜像直接给 4096 或 8192。注意 ext4 镜像文件本身就会是这个体积。

**密码忘了怎么办？**
`squashfs` 固件可以在 LUCI 里「保留配置重置」后回到出厂（出厂就是 `--password` 设的密码）；物理机最稳的办法还是串口/救援模式改 shadow。

**iStore 在 25.12 上能用吗？**
25.12 换成了 apk 包管理器，iStore 商店对它的支持跟进较慢。若只想稳定，用 24.10 + `--istore`，或者 25.12 上关掉 `--istore`。

**编译失败怎么办？**
看 Actions 日志尾部：本仓库的 `build.sh` 会把失败常见原因（磁盘不足、源码包下载失败、root 身份、ccache 拉依赖失败）直接提示出来。多数「下载失败」重跑一次即可。

**能以 root 身份编译吗？**
可以但**不建议**。OpenWrt buildroot 的宿主工具大量使用 autotools，它们会拒绝以 root 执行 `configure`。脚本检测到 root 时会自动 `export FORCE_UNSAFE_CONFIGURE=1` 并给出提示。GitHub 托管 runner 本身就是非 root 用户，不会触发；这条主要照顾本地和自托管 runner。

**为什么默认关掉 ccache？**
`tools/ccache` 自身构建时会用 CMake `FetchContent` 联网拉 xxhash 等依赖，网络受限时会在**编译第一步**就把整条流水线打断，而在一次性 runner 上收益又很有限。需要反复增量构建时，在 `extra_flags` 里填 `--ccache`（本地则直接加 `--ccache`）即可打开，缓存目录由 workflow 自动命中。

**宿主上装了 Docker 会导致构建失败吗？**
会。docker 的构建脚本 `hack/make/binary-daemon` 一旦发现 `/usr/local/bin/runc`，就会把 `containerd`、`ctr`、`rootlesskit` 等一并拷进产物；缺任意一个就会执行 `cp "" 目录/` 而报错。`build.sh` 会自动识别这种情况并临时移走 `runc`，编译结束后自动恢复。

**国内/受限网络怎么办？**
给 `--gh-proxy`（或环境变量 `GH_PROXY`）一个加速前缀即可，例如 `GH_PROXY=https://gh-proxy.com`。它不仅用于 clone 和 feeds，还会配置 git 的 URL 重写，让编译期那些直接 `git ls-remote` GitHub 的包（典型是 docker/dockerd 的版本校验）也一并走代理。
