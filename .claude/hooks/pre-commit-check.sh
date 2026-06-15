#!/bin/bash
# Pre-commit pitfall checker for GDScript files.
# Runs on staged .gd files in this repo, checks for project-specific mistakes.
# Exit 2 = block the commit, exit 0 = allow.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only run on git commit commands
echo "$CMD" | grep -qE '^git commit' || exit 0

REPO="${CLAUDE_PROJECT_DIR:-/mnt/based_backup/Repos/Godot-SpacetimeDB-SDK}"
ISSUES=""
CAVEMAN_MSG="Use caveman:caveman-commit skill to generate the commit message. Conventional Commits format, subject <=50 chars, drop articles/filler, body only if 'why' non-obvious."

# Get staged .gd files
STAGED=$(git -C "$REPO" diff --cached --name-only --diff-filter=ACMR | grep '\.gd$' || true)
if [ -z "$STAGED" ]; then
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"$CAVEMAN_MSG\"}}"
    exit 0
fi

for f in $STAGED; do
    FULL="$REPO/$f"
    [ -f "$FULL" ] || continue

    # Check ALL := in staged file (strict ban, no grandfathering)
    WALRUS=$(grep -nE ':=' "$FULL" 2>/dev/null | head -3)
    if [ -n "$WALRUS" ]; then
        ISSUES="$ISSUES\nMUST FIX: $f — uses := (walrus operator). Use explicit types per H1.\n$(echo "$WALRUS" | head -3)"
    fi

    # Check const Packed*Array (engine bug #88753)
    CONST_PACKED=$(grep -nE 'const.*Packed(Int32|Int64|Float32|Float64|Byte|String|Vector2|Vector3|Color)Array' "$FULL" 2>/dev/null | head -3)
    if [ -n "$CONST_PACKED" ]; then
        ISSUES="$ISSUES\nMUST FIX: $f — const PackedArray (engine bug #88753). Use static var.\n$(echo "$CONST_PACKED" | head -3)"
    fi
done

if [ -n "$ISSUES" ]; then
    echo -e "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"Pre-commit check found issues in staged .gd files:\\n$ISSUES\\n\\n$CAVEMAN_MSG\"}}"
    exit 0
fi

echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"$CAVEMAN_MSG\"}}"
exit 0
