# vps-scripts

> 云服务器一键配置脚本合集 — 新服务器到手，按步骤直接跑。

适用于 **Ubuntu 20.04+ / Debian 10+ / CentOS 7+**，轻量应用服务器（2 核 1G 等均可）。

[![GitHub](https://img.shields.io/badge/GitHub-liaowucisheng/vps--scripts-blue?style=flat-square)](https://github.com/liaowucisheng/vps-scripts)

---

## 📋 新服务器部署路线图

刚买的 VPS → SSH 登录 → 按以下顺序执行：

```
 ① 系统初始化  ─── 更新、BBR、基础依赖
 ② Docker 环境 ─── 容器引擎（所有服务的基础）
 ③ 代理搭建    ─── Xray / Sing-box（按需）
 ④ 开发环境    ─── code-server + AI（按需）
 ⑤ Web 服务    ─── Nginx（按需）
```

每步都是一个独立脚本，只做一件事，可自由跳过或组合。

---

<a name="step-1"></a>
## ① 系统初始化

初次上手的必备操作：换源加速 + 更新系统 + BBR + 基础工具 + 时区/SWAP/SSH 等。

| 脚本 | 功能 | 特点 |
|------|------|------|
| [init.sh](system/init.sh) | 系统一键初始化 | 换源、更新、BBR、SWAP、时区、主机名、SSH 端口、防火墙 |

### 一键运行

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/system/init.sh)"
```

### 脚本特点

- **云厂商自动感知** — 阿里云/腾讯云/华为云默认推荐换源并给出对应镜像源菜单
- **APT 换源** — 支持 5 种国内镜像源 + 自定义，备份原 sources.list
- **系统更新** — 一键 apt update && apt upgrade
- **基础工具** — 安装 curl/wget/openssl/git/vim
- **BBR 加速** — 可选开启 TCP BBR 拥塞控制
- **时区设置** — 默认 Asia/Shanghai
- **SWAP 配置** — 内存 < 2GB 时自动提示添加（按内存大小智能分配）
- **主机名修改** — 可选修改主机名并写入 /etc/hosts
- **SSH 端口修改** — 可选修改端口并自动放行防火墙
- **UFW 防火墙** — 可选启用并放行 SSH 端口

> 💡 后续的 **install-docker.sh** 和代理脚本也会自动启用 BBR，跳过本步不影响。

---

<a name="step-2"></a>
## ② Docker 环境

容器引擎是一切容器化服务的基础。**所有其他脚本都可以依赖 Docker 运行。**

| 脚本 | 功能 | 特点 |
|------|------|------|
| [install-docker.sh](docker/install-docker.sh) | 安装 Docker + Compose | 自动检测云厂商、镜像加速、日志限制、非 root 使用、自检验证 |

### 一键运行

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/install-docker.sh)"
```

### 脚本特点

- **云厂商自动感知** — 识别阿里云/腾讯云/华为云/AWS/Azure/GCP，智能推荐镜像加速
- **地域感知** — 阿里云海外地域默认直连 Docker Hub，国内地域推荐加速器
- **镜像加速菜单** — 支持阿里云专属加速器、Docker Proxy、中科大镜像
- **日志限制** — 单容器日志最大 10MB，保留 3 个文件，防止磁盘写满
- **非 root 使用** — 自动检测 sudo 用户并加入 `docker` 组
- **Docker Compose** — 同时安装 Compose 插件（`docker compose`）和独立命令（`docker-compose`）
- **BBR 加速** — 可选开启 TCP BBR 拥塞控制
- **自检验证** — 安装后自动 `docker run hello-world` 验证

> 💡 **存储建议：** 轻量服务器磁盘有限，定期 `docker image prune -a` 清理无用镜像。

---

<a name="step-3"></a>
## ③ 代理搭建

提供 **Xray-core** 和 **Sing-box** 两种内核，均使用 **VLESS + REALITY + Vision Flow** 协议。客户端通用（v2rayN / Clash Meta / Nekoray 均可导入）。

### 方式一：原生安装（裸机运行，性能最佳）

| 脚本 | 内核 | 协议 | 特点 |
|------|------|------|------|
| [install-xray-reality.sh](proxy/install-xray-reality.sh) | Xray-core | VLESS + REALITY + Vision | REALITY 协议发明者，成熟稳定 |
| [install-singbox-reality.sh](proxy/install-singbox-reality.sh) | Sing-box | VLESS + REALITY + Vision | 内核精简，自带 DNS over TLS，支持 TUN |

```bash
# Xray 版
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/proxy/install-xray-reality.sh)"

# Sing-box 版
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/proxy/install-singbox-reality.sh)"
```

### 方式二：Docker 容器运行（隔离管理，升级卸载更干净）

| 脚本 | 内核 | 特点 |
|------|------|------|
| [install-xray-reality.sh](docker/install-xray-reality.sh) | Xray-core (Docker) | `--network host` 性能无损耗 |
| [install-singbox-reality.sh](docker/install-singbox-reality.sh) | Sing-box (Docker) | 自带 DNS over TLS |

```bash
# Xray Docker 版
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/install-xray-reality.sh)"

# Sing-box Docker 版
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/install-singbox-reality.sh)"
```

### 原生 vs Docker 对比

| 对比项 | 原生安装 | Docker 版 |
|--------|----------|-----------|
| 安装方式 | 下载二进制 + systemd 服务 | 拉取镜像 + Docker 容器 |
| 卸载 | 删文件 + 删服务 | `docker rm -f` 一行搞定 |
| 升级 | 重跑安装脚本 | `docker pull` + 重启容器 |
| 性能 | 裸机 | `--network host` 与裸机一致 |
| 前置依赖 | 无 | 需先安装 Docker |

### 运行说明

每个脚本交互式运行，提示三个参数（直接回车使用默认值）：

```
请输入端口号 (默认 443):              ← 回车
请输入回落目标域名 (默认 www.microsoft.com):  ← 回车
是否开启 BBR? (y/n, 默认 y):         ← 回车
```

执行流程：安装依赖 → 开启 BBR → 拉取内核 → 生成密钥 → 写入配置 → 启动服务 → 配置防火墙

### 客户端配置

脚本运行完成会输出：

| 输出内容 | 用途 |
|----------|------|
| `vless://...` 分享链接 | v2rayN → 从剪贴板导入 |
| Clash Meta 配置段 | Clash Verge / OpenClash 使用 |
| 服务器参数（UUID/PublicKey/ShortId） | 手动配置或分享给朋友 |

> 💡 **速度优化：** v2rayN 中右键节点 → 属性 → MUX 多路复用 → 启用，并发数设为 `8`，可减少 TLS 握手次数，网页加载更快。

---

<a name="step-4"></a>
## ④ 开发环境

在浏览器中写代码，适合无桌面环境的服务器。**需先安装 Docker。**

提供两个版本：**Flash** 轻量够用，**Pro** 支持 Caddy 自动 HTTPS + Continue + Claude Code。

| 脚本 | 版本 | 功能 |
|------|------|------|
| [deploy-codeserver-flash.sh](docker/deploy-codeserver-flash.sh) | Flash | 基础部署，可选 Continue + DeepSeek |
| [deploy-codeserver-pro.sh](docker/deploy-codeserver-pro.sh) | Pro | Caddy HTTPS + Continue + DeepSeek/Claude 双模型 |

### Flash 版 — 轻量快速

适合个人使用，部署简单，资源占用少。

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/deploy-codeserver-flash.sh)"
```

**特点：** 云厂商感知、内存检测（< 1GB 建议加 SWAP）、容器冲突处理、密码自动生成、可选 Continue + DeepSeek（deepseek-chat / deepseek-coder）、防火墙自动放行。

### Pro 版 — 完整功能

适合需要域名 + HTTPS 的生产环境，内置 Caddy 自动申请 Let's Encrypt 证书。

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/deploy-codeserver-pro.sh)"
```

**特点：**
- **自动 HTTPS** — 绑定域名后 Caddy 自动申请 Let's Encrypt 证书，无需手动管理
- **双模式** — 支持 HTTP（仅端口）或 HTTPS（需域名）两种部署方式
- **Continue + DeepSeek/Claude 双模型** — 自动配置 Continue 扩展，支持 DeepSeek 和 Claude 两个 AI 模型
- **Claude Code CLI** — 可选在容器内安装 Claude Code 命令行工具
- **内存感知** — 检测到 < 1GB 内存时自动询问添加 SWAP
- **BBR 可选** — 可选开启 TCP BBR 拥塞控制
- **容器冲突处理** — 同名容器提示重建
- **密码自动生成** — 留空则生成 16 位随机密码
- **就绪等待** — 轮询 `config.yaml` 确保 code-server 初始化完成后再操作
- **防火墙自动放行** — 支持 ufw + firewalld

### 访问方式

```
Flash:  http://<服务器IP>:<端口>            （默认 8443，自签证书）
Pro:    https://<你的域名>                   （Caddy 自动 HTTPS）
登录密码:  脚本中设定或自动生成
```

> 🔒 Flash 版使用 code-server 自签 HTTPS 证书，浏览器显示安全警告时点击「高级 → 继续访问」即可。Pro 版绑定域名后为正规 CA 证书。

### Continue + DeepSeek 使用

如果安装时配置了 DeepSeek API Key，打开 code-server 后：
1. 点击左侧 AI 图标（Continue 插件）
2. Flash 版选择 `DeepSeek Chat` / `DeepSeek Coder`；Pro 版额外支持 `Claude` 模型
3. 编辑代码时 `DeepSeek Coder` 自动补全

### 安装 Claude Code CLI（容器内）

已部署 code-server 后，可运行此脚本在容器内安装 Claude Code CLI，通过 DeepSeek Anthropic 兼容 API 使用：

| 脚本 | 功能 |
|------|------|
| [install-claude-code.sh](docker/install-claude-code.sh) | 容器内安装 Claude Code + DeepSeek |

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/install-claude-code.sh)"
```

**特点：**
- **自动检测容器** — 自动发现运行中的 code-server 容器
- **Node.js 安装** — 容器内缺少 Node.js 时自动安装
- **Claude Code CLI** — 通过 npm 安装 `@anthropic-ai/claude-code`
- **DeepSeek 兼容 API** — 自动配置 `ANTHROPIC_BASE_URL` 指向 DeepSeek
- **多模型支持** — 默认 `deepseek-v4-pro`，可切换 `deepseek-v4-flash`
- **双配置写入** — 同时写入 `settings.json` 和 `.bashrc`，确保终端和 code-server 内均可使用

使用方式：
```bash
# 进入容器直接运行
docker exec -it -u coder <容器名> claude

# 更新 Claude Code
docker exec -u root <容器名> npm update -g @anthropic-ai/claude-code
```

---

<a name="step-5"></a>
## ⑤ Web 服务

部署 Nginx 作为回落站点、静态网站或反向代理。**需先安装 Docker。**

| 脚本 | 功能 | 特点 |
|------|------|------|
| [deploy-nginx.sh](docker/deploy-nginx.sh) | Nginx 容器部署 | 回落站点 / 静态网站 / 反向代理 / 自定义配置 |

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/docker/deploy-nginx.sh)"
```

### 功能特性

- **自定义网站目录** — 挂载宿主机目录到 Nginx 的 `/usr/share/nginx/html`
- **示例页面生成** — 自动生成一个美观的回落站点页面
- **自定义配置** — 支持挂载 `nginx.conf`
- **多端口映射** — 支持同时映射多个宿主机端口

---

<a name="reference"></a>
## 📖 脚本一览

所有脚本快速索引：

| 步骤 | 脚本 | 一句话用途 |
|------|------|------------|
| ① | [init.sh](system/init.sh) | 系统初始化（换源/更新/BBR/时区/SWAP） |
| ② | [install-docker.sh](docker/install-docker.sh) | 安装 Docker + Compose |
| ③ (原生) | [install-xray-reality.sh](proxy/install-xray-reality.sh) | Xray + REALITY 原生安装 |
| ③ (原生) | [install-singbox-reality.sh](proxy/install-singbox-reality.sh) | Sing-box + REALITY 原生安装 |
| ③ (Docker) | [install-xray-reality.sh](docker/install-xray-reality.sh) | Xray + REALITY Docker 部署 |
| ③ (Docker) | [install-singbox-reality.sh](docker/install-singbox-reality.sh) | Sing-box + REALITY Docker 部署 |
| ④ | [deploy-codeserver-flash.sh](docker/deploy-codeserver-flash.sh) | code-server 轻量部署（Docker） |
| ④ | [deploy-codeserver-pro.sh](docker/deploy-codeserver-pro.sh) | code-server 完整部署（Caddy HTTPS） |
| ④ | [install-claude-code.sh](docker/install-claude-code.sh) | 容器内安装 Claude Code + DeepSeek |
| ⑤ | [deploy-nginx.sh](docker/deploy-nginx.sh) | Nginx 容器（回落/静态/反向代理） |

---

<a name="share"></a>
## 📤 分享给朋友

代理脚本运行结束后，终端会输出完整的配置信息，**直接复制发送**即可：

```
服务器信息：
  地址：xxx
  端口：443
  UUID：xxx
  Flow：xtls-rprx-vision
  PublicKey：xxx
  ShortId (3个可选)：xxx / xxx / xxx
  SNI：www.microsoft.com

v2rayN 导入链接：
  vless://xxx@xxx:443?...

Clash Meta 配置：
  - name: 香港
    type: vless
    ...
```

对方在 v2rayN 中 `服务器 → 从剪贴板导入` 即可使用。

> ⚠️ 每台服务器运行脚本会生成唯一 UUID、密钥对和 ShortId，配置独立不重复。

---

## 📂 目录结构

```
vps-scripts/
├── README.md                 ← 本文件（使用引导 + 配置说明）
├── proxy/                    ← 代理搭建（原生安装）
│   ├── install-xray-reality.sh
│   └── install-singbox-reality.sh
├── docker/                   ← Docker 环境 + 容器化服务
│   ├── install-docker.sh           Docker 引擎安装
│   ├── deploy-nginx.sh             Nginx 容器
│   ├── deploy-codeserver-flash.sh      code-server 容器（轻量版）
│   ├── deploy-codeserver-pro.sh        code-server 容器（完整版）
│   ├── install-claude-code.sh          Claude Code + DeepSeek 安装
│   ├── install-xray-reality.sh     Xray 容器
│   └── install-singbox-reality.sh  Sing-box 容器
└── system/                   ← 系统优化
    └── init.sh                     系统一键初始化
```

---

## 🔧 常用管理命令

### Docker

```bash
# 服务状态
systemctl status docker
journalctl -u docker --no-pager -l -n 30

# 容器管理
docker ps                            # 运行中容器
docker ps -a                         # 所有容器
docker logs -f <容器名>              # 实时日志
docker restart <容器名>              # 重启
docker rm -f <容器名>                # 强制删除
docker images                        # 镜像列表
docker image prune -a                # 清理无用镜像
```

### 代理（原生安装）

```bash
# Xray
systemctl status xray
journalctl -u xray --no-pager -l -n 30
systemctl restart xray

# Sing-box
systemctl status sing-box
journalctl -u sing-box --no-pager -l -n 30
systemctl restart sing-box
```

---

<a name="contributing"></a>
## 🤝 贡献

欢迎提交 PR 或开 Issue 补充更多脚本，比如：

- 系统初始化（时区、SSH 加固、Fail2Ban、SWAP 配置）
- Node.js / Python 环境部署
- 网络加速（BBR / BBRx / WireGuard）
- Docker 应用（MySQL、Redis、PostgreSQL 容器化）

---

## 📄 License

MIT
