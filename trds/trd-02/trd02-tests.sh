#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-02 Test Suite — Static File Serving
#  Run: chmod +x test_trd02.sh && ./test_trd02.sh
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

# ── Create temporary docroot with test files ─────────────
DOCROOT=$(mktemp -d)

mkdir -p "$DOCROOT/subdir"
echo '<!DOCTYPE html><html><body>Conduit Index</body></html>' > "$DOCROOT/index.html"
echo '<html><body>Test Page</body></html>' > "$DOCROOT/test.html"
echo 'body { color: black; }' > "$DOCROOT/style.css"
echo 'console.log("conduit");' > "$DOCROOT/script.js"
echo 'plain text content' > "$DOCROOT/hello.txt"
echo '<html><body>Nested</body></html>' > "$DOCROOT/subdir/nested.html"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$DOCROOT"
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Conduit TRD-02 Test Suite${NC}"
echo -e "${BOLD}  Static File Serving${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
info "Docroot: $DOCROOT"
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

# ── T2: Missing docroot argument → exit 1 ───────────────
info "T2: Missing docroot argument exits with error"
if $BINARY "$PORT" >/dev/null 2>&1; then
  fail "Server started without docroot argument (should have exited)"
  # Kill it if it accidentally started
  kill $! 2>/dev/null || true
else
  pass "Exits with error when docroot missing"
fi

# ── Start server ─────────────────────────────────────────
info "Starting server on port $PORT with docroot $DOCROOT..."
$BINARY "$PORT" "$DOCROOT" &
SERVER_PID=$!
sleep 0.5

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  fail "Server failed to start"
  exit 1
fi
info "Server running (PID $SERVER_PID)"
echo ""

# ── T3: GET / serves index.html ─────────────────────────
info "T3: GET / serves index.html content"
BODY=$(curl -s "http://localhost:$PORT/" 2>/dev/null || echo "")
EXPECTED=$(cat "$DOCROOT/index.html")
if [[ "$BODY" == "$EXPECTED" ]]; then
  pass "GET / body matches index.html"
else
  fail "GET / body does not match index.html"
  echo "       Expected: ${EXPECTED:0:60}"
  echo "       Got:      ${BODY:0:60}"
fi

# ── T4: GET /test.html → 200 ────────────────────────────
info "T4: GET /test.html returns 200"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/test.html" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  pass "GET /test.html → 200"
else
  fail "GET /test.html → $STATUS (expected 200)"
fi

# ── T5: .css → text/css ─────────────────────────────────
info "T5: style.css served with Content-Type: text/css"
CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/style.css" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
if echo "$CT" | grep -qi "text/css"; then
  pass ".css → text/css"
else
  fail ".css Content-Type: $CT (expected text/css)"
fi

# ── T6: .js → application/javascript ────────────────────
info "T6: script.js served with correct JS Content-Type"
CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/script.js" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
if echo "$CT" | grep -qiE "(application/javascript|text/javascript)"; then
  pass ".js → javascript MIME type"
else
  fail ".js Content-Type: $CT (expected application/javascript or text/javascript)"
fi

# ── T7: .txt → text/plain ───────────────────────────────
info "T7: hello.txt served with Content-Type: text/plain"
CT=$(curl -s -D - -o /dev/null "http://localhost:$PORT/hello.txt" 2>/dev/null | grep -i "Content-Type" | tr -d '\r')
if echo "$CT" | grep -qi "text/plain"; then
  pass ".txt → text/plain"
else
  fail ".txt Content-Type: $CT (expected text/plain)"
fi

# ── T8: Nonexistent file → 404 ──────────────────────────
info "T8: GET /nonexistent.html returns 404"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/nonexistent.html" 2>/dev/null || echo "000")
if [[ "$STATUS" == "404" ]]; then
  pass "Nonexistent file → 404"
else
  fail "Nonexistent file → $STATUS (expected 404)"
fi

# ── T9: Directory traversal (basic) → 403 ───────────────
info "T9: Directory traversal (/../../../etc/passwd) returns 403"
RESP=$(echo -ne "GET /../../../etc/passwd HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -q "403"; then
  pass "Basic traversal → 403"
else
  fail "Basic traversal did not return 403. Got: $(echo "$RESP" | head -1)"
fi

# ── T10: Directory traversal (nested escape) → 403 ──────
info "T10: Traversal via subdir (/../../../etc/passwd) returns 403"
RESP=$(echo -ne "GET /subdir/../../../etc/passwd HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost "$PORT" 2>/dev/null || true)
if echo "$RESP" | grep -qE "403|404"; then
  # 403 is correct; 404 is acceptable if realpath fails on nonexistent intermediate
  pass "Nested traversal blocked ($(echo "$RESP" | head -1 | grep -oE '[0-9]{3}'))"
else
  fail "Nested traversal not blocked. Got: $(echo "$RESP" | head -1)"
fi

# ── T11: Content-Length matches file size ────────────────
info "T11: Content-Length matches index.html file size"
CL=$(curl -s -D - -o /dev/null "http://localhost:$PORT/" 2>/dev/null | grep -i "Content-Length" | tr -d '\r' | awk '{print $2}')
FILE_SIZE=$(wc -c < "$DOCROOT/index.html" | tr -d ' ')
if [[ -n "$CL" && "$CL" == "$FILE_SIZE" ]]; then
  pass "Content-Length ($CL) matches file size ($FILE_SIZE)"
else
  fail "Content-Length ($CL) vs file size ($FILE_SIZE)"
fi

# ── T12: Subdirectory file serving ───────────────────────
info "T12: GET /subdir/nested.html returns 200"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/subdir/nested.html" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  pass "Subdirectory serving → 200"
else
  fail "Subdirectory serving → $STATUS (expected 200)"
fi

# ── T13: Response body matches file on disk ──────────────
info "T13: Response body matches style.css on disk"
BODY=$(curl -s "http://localhost:$PORT/style.css" 2>/dev/null || echo "")
EXPECTED=$(cat "$DOCROOT/style.css")
if [[ "$BODY" == "$EXPECTED" ]]; then
  pass "Body matches style.css file contents"
else
  fail "Body does not match style.css"
fi

# ── T14: Sequential requests for different files ────────
info "T14: Sequential requests for different files"
S1=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || echo "000")
S2=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/test.html" 2>/dev/null || echo "000")
S3=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/style.css" 2>/dev/null || echo "000")
S4=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/hello.txt" 2>/dev/null || echo "000")
if [[ "$S1" == "200" && "$S2" == "200" && "$S3" == "200" && "$S4" == "200" ]]; then
  pass "4 sequential requests for different files all returned 200"
else
  fail "Sequential: $S1, $S2, $S3, $S4 (expected all 200)"
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
  echo -e "${GREEN}All tests passed.${NC} Answer the comprehension questions before moving to TRD-03."
  exit 0
fi