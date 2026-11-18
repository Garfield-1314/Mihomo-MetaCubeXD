# Mihomo-MetaCubeXD

[![ci](https://github.com/Garfield-1314/Mihomo-MetaCubeXD/actions/workflows/ci.yml/badge.svg)](https://github.com/Garfield-1314/Mihomo-MetaCubeXD/actions/workflows/ci.yml)

在 Debian/Ubuntu 上部署 MetaCubeXD 一体化服务（Dashboard + Control Agent + mihomo 内核），
默认使用本仓库中的本地源码构建镜像，而不是拉取 GHCR 上的 `latest` 镜像。

## 组成

```
.
├── mihomo/                         # mihomo Go 内核源码（子模块，固定到 v1.19.27）
├── metacubexd/                     # MetaCubeXD monorepo（UI / Agent / Server / Desktop）
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
5. 生成 Dashboard Merge Profile 模板。

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

4. 导入订阅、激活 `/opt/metacubexd/merge-profile.yaml`，然后把客户端的网关和
   DNS 指向树莓派 LAN IP。

### WSL（只测试）

```bash
sudo bash install-mihomo-bypass-router.sh
```

- 自动使用 `localhost`，不启用 TUN，不改宿主机路由。
- 打开 `http://localhost:8080`，导入订阅。
- 使用生成的 `/opt/metacubexd/merge-profile.yaml` 配置 CORS。
- 不要在 WSL 里设置客户端网关/DNS；TUN 相关步骤只适用于树莓派。

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

以及同名的外层 `.tar.gz` 和 `.sha256` 文件。

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

### 1. 导入订阅

进入 **Profiles / 配置文件**，点 **从 URL 导入 / Import from URL**，把机场的 **Clash / Mihomo** 订阅地址填进去。导入后点 **激活 / Activate**。

### 2. 选择节点

激活订阅后进入 **Proxies / 代理**，选择代理组和节点，点闪电图标测延迟。节点来自订阅，不需要逐个添加。

### 3. 创建 Merge Profile

安装脚本会生成：

```text
/opt/metacubexd/merge-profile.yaml
```

在 **Profiles → Merge overlays / 合并配置** 中新建，粘贴后启用。基础订阅必须先激活。模板包含：

- `external-controller-cors`：允许 Dashboard 跨端口访问 Clash API
- `allow-lan: false`：避免 7890 被 LAN 设备当成开放代理
- TUN 配置：`stack: mips`、`auto-route`、`auto-redirect`、`dns-hijack`
- `route-exclude-address`：排除 LAN、Docker、WSL 等网段

如果 Dashboard 不是通过模板里的地址访问（例如反向代理域名），需要把该 origin 加进
`external-controller-cors.allow-origins`。

### 3. 旁路由

把测试客户端的网关和 DNS 指向路由器的 LAN IP：

```text
Gateway: <LAN_IP>
DNS:     <LAN_IP>
```

检查转发是否开启：

```bash
sysctl net.ipv4.ip_forward
```

检查 DNS：

```bash
dig @<LAN_IP> example.com
```

如果 DNS 不工作，确认 mihomo 是否监听 53 端口。可以在 Merge Profile 中增加：

```yaml
dns:
  listen: 0.0.0.0:53
```

需要确保宿主机 53 端口没有被 `systemd-resolved` 等程序占用，或者改用 dnsmasq 转发。

## 安全说明

Dashboard 没有登录页。`CONTROL_TOKEN` 会注入页面，任何能打开 8080 的设备都能控制内核。

因此：

- 只允许可信 LAN 访问 8080/9090/7890
- 不要直接暴露到公网
- 远程访问请使用 WireGuard/Tailscale，或带认证的 TLS 反向代理
- Merge Profile 默认 `allow-lan: false`；如果确实要让 LAN 设备使用 7890，请同时配置
  `authentication` 和访问控制

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

这是跨源问题。确认 Merge Profile 中的 `external-controller-cors.allow-origins` 包含 Dashboard
的实际 origin，例如：

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
- Merge Profile 已激活

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
  metacubexd-pi-1.275.2-v1.19.27.tar.gz.sha256
```

发布示例：

```bash
git tag v1.275.2-mihomo-v1.19.27
git push origin v1.275.2-mihomo-v1.19.27
```

如果需要把多架构镜像推送到 GHCR，可以在 release workflow 中增加
`docker/build-push-action` 和 `packages: write` 权限。
