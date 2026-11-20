# Mihomo-MetaCubeXD

[![ci](https://github.com/Garfield-1314/Mihomo-MetaCubeXD/actions/workflows/ci.yml/badge.svg)](https://github.com/Garfield-1314/Mihomo-MetaCubeXD/actions/workflows/ci.yml)

在 Debian/Ubuntu 上部署 MetaCubeXD 一体化服务（Dashboard + Control Agent + mihomo 内核），
默认使用本仓库中的本地源码构建镜像，而不是拉取 GHCR 上的 `latest` 镜像。

变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 部署只需要一个订阅

全新部署的验收标准只有一条：

```text
打开 http://<LAN_IP>:8080 → 粘贴一个订阅 URL → 完成
```

AIO 会自动创建受管路由器配置、开启 TUN、写入 DNS/规则/分组、校验并激活，不需要再手工
创建 Merge Profile、打开 TUN 开关或执行 iptables。以后添加第二个订阅，仍然使用同一个
导入框，节点会自动汇总。

## 组成

```
.
├── mihomo/                         # mihomo Go 内核源码（子模块，固定到 v1.19.27）
├── metacubexd/                     # MetaCubeXD monorepo（UI / Agent / Server / Desktop）
├── docker/router-mode.patch        # 旁路由/多订阅补丁，构建时自动应用到 metacubexd
├── docker/Dockerfile.local         # 本地源码构建的一体化镜像
├── scripts/build-local-image.sh    # 构建脚本
├── scripts/package-pi-image.sh     # 树莓派 arm64 交付包
└── install-mihomo-bypass-router.sh # 一键安装脚本
```

构建产物：

```
mihomo v1.19.27 ──go build──┐
                            ├──> metacubexd-server:local
metacubexd v1.275.2 ─pnpm──┘
```

镜像内包含：

- Nuxt Dashboard
- Nitro Control API（`/api/control`）
- 由本地源码编译的 mihomo 内核

## 部署形态

| 环境 | 用途 | 架构 |
| --- | --- | --- |
| Raspberry Pi 4/5 | 正式旁路由 | arm64 |
| Debian/Ubuntu 服务器 | 正式旁路由 | amd64 / arm64 |
| WSL | UI、订阅、CORS 测试 | amd64 |

## 前置条件

- Debian/Ubuntu（含 WSL）
- root 权限
- x86_64 或 arm64
- **树莓派必须是 64 位系统**（`uname -m` 输出 `aarch64`）；32 位 Raspberry Pi OS 不支持
- 首次构建需要联网：拉取 Node/Go 基础镜像、pnpm 依赖和 Go modules
- 建议至少 3 GB 可用磁盘、2 GB 内存；在树莓派上编译建议 4 GB 内存以上

如果目标路由器性能较弱，建议先在 WSL 或另一台机器构建，再导出镜像：

```bash
# 在 WSL/PC 上交叉构建 arm64
docker run --privileged --rm tonistiigi/binfmt --install arm64
bash scripts/build-local-image.sh \
  --platform linux/arm64 \
  --tag metacubexd-server:pi \
  --save metacubexd-server-pi.tar.gz

# 复制到树莓派后：
gunzip -c metacubexd-server-pi.tar.gz | docker load
sudo bash install-mihomo-bypass-router.sh \
  --no-build --tag metacubexd-server:pi \
  --lan-ip 192.168.5.100 --lan-cidr 192.168.5.0/24
```

也可以直接用交付包脚本，把镜像、安装脚本、README 和校验和一起打出来：

```bash
bash scripts/package-pi-image.sh
# 产物在 dist/metacubexd-pi-<metacubexd>-<mihomo>/
```

树莓派上可以直接用 `--archive`，脚本会自动 `docker load`：

```bash
sudo bash install-mihomo-bypass-router.sh \
  --archive metacubexd-server-pi.tar.gz \
  --tag metacubexd-server:pi \
  --lan-ip 192.168.5.100 --lan-cidr 192.168.5.0/24
```

`--no-build` / `--archive` 模式只要求目标机已有对应镜像，不需要本地源码树。

### 国内网络

Docker Hub 不可达时，可以用镜像站和国内代理构建：

```bash
BASE_REGISTRY=docker.m.daocloud.io \
GOPROXY=https://goproxy.cn,direct \
NPM_REGISTRY=https://registry.npmmirror.com \
BINFMT_IMAGE=docker.m.daocloud.io/tonistiigi/binfmt:latest \
bash scripts/package-pi-image.sh
```

参数说明：

| 变量 | 作用 |
| --- | --- |
| `BASE_REGISTRY` | `golang` / `node` 基础镜像的 registry |
| `GOPROXY` | Go module 代理 |
| `NPM_REGISTRY` | pnpm / npm 包源 |
| `BINFMT_IMAGE` | arm64 交叉构建的 binfmt 镜像 |
| `NUXT_FONTS_DISABLE_REMOTE` | 默认 `true`，跳过 Google Fonts 元数据请求；网络可用时可设为 `false` |

`build-local-image.sh` 也支持这些环境变量。在树莓派上直接构建时：

```bash
sudo env \
  BASE_REGISTRY=docker.m.daocloud.io \
  GOPROXY=https://goproxy.cn,direct \
  NPM_REGISTRY=https://registry.npmmirror.com \
  bash install-mihomo-bypass-router.sh
```

## 快速开始

```bash
git clone https://github.com/Garfield-1314/Mihomo-MetaCubeXD.git
cd Mihomo-MetaCubeXD

# 初始化子模块；mihomo 必须位于 v1.19.27（真实 Go 内核源码）
git submodule update --init --recursive
git -C mihomo checkout v1.19.27

sudo bash install-mihomo-bypass-router.sh
```

脚本会自动：

1. 安装 Docker、IPRoute2 等依赖（Compose v2 可选）。
2. 从 `mihomo/` 和 `metacubexd/` 构建 `metacubexd-server:local`。
3. 启动容器。优先用 Compose；没有 Compose v2 时自动回退到 `docker run`。
4. 等待 `/api/control/health` 通过。
5. 启用旁路由转发、健康检查、日志轮转和每日备份。

默认地址：

| 用途 | 地址 |
| --- | --- |
| Dashboard | `http://<LAN_IP>:8080` |
| Clash API | `http://<LAN_IP>:9090` |
| Mixed Proxy | `<LAN_IP>:7890` |

`CLASH_SECRET` 和 `CONTROL_TOKEN` 会在安装结束时生成，并保存在：

```text
/opt/metacubexd/.env
```

WSL 模式只做 UI/订阅测试，不启用 TUN，地址为 `http://localhost:8080`。

## 树莓派与 WSL

### 树莓派（正式旁路由）

1. 确认是 64 位系统：

   ```bash
   uname -m
   # 必须是 aarch64；armv7l 是 32 位，不支持
   ```

2. 在树莓派上直接构建：

   ```bash
   sudo bash install-mihomo-bypass-router.sh
   ```

   4 GB 内存以下建议先加 swap，或在 WSL/PC 上交叉构建后导入。

3. 如果树莓派有多个网口/Wi-Fi，脚本会优先选择有线接口。安装时注意看输出：

   ```text
   LAN: 192.168.5.100 (192.168.5.100/24)
   ```

   如果选错（例如 Wi-Fi 是上行、Ethernet 是 LAN，或反过来），重新执行：

   ```bash
   sudo bash install-mihomo-bypass-router.sh \
     --lan-ip 192.168.5.100 --lan-cidr 192.168.5.0/24
   ```

4. 打开 Dashboard，只粘贴一个订阅 URL。AIO 会自动创建受管路由器配置、开启 TUN、
   写入 DNS/规则/分组并激活，不需要再建 Merge Profile。
5. 把客户端的网关和 DNS 指向树莓派 LAN IP，或由主路由 DHCP 统一下发。

### WSL（只测试）

```bash
sudo bash install-mihomo-bypass-router.sh
```

- 自动使用 `localhost`，不启用 TUN，不改宿主机路由。
- 打开 `http://localhost:8080`，导入订阅。
- 使用生成的 `/opt/metacubexd/merge-profile.yaml` 配置 CORS。
- 不要在 WSL 里设置客户端网关/DNS；TUN 相关步骤只适用于树莓派。

### 本地开发/测试

`metacubexd` 仍是上游子模块，旁路由改动保存在 `docker/router-mode.patch`。Docker 构建会自动
应用；直接跑 TypeScript 测试前先执行：

```bash
bash scripts/apply-aio-patches.sh
```

该脚本只修改子模块工作区，不要提交子模块指针。

## 常用参数

```bash
# 使用本地源码构建（默认）
sudo bash install-mihomo-bypass-router.sh

# 强制无缓存重建
sudo bash install-mihomo-bypass-router.sh --rebuild

# 指定本地镜像 tag
sudo bash install-mihomo-bypass-router.sh --tag metacubexd-server:test

# 指定 mihomo 版本
sudo bash install-mihomo-bypass-router.sh --mihomo-tag v1.19.27

# 已构建好镜像，只启动
sudo bash install-mihomo-bypass-router.sh --no-build

# 加载预构建镜像包（树莓派常用）
sudo bash install-mihomo-bypass-router.sh \
  --archive metacubexd-server-pi.tar.gz \
  --tag metacubexd-server:pi \
  --lan-ip 192.168.5.100 --lan-cidr 192.168.5.0/24

# 使用外部镜像（GHCR 回退）
sudo bash install-mihomo-bypass-router.sh \
  --image ghcr.io/metacubex/metacubexd-server:latest

# 手动指定 LAN
sudo bash install-mihomo-bypass-router.sh \
  --lan-ip 192.168.5.100 --lan-cidr 192.168.5.0/24

# 写入静态 IP（重启生效，同时禁用 Wi-Fi）
sudo bash install-mihomo-bypass-router.sh \
  --archive metacubexd-server-pi.tar.gz \
  --tag metacubexd-server:pi \
  --lan-ip 192.168.5.100 --lan-cidr 192.168.5.0/24 \
  --set-ip --interface eth0 --gateway 192.168.5.1 --dns 192.168.5.1 \
  --disable-wifi

# 交叉构建（需要 buildx/QEMU）
sudo bash install-mihomo-bypass-router.sh --platform linux/arm64
```

查看全部参数：

```bash
sudo bash install-mihomo-bypass-router.sh --help
```

## 单独构建镜像

```bash
bash scripts/build-local-image.sh
bash scripts/build-local-image.sh --tag metacubexd-server:test --no-cache
bash scripts/build-local-image.sh --platform linux/arm64 \
  --tag metacubexd-server:pi --save metacubexd-server-pi.tar.gz

# 树莓派交付包
bash scripts/package-pi-image.sh
bash scripts/package-pi-image.sh --skip-build
```

`package-pi-image.sh` 会生成：

```text
dist/metacubexd-pi-<metacubexd>-<mihomo>/
├── install-mihomo-bypass-router.sh
├── metacubexd-server-pi.tar.gz
├── README-pi.md
└── SHA256SUMS
```

以及同名的外层 `.tar.gz` 文件。

脚本会校验：

- `mihomo/go.mod` 的 module 路径是 `github.com/metacubex/mihomo`
- `metacubexd/pnpm-lock.yaml` 存在
- 构建完成后运行 `mihomo -v`

## 安装后配置

### 0. 首次登录

新镜像会在 `/config.js` 中自动注入：

- `defaultBackendURL = http://<LAN_IP>:9090`
- `defaultBackendSecret = CLASH_SECRET`
- `controlToken = CONTROL_TOKEN`

因此正常情况下打开：

```text
http://<LAN_IP>:8080
```

会自动连接后端，不需要手动填写。左侧应能看到 **Profiles / 配置文件**。

如果仍然停在连接页，填写：

```text
后端地址：http://<LAN_IP>:9090
密钥：sudo sed -n 's/^CLASH_SECRET=//p' /opt/metacubexd/.env
```

如果访问过旧版本，先清除浏览器站点数据或 Unregister Service Worker，再强制刷新。

### 1. 只导入一个订阅

进入 **配置文件 / Profiles**，在 **从 URL 导入** 里粘贴一个 Clash / Mihomo 订阅地址并导入。

就这样。路由器模式会自动完成：

- 创建受管的 **AIO Router** 基础配置
- 为每个订阅生成一个 mihomo `proxy-provider`
- 开启 TUN（`gvisor`、`Meta`、`auto-route`、`auto-redirect`）
- 监听 `<LAN_IP>:53` 并劫持 DNS（避开 systemd-resolved 的 `127.0.0.53:53`）
- 写入局域网直连、`GEOIP,CN,DIRECT` 和默认代理规则
- 生成 `🚀 节点选择`、`♻️ 自动选择` 和每个订阅的 `📦` 分组
- 校验配置并重启内核
- 放行 `eth0 <-> Meta` 转发

不需要再创建 Merge Profile，也不需要手动打开 TUN。

### 2. 添加更多订阅

以后要加机场，继续用同一个导入框即可。每个订阅自动变成新的 provider：

- 节点名带订阅前缀，避免重名
- 不需要修改分组或规则
- 某个订阅更新失败时，mihomo 保留上一次可用节点，其他订阅不受影响
- 订阅节点由内核每 24 小时自动更新，不重启内核

不同订阅的节点会汇总到同一套路由器分组里。机场自带的 `proxy-groups` / `rules`
不会带过来，这是聚合模式的取舍。

### 3. 客户端接入

把客户端的网关和 DNS 指向路由器的 LAN IP：

```text
Gateway: <LAN_IP>
DNS:     <LAN_IP>
```

或者在主路由 DHCP 里统一下发这两个值。树莓派默认不接管 DHCP，避免和主路由冲突。

检查转发和 DNS：

```bash
sysctl net.ipv4.ip_forward
dig @<LAN_IP> example.com
```

检查 TUN 和策略路由：

```bash
ip addr show Meta
ip rule show
ip route show table 2022
```

正常情况下会看到 `Meta` 接口、`9000/9001/9002` 规则和 `table 2022` 的默认路由。

### 4. 宿主机 DNS

非 WSL 的路由器模式会额外安装：

```text
metacubexd-host-dns.service
metacubexd-host-dns.timer
```

容器健康时，timer 会把树莓派**本机**的上游 DNS 指向 `<LAN_IP>:53`，并每分钟重新确认一次；mihomo 不健康时回退到主路由网关，避免宿主机完全无法解析。这样树莓派本机执行 `ping`、`curl`、`apt` 时也会使用 mihomo 的 fake-ip，而不是主路由返回的污染结果。

检查：

```bash
systemctl status metacubexd-host-dns.timer
resolvectl status | sed -n '1,60p'
resolvectl query www.google.com
# 应返回 198.18.x.x
```

`--no-host-dns` 可以关闭自动管理；设置会写入 `/opt/metacubexd/.env` 的 `HOST_DNS`，升级时保留。

注意：`--set-ip --dns` 仍然决定开机时 netplan/NetworkManager 里的静态 DNS，建议保留主路由作为兜底；host DNS timer 会在 mihomo 健康后覆盖运行时 DNS。若希望静态配置也直接指向 mihomo，可显式传 `--dns <LAN_IP>`。

`--archive` 且从交付包目录运行时，安装成功并通过 host DNS 验证后会自动删除镜像包、外层 bundle 和安装脚本；加 `--no-cleanup` 可以保留现场。

### 5. 无人值守

安装脚本会启用：

```text
metacubexd-forward.timer     每分钟补一次 TUN 转发规则
metacubexd-health.timer      每分钟检查控制面和内核状态
metacubexd-backup.timer      每天 03:30 备份 .env 和数据卷
metacubexd-host-dns.timer    每分钟确认宿主机 DNS 指向 mihomo
```

Docker 日志限制为 `10 MB × 3`，不会长期写满 SD 卡。镜像升级仍然手动触发，
不会自动升级。

查看状态：

```bash
systemctl list-timers 'metacubexd-*'
sudo journalctl -t metacubexd-health -n 50
sudo ls -lh /opt/metacubexd/backups
```

## 安全说明

Dashboard 没有登录页。`CONTROL_TOKEN` 会注入页面，任何能打开 8080 的设备都能控制内核。

因此：

- 只允许可信 LAN 访问 8080/9090/7890
- 不要直接暴露到公网
- 远程访问请使用 WireGuard/Tailscale，或带认证的 TLS 反向代理
- 路由器模式默认 `allow-lan: false`；如果确实要让 LAN 设备使用 7890，请在
  `AIO Router` 模板中同时配置 `authentication` 和访问控制

## 更新

更新 Dashboard：

```bash
git -C metacubexd fetch --tags
git -C metacubexd checkout v1.275.2
```

更新 mihomo 内核：

```bash
git -C mihomo fetch --tags
git -C mihomo checkout v1.19.27   # 改成目标版本
```

重新构建并启动：

```bash
sudo bash install-mihomo-bypass-router.sh --rebuild
```

### 覆盖升级镜像

保留已有 `.env` 和 `metacubexd-data` 卷，直接加载新镜像并重建容器：

```bash
sudo bash install-mihomo-bypass-router.sh \
  --archive metacubexd-server-pi.tar.gz \
  --tag metacubexd-server:pi \
  --lan-ip 192.168.5.100 \
  --lan-cidr 192.168.5.0/24
```

- 旧镜像会保存为 `metacubexd-server:pi.previous`
- 不会删除 `/data` 卷
- 不要在升级时执行 `docker compose down -v` 或 `docker volume rm`

回滚：

```bash
sudo docker rm -f metacubexd
sudo docker tag metacubexd-server:pi.previous metacubexd-server:pi
cd /opt/metacubexd
sudo docker compose up -d --force-recreate
```

## 排错

### UI 提示 Unable to connect to backend

这是跨源问题。路由器模式的受管配置会自动写入 Dashboard origin；如果通过反向代理域名
访问，需要把该 origin 加进受管配置模板（或增加一个全局合并覆盖）：

```yaml
external-controller-cors:
  allow-private-network: true
  allow-origins:
    - 'http://192.168.5.100:8080'
```

### 容器启动失败

有 Compose 时：

```bash
cd /opt/metacubexd
docker compose logs --tail=200
```

没有 Compose（脚本会自动回退到 `docker run`）时：

```bash
docker logs --tail=200 metacubexd
```

### 健康检查

```bash
curl -fsS http://127.0.0.1:8080/api/control/health
```

### 激活后代理列表为空

先检查内核是否真的加载了订阅：

```bash
sudo docker exec metacubexd /usr/local/bin/mihomo -t -f /data/active.yaml
```

如果日志出现 `can't download MMDB` 或 `can't download GeoIP.dat`，说明 GeoIP/GeoSite
数据下载失败。新 AIO 镜像会注入：

```yaml
geodata-mode: true
geox-url:
  geoip: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat
  geosite: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat
```

如果仍然为空，在控制中心点“重启内核”，然后刷新代理页面。

### TUN 不工作

确认：

- 宿主机存在 `/dev/net/tun`
- 容器有 `NET_ADMIN`
- 内核支持 nftables
- `net.ipv4.ip_forward=1`
- 防火墙没有阻断 TUN 接口
- 配置文件页显示 `AIO Router` 为当前激活，而不是某个机场订阅
- `systemctl status metacubexd-forward.timer` 正常

## CI

GitHub Actions 工作流：

| 工作流 | 触发 | 内容 |
| --- | --- | --- |
| `ci.yml` | push / PR / 手动 | preflight、ShellCheck、Actionlint、amd64 构建、arm64 Pi 交付包、镜像 smoke test |
| `release.yml` | `v*` tag / 手动 | 构建 Pi 交付包并附加到 GitHub Release |

CI 产物：

```text
metacubexd-pi-<github-sha>-<run_attempt>/
  metacubexd-pi-1.275.2-v1.19.27.tar.gz
```

发布示例：

```bash
git tag v1.275.2-mihomo-v1.19.27
git push origin v1.275.2-mihomo-v1.19.27
```

如果需要把多架构镜像推送到 GHCR，可以在 release workflow 中增加
`docker/build-push-action` 和 `packages: write` 权限。
