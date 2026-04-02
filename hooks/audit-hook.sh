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

mkdir -p "$NOGLAZE_DIR"

# Parse hook input from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

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

# Write audit entry
jq -n \
    --arg ts "$TIMESTAMP" \
    --arg tool "$TOOL_NAME" \
    --arg file "$FILE_PATH" \
    --arg level "$AUDIT_LEVEL" \
    --arg mode "$MODE" \
    --arg verdict "pending" \
    '{timestamp: $ts, tool: $tool, file: $file, audit_level: $level, mode: $mode, verdict: $verdict}' \
    >> "$AUDIT_LOG"

# In enforcement mode, output the audit prompt for Claude to evaluate
if [[ "$MODE" == "enforce" ]]; then
    cat <<PROMPT
[noGlaze! audit] File written: $FILE_PATH ($AUDIT_LEVEL)

Before proceeding, verify this output:
1. Does the code/content do what it claims?
2. Are there untested edge cases or unhandled errors?
3. Does the docstring/comment match actual behavior?
4. Would this survive adversarial review?

If ANY check fails, revise before continuing. This is not optional.
PROMPT
fi

# Advisory mode: always pass, just log
# Enforce mode: prompt injected, Claude self-audits
exit 0
