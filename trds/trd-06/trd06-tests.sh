#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-06 Test Suite — Hardening
#  Run: chmod +x test_trd06.sh && ./test_trd06.sh
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
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }

# ── Create temporary docroot ─────────────────────────────
DOCROOT=$(mktemp -d)
TMPOUT=$(mktemp -d)

echo '<!DOCTYPE html><html><body>Conduit Index</body></html>' > "$DOCROOT/index.html"
echo '<html><body>Test Page</body></html>' > "$DOCROOT/test.html"
dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' 'C' > "$DOCROOT/large.bin"

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
echo -e "${BOLD}  Conduit TRD-06 Test Suite${NC}"
echo -e "${BOLD}  Hardening${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

# ── T1: Compilation ──────────────────────────────────────
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
  fail "GET / → $STATUS"
fi

# ── T3: 404 (regression) ────────────────────────────────
info "T3: GET /nonexistent → 404"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent" 2>/dev/null || echo "000")
if [[ "$STATUS" == "404" ]]; then
  pass "Nonexistent → 404"
else
  fail "Nonexistent → $STATUS"
fi

# ── T4: Oversized request → 400 ─────────────────────────
info "T4: Oversized request headers (>8 KB) → 400"
HUGE_VAL=$(head -c 16000 /dev/zero | tr '\0' 'A')
RESP=$(echo -ne "GET / HTTP/1.1\r\nHost: localhost\r\nX-Huge: ${HUGE_VAL}\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "400"; then
  pass "Oversized request → 400"
else
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "Oversized request did not return 400 (server alive, got: $(echo "$RESP" | head -1))"
  else
    fail "Server CRASHED on oversized request"
    exit 1
  fi
fi

# ── T5: SIGPIPE resilience ──────────────────────────────
info "T5: Server survives client disconnects (SIGPIPE)"
(
  for i in $(seq 1 15); do
    echo -ne "GET /large.bin HTTP/1.1\r\nHost: localhost\r\n\r\n" | \
      nc -w 1 localhost "$PORT" > /dev/null 2>&1 &
  done
  sleep 0.3
  kill $(jobs -p) 2>/dev/null || true
  wait 2>/dev/null || true
)
sleep 0.5

if kill -0 "$SERVER_PID" 2>/dev/null; then
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    pass "Server survived SIGPIPE (still serving 200)"
  else
    fail "Server alive but degraded ($STATUS)"
  fi
else
  fail "Server CRASHED — SIGPIPE not suppressed"
  exit 1
fi

# ── T6: Rapid connect/disconnect storm ──────────────────
info "T6: 50 rapid connect/disconnect (no data sent)"
(
  for i in $(seq 1 50); do
    nc -w 1 localhost "$PORT" < /dev/null > /dev/null 2>&1 &
  done
  wait 2>/dev/null || true
)
sleep 0.5

if kill -0 "$SERVER_PID" 2>/dev/null; then
  pass "Survived 50 rapid connect/disconnect"
else
  fail "Server CRASHED during connect/disconnect storm"
  exit 1
fi

# ── T7: Malformed request barrage ────────────────────────
info "T7: 10 malformed requests don't crash server"
for i in $(seq 1 10); do
  echo -ne "GARBAGE_REQUEST_$i\r\n\r\n" | nc -w 1 localhost "$PORT" > /dev/null 2>&1 || true
done
sleep 0.5

if kill -0 "$SERVER_PID" 2>/dev/null; then
  pass "Survived 10 malformed requests"
else
  fail "Server CRASHED during malformed barrage"
  exit 1
fi

# ── T8: Server functional after error barrage ────────────
info "T8: Server still functional after all abuse"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
BODY=$(curl -s "http://localhost:$PORT/" 2>/dev/null || echo "")
EXPECTED=$(cat "$DOCROOT/index.html")
if [[ "$STATUS" == "200" && "$BODY" == "$EXPECTED" ]]; then
  pass "GET / → 200 with correct body after abuse"
else
  fail "Post-abuse: status=$STATUS, body match=$([ "$BODY" == "$EXPECTED" ] && echo yes || echo no)"
fi

# ── T9: Mixed valid/invalid concurrent ──────────────────
info "T9: Concurrent mix of valid and invalid requests"
(
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/mx_1" 2>/dev/null &
  echo -ne "GARBAGE\r\n\r\n" | nc -w 1 localhost "$PORT" > /dev/null 2>&1 &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/test.html" > "$TMPOUT/mx_2" 2>/dev/null &
  echo -ne "\r\n\r\n" | nc -w 1 localhost "$PORT" > /dev/null 2>&1 &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/mx_3" 2>/dev/null &
  wait
)

MX1=$(cat "$TMPOUT/mx_1" 2>/dev/null || echo "000")
MX2=$(cat "$TMPOUT/mx_2" 2>/dev/null || echo "000")
MX3=$(cat "$TMPOUT/mx_3" 2>/dev/null || echo "000")

if [[ "$MX1" == "200" && "$MX2" == "200" && "$MX3" == "200" ]]; then
  pass "Valid requests succeeded alongside invalid ones"
else
  fail "Mixed concurrent: $MX1, $MX2, $MX3 (expected 200, 200, 200)"
fi

# ── T10: SIGTERM → clean exit (MUST BE LAST) ────────────
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
    pass "Clean exit (code 0) after SIGTERM"
  else
    fail "Exit code $EXIT_CODE after SIGTERM (expected 0)"
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
  echo -e "${RED}Some tests failed.${NC} Use ${BOLD}strace -f -e trace=signal,network${NC} to debug."
  exit 1
else
  echo -e "${GREEN}All tests passed.${NC} Answer the comprehension questions before moving to TRD-07."
  exit 0
fi