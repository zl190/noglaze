#!/bin/bash
# noGlaze! PreToolUse gate — blocks external actions without test evidence
# Matches: git push, gh repo create, gh pr create, gh release create
#
# Design: registry-based, not command-based. All "outbound" actions
# go through one gate. Add new actions to EXTERNAL_ACTIONS, not new hooks.

set -euo pipefail

NOGLAZE_DIR="${HOME}/.noglaze"
AUDIT_LOG="${NOGLAZE_DIR}/audit.jsonl"
REGISTRY="${NOGLAZE_DIR}/external-actions.json"

mkdir -p "$NOGLAZE_DIR"

# Parse hook input
# Parse hook input from stdin
HOOK_INPUT=$(cat)
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook "$(basename "$0" .sh)" \
  '{ts: $ts, hook: $hook, tool: "Bash"}' >> ~/.claude/logs/hook-fires.jsonl 2>/dev/null || true

# Check if this is an external action
IS_EXTERNAL=false
case "$TOOL_INPUT" in
    git\ push*|gh\ repo\ create*|gh\ pr\ create*|gh\ release\ create*)
        IS_EXTERNAL=true
        ;;
esac

# Also check registry for custom patterns
if [[ -f "$REGISTRY" ]] && [[ "$IS_EXTERNAL" == "false" ]]; then
    PATTERNS=$(jq -r '.[]' "$REGISTRY" 2>/dev/null || echo "")
    while IFS= read -r pattern; do
        if [[ -n "$pattern" ]] && echo "$TOOL_INPUT" | grep -qE "$pattern" 2>/dev/null; then
            IS_EXTERNAL=true
            break
        fi
    done <<< "$PATTERNS"
fi

if [[ "$IS_EXTERNAL" == "false" ]]; then
    exit 0
fi

# --- External action detected. Run gate checks. ---

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ERRORS=()

# Check 1: audit log exists (something was tested)
if [[ ! -f "$AUDIT_LOG" ]] || [[ ! -s "$AUDIT_LOG" ]]; then
    ERRORS+=("No audit trail found. Nothing has been tested this session.")
fi

# Check 2: no unresolved FLAGGED entries
if [[ -f "$AUDIT_LOG" ]]; then
    FLAGGED=$(grep -ci '"flagged"' "$AUDIT_LOG" 2>/dev/null) || FLAGGED=0
    if [[ "$FLAGGED" -gt 0 ]]; then
        ERRORS+=("$FLAGGED flagged audit(s) unresolved. Fix before pushing.")
    fi
fi

# Check 3: at least one audit in the last 30 minutes
if [[ -f "$AUDIT_LOG" ]]; then
    RECENT=$(tail -1 "$AUDIT_LOG" | jq -r '.timestamp // empty' 2>/dev/null || echo "")
    if [[ -n "$RECENT" ]]; then
        # Compare timestamps (basic: just check date matches today)
        TODAY=$(date -u +"%Y-%m-%d")
        AUDIT_DATE=$(echo "$RECENT" | cut -d'T' -f1)
        if [[ "$AUDIT_DATE" != "$TODAY" ]]; then
            ERRORS+=("Last audit was on $AUDIT_DATE, not today. Re-test before pushing.")
        fi
    fi
fi

# Log the gate check
jq -cn \
    --arg ts "$TIMESTAMP" \
    --arg action "$TOOL_INPUT" \
    --arg errors "${ERRORS[*]:-}" \
    --arg verdict "$([ ${#ERRORS[@]} -eq 0 ] && echo 'passed' || echo 'blocked')" \
    '{timestamp: $ts, type: "prepush_gate", action: $action, verdict: $verdict, errors: $errors}' \
    >> "$AUDIT_LOG"

# Verdict
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "noGlaze! 🚫 BLOCKED external action: $TOOL_INPUT" >&2
    for err in "${ERRORS[@]}"; do
        echo "  - $err" >&2
    done
    echo "" >&2
    echo "Fix these issues, then try again." >&2
    exit 2
fi

exit 0
