#!/usr/bin/env bash
# 对运行中的 FileHub 执行快速、无破坏性的部署验收。
set -euo pipefail

URL=http://127.0.0.1:8080
CHECK_SYSTEMD=0

usage() {
  cat <<'EOF'
Usage: bash deploy/smoke_test.sh [--url URL] [--systemd]

Checks the root page, HEAD, Range, /status, /metrics and method rejection.
--systemd additionally requires filehub.service to be active as www-data.
EOF
}

while (($#)); do
  case "$1" in
    --url)
      (($# >= 2)) || { echo "--url requires a value" >&2; exit 2; }
      URL=${2%/}
      shift
      ;;
    --systemd) CHECK_SYSTEMD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v curl >/dev/null || {
  echo "curl is required" >&2
  exit 1
}

if ((CHECK_SYSTEMD)); then
  # 除服务存活外，还要确认 systemd unit 使用预期的低权限账户。
  systemctl is-active --quiet filehub.service
  [[ "$(systemctl show -p User --value filehub.service)" == "www-data" ]] || {
    echo "filehub.service is not configured to run as www-data" >&2
    exit 1
  }
fi

# 基础 GET：确认根页面可访问。
ROOT_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' "$URL/")
[[ "$ROOT_STATUS" == "200" ]] || {
  echo "GET / returned HTTP $ROOT_STATUS" >&2
  exit 1
}

# HEAD：确认不下载正文时仍返回正确状态和内容长度。
HEADERS=$(curl -sSI "$URL/")
grep -q '^HTTP/1.1 200 ' <<<"$HEADERS"
grep -qi '^Content-Length:' <<<"$HEADERS"

# 可观测性端点：检查 JSON 状态和 Prometheus 文本指标的关键字段。
STATUS_BODY=$(curl -fsS "$URL/status")
grep -q '"active_connections"' <<<"$STATUS_BODY"
grep -q '"total_requests"' <<<"$STATUS_BODY"

METRICS_BODY=$(curl -fsS "$URL/metrics")
grep -q '^filehub_requests_total ' <<<"$METRICS_BODY"
grep -q '^filehub_bytes_sent_total ' <<<"$METRICS_BODY"

# 方法约束：静态服务必须拒绝 POST。
POST_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$URL/")
[[ "$POST_STATUS" == "405" ]] || {
  echo "POST / returned HTTP $POST_STATUS instead of 405" >&2
  exit 1
}

# 断点下载：请求前 4 字节并核对 206 与 Content-Range。
RANGE_HEADERS=$(curl -sS -D - -o /dev/null -H 'Range: bytes=0-3' "$URL/info.html")
grep -q '^HTTP/1.1 206 ' <<<"$RANGE_HEADERS"
grep -qi '^Content-Range: bytes 0-3/' <<<"$RANGE_HEADERS"

echo "FileHub deployment smoke test passed: $URL"
