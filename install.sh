#!/bin/sh

set -u

RAW_BASE="${MH_RAW_BASE:-https://raw.githubusercontent.com/YOUR_GITHUB_USER/mihomo-onekey/main}"
CLI_PATH="/usr/local/bin/mh"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请使用 root 权限运行安装脚本：curl -fsSL <install.sh> | sudo sh"
    exit 1
  fi
}

install_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl
  else
    red "未找到 apk 或 apt-get，无法自动安装 curl。"
    exit 1
  fi
}

need_root
install_curl

if [ -f "./mh.sh" ]; then
  cp ./mh.sh "$CLI_PATH"
else
  curl -fsSL "$RAW_BASE/mh.sh" -o "$CLI_PATH"
fi

chmod +x "$CLI_PATH"
green "安装完成。现在可以输入 mh 打开管理面板。"
