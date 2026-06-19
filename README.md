# ✨ Mihomo Lite - 一键配置脚本 V1.0.5

<!-- GitHub Badges -->
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%2B-orange?logo=ubuntu)
![Debian](https://img.shields.io/badge/Debian-12%2B-red?logo=debian)
![Alpine](https://img.shields.io/badge/Alpine-Supported-blue?logo=alpinelinux)
![License](https://img.shields.io/badge/License-MIT-green)

> 🚀 **专为 VPS 打造的极简 Mihomo 管理工具。**
> 
> 安装后仅需在命令行输入 `mh`，即可唤出交互式管理面板。轻松实现内核安装、节点生成、订阅聚合与服务运维。

⚠️ **免责声明**：请务必在遵守当地法律法规、服务商条款（TOS）和网络使用政策的前提下使用本项目。

---

## ⚡ 快速安装

请在具有 `root` 权限的终端中执行以下一键安装命令：

```sh
curl -fsSL https://raw.githubusercontent.com/oKafuChino/Mihomo-lite/main/install.sh | sudo sh
```
---

## 🌟 核心功能

通过终端输入 `mh` 即可打开 TUI 菜单，支持以下快捷操作：

* **📦 核心管理**：一键安装 / 卸载 Mihomo 内核至系统目录。
* **🔗 节点生成**：一键生成代理节点，并自动输出可复制导入的节点链接。
* **📊 节点管理**：查看所有已建节点、单节点链接以及 **Base64 聚合订阅**，支持单节点删除和一键清空。
* **⚙️ 服务运维**：一键查看 YAML 配置文件、重启服务进程。
* **📡 运行监控**：实时查看 Mihomo 运行日志。
* **🔄 无缝升级**：支持一键拉取并更新管理脚本自身。

### 🛡️ 支持的代理协议

生成节点功能目前内置了以下主流且高效的协议组合：

1.  **VLESS + Reality** 
2.  **Hysteria2** 
3.  **AnyTLS**
4.  **VLESS + WebSocket**

---

## 📂 目录与服务架构

本脚本在 Debian / Ubuntu 系统上会自动创建并守护 `systemd` 服务，在 Alpine 系统上则会创建 `OpenRC` 服务。核心路径分布如下：

| 组件名称 | 对应路径 | 说明 |
| :--- | :--- | :--- |
| **管理面板命令** | `/usr/local/bin/mh` | 终端快捷启动命令 |
| **Mihomo 内核** | `/usr/local/bin/mihomo` | 核心可执行文件 |
| **配置主目录** | `/etc/mihomo/` | 存储运行所需的各项配置 |
| **主配置文件** | `/etc/mihomo/config.yaml` | Mihomo 运行的源配置 |
| **节点数据库** | `/etc/mihomo/nodes.db` | 本地化存储已生成的节点记录 |
| **日志目录** | `/var/log/mihomo/` | 存储服务的运行与连接日志 |

*💡 后台守护服务名称：`mihomo`*

### 🧩 低配 LXC 容器说明

脚本默认使用较保守的 Mihomo 运行参数，降低 Alpine/LXC 小内存环境在高速率下崩溃的概率：

* 默认关闭 `fake-ip` 缓存，DNS 使用 `redir-host`。
* 默认日志级别为 `warning`，减少高流量时的日志开销。
* 服务默认注入 `GOMEMLIMIT=128MiB` 和 `GOGC=50`，可在安装或重启前通过环境变量覆盖。

示例：

```sh
MIHOMO_GOMEMLIMIT=192MiB MIHOMO_GOGC=75 mh install
```
