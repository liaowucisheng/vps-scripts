#!/bin/bash
set -e

# ============================================================
# Xray + REALITY 一键安装脚本 (香港优化版)
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
echo " Xray + REALITY 安装脚本 (香港优化版)"
echo "============================================"
echo ""

read -p "请输入端口号 (默认 443): " PORT
PORT=${PORT:-443}

read -p "请输入回落目标域名 (默认 www.microsoft.com): " DEST_DOMAIN
DEST_DOMAIN=${DEST_DOMAIN:-www.microsoft.com}

read -p "是否开启 BBR? (y/n, 默认 y): " ENABLE_BBR
ENABLE_BBR=${ENABLE_BBR:-y}

# ---------- 1. 系统准备 ----------
info "更新系统..."
apt update -y && apt upgrade -y
apt install curl wget unzip openssl -y
timedatectl set-timezone Asia/Hong_Kong
apt install ntp -y
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

# ---------- 3. 安装 Xray ----------
info "安装 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# ---------- 4. 生成密钥 ----------
info "生成加密密钥..."

UUID=$(/usr/local/bin/xray uuid)
KEY_PAIR=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public key:" | awk '{print $3}')
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
info "写入配置文件 /usr/local/etc/xray/config.json ..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
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
          "dest": "${DEST_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${DEST_DOMAIN}",
            "${DEST_DOMAIN#www.}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID1}",
            "${SHORT_ID2}",
            "${SHORT_ID3}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 30
        }
      }
    }
  ]
}
EOF

# ---------- 6. 启动服务 ----------
info "启动 Xray 服务..."
systemctl enable xray
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    info "Xray 服务运行中 ✅"
else
    err "Xray 启动失败！查看日志: journalctl -u xray --no-pager -l -n 30"
    exit 1
fi

# ---------- 7. 防火墙 ----------
info "配置防火墙..."
if command -v ufw &>/dev/null; then
    ufw allow ${PORT}/tcp
    ufw allow 22/tcp
    ufw --force enable 2>/dev/null || true
fi

# ---------- 8. 输出客户端信息 ----------
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ip.sb 2>/dev/null || curl -s icanhazip.com 2>/dev/null)

if [[ "$PORT" == "443" ]]; then
    PORT_STR=""
else
    PORT_STR=":${PORT}"
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}${PORT_STR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID1}&type=tcp&headerType=none#香港-Xray"

echo ""
echo "============================================================"
info "✅ Xray + REALITY 安装完成！"
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
echo "  - name: \"香港-Xray\""
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
echo "  建议客户端开 MUX（v2rayN 设置 → MUX 多路复用 → 并发 8）"
echo ""
highlight "🛠 常用管理命令"
echo "  查看状态:  systemctl status xray"
echo "  查看日志:  journalctl -u xray --no-pager -l -n 30"
echo "  重启:      systemctl restart xray"
echo "============================================================"

# ---------- 9. 验证 ----------
echo ""
info "端口监听验证:"
ss -tlnp | grep ${PORT} | head -3
echo ""
info "Xray 运行状态:"
systemctl status xray --no-pager -l | head -5
echo ""
info "🎉 安装完成！以上信息建议截图保存。"
