#!/bin/sh

set -u

SCRIPT_AUTHOR="oKafuChino"
SCRIPT_VERSION="1.3.0"
BIN_PATH="/usr/local/bin/mihomo"
CLI_PATH="/usr/local/bin/mh"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
NODES_DB="$CONFIG_DIR/nodes.db"
LOG_DIR="/var/log/mihomo"
SERVICE_NAME="mihomo"
MIHOMO_GOMEMLIMIT="${MIHOMO_GOMEMLIMIT:-}"
MIHOMO_GOGC="${MIHOMO_GOGC:-}"
HY2_UP_MBPS=10000
HY2_DOWN_MBPS=10000
GITHUB_API="${MIHOMO_GITHUB_API:-https://api.github.com/repos/MetaCubeX/mihomo/releases/latest}"
SCRIPT_RAW_URL="${MH_SCRIPT_RAW_URL:-https://raw.githubusercontent.com/oKafuChino/Mihomo-lite/main/mh.sh}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }

C_CYAN=$(printf '\033[1;36m')
C_GREEN=$(printf '\033[1;32m')
C_YELLOW=$(printf '\033[1;33m')
C_PURPLE=$(printf '\033[1;35m')
C_RED=$(printf '\033[1;31m')
C_BOLD=$(printf '\033[1m')
C_RESET=$(printf '\033[0m')

ui_line() { printf '%s====================================================%s\n' "$C_CYAN" "$C_RESET"; }
ui_dash() { printf '%s----------------------------------------------------%s\n' "$C_CYAN" "$C_RESET"; }
ui_title() {
  ui_line
  printf ' [*] %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
  ui_line
}
screen_title() {
  clear 2>/dev/null || true
  ui_title "$1"
}
ui_section() { printf ' %s[+] %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
ui_prompt() { printf '%s%s%s' "$C_BOLD" "$1" "$C_RESET"; }
ui_success() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
ui_warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
ui_error() { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$1"; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请使用 root 权限运行：sudo mh"
    exit 1
  fi
}

pause() {
  printf '\n'
  ui_prompt "按回车返回菜单..."
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

service_status_text() {
  if [ ! -x "$BIN_PATH" ] || [ ! -f "$CONFIG_FILE" ]; then
    printf '未安装'
    return 0
  fi

  manager="$(service_manager)"
  case "$manager" in
    systemd)
      if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        printf '运行中'
      else
        printf '未运行'
      fi
      ;;
    openrc)
      if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        printf '运行中'
      else
        printf '未运行'
      fi
      ;;
    *)
      printf '未知'
      ;;
  esac
}

install_packages() {
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates "$@" >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates "$@"
  else
    red "未找到 apk 或 apt-get，无法自动安装依赖。"
    exit 1
  fi
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 || install_packages curl
}

make_temp() {
  mktemp "$1" 2>/dev/null || {
    red "无法创建临时文件：$1"
    exit 1
  }
}

recommended_runtime() {
  case "${os_id:-}" in
    alpine) printf '192MiB|75' ;;
    debian|ubuntu) printf '384MiB|150' ;;
    *) printf '256MiB|100' ;;
  esac
}

prompt_runtime_tuning() {
  recommended="$(recommended_runtime)"
  recommended_mem="${recommended%%|*}"
  recommended_gogc="${recommended#*|}"

  ui_section "设置 Mihomo 运行参数"
  if [ -z "$MIHOMO_GOMEMLIMIT" ]; then
    ui_prompt "请输入 GOMEMLIMIT（推荐 $recommended_mem）："
    read -r input_mem || true
    MIHOMO_GOMEMLIMIT="${input_mem:-$recommended_mem}"
  else
    ui_warn "使用环境变量 GOMEMLIMIT=$MIHOMO_GOMEMLIMIT"
  fi

  if [ -z "$MIHOMO_GOGC" ]; then
    ui_prompt "请输入 GOGC（推荐 $recommended_gogc）："
    read -r input_gogc || true
    MIHOMO_GOGC="${input_gogc:-$recommended_gogc}"
  else
    ui_warn "使用环境变量 GOGC=$MIHOMO_GOGC"
  fi

  case "$MIHOMO_GOGC" in
    ''|*[!0-9]*)
      red "GOGC 必须是数字。"
      exit 1
      ;;
  esac
  case "$MIHOMO_GOMEMLIMIT" in
    *[!A-Za-z0-9]*|'')
      red "GOMEMLIMIT 只能包含字母和数字，例如 192MiB。"
      exit 1
      ;;
  esac
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

rand_hex() {
  bytes="${1:-4}"
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    h="$(rand_hex 16)"
    printf '%s-%s-%s-%s-%s\n' \
      "$(printf '%s' "$h" | cut -c1-8)" \
      "$(printf '%s' "$h" | cut -c9-12)" \
      "$(printf '%s' "$h" | cut -c13-16)" \
      "$(printf '%s' "$h" | cut -c17-20)" \
      "$(printf '%s' "$h" | cut -c21-32)"
  fi
}

url_path() {
  value="${1:-node}"
  printf '%s' "$value" | sed 's/%/%25/g; s/ /%20/g; s/\//%2F/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g'
}

need_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    red "缺少 openssl，请先在菜单输入 1 安装/补齐依赖。"
    exit 1
  fi
}

base64_urlsafe() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}

base64_one_line() {
  base64 | tr -d '\n'
}

create_reality_keypair() {
  need_openssl
  key_file="$CONFIG_DIR/reality.key.$$"
  openssl genpkey -algorithm X25519 -out "$key_file" >/dev/null 2>&1 || {
    rm -f "$key_file"
    red "生成 Reality X25519 密钥失败。"
    exit 1
  }
  private_key="$(openssl pkey -in "$key_file" -outform DER 2>/dev/null | tail -c 32 | base64_urlsafe)"
  public_key="$(openssl pkey -in "$key_file" -pubout -outform DER 2>/dev/null | tail -c 32 | base64_urlsafe)"
  rm -f "$key_file"

  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    red "解析 Reality 密钥失败。"
    exit 1
  fi

  printf '%s|%s' "$private_key" "$public_key"
}

ensure_tls_cert() {
  need_openssl
  cert_name="$1"
  sni="$2"
  cert_dir="$CONFIG_DIR/certs"
  cert_file="$cert_dir/${cert_name}.crt"
  key_file="$cert_dir/${cert_name}.key"
  mkdir -p "$cert_dir"

  if [ ! -s "$cert_file" ] || [ ! -s "$key_file" ]; then
    openssl req -x509 -nodes -newkey ec \
      -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key_file" \
      -out "$cert_file" \
      -subj "/CN=$sni" \
      -days 3650 >/dev/null 2>&1 || {
        red "生成 TLS 自签证书失败。"
        exit 1
      }
    chmod 600 "$key_file" "$cert_file"
  fi

  printf '%s|%s' "$cert_file" "$key_file"
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
log-level: warning
ipv6: false
external-controller: 127.0.0.1:9090
secret: "$controller_secret"
profile:
  store-selected: true
  store-fake-ip: false
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: redir-host
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
EOF

  if [ -s "$NODES_DB" ]; then
    printf 'listeners:\n' >> "$tmp_file"
    while IFS='|' read -r cfg_proto cfg_node_name cfg_node_port cfg_value1 cfg_value2 cfg_value3 cfg_value4 cfg_value5 cfg_value6; do
      [ -n "$cfg_proto" ] || continue
      case "$cfg_proto" in
        vless-reality)
          cfg_node_uuid="$cfg_value1"
          cfg_sni="$cfg_value2"
          cfg_dest="$cfg_value3"
          cfg_private_key="$cfg_value4"
          cfg_short_id="$cfg_value6"
          cat >> "$tmp_file" <<EOF
  - name: "$cfg_node_name"
    type: vless
    port: $cfg_node_port
    listen: 0.0.0.0
    users:
      - username: "$cfg_node_name"
        uuid: "$cfg_node_uuid"
    tls: true
    reality-config:
      dest: "$cfg_dest"
      private-key: "$cfg_private_key"
      short-id:
        - "$cfg_short_id"
      server-names:
        - "$cfg_sni"
EOF
          ;;
        hysteria2)
          cfg_node_password="$cfg_value1"
          cfg_cert_file="$cfg_value3"
          cfg_key_file="$cfg_value4"
          cfg_salamander_password="$cfg_value5"
          cat >> "$tmp_file" <<EOF
  - name: "$cfg_node_name"
    type: hysteria2
    port: $cfg_node_port
    listen: 0.0.0.0
    users:
      "$cfg_node_name": "$cfg_node_password"
    certificate: "$cfg_cert_file"
    private-key: "$cfg_key_file"
    up: ${HY2_UP_MBPS} Mbps
    down: ${HY2_DOWN_MBPS} Mbps
EOF
          if [ -n "$cfg_salamander_password" ]; then
            cat >> "$tmp_file" <<EOF
    obfs: salamander
    obfs-password: "$cfg_salamander_password"
EOF
          fi
          ;;
        anytls)
          cfg_node_password="$cfg_value1"
          cfg_cert_file="$cfg_value3"
          cfg_key_file="$cfg_value4"
          cat >> "$tmp_file" <<EOF
  - name: "$cfg_node_name"
    type: anytls
    port: $cfg_node_port
    listen: 0.0.0.0
    users:
      "$cfg_node_name": "$cfg_node_password"
    certificate: "$cfg_cert_file"
    private-key: "$cfg_key_file"
EOF
          ;;
        vless-ws)
          cfg_node_uuid="$cfg_value1"
          cfg_ws_path="$cfg_value2"
          cat >> "$tmp_file" <<EOF
  - name: "$cfg_node_name"
    type: vless
    port: $cfg_node_port
    listen: 0.0.0.0
    allow-insecure: true
    users:
      - username: "$cfg_node_name"
        uuid: "$cfg_node_uuid"
    ws-path: "$cfg_ws_path"
EOF
          ;;
      esac
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
Environment=GOMEMLIMIT=$MIHOMO_GOMEMLIMIT
Environment=GOGC=$MIHOMO_GOGC
ExecStart=$BIN_PATH -d $CONFIG_DIR -f $CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

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
output_log="$LOG_DIR/${SERVICE_NAME}.log"
error_log="$LOG_DIR/${SERVICE_NAME}.err"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
export GOMEMLIMIT="$MIHOMO_GOMEMLIMIT"
export GOGC="$MIHOMO_GOGC"

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
  screen_title "一键安装 Mihomo 内核"
  detect_os
  prompt_runtime_tuning
  ui_section "安装系统依赖"
  install_packages curl gzip openssl
  mkdir -p "$CONFIG_DIR" "$LOG_DIR"

  download_url="$(latest_download_url)"
  tmp_file="$(make_temp /tmp/mihomo.XXXXXX)"
  bin_tmp="$(make_temp /tmp/mihomo-bin.XXXXXX)"

  ui_warn "下载地址：$download_url"
  ui_section "下载并安装 Mihomo 内核"
  curl -fL "$download_url" -o "$tmp_file" || {
    rm -f "$tmp_file" "$bin_tmp"
    exit 1
  }
  gzip -dc "$tmp_file" > "$bin_tmp" || {
    rm -f "$tmp_file" "$bin_tmp"
    exit 1
  }
  chmod +x "$bin_tmp"
  mv "$bin_tmp" "$BIN_PATH"
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
      ui_error "未找到 systemd 或 OpenRC，mihomo 已安装但服务未创建。"
      exit 1
      ;;
  esac

  ui_success "mihomo 内核安装完成，服务已启动。"
}

ensure_installed() {
  if [ ! -x "$BIN_PATH" ] || [ ! -f "$CONFIG_FILE" ]; then
    red "mihomo 尚未安装，请先在菜单输入 1 安装内核。"
    exit 1
  fi
}

node_name_exists() {
  name="$1"
  awk -F'|' -v n="$name" '
    $1 == "vless-reality" || $1 == "hysteria2" || $1 == "anytls" || $1 == "vless-ws" {
      if ($2 == n) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$NODES_DB" 2>/dev/null
}

port_in_use() {
  port="$1"
  awk -F'|' -v p="$port" '
    $1 == "vless-reality" || $1 == "hysteria2" || $1 == "anytls" || $1 == "vless-ws" {
      if ($3 == p) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$NODES_DB" 2>/dev/null
}

prompt_node_name() {
  proto_prefix="$1"
  default_name="$proto_prefix"
  ui_prompt "请输入节点名称（默认 $default_name）："
  read -r node_name || true
  if [ -z "$node_name" ]; then
    node_name="$default_name"
  fi
  node_name="$(printf '%s' "$node_name" | tr -cd 'A-Za-z0-9_.-')"
  if [ -z "$node_name" ]; then
    red "节点名称无效，只能包含字母、数字、下划线、点和短横线。"
    exit 1
  fi

  if node_name_exists "$node_name"; then
    red "节点 $node_name 已存在。"
    exit 1
  fi
  SELECTED_NODE_NAME="$node_name"
}

prompt_port() {
  default_port="$(random_port)"
  ui_prompt "请输入监听端口（默认 $default_port）："
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

  if port_in_use "$node_port"; then
    red "端口 $node_port 已被脚本内的其他节点使用。"
    exit 1
  fi
  SELECTED_NODE_PORT="$node_port"
}

append_node() {
  printf '%s\n' "$1" >> "$NODES_DB"
  chmod 600 "$NODES_DB"
  render_config
  restart_service
}

node_share_link() {
  proto="$1"
  node_name="$2"
  node_port="$3"
  value1="${4:-}"
  value2="${5:-}"
  value3="${6:-}"
  value4="${7:-}"
  value5="${8:-}"
  value6="${9:-}"
  server_ip="${SHARE_SERVER_IP:-$(public_ip)}"
  link_name="$(url_path "$node_name")"

  case "$proto" in
    vless-reality)
      node_uuid="$value1"
      sni="$value2"
      public_key="$value5"
      short_id="$value6"
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$node_uuid" "$server_ip" "$node_port" "$sni" "$public_key" "$short_id" "$link_name"
      ;;
    hysteria2)
      node_password="$value1"
      sni="$value2"
      salamander_password="$value5"
      if [ -n "$salamander_password" ]; then
        printf 'hysteria2://%s@%s:%s?insecure=1&sni=%s&upmbps=%s&downmbps=%s&obfs=salamander&obfs-password=%s#%s\n' \
          "$node_password" "$server_ip" "$node_port" "$sni" "$HY2_UP_MBPS" "$HY2_DOWN_MBPS" "$salamander_password" "$link_name"
      else
        printf 'hysteria2://%s@%s:%s?insecure=1&sni=%s&upmbps=%s&downmbps=%s#%s\n' \
          "$node_password" "$server_ip" "$node_port" "$sni" "$HY2_UP_MBPS" "$HY2_DOWN_MBPS" "$link_name"
      fi
      ;;
    anytls)
      node_password="$value1"
      sni="$value2"
      printf 'anytls://%s@%s:%s?insecure=1&sni=%s#%s\n' \
        "$node_password" "$server_ip" "$node_port" "$sni" "$link_name"
      ;;
    vless-ws)
      node_uuid="$value1"
      ws_path="$(url_path "$value2")"
      ws_host="${value3:-$server_ip}"
      printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' \
        "$node_uuid" "$server_ip" "$node_port" "$ws_host" "$ws_path" "$link_name"
      ;;
  esac
}

print_node_link() {
  proto="$1"
  node_name="$2"
  node_port="$3"
  value1="${4:-}"
  value2="${5:-}"
  value3="${6:-}"
  value4="${7:-}"
  value5="${8:-}"
  value6="${9:-}"
  if [ -z "$node_name" ] || [ -z "$node_port" ]; then
    red "生成节点链接失败：节点名称或端口为空。"
    return 1
  fi
  node_link="$(node_share_link "$proto" "$node_name" "$node_port" "$value1" "$value2" "$value3" "$value4" "$value5" "$value6")"
  cat <<EOF

${C_CYAN}----------------------------------------------------${C_RESET}
 ${C_YELLOW}[!]${C_RESET} 请确认 VPS 防火墙和云厂商安全组已放行 TCP/UDP ${C_BOLD}$node_port${C_RESET}

 ${C_GREEN}[+] 节点链接${C_RESET}
$node_link
${C_CYAN}----------------------------------------------------${C_RESET}
EOF
}

add_vless_reality_node() {
  screen_title "创建 VLESS + Reality 节点"
  prompt_node_name vless-reality
  node_name="$SELECTED_NODE_NAME"
  prompt_port
  node_port="$SELECTED_NODE_PORT"
  ui_prompt "请输入 Reality SNI（默认 www.amd.com）："
  read -r sni || true
  [ -n "$sni" ] || sni="www.amd.com"
  dest="${sni}:443"
  node_uuid="$(new_uuid)"
  key_pair="$(create_reality_keypair)" || exit 1
  private_key="${key_pair%%|*}"
  public_key="${key_pair#*|}"
  short_id="$(rand_hex 8)"
  append_node "vless-reality|$node_name|$node_port|$node_uuid|$sni|$dest|$private_key|$public_key|$short_id"
  ui_success "VLESS + Reality 节点已生成并重启服务。"
  print_node_link vless-reality "$node_name" "$node_port" "$node_uuid" "$sni" "$dest" "$private_key" "$public_key" "$short_id"
}

add_hysteria2_node() {
  screen_title "创建 Hysteria2 节点"
  prompt_node_name hy2
  node_name="$SELECTED_NODE_NAME"
  prompt_port
  node_port="$SELECTED_NODE_PORT"
  ui_prompt "请输入 TLS SNI / 证书域名（默认 www.amd.com）："
  read -r sni || true
  [ -n "$sni" ] || sni="www.amd.com"
  default_password="$(rand_alnum 32)"
  ui_prompt "请输入 Hysteria2 密码（默认随机生成）："
  read -r node_password || true
  [ -n "$node_password" ] || node_password="$default_password"
  node_password="$(printf '%s' "$node_password" | tr -cd 'A-Za-z0-9._~-')"
  [ -n "$node_password" ] || node_password="$default_password"
  ui_prompt "是否开启 Salamander 混淆？会增加 CPU 占用，低配机器建议关闭 [y/N]："
  read -r enable_salamander || true
  salamander_password=""
  case "$enable_salamander" in
    y|Y|yes|YES)
      salamander_password="$(rand_alnum 32)"
      ;;
  esac
  cert_pair="$(ensure_tls_cert "$node_name" "$sni")" || exit 1
  cert_file="${cert_pair%%|*}"
  key_file="${cert_pair#*|}"
  append_node "hysteria2|$node_name|$node_port|$node_password|$sni|$cert_file|$key_file|$salamander_password|"
  ui_success "Hysteria2 节点已生成并重启服务。"
  print_node_link hysteria2 "$node_name" "$node_port" "$node_password" "$sni" "$cert_file" "$key_file" "$salamander_password" ""
}

add_anytls_node() {
  screen_title "创建 AnyTLS 节点"
  prompt_node_name anytls
  node_name="$SELECTED_NODE_NAME"
  prompt_port
  node_port="$SELECTED_NODE_PORT"
  ui_prompt "请输入 TLS SNI / 证书域名（默认 www.amd.com）："
  read -r sni || true
  [ -n "$sni" ] || sni="www.amd.com"
  node_password="$(rand_alnum 32)"
  cert_pair="$(ensure_tls_cert "$node_name" "$sni")" || exit 1
  cert_file="${cert_pair%%|*}"
  key_file="${cert_pair#*|}"
  append_node "anytls|$node_name|$node_port|$node_password|$sni|$cert_file|$key_file||"
  ui_success "AnyTLS 节点已生成并重启服务。"
  print_node_link anytls "$node_name" "$node_port" "$node_password" "$sni" "$cert_file" "$key_file" "" ""
}

add_vless_ws_node() {
  screen_title "创建 VLESS + WebSocket 节点"
  prompt_node_name vless-ws
  node_name="$SELECTED_NODE_NAME"
  prompt_port
  node_port="$SELECTED_NODE_PORT"
  server_ip="$(public_ip)"
  ui_prompt "请输入 WebSocket 域名/Host（默认 $server_ip）："
  read -r ws_host || true
  [ -n "$ws_host" ] || ws_host="$server_ip"
  ws_host="$(printf '%s' "$ws_host" | tr -d '|')"
  default_path="/$(rand_alnum 10)"
  ui_prompt "请输入 WebSocket 路径（默认 $default_path）："
  read -r ws_path || true
  [ -n "$ws_path" ] || ws_path="$default_path"
  case "$ws_path" in
    /*) ;;
    *) ws_path="/$ws_path" ;;
  esac
  node_uuid="$(new_uuid)"
  append_node "vless-ws|$node_name|$node_port|$node_uuid|$ws_path|$ws_host|||"
  ui_success "VLESS + WS 节点已生成并重启服务。"
  print_node_link vless-ws "$node_name" "$node_port" "$node_uuid" "$ws_path" "$ws_host" "" "" ""
}

add_node() {
  need_root
  ensure_installed

  clear 2>/dev/null || true
  cat <<EOF
${C_CYAN}====================================================${C_RESET}
 [*] ${C_BOLD}创建代理节点${C_RESET}
${C_CYAN}====================================================${C_RESET}
 ${C_YELLOW}[+] 请选择协议类型${C_RESET}
   ${C_GREEN}1.${C_RESET} VLESS + Reality
   ${C_GREEN}2.${C_RESET} Hysteria2
   ${C_GREEN}3.${C_RESET} AnyTLS
   ${C_GREEN}4.${C_RESET} VLESS + WebSocket
${C_CYAN}----------------------------------------------------${C_RESET}
 ${C_GREEN}0.${C_RESET} => 返回主菜单
${C_CYAN}====================================================${C_RESET}
EOF
  ui_prompt "请输入数字选择 (0-4)："
  read -r protocol_choice || true

  case "$protocol_choice" in
    1) add_vless_reality_node ;;
    2) add_hysteria2_node ;;
    3) add_anytls_node ;;
    4) add_vless_ws_node ;;
    0) return 0 ;;
    *) red "无效选择。"; exit 1 ;;
  esac
}

show_all_nodes() {
  if [ ! -s "$NODES_DB" ]; then
    clear 2>/dev/null || true
    ui_title "查看所有节点"
    ui_warn "当前没有节点。"
    return 1
  fi

  screen_title "查看所有节点"
  ui_section "节点列表"
  i=1
  SHARE_SERVER_IP="$(public_ip)"
  export SHARE_SERVER_IP
  sub_file="$(make_temp /tmp/mihomo-sub.XXXXXX)"
  : > "$sub_file"
  while IFS='|' read -r proto node_name node_port value1 value2 value3 value4 value5 value6; do
    [ -n "$proto" ] || continue
    case "$proto" in
      vless-reality|hysteria2|anytls|vless-ws)
        node_link="$(node_share_link "$proto" "$node_name" "$node_port" "$value1" "$value2" "$value3" "$value4" "$value5" "$value6")"
        printf ' %s%s.%s %s%s%s  protocol=%s  port=%s\n' "$C_GREEN" "$i" "$C_RESET" "$C_BOLD" "$node_name" "$C_RESET" "$proto" "$node_port"
        printf '   %s\n\n' "$node_link"
        printf '%s\n' "$node_link" >> "$sub_file"
        i=$((i + 1))
        ;;
    esac
  done < "$NODES_DB"

  if [ -s "$sub_file" ]; then
    sub_base64="$(base64_one_line < "$sub_file")"
    cat <<EOF

${C_CYAN}----------------------------------------------------${C_RESET}
 ${C_YELLOW}[+] 聚合订阅 Base64${C_RESET}
$sub_base64
${C_CYAN}----------------------------------------------------${C_RESET}
EOF
  fi
  rm -f "$sub_file"
}

list_nodes() {
  if [ ! -s "$NODES_DB" ]; then
    ui_warn "当前没有节点。"
    return 1
  fi

  ui_section "可删除节点"
  i=1
  while IFS='|' read -r proto node_name node_port value1 value2 value3 value4 value5 value6; do
    [ -n "$proto" ] || continue
    case "$proto" in
      vless-reality|hysteria2|anytls|vless-ws)
        printf ' %s%s.%s %s%s%s  protocol=%s  port=%s\n' "$C_GREEN" "$i" "$C_RESET" "$C_BOLD" "$node_name" "$C_RESET" "$proto" "$node_port"
        i=$((i + 1))
        ;;
    esac
  done < "$NODES_DB"
}

delete_node() {
  need_root
  ensure_installed

  screen_title "删除节点"
  list_nodes || return 0
  ui_dash
  printf ' %s0.%s 返回上一级\n' "$C_GREEN" "$C_RESET"
  printf ' %s99.%s 一键删除所有节点\n' "$C_GREEN" "$C_RESET"
  ui_dash
  ui_prompt "请输入要删除的节点编号："
  read -r choice || true

  case "$choice" in
    ''|*[!0-9]*)
      ui_error "请输入有效数字。"
      exit 1
      ;;
  esac

  if [ "$choice" = "0" ]; then
    ui_warn "已退出删除节点页面。"
    return 0
  fi

  if [ "$choice" = "99" ]; then
    ui_prompt "确认删除所有节点？输入 y 确认："
    read -r confirm_all || true
    case "$confirm_all" in
      y|Y|yes|YES) ;;
      *)
        ui_warn "已取消删除所有节点。"
        return 0
        ;;
    esac
    : > "$NODES_DB"
    chmod 600 "$NODES_DB"
    render_config
    restart_service
    ui_success "所有节点已删除，服务已重启。"
    return 0
  fi

  deleted="$(awk -F'|' -v n="$choice" '
    $1 == "vless-reality" || $1 == "hysteria2" || $1 == "anytls" || $1 == "vless-ws" {
      i++
      if (i == n) { print $2; exit }
    }
  ' "$NODES_DB")"
  if [ -z "$deleted" ]; then
    ui_error "未找到编号 $choice。"
    exit 1
  fi

  ui_prompt "确认删除节点 $deleted？输入 y 确认："
  read -r confirm || true
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      ui_warn "已取消删除。"
      return 0
      ;;
  esac

  tmp_file="$(make_temp "$CONFIG_DIR/nodes.XXXXXX")"
  awk -F'|' -v n="$choice" '
    $1 == "vless-reality" || $1 == "hysteria2" || $1 == "anytls" || $1 == "vless-ws" {
      i++
      if (i == n) next
    }
    { print }
  ' "$NODES_DB" > "$tmp_file"
  mv "$tmp_file" "$NODES_DB"
  chmod 600 "$NODES_DB"
  render_config
  restart_service
  ui_success "节点 $deleted 已删除，服务已重启。"
}

show_config() {
  need_root
  ensure_installed
  screen_title "查看 YAML 配置文件"
  ui_warn "配置文件路径：$CONFIG_FILE"
  ui_dash
  if command -v less >/dev/null 2>&1; then
    less "$CONFIG_FILE"
  else
    cat "$CONFIG_FILE"
  fi
}

show_logs() {
  ensure_installed
  screen_title "查看服务实时日志"
  ui_warn "按 Ctrl+C 可停止查看日志并返回终端。"
  ui_dash
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

update_script() {
  need_root
  ensure_curl

  screen_title "更新管理脚本"
  tmp_file="$(make_temp /tmp/mh-update.XXXXXX)"
  ui_warn "更新来源：$SCRIPT_RAW_URL"
  ui_section "下载最新脚本"
  curl -fsSL "$SCRIPT_RAW_URL" -o "$tmp_file" || {
    rm -f "$tmp_file"
    ui_error "更新失败：无法下载最新脚本。"
    exit 1
  }

  if ! grep -q 'mihomo 一键配置管理面板' "$tmp_file"; then
    rm -f "$tmp_file"
    ui_error "更新失败：下载内容不像 mh 脚本，已取消替换。"
    exit 1
  fi

  if ! sh -n "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    ui_error "更新失败：下载脚本语法检查未通过，已取消替换。"
    exit 1
  fi

  chmod +x "$tmp_file"
  mv "$tmp_file" "$CLI_PATH"
  ui_success "脚本更新完成。重新输入 mh 可打开新版管理面板。"
}

uninstall_all() {
  need_root
  screen_title "彻底卸载脚本"
  ui_warn "将停止服务，并删除 mihomo 内核、配置目录、日志目录和 mh 命令。"
  ui_prompt "确认卸载 mihomo、删除配置和 mh 命令？输入 y 确认："
  read -r confirm || true
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      ui_warn "已取消卸载。"
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
  ui_success "卸载完成。"
}

menu() {
  while true; do
    clear 2>/dev/null || true
    current_status="$(service_status_text)"
    
    cat <<EOF
${C_CYAN}====================================================${C_RESET}
 [*] ${C_BOLD}Mihomo 一键配置管理面板${C_RESET}
${C_CYAN}====================================================${C_RESET}
  >  ${C_BOLD}作者${C_RESET}：${C_PURPLE}${SCRIPT_AUTHOR}${C_RESET}
  >  ${C_BOLD}版本${C_RESET}：${C_PURPLE}${SCRIPT_VERSION}${C_RESET}
  >  ${C_BOLD}状态${C_RESET}：${current_status}
${C_CYAN}----------------------------------------------------${C_RESET}
 ${C_YELLOW}[+] 节点管理${C_RESET}
   ${C_GREEN}1.${C_RESET} 一键生成代理节点
   ${C_GREEN}2.${C_RESET} 查看所有节点链接
   ${C_GREEN}3.${C_RESET} 删除特定节点

 ${C_YELLOW}[+] 核心管理${C_RESET}
   ${C_GREEN}4.${C_RESET} 一键安装 Mihomo 内核
   ${C_GREEN}5.${C_RESET} 更新管理脚本
   ${C_GREEN}6.${C_RESET} 彻底卸载脚本
   
 ${C_YELLOW}[+] 服务运维${C_RESET}
   ${C_GREEN}7.${C_RESET} 查看 YAML 配置文件
   ${C_GREEN}8.${C_RESET} 重启 Mihomo 服务
   ${C_GREEN}9.${C_RESET} 查看服务实时日志
${C_CYAN}----------------------------------------------------${C_RESET}
 ${C_GREEN}0.${C_RESET} => 退出脚本面板
${C_CYAN}====================================================${C_RESET}
EOF
    printf "${C_BOLD}请输入数字选择 (0-9)：${C_RESET}"
    read -r choice || exit 0

    case "$choice" in
      1) add_node; pause ;;
      2) show_all_nodes; pause ;;
      3) delete_node; pause ;;
      4) install_core; pause ;;
      5) update_script; pause ;;
      6) uninstall_all; pause ;;
      7) show_config; pause ;;
      8) need_root; ensure_installed; clear 2>/dev/null || true; ui_title "重启 Mihomo 服务"; restart_service; ui_success "服务已重启。"; pause ;;
      9) show_logs ;;
      0) clear; exit 0 ;;
      *) ui_error "无效选择，请输入 0-9 之间的数字。"; pause ;;
    esac
  done
}

case "${1:-}" in
  install) install_core ;;
  add) add_node ;;
  list|nodes) show_all_nodes ;;
  config) show_config ;;
  delete|del|remove) delete_node ;;
  restart) need_root; ensure_installed; restart_service ;;
  logs|log) show_logs ;;
  update) update_script ;;
  uninstall) uninstall_all ;;
  *) menu ;;
esac
