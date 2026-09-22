#!/usr/bin/env bash
# 对已部署服务执行阶梯并发压测，并把原始数据和资源快照落盘。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
URL=http://127.0.0.1:8080
TARGET_PATH=/info.html
DURATION=15
CONNECTIONS=10,50,100,200
THREADS=4
SERVICE=filehub.service
CONFIG_FILE=/etc/filehub/filehub.conf
CHECK_SYSTEMD=1
OUTPUT_DIR=

usage() {
  cat <<'EOF'
Usage: bash deploy/load_test.sh [options]

Options:
  --url URL              Base URL (default: http://127.0.0.1:8080)
  --path PATH            File path to request (default: /info.html)
  --duration SECONDS     Duration per concurrency level (default: 15)
  --connections LIST     Comma-separated levels (default: 10,50,100,200)
  --threads N            Maximum wrk threads (default: 4)
  --service NAME         systemd unit (default: filehub.service)
  --config FILE         Deployed config (default: /etc/filehub/filehub.conf)
  --output-dir DIR       Result directory
  --no-systemd           Skip process/systemd checks (test use only)

The default run lasts about one minute and expects zero socket errors and
zero non-2xx responses at every level.
EOF
}

while (($#)); do
  case "$1" in
    --url) URL=${2%/}; shift ;;
    --path) TARGET_PATH=$2; shift ;;
    --duration) DURATION=$2; shift ;;
    --connections) CONNECTIONS=$2; shift ;;
    --threads) THREADS=$2; shift ;;
    --service) SERVICE=$2; shift ;;
    --config) CONFIG_FILE=$2; shift ;;
    --output-dir) OUTPUT_DIR=$2; shift ;;
    --no-systemd) CHECK_SYSTEMD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# 在产生结果目录或发起网络请求前，集中完成参数校验。
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || {
  echo "--duration must be a positive integer" >&2
  exit 2
}
[[ "$THREADS" =~ ^[1-9][0-9]*$ ]] || {
  echo "--threads must be a positive integer" >&2
  exit 2
}
[[ "$TARGET_PATH" == /* ]] || {
  echo "--path must begin with /" >&2
  exit 2
}

# 优先使用当前环境中的 wrk；未激活环境时兼容固定的 conda 安装位置。
if command -v wrk >/dev/null; then
  WRK=$(command -v wrk)
elif [[ -x "$HOME/miniconda3/envs/filehub-test/bin/wrk" ]]; then
  WRK="$HOME/miniconda3/envs/filehub-test/bin/wrk"
else
  echo "wrk was not found; activate filehub-test first" >&2
  exit 1
fi
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }

if [[ -z "$OUTPUT_DIR" ]]; then
  # 每次测试使用独立时间戳目录，保留历史结果用于趋势对比。
  OUTPUT_DIR="$PROJECT_ROOT/tests/results/deployment-pressure-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"

shopt -s nullglob

# /proc 中 VmRSS 的单位为 KiB；读取失败用 -1 表示。
rss_kb() {
  awk '/^VmRSS:/ {print $2; found=1} END {if (!found) print -1}' "/proc/$1/status"
}

# 普通用户无权读取目标 /proc 目录时，尝试复用已有的 sudo 凭据。
fd_count() {
  if [[ -r "/proc/$1/fd" ]]; then
    local entries=("/proc/$1/fd"/*)
    printf '%s\n' "${#entries[@]}"
  elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    sudo -n find "/proc/$1/fd" -mindepth 1 -maxdepth 1 -printf '.' \
      2>/dev/null | wc -c
  else
    printf '%s\n' -1
  fi
}

PID=0
RESTARTS_BEFORE=not-checked
RSS_BEFORE=not-checked
FD_BEFORE=not-checked
if ((CHECK_SYSTEMD)); then
  # 高频逐请求日志会严重扰动性能并灌满 journal，因此部署压测要求关闭它。
  if [[ -r "$CONFIG_FILE" ]]; then
    ACCESS_LOG=$(awk -F= '
      /^[[:space:]]*access_log[[:space:]]*=/ {
        gsub(/[[:space:]]/, "", $2)
        print $2
        exit
      }' "$CONFIG_FILE")
    if [[ "$ACCESS_LOG" == "1" ]]; then
      echo "Refusing a high-rate test while access_log=1." >&2
      echo "Temporarily set access_log=0 and reload $SERVICE first." >&2
      exit 2
    fi
  fi
  systemctl is-active --quiet "$SERVICE" || {
    echo "$SERVICE is not active" >&2
    exit 1
  }
  PID=$(systemctl show -p MainPID --value "$SERVICE")
  [[ "$PID" =~ ^[1-9][0-9]*$ && -r "/proc/$PID/status" ]] || {
    echo "Cannot inspect MainPID for $SERVICE" >&2
    exit 1
  }
  SERVICE_USER=$(ps -o user= -p "$PID" | tr -d ' ')
  # 生产验收必须确认进程没有意外以当前用户或 root 身份运行。
  [[ "$SERVICE_USER" == "www-data" ]] || {
    echo "$SERVICE is running as $SERVICE_USER instead of www-data" >&2
    exit 1
  }
  RESTARTS_BEFORE=$(systemctl show -p NRestarts --value "$SERVICE")
  RSS_BEFORE=$(rss_kb "$PID")
  FD_BEFORE=$(fd_count "$PID")
fi

TARGET_URL="$URL$TARGET_PATH"
# 记录压测前的响应哈希；每个并发级别结束后重新校验内容完整性。
EXPECTED_HASH=$(curl -fsS "$TARGET_URL" | sha256sum | awk '{print $1}')
curl -fsS "$URL/status" | grep -q '"total_requests"'

START_EPOCH=$(date +%s)
{
  echo "url=$URL"
  echo "target_path=$TARGET_PATH"
  echo "duration_seconds=$DURATION"
  echo "connections=$CONNECTIONS"
  echo "threads_max=$THREADS"
  echo "wrk=$WRK"
  echo "service=$SERVICE"
  echo "pid_before=$PID"
  echo "restarts_before=$RESTARTS_BEFORE"
  echo "rss_kb_before=$RSS_BEFORE"
  echo "fd_before=$FD_BEFORE"
  echo "expected_sha256=$EXPECTED_HASH"
} >"$OUTPUT_DIR/metadata.txt"

echo "Warm-up: 3 seconds, 10 connections"
# 预热连接处理路径和页缓存，预热输出不计入正式结果。
"$WRK" -t2 -c10 -d3s "$TARGET_URL" >"$OUTPUT_DIR/warmup.txt"

IFS=, read -r -a LEVELS <<<"$CONNECTIONS"
# 按并发级别串行执行，便于观察吞吐平台和延迟拐点。
for CONNECTION_COUNT in "${LEVELS[@]}"; do
  [[ "$CONNECTION_COUNT" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid connection count: $CONNECTION_COUNT" >&2
    exit 2
  }
  CURRENT_THREADS=$THREADS
  if ((CONNECTION_COUNT < CURRENT_THREADS)); then
    CURRENT_THREADS=$CONNECTION_COUNT
  fi
  RESULT="$OUTPUT_DIR/c$CONNECTION_COUNT.txt"
  echo "Pressure: c=$CONNECTION_COUNT, t=$CURRENT_THREADS, d=${DURATION}s"
  "$WRK" -t"$CURRENT_THREADS" -c"$CONNECTION_COUNT" \
    -d"${DURATION}s" --latency "$TARGET_URL" | tee "$RESULT"

  # wrk 只在计数非零时打印错误行，出现即判定该级别失败。
  if grep -q '^Socket errors:' "$RESULT"; then
    echo "wrk reported socket errors at c=$CONNECTION_COUNT" >&2
    exit 1
  fi
  if grep -q '^Non-2xx or 3xx responses:' "$RESULT"; then
    echo "wrk reported non-2xx responses at c=$CONNECTION_COUNT" >&2
    exit 1
  fi
  ACTUAL_HASH=$(curl -fsS "$TARGET_URL" | sha256sum | awk '{print $1}')
  [[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || {
    echo "Response hash changed at c=$CONNECTION_COUNT" >&2
    exit 1
  }
  curl -fsS "$URL/status" | grep -q '"active_connections"'

  if ((CHECK_SYSTEMD)); then
    systemctl is-active --quiet "$SERVICE"
    CURRENT_PID=$(systemctl show -p MainPID --value "$SERVICE")
    [[ "$CURRENT_PID" == "$PID" ]] || {
      echo "$SERVICE restarted during the pressure test" >&2
      exit 1
    }
  fi
done

sleep 2
# 压力结束后重新覆盖核心协议功能，防止服务“仍存活但已异常”。
bash "$SCRIPT_DIR/smoke_test.sh" --url "$URL"

if ((CHECK_SYSTEMD)); then
  RESTARTS_AFTER=$(systemctl show -p NRestarts --value "$SERVICE")
  RSS_AFTER=$(rss_kb "$PID")
  FD_AFTER=$(fd_count "$PID")
  [[ "$RESTARTS_AFTER" == "$RESTARTS_BEFORE" ]] || {
    echo "$SERVICE restart count changed: $RESTARTS_BEFORE -> $RESTARTS_AFTER" >&2
    exit 1
  }
  # 允许少量瞬时波动，但连接 FD 必须基本回落到基线。
  if ((FD_BEFORE >= 0 && FD_AFTER >= 0)); then
    ((FD_AFTER <= FD_BEFORE + 4)) || {
      echo "FD count did not return near baseline: $FD_BEFORE -> $FD_AFTER" >&2
      exit 1
    }
  else
    echo "FD check skipped: run 'sudo -v' before the test to grant /proc access."
  fi
  # 短时压测允许 16 MiB 内的缓存/分配器波动，超出则视为异常增长。
  ((RSS_AFTER <= RSS_BEFORE + 16384)) || {
    echo "RSS grew by more than 16 MiB: $RSS_BEFORE -> $RSS_AFTER KiB" >&2
    exit 1
  }
  # 保存测试窗口内的服务日志，失败后可与具体时间段对应排查。
  journalctl -u "$SERVICE" --since "@$START_EPOCH" --no-pager \
    >"$OUTPUT_DIR/journal.txt" || true
else
  RESTARTS_AFTER=not-checked
  RSS_AFTER=not-checked
  FD_AFTER=not-checked
fi

{
  echo "restarts_after=$RESTARTS_AFTER"
  echo "rss_kb_after=$RSS_AFTER"
  echo "fd_after=$FD_AFTER"
  echo "result=PASS"
} | tee "$OUTPUT_DIR/summary.txt"

echo "Deployment pressure test passed."
echo "Results: $OUTPUT_DIR"
