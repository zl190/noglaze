#!/bin/bash
# noGlaze! PostToolUse audit hook
# Triggers after Write/Edit — checks if output survives adversarial review
# exit 0 = pass (advisory log), exit 2 = block (enforcement)
#
# Origin: learned from Claude Code source (513K lines) — hooks use exit 2
# for system-level enforcement that works even when context degrades.

set -euo pipefail

NOGLAZE_DIR="${HOME}/.noglaze"
AUDIT_LOG="${NOGLAZE_DIR}/audit.jsonl"
CONFIG="${NOGLAZE_DIR}/config.json"
# Resolve auditor prompt relative to hook location (works as plugin or local)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDITOR_PROMPT="${SCRIPT_DIR}/../agents/auditor.md"

mkdir -p "$NOGLAZE_DIR"

# Parse hook input from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"hook\":\"$(basename "$0" .sh)\",\"tool\":\"${TOOL_NAME:-unknown}\"}" >> ~/.claude/logs/hook-fires.jsonl 2>/dev/null || true

# Skip if not a write operation or no file path
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Skip noglaze's own files to prevent recursion
if [[ "$FILE_PATH" == *"/.noglaze/"* ]] || [[ "$FILE_PATH" == *"/noglaze/"* ]]; then
    exit 0
fi

# Skip non-code files (images, binaries, etc)
case "$FILE_PATH" in
    *.png|*.jpg|*.gif|*.pdf|*.zip|*.tar|*.gz|*.lock|*.sum)
        exit 0
        ;;
esac

# Read enforcement mode from config (default: advisory)
MODE="advisory"
if [[ -f "$CONFIG" ]]; then
    MODE=$(jq -r '.mode // "advisory"' "$CONFIG" 2>/dev/null || echo "advisory")
fi

# Log the audit event
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BASENAME=$(basename "$FILE_PATH")
EXTENSION="${BASENAME##*.}"

# Determine audit level based on file type
AUDIT_LEVEL="standard"
case "$EXTENSION" in
    md|txt)
        AUDIT_LEVEL="content"  # check claims, AI smell
        ;;
    py|ts|js|go|rs|java)
        AUDIT_LEVEL="code"     # check tests, error handling, docstring accuracy
        ;;
    sh|bash)
        AUDIT_LEVEL="script"   # check safety, shellcheck patterns
        ;;
    json|yaml|yml|toml)
        AUDIT_LEVEL="config"   # check schema, no secrets
        ;;
esac

# ── Run subagent audit ──
# Returns "PASS" or "FAIL: <reason>" via stdout
# Fails open on any infrastructure error (claude not found, timeout, etc.)
run_audit() {
    local file="$1"

    # Skip if file doesn't exist (can't audit what isn't there)
    [[ ! -f "$file" ]] && echo "PASS" && return

    # Skip if claude command not available — fail open
    if ! command -v claude >/dev/null 2>&1; then
        echo "PASS"
        return
    fi

    # Skip if auditor prompt not available — fail open
    if [[ ! -f "$AUDITOR_PROMPT" ]]; then
        echo "PASS"
        return
    fi

    local prompt
    prompt=$(cat "$AUDITOR_PROMPT")
    local content
    content=$(cat "$file" 2>/dev/null || echo "")

    local subagent_input
    subagent_input="$(printf '%s\n\nNow audit this file: %s\n\n%s' "$prompt" "$file" "$content")"

    local result
    # Timeout 30s — fail open if it hangs
    result=$(echo "$subagent_input" | timeout 30 claude -p 2>/dev/null) || { echo "PASS"; return; }

    # Parse verdict: look for PASSED or FLAGGED in auditor output format
    if echo "$result" | grep -qiE 'Verdict:\s*(FLAGGED|FAIL)'; then
        local reason
        reason=$(echo "$result" | grep -iE 'Verdict:' | head -1)
        echo "FAIL: $reason"
    else
        echo "PASS"
    fi
}
# Announce audit start — "noGlaze! audit" text required by test 5
echo "[noGlaze! audit] File written: $FILE_PATH ($AUDIT_LEVEL)" >&2

VERDICT_RESULT=$(run_audit "$FILE_PATH")
VERDICT="PASS"
VERDICT_REASON=""

if [[ "$VERDICT_RESULT" == FAIL* ]]; then
    VERDICT="FAIL"
    VERDICT_REASON="${VERDICT_RESULT#FAIL: }"
else
    VERDICT="PASS"
fi

# Write audit entry (compact single-line JSONL) with actual verdict
jq -cn \
    --arg ts "$TIMESTAMP" \
    --arg tool "$TOOL_NAME" \
    --arg file "$FILE_PATH" \
    --arg level "$AUDIT_LEVEL" \
    --arg mode "$MODE" \
    --arg verdict "$VERDICT" \
    --arg reason "$VERDICT_REASON" \
    '{timestamp: $ts, tool: $tool, file: $file, audit_level: $level, mode: $mode, verdict: $verdict, reason: $reason}' \
    >> "$AUDIT_LOG"

# Enforce mode: exit 2 on FAIL verdict
if [[ "$MODE" == "enforce" ]] && [[ "$VERDICT" == "FAIL" ]]; then
    echo "╔══════════════════════════════════════════╗" >&2
    echo "║  noGlaze! AUDIT BLOCKED                  ║" >&2
    echo "╚══════════════════════════════════════════╝" >&2
    echo "  File: $FILE_PATH" >&2
    echo "  Reason: $VERDICT_REASON" >&2
    echo "  Fix the issues above before proceeding." >&2
    exit 2
fi

# Advisory mode (or enforce+PASS): always exit 0
exit 0
