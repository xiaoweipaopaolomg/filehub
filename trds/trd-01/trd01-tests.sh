#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-01 Test Suite — HTTP/1.1 Request Parsing
#  Run: chmod +x test_trd01.sh && ./test_trd01.sh
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

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Conduit TRD-01 Test Suite${NC}"
echo -e "${BOLD}  HTTP/1.1 Request Parsing${NC}"
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
$BINARY "$PORT" &
SERVER_PID=$!
sleep 0.5

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  fail "Server failed to start"
  exit 1
fi
info "Server running (PID $SERVER_PID)"
echo ""

# ── T2: GET / → 200 ─────────────────────────────────────
info "T2: GET / returns 200"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  pass "GET / → 200"
else
  fail "GET / → $STATUS (expected 200)"
fi

# ── T3: GET / has non-empty body ─────────────────────────
info "T3: GET / returns non-empty body"
BODY=$(curl -s "http://localhost:$PORT/" 2>/dev/null || echo "")
if [[ -n "$BODY" ]]; then
  pass "GET / body present (${#BODY} bytes)"
else
  fail "GET / returned empty body"
fi

# ── T4: GET /nonexistent → 404 ──────────────────────────
info "T4: GET /nonexistent returns 404"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent" 2>/dev/null || echo "000")
if [[ "$STATUS" == "404" ]]; then
  pass "GET /nonexistent → 404"
else
  fail "GET /nonexistent → $STATUS (expected 404)"
fi

# ── T5: POST / → 405 ────────────────────────────────────
info "T5: POST / returns 405"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "405" ]]; then
  pass "POST / → 405"
else
  fail "POST / → $STATUS (expected 405)"
fi

# ── T6: DELETE / → 405 ──────────────────────────────────
info "T6: DELETE / returns 405"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "405" ]]; then
  pass "DELETE / → 405"
else
  fail "DELETE / → $STATUS (expected 405)"
fi

# ── T7: Malformed request (missing version) → 400 ───────
info "T7: Malformed request (no HTTP version) returns 400"
RESP=$(echo -ne "GET /\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "400"; then
  pass "Missing version → 400"
else
  fail "Missing version did not return 400. Got: $(echo "$RESP" | head -1)"
fi

# ── T8: Garbage request → 400 ───────────────────────────
info "T8: Complete garbage returns 400"
RESP=$(echo -ne "GARBAGE\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "400"; then
  pass "Garbage → 400"
else
  fail "Garbage did not return 400. Got: $(echo "$RESP" | head -1)"
fi

# ── T9: Wrong HTTP version → 400 ────────────────────────
info "T9: HTTP/2.0 returns 400"
RESP=$(echo -ne "GET / HTTP/2.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "400"; then
  pass "HTTP/2.0 → 400"
else
  fail "HTTP/2.0 did not return 400. Got: $(echo "$RESP" | head -1)"
fi

# ── T10: Extra headers don't break parsing ───────────────
info "T10: Request with extra headers returns 200"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "X-Custom: test" \
  -H "Accept: text/html" \
  -H "X-Another: value" \
  "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  pass "Extra headers → 200"
else
  fail "Extra headers → $STATUS (expected 200)"
fi

# ── T11: Multiple sequential requests ────────────────────
info "T11: Three sequential requests succeed"
S1=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
S2=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
S3=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$S1" == "200" && "$S2" == "200" && "$S3" == "200" ]]; then
  pass "3 sequential requests all returned 200"
else
  fail "Sequential: $S1, $S2, $S3 (expected 200, 200, 200)"
fi

# ── T12: Content-Type header present ─────────────────────
info "T12: Response includes Content-Type"
HDRS=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null || echo "")
if echo "$HDRS" | grep -qi "Content-Type"; then
  pass "Content-Type header present"
else
  fail "Content-Type header missing"
fi

# ── T13: Content-Length matches body ─────────────────────
info "T13: Content-Length matches actual body size"
CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')
BODY_LEN=$(curl -s "http://localhost:$PORT/" 2>/dev/null | wc -c | tr -d ' ')
if [[ -n "$CL" && "$CL" == "$BODY_LEN" ]]; then
  pass "Content-Length ($CL) matches body ($BODY_LEN)"
else
  fail "Content-Length ($CL) vs body ($BODY_LEN)"
fi

# ── Results ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}Some tests failed.${NC} Use ${BOLD}curl -v${NC} and ${BOLD}strace${NC} to debug."
  exit 1
else
  echo -e "${GREEN}All tests passed.${NC} Answer the comprehension questions before moving to TRD-02."
  exit 0
fi