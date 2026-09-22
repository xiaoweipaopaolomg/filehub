#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-03 Test Suite — HTTP Response Engine
#  Run: chmod +x test_trd03.sh && ./test_trd03.sh
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
mkdir -p "$DOCROOT/subdir"
echo '<!DOCTYPE html><html><body>Conduit Index</body></html>' > "$DOCROOT/index.html"
echo 'body { color: black; }' > "$DOCROOT/style.css"
echo 'secret data' > "$DOCROOT/noperm.txt"
chmod 000 "$DOCROOT/noperm.txt"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  chmod -R u+rwX "$DOCROOT" 2>/dev/null || true
  rm -rf "$DOCROOT"
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Conduit TRD-03 Test Suite${NC}"
echo -e "${BOLD}  HTTP Response Engine${NC}"
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

# ── T2: GET / → 200 with file body (regression) ─────────
info "T2: GET / returns 200 with correct body"
BODY=$(curl -s "http://localhost:$PORT/" 2>/dev/null || echo "")
EXPECTED=$(cat "$DOCROOT/index.html")
if [[ "$BODY" == "$EXPECTED" ]]; then
  pass "GET / body matches index.html"
else
  fail "GET / body mismatch"
fi

# ── T3: CSS MIME type (regression) ───────────────────────
info "T3: style.css → Content-Type: text/css"
CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/style.css" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
if echo "$CT" | grep -qi "text/css"; then
  pass ".css → text/css"
else
  fail ".css Content-Type: $CT"
fi

# ── T4: 404 (regression) ────────────────────────────────
info "T4: GET /nonexistent → 404"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent" 2>/dev/null || echo "000")
if [[ "$STATUS" == "404" ]]; then
  pass "Nonexistent → 404"
else
  fail "Nonexistent → $STATUS (expected 404)"
fi

# ── T5: 405 (regression) ────────────────────────────────
info "T5: POST / → 405"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$STATUS" == "405" ]]; then
  pass "POST → 405"
else
  fail "POST → $STATUS (expected 405)"
fi

# ── T6: 400 (regression) ────────────────────────────────
info "T6: Malformed request → 400"
RESP=$(echo -ne "GARBAGE\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "400"; then
  pass "Garbage → 400"
else
  fail "Garbage did not return 400"
fi

# ── T7: 403 traversal (regression) ──────────────────────
info "T7: Directory traversal → 403"
RESP=$(echo -ne "GET /../../../etc/passwd HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "403"; then
  pass "Traversal → 403"
else
  fail "Traversal did not return 403"
fi

# ── T8: 200 status line format ──────────────────────────
info "T8: 200 response has valid HTTP/1.1 status line"
LINE=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null | head -1 | tr -d '\r')
if [[ "$LINE" =~ ^HTTP/1\.1\ 200\  ]]; then
  pass "200 status line: $LINE"
else
  fail "200 status line malformed: $LINE"
fi

# ── T9: 404 status line format ──────────────────────────
info "T9: 404 response has valid HTTP/1.1 status line"
LINE=$(curl -s -D - -o /dev/null "http://localhost:$PORT/nope" 2>/dev/null | head -1 | tr -d '\r')
if [[ "$LINE" =~ ^HTTP/1\.1\ 404\  ]]; then
  pass "404 status line: $LINE"
else
  fail "404 status line malformed: $LINE"
fi

# ── T10: 405 status line format ─────────────────────────
info "T10: 405 response has valid HTTP/1.1 status line"
LINE=$(curl -s -D - -o /dev/null -X DELETE "http://localhost:$PORT/" 2>/dev/null | head -1 | tr -d '\r')
if [[ "$LINE" =~ ^HTTP/1\.1\ 405\  ]]; then
  pass "405 status line: $LINE"
else
  fail "405 status line malformed: $LINE"
fi

# ── T11: Error responses have Content-Type + Content-Length
info "T11: 404 response includes Content-Type and Content-Length"
HDRS=$(curl -s -D - -o /dev/null "http://localhost:$PORT/nope" 2>/dev/null)
HAS_CT=$(echo "$HDRS" | grep -ci "Content-Type" || true)
HAS_CL=$(echo "$HDRS" | grep -ci "Content-Length" || true)
if [[ "$HAS_CT" -ge 1 && "$HAS_CL" -ge 1 ]]; then
  pass "404 has Content-Type and Content-Length"
else
  fail "404 missing headers (CT=$HAS_CT, CL=$HAS_CL)"
fi

# ── T12: Error bodies are non-empty ─────────────────────
info "T12: Error response bodies are non-empty"
B404=$(curl -s "http://localhost:$PORT/nope" 2>/dev/null || echo "")
B405=$(curl -s -X POST "http://localhost:$PORT/" 2>/dev/null || echo "")
if [[ -n "$B404" && -n "$B405" ]]; then
  pass "404 and 405 bodies non-empty"
else
  fail "Empty error body (404=${#B404}b, 405=${#B405}b)"
fi

# ── T13: Error Content-Length matches body ───────────────
info "T13: 404 Content-Length matches actual body size"
CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/nope" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')
BODY_LEN=$(curl -s "http://localhost:$PORT/nope" 2>/dev/null | wc -c | tr -d ' ')
if [[ -n "$CL" && "$CL" == "$BODY_LEN" ]]; then
  pass "404 Content-Length ($CL) matches body ($BODY_LEN)"
else
  fail "404 Content-Length ($CL) vs body ($BODY_LEN)"
fi

# ── T14: Permission-denied file → 403 ───────────────────
info "T14: Permission-denied file returns 403"
if [[ "$(id -u)" == "0" ]]; then
  skip "Running as root — chmod 000 has no effect, skipping"
else
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/noperm.txt" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "403" ]]; then
    pass "Permission denied → 403"
  else
    fail "Permission denied → $STATUS (expected 403)"
  fi
fi

# ── T15: Mixed sequential requests ──────────────────────
info "T15: Mixed sequential (200, 404, 405, 200)"
S1=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
S2=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nope" 2>/dev/null || echo "000")
S3=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/" 2>/dev/null || echo "000")
S4=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
if [[ "$S1" == "200" && "$S2" == "404" && "$S3" == "405" && "$S4" == "200" ]]; then
  pass "Mixed: 200, 404, 405, 200"
else
  fail "Mixed: $S1, $S2, $S3, $S4 (expected 200, 404, 405, 200)"
fi

# ── Results ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}Some tests failed.${NC} Debug with ${BOLD}curl -v${NC} and ${BOLD}strace${NC}."
  exit 1
else
  echo -e "${GREEN}All tests passed.${NC} Answer the comprehension questions before moving to TRD-04."
  exit 0
fi