#!/bin/bash
set -e

#============================================================
# 一键部署 code-server（支持 HTTPS + Continue + Claude Code）
# 兼容：Ubuntu 20.04+/Debian 10+/CentOS 7+
# 特点：
#   - 自动检测云厂商与架构
#   - 可选 BBR、SWAP、防火墙
#   - 自定义 HTTP 端口 或 自动 HTTPS（Caddy+Let's Encrypt）
#   - 内置 Continue + DeepSeek/Claude 双模型配置
#   - 可选安装 Claude Code CLI
#   - 配置、项目、Continue 数据完全持久化
#============================================================

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

#--------------------- 云厂商检测 ---------------------#
detect_cloud_provider() {
    local vendor="" product=""
    [ -f /sys/class/dmi/id/sys_vendor ]   && vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)   || true
    [ -f /sys/class/dmi/id/product_name ] && product=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || true

    if echo "$vendor" | grep -qi "Alibaba" || echo "$product" | grep -qi "Alibaba"; then echo "aliyun"; return; fi
    if echo "$vendor" | grep -qi "Tencent" || echo "$product" | grep -qi "Tencent"; then echo "tencent"; return; fi
    if echo "$vendor" | grep -qi "Huawei"   || echo "$product" | grep -qi "Huawei" ||
       echo "$vendor" | grep -qi "HiSilicon" ; then echo "huawei"; return; fi
    if echo "$vendor" | grep -qi "Amazon EC2" || echo "$product" | grep -qi "Amazon EC2"; then echo "aws"; return; fi
    if echo "$vendor" | grep -qi "Microsoft" || echo "$product" | grep -qi "Microsoft"; then echo "azure"; return; fi
    if echo "$vendor" | grep -qi "Google" || echo "$product" | grep -qi "Google Compute Engine"; then echo "gcp"; return; fi
    if curl -s --max-time 1 http://100.100.100.200/latest/meta-data/ 2>/dev/null | grep -q .; then echo "aliyun"; return; fi
    if curl -s --max-time 1 http://metadata.tencentyun.com/latest/meta-data/ 2>/dev/null | grep -q .; then echo "tencent"; return; fi
    echo "unknown"
}
cloud_name() {
    case "$1" in aliyun)  echo "阿里云" ;; tencent) echo "腾讯云" ;; huawei)  echo "华为云" ;;
             aws)     echo "AWS" ;; azure)   echo "Azure" ;; gcp)     echo "Google Cloud" ;; *) echo "未知" ;; esac
}
is_china_cloud() { case "$1" in aliyun|tencent|huawei) return 0 ;; *) return 1 ;; esac }

CLOUD_PROVIDER=$(detect_cloud_provider)
CLOUD_NAME=$(cloud_name "$CLOUD_PROVIDER")

#--------------------- 架构检测 ---------------------#
detect_arch() {
    case "$(uname -m)" in x86_64)  echo "amd64" ;; aarch64) echo "arm64" ;; *) echo "$(uname -m)" ;; esac
}
ARCH=$(detect_arch)

#--------------------- 权限处理 ---------------------#
if [ "$EUID" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# 检查普通用户是否在 docker 组中
if ! groups | grep -q docker && [ "$EUID" -ne 0 ]; then
    warn "当前用户不在 docker 组，脚本可能因权限失败。"
    warn "建议运行: sudo usermod -aG docker $USER 并重新登录后再运行脚本。"
    read -p "是否继续使用 sudo 运行 Docker 命令？(y/n, 默认 y): " CONTINUE_SUDO
    CONTINUE_SUDO=${CONTINUE_SUDO:-y}
    if [[ "$CONTINUE_SUDO" != "y" ]]; then
        exit 0
    fi
fi

#--------------------- 1. 依赖安装 ---------------------#
install_deps() {
    info "安装必要依赖 (curl, python3)..."
    if ! command -v curl &>/dev/null || ! command -v python3 &>/dev/null; then
        if command -v apt &>/dev/null; then
            $SUDO apt update -qq && $SUDO apt install -y curl python3
        elif command -v yum &>/dev/null; then
            $SUDO yum install -y curl python3 || $SUDO dnf install -y curl python3
        elif command -v dnf &>/dev/null; then
            $SUDO dnf install -y curl python3
        else
            err "不支持的包管理器"; exit 1
        fi
        ok "依赖安装完成"
    fi
}

install_docker_if_needed() {
    if ! command -v docker &>/dev/null; then
        info "安装 Docker..."
        curl -fsSL https://get.docker.com | $SUDO sh
        ok "Docker 已安装"
    fi
    if ! $SUDO docker info &>/dev/null; then
        $SUDO systemctl start docker &>/dev/null || true
        sleep 2
    fi
    if ! command -v docker compose &>/dev/null && ! $SUDO docker compose version &>/dev/null; then
        info "安装 Docker Compose 插件..."
        if command -v apt &>/dev/null; then
            $SUDO apt install -y docker-compose-plugin
        else
            $SUDO yum install -y docker-compose-plugin || $SUDO dnf install -y docker-compose-plugin
        fi
        ok "Docker Compose 已安装"
    fi
    ok "Docker 环境就绪"
}

#--------------------- 2. 内存优化 ---------------------#
setup_swap_if_needed() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $TOTAL_MEM -lt 1024 ]]; then
        warn "系统内存仅 ${TOTAL_MEM}MB，code-server 建议 ≥1GB"
        read -p "是否添加 1GB SWAP? (y/n, 默认 y): " SETUP_SWAP
        SETUP_SWAP=${SETUP_SWAP:-y}
        if [[ "$SETUP_SWAP" == "y" ]]; then
            if ! swapon --show | grep -q .; then
                $SUDO dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
                $SUDO chmod 600 /swapfile
                $SUDO mkswap /swapfile >/dev/null
                $SUDO swapon /swapfile
                grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null
                ok "SWAP 已添加"
            fi
        fi
    fi
}

#--------------------- 3. BBR ---------------------#
enable_bbr_if_agreed() {
    read -p "是否开启 BBR 拥塞控制? (y/n, 默认 y): " ENABLE_BBR
    ENABLE_BBR=${ENABLE_BBR:-y}
    if [[ "$ENABLE_BBR" == "y" ]]; then
        $SUDO modprobe tcp_bbr 2>/dev/null || true
        $SUDO mkdir -p /etc/modules-load.d
        if ! grep -q "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
            echo "tcp_bbr" | $SUDO tee -a /etc/modules-load.d/modules.conf >/dev/null
        fi
        # 写入 sysctl 配置（避免重复）
        if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
            echo "net.core.default_qdisc=fq" | $SUDO tee -a /etc/sysctl.conf >/dev/null
        fi
        if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
            echo "net.ipv4.tcp_congestion_control=bbr" | $SUDO tee -a /etc/sysctl.conf >/dev/null
        fi
        $SUDO sysctl -p >/dev/null 2>&1 || true
        if lsmod | grep -q bbr; then ok "BBR 已启用"; else warn "BBR 将在重启后生效"; fi
    fi
}

#--------------------- 4. 用户配置 ---------------------#
collect_config() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  code-server 一键部署（支持 HTTPS）${NC}"
    echo -e "${BLUE}  架构: ${ARCH}  云厂商: ${CLOUD_NAME}${NC}"
    echo -e "${BLUE}========================================${NC}"

    # 容器名
    read -p "容器名称 (默认 code-server): " CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-code-server}

    # HTTPS 选择
    read -p "是否启用自动 HTTPS? (需要域名，Yes 将使用 Caddy) [y/N]: " USE_HTTPS
    USE_HTTPS=$(echo "$USE_HTTPS" | tr '[:upper:]' '[:lower:]')
    if [[ "$USE_HTTPS" == "y" ]]; then
        USE_HTTPS=true
        read -p "请输入域名 (如 code.example.com): " DOMAIN
        HOST_PORT=""
    else
        USE_HTTPS=false
        read -p "HTTP 端口 (默认 8443): " HOST_PORT
        HOST_PORT=${HOST_PORT:-8443}
    fi

    # 密码（提示避免使用特殊字符 |，为生成 compose 安全）
    echo "注意：密码中请不要包含竖线字符 '|'"
    read -sp "设置访问密码 (留空随机生成): " PASSWORD
    echo
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)
        GEN_PASSWORD=1
    fi
    # 检查是否包含竖线，若包含提示重新输入
    while [[ "$PASSWORD" == *"|"* ]]; do
        warn "密码包含竖线 '|'，可能引起配置错误，请重新设置"
        read -sp "设置访问密码 (不含|): " PASSWORD
        echo
        if [[ -z "$PASSWORD" ]]; then
            PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)
            GEN_PASSWORD=1
        fi
    done

    # 项目目录
    read -p "项目存放目录 (默认 $HOME/code): " PROJECT_DIR
    PROJECT_DIR=${PROJECT_DIR:-$HOME/code}

    # 时区
    read -p "时区 (默认 Asia/Shanghai): " TZ
    TZ=${TZ:-Asia/Shanghai}

    # Continue
    read -p "是否安装 Continue AI 编程助手? [y/N]: " INSTALL_CONTINUE
    INSTALL_CONTINUE=$(echo "$INSTALL_CONTINUE" | tr '[:upper:]' '[:lower:]')
    INSTALL_CONTINUE=${INSTALL_CONTINUE:-n}

    DEEPSEEK_KEY=""
    ANTHROPIC_KEY=""
    if [[ "$INSTALL_CONTINUE" == "y" ]]; then
        echo ""
        echo "可配置 AI 模型 API Key (支持 DeepSeek 和 Claude)"
        read -sp "DeepSeek API Key (留空跳过): " DEEPSEEK_KEY
        echo
        read -sp "Anthropic API Key (留空跳过): " ANTHROPIC_KEY
        echo
    fi

    # Claude Code CLI
    read -p "是否安装 Claude Code CLI? [y/N]: " INSTALL_CLAUDE_CLI
    INSTALL_CLAUDE_CLI=$(echo "$INSTALL_CLAUDE_CLI" | tr '[:upper:]' '[:lower:]')
    INSTALL_CLAUDE_CLI=${INSTALL_CLAUDE_CLI:-n}
}

#--------------------- 5. 容器冲突检查 ---------------------#
check_container_conflict() {
    if $SUDO docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        warn "容器 '${CONTAINER_NAME}' 已存在"
        read -p "删除旧容器并继续? (y/n, 默认 n): " RECREATE
        if [[ "$RECREATE" == "y" ]]; then
            $SUDO docker rm -f "${CONTAINER_NAME}" || true
            ok "旧容器已删除"
        else
            err "部署取消"; exit 1
        fi
    fi
}

#--------------------- 6. HTTPS 前置检查 ---------------------#
check_https_prereq() {
    if [ "$USE_HTTPS" = true ]; then
        if $SUDO ss -tlnp | grep -qE ':(80|443) '; then
            warn "80 或 443 端口可能被占用，请确认未运行其他 Web 服务"
        fi
        if ! host "$DOMAIN" &>/dev/null; then
            warn "域名 ${DOMAIN} 无法解析，HTTPS 证书自动申请可能失败"
        fi
    fi
}

#--------------------- 7. 目录准备 ---------------------#
prepare_dirs() {
    BASE_DIR="$HOME/code-server-deploy"
    CONFIG_DIR="$BASE_DIR/config"
    CONTINUE_DIR="$BASE_DIR/continue"
    CADDY_DIR="$BASE_DIR/caddy"
    DOCKER_COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    CADDYFILE="$BASE_DIR/Caddyfile"

    mkdir -p "$CONFIG_DIR" "$PROJECT_DIR" "$CONTINUE_DIR"
    if [ "$USE_HTTPS" = true ]; then mkdir -p "$CADDY_DIR"; fi
    # 官方镜像 coder 用户 UID/GID 为 1000
    $SUDO chown -R 1000:1000 "$CONFIG_DIR" "$PROJECT_DIR" "$CONTINUE_DIR"
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        warn "docker-compose.yml 已存在，将备份为 .bak"
        mv "$DOCKER_COMPOSE_FILE" "$DOCKER_COMPOSE_FILE.bak"
    fi
    ok "持久化目录创建完成"
}

#--------------------- 8. 生成配置 ---------------------#
generate_compose() {
    # 写入基础部分（禁用变量展开以保留占位符）
    cat > "$DOCKER_COMPOSE_FILE" <<'EOF'
version: '3.8'

services:
  code-server:
    image: codercom/code-server:latest
    container_name: __CONTAINER_NAME__
    restart: unless-stopped
    environment:
      - PASSWORD=__PASSWORD__
      - TZ=__TZ__
    volumes:
      - __CONFIG_DIR__:/home/coder/.config/code-server
      - __PROJECT_DIR__:/home/coder/project
      - __CONTINUE_DIR__:/home/coder/.continue
EOF

    # 替换占位符
    sed -i "s|__CONTAINER_NAME__|${CONTAINER_NAME}|g" "$DOCKER_COMPOSE_FILE"
    sed -i "s|__PASSWORD__|${PASSWORD}|g" "$DOCKER_COMPOSE_FILE"
    sed -i "s|__TZ__|${TZ}|g" "$DOCKER_COMPOSE_FILE"
    sed -i "s|__CONFIG_DIR__|${CONFIG_DIR}|g" "$DOCKER_COMPOSE_FILE"
    sed -i "s|__PROJECT_DIR__|${PROJECT_DIR}|g" "$DOCKER_COMPOSE_FILE"
    sed -i "s|__CONTINUE_DIR__|${CONTINUE_DIR}|g" "$DOCKER_COMPOSE_FILE"

    if [ "$USE_HTTPS" = true ]; then
        cat >> "$DOCKER_COMPOSE_FILE" <<'EOF'
    networks:
      - caddy_net

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - __CADDYFILE__:/etc/caddy/Caddyfile
      - __CADDY_DATA__:/data
      - __CADDY_CONFIG__:/config
    networks:
      - caddy_net

networks:
  caddy_net:
EOF
        sed -i "s|__CADDYFILE__|${CADDYFILE}|g" "$DOCKER_COMPOSE_FILE"
        sed -i "s|__CADDY_DATA__|${CADDY_DIR}/data|g" "$DOCKER_COMPOSE_FILE"
        sed -i "s|__CADDY_CONFIG__|${CADDY_DIR}/config|g" "$DOCKER_COMPOSE_FILE"
    else
        # HTTP 模式直接暴露端口
        cat >> "$DOCKER_COMPOSE_FILE" <<EOF
    ports:
      - "${HOST_PORT}:8080"
EOF
    fi
    ok "docker-compose.yml 已生成"
}

generate_caddyfile() {
    if [ "$USE_HTTPS" = true ]; then
        cat > "$CADDYFILE" <<EOF
${DOMAIN} {
    reverse_proxy code-server:8080
}
EOF
        ok "Caddyfile 已生成"
    fi
}

#--------------------- 9. 拉取镜像 & 启动 ---------------------#
pull_and_start() {
    cd "$BASE_DIR"
    info "拉取 code-server 镜像..."
    for i in 1 2 3; do
        if $SUDO docker compose pull code-server 2>/dev/null; then
            ok "镜像拉取成功"; break
        fi
        if [[ $i -lt 3 ]]; then warn "重试拉取 ($i/3)"; sleep 3; fi
    done

    info "启动服务..."
    $SUDO docker compose up -d
    sleep 3

    # 等待容器内 code-server 进程就绪
    info "等待 code-server 初始化..."
    for i in {1..15}; do
        if $SUDO docker exec "$CONTAINER_NAME" pgrep -f "code-server" &>/dev/null; then
            ok "code-server 进程已启动"
            break
        fi
        sleep 2
        if [[ $i -eq 15 ]]; then
            warn "code-server 进程可能尚未完全就绪，后续安装可能受影响"
        fi
    done
}

#--------------------- 10. 安装扩展与工具 ---------------------#
install_extensions() {
    if [[ "$INSTALL_CONTINUE" == "y" ]]; then
        info "安装 Continue 扩展..."
        $SUDO docker exec -u coder "$CONTAINER_NAME" code-server --install-extension Continue.continue --force || warn "Continue 安装失败"
    fi

    if [[ "$INSTALL_CLAUDE_CLI" == "y" ]]; then
        info "安装 Claude Code CLI..."
        $SUDO docker exec -u root "$CONTAINER_NAME" npm install -g @anthropic-ai/claude-code || warn "Claude Code CLI 安装失败"
    fi
}

#--------------------- 11. Continue 模型配置（python3） ---------------------#
configure_continue() {
    if [[ "$INSTALL_CONTINUE" != "y" ]]; then return; fi
    if [[ -z "$DEEPSEEK_KEY" && -z "$ANTHROPIC_KEY" ]]; then return; fi

    CONFIG_JSON="$CONTINUE_DIR/config.json"
    mkdir -p "$CONTINUE_DIR"

    $SUDO python3 << PYEOF
import json, os

config_path = "$CONFIG_JSON"
if os.path.exists(config_path):
    with open(config_path) as f:
        config = json.load(f)
else:
    config = {"models": [], "embeddingsProvider": {"provider": "transformers.js"}}

models = config.setdefault("models", [])

# 添加 DeepSeek（去重：若已存在同名模型则跳过）
if "$DEEPSEEK_KEY":
    existing = [m['title'] for m in models if 'title' in m]
    if "DeepSeek Chat" not in existing:
        models.append({"title":"DeepSeek Chat","provider":"openai","model":"deepseek-chat","apiKey":"$DEEPSEEK_KEY","apiBase":"https://api.deepseek.com/v1"})
    if "DeepSeek Coder" not in existing:
        models.append({"title":"DeepSeek Coder","provider":"openai","model":"deepseek-coder","apiKey":"$DEEPSEEK_KEY","apiBase":"https://api.deepseek.com/v1"})
    config["tabAutocompleteModel"] = {"title":"DeepSeek Coder","provider":"openai","model":"deepseek-coder","apiKey":"$DEEPSEEK_KEY","apiBase":"https://api.deepseek.com/v1"}

# 添加 Claude
if "$ANTHROPIC_KEY":
    existing = [m['title'] for m in models if 'title' in m]
    if "Claude 3.5 Sonnet" not in existing:
        models.append({"title":"Claude 3.5 Sonnet","provider":"anthropic","model":"claude-3-5-sonnet-latest","apiKey":"$ANTHROPIC_KEY"})

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
os.chown(config_path, 1000, 1000)
PYEOF
    ok "Continue 模型配置完成"
}

#--------------------- 12. 防火墙 ---------------------#
configure_firewall() {
    if [ "$USE_HTTPS" = true ]; then
        if command -v ufw &>/dev/null; then
            $SUDO ufw allow 80/tcp && $SUDO ufw allow 443/tcp
            info "已放行 80/443 (UFW)"
        fi
        if command -v firewall-cmd &>/dev/null; then
            $SUDO firewall-cmd --permanent --add-service=http --add-service=https
            $SUDO firewall-cmd --reload
            info "已放行 80/443 (firewalld)"
        fi
    else
        if command -v ufw &>/dev/null; then
            $SUDO ufw allow "${HOST_PORT}/tcp"
            info "已放行 ${HOST_PORT} (UFW)"
        fi
        if command -v firewall-cmd &>/dev/null; then
            $SUDO firewall-cmd --permanent --add-port="${HOST_PORT}/tcp"
            $SUDO firewall-cmd --reload
            info "已放行 ${HOST_PORT} (firewalld)"
        fi
    fi
}

#--------------------- 13. 输出信息 ---------------------#
show_result() {
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ip.sb 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    echo "============================================================"
    highlight "✅ code-server 部署完成！"
    echo "============================================================"
    if [ "$USE_HTTPS" = true ]; then
        echo -e "访问地址:  ${GREEN}https://${DOMAIN}${NC}"
    else
        echo -e "访问地址:  ${GREEN}http://${SERVER_IP}:${HOST_PORT}${NC}"
    fi
    echo -e "密码:      ${GREEN}${PASSWORD}${NC}"
    echo "项目目录:  ${PROJECT_DIR} → /home/coder/project"
    echo "配置目录:  ${CONFIG_DIR} → /home/coder/.config/code-server"
    if [[ "$INSTALL_CONTINUE" == "y" ]]; then
        echo "Continue:  已安装"
        [ -n "$DEEPSEEK_KEY" ] && echo "DeepSeek:  已配置 (Chat & Coder)"
        [ -n "$ANTHROPIC_KEY" ] && echo "Claude:    Claude 3.5 Sonnet"
    fi
    if [[ "$INSTALL_CLAUDE_CLI" == "y" ]]; then
        echo "Claude CLI: 已安装 (容器终端输入 claude)"
    fi
    echo ""
    highlight "常用管理命令:"
    echo "  查看日志:   docker logs ${CONTAINER_NAME}"
    echo "  重启:       docker compose -f ${DOCKER_COMPOSE_FILE} restart"
    echo "  升级:       docker compose -f ${DOCKER_COMPOSE_FILE} pull && docker compose -f ${DOCKER_COMPOSE_FILE} up -d"
    echo "  修改密码:   删除容器后使用新密码重建 (数据保存在持久化目录)"
    echo ""
    if [[ "$USE_HTTPS" = false ]]; then
        highlight "安全建议:"
        echo "  当前仅 HTTP，建议后续使用反向代理启用 HTTPS"
        echo "  可使用 SSH 隧道安全访问: ssh -L ${HOST_PORT}:localhost:${HOST_PORT} user@server"
    fi
    if [[ "$GEN_PASSWORD" -eq 1 ]]; then
        warn "密码已随机生成，请务必保存：${PASSWORD}"
    fi
    echo "============================================================"
}

#--------------------- 主流程 ---------------------#
main() {
    install_deps
    install_docker_if_needed
    setup_swap_if_needed
    enable_bbr_if_agreed
    collect_config
    check_container_conflict
    check_https_prereq
    prepare_dirs
    generate_compose
    generate_caddyfile
    pull_and_start
    install_extensions
    configure_continue
    configure_firewall
    show_result
}

main