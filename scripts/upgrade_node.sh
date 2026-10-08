#!/bin/bash
# ==============================================================================
# GCP Xray (VLESS-Reality) 存量节点无损热升级脚本 (保持客户端链接/密钥/IP 100% 不变)
# ==============================================================================
set -euo pipefail

PROJECT_ID=""
ZONE=""
INSTANCE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project)  PROJECT_ID="$2"; shift 2 ;;
        -z|--zone)     ZONE="$2"; shift 2 ;;
        -i|--instance) INSTANCE_NAME="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$INSTANCE_NAME" || -z "$ZONE" ]]; then
    echo "用法: bash upgrade_node.sh --instance <实例名> --zone <可用区> [--project <GCP项目ID>]"
    exit 1
fi

PROJECT_FLAG=()
if [[ -n "$PROJECT_ID" ]]; then
    PROJECT_FLAG=(--project="$PROJECT_ID")
fi

echo "=================================================="
echo "🔧 正在无损热升级存量节点: $INSTANCE_NAME ($ZONE)"
echo "=================================================="

REMOTE_SCRIPT=$(cat << 'EOF_REMOTE'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CONFIG_FILE="/usr/local/etc/xray/config.json"
INFO_FILE="/usr/local/etc/xray/node_info.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ 未找到 $CONFIG_FILE，该实例尚未安装 Xray。"
    exit 1
fi

# 1. 升级 Xray-core 至最新正式版（不覆盖现有配置参数）
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || true

# 2. 提取并持久化现有密钥与 UUID（确保客户端链接 100% 不变）
if [[ -f "$INFO_FILE" ]]; then
    source "$INFO_FILE"
else
    UUID=$(python3 -c 'import json; c=json.load(open("/usr/local/etc/xray/config.json")); print(c["inbounds"][0]["settings"]["clients"][0]["id"])')
    PRI_KEY=$(python3 -c 'import json; c=json.load(open("/usr/local/etc/xray/config.json")); print(c["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"])')
    SHORT_ID=$(python3 -c 'import json; c=json.load(open("/usr/local/etc/xray/config.json")); print(c["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"][0])')
    SNI=$(python3 -c 'import json; c=json.load(open("/usr/local/etc/xray/config.json")); print(c["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"][0])')
    KEYS=$(/usr/local/bin/xray x25519 -i "$PRI_KEY")
    PUB_KEY=$(echo "$KEYS" | awk -F ': ' '/PublicKey|Public key|Password/{print $2}' | tr -d ' \r\n')
    cat << EOF_ENV > "$INFO_FILE"
UUID="$UUID"
PRI_KEY="$PRI_KEY"
PUB_KEY="$PUB_KEY"
SHORT_ID="$SHORT_ID"
SNI="$SNI"
EOF_ENV
    chmod 600 "$INFO_FILE"
fi

# 3. 写入经跨太平洋实测验证的 Config 3 内核参数 (含 e2-micro 全局 tcp_mem 扩容)
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

# 4. 系统级 getaddrinfo 优先 IPv4
if ! grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
fi

# 5. 默认路由初始窗口提升至 32 MSS 并注册开机持久化服务
cat << 'EOF_ROUTE_SVC' > /etc/systemd/system/xray-route-tune.service
[Unit]
Description=Tune default route initcwnd/initrwnd to 32 for Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'R=$(ip route show default | head -n 1); if [ -n "$R" ]; then C=$(echo "$R" | sed -E "s/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g"); ip route change $C initcwnd 32 initrwnd 32; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_ROUTE_SVC

mkdir -p /etc/systemd/system/xray.service.d
cat << 'EOF_LIMITS' > /etc/systemd/system/xray.service.d/10-limits.conf
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
EOF_LIMITS

# 6. 更新 config.json 为纯净直通 + UseIPv4 (保留原密钥与 SNI)
cat << EOF_JSON > "$CONFIG_FILE"
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
systemctl enable xray-route-tune.service >/dev/null 2>&1 || true
systemctl start xray-route-tune.service || true
systemctl restart xray

IP=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || curl -sf https://api.ipify.org)
echo "✅ 节点升级完成: $IP:443 (SNI=$SNI, Xray=$(/usr/local/bin/xray version | head -n 1 | awk '{print $2}'))"
echo "vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#GCP-Node"
EOF_REMOTE
)

gcloud compute ssh "$INSTANCE_NAME" "${PROJECT_FLAG[@]}" --zone="$ZONE" --quiet \
    --command="sudo bash -c $(printf '%q' "$REMOTE_SCRIPT")" -- -o ProxyCommand=none -o StrictHostKeyChecking=no
