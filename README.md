# GCP Xray (VLESS-Reality) 自动化部署脚本 (极速增强版)

这是一个用于在 Google Cloud Platform (GCP) 上全自动部署 **Xray-core (VLESS + XTLS-Vision + Reality)** 高性能节点的 Shell 脚本。支持在 **GCP Cloud Shell** 或任意已登录 `gcloud` 的本地终端一键执行。

## 🌟 核心特性

- **零干预一键部署 (Zero-Touch Provisioning)**：自动化启用 API、配置防火墙（TCP/UDP 443）、创建实例、安装 Xray-core 并提取 `vless://` 链接，同时支持交互式菜单与命令行非交互参数（`--project`、`--region`、`--sni`）。
- **重启密钥持久化 (Reboot Persistence)**：首次部署时自动将 `UUID`、`PrivateKey`、`PublicKey`、`ShortID` 与伪装域名加密持久化至 `/usr/local/etc/xray/node_info.env`。当机器因谷歌云维护或手动开关机重启时，自动复用原密钥并仅通过 GCP 内部元数据接口毫秒级刷新公网 IP，**彻底解决重启后客户端节点失联问题**。
- **高信誉零告警 Reality 伪装 (Anti-GFW Hardening)**：默认采用支持 **TLS 1.3 + HTTP/2 + 后量子密钥交换 (`X25519MLKEM768`)** 的高信誉域名 `www.amd.com:443`（3,291 B 轻量双证书链，规避了 Xray 官方点名警告易被 GFW 封禁的 `www.apple.com`）。
- **经跨太平洋实测验证的内核与协议调优 (Empirically Verified Cross-Pacific Tuning)**：
  - **32MB 大窗口 BBR + `e2-micro` 全局 TCP 内存水位线扩容 (`tcp_mem`)**：开启 `fq + bbr` 与 `32MB` 单连接读写缓冲（匹配 1Gbps 跨洋高带宽时延积 BDP），同时将 `net.ipv4.tcp_mem` 从 `e2-micro` (1GB RAM) 默认的 `41MB/55MB/82MB` 提升至 `256MB/384MB/512MB`（`65536 98304 131072` 页），彻底消除多线程并发下载触发内核 `TCPMemoryPressures` 紧急限速的隐蔽瓶颈（实测单线程跨洋下载速度 **+39.0%**，4 线程并发下载吞吐达 **387.5 Mbps**）。
  - **零空闲慢启动重置 (`tcp_slow_start_after_idle=0`)**：阅读网页或刷流媒体停顿数秒后再次请求时，保持已探测到的 BBR 发送窗口（`cwnd`）不归零（实测空闲 3 秒后恢复传输的首包 TTFB 降低 **33.2%**）。
  - **路由初始拥塞与接收窗口扩容 (`initcwnd 32 initrwnd 32`)**：将默认路由初始窗口从 `10 MSS` (约 14KB) 提升至 `32 MSS` (约 45KB)，使首屏 TLS 证书链与网页 HTML 在首个跨洋 RTT 内即可一次性传完，首屏完整加载时间缩短约 **100~117ms（省去整整 1 个跨太平洋 RTT）**。
  - **系统级纯 IPv4 极速直连 (`UseIPv4` + `gai.conf`)**：通过 `freedom` 出站 `domainStrategy: "UseIPv4"` 配合系统 `/etc/gai.conf` IPv4 优先策略，直接调用 GCP 本机 `169.254.169.254:53` 元数据 DNS 进行毫秒级（`~0.4ms`）纯 `A` 记录解析，砍掉无效的 `AAAA` (IPv6) 查询开销，且绝不配置会误伤 `169.254.0.0/16` 链路本地 DNS 的内置 `geoip:private` 路由黑洞。
  - **高并发句柄扩容**：自动配置 systemd `LimitNOFILE=1048576` 与 `somaxconn=32768`。
- **轻量 Debian 12 镜像**：默认采用官方 `debian-12` 镜像（无 Ubuntu `snapd` 后台内存占用与 `apt` 锁死问题，30~40 秒极速出链接）。

---

## 🤖 方式一：作为 AI Agent Skill 一键安装（支持 Claude Code / Gemini CLI / Jetski）

本仓库内置标准 `SKILL.md` 与自动化脚本，可直接安装为 AI 编程助手（Claude Code、Gemini CLI、Jetski 等）的专属技能。安装后只需对 AI 说 **“帮我在 `<GCP项目ID>` 部署一台美国/台湾/新加坡 Xray 节点”** 或 **“帮我无损升级现有的 Xray 节点”**，AI 即可全自动完成部署、调优并输出客户端链接与路由器分项参数：

```bash
# 安装到 Gemini CLI / Jetski 全局技能目录
git clone https://github.com/gitreposcripts/gcp-xray.git ~/.gemini/config/skills/gcp-xray

# 或安装到 Claude Code 全局技能目录
mkdir -p ~/.claude/skills && git clone https://github.com/gitreposcripts/gcp-xray.git ~/.claude/skills/gcp-xray
```

---

## 🛠️ 方式二：命令行直接一键部署 / 升级

### 1. 交互式一键部署新节点（推荐在 Google Cloud Shell 中使用）

```bash
bash <(curl -sL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/install.sh)
```

根据终端提示输入数字选择区域（默认 `5` 为美国西区 `us-west1-b` 永久免费额度机型）：
- `1` — 🟢 `[TW]` 台湾 (`asia-east1-b`)
- `2` — 🇸🇬 `[SG]` 新加坡 (`asia-southeast1-b`)
- `3` — 🇭🇰 `[HK]` 香港 (`asia-east2-a`)
- `4` — 🇯🇵 `[JP]` 日本 (`asia-northeast1-b`)
- `5` — 🇺🇸 `[US]` 美国 (`us-west1-b`，包含在 GCP Always Free 永久免费额度内)

### 2. 命令行非交互式部署新节点（指定项目 / 区域 / 自定义伪装域名）

```bash
curl -sL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/install.sh | bash -s -- \
  --project your-gcp-project-id \
  --region US \
  --sni www.amd.com
```

### 3. 存量节点无损热升级（保持原客户端链接 / IP / UUID / 密钥 100% 不变）

```bash
curl -sL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/scripts/upgrade_node.sh | bash -s -- \
  --project your-gcp-project-id \
  --zone asia-east1-b \
  --instance your-instance-name
```

---

## 📱 客户端与路由器配置指南

获取到终端输出的 `vless://...` 链接后，全选复制并导入以下客户端或路由器插件即可使用：

- **iOS / macOS**：**Shadowrocket (小火箭)** / **V2rayTun** / **Clash Verge Rev**
- **Android**：**v2rayNG** / **NekoBox**
- **Windows**：**v2rayN** / **Clash Verge Rev**
- **软路由 / OpenWrt**：**PassWall** / **SSR Plus** / **OpenClash** / **ShellCrash**（支持直接导入 `vless://` 链接或按 `SKILL.md` 分项填写 `xtls-rprx-vision` + `reality` 参数）
