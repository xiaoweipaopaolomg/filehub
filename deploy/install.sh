#!/usr/bin/env bash
# FileHub 的可重复安装脚本；支持真实系统安装和非特权暂存安装。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
DESTDIR=${DESTDIR:-}
NO_START=0
FORCE_CONFIG=0

usage() {
  cat <<'EOF'
Usage: sudo bash deploy/install.sh [--no-start] [--force-config]

Options:
  --no-start      Install files but do not enable or start the systemd service.
  --force-config  Replace an existing /etc/filehub/filehub.conf.

For a non-root staged installation:
  DESTDIR=/tmp/filehub-stage bash deploy/install.sh --no-start
EOF
}

while (($#)); do
  case "$1" in
    --no-start) NO_START=1 ;;
    --force-config) FORCE_CONFIG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$DESTDIR" ]]; then
  # DESTDIR 只能指向明确的绝对目录，禁止误把暂存安装写入根目录。
  [[ "$DESTDIR" = /* && "$DESTDIR" != "/" ]] || {
    echo "DESTDIR must be an absolute path other than /" >&2
    exit 2
  }
  NO_START=1
elif ((EUID != 0)); then
  echo "System installation requires root; run with sudo." >&2
  echo "Use DESTDIR=/absolute/path for a non-root staged installation." >&2
  exit 1
fi

# 在复制文件前完成依赖与目标环境检查，避免留下半安装状态。
command -v install >/dev/null || {
  echo "The coreutils install command is required" >&2
  exit 1
}
if [[ -z "$DESTDIR" ]]; then
  command -v systemctl >/dev/null || {
    echo "systemctl is required for a system installation" >&2
    exit 1
  }
  command -v curl >/dev/null || {
    echo "curl is required for the post-install smoke test" >&2
    exit 1
  }
  [[ -d /run/systemd/system ]] || {
    echo "systemd is not the active system manager on this machine" >&2
    exit 1
  }
  getent passwd www-data >/dev/null || {
    echo "Required service user www-data does not exist" >&2
    exit 1
  }
  getent group www-data >/dev/null || {
    echo "Required service group www-data does not exist" >&2
    exit 1
  }
fi

[[ -x "$PROJECT_ROOT/filehub" ]] || {
  echo "Missing executable: $PROJECT_ROOT/filehub" >&2
  echo "Run 'make clean all' before installing." >&2
  exit 1
}

# 为系统绝对路径添加可选的暂存前缀。
target() {
  printf '%s%s' "$DESTDIR" "$1"
}

BIN_DIR=$(target /usr/local/bin)
CONF_DIR=$(target /etc/filehub)
UNIT_DIR=$(target /etc/systemd/system)
DOC_ROOT=$(target /srv/filehub)
CONF_FILE="$CONF_DIR/filehub.conf"
UNIT_FILE="$UNIT_DIR/filehub.service"

install -d -m 0755 "$BIN_DIR" "$CONF_DIR" "$UNIT_DIR" "$DOC_ROOT"

# 先写同目录临时文件再 rename，避免服务读到只复制了一部分的可执行文件。
BINARY_TMP="$BIN_DIR/.filehub.install.$$"
trap 'rm -f "$BINARY_TMP"' EXIT
install -m 0755 "$PROJECT_ROOT/filehub" "$BINARY_TMP"
mv -f "$BINARY_TMP" "$BIN_DIR/filehub"
trap - EXIT
install -m 0644 "$SCRIPT_DIR/filehub.service" "$UNIT_FILE"

# 除非明确指定 --force-config，否则升级时保留现场配置。
if [[ ! -e "$CONF_FILE" || "$FORCE_CONFIG" -eq 1 ]]; then
  install -m 0644 "$SCRIPT_DIR/filehub.conf.example" "$CONF_FILE"
  echo "Installed configuration: $CONF_FILE"
else
  echo "Preserved existing configuration: $CONF_FILE"
fi

# 示例站点文件同样只在不存在时安装，避免覆盖用户发布的内容。
if [[ ! -e "$DOC_ROOT/index.html" ]]; then
  install -m 0644 "$PROJECT_ROOT/docroot/index.html" "$DOC_ROOT/index.html"
fi
if [[ ! -e "$DOC_ROOT/info.html" ]]; then
  install -m 0644 "$PROJECT_ROOT/docroot/info.html" "$DOC_ROOT/info.html"
fi

echo "Installed binary:       $BIN_DIR/filehub"
echo "Installed service unit: $UNIT_FILE"
echo "Document root:          $DOC_ROOT"

if [[ -n "$DESTDIR" ]]; then
  echo "Staged installation complete; systemd was not modified."
  exit 0
fi

# 在通知 systemd 前校验 unit 语法；工具不存在时保持兼容。
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$UNIT_FILE"
fi
systemctl daemon-reload

if ((NO_START)); then
  echo "Files installed. Start later with:"
  echo "  sudo systemctl enable --now filehub.service"
else
  systemctl enable filehub.service
  systemctl restart filehub.service
  systemctl --no-pager --full status filehub.service
  # 从最终配置读取端口，确保冒烟测试命中实际部署实例。
  LISTEN_PORT=$(awk -F= '
    /^[[:space:]]*listen_port[[:space:]]*=/ {
      gsub(/[[:space:]]/, "", $2)
      print $2
      exit
    }' "$CONF_FILE")
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || {
    echo "Could not determine listen_port from $CONF_FILE" >&2
    exit 1
  }
  "$SCRIPT_DIR/smoke_test.sh" \
    --url "http://127.0.0.1:$LISTEN_PORT" --systemd
fi
