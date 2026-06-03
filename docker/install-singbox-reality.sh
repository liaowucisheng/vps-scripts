#!/bin/bash
set -e
set -o pipefail

# ============================================================
# Sing-box + REALITY 一键安装脚本 (Docker 版)
# 适用系统: Ubuntu 20.04+ / Debian 10+（需已安装 Docker）
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
ok()        { echo -e "${GREEN}[✓]${NC} $1"; }

# ============================================================
# 前置检查: Docker
# ============================================================
if ! command -v docker &>/dev/null; then
    err "Docker 未安装！请先运行 install-docker.sh 安装 Docker。"
    exit 1
fi
ok "Docker 已安装: $(docker --version)"

if ! docker info &>/dev/null; then
    err "Docker 服务未运行！请先启动: systemctl start docker"
    exit 1
fi

# ============================================================
# 交互输入
# ============================================================
echo "============================================"
echo " Sing-box + REALITY 安装脚本 (Docker 版)"
echo " 前置条件: 已安装 Docker"
echo "============================================"
echo ""

read -p "请输入端口号 (默认 443): " PORT
PORT=${PORT:-443}

read -p "请输入回落目标域名 (默认 www.microsoft.com): " DEST_DOMAIN
DEST_DOMAIN=${DEST_DOMAIN:-www.microsoft.com}

read -p "是否开启 BBR? (y/n, 默认 y): " ENABLE_BBR
ENABLE_BBR=${ENABLE_BBR:-y}

# ============================================================
# 1. 系统准备
# ============================================================
info "更新系统..."
apt update -y && apt upgrade -y
apt install curl openssl -y

# ============================================================
# 2. 开启 BBR
# ============================================================
if [[ "$ENABLE_BBR" == "y" ]]; then
    info "开启 BBR 拥塞控制..."
    modprobe tcp_bbr 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null || echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p >/dev/null 2>&1
    if lsmod | grep -q bbr; then
        ok "BBR 已开启"
    else
        warn "BBR 未在当前内核生效（重启后生效）"
    fi
fi

# ============================================================
# 3. 拉取镜像
# ============================================================
info "拉取 Sing-box 镜像..."
PULL_OK=0
for i in 1 2 3; do
    if docker pull ghcr.io/sagernet/sing-box:latest >/dev/null 2>&1; then
        PULL_OK=1
        break
    fi
    if [[ $i -lt 3 ]]; then
        warn "拉取失败，${i}s 后重试... ($i/3)"
        sleep 2
    fi
done

if [[ $PULL_OK -eq 0 ]]; then
    err "拉取 Sing-box 镜像失败！请检查网络连接"
    exit 1
fi
ok "Sing-box 镜像拉取成功"

# ============================================================
# 4. 生成密钥
# ============================================================
info "生成加密密钥..."

UUID=$(docker run --rm ghcr.io/sagernet/sing-box:latest generate uuid)
KEY_OUTPUT=$(docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "PublicKey" | awk '{print $2}')
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

# ============================================================
# 5. 写入配置
# ============================================================
info "写入配置文件 /etc/singbox-docker/config.json ..."
mkdir -p /etc/singbox-docker

cat > /etc/singbox-docker/config.json <<EOF
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

ok "配置已写入"

# ============================================================
# 6. 停止冲突服务（如有）
# ============================================================
if systemctl is-active --quiet sing-box 2>/dev/null; then
    warn "检测到宿主机已安装 Sing-box (systemd 服务)，与 Docker 版端口冲突"
    read -p "是否停止并禁用系统 Sing-box 服务? (y/n, 默认 n): " STOP_NATIVE
    STOP_NATIVE=${STOP_NATIVE:-n}
    if [[ "$STOP_NATIVE" == "y" ]]; then
        systemctl stop sing-box
        systemctl disable sing-box
        ok "已停止系统 Sing-box 服务"
    else
        warn "跳过，请自行确保端口 ${PORT} 未被占用"
    fi
fi

if ss -tlnp | grep -q ":$PORT " 2>/dev/null; then
    warn "端口 ${PORT} 已被占用，Docker 容器可能启动失败"
    warn "运行: ss -tlnp | grep :${PORT}"
fi

# ============================================================
# 7. 启动容器
# ============================================================
info "启动 Sing-box Docker 容器..."

# 清理旧容器
docker rm -f singbox-reality 2>/dev/null || true

docker run -d \
    --name singbox-reality \
    --restart unless-stopped \
    --network host \
    -v /etc/singbox-docker/config.json:/etc/sing-box/config.json:ro \
    ghcr.io/sagernet/sing-box:latest \
    run -c /etc/sing-box/config.json >/dev/null 2>&1 || true

sleep 2

# 验证容器
if docker ps --format '{{.Names}}' | grep -qx "singbox-reality"; then
    ok "Sing-box Docker 容器运行中"
else
    err "Sing-box 容器启动失败！查看日志: docker logs singbox-reality"
    exit 1
fi

# ============================================================
# 8. 防火墙
# ============================================================
info "配置防火墙..."
if command -v ufw &>/dev/null; then
    ufw allow ${PORT}/tcp
    ufw allow 22/tcp
    ufw --force enable 2>/dev/null || true
fi

# ============================================================
# 9. 输出客户端信息
# ============================================================
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ip.sb 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null)

if [[ "$PORT" == "443" ]]; then
    PORT_STR=""
else
    PORT_STR=":${PORT}"
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}${PORT_STR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID1}&type=tcp&headerType=none#香港-SingBox"

echo ""
echo "============================================================"
highlight "✅ Sing-box + REALITY (Docker) 安装完成！"
echo "============================================================"
echo ""

highlight "📋 服务器参数"
echo "  协议:       VLESS + REALITY + Vision"
echo "  部署方式:   Docker ($(docker images --format '{{.Repository}}:{{.Tag}}' | grep sing-box))"
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
highlight "🛠 常用管理命令"
echo "  查看状态:       docker ps -a --filter name=singbox-reality"
echo "  查看日志:       docker logs singbox-reality"
echo "  实时日志:       docker logs -f singbox-reality"
echo "  重启:           docker restart singbox-reality"
echo "  停止:           docker stop singbox-reality"
echo "  启动:           docker start singbox-reality"
echo "  删除:           docker rm -f singbox-reality"
echo "  升级:           docker pull ghcr.io/sagernet/sing-box:latest && docker restart singbox-reality"
echo ""

highlight "🚀 速度参考"
echo "  Docker 使用 --network host 模式，性能与直接安装一致"
echo "  Sing-box 已开启: TCP Fast Open + Sniffing + DNS over TLS"
echo "  建议客户端开 MUX 多路复用"
echo ""

# ============================================================
# 10. 验证
# ============================================================
echo ""
info "端口监听验证:"
ss -tlnp | grep ${PORT} | head -3 || echo "  (无监听信息)"
echo ""
info "🎉 安装完成！以上信息建议截图保存。"
