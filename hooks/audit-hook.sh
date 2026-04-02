#!/bin/bash
# noGlaze! PostToolUse audit hook v0.3
# Triggers after Write/Edit — checks if output survives adversarial review
# exit 0 = pass (advisory log), exit 2 = block (enforcement)
#
# Origin: learned from Claude Code source (513K lines) — hooks use exit 2
# for system-level enforcement that works even when context degrades.

set -euo pipefail

NOGLAZE_DIR="${HOME}/.noglaze"
AUDIT_LOG="${NOGLAZE_DIR}/audit.jsonl"
LEGACY_CONFIG="${NOGLAZE_DIR}/config.json"
# Resolve auditor prompt relative to hook location (works as plugin or local)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDITOR_PROMPT="${SCRIPT_DIR}/../agents/auditor.md"

mkdir -p "$NOGLAZE_DIR"

# Parse hook input from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook "$(basename "$0" .sh)" --arg tool "${TOOL_NAME:-unknown}" \
  '{ts: $ts, hook: $hook, tool: $tool}' >> ~/.claude/logs/hook-fires.jsonl 2>/dev/null || true

# Skip if not a write operation or no file path
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Skip noglaze's own files to prevent recursion
if [[ "$FILE_PATH" == *"/.noglaze/"* ]] || [[ "$FILE_PATH" == *"/noglaze/"* ]]; then
    exit 0
fi

# ── Load config (.noglaze YAML takes precedence over legacy JSON) ──
MODE="advisory"
STRICTNESS="default"
TIMEOUT=60
SKIP_PATTERNS=()

load_noglaze_config() {
    local dir="$1"
    local config_file="${dir}/.noglaze"
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    # Parse simple YAML: key: value pairs only (no nested blocks)
    local raw_strictness raw_timeout raw_skip raw_mode
    raw_strictness=$(grep -E '^strictness:' "$config_file" | sed 's/strictness:[[:space:]]*//' | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
    raw_timeout=$(grep -E '^timeout:' "$config_file" | sed 's/timeout:[[:space:]]*//' | tr -d '"' | tr -d "'" 2>/dev/null || echo "")
    raw_mode=$(grep -E '^mode:' "$config_file" | sed 's/mode:[[:space:]]*//' | tr -d '"' | tr -d "'" 2>/dev/null || echo "")

    [[ -n "$raw_strictness" ]] && STRICTNESS="$raw_strictness"
    [[ -n "$raw_timeout" ]] && TIMEOUT="$raw_timeout"
    [[ -n "$raw_mode" ]] && MODE="$raw_mode"

    # Parse skip_patterns list: lines starting with "  - " after "skip_patterns:"
    local in_skip=false
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^skip_patterns:'; then
            in_skip=true
            continue
        fi
        if [[ "$in_skip" == "true" ]]; then
            if echo "$line" | grep -qE '^[[:space:]]*-[[:space:]]'; then
                local pat
                pat=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d '"' | tr -d "'")
                SKIP_PATTERNS+=("$pat")
            else
                in_skip=false
            fi
        fi
    done < "$config_file"
    return 0
}

# Search for .noglaze config: file's directory, then parents up to home
CONFIG_LOADED=false
if [[ -n "$FILE_PATH" ]]; then
    dir="$(dirname "$FILE_PATH")"
    while [[ "$dir" != "/" ]] && [[ "$dir" != "$HOME" ]]; do
        if load_noglaze_config "$dir" 2>/dev/null; then
            CONFIG_LOADED=true
            break
        fi
        dir="$(dirname "$dir")"
    done
    if [[ "$CONFIG_LOADED" == "false" ]]; then
        load_noglaze_config "$HOME" 2>/dev/null || true
    fi
fi

# Fall back to legacy JSON config
if [[ "$CONFIG_LOADED" == "false" ]] && [[ -f "$LEGACY_CONFIG" ]]; then
    MODE=$(jq -r '.mode // "advisory"' "$LEGACY_CONFIG" 2>/dev/null || echo "advisory")
    STRICTNESS=$(jq -r '.strictness // "default"' "$LEGACY_CONFIG" 2>/dev/null || echo "default")
    TIMEOUT=$(jq -r '.timeout // 60' "$LEGACY_CONFIG" 2>/dev/null || echo "60")
fi

# Apply strictness → mode override (strict always enforces)
if [[ "$STRICTNESS" == "strict" ]] && [[ "$MODE" == "advisory" ]]; then
    MODE="enforce"
fi

# ── Apply skip_patterns ──
should_skip_by_pattern() {
    local file="$1"
    local basename
    basename="$(basename "$file")"
    for pat in "${SKIP_PATTERNS[@]:-}"; do
        [[ -z "$pat" ]] && continue
        # Shell glob match against basename or full path
        # shellcheck disable=SC2053
        if [[ "$basename" == $pat ]] || [[ "$file" == $pat ]]; then
            return 0
        fi
    done
    return 1
}

if should_skip_by_pattern "$FILE_PATH"; then
    exit 0
fi

# Skip built-in binary/non-code files
case "$FILE_PATH" in
    *.png|*.jpg|*.gif|*.pdf|*.zip|*.tar|*.gz|*.lock|*.sum)
        exit 0
        ;;
esac

# Skip empty and very large files (>500KB) — too expensive to audit
if [[ -f "$FILE_PATH" ]]; then
    FILE_SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ') || FILE_SIZE=0
    if [[ "$FILE_SIZE" -eq 0 ]]; then
        exit 0
    fi
    if [[ "$FILE_SIZE" -gt 512000 ]]; then
        echo "[noGlaze! audit] Skipping large file (${FILE_SIZE} bytes): $FILE_PATH" >&2
        exit 0
    fi
fi

# Skip binary files (check for null bytes in first 8KB via python3 for portability)
if [[ -f "$FILE_PATH" ]] && python3 -c "
import sys
try:
    data = open(sys.argv[1], 'rb').read(8192)
    is_binary = b'\x00' in data
except Exception:
    is_binary = False
sys.exit(0 if is_binary else 1)
" "$FILE_PATH" 2>/dev/null; then
    exit 0
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
# Returns structured JSON result via stdout on success, or "PASS" as fallback
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
    subagent_input="$(printf 'STRICTNESS=%s\n\n%s\n\nNow audit this file: %s\n\n%s' "$STRICTNESS" "$prompt" "$file" "$content")"

    local result
    # Use configured timeout — fail open if it hangs
    result=$(echo "$subagent_input" | timeout "$TIMEOUT" claude -p 2>/dev/null) || { echo "PASS"; return; }

    # Try to extract JSON from result (auditor should output pure JSON)
    local json_result
    json_result=$(echo "$result" | python3 -c "
import sys, json, re
text = sys.stdin.read()
# Try direct JSON parse
try:
    obj = json.loads(text.strip())
    print(json.dumps(obj))
    sys.exit(0)
except:
    pass
# Try to find JSON block in text
match = re.search(r'\\{[\\s\\S]*\\}', text)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj))
        sys.exit(0)
    except:
        pass
sys.exit(1)
" 2>/dev/null) || json_result=""

    if [[ -n "$json_result" ]]; then
        # Valid JSON from auditor — use structured verdict
        local verdict
        verdict=$(echo "$json_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('verdict','PASS'))" 2>/dev/null || echo "PASS")
        if [[ "$verdict" == "FAIL" ]] || [[ "$verdict" == "FLAGGED" ]]; then
            echo "FAIL_JSON:${json_result}"
        else
            echo "PASS_JSON:${json_result}"
        fi
    else
        # Fallback: parse free-text verdict (legacy format)
        if echo "$result" | grep -qiE 'Verdict:\s*(FLAGGED|FAIL)'; then
            local reason
            reason=$(echo "$result" | grep -iE 'Verdict:' | head -1)
            echo "FAIL: $reason"
        else
            echo "PASS"
        fi
    fi
}

# Announce audit start — "noGlaze! audit" text required by test 5
echo "[noGlaze! audit] File written: $FILE_PATH ($AUDIT_LEVEL, strictness=$STRICTNESS)" >&2

VERDICT_RESULT=$(run_audit "$FILE_PATH")
VERDICT="PASS"
VERDICT_REASON=""
AUDIT_JSON=""

if [[ "$VERDICT_RESULT" == FAIL_JSON:* ]]; then
    VERDICT="FLAGGED"
    AUDIT_JSON="${VERDICT_RESULT#FAIL_JSON:}"
    # Extract reason from JSON
    VERDICT_REASON=$(echo "$AUDIT_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
gaps = d.get('gaps_found', [])
if gaps:
    print('; '.join(g.get('issue','') for g in gaps[:3]))
else:
    print('See audit JSON for details')
" 2>/dev/null || echo "Audit flagged issues")
elif [[ "$VERDICT_RESULT" == PASS_JSON:* ]]; then
    VERDICT="PASS"
    AUDIT_JSON="${VERDICT_RESULT#PASS_JSON:}"
elif [[ "$VERDICT_RESULT" == FAIL* ]]; then
    VERDICT="FLAGGED"
    VERDICT_REASON="${VERDICT_RESULT#FAIL: }"
else
    VERDICT="PASS"
fi

# Write audit entry (compact single-line JSONL) with actual verdict
if [[ -n "$AUDIT_JSON" ]]; then
    # Write enriched entry with full audit chain
    jq -cn \
        --arg ts "$TIMESTAMP" \
        --arg tool "$TOOL_NAME" \
        --arg file "$FILE_PATH" \
        --arg level "$AUDIT_LEVEL" \
        --arg mode "$MODE" \
        --arg strictness "$STRICTNESS" \
        --arg verdict "$VERDICT" \
        --arg reason "$VERDICT_REASON" \
        --argjson audit_detail "$AUDIT_JSON" \
        '{timestamp: $ts, tool: $tool, file: $file, audit_level: $level, mode: $mode, strictness: $strictness, verdict: $verdict, reason: $reason, audit: $audit_detail}' \
        >> "$AUDIT_LOG"
else
    jq -cn \
        --arg ts "$TIMESTAMP" \
        --arg tool "$TOOL_NAME" \
        --arg file "$FILE_PATH" \
        --arg level "$AUDIT_LEVEL" \
        --arg mode "$MODE" \
        --arg strictness "$STRICTNESS" \
        --arg verdict "$VERDICT" \
        --arg reason "$VERDICT_REASON" \
        '{timestamp: $ts, tool: $tool, file: $file, audit_level: $level, mode: $mode, strictness: $strictness, verdict: $verdict, reason: $reason}' \
        >> "$AUDIT_LOG"
fi

# Enforce mode: exit 2 on FLAGGED or FAIL verdict
if [[ "$MODE" == "enforce" ]] && [[ "$VERDICT" != "PASS" ]]; then
    echo "╔══════════════════════════════════════════╗" >&2
    echo "║  noGlaze! AUDIT BLOCKED                  ║" >&2
    echo "╚══════════════════════════════════════════╝" >&2
    echo "  File: $FILE_PATH" >&2
    echo "  Verdict: $VERDICT" >&2
    echo "  Reason: $VERDICT_REASON" >&2
    echo "  Fix the issues above before proceeding." >&2
    exit 2
fi

# Advisory mode (or enforce+PASS): always exit 0
exit 0
