#!/usr/bin/env bash
# 在 Valgrind 下启动服务并执行一组最小请求，退出后展示内存检查摘要。
set -euo pipefail

command -v valgrind >/dev/null || { echo "valgrind is not installed" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is not installed" >&2; exit 2; }

PORT=${1:-4321}
ROOT=${2:-./docroot}
LOG=$(mktemp)
PID=''
cleanup() {
  # 测试中断或失败时不遗留 Valgrind 子进程和临时日志。
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes \
  ./filehub --port "$PORT" --root "$ROOT" >"$LOG" 2>&1 &
PID=$!

ready=0
# Valgrind 启动明显慢于原生进程，因此轮询最长等待 10 秒。
for _ in $(seq 1 40); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 0.25
done
if [[ "$ready" != 1 ]]; then
  echo "FileHub did not start" >&2
  tail -40 "$LOG" >&2
  exit 1
fi

curl -fsS "http://127.0.0.1:$PORT/" >/dev/null
# 同时覆盖成功、404 和 405 响应的资源释放路径。
curl -sS -o /dev/null "http://127.0.0.1:$PORT/not-found"
curl -sS -o /dev/null -X POST "http://127.0.0.1:$PORT/"
kill -TERM "$PID"
wait "$PID"
PID=''
tail -40 "$LOG"
