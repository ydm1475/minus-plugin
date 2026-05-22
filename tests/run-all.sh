#!/bin/bash
# Run all tests for minus-creator plugin
# Usage: bash tests/run-all.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

echo "╔══════════════════════════════════════╗"
echo "║   Minus Creator Plugin — Test Suite  ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── Shell Script Tests ──
echo "▶ Shell Script Tests"
echo "────────────────────"
if bash "$SCRIPT_DIR/shell-scripts.test.sh"; then
  echo ""
else
  FAILED=1
  echo ""
  echo "  ⚠ Some shell tests failed"
  echo ""
fi

# ── E2E Conversation Replay Tests ──
echo "▶ E2E Conversation Replay Tests"
echo "────────────────────"

for e2e_test in "$SCRIPT_DIR"/e2e-conversation-replay*.test.sh; do
  [ -f "$e2e_test" ] || continue
  echo "  Running $(basename "$e2e_test")..."
  if bash "$e2e_test"; then
    echo ""
  else
    FAILED=1
    echo ""
    echo "  ⚠ $(basename "$e2e_test") failed"
    echo ""
  fi
done

# ── MCP Server Tests ──
echo "▶ MCP Server Tests (Unit)"
echo "────────────────────"
if node --test "$SCRIPT_DIR/mcp-server.test.js" 2>&1 | grep -E "^(ok|not ok|#|$)" | head -30; then
  echo ""
else
  FAILED=1
  echo ""
  echo "  ⚠ Some MCP unit tests failed"
  echo ""
fi

# ── Integration Tests ──
echo "▶ Integration Tests (Mock API → MCP → Shell)"
echo "────────────────────"
if node --test "$SCRIPT_DIR/integration.test.js" 2>&1 | grep -E "^(ok|not ok|#|$)" | head -40; then
  echo ""
else
  FAILED=1
  echo ""
  echo "  ⚠ Some integration tests failed"
  echo ""
fi

# ── Summary ──
echo "╔══════════════════════════════════════╗"
if [ "$FAILED" -eq 0 ]; then
  echo "║         ✓ All tests passed!          ║"
else
  echo "║       ✗ Some tests failed!           ║"
fi
echo "╚══════════════════════════════════════╝"

exit $FAILED
