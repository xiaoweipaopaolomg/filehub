#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-04 Test Suite — Epoll Event Loop
#  Run: chmod +x test_trd04.sh && ./test_trd04.sh
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
echo 'body { color: black; }' > "$DOCROOT/style.css"

# Large file: 256 KB of repeating printable characters
dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' 'A' > "$DOCROOT/large.bin"

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
echo -e "${BOLD}  Conduit TRD-04 Test Suite${NC}"
echo -e "${BOLD}  Epoll Event Loop${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

# ── T1: Compilation ──────────────────────────────────────
info "T1: Compilation via Makefile"
if [[ ! -f "Makefile" ]]; then
  fail "Makefile not found — required for multi-file builds"
  exit 1
fi
for FLAG in -Wall -Wextra -Werror -pedantic; do
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

# ── T4: 405 (regression) ────────────────────────────────
info "T4: POST / → 405"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "405" ]]; then
  pass "POST → 405"
else
  fail "POST → $STATUS (expected 405)"
fi

# ── T5: 10 concurrent connections ────────────────────────
info "T5: 10 concurrent connections all return 200"
(
  for i in $(seq 1 10); do
    curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/conc_$i" 2>/dev/null &
  done
  wait
)

CONC_OK=0
for i in $(seq 1 10); do
  RESULT=$(cat "$TMPOUT/conc_$i" 2>/dev/null || echo "000")
  if [[ "$RESULT" == "200" ]]; then
    CONC_OK=$((CONC_OK + 1))
  fi
done

if [[ "$CONC_OK" -eq 10 ]]; then
  pass "10/10 concurrent requests returned 200"
else
  fail "$CONC_OK/10 returned 200"
fi

# ── T6: 50 rapid sequential connections ──────────────────
info "T6: 50 rapid sequential requests"
SEQ_OK=0
for i in $(seq 1 50); do
  S=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
  if [[ "$S" == "200" ]]; then
    SEQ_OK=$((SEQ_OK + 1))
  fi
done

if [[ "$SEQ_OK" -eq 50 ]]; then
  pass "50/50 sequential requests returned 200"
else
  fail "$SEQ_OK/50 sequential requests returned 200"
fi

# ── T7: Large file (256 KB) served correctly ─────────────
info "T7: Large file served with correct Content-Length"
EXPECTED_SIZE=$(wc -c < "$DOCROOT/large.bin" | tr -d ' ')
curl -s "http://localhost:$PORT/large.bin" -o "$TMPOUT/large_dl" 2>/dev/null || true
DL_SIZE=$(wc -c < "$TMPOUT/large_dl" 2>/dev/null | tr -d ' ')

CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/large.bin" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')

if [[ "$DL_SIZE" == "$EXPECTED_SIZE" && "$CL" == "$EXPECTED_SIZE" ]]; then
  pass "Large file: $EXPECTED_SIZE bytes, CL=$CL, downloaded=$DL_SIZE"
else
  fail "Large file: expected=$EXPECTED_SIZE, CL=$CL, downloaded=$DL_SIZE"
fi

# ── T8: Slow client doesn't block fast client ────────────
info "T8: Slow client does not block fast client"

(echo -ne "GET / HTTP/1.1\r\n"; sleep 3; echo -ne "Host: localhost\r\n\r\n") | \
  nc -w 5 localhost "$PORT" > /dev/null 2>&1 &
SLOW_PID=$!
sleep 0.3

FAST_STATUS=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")

kill "$SLOW_PID" 2>/dev/null || true
wait "$SLOW_PID" 2>/dev/null || true

if [[ "$FAST_STATUS" == "200" ]]; then
  pass "Fast client served (200) while slow client pending"
else
  fail "Fast client returned $FAST_STATUS (expected 200 — server may be blocking)"
fi

# ── T9: No fd leaks after many connections ───────────────
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
    pass "FD count stable (before=$FD_BEFORE, after=$FD_AFTER, diff=$FD_DIFF)"
  else
    fail "FD leak detected (before=$FD_BEFORE, after=$FD_AFTER, diff=$FD_DIFF)"
  fi
else
  info "SKIP: /proc/$SERVER_PID/fd not accessible"
fi

# ── T10: Concurrent requests for different files ─────────
info "T10: Concurrent requests for different files"
(
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" > "$TMPOUT/multi_1" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/test.html" > "$TMPOUT/multi_2" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/style.css" > "$TMPOUT/multi_3" 2>/dev/null &
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/large.bin" > "$TMPOUT/multi_4" 2>/dev/null &
  wait
)

M1=$(cat "$TMPOUT/multi_1" 2>/dev/null || echo "000")
M2=$(cat "$TMPOUT/multi_2" 2>/dev/null || echo "000")
M3=$(cat "$TMPOUT/multi_3" 2>/dev/null || echo "000")
M4=$(cat "$TMPOUT/multi_4" 2>/dev/null || echo "000")

if [[ "$M1" == "200" && "$M2" == "200" && "$M3" == "200" && "$M4" == "200" ]]; then
  pass "4 concurrent requests for different files: all 200"
else
  fail "Concurrent multi-file: $M1, $M2, $M3, $M4 (expected all 200)"
fi

# ── Results ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}Some tests failed.${NC} Debug with ${BOLD}strace -f -e trace=network${NC}."
  exit 1
else
  echo -e "${GREEN}All tests passed.${NC} Answer the comprehension questions before moving to TRD-05."
  exit 0
fi