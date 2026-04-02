#!/bin/bash
# noGlaze! test suite — run after any hook change
set -e

NOGLAZE_DIR="${HOME}/.noglaze"
HOOKS_DIR="$(cd "$(dirname "$0")/hooks" && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "noGlaze! test suite"
echo "==================="
echo ""

# Clean state
rm -f "$NOGLAZE_DIR/audit.jsonl" "$NOGLAZE_DIR/checkpoint.md" "$NOGLAZE_DIR/config.json"
mkdir -p "$NOGLAZE_DIR"

# --- Test 1: audit hook logs code file ---
echo "[1] Audit hook — code file"
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
if grep -q '"code"' "$NOGLAZE_DIR/audit.jsonl" 2>/dev/null; then
    pass "logged with audit_level=code"
else
    fail "audit entry not found or wrong level"
fi

# --- Test 2: audit hook logs content file ---
echo "[2] Audit hook — content file"
echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/t.md"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
if grep -q '"content"' "$NOGLAZE_DIR/audit.jsonl" 2>/dev/null; then
    pass "logged with audit_level=content"
else
    fail "audit entry not found or wrong level"
fi

# --- Test 3: audit hook skips images ---
echo "[3] Audit hook — skip binary files"
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/img.png"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
if [[ "$LINES_BEFORE" == "$LINES_AFTER" ]]; then
    pass "skipped .png file"
else
    fail "should not log binary files"
fi

# --- Test 4: audit hook skips own files ---
echo "[4] Audit hook — skip noglaze's own files"
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo '{"tool_name":"Write","tool_input":{"file_path":"'$HOME'/.noglaze/config.json"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
if [[ "$LINES_BEFORE" == "$LINES_AFTER" ]]; then
    pass "skipped own file"
else
    fail "should not log noglaze's own files"
fi

# --- Test 5: enforce mode outputs audit prompt ---
echo "[5] Audit hook — enforce mode"
echo '{"mode":"enforce"}' > "$NOGLAZE_DIR/config.json"
OUTPUT=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.js"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" 2>&1)
rm -f "$NOGLAZE_DIR/config.json"
if echo "$OUTPUT" | grep -q "noGlaze! audit"; then
    pass "enforce mode outputs audit prompt"
else
    fail "enforce mode did not output prompt"
fi

# --- Test 6: prepush blocks without audit trail ---
echo "[6] Pre-push gate — block without audit trail"
rm -f "$NOGLAZE_DIR/audit.jsonl"
OUTPUT=$(echo '{"tool_input":{"command":"git push origin main"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && BLOCKED=false || BLOCKED=true
if [[ "$BLOCKED" == "true" ]] && echo "$OUTPUT" | grep -q "BLOCKED"; then
    pass "blocked git push with no audit trail"
else
    fail "should have blocked git push"
fi

# --- Test 7: prepush passes with audit trail ---
echo "[7] Pre-push gate — pass with audit trail"
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
OUTPUT=$(echo '{"tool_input":{"command":"git push origin main"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && PASSED_GATE=true || PASSED_GATE=false
if [[ "$PASSED_GATE" == "true" ]]; then
    pass "allowed git push with audit trail"
else
    fail "should have allowed git push"
fi

# --- Test 8: prepush ignores non-external commands ---
echo "[8] Pre-push gate — ignore non-external"
OUTPUT=$(echo '{"tool_input":{"command":"ls -la /tmp"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && PASSED_GATE=true || PASSED_GATE=false
if [[ "$PASSED_GATE" == "true" ]]; then
    pass "ls -la passed silently"
else
    fail "non-external command should pass"
fi

# --- Test 9: prepush catches gh repo create ---
echo "[9] Pre-push gate — catch gh repo create"
rm -f "$NOGLAZE_DIR/audit.jsonl"
OUTPUT=$(echo '{"tool_input":{"command":"gh repo create myrepo --public"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && BLOCKED=false || BLOCKED=true
if [[ "$BLOCKED" == "true" ]]; then
    pass "blocked gh repo create"
else
    fail "should have blocked gh repo create"
fi

# --- Test 10: checkpoint ---
echo "[10] PreCompact checkpoint"
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
echo '{}' | bash "$HOOKS_DIR/precompact-checkpoint.sh" >/dev/null 2>&1
if [[ -f "$NOGLAZE_DIR/checkpoint.md" ]] && grep -q "Total audits" "$NOGLAZE_DIR/checkpoint.md"; then
    pass "checkpoint written with stats"
else
    fail "checkpoint missing or incomplete"
fi

# --- Test 11: JSONL format valid ---
echo "[11] JSONL format validation"
INVALID=$(while IFS= read -r line; do echo "$line" | jq . >/dev/null 2>&1 || echo "BAD"; done < "$NOGLAZE_DIR/audit.jsonl")
if [[ -z "$INVALID" ]]; then
    pass "all JSONL entries are valid JSON"
else
    fail "invalid JSON entries found"
fi

# --- Summary ---
echo ""
echo "==================="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
if [[ $FAIL -gt 0 ]]; then
    echo "❌ $FAIL FAILED"
    exit 1
else
    echo "✅ All tests passed"
    exit 0
fi
