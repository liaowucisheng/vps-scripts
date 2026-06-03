#!/bin/bash
set -e
set -o pipefail

# ============================================================
# Sing-box + REALITY 一键安装脚本 (香港优化版)
# 适用系统: Ubuntu 20.04+ / Debian 10+
# 协议: VLESS + REALITY + Vision Flow
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()      { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()      { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()       { echo -e "${RED}[ERR]${NC} $1"; }
highlight() { echo -e "${BLUE}$1${NC}"; }

# ---------- 交互输入 ----------
echo "============================================"
echo " Sing-box + REALITY 安装脚本 (香港优化版)"
echo "============================================"
echo ""

read -p "请输入端口号 (默认 443): " PORT
PORT=${PORT:-443}

read -p "请输入回落目标域名 (默认 www.microsoft.com): " DEST_DOMAIN
DEST_DOMAIN=${DEST_DOMAIN:-www.microsoft.com}

read -p "是否开启 BBR? (y/n, 默认 y): " ENABLE_BBR
ENABLE_BBR=${ENABLE_BBR:-y}

SING_BOX_VERSION="1.11.6"

# ---------- 1. 系统准备 ----------
info "更新系统..."
apt update -y && apt upgrade -y
apt install curl wget unzip openssl ntp -y
timedatectl set-timezone Asia/Hong_Kong
systemctl enable ntp --now 2>/dev/null || true

# ---------- 2. 开启 BBR ----------
if [[ "$ENABLE_BBR" == "y" ]]; then
    info "开启 BBR 拥塞控制..."
    modprobe tcp_bbr 2>/dev/null || true
    grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null || echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p >/dev/null 2>&1
    if lsmod | grep -q bbr; then
        info "BBR 已开启 ✅"
    else
        warn "BBR 未在当前内核生效（重启后生效）"
    fi
fi

# ---------- 3. 安装 Sing-box ----------
info "下载 Sing-box ${SING_BOX_VERSION}..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)       err "不支持的架构: $ARCH"; exit 1 ;;
esac

DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"

wget -q -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL" || {
    err "下载失败，尝试获取最新版本..."
    LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz"
    SING_BOX_VERSION=$LATEST
    wget -q -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL"
}

tar xzf /tmp/sing-box.tar.gz -C /tmp/
cp "/tmp/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sing-box*

info "Sing-box 版本: $(sing-box version | head -1)"

# ---------- 4. 生成密钥 ----------
info "生成加密密钥..."

KEY_OUTPUT=$(sing-box generate reality-keypair 2>/dev/null || /usr/local/bin/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "PublicKey" | awk '{print $2}')

if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -oP 'PrivateKey:\s*\K.+')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -oP 'PublicKey:\s*\K.+')
fi

UUID=$(sing-box generate uuid 2>/dev/null || /usr/local/bin/sing-box generate uuid)
SHORT_ID1=$(openssl rand -hex 4)
SHORT_ID2=$(openssl rand -hex 4)
SHORT_ID3=$(openssl rand -hex 4)

echo ""
info "=========== 以下信息请保存 ==========="
info "UUID:         $UUID"
info "Private Key:  $PRIVATE_KEY"
info "Public Key:   $PUBLIC_KEY"
info "Short IDs:    $SHORT_ID1, $SHORT_ID2, $SHORT_ID3"
echo "======================================="
echo ""

# ---------- 5. 写入配置 ----------
info "写入配置文件 /etc/sing-box/config.json ..."
mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "address": "tls://8.8.8.8",
        "strategy": "ipv4_only"
      },
      {
        "tag": "local",
        "address": "local",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "local"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${PORT},
      "tcp_fast_open": true,
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "ipv4_only",
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": [
          "${DEST_DOMAIN}",
          "${DEST_DOMAIN#www.}"
        ],
        "reality": {
          "enabled": true,
          "dest": "${DEST_DOMAIN}:443",
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID1}",
            "${SHORT_ID2}",
            "${SHORT_ID3}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ]
  }
}
EOF

# ---------- 6. 创建 systemd 服务 ----------
info "配置 systemd 服务..."

cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=Sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ---------- 7. 启动服务 ----------
info "启动 Sing-box 服务..."
systemctl enable sing-box
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    info "Sing-box 服务运行中 ✅"
else
    err "Sing-box 启动失败！查看日志: journalctl -u sing-box --no-pager -l -n 50"
    exit 1
fi

# ---------- 8. 防火墙 ----------
info "配置防火墙..."
if command -v ufw &>/dev/null; then
    ufw allow ${PORT}/tcp
    ufw allow 22/tcp
    ufw --force enable 2>/dev/null || true
fi

# ---------- 9. 输出客户端信息 ----------
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ip.sb 2>/dev/null || curl -s icanhazip.com 2>/dev/null)

if [[ "$PORT" == "443" ]]; then
    PORT_STR=""
else
    PORT_STR=":${PORT}"
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}${PORT_STR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID1}&type=tcp&headerType=none#香港-SingBox"

echo ""
echo "============================================================"
info "✅ Sing-box + REALITY 安装完成！"
echo "============================================================"
echo ""
highlight "📋 服务器参数"
echo "  协议:       VLESS + REALITY + Vision"
echo "  地址:       $SERVER_IP"
echo "  端口:       $PORT"
echo "  UUID:       $UUID"
echo "  Flow:       xtls-rprx-vision"
echo "  SNI:        $DEST_DOMAIN"
echo "  PublicKey:  $PUBLIC_KEY"
echo "  ShortId:    $SHORT_ID1（也可用 $SHORT_ID2 / $SHORT_ID3）"
echo "  Client-FP:  chrome"
echo ""
highlight "🔗 v2rayN / 通用 VLESS 分享链接（从剪贴板导入）"
echo "${VLESS_LINK}"
echo ""
highlight "📝 Clash Meta 配置"
echo "------------------------------------------------------------"
echo "proxies:"
echo "  - name: \"香港-SingBox\""
echo "    type: vless"
echo "    server: $SERVER_IP"
echo "    port: $PORT"
echo "    uuid: $UUID"
echo "    network: tcp"
echo "    tls: true"
echo "    flow: xtls-rprx-vision"
echo "    servername: $DEST_DOMAIN"
echo "    client-fingerprint: chrome"
echo "    reality-opts:"
echo "      public-key: $PUBLIC_KEY"
echo "      short-id: $SHORT_ID1"
echo "    udp: true"
echo "------------------------------------------------------------"
echo ""
highlight "📤 分享给朋友（复制以下完整配置块）"
echo "============================================================"
echo "服务器信息："
echo "  地址：$SERVER_IP"
echo "  端口：$PORT"
echo "  UUID：$UUID"
echo "  Flow：xtls-rprx-vision"
echo "  PublicKey：$PUBLIC_KEY"
echo "  ShortId (3个可选)：$SHORT_ID1 / $SHORT_ID2 / $SHORT_ID3"
echo "  SNI：$DEST_DOMAIN"
echo ""
echo "v2rayN 导入链接："
echo "${VLESS_LINK}"
echo ""
echo "Clash Meta 配置："
echo "  - name: 香港"
echo "    type: vless"
echo "    server: $SERVER_IP"
echo "    port: $PORT"
echo "    uuid: $UUID"
echo "    network: tcp"
echo "    tls: true"
echo "    flow: xtls-rprx-vision"
echo "    servername: $DEST_DOMAIN"
echo "    client-fingerprint: chrome"
echo "    reality-opts:"
echo "      public-key: $PUBLIC_KEY"
echo "      short-id: $SHORT_ID1"
echo "    udp: true"
echo "============================================================"
echo ""
warn "📌 保存好上面的 PublicKey、UUID、ShortId"
warn "📌 云服务器安全组放行 TCP ${PORT} 端口"
echo ""
highlight "🚀 速度参考（香港 → 深圳联通）"
echo "  预计延迟: 10-30ms"
echo "  Sing-box 已开启: TCP Fast Open + Sniffing + DNS over TLS"
echo "  客户端建议开 MUX 多路复用"
echo ""
highlight "🛠 常用管理命令"
echo "  查看状态:  systemctl status sing-box"
echo "  查看日志:  journalctl -u sing-box --no-pager -l -n 30"
echo "  重启:      systemctl restart sing-box"
echo "============================================================"

# ---------- 10. 验证 ----------
echo ""
info "端口监听验证:"
ss -tlnp | grep ${PORT} | head -3
echo ""
info "Sing-box 运行状态:"
systemctl status sing-box --no-pager -l | head -5
echo ""
info "🎉 安装完成！以上信息建议截图保存。"
