# mihomo 一键配置脚本

一个面向 VPS 的 mihomo 管理脚本，支持 Ubuntu 22+、Debian 12+ 和 Alpine。安装后可以在命令行输入 `mh` 打开管理面板，面板会显示作者、版本号和 mihomo 内核运行状态，并可通过数字菜单安装内核、生成节点、查看节点、删除节点、查看配置、重启服务、查看日志、更新脚本和卸载。

> 请在遵守当地法律法规、服务商条款和网络使用政策的前提下使用。

## 功能

- `1` 一键安装 mihomo 内核到 `/usr/local/bin/mihomo`
- `2` 一键生成节点，并输出可复制导入的节点链接
- `3` 查看所有节点、节点链接和 Base64 聚合订阅
- `4` 删除已生成的节点
- `5` 查看 mihomo 配置文件
- `6` 重启 mihomo 服务
- `7` 查看实时日志
- `8` 更新脚本
- `9` 卸载 mihomo、配置和 `mh` 命令
- `0` 退出脚本

生成节点页面支持：

- `1` VLESS + Reality
- `2` Hysteria2，可自定义密码，可选择 Salamander 混淆
- `3` AnyTLS
- `4` VLESS + WebSocket，可自定义域名/Host 和路径

## 快速安装

项目推送到 GitHub 后，把下面命令中的 `<用户名>` 和 `<仓库>` 替换为你的仓库信息：

```sh
curl -fsSL https://raw.githubusercontent.com/oKafuChino/Mihomo-lite/main/install.sh | sudo sh
```

## 目录和服务

- 管理命令：`/usr/local/bin/mh`
- mihomo 内核：`/usr/local/bin/mihomo`
- 配置目录：`/etc/mihomo`
- 主配置：`/etc/mihomo/config.yaml`
- 节点记录：`/etc/mihomo/nodes.db`
- 日志目录：`/var/log/mihomo`
- 服务名：`mihomo`

脚本会在 Debian/Ubuntu 上创建 systemd 服务，在 Alpine 上创建 OpenRC 服务。

## 节点说明

当前脚本生成的是 mihomo `listeners` 入站节点：

- VLESS + Reality 会自动生成 UUID、Reality X25519 密钥对和 short-id
- Hysteria2 会自动生成自签 TLS 证书，支持用户输入密码和自动配置 Salamander 混淆
- AnyTLS 会自动生成自签 TLS 证书
- VLESS + WebSocket 会自动生成 UUID，并允许用户输入域名/Host 和 WS 路径
- 菜单 `3` 会输出所有节点链接，同时生成 Base64 聚合订阅内容和 Data URI

生成节点后，请确认 VPS 系统防火墙和云厂商安全组已经放行对应端口的 TCP/UDP。

## 参考

- [mihomo GitHub 仓库](https://github.com/MetaCubeX/mihomo)
- [mihomo 配置示例](https://raw.githubusercontent.com/MetaCubeX/mihomo/Alpha/docs/config.yaml)
