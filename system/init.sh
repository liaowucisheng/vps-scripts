#!/bin/bash
set -e
set -o pipefail

# ============================================================
# 系统一键初始化脚本
# 适用: Ubuntu 20.04+ / Debian 10+ / CentOS 7+
# 功能: 换源、更新、BBR、基础工具、时区、SWAP、主机名
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

    # 备用检测：metadata 地址
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

is_china_cloud() {
    case "$1" in
        aliyun|tencent|huawei) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# 系统信息检测
# ============================================================
detect_os() {
    if   grep -qi "ubuntu" /etc/os-release 2>/dev/null; then echo "ubuntu"
    elif grep -qi "debian" /etc/os-release 2>/dev/null; then echo "debian"
    elif grep -qi "centos" /etc/os-release 2>/dev/null; then echo "centos"
    elif grep -qi "rhel" /etc/os-release 2>/dev/null;   then echo "rhel"
    else echo "unknown"
    fi
}

detect_os_version() {
    grep -oP '(?<=VERSION_ID=")[^"]*' /etc/os-release 2>/dev/null | cut -d. -f1
}

OS=$(detect_os)
OS_VERSION=$(detect_os_version)
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_DISK=$(df -BG / | awk 'NR==2{print $2}' | sed 's/G//')
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

# ============================================================
# 交互输入
# ============================================================
echo "============================================"
echo " 系统一键初始化脚本"
echo " 适用: Ubuntu 20.04+ / Debian 10+ / CentOS 7+"
echo "============================================"
echo ""

if [[ "$CLOUD_PROVIDER" != "unknown" ]]; then
    info "检测到云厂商: ${CLOUD_NAME}"
else
    info "未检测到特定云厂商（通用服务器）"
fi
echo ""

# ---------- 1. APT 换源（仅 Debian/Ubuntu）----------
APT_SOURCES_MIRROR=""
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    MIRROR_DEFAULT="n"
    is_china_cloud "$CLOUD_PROVIDER" && MIRROR_DEFAULT="y"

    echo "━━━ APT 软件源 ━━━"
    if is_china_cloud "$CLOUD_PROVIDER"; then
        warn "国内 ${CLOUD_NAME} 服务器，推荐切换为国内镜像源（大幅提升 apt 速度）"
    fi
    read -p "是否更换 APT 源为国内镜像? (y/n, 默认 ${MIRROR_DEFAULT}): " CHANGE_APT_MIRROR
    CHANGE_APT_MIRROR=${CHANGE_APT_MIRROR:-$MIRROR_DEFAULT}

    if [[ "$CHANGE_APT_MIRROR" == "y" ]]; then
        echo ""
        echo "选择镜像源:"

        case "$CLOUD_PROVIDER" in
            aliyun)
                echo "  1) 阿里云镜像 (mirrors.aliyun.com)  [推荐]"
                echo "  2) 华为云镜像 (mirrors.huaweicloud.com)"
                echo "  3) 腾讯云镜像 (mirrors.tencent.com)"
                echo "  4) 中科大镜像 (mirrors.ustc.edu.cn)"
                echo "  5) 网易镜像 (mirrors.163.com)"
                echo "  6) 自定义"
                read -p "请输入选项 (1-6, 默认 1): " MIRROR_CHOICE
                MIRROR_CHOICE=${MIRROR_CHOICE:-1}
                ;;
            tencent)
                echo "  1) 腾讯云镜像 (mirrors.tencent.com)  [推荐]"
                echo "  2) 阿里云镜像 (mirrors.aliyun.com)"
                echo "  3) 华为云镜像 (mirrors.huaweicloud.com)"
                echo "  4) 中科大镜像 (mirrors.ustc.edu.cn)"
                echo "  5) 网易镜像 (mirrors.163.com)"
                echo "  6) 自定义"
                read -p "请输入选项 (1-6, 默认 1): " MIRROR_CHOICE
                MIRROR_CHOICE=${MIRROR_CHOICE:-1}
                ;;
            huawei)
                echo "  1) 华为云镜像 (mirrors.huaweicloud.com)  [推荐]"
                echo "  2) 阿里云镜像 (mirrors.aliyun.com)"
                echo "  3) 腾讯云镜像 (mirrors.tencent.com)"
                echo "  4) 中科大镜像 (mirrors.ustc.edu.cn)"
                echo "  5) 网易镜像 (mirrors.163.com)"
                echo "  6) 自定义"
                read -p "请输入选项 (1-6, 默认 1): " MIRROR_CHOICE
                MIRROR_CHOICE=${MIRROR_CHOICE:-1}
                ;;
            *)
                echo "  1) 阿里云镜像 (mirrors.aliyun.com)"
                echo "  2) 华为云镜像 (mirrors.huaweicloud.com)"
                echo "  3) 腾讯云镜像 (mirrors.tencent.com)"
                echo "  4) 中科大镜像 (mirrors.ustc.edu.cn)  [推荐]"
                echo "  5) 网易镜像 (mirrors.163.com)"
                echo "  6) 自定义"
                read -p "请输入选项 (1-6, 默认 4): " MIRROR_CHOICE
                MIRROR_CHOICE=${MIRROR_CHOICE:-4}
                ;;
        esac

        case "$MIRROR_CHOICE" in
            1)
                case "$CLOUD_PROVIDER" in
                    aliyun)  APT_SOURCES_MIRROR="mirrors.aliyun.com" ;;
                    tencent) APT_SOURCES_MIRROR="mirrors.tencent.com" ;;
                    huawei)  APT_SOURCES_MIRROR="mirrors.huaweicloud.com" ;;
                    *)       APT_SOURCES_MIRROR="mirrors.aliyun.com" ;;
                esac
                ;;
            2)
                case "$CLOUD_PROVIDER" in
                    aliyun)  APT_SOURCES_MIRROR="mirrors.huaweicloud.com" ;;
                    tencent) APT_SOURCES_MIRROR="mirrors.aliyun.com" ;;
                    huawei)  APT_SOURCES_MIRROR="mirrors.aliyun.com" ;;
                    *)       APT_SOURCES_MIRROR="mirrors.huaweicloud.com" ;;
                esac
                ;;
            3)
                case "$CLOUD_PROVIDER" in
                    aliyun)  APT_SOURCES_MIRROR="mirrors.tencent.com" ;;
                    tencent) APT_SOURCES_MIRROR="mirrors.huaweicloud.com" ;;
                    huawei)  APT_SOURCES_MIRROR="mirrors.tencent.com" ;;
                    *)       APT_SOURCES_MIRROR="mirrors.tencent.com" ;;
                esac
                ;;
            4) APT_SOURCES_MIRROR="mirrors.ustc.edu.cn" ;;
            5) APT_SOURCES_MIRROR="mirrors.163.com" ;;
            6)
                read -p "请输入镜像源地址 (如 mirrors.aliyun.com): " APT_SOURCES_MIRROR
                ;;
        esac
    fi
fi

echo ""

# ---------- 2. 系统包更新 ----------
read -p "是否更新系统软件包? (apt update && apt upgrade, y/n, 默认 y): " DO_UPDATE
DO_UPDATE=${DO_UPDATE:-y}

echo ""
# ---------- 3. 基础工具 ----------
read -p "是否安装基础工具 (curl/wget/openssl/git/vim)? (y/n, 默认 y): " INSTALL_TOOLS
INSTALL_TOOLS=${INSTALL_TOOLS:-y}

echo ""
# ---------- 4. BBR ----------
read -p "是否开启 BBR 拥塞控制? (y/n, 默认 y): " ENABLE_BBR
ENABLE_BBR=${ENABLE_BBR:-y}

echo ""
# ---------- 5. 时区 ----------
read -p "是否设置时区为 Asia/Shanghai? (y/n, 默认 y): " SET_TZ
SET_TZ=${SET_TZ:-y}

echo ""
# ---------- 6. SWAP ----------
SETUP_SWAP="n"
if [[ $TOTAL_MEM -lt 2048 ]]; then
    warn "内存仅 ${TOTAL_MEM}MB，建议添加 SWAP"
    read -p "是否添加 SWAP? (y/n, 默认 y): " SETUP_SWAP
    SETUP_SWAP=${SETUP_SWAP:-y}
fi

echo ""
# ---------- 7. 主机名 ----------
read -p "是否修改主机名? (y/n, 默认 n): " SET_HOSTNAME
SET_HOSTNAME=${SET_HOSTNAME:-n}
if [[ "$SET_HOSTNAME" == "y" ]]; then
    read -p "请输入新的主机名: " NEW_HOSTNAME
fi

echo ""
# ---------- 8. SSH 端口 ----------
read -p "是否修改 SSH 端口? (y/n, 默认 n): " CHANGE_SSH_PORT
CHANGE_SSH_PORT=${CHANGE_SSH_PORT:-n}
if [[ "$CHANGE_SSH_PORT" == "y" ]]; then
    read -p "请输入新的 SSH 端口 (22-65535): " SSH_PORT
fi

# ============================================================
# 1. 换源 (Debian/Ubuntu)
# ============================================================
if [[ -n "$APT_SOURCES_MIRROR" ]]; then
    echo ""
    info "更换 APT 源为 ${APT_SOURCES_MIRROR} ..."

    # 备份原 sources.list（仅首次备份）
    if [[ ! -f /etc/apt/sources.list.bak ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
    fi

    if [[ "$OS" == "ubuntu" ]]; then
        UBUNTU_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
        cat > /etc/apt/sources.list <<EOF
deb https://${APT_SOURCES_MIRROR}/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb https://${APT_SOURCES_MIRROR}/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
deb https://${APT_SOURCES_MIRROR}/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb https://${APT_SOURCES_MIRROR}/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
EOF
        ok "Ubuntu ${UBUNTU_CODENAME} 源已更换为 ${APT_SOURCES_MIRROR}"

    elif [[ "$OS" == "debian" ]]; then
        DEBIAN_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
        cat > /etc/apt/sources.list <<EOF
deb https://${APT_SOURCES_MIRROR}/debian/ ${DEBIAN_CODENAME} main contrib non-free
deb https://${APT_SOURCES_MIRROR}/debian/ ${DEBIAN_CODENAME}-security main contrib non-free
deb https://${APT_SOURCES_MIRROR}/debian/ ${DEBIAN_CODENAME}-updates main contrib non-free
EOF
        ok "Debian ${DEBIAN_CODENAME} 源已更换为 ${APT_SOURCES_MIRROR}"
    fi
fi

# ============================================================
# 2. 更新系统
# ============================================================
if [[ "$DO_UPDATE" == "y" ]]; then
    echo ""
    info "更新系统软件包..."
    if command -v apt &>/dev/null; then
        apt update -y
        apt upgrade -y
        ok "系统已更新"
    elif command -v yum &>/dev/null; then
        yum update -y
        ok "系统已更新"
    elif command -v dnf &>/dev/null; then
        dnf update -y
        ok "系统已更新"
    fi
fi

# ============================================================
# 3. 安装基础工具
# ============================================================
if [[ "$INSTALL_TOOLS" == "y" ]]; then
    echo ""
    info "安装基础工具..."
    if command -v apt &>/dev/null; then
        apt install -y curl wget openssl git vim ufw
    elif command -v yum &>/dev/null; then
        yum install -y curl wget openssl git vim
    elif command -v dnf &>/dev/null; then
        dnf install -y curl wget openssl git vim
    fi
    ok "基础工具已安装 (curl/wget/openssl/git/vim)"
fi

# ============================================================
# 4. 开启 BBR
# ============================================================
if [[ "$ENABLE_BBR" == "y" ]]; then
    echo ""
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
# 5. 设置时区
# ============================================================
if [[ "$SET_TZ" == "y" ]]; then
    echo ""
    info "设置时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    ok "时区已设置为 Asia/Shanghai（之前: ${CURRENT_TZ}）"
fi

# ============================================================
# 6. SWAP
# ============================================================
if [[ "$SETUP_SWAP" == "y" ]]; then
    echo ""
    # 检查是否已有 SWAP
    if swapon --show 2>/dev/null | grep -q .; then
        SWAP_EXIST=$(swapon --show | awk 'NR==2{print $3}')
        ok "SWAP 已存在: ${SWAP_EXIST}"
    else
        # 按内存大小决定 SWAP 容量
        if [[ $TOTAL_MEM -le 512 ]]; then
            SWAP_SIZE=1024
        elif [[ $TOTAL_MEM -le 1024 ]]; then
            SWAP_SIZE=1024
        elif [[ $TOTAL_MEM -le 2048 ]]; then
            SWAP_SIZE=2048
        else
            SWAP_SIZE=2048
        fi
        info "内存 ${TOTAL_MEM}MB，添加 ${SWAP_SIZE}MB SWAP..."
        dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        ok "SWAP 已添加（${SWAP_SIZE}MB）"
    fi
fi

# ============================================================
# 7. 修改主机名
# ============================================================
if [[ "$SET_HOSTNAME" == "y" ]] && [[ -n "$NEW_HOSTNAME" ]]; then
    echo ""
    info "修改主机名为 ${NEW_HOSTNAME} ..."
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || hostname "$NEW_HOSTNAME"
    # 写入 /etc/hosts（防止 sudo 警告）
    sed -i "/127.0.1.1/d" /etc/hosts 2>/dev/null || true
    echo "127.0.1.1   ${NEW_HOSTNAME}" >> /etc/hosts
    ok "主机名已修改为 ${NEW_HOSTNAME}"
fi

# ============================================================
# 8. 修改 SSH 端口
# ============================================================
if [[ "$CHANGE_SSH_PORT" == "y" ]] && [[ -n "$SSH_PORT" ]]; then
    if [[ "$SSH_PORT" -ge 22 ]] && [[ "$SSH_PORT" -le 65535 ]]; then
        echo ""
        info "修改 SSH 端口为 ${SSH_PORT} ..."
        sed -i "s/^#\?Port [0-9]*/Port ${SSH_PORT}/" /etc/ssh/sshd_config 2>/dev/null || \
            echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
        ok "SSH 端口已修改为 ${SSH_PORT}（重启服务后生效）"

        # 防火墙放行新端口
        if command -v ufw &>/dev/null; then
            ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
            info "UFW 已放行端口 ${SSH_PORT}"
        fi
        if command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            info "firewalld 已放行端口 ${SSH_PORT}"
        fi
    else
        warn "端口号无效（22-65535），跳过 SSH 端口修改"
    fi
fi

# ============================================================
# 9. 防火墙基础配置
# ============================================================
echo ""
info "检查防火墙..."
if command -v ufw &>/dev/null; then
    if ! ufw status | grep -q "active"; then
        if [[ "$CHANGE_SSH_PORT" == "y" ]] && [[ -n "$SSH_PORT" ]]; then
            info "UFW 已放行 SSH 端口 ${SSH_PORT}"
        else
            ufw allow 22/tcp >/dev/null 2>&1
        fi
        read -p "是否启用 UFW 防火墙? (y/n, 默认 n): " ENABLE_UFW
        ENABLE_UFW=${ENABLE_UFW:-n}
        if [[ "$ENABLE_UFW" == "y" ]]; then
            ufw --force enable >/dev/null 2>&1
            ok "UFW 已启用"
        fi
    else
        ok "UFW 防火墙已在运行"
    fi
fi

# ============================================================
# 10. 输出摘要
# ============================================================
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ip.sb 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null)

echo ""
echo "============================================================"
highlight "✅ 系统初始化完成！"
echo "============================================================"
echo ""

highlight "📋 系统信息"
echo "  云厂商:          ${CLOUD_NAME}"
echo "  操作系统:        ${OS} ${OS_VERSION}"
echo "  公网 IP:         ${SERVER_IP:-获取失败}"
echo "  内存:            ${TOTAL_MEM}MB"
echo "  磁盘:            ${TOTAL_DISK}GB"
echo "  时区:            $(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "N/A")"
echo ""

highlight "🔧 已执行的操作"
if [[ -n "$APT_SOURCES_MIRROR" ]]; then
    echo "  ✓ APT 源 → ${APT_SOURCES_MIRROR}"
fi
if [[ "$DO_UPDATE" == "y" ]]; then
    echo "  ✓ 系统软件包已更新"
fi
if [[ "$INSTALL_TOOLS" == "y" ]]; then
    echo "  ✓ 基础工具已安装"
fi
if [[ "$ENABLE_BBR" == "y" ]]; then
    echo "  ✓ BBR $(lsmod 2>/dev/null | grep -q bbr && echo '已开启' || echo '已配置（重启生效）')"
fi
if [[ "$SET_TZ" == "y" ]]; then
    echo "  ✓ 时区已设置"
fi
if [[ "$SETUP_SWAP" == "y" ]]; then
    echo "  ✓ SWAP 已配置"
fi
if [[ "$SET_HOSTNAME" == "y" ]] && [[ -n "$NEW_HOSTNAME" ]]; then
    echo "  ✓ 主机名 → ${NEW_HOSTNAME}"
fi
if [[ "$CHANGE_SSH_PORT" == "y" ]] && [[ -n "$SSH_PORT" ]]; then
    echo "  ✓ SSH 端口 → ${SSH_PORT}（需重启服务生效）"
fi
if [[ "$ENABLE_UFW" == "y" ]]; then
    echo "  ✓ UFW 防火墙已启用"
fi
echo ""

if [[ "$CHANGE_SSH_PORT" == "y" ]] && [[ -n "$SSH_PORT" ]]; then
    warn "📌 SSH 端口已修改为 ${SSH_PORT}，建议保持当前会话不退出"
    warn "   另开一个终端验证能正常登录后，再关闭当前会话"
    echo ""
fi

highlight "📌 后续步骤"
echo "  ② Docker 环境 → 运行 install-docker.sh"
echo "  ③ 代理搭建   → 根据需求选择代理脚本"
echo "  ④ 开发环境   → code-server 部署"
echo ""

info "🎉 初始化完成！建议重启服务器使所有配置生效:"
echo "  sudo reboot"
echo ""
