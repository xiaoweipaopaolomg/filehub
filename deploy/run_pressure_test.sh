#!/usr/bin/env bash
# 部署压测包装器：临时关闭访问日志，并保证退出时恢复原值。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=/etc/filehub/filehub.conf
SERVICE=filehub.service
RESTORE_NEEDED=0

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "Cannot read deployed configuration: $CONFIG_FILE" >&2
  exit 1
fi

sudo -v

# 只修改 access_log，其余现场配置保持不变。
ORIGINAL_ACCESS_LOG=$(awk -F= '
  /^[[:space:]]*access_log[[:space:]]*=/ {
    gsub(/[[:space:]]/, "", $2)
    print $2
    exit
  }' "$CONFIG_FILE")

restore_access_log() {
  if ((RESTORE_NEEDED)); then
    echo "Restoring access_log=$ORIGINAL_ACCESS_LOG"
    sudo sed -i -E \
      "s/^[[:space:]]*access_log[[:space:]]*=.*/access_log=$ORIGINAL_ACCESS_LOG/" \
      "$CONFIG_FILE"
    sudo systemctl reload "$SERVICE"
  fi
}
# EXIT 同时覆盖成功、普通失败和显式 exit；INT/TERM 先转换为退出码再触发恢复。
trap restore_access_log EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$ORIGINAL_ACCESS_LOG" == "1" ]]; then
  echo "Temporarily disabling per-request access logging for pressure testing."
  sudo sed -i -E \
    's/^[[:space:]]*access_log[[:space:]]*=.*/access_log=0/' \
    "$CONFIG_FILE"
  sudo systemctl reload "$SERVICE"
  # 只有完成修改后才置位，避免前序失败时执行不必要的恢复操作。
  RESTORE_NEEDED=1
  sleep 1
fi

bash "$SCRIPT_DIR/load_test.sh" "$@"
