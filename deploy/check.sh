#!/usr/bin/env bash
# 在临时 DESTDIR 中验证安装流程，不修改真实的 /etc、/usr/local 和 /srv。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
STAGE=$(mktemp -d -p /tmp filehub-deploy-check-XXXXXX)
SERVER_PID=
LOG_FILE="$STAGE/filehub.log"

cleanup() {
  # 测试在任意步骤退出时，都终止临时服务并移除暂存目录。
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$LOG_FILE"
  rm -rf "$STAGE"
}
trap cleanup EXIT

# 先做所有脚本的语法检查，再执行暂存安装。
bash -n "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/smoke_test.sh" \
  "$SCRIPT_DIR/load_test.sh" "$SCRIPT_DIR/run_pressure_test.sh" "$0"
DESTDIR="$STAGE" bash "$SCRIPT_DIR/install.sh" --no-start

[[ -x "$STAGE/usr/local/bin/filehub" ]]
[[ "$(stat -c '%a' "$STAGE/usr/local/bin/filehub")" == "755" ]]
[[ "$(stat -c '%a' "$STAGE/etc/filehub/filehub.conf")" == "644" ]]
[[ "$(stat -c '%a' "$STAGE/etc/systemd/system/filehub.service")" == "644" ]]
[[ "$(stat -c '%a' "$STAGE/srv/filehub/index.html")" == "644" ]]
cmp -s "$PROJECT_ROOT/filehub" "$STAGE/usr/local/bin/filehub"

# 重复安装默认必须保留管理员修改过的配置文件。
printf '\n# deployment-check local setting\n' >>"$STAGE/etc/filehub/filehub.conf"
CONFIG_HASH=$(sha256sum "$STAGE/etc/filehub/filehub.conf" | awk '{print $1}')
DESTDIR="$STAGE" bash "$SCRIPT_DIR/install.sh" --no-start
[[ "$(sha256sum "$STAGE/etc/filehub/filehub.conf" | awk '{print $1}')" == "$CONFIG_HASH" ]]

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
"$STAGE/usr/local/bin/filehub" \
  --config "$STAGE/etc/filehub/filehub.conf" \
  --port "$PORT" \
  --root "$STAGE/srv/filehub" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

READY=0
# 轮询端口和进程状态，避免固定 sleep 导致快慢机器上的偶发失败。
for _ in $(seq 1 50); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
    READY=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [[ "$READY" != 1 ]]; then
  echo "Staged FileHub did not start" >&2
  tail -40 "$LOG_FILE" >&2
  exit 1
fi

# 端口已占用时，第二个服务进程必须明确失败而不是静默运行。
if "$STAGE/usr/local/bin/filehub" \
    --port "$PORT" --root "$STAGE/srv/filehub" \
    >"$STAGE/port-conflict.log" 2>&1; then
  echo "A second FileHub unexpectedly bound the occupied port" >&2
  exit 1
fi

bash "$SCRIPT_DIR/smoke_test.sh" --url "http://127.0.0.1:$PORT"
bash "$SCRIPT_DIR/load_test.sh" \
  --no-systemd --url "http://127.0.0.1:$PORT" \
  --duration 1 --connections 1,5 \
  --output-dir "$STAGE/load-results"
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
SERVER_PID=

# 非法配置和缺失的站点根目录必须在开始服务前失败。
printf 'unknown_deployment_option=1\n' >"$STAGE/invalid.conf"
if "$STAGE/usr/local/bin/filehub" --config "$STAGE/invalid.conf" \
    >"$STAGE/invalid-config.log" 2>&1; then
  echo "FileHub unexpectedly accepted an invalid configuration" >&2
  exit 1
fi
if "$STAGE/usr/local/bin/filehub" --port "$PORT" --root "$STAGE/missing-root" \
    >"$STAGE/missing-root.log" 2>&1; then
  echo "FileHub unexpectedly accepted a missing document root" >&2
  exit 1
fi

echo "FileHub staged deployment check passed."
