# vps-scripts

> 服务器常用安装脚本集合 — 一键部署，开箱即用。

适用于 Ubuntu 20.04+ / Debian 10+，专注香港 VPS 场景。

[![GitHub](https://img.shields.io/badge/GitHub-liaowucisheng/vps--scripts-blue?style=flat-square)](https://github.com/liaowucisheng/vps-scripts)

---

## 目录

- [代理搭建](#proxy)
- [快速使用](#quickstart)
- [分享给朋友](#share)
- [贡献指南](#contributing)

---

<a name="proxy"></a>
## 📡 代理搭建

| 脚本 | 内核 | 协议 | 特点 |
|------|------|------|------|
| [install-xray-reality.sh](proxy/install-xray-reality.sh) | Xray-core | VLESS + REALITY + Vision | 稳定成熟，配置简单 |
| [install-singbox-reality.sh](proxy/install-singbox-reality.sh) | Sing-box | VLESS + REALITY + Vision | 原生 DNS over TLS，内核更精简 |

两款脚本效果一样（客户端都是 v2rayN / Clash Meta 通用），区别只在于服务端内核：

- **Xray** — REALITY 协议的发明者，生态最成熟
- **Sing-box** — 内核更现代，自带 DNS 防污染，支持 TUN 模式

---

<a name="quickstart"></a>
## 🚀 快速开始

### 一键运行

无需下载，`curl` 直连 GitHub raw 执行：

**Xray 版：**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/proxy/install-xray-reality.sh)"
```

**Sing-box 版：**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/liaowucisheng/vps-scripts/main/proxy/install-singbox-reality.sh)"
```

### 运行流程

1. 执行后会提示输入三个参数（都有默认值，直接回车即可）：

   ```
   请输入端口号 (默认 443):          ← 回车
   请输入回落目标域名 (默认 www.microsoft.com):   ← 回车
   是否开启 BBR? (y/n, 默认 y):     ← 回车
   ```

2. 脚本自动完成：安装依赖 → 开启 BBR → 安装内核 → 生成密钥 → 写入配置 → 启动服务 → 配置防火墙

3. 安装完成后终端会打印服务器信息和客户端配置：

   ```
   ✅ Xray + REALITY 安装完成！
   📋 服务器参数
   🔗 v2rayN 导入链接
   📝 Clash Meta 配置
   📤 分享给朋友
   🛠 常用管理命令
   ```

### 客户端配置

安装完成后，复制终端输出的 **v2rayN 导入链接**（`vless://...`），在 v2rayN 中：

1. 打开 v2rayN
2. `服务器` → `从剪贴板导入`
3. 右键节点 → `设为活动服务器`

**Clash Meta / Clash Verge 用户**：使用终端输出的 Clash 配置段，粘贴到配置文件中即可。

> 💡 **速度优化建议：** 在 v2rayN 中右键服务器 → 编辑 → MUX 多路复用 → 启用，并发数设为 `8`。多路复用可大幅减少 TLS 握手次数，网页加载更快。

---

<a name="share"></a>
## 📤 分享给朋友

安装脚本运行结束后，会输出以下格式的完整配置块，**直接复制发送**给你的朋友：

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

对方在 v2rayN 中`从剪贴板导入`即可使用。

> ⚠️ 每个脚本运行时会自动生成唯一的 UUID、密钥对和 ShortId，所以每台服务器的配置都是独立的。

---

## 📂 目录结构

```
vps-scripts/
├── README.md               ← 本文件
├── proxy/                  ← 代理搭建
│   ├── install-xray-reality.sh
│   └── install-singbox-reality.sh
├── system/                 ← 系统优化（开发中）
└── docker/                 ← Docker 安装（开发中）
```

---

## ⚙️ 管理命令

安装后常用操作：

```bash
# 查看运行状态
systemctl status xray        # Xray
systemctl status sing-box    # Sing-box

# 查看日志
journalctl -u xray --no-pager -l -n 30
journalctl -u sing-box --no-pager -l -n 30

# 重启
systemctl restart xray
systemctl restart sing-box
```

---

<a name="contributing"></a>
## 🤝 贡献

欢迎提交 PR 或开 Issue 补充更多服务器脚本，比如：

- 系统初始化（时区、SSH 加固、Fail2Ban）
- Docker / Docker Compose 安装
- Node.js / Python 环境部署
- 网络加速（BBR、BBRx）
- WireGuard VPN

---

## 📄 License

MIT
