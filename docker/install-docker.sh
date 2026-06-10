#!/bin/bash
set -e
set -o pipefail

# ============================================================
# Docker + Docker Compose 一键安装脚本
# 适用系统: Ubuntu 20.04+ / Debian 10+ / CentOS 7+
# 适用场景: 阿里云 / 腾讯云 / 华为云 轻量应用服务器
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================
# Root 权限检查
# ============================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERR] 此脚本需要 root 权限运行！${NC}"
    echo -e "${YELLOW}请使用 sudo 或以 root 用户执行:${NC}"
    echo -e "  ${BLUE}sudo bash $0${NC}"
    echo ""
    echo -e "${YELLOW}或者切换到 root 用户:${NC}"
    echo -e "  ${BLUE}sudo -i${NC}"
    exit 1
fi

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

    # 备用检测: 尝试访问各云厂商 metadata 地址（超时短，不阻塞）
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

CLOUD_PROVIDER=$(detect_cloud_provider)

# 云厂商中文名
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

CLOUD_NAME=$(cloud_name "$CLOUD_PROVIDER")

# 判断是否国内云厂商
is_china_cloud() {
    case "$1" in
        aliyun|tencent|huawei) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# 交互输入
# ============================================================
echo "============================================"
echo " Docker + Compose 一键安装脚本"
echo " 适用: Ubuntu 20.04+ / Debian 10+ / CentOS 7+"
echo "============================================"
echo ""

if [[ "$CLOUD_PROVIDER" != "unknown" ]]; then
    info "检测到云厂商: ${CLOUD_NAME}"
else
    info "未检测到特定云厂商（通用服务器）"
fi
echo ""

# ---------- 镜像加速（国内云厂商默认推荐）----------
MIRROR_DEFAULT="n"
is_china_cloud "$CLOUD_PROVIDER" && MIRROR_DEFAULT="y"

# 阿里云国内/海外地域分别处理
if [[ "$CLOUD_PROVIDER" == "aliyun" ]]; then
    echo -e "${YELLOW}检测到阿里云服务器。${NC}"
    echo -e "${YELLOW}如果服务器在中国大陆，建议启用镜像加速。${NC}"
    echo -e "${YELLOW}如果服务器在海外，可直接拉取 Docker Hub 镜像，无需加速。${NC}"
    echo ""
    read -p "服务器是否在中国大陆地域? (y/n, 默认 n): " IS_CHINA_REGION
    IS_CHINA_REGION=${IS_CHINA_REGION:-n}
    if [[ "$IS_CHINA_REGION" == "y" ]]; then
        MIRROR_DEFAULT="y"
    else
        MIRROR_DEFAULT="n"
    fi
elif is_china_cloud "$CLOUD_PROVIDER"; then
    echo -e "${YELLOW}检测到 ${CLOUD_NAME} 服务器，推荐启用镜像加速。${NC}"
    MIRROR_DEFAULT="y"
fi

echo ""
read -p "是否启用 Docker 镜像加速? (y/n, 默认 ${MIRROR_DEFAULT}): " ENABLE_MIRROR
ENABLE_MIRROR=${ENABLE_MIRROR:-$MIRROR_DEFAULT}

DOCKER_MIRROR=""
if [[ "$ENABLE_MIRROR" == "y" ]]; then
    echo ""
    echo "选择镜像源:"

    # 根据云厂商调整推荐顺序
    case "$CLOUD_PROVIDER" in
        aliyun)
            echo "  1) 阿里云容器镜像服务加速器 (推荐，需登录 cr.console.aliyun.com 获取专属地址)"
            echo "  2) Docker Proxy 镜像 (https://dockerproxy.com)"
            echo "  3) 中科大镜像 (https://docker.mirrors.ustc.edu.cn)"
            echo "  4) 自定义"
            read -p "请输入选项 (1-4, 默认 1): " MIRROR_CHOICE
            MIRROR_CHOICE=${MIRROR_CHOICE:-1}
            ;;
        tencent)
            echo "  1) 腾讯云容器镜像服务加速器 (推荐，需登录 console.cloud.tencent.com/tcr 获取)"
            echo "  2) Docker Proxy 镜像 (https://dockerproxy.com)"
            echo "  3) 中科大镜像 (https://docker.mirrors.ustc.edu.cn)"
            echo "  4) 自定义"
            read -p "请输入选项 (1-4, 默认 1): " MIRROR_CHOICE
            MIRROR_CHOICE=${MIRROR_CHOICE:-1}
            ;;
        *)
            echo "  1) 阿里云加速器 (需登录 cr.console.aliyun.com 获取专属地址)"
            echo "  2) Docker Proxy 镜像 (https://dockerproxy.com)"
            echo "  3) 中科大镜像 (https://docker.mirrors.ustc.edu.cn)"
            echo "  4) 自定义"
            read -p "请输入选项 (1-4, 默认 2): " MIRROR_CHOICE
            MIRROR_CHOICE=${MIRROR_CHOICE:-2}
            ;;
    esac

    case "$MIRROR_CHOICE" in
        1)
            if [[ "$CLOUD_PROVIDER" == "aliyun" ]]; then
                read -p "请输入阿里云加速器地址 (如 https://xxxxx.mirror.aliyuncs.com): " DOCKER_MIRROR
            elif [[ "$CLOUD_PROVIDER" == "tencent" ]]; then
                read -p "请输入腾讯云加速器地址: " DOCKER_MIRROR
            else
                read -p "请输入加速器地址: " DOCKER_MIRROR
            fi
            ;;
        2)
            DOCKER_MIRROR="https://dockerproxy.com"
            ;;
        3)
            DOCKER_MIRROR="https://docker.mirrors.ustc.edu.cn"
            ;;
        4)
            read -p "请输入镜像加速地址: " DOCKER_MIRROR
            ;;
    esac
fi

echo ""
read -p "是否安装 Docker Compose? (y/n, 默认 y): " INSTALL_COMPOSE
INSTALL_COMPOSE=${INSTALL_COMPOSE:-y}

echo ""
read -p "是否开启 BBR? (y/n, 默认 y): " ENABLE_BBR
ENABLE_BBR=${ENABLE_BBR:-y}

echo ""
read -p "是否允许非 root 用户运行 Docker? (y/n, 默认 y): " NON_ROOT
NON_ROOT=${NON_ROOT:-y}

# ============================================================
# 1. 系统准备
# ============================================================
info "更新系统..."
if command -v apt &>/dev/null; then
    apt update -y && apt upgrade -y
    apt install curl wget -y
elif command -v yum &>/dev/null; then
    yum update -y
    yum install curl wget -y
elif command -v dnf &>/dev/null; then
    dnf update -y
    dnf install curl wget -y
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
# 3. 卸载旧版本
# ============================================================
info "移除旧版 Docker（如有）..."
if command -v apt &>/dev/null; then
    for pkg in docker docker-engine docker.io containerd runc; do
        apt remove -y "$pkg" 2>/dev/null || true
    done
elif command -v yum &>/dev/null; then
    yum remove -y docker docker-client docker-client-latest docker-common \
        docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
fi

# ============================================================
# 4. 安装 Docker
# ============================================================
info "安装 Docker (官方脚本)..."
curl -fsSL --max-time 30 https://get.docker.com -o /tmp/get-docker.sh || {
    err "下载 Docker 安装脚本失败，请检查网络连接"
    exit 1
}

# 国内云服务器: 将 download.docker.com 替换为阿里云镜像
if is_china_cloud "$CLOUD_PROVIDER"; then
    info "检测到国内云厂商，使用阿里云 Docker CE 镜像加速下载..."
    sed -i 's|https://download.docker.com|https://mirrors.aliyun.com/docker-ce|g' /tmp/get-docker.sh
    ok "已将 download.docker.com 替换为 mirrors.aliyun.com/docker-ce"
fi

sh /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

if command -v docker &>/dev/null; then
    ok "Docker 安装成功: $(docker --version)"
else
    err "Docker 安装失败！"
    exit 1
fi

# ============================================================
# 5. 配置 daemon.json（镜像加速 + 日志限制 合并写入）
# ============================================================
info "配置 Docker daemon..."
mkdir -p /etc/docker
DAEMON_JSON="/etc/docker/daemon.json"

build_daemon_json() {
    # 用 python3 构建 JSON（如果可用），否则 fallback 到 cat + 仅写入基础配置
    if command -v python3 &>/dev/null; then
        python3 -c "
import json
cfg = {}
# 读取已有配置
try:
    with open('$DAEMON_JSON', 'r') as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass
# 镜像加速
${DOCKER_MIRROR:+mirrors = cfg.get('registry-mirrors', []); _m = '$DOCKER_MIRROR'; _m not in mirrors and mirrors.append(_m); cfg['registry-mirrors'] = mirrors}
# 日志限制
cfg['log-driver'] = 'json-file'
cfg['log-opts'] = {'max-size': '10m', 'max-file': '3'}
with open('$DAEMON_JSON', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && return 0
    fi
    return 1
}

if build_daemon_json; then
    ok "Docker 配置已更新"
else
    warn "python3 不可用，使用基础配置"
    cat > "$DAEMON_JSON" <<EOF
{
  "registry-mirrors": [${DOCKER_MIRROR:+"\"${DOCKER_MIRROR}\""}],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    ok "Docker 基础配置已写入"
fi

if [[ -n "$DOCKER_MIRROR" ]]; then
    ok "已配置镜像加速: ${DOCKER_MIRROR}"
fi
ok "已配置日志限制（单容器最大 10MB，保留 3 个文件）"

# ============================================================
# 6. 启动 Docker
# ============================================================
info "启动 Docker 服务..."
systemctl enable docker
systemctl restart docker
sleep 2

if systemctl is-active --quiet docker; then
    ok "Docker 服务运行中"
else
    err "Docker 启动失败！查看日志: journalctl -u docker --no-pager -l -n 50"
    exit 1
fi

# ============================================================
# 7. 非 root 用户
# ============================================================
if [[ "$NON_ROOT" == "y" ]]; then
    # 尝试检测当前登录用户（非 root）
    TARGET_USER=""
    if command -v getent &>/dev/null; then
        # 找 sudo 组或 wheel 组中第一个非 root 用户
        TARGET_USER=$( (getent group sudo 2>/dev/null || true) | cut -d: -f4 | tr ',' '\n' | head -1)
        [[ -z "$TARGET_USER" ]] && TARGET_USER=$( (getent group wheel 2>/dev/null || true) | cut -d: -f4 | tr ',' '\n' | head -1)
    fi

    # 如果没找到，检查 SUDO_USER 环境变量
    if [[ -z "$TARGET_USER" ]] && [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    fi

    # 如果仍然没找到，尝试使用 $USER（前提是非 root）
    if [[ -z "$TARGET_USER" ]] && [[ "${USER:-root}" != "root" ]]; then
        TARGET_USER="$USER"
    fi

    if [[ -n "$TARGET_USER" ]]; then
        if id -u "$TARGET_USER" &>/dev/null; then
            usermod -aG docker "$TARGET_USER"
            ok "已添加用户 $TARGET_USER 到 docker 组（重新登录后生效）"
        else
            warn "用户 $TARGET_USER 不存在，跳过非 root 配置"
        fi
    else
        warn "未找到非 root 用户，跳过 docker 组配置"
        warn "  ├ 安装后手动执行: usermod -aG docker \$USER"
        warn "  └ 然后重新登录终端使权限生效"
    fi
fi

# ============================================================
# 8. 安装 Docker Compose
# ============================================================
if [[ "$INSTALL_COMPOSE" == "y" ]]; then
    info "安装 Docker Compose..."

    # 新版 Docker 自带 compose 插件
    if docker compose version &>/dev/null; then
        ok "Docker Compose 插件已安装: $(docker compose version)"
    else
        warn "Docker Compose 插件缺失，尝试独立安装..."

        # 从 GitHub 获取最新版本（带 fallback）
        COMPOSE_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/docker/compose/releases/latest \
            | grep "tag_name" | cut -d '"' -f 4 || true)
        [[ -z "$COMPOSE_VERSION" ]] && COMPOSE_VERSION="v2.32.4"

        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  COMPOSE_ARCH="x86_64" ;;
            aarch64) COMPOSE_ARCH="aarch64" ;;
            *)       err "不支持的架构: $ARCH"; exit 1 ;;
        esac

        curl -fsSL --max-time 30 \
            "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose

        if command -v docker-compose &>/dev/null; then
            ok "Docker Compose 安装成功: $(docker-compose --version)"
        else
            err "Docker Compose 安装失败！"
        fi
    fi

    # 确保 docker compose（插件）和 docker-compose（独立命令）都可用
    # 新版 Docker 的 compose 插件可能在多个路径
    if ! command -v docker-compose &>/dev/null && docker compose version &>/dev/null; then
        for _path in /usr/libexec/docker/cli-plugins/docker-compose \
                     /usr/local/lib/docker/cli-plugins/docker-compose \
                     /usr/lib/docker/cli-plugins/docker-compose; do
            if [ -x "$_path" ]; then
                ln -sf "$_path" /usr/local/bin/docker-compose 2>/dev/null || true
                break
            fi
        done
    fi
fi

# ============================================================
# 9. 防火墙
# ============================================================
info "配置防火墙..."
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp >/dev/null 2>&1
    ufw --force enable 2>/dev/null || true
    warn "如需暴露 Docker 容器端口，请在 ${CLOUD_NAME} 安全组放行对应端口"
fi

if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    warn "如需暴露 Docker 容器端口，请在 ${CLOUD_NAME} 安全组放行对应端口"
fi

# ============================================================
# 10. Docker 自检
# ============================================================
info "运行 Docker 自检..."
set +e
DOCKER_TEST_OUTPUT=$(docker run --rm hello-world 2>&1)
DOCKER_TEST_EXIT=$?
set -e

if [[ $DOCKER_TEST_EXIT -eq 0 ]]; then
    ok "Docker 自检通过"
else
    warn "Docker 自检失败: $(echo "$DOCKER_TEST_OUTPUT" | tail -3)"
    warn "这通常不影响功能，可稍后手动验证: docker run --rm hello-world"
fi
docker image rm hello-world 2>/dev/null || true

# ============================================================
# 11. 输出信息
# ============================================================
echo ""
echo "============================================================"
highlight "✅ Docker + Compose 安装完成！"
echo "============================================================"
echo ""

highlight "📋 安装摘要"
echo "  云厂商:           ${CLOUD_NAME}"
echo "  Docker:           $(docker --version 2>/dev/null)"
if docker compose version &>/dev/null; then
    echo "  Compose 插件:     $(docker compose version)"
fi
if command -v docker-compose &>/dev/null; then
    echo "  docker-compose:   $(docker-compose --version 2>/dev/null)"
fi
echo "  Docker 服务:      $(systemctl is-active docker)"

if [[ -n "$DOCKER_MIRROR" ]]; then
    echo "  镜像加速:         $DOCKER_MIRROR"
fi

echo ""
highlight "🛠 常用管理命令"
echo "  查看 Docker 版本:         docker --version"
echo "  查看运行中容器:           docker ps"
echo "  查看所有容器:             docker ps -a"
echo "  查看镜像列表:             docker images"
echo "  查看服务状态:             systemctl status docker"
echo "  查看日志:                 journalctl -u docker --no-pager -l -n 30"
echo "  重启 Docker:              systemctl restart docker"
echo ""
echo "  Docker Compose 常用:"
echo "    启动所有服务:           docker compose up -d"
echo "    停止所有服务:           docker compose down"
echo "    查看日志:               docker compose logs -f"
echo "    重新构建并启动:         docker compose up -d --build"
echo ""

highlight "📦 快速验证"
echo "  docker run hello-world        # 测试 Docker 能否正常工作"
echo ""

warn "📌 ${CLOUD_NAME} 安全组记得放行需要暴露的端口！"
warn "📌 非 root 用户需重新登录终端使 docker 组权限生效"
echo ""

# ============================================================
# 12. 最终检查
# ============================================================
echo ""
info "Docker 版本:"
docker --version
echo ""
info "端口监听验证:"
ss -tlnp 2>/dev/null | grep -E "dockerd|containerd" | head -3 || echo "  (Docker 默认不监听 TCP 端口，这是正常的)"
echo ""
if [[ "$ENABLE_BBR" == "y" ]]; then
    info "BBR 状态:"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print "  " $3}' || echo "  (不可用)"
fi
echo ""
info "🎉 安装完成！Docker 环境已就绪。"
