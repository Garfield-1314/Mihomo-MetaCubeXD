# 更新日志

记录 Mihomo-MetaCubeXD 在树莓派旁路由、安装脚本、交付包和发布流程上的变更。

## v1.275.2-mihomo-v1.19.27-r2（2026-11-20）

### 新增

- 宿主机 DNS 自动管理：新增 `metacubexd-host-dns.service` 和 `metacubexd-host-dns.timer`。
  - 容器健康时，把树莓派本机的 DNS 指向 `<LAN_IP>:53`。
  - mihomo 不健康时回退到主路由网关，避免宿主机完全无法解析。
  - timer 每分钟重新确认，网络配置被改回后可以自动恢复。
- 新增 `--no-host-dns`，允许关闭宿主机 DNS 自动管理；设置写入 `/opt/metacubexd/.env` 的 `HOST_DNS`，升级时保留。
- 新增 `--no-cleanup`，部署成功后保留安装包，便于排查。
- 安装脚本在 `--archive` 模式加载镜像前，自动校验包内 `SHA256SUMS`。
  - 校验失败会直接退出，不会执行 `docker load` 或重建容器。
  - 非 bundle 模式或没有 `SHA256SUMS` 时跳过校验。
- 部署成功且宿主机 DNS 验证通过后，自动删除镜像包、外层 bundle、安装脚本，以及旧版遗留的 SHA256 文件。
- 新增本更新日志。

### 修复

- 修复树莓派本机 DNS 仍走主路由，导致 `www.google.com` 被解析到污染 IP 的问题。
  - 修复前：树莓派本机解析到 `157.240.7.20` 等污染地址，`ping` 和直连 `curl` 失败。
  - 修复后：本机解析到 `198.18.x.x` 的 fake-ip，`curl` 经代理返回 `204`。
- 修复 Ubuntu `stonking` 源返回 400 导致 `apt-get update` 阻塞升级的问题。
  - 运行时依赖已存在时跳过 apt。
- 修复升级后旧镜像和安装包残留的问题。
- Release 不再发布外层 `.tar.gz.sha256`，避免额外下载项。

### 变更

- 保留包内 `SHA256SUMS`，用于校验安装脚本、镜像包和 README。
- 不再生成外层 `.sha256` 文件。
- CI 和 Release 只上传/发布 `dist/*.tar.gz`。
- 升级时保留 `/opt/metacubexd/.env` 和 `metacubexd-data` 数据卷。
- 升级前的镜像保存为 `metacubexd-server:pi.previous`，验证通过后可手动删除。

## 后续计划

### 可靠性

- [ ] host DNS 增加 DNS 探测、连续失败阈值和 networkd/NetworkManager dispatcher，减少切换延迟和抖动。
- [ ] 安装时校验 `LAN_IP` 是否属于 `LAN_IFACE`、是否等于默认网关，以及 `LAN_IP:53` 是否被占用。
- [ ] IPv6 旁路收口：明确关闭 IPv6，或补齐 IPv6 TUN、路由和防火墙规则。
- [ ] 检测 `LAN_IP` 变化并提示重新生成配置；文档强调 DHCP 保留或静态 IP。

### 安全

- [ ] 限制 8080/9090/7890 只允许 LAN 访问，避免 Dashboard 和代理端口暴露。
- [ ] 安装日志不再输出 `CLASH_SECRET`，改为提示从 `.env` 读取。
- [ ] 提供可选的 Dashboard 认证，或只允许通过 WireGuard/Tailscale 访问。

### 功能

- [ ] 增加 `sniffer`，从 TLS SNI 恢复域名，处理客户端使用自有 DNS 的情况。
- [ ] 分流规则增加 `GEOSITE,CN,DIRECT`，减少 DNS 解析结果导致的误判。
- [ ] 新增 `scripts/verify-pi.sh`，一键验证宿主机 DNS、TUN、容器、timer 和外部客户端。
- [ ] 增加 `--archive` 校验失败的自动化测试，覆盖缺失 `SHA256SUMS` 和校验不通过两种场景。

### 运维

- [ ] 限制 systemd journal 大小，避免长期写满 SD 卡。
- [ ] 增加温度、欠压和磁盘检查，例如 `vcgencmd get_throttled` 和 `thermal_zone0`。
- [ ] 做一次备份恢复演练，并补充恢复文档。
- [ ] 自动化清理旧镜像，同时保留最近一个可回滚版本。

### 发布与文档

- [ ] 合并当前分支后打新 tag，发布包含宿主机 DNS 修复的版本。
- [ ] 在 README 中说明：没有外层 `.sha256` 时，可用 GitHub 资产摘要或包内 `SHA256SUMS` 校验。
- [ ] 补充 fake-ip `ping` 与真实连通性的区别，以及 `LAN_IP`、网关、DNS 的拓扑说明。
- [ ] 补充 host DNS、`--no-host-dns`、`--no-cleanup` 和回滚流程的排错文档。

## v1.275.2-mihomo-v1.19.27

- MetaCubeXD 1.275.2 + mihomo v1.19.27 树莓派交付包。
- AIO Router：受管基础配置、多订阅 provider、TUN、DNS 和分流规则自动生成。
- 支持 `--archive` 离线加载镜像，以及保留 `.env` 和数据卷的覆盖升级。
