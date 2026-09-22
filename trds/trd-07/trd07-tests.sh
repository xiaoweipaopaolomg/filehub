#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Conduit TRD-07 — Benchmarking & Documentation
#  This script verifies deliverables and automates benchmarks.
#  Run: chmod +x test_trd07.sh && ./test_trd07.sh
# ═══════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
PORT="${1:-9876}"
PYPORT="9877"
BINARY="./conduit"
SRC="conduit.c"
RESULTS_FILE="benchmark_results.txt"

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; SKIP=$((SKIP + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# ── Create temporary docroot ─────────────────────────────
DOCROOT=$(mktemp -d)
echo '<!DOCTYPE html><html><body>Conduit Benchmark Target</body></html>' > "$DOCROOT/index.html"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${VG_PID:-}" ]] && kill -0 "$VG_PID" 2>/dev/null; then
    kill "$VG_PID" 2>/dev/null; wait "$VG_PID" 2>/dev/null || true
  fi
  if [[ -n "${PY_PID:-}" ]] && kill -0 "$PY_PID" 2>/dev/null; then
    kill "$PY_PID" 2>/dev/null; wait "$PY_PID" 2>/dev/null || true
  fi
  rm -rf "$DOCROOT"
}
trap cleanup EXIT

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Conduit TRD-07 — Final Verification${NC}"
echo -e "${BOLD}  Benchmarking & Documentation${NC}"
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
  pass "Compiles via Makefile"
else
  fail "Compilation failed — cannot continue"
  exit 1
fi

# ── T2: Sanity check ────────────────────────────────────
info "T2: Server sanity check"
$BINARY "$PORT" "$DOCROOT" &
SERVER_PID=$!
sleep 0.5

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/index.html" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
  pass "Server starts and serves index.html"
else
  fail "Server sanity failed ($STATUS)"
  exit 1
fi

# Stop server for valgrind test
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
sleep 0.5

# ── T3: Valgrind memcheck ───────────────────────────────
info "T3: Valgrind memory leak check"
if command -v valgrind &> /dev/null; then
  VG_OUT=$(mktemp)

  valgrind --leak-check=full --show-leak-kinds=all \
    ./conduit "$PORT" "$DOCROOT" 2> "$VG_OUT" &
  VG_PID=$!
  sleep 3  # valgrind startup is slow

  # Exercise code paths
  curl -s --max-time 5 "http://localhost:$PORT/index.html" > /dev/null 2>&1 || true
  curl -s --max-time 5 "http://localhost:$PORT/nonexistent" > /dev/null 2>&1 || true
  curl -s --max-time 5 -X POST "http://localhost:$PORT/" > /dev/null 2>&1 || true
  echo -ne "GARBAGE\r\n\r\n" | nc -w 2 localhost "$PORT" > /dev/null 2>&1 || true
  curl -s --max-time 5 "http://localhost:$PORT/index.html" > /dev/null 2>&1 || true
  sleep 1

  # Graceful shutdown
  kill -TERM "$VG_PID" 2>/dev/null || true
  WAITED=0
  while kill -0 "$VG_PID" 2>/dev/null && [[ "$WAITED" -lt 20 ]]; do
    sleep 0.5
    WAITED=$((WAITED + 1))
  done
  if kill -0 "$VG_PID" 2>/dev/null; then
    kill -9 "$VG_PID" 2>/dev/null || true
  fi
  wait "$VG_PID" 2>/dev/null || true
  VG_PID=""

  # Check for leaks
  DEF_LOST=$(grep "definitely lost:" "$VG_OUT" | grep -oE '[0-9,]+ bytes' | head -1 || echo "unknown")
  if grep -q "definitely lost: 0 bytes" "$VG_OUT"; then
    pass "Valgrind: 0 bytes definitely lost"
  else
    fail "Valgrind: definitely lost: $DEF_LOST"
    echo "       Full report: $VG_OUT"
  fi
  rm -f "$VG_OUT"
else
  skip "valgrind not installed"
fi
sleep 0.5

# ── T4 & T5: wrk benchmarks ─────────────────────────────
info "T4: wrk benchmark suite"
if command -v wrk &> /dev/null; then
  # Restart server for benchmarking
  $BINARY "$PORT" "$DOCROOT" &
  SERVER_PID=$!
  sleep 0.5

  echo "" > "$RESULTS_FILE"
  echo "═══════════════════════════════════════════════" >> "$RESULTS_FILE"
  echo "  Conduit Benchmark Results" >> "$RESULTS_FILE"
  echo "  $(date)" >> "$RESULTS_FILE"
  echo "  Host: $(uname -n) | $(uname -m) | $(nproc) cores" >> "$RESULTS_FILE"
  echo "  File: index.html | Duration: 10s | Threads: 2" >> "$RESULTS_FILE"
  echo "═══════════════════════════════════════════════" >> "$RESULTS_FILE"
  echo "" >> "$RESULTS_FILE"

  # Warm up
  wrk -t2 -c10 -d5s "http://localhost:$PORT/index.html" > /dev/null 2>&1 || true

  BENCH_OK=0
  for CONNS in 1 10 50 100; do
    echo "--- Concurrency: $CONNS ---" >> "$RESULTS_FILE"
    WRK_OUT=$(wrk -t2 -c"$CONNS" -d10s --latency "http://localhost:$PORT/index.html" 2>&1 || true)
    echo "$WRK_OUT" >> "$RESULTS_FILE"
    echo "" >> "$RESULTS_FILE"

    # Check wrk produced output
    if echo "$WRK_OUT" | grep -q "Requests/sec"; then
      BENCH_OK=$((BENCH_OK + 1))
      RPS=$(echo "$WRK_OUT" | grep "Requests/sec" | awk '{print $2}')
      P99=$(echo "$WRK_OUT" | grep "99%" | awk '{print $2}')
      info "  c=$CONNS: ${RPS} req/s, p99=${P99:-n/a}"
    fi
  done

  if [[ "$BENCH_OK" -eq 4 ]]; then
    pass "wrk completed at all 4 concurrency levels"
  else
    fail "wrk completed at $BENCH_OK/4 levels"
  fi

  # T5: Results file
  info "T5: Benchmark results saved"
  if [[ -s "$RESULTS_FILE" ]]; then
    pass "Results saved to $RESULTS_FILE"
  else
    fail "Results file empty or missing"
  fi

  # Stop server
  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  sleep 0.5
else
  skip "wrk not installed — install with: sudo apt install wrk"
  skip "T5 skipped (depends on wrk)"
fi

# ── T6: README.md check ─────────────────────────────────
info "T6: README.md exists with required sections"
if [[ -f "README.md" ]]; then
  SECTIONS_FOUND=0
  SECTIONS_MISSING=""

  for SECTION in "architecture" "build" "benchmark" "design" "limitation"; do
    if grep -qi "$SECTION" README.md; then
      SECTIONS_FOUND=$((SECTIONS_FOUND + 1))
    else
      SECTIONS_MISSING="$SECTIONS_MISSING $SECTION"
    fi
  done

  if [[ "$SECTIONS_FOUND" -ge 4 ]]; then
    pass "README.md found with $SECTIONS_FOUND/5 required sections"
  else
    fail "README.md missing sections:$SECTIONS_MISSING"
  fi
else
  fail "README.md not found in current directory"
fi

# ── T7: Python baseline comparison ──────────────────────
info "T7: Python http.server baseline comparison"
if command -v wrk &> /dev/null && command -v python3 &> /dev/null; then
  # Start Python server
  (cd "$DOCROOT" && python3 -m http.server "$PYPORT" > /dev/null 2>&1) &
  PY_PID=$!
  sleep 1

  if kill -0 "$PY_PID" 2>/dev/null; then
    echo "" >> "$RESULTS_FILE"
    echo "═══════════════════════════════════════════════" >> "$RESULTS_FILE"
    echo "  Python http.server Baseline (port $PYPORT)" >> "$RESULTS_FILE"
    echo "═══════════════════════════════════════════════" >> "$RESULTS_FILE"
    echo "" >> "$RESULTS_FILE"

    PY_OK=0
    for CONNS in 1 10 50; do
      echo "--- Concurrency: $CONNS ---" >> "$RESULTS_FILE"
      PY_OUT=$(wrk -t2 -c"$CONNS" -d10s --latency "http://localhost:$PYPORT/index.html" 2>&1 || true)
      echo "$PY_OUT" >> "$RESULTS_FILE"
      echo "" >> "$RESULTS_FILE"

      if echo "$PY_OUT" | grep -q "Requests/sec"; then
        PY_OK=$((PY_OK + 1))
        RPS=$(echo "$PY_OUT" | grep "Requests/sec" | awk '{print $2}')
        info "  Python c=$CONNS: ${RPS} req/s"
      fi
    done

    kill "$PY_PID" 2>/dev/null; wait "$PY_PID" 2>/dev/null || true
    PY_PID=""

    if [[ "$PY_OK" -ge 2 ]]; then
      pass "Python baseline collected ($PY_OK/3 levels)"
    else
      fail "Python baseline incomplete ($PY_OK/3)"
    fi
  else
    fail "Python http.server failed to start"
  fi
else
  skip "wrk or python3 not available for baseline"
fi

# ── Results ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Results: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / ${YELLOW}$SKIP skipped${NC} / $TOTAL total"
if [[ -s "$RESULTS_FILE" ]]; then
  echo -e "  Benchmark data: ${BOLD}$RESULTS_FILE${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}Issues found.${NC} Fix leaks, complete README, then re-run."
  exit 1
else
  echo -e "${GREEN}All checks passed.${NC}"
  echo ""
  echo -e "  ${BOLD}Conduit is complete.${NC}"
  echo ""
  echo "  Next steps:"
  echo "    1. Copy benchmark data from $RESULTS_FILE into README.md"
  echo "    2. Add hardware specs and methodology notes"
  echo "    3. Commit, tag (git tag v1.0), push"
  echo "    4. Verify README renders correctly on GitHub"
  echo ""
  exit 0
fi