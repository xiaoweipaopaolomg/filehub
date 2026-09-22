#!/usr/bin/env bash
#
# Conduit — TRD-00 Test Suite
# Usage: chmod +x test_trd00.sh && ./test_trd00.sh
#
# Expects conduit.c in the current directory.
# Will compile it, run it, test it, and kill it.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────
PORT=9876
BINARY="./conduit"
SOURCE="conduit.c"
PASS=0
FAIL=0
TOTAL=11

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SERVER_PID=""

# ─── Helpers ─────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -f "$BINARY" /tmp/trd00_response_* /tmp/trd00_headers_* /tmp/trd00_body_*
}
trap cleanup EXIT

pass() {
    echo -e "  ${GREEN}✓ PASS${NC} — $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}✗ FAIL${NC} — $1"
    [[ -n "${2:-}" ]] && echo -e "         ${RED}↳ $2${NC}"
    FAIL=$((FAIL + 1))
}

wait_for_server() {
    local retries=20
    while ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            echo -e "${RED}ERROR: Server failed to start on port $PORT${NC}"
            exit 1
        fi
        sleep 0.1
    done
}

start_server() {
    "$BINARY" "$PORT" &
    SERVER_PID=$!
    wait_for_server
}

# ─── Banner ──────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║     CONDUIT — TRD-00 TEST SUITE          ║${NC}"
echo -e "${CYAN}${BOLD}║     TCP Echo Foundation                   ║${NC}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════╝${NC}"
echo ""

# ─── TEST 1: Compilation ────────────────────────────────────────────
echo -e "${YELLOW}[1/11] Compilation${NC}"
if [[ ! -f "$SOURCE" ]]; then
    fail "Compilation" "$SOURCE not found in current directory"
    echo -e "\n${RED}Cannot continue without source file. Exiting.${NC}"
    exit 1
fi

COMPILE_OUTPUT=$(gcc -Wall -Wextra -Werror -std=c11 -o "$BINARY" "$SOURCE" 2>&1) || {
    fail "Compiles with -Wall -Wextra -Werror -std=c11" "Compilation failed:\n$COMPILE_OUTPUT"
    echo -e "\n${RED}Cannot continue without successful compilation. Exiting.${NC}"
    exit 1
}
pass "Compiles cleanly with -Wall -Wextra -Werror -std=c11"

# ─── TEST 2: Usage message (no args) ────────────────────────────────
echo -e "${YELLOW}[2/11] Usage message${NC}"
set +e
USAGE_OUTPUT=$("$BINARY" 2>&1)
USAGE_EXIT=$?
set -e

if [[ $USAGE_EXIT -ne 0 ]] && [[ -n "$USAGE_OUTPUT" ]]; then
    pass "No-args run prints message and exits non-zero (exit code: $USAGE_EXIT)"
else
    if [[ $USAGE_EXIT -eq 0 ]]; then
        fail "Usage message" "Expected non-zero exit code, got 0"
    else
        fail "Usage message" "Expected error message on stderr/stdout, got nothing"
    fi
fi

# ─── TEST 3: Starts and accepts TCP connection ──────────────────────
echo -e "${YELLOW}[3/11] Starts and listens${NC}"
start_server

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    pass "Server accepts TCP connections on port $PORT"
else
    fail "Server accepts TCP connections" "Could not connect to 127.0.0.1:$PORT"
    exit 1
fi

# ─── TEST 4: Returns HTTP 200 ───────────────────────────────────────
echo -e "${YELLOW}[4/11] HTTP 200 response${NC}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || HTTP_CODE="000"

if [[ "$HTTP_CODE" == "200" ]]; then
    pass "Returns HTTP 200 status code"
else
    fail "Returns HTTP 200" "Got HTTP $HTTP_CODE"
fi

# ─── TEST 5: Content-Type header ────────────────────────────────────
echo -e "${YELLOW}[5/11] Content-Type header${NC}"
HEADERS=$(curl -sI --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || HEADERS=""

if echo "$HEADERS" | grep -qi "Content-Type: text/plain"; then
    pass "Content-Type: text/plain header present"
else
    fail "Content-Type header" "Header not found or incorrect. Got headers:\n$HEADERS"
fi

# ─── TEST 6: Content-Length matches body ─────────────────────────────
echo -e "${YELLOW}[6/11] Content-Length matches body${NC}"
BODY_FOR_LEN=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || BODY_FOR_LEN=""
ACTUAL_BODY_LEN=$(echo -n "$BODY_FOR_LEN" | wc -c | tr -d ' ')
CL_VALUE=$(echo "$HEADERS" | grep -i "Content-Length" | tr -d '\r' | awk -F': ' '{print $2}' | tr -d ' ')

if [[ -z "$CL_VALUE" ]]; then
    fail "Content-Length header" "Content-Length header not found in response"
elif [[ "$CL_VALUE" == "$ACTUAL_BODY_LEN" ]]; then
    pass "Content-Length: $CL_VALUE matches actual body size ($ACTUAL_BODY_LEN bytes)"
else
    fail "Content-Length matches body" "Header says $CL_VALUE but body is $ACTUAL_BODY_LEN bytes"
fi

# ─── TEST 7: Connection: close header ───────────────────────────────
echo -e "${YELLOW}[7/11] Connection: close header${NC}"
if echo "$HEADERS" | grep -qi "Connection: close"; then
    pass "Connection: close header present"
else
    fail "Connection: close header" "Header not found in response"
fi

# ─── TEST 8: Correct body ───────────────────────────────────────────
echo -e "${YELLOW}[8/11] Response body${NC}"
EXPECTED_BODY="Conduit is alive — TRD00"
ACTUAL_BODY=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || ACTUAL_BODY=""

if [[ "$ACTUAL_BODY" == "$EXPECTED_BODY" ]]; then
    pass "Body is exactly '$EXPECTED_BODY'"
else
    fail "Response body" "Expected: '$EXPECTED_BODY'\n         Got:      '$ACTUAL_BODY'"
    # Show hex diff for debugging encoding issues
    echo -e "         ${CYAN}Expected hex:${NC} $(echo -n "$EXPECTED_BODY" | xxd -p)"
    echo -e "         ${CYAN}Actual hex:  ${NC} $(echo -n "$ACTUAL_BODY" | xxd -p)"
fi

# ─── TEST 9: Sequential requests ────────────────────────────────────
echo -e "${YELLOW}[9/11] Sequential requests (5x)${NC}"
SEQ_PASS=0
for i in $(seq 1 5); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || CODE="000"
    if [[ "$CODE" == "200" ]]; then
        SEQ_PASS=$((SEQ_PASS + 1))
    fi
done

if [[ $SEQ_PASS -eq 5 ]]; then
    pass "5/5 sequential requests returned HTTP 200"
else
    fail "Sequential requests" "Only $SEQ_PASS/5 returned HTTP 200"
fi

# ─── TEST 10: No FD leak (20 requests) ──────────────────────────────
echo -e "${YELLOW}[10/11] FD leak check (20 sequential requests)${NC}"
LEAK_PASS=0
for i in $(seq 1 20); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || CODE="000"
    if [[ "$CODE" == "200" ]]; then
        LEAK_PASS=$((LEAK_PASS + 1))
    fi
done

if [[ $LEAK_PASS -eq 20 ]]; then
    pass "20/20 requests succeeded — no FD exhaustion detected"
else
    fail "FD leak check" "Only $LEAK_PASS/20 succeeded. Possible FD leak."
fi

# ─── TEST 11: Bad client (connect + immediate disconnect) ───────────
echo -e "${YELLOW}[11/11] Bad client resilience${NC}"

# Send 3 rude disconnects
for i in $(seq 1 3); do
    (echo "" | nc -w 1 127.0.0.1 "$PORT" 2>/dev/null) || true
    sleep 0.2
done

# Now try a real request
sleep 0.5
AFTER_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null) || AFTER_CODE="000"

if [[ "$AFTER_CODE" == "200" ]]; then
    pass "Server survives rude client disconnects and still serves HTTP 200"
else
    fail "Bad client resilience" "Server returned HTTP $AFTER_CODE after bad clients (expected 200)"
    # Check if server is still alive
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo -e "         ${RED}↳ SERVER CRASHED after bad client connection${NC}"
    fi
fi

# ─── Results ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Results: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"

if [[ $FAIL -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}${BOLD}  ╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║   TRD-00 COMPLETE — FOUNDATION LAID  ║${NC}"
    echo -e "${GREEN}${BOLD}  ║   Proceed to TRD-01: HTTP Parsing    ║${NC}"
    echo -e "${GREEN}${BOLD}  ╚═══════════════════════════════════════╝${NC}"
else
    echo ""
    echo -e "${RED}${BOLD}  TRD-00 NOT YET COMPLETE — $FAIL test(s) failing${NC}"
    echo -e "  Fix the failures and run again."
fi
echo ""
