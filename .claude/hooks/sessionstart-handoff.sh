#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')
src=$(printf '%s' "$input" | jq -r '.source // ""')
case "$src" in compact|resume) ;; *) exit 0 ;; esac
handoff="$cwd/docs/handoff-context.md"
[ ! -f "$handoff" ] && exit 0
content=$(cat "$handoff")
jq -n --arg c "$content" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("# Handoff from prior session\n\n" + $c)
  }
}'
