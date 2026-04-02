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
rm -f /tmp/.noglaze /tmp/noglaze_test/.noglaze
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

# --- Test 10: registry-based matching (custom patterns) ---
echo "[10] Pre-push gate — registry custom pattern"
rm -f "$NOGLAZE_DIR/audit.jsonl"
echo '["npm publish", "docker push"]' > "$NOGLAZE_DIR/external-actions.json"
OUTPUT=$(echo '{"tool_input":{"command":"docker push myimage"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && BLOCKED=false || BLOCKED=true
rm -f "$NOGLAZE_DIR/external-actions.json"
if [[ "$BLOCKED" == "true" ]] && echo "$OUTPUT" | grep -q "BLOCKED"; then
    pass "registry caught docker push"
else
    fail "registry should have caught docker push"
fi

# --- Test 11: checkpoint ---
echo "[11] PreCompact checkpoint"
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
echo '{}' | bash "$HOOKS_DIR/precompact-checkpoint.sh" >/dev/null 2>&1
if [[ -f "$NOGLAZE_DIR/checkpoint.md" ]] && grep -q "Total audits" "$NOGLAZE_DIR/checkpoint.md"; then
    pass "checkpoint written with stats"
else
    fail "checkpoint missing or incomplete"
fi

# --- Test 12: JSONL format valid ---
echo "[12] JSONL format validation"
INVALID=$(while IFS= read -r line; do echo "$line" | jq . >/dev/null 2>&1 || echo "BAD"; done < "$NOGLAZE_DIR/audit.jsonl")
if [[ -z "$INVALID" ]]; then
    pass "all JSONL entries are valid JSON"
else
    fail "invalid JSON entries found"
fi

# --- Test 13: empty file is skipped (no audit, no log entry) ---
echo "[13] Audit hook — skip empty file"
EMPTY_FILE=$(mktemp /tmp/noglaze_empty_XXXX.py)
# File is already empty from mktemp
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$EMPTY_FILE\"}}" \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
rm -f "$EMPTY_FILE"
if [[ "$LINES_BEFORE" == "$LINES_AFTER" ]]; then
    pass "empty file skipped (no audit entry)"
else
    fail "empty file should not generate audit entry"
fi

# --- Test 14: very large file is skipped ---
echo "[14] Audit hook — skip very large file (>512KB)"
LARGE_FILE=$(mktemp /tmp/noglaze_large_XXXX.py)
# Write 600KB of content
dd if=/dev/zero bs=1024 count=600 2>/dev/null | tr '\0' 'x' > "$LARGE_FILE"
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$LARGE_FILE\"}}" \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
rm -f "$LARGE_FILE"
if [[ "$LINES_BEFORE" == "$LINES_AFTER" ]]; then
    pass "large file skipped (>512KB)"
else
    fail "large file should be skipped to avoid expensive audit"
fi

# --- Test 15: binary file with null bytes is skipped ---
echo "[15] Audit hook — skip file with null bytes (binary)"
BINARY_FILE=$(mktemp /tmp/noglaze_bin_XXXX.py)
printf 'hello\x00world' > "$BINARY_FILE"
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BINARY_FILE\"}}" \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
rm -f "$BINARY_FILE"
if [[ "$LINES_BEFORE" == "$LINES_AFTER" ]]; then
    pass "binary file (null bytes) skipped"
else
    fail "binary file should be skipped"
fi

# --- Test 16: .noglaze config skip_patterns respected ---
echo "[16] .noglaze config — skip_patterns"
mkdir -p /tmp/noglaze_test
cat > /tmp/noglaze_test/.noglaze <<'YAMLEOF'
strictness: default
skip_patterns:
  - "*.md"
  - "*.txt"
timeout: 60
YAMLEOF
# Create a real .md file so it would normally be logged
MD_FILE="/tmp/noglaze_test/readme.md"
echo "# Hello" > "$MD_FILE"
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MD_FILE\"}}" \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
rm -f "$MD_FILE" /tmp/noglaze_test/.noglaze
rmdir /tmp/noglaze_test 2>/dev/null || true
if [[ "$LINES_BEFORE" == "$LINES_AFTER" ]]; then
    pass ".noglaze skip_patterns blocked *.md from audit"
else
    fail ".noglaze skip_patterns should skip *.md files"
fi

# --- Test 17: .noglaze config strictness field is logged ---
echo "[17] .noglaze config — strictness field in audit log"
cat > "$NOGLAZE_DIR/config.json" <<'JSONEOF'
{"mode": "advisory", "strictness": "strict"}
JSONEOF
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t2.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
rm -f "$NOGLAZE_DIR/config.json"
if grep -q '"strictness"' "$NOGLAZE_DIR/audit.jsonl" 2>/dev/null; then
    pass "strictness field present in audit log"
else
    fail "strictness field missing from audit log"
fi

# --- Test 18: enforce mode PASS path exits 0 ---
echo "[18] Integration — enforce mode PASS exits 0"
echo '{"mode":"enforce"}' > "$NOGLAZE_DIR/config.json"
EXIT_CODE=0
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/nonexistent_audit_test.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1 || EXIT_CODE=$?
rm -f "$NOGLAZE_DIR/config.json"
if [[ "$EXIT_CODE" -eq 0 ]]; then
    pass "enforce mode with PASS verdict exits 0"
else
    fail "enforce mode with PASS verdict should exit 0, got $EXIT_CODE"
fi

# --- Test 19: prepush gate logs verdict to JSONL ---
echo "[19] Pre-push gate — logs verdict to JSONL"
# Recreate audit trail first so push is allowed
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.py"}}' \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
LINES_BEFORE=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
echo '{"tool_input":{"command":"git push origin main"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" >/dev/null 2>&1 || true
LINES_AFTER=$(wc -l < "$NOGLAZE_DIR/audit.jsonl" | tr -d ' ')
if [[ "$LINES_AFTER" -gt "$LINES_BEFORE" ]]; then
    pass "prepush gate appends verdict to audit log"
else
    fail "prepush gate should log verdict to JSONL"
fi

# --- Test 20: audit log contains timestamp field ---
echo "[20] JSONL — entries have timestamp field"
if grep -q '"timestamp"' "$NOGLAZE_DIR/audit.jsonl" 2>/dev/null; then
    pass "audit entries contain timestamp field"
else
    fail "audit entries missing timestamp field"
fi

# --- Test 21: prepush catches gh pr create ---
echo "[21] Pre-push gate — catch gh pr create"
rm -f "$NOGLAZE_DIR/audit.jsonl"
OUTPUT=$(echo '{"tool_input":{"command":"gh pr create --title test"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && BLOCKED=false || BLOCKED=true
if [[ "$BLOCKED" == "true" ]] && echo "$OUTPUT" | grep -q "BLOCKED"; then
    pass "blocked gh pr create without audit trail"
else
    fail "should have blocked gh pr create"
fi

# --- Test 22: audit hook skips file with no extension that has binary content ---
echo "[22] Audit hook — script audit level for .sh files"
SH_FILE=$(mktemp /tmp/noglaze_script_XXXX.sh)
echo '#!/bin/bash\necho hello' > "$SH_FILE"
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SH_FILE\"}}" \
  | bash "$HOOKS_DIR/audit-hook.sh" >/dev/null 2>&1
rm -f "$SH_FILE"
if grep -q '"script"' "$NOGLAZE_DIR/audit.jsonl" 2>/dev/null; then
    pass ".sh file logged with audit_level=script"
else
    fail ".sh file should be logged with audit_level=script"
fi

# --- Test 23: FLAGGED entry blocks prepush (cross-component integration) ---
echo "[23] Integration — FLAGGED audit entry blocks prepush"
rm -f "$NOGLAZE_DIR/audit.jsonl"
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Write a PASS entry first (so audit trail exists), then a FLAGGED entry
jq -cn --arg ts "$NOW_TS" '{timestamp:$ts,tool:"Write",file:"/tmp/ok.py",verdict:"PASS"}' >> "$NOGLAZE_DIR/audit.jsonl"
jq -cn --arg ts "$NOW_TS" '{timestamp:$ts,tool:"Write",file:"/tmp/bad.py",verdict:"FLAGGED"}' >> "$NOGLAZE_DIR/audit.jsonl"
OUTPUT=$(echo '{"tool_input":{"command":"git push origin main"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && BLOCKED=false || BLOCKED=true
if [[ "$BLOCKED" == "true" ]] && echo "$OUTPUT" | grep -q "BLOCKED"; then
    pass "FLAGGED entry in audit.jsonl blocks git push"
else
    fail "FLAGGED entry should block git push (case mismatch bug?)"
fi

# --- Test 24: checkpoint stats count verdicts correctly ---
echo "[24] Checkpoint — stats count PASS and FLAGGED correctly"
rm -f "$NOGLAZE_DIR/audit.jsonl" "$NOGLAZE_DIR/checkpoint.md"
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Write entries with UPPERCASE verdicts (as audit-hook.sh produces)
jq -cn --arg ts "$NOW_TS" '{timestamp:$ts,verdict:"PASS"}' >> "$NOGLAZE_DIR/audit.jsonl"
jq -cn --arg ts "$NOW_TS" '{timestamp:$ts,verdict:"PASS"}' >> "$NOGLAZE_DIR/audit.jsonl"
jq -cn --arg ts "$NOW_TS" '{timestamp:$ts,verdict:"FLAGGED"}' >> "$NOGLAZE_DIR/audit.jsonl"
echo '{}' | bash "$HOOKS_DIR/precompact-checkpoint.sh" >/dev/null 2>&1
if grep -q "Passed: 2" "$NOGLAZE_DIR/checkpoint.md" 2>/dev/null && \
   grep -q "Flagged: 1" "$NOGLAZE_DIR/checkpoint.md" 2>/dev/null; then
    pass "checkpoint counts PASS=2, FLAGGED=1 correctly"
else
    fail "checkpoint stats wrong (case mismatch?)"
fi

# --- Test 25: prepush passes when only PASS entries exist ---
echo "[25] Integration — only PASS entries allows push"
rm -f "$NOGLAZE_DIR/audit.jsonl"
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -cn --arg ts "$NOW_TS" '{timestamp:$ts,verdict:"PASS"}' >> "$NOGLAZE_DIR/audit.jsonl"
OUTPUT=$(echo '{"tool_input":{"command":"git push origin main"}}' \
  | bash "$HOOKS_DIR/prepush-gate.sh" 2>&1) && PASSED_GATE=true || PASSED_GATE=false
if [[ "$PASSED_GATE" == "true" ]]; then
    pass "push allowed with only PASS entries"
else
    fail "push should be allowed with only PASS entries"
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
