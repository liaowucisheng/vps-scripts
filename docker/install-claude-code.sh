#!/bin/bash
set -e
set -o pipefail

# ============================================================
# Claude Code + DeepSeek 一键安装脚本 (code-server 容器内)
# 功能: 在已运行的 code-server 容器中安装 Claude Code CLI
#       并配置 DeepSeek Anthropic 兼容 API
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
echo " Claude Code + DeepSeek 一键安装"
echo " 环境: code-server Docker 容器"
echo "============================================"
echo ""

# 自动检测正在运行的 code-server 容器
AUTO_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i code-server | head -1)
DEFAULT_CONTAINER="${AUTO_CONTAINER:-code-server}"

read -p "请输入 code-server 容器名称 (默认 ${DEFAULT_CONTAINER}): " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-$DEFAULT_CONTAINER}

# 检查容器是否存在
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    # 检查是否存在于停止的容器中
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        err "容器 \"$CONTAINER_NAME\" 存在但未运行！请先启动:"
        echo "  docker start $CONTAINER_NAME"
        exit 1
    fi
    err "容器 \"$CONTAINER_NAME\" 不存在！"
    err "请先运行 code-server 部署脚本。"
    exit 1
fi
ok "检测到容器: ${CONTAINER_NAME} (运行中)"

echo ""
echo "可在 https://platform.deepseek.com/api_keys 获取"
read -r -p "请输入 DeepSeek API Key (sk-...): " DEEPSEEK_KEY
if [[ -z "$DEEPSEEK_KEY" ]]; then
    err "API Key 不能为空！"
    exit 1
fi

echo ""
read -p "指定默认模型 (deepseek-v4-pro / deepseek-v4-flash, 默认 deepseek-v4-pro): " DEFAULT_MODEL
DEFAULT_MODEL=${DEFAULT_MODEL:-deepseek-v4-pro}

echo ""
info "即将执行以下操作:"
echo "  1. 在容器内安装 Node.js（如未安装）"
echo "  2. 通过 npm 安装 @anthropic-ai/claude-code"
echo "  3. 配置 DeepSeek Anthropic 兼容 API 端点"
echo "  4. 验证安装结果"
echo ""

read -p "是否继续? (y/n, 默认 y): " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ "$CONFIRM" != "y" ]]; then
    err "已取消"
    exit 1
fi

# ============================================================
# 1. 安装 Node.js（容器内）
# ============================================================
echo ""
info "检查容器内 Node.js 环境..."

# 检查 node 是否已安装
if docker exec "$CONTAINER_NAME" sh -c "command -v node && node -v" 2>/dev/null; then
    NODE_VERSION=$(docker exec "$CONTAINER_NAME" node -v 2>/dev/null)
    ok "Node.js 已安装: ${NODE_VERSION}"
else
    info "容器内未检测到 Node.js，开始安装..."
    warn "安装过程需要 root 权限，安装后会自动清理"

    # 用 && 连接确保每一步成功，避免装到一半出错
    docker exec -u root "$CONTAINER_NAME" sh -c "
        apt update -y >/dev/null 2>&1 &&
        apt install -y ca-certificates curl gnupg >/dev/null 2>&1 &&
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 &&
        apt install -y nodejs >/dev/null 2>&1
    " || {
        err "Node.js 安装失败！"
        err "请手动进入容器安装: docker exec -u root -it $CONTAINER_NAME bash"
        exit 1
    }

    if docker exec "$CONTAINER_NAME" sh -c "command -v node && node -v" 2>/dev/null; then
        NODE_VERSION=$(docker exec "$CONTAINER_NAME" node -v 2>/dev/null)
        ok "Node.js 安装成功: ${NODE_VERSION}"
    else
        err "Node.js 安装后验证失败！"
        exit 1
    fi
fi

# ============================================================
# 2. 安装 Claude Code CLI
# ============================================================
echo ""
info "安装 Claude Code CLI..."

docker exec -u root "$CONTAINER_NAME" npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || {
    err "Claude Code CLI 安装失败！"
    err "请手动执行: docker exec -u root $CONTAINER_NAME npm install -g @anthropic-ai/claude-code"
    exit 1
}

if docker exec "$CONTAINER_NAME" sh -c "command -v claude && claude --version" 2>/dev/null; then
    CLAUDE_VERSION=$(docker exec "$CONTAINER_NAME" claude --version 2>/dev/null)
    ok "Claude Code CLI 安装成功: ${CLAUDE_VERSION}"
else
    err "Claude Code CLI 安装后验证失败！"
    exit 1
fi

# 确认 coder 用户能访问 claude
if docker exec -u coder "$CONTAINER_NAME" sh -c "command -v claude" 2>/dev/null; then
    ok "coder 用户可正常调用 claude 命令"
else
    warn "coder 用户无法直接调用 claude 命令（PATH 问题），创建符号链接..."
    # 查找全局安装路径
    NODE_PREFIX=$(docker exec -u root "$CONTAINER_NAME" npm prefix -g 2>/dev/null)
    if [[ -n "$NODE_PREFIX" ]]; then
        docker exec -u root "$CONTAINER_NAME" ln -sf "${NODE_PREFIX}/bin/claude" /usr/local/bin/claude 2>/dev/null || true
        if docker exec -u coder "$CONTAINER_NAME" sh -c "command -v claude" 2>/dev/null; then
            ok "符号链接创建成功"
        fi
    fi
fi

# ============================================================
# 3. 配置 DeepSeek API（写入 coder 用户的 settings.json）
# ============================================================
echo ""
info "配置 DeepSeek Anthropic 兼容 API..."

docker exec -u coder "$CONTAINER_NAME" mkdir -p /home/coder/.claude 2>/dev/null || true

docker exec -u coder "$CONTAINER_NAME" sh -c "cat > /home/coder/.claude/settings.json << 'EOFCONFIG'
{
  \"env\": {
    \"ANTHROPIC_BASE_URL\": \"https://api.deepseek.com/anthropic\",
    \"ANTHROPIC_AUTH_TOKEN\": \"${DEEPSEEK_KEY}\",
    \"ANTHROPIC_MODEL\": \"${DEFAULT_MODEL}\",
    \"ANTHROPIC_DEFAULT_OPUS_MODEL\": \"${DEFAULT_MODEL}\",
    \"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"${DEFAULT_MODEL}\",
    \"ANTHROPIC_DEFAULT_HAIKU_MODEL\": \"deepseek-v4-flash\",
    \"CLAUDE_CODE_EFFORT_LEVEL\": \"max\"
  }
}
EOFCONFIG
" 2>/dev/null

# 验证配置文件
if docker exec -u coder "$CONTAINER_NAME" test -f /home/coder/.claude/settings.json 2>/dev/null; then
    ok "DeepSeek 配置已写入 /home/coder/.claude/settings.json"
else
    warn "配置文件写入失败，请手动检查"
fi

# 同时写入 .bashrc 作为备用（支持直接 docker exec -it 使用）
docker exec -u root "$CONTAINER_NAME" sh -c "
    grep -q 'ANTHROPIC_BASE_URL' /home/coder/.bashrc 2>/dev/null || {
        echo >> /home/coder/.bashrc
        echo '# Claude Code + DeepSeek 配置' >> /home/coder/.bashrc
        echo 'export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' >> /home/coder/.bashrc
        echo 'export ANTHROPIC_AUTH_TOKEN=${DEEPSEEK_KEY}' >> /home/coder/.bashrc
        echo 'export ANTHROPIC_MODEL=${DEFAULT_MODEL}' >> /home/coder/.bashrc
    }
" 2>/dev/null && ok "环境变量已写入 .bashrc（备用）"

# ============================================================
# 4. 输出信息
# ============================================================
echo ""
echo "============================================================"
highlight "✅ Claude Code + DeepSeek 安装完成！"
echo "============================================================"
echo ""

highlight "📋 安装信息"
echo "  容器:               ${CONTAINER_NAME}"
if [[ -n "$NODE_VERSION" ]]; then
    echo "  Node.js:            ${NODE_VERSION}"
fi
if [[ -n "$CLAUDE_VERSION" ]]; then
    echo "  Claude Code:        ${CLAUDE_VERSION}"
fi
echo "  API 端点:           https://api.deepseek.com/anthropic"
echo "  默认模型:           ${DEFAULT_MODEL}"
echo "  Haiku/Fast 模型:    deepseek-v4-flash"
echo "  配置目录:           /home/coder/.claude/settings.json"
echo ""

highlight "🚀 使用方法"
echo ""
echo "方法一 - 在 code-server 终端中直接运行:"
echo "  claude"
echo ""
echo "方法二 - 从宿主机进入容器运行:"
echo "  docker exec -it -u coder ${CONTAINER_NAME} claude"
echo ""

highlight "🛠 常用命令"
echo "  更新 Claude Code:   docker exec -u root ${CONTAINER_NAME} npm update -g @anthropic-ai/claude-code"
echo "  修改配置:           docker exec -it -u coder ${CONTAINER_NAME} vi /home/coder/.claude/settings.json"
echo "  切换模型:           在 claude 对话中输入 /model"
echo "  查看版本:           docker exec ${CONTAINER_NAME} claude --version"
echo ""

highlight "🤖 DeepSeek 模型选择"
echo "  deepseek-v4-pro     全能主力模型（默认）"
echo "  deepseek-v4-flash   轻量快速模型"
echo "  在 claude 内可用 /model 命令切换"
echo ""

highlight "📌 注意事项"
echo "  1. DeepSeek Anthropic API 不支持图片输入和 MCP Server"
echo "  2. 如需切回官方 Claude API，删掉 settings.json 中 ANTHROPIC_BASE_URL 即可"
echo "  3. API Key 可在 https://platform.deepseek.com/api_keys 管理"
echo ""

# ============================================================
# 5. 最终验证
# ============================================================
echo ""
info "最终验证..."

docker exec -u coder "$CONTAINER_NAME" sh -c "
    echo -n '  Node.js:      '
    node -v 2>/dev/null || echo '不可用'
    echo -n '  claude:       '
    claude --version 2>/dev/null || echo '不可用'
    echo -n '  API 端点:     '
    echo \$ANTHROPIC_BASE_URL 2>/dev/null || echo '(未设置)'
    echo -n '  配置文件:     '
    test -f /home/coder/.claude/settings.json && echo '存在' || echo '不存在'
"

echo ""
info "🎉 安装完成！进入容器运行 claude 开始使用:"
echo "  docker exec -it -u coder ${CONTAINER_NAME} claude"
echo ""
