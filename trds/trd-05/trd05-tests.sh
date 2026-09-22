#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-05 Test Suite — Thread Pool
#  Run: chmod +x test_trd05.sh && ./test_trd05.sh
# ═══════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
PORT="${1:-9876}"
BINARY="./conduit"
SRC="conduit.c"

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ── Create temporary docroot ─────────────────────────────
DOCROOT=$(mktemp -d)
TMPOUT=$(mktemp -d)

echo '<!DOCTYPE html><html><body>Conduit Index</body></html>' > "$DOCROOT/index.html"
echo '<html><body>Test Page</body></html>' > "$DOCROOT/test.html"
dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' 'B' > "$DOCROOT/large.bin"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$DOCROOT" "$TMPOUT"
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Conduit TRD-05 Test Suite${NC}"
echo -e "${BOLD}  Thread Pool${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

# ── T1: Compilation with -pthread ────────────────────────
info "T1: Compilation via Makefile"
if [[ ! -f "Makefile" ]]; then
  fail "Makefile not found — required for multi-file builds"
  exit 1
fi
for FLAG in -Wall -Wextra -Werror -pedantic -pthread; do
  if ! grep -q -- "$FLAG" Makefile; then
    fail "Makefile missing required flag: $FLAG"
    exit 1
  fi
done
make clean > /dev/null 2>&1 || true
if make > /dev/null 2>&1 && [[ -x "$BINARY" ]]; then
  pass "Compiles via Makefile (with -pthread)"
else
  fail "Compilation failed — cannot continue"
  exit 1
fi

# ── Start server ─────────────────────────────────────────
info "Starting server on port $PORT..."
$BINARY "$PORT" "$DOCROOT" &
SERVER_PID=$!
sleep 0.5

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  fail "Server failed to start"
  exit 1
fi
info "Server running (PID $SERVER_PID)"
echo ""

# ── T2: GET / → 200 (regression) ────────────────────────
info "T2: GET / returns 200"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  pass "GET / → 200"
else
  fail "GET / → $STATUS (expected 200)"
fi

# ── T3: 404 (regression) ────────────────────────────────
info "T3: GET /nonexistent → 404"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent" 2>/dev/null || echo "000")
if [[ "$STATUS" == "404" ]]; then
  pass "Nonexistent → 404"
else
  fail "Nonexistent → $STATUS (expected 404)"
fi

# ── T4: 10 concurrent connections ────────────────────────
info "T4: 10 concurrent connections all return 200"
(
  for i in $(seq 1 10); do
    curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/c10_$i" 2>/dev/null &
  done
  wait
)

C10_OK=0
for i in $(seq 1 10); do
  R=$(cat "$TMPOUT/c10_$i" 2>/dev/null || echo "000")
  if [[ "$R" == "200" ]]; then C10_OK=$((C10_OK + 1)); fi
done

if [[ "$C10_OK" -eq 10 ]]; then
  pass "10/10 concurrent → 200"
else
  fail "$C10_OK/10 concurrent → 200"
fi

# ── T5: 50 concurrent connections ────────────────────────
info "T5: 50 concurrent connections (exceeding thread count)"
(
  for i in $(seq 1 50); do
    curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/c50_$i" 2>/dev/null &
  done
  wait
)

C50_OK=0
for i in $(seq 1 50); do
  R=$(cat "$TMPOUT/c50_$i" 2>/dev/null || echo "000")
  if [[ "$R" == "200" ]]; then C50_OK=$((C50_OK + 1)); fi
done

if [[ "$C50_OK" -eq 50 ]]; then
  pass "50/50 concurrent → 200"
elif [[ "$C50_OK" -ge 45 ]]; then
  pass "50 concurrent: $C50_OK/50 returned 200 (within tolerance)"
else
  fail "$C50_OK/50 concurrent → 200"
fi

# ── T6: Concurrent large file requests ──────────────────
info "T6: 5 concurrent large file (256 KB) requests"
EXPECTED_SIZE=$(wc -c < "$DOCROOT/large.bin" | tr -d ' ')
(
  for i in $(seq 1 5); do
    curl -s "http://localhost:$PORT/large.bin" -o "$TMPOUT/lg_$i" 2>/dev/null &
  done
  wait
)

LG_OK=0
for i in $(seq 1 5); do
  SZ=$(wc -c < "$TMPOUT/lg_$i" 2>/dev/null | tr -d ' ')
  if [[ "$SZ" == "$EXPECTED_SIZE" ]]; then LG_OK=$((LG_OK + 1)); fi
done

if [[ "$LG_OK" -eq 5 ]]; then
  pass "5/5 large file downloads correct ($EXPECTED_SIZE bytes each)"
else
  fail "$LG_OK/5 large file downloads correct"
fi

# ── T7: Mixed concurrent status codes ───────────────────
info "T7: Mixed concurrent (200, 404, 405)"
(
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/mx_1" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nope" > "$TMPOUT/mx_2" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" > "$TMPOUT/mx_3" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/test.html" > "$TMPOUT/mx_4" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nope2" > "$TMPOUT/mx_5" 2>/dev/null &
  wait
)

MX1=$(cat "$TMPOUT/mx_1" 2>/dev/null || echo "000")
MX2=$(cat "$TMPOUT/mx_2" 2>/dev/null || echo "000")
MX3=$(cat "$TMPOUT/mx_3" 2>/dev/null || echo "000")
MX4=$(cat "$TMPOUT/mx_4" 2>/dev/null || echo "000")
MX5=$(cat "$TMPOUT/mx_5" 2>/dev/null || echo "000")

if [[ "$MX1" == "200" && "$MX2" == "404" && "$MX3" == "405" && "$MX4" == "200" && "$MX5" == "404" ]]; then
  pass "Mixed concurrent: 200, 404, 405, 200, 404"
else
  fail "Mixed concurrent: $MX1, $MX2, $MX3, $MX4, $MX5"
fi

# ── T8: 100 rapid sequential requests ───────────────────
info "T8: 100 rapid sequential requests"
SEQ_OK=0
for i in $(seq 1 100); do
  S=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  if [[ "$S" == "200" ]]; then SEQ_OK=$((SEQ_OK + 1)); fi
done

if [[ "$SEQ_OK" -eq 100 ]]; then
  pass "100/100 sequential → 200"
else
  fail "$SEQ_OK/100 sequential → 200"
fi

# ── T9: No fd leaks ─────────────────────────────────────
info "T9: File descriptor count stable after 100 connections"
if [[ -d "/proc/$SERVER_PID/fd" ]]; then
  FD_BEFORE=$(ls "/proc/$SERVER_PID/fd" 2>/dev/null | wc -l)

  for i in $(seq 1 100); do
    curl -s -o /dev/null "http://localhost:$PORT/" 2>/dev/null || true
  done
  sleep 1

  FD_AFTER=$(ls "/proc/$SERVER_PID/fd" 2>/dev/null | wc -l)
  FD_DIFF=$((FD_AFTER - FD_BEFORE))

  if [[ "$FD_DIFF" -ge -3 && "$FD_DIFF" -le 3 ]]; then
    pass "FD stable (before=$FD_BEFORE, after=$FD_AFTER, diff=$FD_DIFF)"
  else
    fail "FD leak (before=$FD_BEFORE, after=$FD_AFTER, diff=$FD_DIFF)"
  fi
else
  info "SKIP: /proc/$SERVER_PID/fd not accessible"
fi

# ── T10: SIGTERM → clean exit (MUST BE LAST TEST) ───────
info "T10: SIGTERM triggers graceful shutdown"
kill -TERM "$SERVER_PID" 2>/dev/null || true

WAITED=0
while kill -0 "$SERVER_PID" 2>/dev/null && [[ "$WAITED" -lt 6 ]]; do
  sleep 0.5
  WAITED=$((WAITED + 1))
done

if kill -0 "$SERVER_PID" 2>/dev/null; then
  fail "Server did not exit after SIGTERM (3s timeout)"
  kill -9 "$SERVER_PID" 2>/dev/null || true
else
  set +e
  wait "$SERVER_PID" 2>/dev/null
  EXIT_CODE=$?
  set -e

  if [[ "$EXIT_CODE" -eq 0 ]]; then
    pass "Server exited cleanly (code 0) after SIGTERM"
  else
    fail "Server exited with code $EXIT_CODE after SIGTERM (expected 0)"
  fi
fi

SERVER_PID=""

# ── Results ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}Some tests failed.${NC} Use ${BOLD}strace -f${NC} to trace thread behavior."
  exit 1
else
  echo -e "${GREEN}All tests passed.${NC} Answer the comprehension questions before moving to TRD-06."
  exit 0
fi