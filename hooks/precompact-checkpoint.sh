#!/bin/bash
# noGlaze! PreCompact hook — saves audit state before context compression
# Learned from tanweai/pua's PreCompact pattern: state must survive compaction.

NOGLAZE_DIR="${HOME}/.noglaze"
AUDIT_LOG="${NOGLAZE_DIR}/audit.jsonl"
CHECKPOINT="${NOGLAZE_DIR}/checkpoint.md"

mkdir -p "$NOGLAZE_DIR"

if [[ ! -f "$AUDIT_LOG" ]]; then
    exit 0
fi

# Count audit stats
TOTAL=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
PENDING=$(grep -ci '"pending"' "$AUDIT_LOG" 2>/dev/null) || PENDING=0
PASSED=$(grep -ci '"pass"' "$AUDIT_LOG" 2>/dev/null) || PASSED=0
FLAGGED=$(grep -ci '"flagged"' "$AUDIT_LOG" 2>/dev/null) || FLAGGED=0

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$CHECKPOINT" <<EOF
# noGlaze! Checkpoint — $TIMESTAMP

## Audit Stats
- Total audits: $TOTAL
- Passed: $PASSED
- Flagged: $FLAGGED
- Pending: $PENDING

## Recent Audits (last 5)
$(tail -5 "$AUDIT_LOG" | jq -r '"- \(.file) [\(.audit_level)] → \(.verdict)"' 2>/dev/null || echo "- (no entries)")

## State
Audit enforcement is active. Do not skip quality checks after compaction.
EOF

echo "[noGlaze!] Checkpoint saved. $TOTAL audits ($FLAGGED flagged)."
exit 0
