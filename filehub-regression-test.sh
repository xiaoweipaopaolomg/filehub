#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  FileHub 累积回归测试入口
#  从 TRD-00 开始，依次运行到命令行指定的 TRD 阶段。
#
#  用法：./filehub-regression-test.sh <trd-number>
#  示例：./filehub-regression-test.sh 3
#        ./filehub-regression-test.sh 5
# ═══════════════════════════════════════════════════════════
set -euo pipefail

# ── 终端颜色 ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── 参数与帮助 ───────────────────────────────────────────
if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: ./test-suite <trd-number>"
  echo ""
  echo "  trd-number   0–7 (runs all tests from TRD-00 through TRD-N)"
  echo "  Requires a Makefile that produces ./filehub"
  echo ""
  echo "Examples:"
  echo "  ./test-suite 1    # test TRD-00 + TRD-01"
  echo "  ./test-suite 5    # test TRD-00 through TRD-05"
  exit 0
fi

TRD_LEVEL="$1"

# 只接受脚本实际实现的阶段，避免算术比较时出现歧义。
if [[ "$TRD_LEVEL" -lt 0 || "$TRD_LEVEL" -gt 7 ]]; then
  echo "Error: TRD level must be 0–7"; exit 1
fi

# ── 测试状态 ─────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
TOTAL=0
PORT=$(( (RANDOM % 10000) + 20000 ))
BINARY="./filehub"
SERVER_PID=""
DOCROOT=""
TMPOUT=""

pass() { echo -e "    ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
fail() { echo -e "    ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
skip() { echo -e "    ${YELLOW}–${NC} $1"; SKIP=$((SKIP + 1)); TOTAL=$((TOTAL + 1)); }
group() { echo -e "\n  ${CYAN}${BOLD}[$1]${NC} ${BOLD}$2${NC}"; }

cleanup() {
  # 无论成功或失败，都停止服务并删除带特殊权限的临时目录。
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
  fi
  [[ -n "$DOCROOT" ]] && { chmod -R u+rwX "$DOCROOT" 2>/dev/null || true; rm -rf "$DOCROOT"; }
  [[ -n "$TMPOUT" ]] && rm -rf "$TMPOUT"
}
trap cleanup EXIT

# ── 测试数据准备 ─────────────────────────────────────────
DOCROOT=$(mktemp -d)
TMPOUT=$(mktemp -d)

echo '<!DOCTYPE html><html><body>FileHub Index</body></html>' > "$DOCROOT/index.html"
echo '<html><body>Test Page</body></html>'   > "$DOCROOT/test.html"
echo 'body { color: black; }'               > "$DOCROOT/style.css"
echo 'console.log("filehub");'              > "$DOCROOT/script.js"
echo 'plain text content'                   > "$DOCROOT/hello.txt"
mkdir -p "$DOCROOT/subdir"
echo '<html><body>Nested</body></html>'     > "$DOCROOT/subdir/nested.html"
dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' 'X' > "$DOCROOT/large.bin"
echo 'secret' > "$DOCROOT/noperm.txt"
chmod 000 "$DOCROOT/noperm.txt"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  FileHub Cumulative Test Runner${NC}"
echo -e "${BOLD}  Testing: TRD-00 through TRD-$(printf '%02d' "$TRD_LEVEL")${NC}"
echo -e "${BOLD}  Port:    $PORT${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"

# ── 使用 Makefile 编译 ───────────────────────────────────
group "BUILD" "Compilation"

if [[ ! -f "Makefile" ]]; then
  fail "Makefile not found — required for multi-file builds"
  exit 1
fi

REQUIRED_FLAGS="-Wall -Wextra -Werror -pedantic"
# 线程池阶段开始要求显式启用 pthread 编译与链接选项。
if [[ "$TRD_LEVEL" -ge 5 ]]; then
  REQUIRED_FLAGS="$REQUIRED_FLAGS -pthread"
fi
for FLAG in $REQUIRED_FLAGS; do
  if ! grep -q -- "$FLAG" Makefile; then
    fail "Makefile missing required flag: $FLAG"
    exit 1
  fi
done

make clean > /dev/null 2>&1 || true
if make > /dev/null 2>&1 && [[ -x "$BINARY" ]]; then
  pass "Compiles via Makefile"
else
  fail "Compilation failed — cannot continue"
  exit 1
fi

# ── 启动被测服务 ─────────────────────────────────────────
# TRD-00/01 沿用早期单参数接口，其余阶段传入独立 document root。
if [[ "$TRD_LEVEL" -le 1 ]]; then
  $BINARY "$PORT" &
else
  $BINARY "$PORT" "$DOCROOT" &
fi
SERVER_PID=$!
sleep 0.5

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  fail "Server failed to start"; exit 1
fi

# ── 公共断言 ─────────────────────────────────────────────
assert_alive() {
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "SERVER CRASHED — aborting"; exit 1
  fi
}

# ═════════════════════════════════════════════════════════
#  TRD-00：TCP 基础与响应完整性
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 0 ]]; then
  group "TRD-00" "TCP Foundation"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$STATUS" == "200" ]] && pass "GET / → 200" || fail "GET / → $STATUS"

  BODY=$(curl -s "http://localhost:$PORT/" 2>/dev/null || echo "")
  [[ -n "$BODY" ]] && pass "Response has body (${#BODY} bytes)" || fail "Empty body"

  CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')
  BL=$(curl -s "http://localhost:$PORT/" 2>/dev/null | wc -c | tr -d ' ')
  [[ -n "$CL" && "$CL" == "$BL" ]] && pass "Content-Length ($CL) matches body" || fail "Content-Length mismatch ($CL vs $BL)"

  S1=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  S2=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$S1" == "200" && "$S2" == "200" ]] && pass "Sequential requests work" || fail "Sequential: $S1, $S2"
fi

# ═════════════════════════════════════════════════════════
#  TRD-01：HTTP 请求解析
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 1 ]]; then
  group "TRD-01" "HTTP Request Parsing"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent" 2>/dev/null || echo "000")
  [[ "$STATUS" == "404" ]] && pass "GET /nonexistent → 404" || fail "GET /nonexistent → $STATUS"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$STATUS" == "405" ]] && pass "POST / → 405" || fail "POST / → $STATUS"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$STATUS" == "405" ]] && pass "DELETE / → 405" || fail "DELETE / → $STATUS"

  RESP=$(echo -ne "GARBAGE\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
  echo "$RESP" | grep -q "400" && pass "Garbage request → 400" || fail "Garbage did not → 400"

  RESP=$(echo -ne "GET / HTTP/2.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
  echo "$RESP" | grep -q "400" && pass "HTTP/2.0 → 400" || fail "HTTP/2.0 did not → 400"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Custom: test" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$STATUS" == "200" ]] && pass "Extra headers don't break parsing" || fail "Extra headers → $STATUS"

  assert_alive
fi

# ═════════════════════════════════════════════════════════
#  TRD-02：静态文件服务与路径安全
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 2 ]]; then
  group "TRD-02" "Static File Serving"

  BODY=$(curl -s "http://localhost:$PORT/" 2>/dev/null || echo "")
  EXPECTED=$(cat "$DOCROOT/index.html")
  [[ "$BODY" == "$EXPECTED" ]] && pass "GET / serves index.html" || fail "GET / body mismatch"

  CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/style.css" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
  echo "$CT" | grep -qi "text/css" && pass ".css → text/css" || fail ".css → $CT"

  CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/script.js" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
  echo "$CT" | grep -qiE "(application/javascript|text/javascript)" && pass ".js → javascript" || fail ".js → $CT"

  CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/hello.txt" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
  echo "$CT" | grep -qi "text/plain" && pass ".txt → text/plain" || fail ".txt → $CT"

  RESP=$(echo -ne "GET /../../../etc/passwd HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
  echo "$RESP" | grep -q "403" && pass "Directory traversal → 403" || fail "Traversal not blocked"

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/subdir/nested.html" 2>/dev/null || echo "000")
  [[ "$STATUS" == "200" ]] && pass "Subdirectory serving → 200" || fail "Subdirectory → $STATUS"

  CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')
  FS=$(wc -c < "$DOCROOT/index.html" | tr -d ' ')
  [[ -n "$CL" && "$CL" == "$FS" ]] && pass "Content-Length matches file size" || fail "CL=$CL vs file=$FS"

  assert_alive
fi

# ═════════════════════════════════════════════════════════
#  TRD-03：响应生成与错误处理
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 3 ]]; then
  group "TRD-03" "Response Engine"

  LINE=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null | head -1 | tr -d '\r')
  [[ "$LINE" =~ ^HTTP/1\.1\ 200\  ]] && pass "200 has valid status line" || fail "200 line: $LINE"

  LINE=$(curl -s -D - -o /dev/null "http://localhost:$PORT/nope" 2>/dev/null | head -1 | tr -d '\r')
  [[ "$LINE" =~ ^HTTP/1\.1\ 404\  ]] && pass "404 has valid status line" || fail "404 line: $LINE"

  HDRS=$(curl -s -D - -o /dev/null "http://localhost:$PORT/nope" 2>/dev/null)
  HCT=$(echo "$HDRS" | grep -ci "Content-Type" || true)
  HCL=$(echo "$HDRS" | grep -ci "Content-Length" || true)
  [[ "$HCT" -ge 1 && "$HCL" -ge 1 ]] && pass "Error responses have CT + CL" || fail "Error missing headers"

  B404=$(curl -s "http://localhost:$PORT/nope" 2>/dev/null || echo "")
  B405=$(curl -s -X POST "http://localhost:$PORT/" 2>/dev/null || echo "")
  [[ -n "$B404" && -n "$B405" ]] && pass "Error bodies non-empty" || fail "Empty error body"

  CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/nope" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')
  BL=$(curl -s "http://localhost:$PORT/nope" 2>/dev/null | wc -c | tr -d ' ')
  [[ -n "$CL" && "$CL" == "$BL" ]] && pass "Error CL matches body" || fail "Error CL=$CL vs body=$BL"

  if [[ "$(id -u)" != "0" ]]; then
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/noperm.txt" 2>/dev/null || echo "000")
    [[ "$STATUS" == "403" ]] && pass "Permission denied → 403" || fail "Permission denied → $STATUS"
  else
    skip "Permission test (running as root)"
  fi

  assert_alive
fi

# ═════════════════════════════════════════════════════════
#  TRD-04：epoll 事件循环
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 4 ]]; then
  group "TRD-04" "Epoll Event Loop"

  (
    for i in $(seq 1 10); do
      curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/c_$i" 2>/dev/null &
    done
    wait
  )
  C_OK=0
  for i in $(seq 1 10); do
    R=$(cat "$TMPOUT/c_$i" 2>/dev/null || echo "000")
    [[ "$R" == "200" ]] && C_OK=$((C_OK + 1))
  done
  [[ "$C_OK" -eq 10 ]] && pass "10 concurrent → all 200" || fail "$C_OK/10 concurrent → 200"

  EXPECTED_SZ=$(wc -c < "$DOCROOT/large.bin" | tr -d ' ')
  curl -s "http://localhost:$PORT/large.bin" -o "$TMPOUT/lg_dl" 2>/dev/null || true
  DL_SZ=$(wc -c < "$TMPOUT/lg_dl" 2>/dev/null | tr -d ' ')
  [[ "$DL_SZ" == "$EXPECTED_SZ" ]] && pass "Large file (256 KB) served correctly" || fail "Large file: expected=$EXPECTED_SZ got=$DL_SZ"

  # 慢客户端分段发送请求时，普通客户端仍应在 2 秒内得到响应。
  (echo -ne "GET / HTTP/1.1\r\n"; sleep 3; echo -ne "Host: localhost\r\n\r\n") | nc -w 5 localhost "$PORT" > /dev/null 2>&1 &
  SLOW_PID=$!
  sleep 0.3
  FAST=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  kill "$SLOW_PID" 2>/dev/null || true; wait "$SLOW_PID" 2>/dev/null || true
  [[ "$FAST" == "200" ]] && pass "Slow client doesn't block fast client" || fail "Fast client → $FAST (blocking?)"

  # 连续请求前后 FD 数允许小范围瞬时波动，但不能持续增长。
  if [[ -d "/proc/$SERVER_PID/fd" ]]; then
    FDB=$(ls "/proc/$SERVER_PID/fd" 2>/dev/null | wc -l)
    for i in $(seq 1 50); do curl -s -o /dev/null "http://localhost:$PORT/" 2>/dev/null || true; done
    sleep 1
    FDA=$(ls "/proc/$SERVER_PID/fd" 2>/dev/null | wc -l)
    DIFF=$((FDA - FDB))
    [[ "$DIFF" -ge -3 && "$DIFF" -le 3 ]] && pass "No fd leaks (diff=$DIFF)" || fail "FD leak (before=$FDB after=$FDA)"
  else
    skip "FD leak check (/proc not accessible)"
  fi

  assert_alive
fi

# ═════════════════════════════════════════════════════════
#  TRD-05：线程池与混合并发
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 5 ]]; then
  group "TRD-05" "Thread Pool"

  (
    for i in $(seq 1 50); do
      curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/c50_$i" 2>/dev/null &
    done
    wait
  )
  C50=0
  for i in $(seq 1 50); do
    R=$(cat "$TMPOUT/c50_$i" 2>/dev/null || echo "000")
    [[ "$R" == "200" ]] && C50=$((C50 + 1))
  done
  [[ "$C50" -ge 45 ]] && pass "50 concurrent: $C50/50 → 200" || fail "$C50/50 concurrent"

  (
    curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/"     > "$TMPOUT/mx1" 2>/dev/null &
    curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nope" > "$TMPOUT/mx2" 2>/dev/null &
    curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" > "$TMPOUT/mx3" 2>/dev/null &
    wait
  )
  MX1=$(cat "$TMPOUT/mx1" 2>/dev/null || echo "000")
  MX2=$(cat "$TMPOUT/mx2" 2>/dev/null || echo "000")
  MX3=$(cat "$TMPOUT/mx3" 2>/dev/null || echo "000")
  [[ "$MX1" == "200" && "$MX2" == "404" && "$MX3" == "405" ]] \
    && pass "Mixed concurrent: 200, 404, 405" || fail "Mixed: $MX1, $MX2, $MX3"

  S100=0
  for i in $(seq 1 100); do
    S=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
    [[ "$S" == "200" ]] && S100=$((S100 + 1))
  done
  [[ "$S100" -eq 100 ]] && pass "100 sequential → all 200" || fail "$S100/100 sequential"

  assert_alive
fi

# ═════════════════════════════════════════════════════════
#  TRD-06：异常输入与鲁棒性加固
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 6 ]]; then
  group "TRD-06" "Hardening"

  HUGE=$(head -c 16000 /dev/zero | tr '\0' 'A')
  RESP=$(echo -ne "GET / HTTP/1.1\r\nHost: localhost\r\nX-Huge: ${HUGE}\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
  echo "$RESP" | grep -q "400" && pass "Oversized request → 400" || fail "Oversized not rejected"
  assert_alive

  # 下载刚开始就批量断连，覆盖 EPIPE/SIGPIPE 清理路径。
  (
    for i in $(seq 1 10); do
      echo -ne "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n" | \
        nc -w 1 localhost "$PORT" > /dev/null 2>&1 &
    done
    sleep 0.3
    kill $(jobs -p) 2>/dev/null || true
    wait 2>/dev/null || true
  )
  sleep 0.5
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$STATUS" == "200" ]] && pass "Survived SIGPIPE (still serving)" || fail "SIGPIPE may have crashed server ($STATUS)"
  assert_alive

  # 建立后不发送请求即断开，验证空连接不会积累。
  (
    for i in $(seq 1 50); do
      nc -w 1 localhost "$PORT" < /dev/null > /dev/null 2>&1 &
    done
    wait 2>/dev/null || true
  )
  sleep 0.5
  assert_alive
  pass "Survived 50 connect/disconnect"

  for i in $(seq 1 10); do
    echo -ne "GARBAGE_$i\r\n\r\n" | nc -w 1 localhost "$PORT" > /dev/null 2>&1 || true
  done
  sleep 0.5
  assert_alive
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  [[ "$STATUS" == "200" ]] && pass "Functional after malformed barrage" || fail "Degraded after barrage ($STATUS)"
fi

# ═════════════════════════════════════════════════════════
#  SIGTERM：会终止服务，必须作为最后一项功能测试
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 5 ]]; then
  group "SHUTDOWN" "Graceful Exit"

  kill -TERM "$SERVER_PID" 2>/dev/null || true
  WAITED=0
  while kill -0 "$SERVER_PID" 2>/dev/null && [[ "$WAITED" -lt 6 ]]; do
    sleep 0.5; WAITED=$((WAITED + 1))
  done

  if kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "Server did not exit after SIGTERM"
    kill -9 "$SERVER_PID" 2>/dev/null || true
  else
    set +e; wait "$SERVER_PID" 2>/dev/null; EC=$?; set -e
    [[ "$EC" -eq 0 ]] && pass "Clean exit (code 0) after SIGTERM" || fail "Exit code $EC (expected 0)"
  fi
  SERVER_PID=""
fi

# ═════════════════════════════════════════════════════════
#  TRD-07：独立性能与文档测试提示
# ═════════════════════════════════════════════════════════
if [[ "$TRD_LEVEL" -ge 7 ]]; then
  group "TRD-07" "Benchmarking & Documentation"
  echo -e "    ${DIM}TRD-07 tests (valgrind, wrk, README) require standalone execution.${NC}"
  echo -e "    ${DIM}Run: ./trds/07-benchmarking/test_trd07.sh${NC}"
fi

# ═════════════════════════════════════════════════════════
#  结果汇总
# ═════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  TRD-00 through TRD-$(printf '%02d' "$TRD_LEVEL")"
echo -e "  ${GREEN}$PASS passed${NC}  ${RED}$FAIL failed${NC}  ${YELLOW}$SKIP skipped${NC}  ($TOTAL total)"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}Regressions detected.${NC} Fix before proceeding to the next TRD."
  exit 1
else
  echo -e "${GREEN}All tests passed through TRD-$(printf '%02d' "$TRD_LEVEL").${NC}"
  exit 0
fi
