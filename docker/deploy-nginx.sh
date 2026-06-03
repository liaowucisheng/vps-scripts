#!/bin/bash
set -e
set -o pipefail

# ============================================================
# Docker Nginx 一键部署脚本
# 适用场景: 回落站点 / 静态网站 / 反向代理
# 前置条件: 已安装 Docker（可用 install-docker.sh）
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
# 前置检查: Docker 是否已安装
# ============================================================
if ! command -v docker &>/dev/null; then
    err "Docker 未安装！请先运行 install-docker.sh 安装 Docker。"
    exit 1
fi

ok "Docker 已安装: $(docker --version)"

# 检查 Docker 服务是否在运行
if ! docker info &>/dev/null; then
    err "Docker 服务未运行！请先启动 Docker: systemctl start docker"
    exit 1
fi

# ============================================================
# 交互输入
# ============================================================
echo "============================================"
echo " Docker Nginx 一键部署脚本"
echo " 前置条件: 已安装 Docker"
echo "============================================"
echo ""

read -p "请输入容器名称 (默认 nginx): " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-nginx}

# 检查容器名是否已被占用
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
read -p "请输入映射端口 (宿主机:容器, 默认 80:80): " PORT_MAP
PORT_MAP=${PORT_MAP:-80:80}

echo ""
read -p "Nginx 版本 (默认 nginx:alpine, 也可指定如 nginx:1.26-alpine): " NGINX_IMAGE
NGINX_IMAGE=${NGINX_IMAGE:-nginx:alpine}

echo ""
read -p "网站根目录路径 (留空则不挂载自定义目录): " SITE_DIR

# 如果要挂载目录，询问是否创建示例页面
CREATE_INDEX="n"
if [[ -n "$SITE_DIR" ]]; then
    echo ""
    if [[ ! -d "$SITE_DIR" ]]; then
        read -p "目录不存在，是否创建? (y/n, 默认 y): " CREATE_DIR
        CREATE_DIR=${CREATE_DIR:-y}
        if [[ "$CREATE_DIR" == "y" ]]; then
            mkdir -p "$SITE_DIR"
            ok "已创建目录: $SITE_DIR"
        fi
    fi
    read -p "是否生成示例 index.html? (y/n, 默认 y): " CREATE_INDEX
    CREATE_INDEX=${CREATE_INDEX:-y}
fi

# 是否挂载 nginx 配置文件
echo ""
read -p "是否挂载自定义 nginx.conf? (y/n, 默认 n): " USE_CUSTOM_CONF
USE_CUSTOM_CONF=${USE_CUSTOM_CONF:-n}

CUSTOM_CONF_PATH=""
if [[ "$USE_CUSTOM_CONF" == "y" ]]; then
    read -p "请输入 nginx.conf 文件路径: " CUSTOM_CONF_PATH
    if [[ ! -f "$CUSTOM_CONF_PATH" ]]; then
        err "文件不存在: $CUSTOM_CONF_PATH"
        exit 1
    fi
fi

# 额外端口
echo ""
read -p "是否需要额外映射端口? (如 443:443, 多个用空格分隔, 直接回车跳过): " EXTRA_PORTS

# ============================================================
# 部署 Nginx 容器
# ============================================================
echo ""
info "拉取镜像 ${NGINX_IMAGE}..."

# 带重试的拉取
PULL_OK=0
for i in 1 2 3; do
    if docker pull "$NGINX_IMAGE" >/dev/null 2>&1; then
        PULL_OK=1
        break
    fi
    if [[ $i -lt 3 ]]; then
        warn "拉取失败，${i}s 后重试... ($i/3)"
        sleep 2
    fi
done

if [[ $PULL_OK -eq 0 ]]; then
    err "拉取镜像失败！请检查网络或镜像名称: $NGINX_IMAGE"
    exit 1
fi
ok "镜像拉取成功"

# ============================================================
# 生成示例 index.html
# ============================================================
if [[ "$CREATE_INDEX" == "y" ]] && [[ -n "$SITE_DIR" ]]; then
    # 确保目录存在（用户可能之前选择不创建，但这里需要写入）
    mkdir -p "$SITE_DIR"
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ip.sb 2>/dev/null || echo "your-server-ip")
    cat > "$SITE_DIR/index.html" <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #fff;
        }
        .card {
            text-align: center; padding: 60px;
            background: rgba(255,255,255,0.1); border-radius: 20px;
            backdrop-filter: blur(10px); box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        h1 { font-size: 3em; margin-bottom: 20px; }
        p { font-size: 1.2em; opacity: 0.9; }
        .info { margin-top: 30px; font-size: 0.9em; opacity: 0.7; }
    </style>
</head>
<body>
    <div class="card">
        <h1>🚀 运行中</h1>
        <p>Nginx Docker 容器已成功部署</p>
        <p class="info">$(date +"%Y-%m-%d %H:%M:%S") · ${SERVER_IP}</p>
    </div>
</body>
</html>
EOF
    ok "已生成示例页面: $SITE_DIR/index.html"
fi

# ============================================================
# 启动 Nginx 容器
# ============================================================
info "启动 Nginx 容器..."

DOCKER_ARGS=(
    -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    -p "$PORT_MAP"
)

if [[ -n "$SITE_DIR" ]]; then
    DOCKER_ARGS+=(-v "${SITE_DIR}:/usr/share/nginx/html:ro")
fi

if [[ -n "$CUSTOM_CONF_PATH" ]]; then
    DOCKER_ARGS+=(-v "${CUSTOM_CONF_PATH}:/etc/nginx/nginx.conf:ro")
fi

if [[ -n "$EXTRA_PORTS" ]]; then
    for p in $EXTRA_PORTS; do
        DOCKER_ARGS+=(-p "$p")
    done
fi

DOCKER_ARGS+=("$NGINX_IMAGE")

# 分离 stdout/stderr，避免 Docker warning 污染容器 ID
CONTAINER_ID=$(docker run "${DOCKER_ARGS[@]}" 2>/dev/null) || true

if [[ -z "$CONTAINER_ID" ]]; then
    err "容器启动失败！"
    warn "查看容器日志排查原因:"
    echo "  docker logs $CONTAINER_NAME"
    warn "或直接运行镜像查看启动输出:"
    echo "  docker run --rm $NGINX_IMAGE"
    exit 1
fi

ok "Nginx 容器已启动"

# 等待容器就绪
sleep 2

# 验证容器运行状态
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    ok "容器运行中"
else
    warn "容器可能未正常运行，查看日志: docker logs $CONTAINER_NAME"
fi

# ============================================================
# 输出信息
# ============================================================
HOST_PORT=$(echo "$PORT_MAP" | cut -d: -f1)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ip.sb 2>/dev/null || echo "your-server-ip")

echo ""
echo "============================================================"
highlight "✅ Nginx Docker 部署完成！"
echo "============================================================"
echo ""

highlight "📋 部署信息"
echo "  容器名称:       $CONTAINER_NAME"
echo "  镜像:           $NGINX_IMAGE"
echo "  端口映射:       $PORT_MAP"
if [[ -n "$EXTRA_PORTS" ]]; then
    echo "  额外端口:       $EXTRA_PORTS"
fi
if [[ -n "$SITE_DIR" ]]; then
    echo "  网站目录:       $SITE_DIR → /usr/share/nginx/html"
fi
if [[ -n "$CUSTOM_CONF_PATH" ]]; then
    echo "  配置文件:       $CUSTOM_CONF_PATH → /etc/nginx/nginx.conf"
fi
echo ""
highlight "🌐 访问地址"
echo "  http://${SERVER_IP}:${HOST_PORT}"
echo "  http://localhost:${HOST_PORT}  (服务器本地)"
echo ""

highlight "🛠 常用管理命令"
echo "  查看状态:       docker ps -a --filter name=$CONTAINER_NAME"
echo "  查看日志:       docker logs $CONTAINER_NAME"
echo "  实时日志:       docker logs -f $CONTAINER_NAME"
echo "  重启:           docker restart $CONTAINER_NAME"
echo "  停止:           docker stop $CONTAINER_NAME"
echo "  启动:           docker start $CONTAINER_NAME"
echo "  删除:           docker rm -f $CONTAINER_NAME"
echo "  进入容器:       docker exec -it $CONTAINER_NAME sh"
echo ""

highlight "📁 网站管理"
if [[ -n "$SITE_DIR" ]]; then
    echo "  上传文件到:     $SITE_DIR"
    echo "  修改后无需重启容器，Nginx 会自动加载新文件"
    echo ""
fi

highlight "📌 如果作为 Xray/Sing-box 回落站点"
echo "  脚本已默认生成回落页面，稍后修改 Xray/Sing-box 配置："
echo "  将回落域名指向本服务器 IP，回落流量会显示你的站点页面"
echo ""

warn "📌 云服务器安全组记得放行端口 ${HOST_PORT}"
warn "📌 如需绑定域名，配置 DNS 解析后将域名指向本服务器 IP"
echo ""

info "🎉 部署完成！访问 http://${SERVER_IP}:${HOST_PORT} 查看效果"
