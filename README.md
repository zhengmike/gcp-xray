# GCP Xray (VLESS-Reality) 自动化部署脚本 (极速增强版)

这是一个用于在 Google Cloud Platform (GCP) 上全自动部署 **Xray-core (VLESS + XTLS-Vision + Reality)** 高性能节点的 Shell 脚本。支持在 **GCP Cloud Shell** 或任意已登录 `gcloud` 的本地终端一键执行。

## 🌟 核心特性

- **零干预一键部署 (Zero-Touch Provisioning)**：自动化启用 API、配置防火墙（TCP/UDP 443）、创建实例、安装 Xray-core 并提取 `vless://` 链接，同时支持交互式菜单与命令行非交互参数（`--project`、`--region`、`--sni`）。
- **重启密钥持久化 (Reboot Persistence)**：首次部署时自动将 `UUID`、`PrivateKey`、`PublicKey`、`ShortID` 与伪装域名加密持久化至 `/usr/local/etc/xray/node_info.env`。当机器因谷歌云维护或手动开关机重启时，自动复用原密钥并仅通过 GCP 内部元数据接口毫秒级刷新公网 IP，**彻底解决重启后客户端节点失联问题**。
- **高信誉零告警 Reality 伪装 (Anti-GFW Hardening)**：默认采用支持 **TLS 1.3 + HTTP/2 + 后量子密钥交换 (`X25519MLKEM768`)** 的高信誉域名 `www.amd.com:443`（规避了 Xray 官方点名警告易被 GFW 封禁的 `www.apple.com`），并开启 `"maxTimeDiff": 60000` 防重放探测。
- **跨洋极速网络调优 (Cross-Pacific Speed Optimization)**：
  - **智能阻断出站 `UDP 443 (QUIC)`**：引导浏览器与 YouTube App 在 1ms 内无感回退至标准 `HTTP/2 (TCP 443)`，100% 激活 **XTLS-Vision 内核级零拷贝加速** 与 TCP BBR，彻底消除 UDP-over-TCP 队头阻塞。
  - **32MB 大窗口 BBR + 零空闲慢启动重置**：自动注入 `/etc/sysctl.d/99-xray-bbr.conf`，开启 `fq + bbr`、32MB TCP 读写缓冲、`tcp_fastopen=3`、`tcp_slow_start_after_idle=0`（解决停顿几秒再点网页需要重新爬坡的问题）、`tcp_notsent_lowat=16384`（消除 Bufferbloat）与 `tcp_mtu_probing=1`。
  - **纯 IPv4 内存级 DNS 缓存**：配置 Xray 内置 `UseIPv4` DNS（直连 GCP 内网 `169.254.169.254` + `1.1.1.1`），砍掉无效的 IPv6 `AAAA` 解析等待，缩短新域名首包建连时间（TTFB）。
  - **高并发句柄扩容**：自动配置 systemd `LimitNOFILE=1048576` 与 `somaxconn=32768`。
- **轻量 Debian 12 镜像 + 项目防滥用保护**：默认采用官方 `debian-12` 镜像（无 Ubuntu `snapd` 内存占用与后台 `apt` 锁死问题，30~40 秒极速出链接），并在服务端 `routing` 层自动黑洞拦截 `bittorrent` (BT/PT) 协议与 `geoip:private` 内网探测流量，保护 GCP 账号安全。

---

## 🛠️ 使用说明

### 方式一：交互式一键部署（推荐在 Google Cloud Shell 中使用）

```bash
bash <(curl -sL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/install.sh)
```

根据终端提示输入数字选择区域（默认 `5` 为美国西区 `us-west1-b` 永久免费额度机型）：
- `1` — 🇹🇼 台湾 (`asia-east1-b`)
- `2` — 🇸🇬 新加坡 (`asia-southeast1-b`)
- `3` — 🇭🇰 香港 (`asia-east2-a`)
- `4` — 🇯🇵 日本 (`asia-northeast1-b`)
- `5` — 🇺🇸 美国 (`us-west1-b`，包含在 GCP Always Free 永久免费额度内)

### 方式二：命令行非交互式部署（指定项目 / 区域 / 自定义伪装域名）

```bash
curl -sL https://raw.githubusercontent.com/gitreposcripts/gcp-xray/main/install.sh | bash -s -- \
  --project your-gcp-project-id \
  --region US \
  --sni www.amd.com
```

---

## 📱 客户端配置指南

获取到终端输出的 `vless://...` 链接后，全选复制并导入以下客户端即可使用：

- **iOS / macOS**：**Shadowrocket (小火箭)** / **V2rayTun** / **Clash Verge Rev**
- **Android**：**v2rayNG** / **NekoBox**
- **Windows**：**v2rayN** / **Clash Verge Rev**
