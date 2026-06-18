#!/bin/sh

set -u

APP_NAME="mihomo-onekey"
BIN_PATH="/usr/local/bin/mihomo"
CLI_PATH="/usr/local/bin/mh"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
NODES_DB="$CONFIG_DIR/nodes.db"
LOG_DIR="/var/log/mihomo"
SERVICE_NAME="mihomo"
GITHUB_API="${MIHOMO_GITHUB_API:-https://api.github.com/repos/MetaCubeX/mihomo/releases/latest}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请使用 root 权限运行：sudo mh"
    exit 1
  fi
}

pause() {
  printf '\n按回车返回菜单...'
  read -r _ || true
}

detect_os() {
  if [ ! -r /etc/os-release ]; then
    red "无法识别系统：缺少 /etc/os-release"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-0}"
  os_major="${os_version%%.*}"

  case "$os_id" in
    ubuntu)
      if [ "${os_major:-0}" -lt 22 ]; then
        red "当前 Ubuntu 版本为 $os_version，本脚本要求 Ubuntu 22+。"
        exit 1
      fi
      ;;
    debian)
      if [ "${os_major:-0}" -lt 12 ]; then
        red "当前 Debian 版本为 $os_version，本脚本要求 Debian 12+。"
        exit 1
      fi
      ;;
    alpine)
      ;;
    *)
      red "暂不支持当前系统：$os_id。支持 Ubuntu 22+、Debian 12+、Alpine。"
      exit 1
      ;;
  esac
}

service_manager() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    printf 'systemd'
  elif command -v rc-service >/dev/null 2>&1; then
    printf 'openrc'
  else
    printf 'unknown'
  fi
}

install_packages() {
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl gzip tar >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gzip tar
  else
    red "未找到 apk 或 apt-get，无法自动安装依赖。"
    exit 1
  fi
}

detect_arch() {
  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    armv7l | armv7) printf 'armv7' ;;
    armv6l | armv6) printf 'armv6' ;;
    i386 | i686) printf '386' ;;
    riscv64) printf 'riscv64' ;;
    *)
      red "暂不支持当前 CPU 架构：$machine"
      exit 1
      ;;
  esac
}

latest_download_url() {
  arch="$(detect_arch)"
  release_json="$(curl -fsSL "$GITHUB_API")" || {
    red "无法访问 mihomo GitHub Release API。"
    exit 1
  }

  urls="$(printf '%s\n' "$release_json" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  download_url="$(printf '%s\n' "$urls" | grep -Ei "mihomo-linux-${arch}.*compatible.*\.gz$" | head -n 1 || true)"

  if [ -z "$download_url" ]; then
    download_url="$(printf '%s\n' "$urls" | grep -Ei "mihomo-linux-${arch}.*\.gz$" | head -n 1 || true)"
  fi

  if [ -z "$download_url" ]; then
    red "没有找到适配 linux-$arch 的 mihomo release 资产。"
    exit 1
  fi

  printf '%s' "$download_url"
}

rand_alnum() {
  length="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

random_port() {
  od -An -N2 -tu2 /dev/urandom | awk '{ print 20000 + ($1 % 30000) }'
}

public_ip() {
  ip="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$ip" ]; then
    ip="YOUR_SERVER_IP"
  fi
  printf '%s' "$ip"
}

render_config() {
  mkdir -p "$CONFIG_DIR" "$LOG_DIR"
  tmp_file="$CONFIG_FILE.tmp"
  secret_file="$CONFIG_DIR/controller.secret"

  if [ ! -s "$secret_file" ]; then
    rand_alnum 32 > "$secret_file"
    chmod 600 "$secret_file"
  fi
  controller_secret="$(cat "$secret_file")"

  cat > "$tmp_file" <<EOF
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090
secret: "$controller_secret"
profile:
  store-selected: true
  store-fake-ip: true
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: fake-ip
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
EOF

  if [ -s "$NODES_DB" ]; then
    printf 'listeners:\n' >> "$tmp_file"
    while IFS='|' read -r node_name node_port node_cipher node_password; do
      [ -n "$node_name" ] || continue
      cat >> "$tmp_file" <<EOF
  - name: "$node_name"
    type: shadowsocks
    port: $node_port
    listen: 0.0.0.0
    cipher: $node_cipher
    password: "$node_password"
    udp: true
EOF
    done < "$NODES_DB"
  else
    printf 'listeners: []\n' >> "$tmp_file"
  fi

  cat >> "$tmp_file" <<'EOF'
proxies: []
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,DIRECT
EOF

  mv "$tmp_file" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

write_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=mihomo proxy service
Documentation=https://wiki.metacubex.one/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH -d $CONFIG_DIR -f $CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
}

write_openrc_service() {
  cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run

description="mihomo proxy service"
command="$BIN_PATH"
command_args="-d $CONFIG_DIR -f $CONFIG_FILE"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="$LOG_DIR/${SERVICE_NAME}.log"
error_log="$LOG_DIR/${SERVICE_NAME}.err"

depend() {
  need net
}
EOF
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  rc-update add "$SERVICE_NAME" default >/dev/null
  rc-service "$SERVICE_NAME" restart
}

restart_service() {
  manager="$(service_manager)"
  case "$manager" in
    systemd)
      systemctl daemon-reload
      systemctl restart "$SERVICE_NAME"
      ;;
    openrc)
      rc-service "$SERVICE_NAME" restart
      ;;
    *)
      red "未找到 systemd 或 OpenRC，无法管理 mihomo 服务。"
      exit 1
      ;;
  esac
}

install_core() {
  need_root
  detect_os
  install_packages
  mkdir -p "$CONFIG_DIR" "$LOG_DIR"

  download_url="$(latest_download_url)"
  tmp_file="/tmp/mihomo.$$"

  info "正在下载 mihomo：$download_url"
  curl -fL "$download_url" -o "$tmp_file"
  gzip -dc "$tmp_file" > "$BIN_PATH"
  rm -f "$tmp_file"
  chmod +x "$BIN_PATH"

  [ -f "$NODES_DB" ] || : > "$NODES_DB"
  chmod 600 "$NODES_DB"
  render_config

  manager="$(service_manager)"
  case "$manager" in
    systemd) write_systemd_service ;;
    openrc) write_openrc_service ;;
    *)
      red "未找到 systemd 或 OpenRC，mihomo 已安装但服务未创建。"
      exit 1
      ;;
  esac

  green "mihomo 内核安装完成，服务已启动。"
}

ensure_installed() {
  if [ ! -x "$BIN_PATH" ] || [ ! -f "$CONFIG_FILE" ]; then
    red "mihomo 尚未安装，请先在菜单输入 1 安装内核。"
    exit 1
  fi
}

add_node() {
  need_root
  ensure_installed

  printf '请输入节点名称（默认 ss-%s）：' "$(date +%m%d%H%M)"
  read -r node_name || true
  if [ -z "$node_name" ]; then
    node_name="ss-$(date +%m%d%H%M)"
  fi
  node_name="$(printf '%s' "$node_name" | tr -cd 'A-Za-z0-9_.-')"
  if [ -z "$node_name" ]; then
    red "节点名称无效，只能包含字母、数字、下划线、点和短横线。"
    exit 1
  fi

  if awk -F'|' -v n="$node_name" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$NODES_DB" 2>/dev/null; then
    red "节点 $node_name 已存在。"
    exit 1
  fi

  default_port="$(random_port)"
  printf '请输入监听端口（默认 %s）：' "$default_port"
  read -r node_port || true
  [ -n "$node_port" ] || node_port="$default_port"

  case "$node_port" in
    ''|*[!0-9]*)
      red "端口必须是数字。"
      exit 1
      ;;
  esac
  if [ "$node_port" -lt 1 ] || [ "$node_port" -gt 65535 ]; then
    red "端口范围必须为 1-65535。"
    exit 1
  fi

  if awk -F'|' -v p="$node_port" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' "$NODES_DB" 2>/dev/null; then
    red "端口 $node_port 已被脚本内的其他节点使用。"
    exit 1
  fi

  node_cipher="chacha20-ietf-poly1305"
  node_password="$(rand_alnum 32)"
  printf '%s|%s|%s|%s\n' "$node_name" "$node_port" "$node_cipher" "$node_password" >> "$NODES_DB"
  chmod 600 "$NODES_DB"
  render_config
  restart_service

  server_ip="$(public_ip)"
  green "节点已生成并重启服务。"
  cat <<EOF

请确认 VPS 防火墙和云厂商安全组已放行 TCP/UDP $node_port。

mihomo 客户端节点片段：
- name: $node_name
  type: ss
  server: $server_ip
  port: $node_port
  cipher: $node_cipher
  password: "$node_password"
  udp: true
EOF
}

list_nodes() {
  if [ ! -s "$NODES_DB" ]; then
    yellow "当前没有节点。"
    return 1
  fi

  i=1
  while IFS='|' read -r node_name node_port node_cipher node_password; do
    [ -n "$node_name" ] || continue
    printf '%s. %s  port=%s  cipher=%s\n' "$i" "$node_name" "$node_port" "$node_cipher"
    i=$((i + 1))
  done < "$NODES_DB"
}

delete_node() {
  need_root
  ensure_installed

  list_nodes || return 0
  printf '请输入要删除的节点编号：'
  read -r choice || true

  case "$choice" in
    ''|*[!0-9]*)
      red "请输入有效数字。"
      exit 1
      ;;
  esac

  tmp_file="$NODES_DB.tmp"
  deleted="$(awk -F'|' -v n="$choice" 'NR == n { print $1 }' "$NODES_DB")"
  if [ -z "$deleted" ]; then
    red "未找到编号 $choice。"
    exit 1
  fi

  awk -v n="$choice" 'NR != n { print }' "$NODES_DB" > "$tmp_file"
  mv "$tmp_file" "$NODES_DB"
  chmod 600 "$NODES_DB"
  render_config
  restart_service
  green "节点 $deleted 已删除，服务已重启。"
}

show_logs() {
  ensure_installed
  manager="$(service_manager)"
  case "$manager" in
    systemd) journalctl -u "$SERVICE_NAME" -f --no-pager ;;
    openrc)
      touch "$LOG_DIR/${SERVICE_NAME}.log" "$LOG_DIR/${SERVICE_NAME}.err"
      tail -F "$LOG_DIR/${SERVICE_NAME}.log" "$LOG_DIR/${SERVICE_NAME}.err"
      ;;
    *)
      red "未找到 systemd 或 OpenRC，无法查看服务日志。"
      exit 1
      ;;
  esac
}

uninstall_all() {
  need_root
  printf '确认卸载 mihomo、删除配置和 mh 命令？输入 y 确认：'
  read -r confirm || true
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      yellow "已取消卸载。"
      return 0
      ;;
  esac

  manager="$(service_manager)"
  case "$manager" in
    systemd)
      systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
      rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
      systemctl daemon-reload 2>/dev/null || true
      ;;
    openrc)
      rc-service "$SERVICE_NAME" stop 2>/dev/null || true
      rc-update del "$SERVICE_NAME" default 2>/dev/null || true
      rm -f "/etc/init.d/${SERVICE_NAME}"
      ;;
  esac

  rm -f "$BIN_PATH" "$CLI_PATH"
  rm -rf "$CONFIG_DIR" "$LOG_DIR"
  green "卸载完成。"
}

menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'EOF'
========================================
  mihomo 一键配置管理面板
========================================
  1. 一键安装 mihomo 内核
  2. 一键生成节点
  3. 删除节点
  4. 重启服务
  5. 查看实时日志
  6. 卸载脚本
  0. 退出脚本
========================================
EOF
    printf '请输入数字选择：'
    read -r choice || exit 0

    case "$choice" in
      1) install_core; pause ;;
      2) add_node; pause ;;
      3) delete_node; pause ;;
      4) need_root; ensure_installed; restart_service; green "服务已重启。"; pause ;;
      5) show_logs ;;
      6) uninstall_all; pause ;;
      0) exit 0 ;;
      *) red "无效选择。"; pause ;;
    esac
  done
}

case "${1:-}" in
  install) install_core ;;
  add) add_node ;;
  delete|del|remove) delete_node ;;
  restart) need_root; ensure_installed; restart_service ;;
  logs|log) show_logs ;;
  uninstall) uninstall_all ;;
  *) menu ;;
esac
