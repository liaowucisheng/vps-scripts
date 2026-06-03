#!/bin/bash
set -e
set -o pipefail

# ============================================================
# code-server 一键部署脚本 (Docker 版)
# 适用系统: Ubuntu 20.04+ / Debian 10+ / CentOS 7+
# 功能: 浏览器中使用 VS Code，可选集成 Continue + DeepSeek AI
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
# 云厂商自动检测
# ============================================================
detect_cloud_provider() {
    local vendor=""
    local product=""

    [ -f /sys/class/dmi/id/sys_vendor ]   && vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)   || true
    [ -f /sys/class/dmi/id/product_name ] && product=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || true

    if echo "$vendor" | grep -qi "Alibaba" || echo "$product" | grep -qi "Alibaba"; then
        echo "aliyun"
        return
    fi
    if echo "$vendor" | grep -qi "Tencent" || echo "$product" | grep -qi "Tencent"; then
        echo "tencent"
        return
    fi
    if echo "$vendor" | grep -qi "Huawei"   || echo "$product" | grep -qi "Huawei" ||
       echo "$vendor" | grep -qi "HiSilicon" ; then
        echo "huawei"
        return
    fi
    if echo "$vendor" | grep -qi "Amazon EC2" || echo "$product" | grep -qi "Amazon EC2"; then
        echo "aws"
        return
    fi
    if echo "$vendor" | grep -qi "Microsoft" || echo "$product" | grep -qi "Microsoft"; then
        echo "azure"
        return
    fi
    if echo "$vendor" | grep -qi "Google" || echo "$product" | grep -qi "Google Compute Engine"; then
        echo "gcp"
        return
    fi

    # 备用检测: metadata 地址
    if curl -s --max-time 1 http://100.100.100.200/latest/meta-data/ 2>/dev/null | grep -q .; then
        echo "aliyun"
        return
    fi
    if curl -s --max-time 1 http://metadata.tencentyun.com/latest/meta-data/ 2>/dev/null | grep -q .; then
        echo "tencent"
        return
    fi

    echo "unknown"
}

cloud_name() {
    case "$1" in
        aliyun)  echo "阿里云" ;;
        tencent) echo "腾讯云" ;;
        huawei)  echo "华为云" ;;
        aws)     echo "AWS" ;;
        azure)   echo "Azure" ;;
        gcp)     echo "Google Cloud" ;;
        *)       echo "未知" ;;
    esac
}

is_china_cloud() {
    case "$1" in
        aliyun|tencent|huawei) return 0 ;;
        *) return 1 ;;
    esac
}

CLOUD_PROVIDER=$(detect_cloud_provider)
CLOUD_NAME=$(cloud_name "$CLOUD_PROVIDER")

# ============================================================
# 架构检测
# ============================================================
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       echo "$(uname -m)" ;;
    esac
}
ARCH=$(detect_arch)

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
echo " code-server 一键部署脚本 (Docker 版)"
echo " 适用: 浏览器中使用 VS Code"
echo " 系统: Ubuntu 20.04+ / Debian 10+ / CentOS 7+"
echo " 架构: ${ARCH}"
echo "============================================"
echo ""

if [[ "$CLOUD_PROVIDER" != "unknown" ]]; then
    info "检测到云厂商: ${CLOUD_NAME}"
else
    info "未检测到特定云厂商（通用服务器）"
fi

# 国内云厂商且无 Docker 镜像加速时提示
if is_china_cloud "$CLOUD_PROVIDER"; then
    if ! docker info 2>/dev/null | grep -q "Registry Mirrors:"; then
        warn "当前未配置 Docker 镜像加速"
        warn "国内服务器拉取 Docker Hub 镜像可能较慢或超时"
        warn "建议中断后先运行 install-docker.sh 配置镜像加速"
        echo ""
    fi
fi

# 检查系统内存
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
if [[ $TOTAL_MEM -lt 1024 ]]; then
    echo ""
    warn "系统内存仅 ${TOTAL_MEM}MB，code-server 最低建议 1GB"
    warn "轻量使用（编辑代码）可以运行，但打开大文件可能卡顿"
    read -p "是否添加 1GB SWAP 以缓解内存不足? (y/n, 默认 y): " SETUP_SWAP
    SETUP_SWAP=${SETUP_SWAP:-y}
    if [[ "$SETUP_SWAP" == "y" ]]; then
        if ! swapon --show 2>/dev/null | grep -q .; then
            info "添加 1GB SWAP..."
            dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile
            grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
            ok "SWAP 已添加（1GB）"
        else
            ok "SWAP 已存在，跳过"
        fi
    fi
    echo ""
fi

echo ""
read -p "请输入容器名称 (默认 code-server): " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-code-server}

# 检查容器是否已存在
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn "容器 \"$CONTAINER_NAME\" 已存在"
    read -p "是否删除旧容器并重建? (y/n, 默认 n): " RECREATE
    RECREATE=${RECREATE:-n}
    if [[ "$RECREATE" == "y" ]]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null
        ok "已删除旧容器"
    else
        err "取消部署"
        exit 1
    fi
fi

echo ""
read -p "请输入宿主机端口 (默认 8443): " HOST_PORT
HOST_PORT=${HOST_PORT:-8443}

echo ""
read -p "请设置访问密码 (留空自动生成 16 位随机密码): " PASSWORD
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 12)
    GEN_PASSWORD=1
fi

echo ""
read -p "项目存放目录 (默认 /root/code): " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-/root/code}

echo ""
read -p "时区 (默认 Asia/Shanghai): " TZ
TZ=${TZ:-Asia/Shanghai}

echo ""
read -p "是否安装 Continue AI 编程助手扩展? (y/n, 默认 n): " INSTALL_CONTINUE
INSTALL_CONTINUE=${INSTALL_CONTINUE:-n}

DEEPSEEK_KEY=""
if [[ "$INSTALL_CONTINUE" == "y" ]]; then
    echo ""
    read -p "是否配置 DeepSeek API 密钥? (y/n, 默认 n): " SETUP_DEEPSEEK
    SETUP_DEEPSEEK=${SETUP_DEEPSEEK:-n}
    if [[ "$SETUP_DEEPSEEK" == "y" ]]; then
        echo "可在 https://platform.deepseek.com/api_keys 获取"
        echo ""
        read -p "请输入 DeepSeek API Key (sk-...): " DEEPSEEK_KEY
    fi
fi

echo ""
read -p "是否开启 BBR 拥塞控制? (y/n, 默认 y): " ENABLE_BBR
ENABLE_BBR=${ENABLE_BBR:-y}

# ============================================================
# 1. 系统准备
# ============================================================
info "更新系统并安装依赖..."
if command -v apt &>/dev/null; then
    apt update -y && apt upgrade -y
    apt install curl openssl -y
elif command -v yum &>/dev/null; then
    yum update -y
    yum install curl openssl -y
elif command -v dnf &>/dev/null; then
    dnf update -y
    dnf install curl openssl -y
else
    err "不支持的包管理器！仅支持 apt/yum/dnf"
    exit 1
fi

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
# 3. 创建目录
# ============================================================
echo ""
CONFIG_DIR=/etc/code-server-docker
info "创建配置目录 ${CONFIG_DIR}..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$PROJECT_DIR"
ok "目录已就绪"

# ============================================================
# 4. 拉取镜像
# ============================================================
info "拉取 code-server 镜像..."
PULL_OK=0
for i in 1 2 3; do
    if docker pull codercom/code-server:latest >/dev/null 2>&1; then
        PULL_OK=1
        break
    fi
    if [[ $i -lt 3 ]]; then
        warn "拉取失败，${i}s 后重试... ($i/3)"
        sleep 2
    fi
done

if [[ $PULL_OK -eq 0 ]]; then
    err "拉取 code-server 镜像失败！"
    if is_china_cloud "$CLOUD_PROVIDER"; then
        err "提示：国内服务器可能出现 Docker Hub 连接问题"
        err "建议先运行 install-docker.sh 配置镜像加速，再重试本脚本"
    fi
    exit 1
fi
ok "code-server 镜像拉取成功"

# ============================================================
# 5. 启动容器
# ============================================================
info "启动 code-server 容器..."

DOCKER_ARGS=(
    -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    -p "${HOST_PORT}:8443"
    -v "${CONFIG_DIR}:/home/coder/.config/code-server"
    -v "${PROJECT_DIR}:/home/coder/project"
    -e "PASSWORD=${PASSWORD}"
    -e "TZ=${TZ}"
    -e "DEFAULT_WORKSPACE=/home/coder/project"
)

docker run "${DOCKER_ARGS[@]}" codercom/code-server:latest >/dev/null 2>&1 || true

# 等待容器初始化（config.yaml 生成后才算就绪）
info "等待 code-server 初始化..."
CODER_READY=0
for i in 1 2 3 4 5; do
    if docker exec "$CONTAINER_NAME" test -f /home/coder/.config/code-server/config.yaml 2>/dev/null; then
        CODER_READY=1
        ok "code-server 初始化完成"
        break
    fi
    sleep 1
done

if [[ $CODER_READY -eq 0 ]]; then
    warn "code-server 初始化超时，可能仍在启动中"
fi

# 验证容器运行状态
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    ok "code-server 容器运行中"
else
    err "容器启动失败！查看日志: docker logs $CONTAINER_NAME"
    exit 1
fi

# ============================================================
# 6. 安装 Continue 扩展（可选）
# ============================================================
if [[ "$INSTALL_CONTINUE" == "y" ]]; then
    echo ""
    info "正在安装 Continue 扩展（可能需要 10-30 秒，请等待）..."
    docker exec -u coder "$CONTAINER_NAME" code-server --install-extension Continue.continue --force >/dev/null 2>&1 || true

    if docker exec -u coder "$CONTAINER_NAME" code-server --list-extensions 2>/dev/null | grep -qi continue; then
        ok "Continue 扩展已安装"
    else
        warn "Continue 扩展安装未完成，可稍后手动安装:"
        warn "  docker exec -u coder $CONTAINER_NAME code-server --install-extension Continue.continue"
    fi

    # 配置 DeepSeek（可选）
    if [[ -n "$DEEPSEEK_KEY" ]]; then
        info "配置 DeepSeek API..."

        # 构建 Continue 配置 JSON（宿主机端完成变量替换）
        CONTINUE_CONFIG=$(cat << EOF
{
  "models": [
    {
      "title": "DeepSeek Chat",
      "provider": "openai",
      "model": "deepseek-chat",
      "apiKey": "${DEEPSEEK_KEY}",
      "apiBase": "https://api.deepseek.com/v1"
    },
    {
      "title": "DeepSeek Coder",
      "provider": "openai",
      "model": "deepseek-coder",
      "apiKey": "${DEEPSEEK_KEY}",
      "apiBase": "https://api.deepseek.com/v1"
    }
  ],
  "tabAutocompleteModel": {
    "title": "DeepSeek Coder",
    "provider": "openai",
    "model": "deepseek-coder",
    "apiKey": "${DEEPSEEK_KEY}",
    "apiBase": "https://api.deepseek.com/v1"
  },
  "embeddingsProvider": {
    "provider": "transformers.js"
  }
}
EOF
)

        echo "$CONTINUE_CONFIG" | docker exec -i -u coder "$CONTAINER_NAME" sh -c "mkdir -p /home/coder/.continue && cat > /home/coder/.continue/config.json"
        ok "DeepSeek 配置已写入"
    fi
fi

# ============================================================
# 7. 防火墙
# ============================================================
if command -v ufw &>/dev/null; then
    ufw allow "${HOST_PORT}/tcp" >/dev/null 2>&1
    info "已放行端口 ${HOST_PORT}（UFW）"
fi

if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${HOST_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "已放行端口 ${HOST_PORT}（firewalld）"
fi

# ============================================================
# 8. 输出信息
# ============================================================
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ip.sb 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null)

echo ""
echo "============================================================"
highlight "✅ code-server (Docker) 部署完成！"
echo "============================================================"
echo ""

highlight "📋 部署信息"
echo "  云厂商:        ${CLOUD_NAME}"
echo "  访问地址:      http://${SERVER_IP}:${HOST_PORT}"
echo "  密码:          ${PASSWORD}"
echo "  项目目录:      ${PROJECT_DIR} → /home/coder/project"
echo "  配置目录:      ${CONFIG_DIR} → /home/coder/.config/code-server"
echo "  容器镜像:      codercom/code-server:latest"
if [[ "$INSTALL_CONTINUE" == "y" ]]; then
    echo "  Continue:      已安装"
    if [[ -n "$DEEPSEEK_KEY" ]]; then
        echo "  DeepSeek:      已配置 (deepseek-chat / deepseek-coder)"
    fi
fi
echo ""

highlight "🔑 密码管理"
echo "  如需修改密码，删除容器后用新密码重新创建:"
echo "  docker rm -f $CONTAINER_NAME"
echo "  docker run ... -e PASSWORD=新密码 ..."
echo ""

highlight "🛠 常用管理命令"
echo "  查看状态:       docker ps -a --filter name=$CONTAINER_NAME"
echo "  查看日志:       docker logs $CONTAINER_NAME"
echo "  实时日志:       docker logs -f $CONTAINER_NAME"
echo "  重启:           docker restart $CONTAINER_NAME"
echo "  停止:           docker stop $CONTAINER_NAME"
echo "  启动:           docker start $CONTAINER_NAME"
echo "  删除:           docker rm -f $CONTAINER_NAME"
echo "  进入容器:       docker exec -it $CONTAINER_NAME /bin/bash"
echo "  升级:           docker pull codercom/code-server:latest && docker restart $CONTAINER_NAME"
echo ""

highlight "📁 项目管理"
echo "  上传文件到:     ${PROJECT_DIR}"
echo "  容器内路径:     /home/coder/project"
echo "  修改后无需重启，文件实时同步"
echo ""

if [[ "$INSTALL_CONTINUE" == "y" ]] && [[ -n "$DEEPSEEK_KEY" ]]; then
    highlight "🤖 Continue + DeepSeek 已就绪"
    echo "  打开 VS Code → 左侧 AI 图标 → 选择 DeepSeek Chat 即可开始对话"
    echo "  编辑代码时 DeepSeek Coder 会自动提供补全建议"
    echo "  如需修改配置: docker exec -it $CONTAINER_NAME vi /home/coder/.continue/config.json"
    echo ""
fi

highlight "🌐 安全建议"
echo "  1. 云服务器安全组放行 TCP ${HOST_PORT} 端口"
echo "  2. code-server 默认自签 HTTPS 证书，浏览器会显示安全警告，点击「高级」继续访问即可"
echo "  3. 如需绑定域名 + 合法证书，可用 deploy-nginx.sh 反向代理"
echo "  4. 建议设置复杂密码，避免端口暴露后被扫描"
echo "";

if [[ $GEN_PASSWORD -eq 1 ]]; then
    warn "📌 密码为随机生成，建议截图保存：${PASSWORD}"
fi
echo ""

# ============================================================
# 9. 最终验证
# ============================================================
info "端口监听验证:"
ss -tlnp 2>/dev/null | grep ":${HOST_PORT} " | head -3 || echo "  (无监听信息，容器可能尚未绑定)"
echo ""

info "🎉 部署完成！浏览器打开 http://${SERVER_IP}:${HOST_PORT} 输入密码即可使用"
