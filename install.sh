#!/bin/bash
# ==============================================================================
# GCP Xray (VLESS-Reality) 全自动一键部署脚本 (增强防封锁 & 重启持久化 & 跨洋极速版)
# ==============================================================================
set -euo pipefail

PROJECT_ID=""
REGION_CHOICE=""
SNI_DOMAIN="${SNI_DOMAIN:-www.amd.com}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project) PROJECT_ID="$2"; shift 2 ;;
        -r|--region)  REGION_CHOICE="$2"; shift 2 ;;
        -s|--sni)     SNI_DOMAIN="$2"; shift 2 ;;
        *) shift ;;
    esac
done

PROJECT_FLAG=()
if [[ -n "$PROJECT_ID" ]]; then
    PROJECT_FLAG=(--project="$PROJECT_ID")
fi

TMP_STARTUP=$(mktemp /tmp/xray-startup.XXXXXX.sh)
trap 'rm -f "$TMP_STARTUP"' EXIT

echo "=================================================="
echo "🚀 欢迎使用 GCP Reality 节点全自动部署向导 (极速增强版)"
echo "=================================================="

if [[ -z "$REGION_CHOICE" ]]; then
    echo "请选择服务器物理位置 (机型: e2-micro, 10G 硬盘):"
    echo "  1) 🟢 [TW] 台湾 (asia-east1-b)   - 约 \$6.5 ~ \$7.0 / 月"
    echo "  2) 🇸🇬 新加坡 (asia-southeast1-b) - 约 \$6.5 ~ \$7.0 / 月"
    echo "  3) 🇭🇰 香港 (asia-east2-a)        - 约 \$7.0 ~ \$8.0 / 月"
    echo "  4) 🇯🇵 日本 (asia-northeast1-b)   - 约 \$6.5 ~ \$7.0 / 月"
    echo "  5) 🇺🇸 美国 (us-west1-b)          - 包含在 GCP 永久免费额度内 (0\$)"
    echo "--------------------------------------------------"
    read -r -p "请输入数字 [默认 5 美国]: " REGION_CHOICE < /dev/tty || REGION_CHOICE="5"
fi

case "${REGION_CHOICE^^}" in
    1|TW) ZONE="asia-east1-b"; PREFIX="TW" ;;
    2|SG) ZONE="asia-southeast1-b"; PREFIX="SG" ;;
    3|HK) ZONE="asia-east2-a"; PREFIX="HK" ;;
    4|JP) ZONE="asia-northeast1-b"; PREFIX="JP" ;;
    5|US|*) ZONE="us-west1-b"; PREFIX="US" ;;
esac

PREFIX_LOWER=$(echo "$PREFIX" | tr 'A-Z' 'a-z')
RAND_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4 || true)
INSTANCE_NAME="${PREFIX_LOWER}-node-${RAND_SUFFIX}"

echo ""
echo "🎯 已选择区域: $ZONE"
echo "🖥️  即将创建的实例名称: $INSTANCE_NAME"
echo "🔒 Reality 伪装域名: $SNI_DOMAIN"
echo "=================================================="

# 1. 确保 Compute Engine API 处于启用状态
echo "⏳ 正在检查并启用 Compute Engine API..."
gcloud services enable compute.googleapis.com "${PROJECT_FLAG[@]}" --quiet

# 2. 创建防火墙规则，放行 443 端口
echo "🛡️  正在配置云端防火墙 (放行 443 端口)..."
gcloud compute firewall-rules create allow-xray-443 \
    "${PROJECT_FLAG[@]}" \
    --direction=INGRESS --network=default --action=ALLOW \
    --rules=tcp:443,udp:443 --source-ranges=0.0.0.0/0 \
    --target-tags=xray-server --quiet 2>/dev/null || true

# 3. 生成要在机器内部执行的启动脚本 (支持幂等重启与内核高并发跨洋调优)
cat << 'INLINESCRIPT' > "$TMP_STARTUP"
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 幂等写入 BBR 与跨洋高带宽时延积 (BDP) + 全局 TCP 内存水位线 + 零慢启动重置调优
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-xray-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.ipv4.tcp_mem=65536 98304 131072
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.netdev_max_backlog=16384
net.core.somaxconn=32768
SYSCTL_EOF
sysctl --system >/dev/null 2>&1 || true

# 系统级 getaddrinfo 优先 IPv4 (避免 Reality 握手与出站连接尝试不可达 IPv6)
if ! grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
fi

# 提升默认路由初始拥塞窗口与接收窗口 (10 MSS -> 32 MSS ≈ 45KB)，消除跨洋首屏多轮 RTT 慢启动等待
DEFAULT_ROUTE=$(ip route show default | head -n 1)
if [[ -n "$DEFAULT_ROUTE" ]]; then
    CLEAN_ROUTE=$(echo "$DEFAULT_ROUTE" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g')
    ip route change $CLEAN_ROUTE initcwnd 32 initrwnd 32 2>/dev/null || true
fi

# 通过 GCP 内部元数据服务器毫秒级获取公网 IP (兜底 api.ipify.org)
IP=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || curl -sf https://api.ipify.org)

INFO_FILE="/usr/local/etc/xray/node_info.env"

# 若已初始化过，则重启时直接复用原密钥与 UUID，防止重启后客户端失联
if [[ -f "$INFO_FILE" && -x /usr/local/bin/xray ]]; then
    source "$INFO_FILE"
    systemctl restart xray || true
    LINK="vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#GCP-MARKER_PREFIX"
    echo "VLESS_LINK_START::::${LINK}::::VLESS_LINK_END"
    exit 0
fi

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 3; done

apt-get update -y && apt-get install -y curl unzip openssl ca-certificates procps iproute2
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

UUID=$(/usr/local/bin/xray uuid)
KEYS=$(/usr/local/bin/xray x25519)
PRI_KEY=$(echo "$KEYS" | awk -F ': ' '/PrivateKey|Private key/{print $2}' | tr -d ' \r\n')
PUB_KEY=$(echo "$KEYS" | awk -F ': ' '/PublicKey|Public key|Password/{print $2}' | tr -d ' \r\n')
SHORT_ID=$(openssl rand -hex 4)
SNI="MARKER_SNI"

mkdir -p /usr/local/etc/xray
cat << EOF_ENV > "$INFO_FILE"
UUID="$UUID"
PRI_KEY="$PRI_KEY"
PUB_KEY="$PUB_KEY"
SHORT_ID="$SHORT_ID"
SNI="$SNI"
EOF_ENV
chmod 600 "$INFO_FILE"

mkdir -p /etc/systemd/system/xray.service.d
cat << 'EOF_LIMITS' > /etc/systemd/system/xray.service.d/10-limits.conf
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
EOF_LIMITS

# 保持纯净直通的 VLESS + XTLS-Vision + Reality 配置：
# 1) 不启用内置 DNS 与 routing geoip:private 拦截，避免 GCP 本机元数据 DNS (169.254.169.254) 被误判为链路本地私网黑洞
# 2) freedom 出站设置 domainStrategy=UseIPv4，直接通过系统 getaddrinfo(AF_INET) 走 169.254.169.254 毫秒级纯 A 记录解析与零拷贝转发
cat << EOF_JSON > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "$PRI_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    }
  ]
}
EOF_JSON

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

LINK="vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#GCP-MARKER_PREFIX"
echo "VLESS_LINK_START::::${LINK}::::VLESS_LINK_END"
INLINESCRIPT

sed -i "s/MARKER_PREFIX/${PREFIX}/g" "$TMP_STARTUP"
sed -i "s/MARKER_SNI/${SNI_DOMAIN}/g" "$TMP_STARTUP"

# 4. 发起创建实例的请求 (使用轻量 Debian 12 镜像，规避 snapd 内存占用与 apt 锁等待)
echo "➡️ 正在向谷歌云申请创建服务器，等待启动 (约需 30~45 秒) ..."
gcloud compute instances create "$INSTANCE_NAME" \
    "${PROJECT_FLAG[@]}" \
    --zone="$ZONE" --machine-type=e2-micro \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=10GB --boot-disk-type=pd-standard \
    --tags=xray-server \
    --metadata-from-file=startup-script="$TMP_STARTUP" --quiet

# 5. 轮询监控日志获取节点链接 (带 180 秒超时保护)
echo -n "➡️ 机器已启动，等待后台自动配置底层防封锁参数 "
LINK=""
MAX_WAIT=36
COUNT=0
while [[ $COUNT -lt $MAX_WAIT ]]; do
    OUTPUT=$(gcloud compute instances get-serial-port-output "$INSTANCE_NAME" "${PROJECT_FLAG[@]}" --zone="$ZONE" --quiet 2>/dev/null | grep "VLESS_LINK_START::::" | tail -n 1 || true)
    if [[ -n "$OUTPUT" ]]; then
        LINK=$(echo "$OUTPUT" | sed 's/.*VLESS_LINK_START:::://' | sed 's/::::VLESS_LINK_END.*//')
        break
    fi
    echo -n "."
    sleep 5
    COUNT=$((COUNT + 1))
done

echo ""
if [[ -z "$LINK" ]]; then
    echo "❌ 超时未能从串口日志获取到链接，请运行以下命令排查日志："
    echo "gcloud compute instances get-serial-port-output $INSTANCE_NAME --zone=$ZONE ${PROJECT_FLAG[*]}"
    exit 1
fi

echo "=================================================="
echo "🎉 部署大功告成！"
echo "=================================================="
echo "📎 请全选复制下方这段长链接，导入到 V2rayNG 或 Shadowrocket 中："
echo ""
echo "$LINK"
echo ""
echo "=================================================="
