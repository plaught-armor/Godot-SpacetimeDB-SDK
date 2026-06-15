#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')
[ -z "$transcript" ] && exit 0
[ ! -f "$transcript" ] && exit 0
out="$cwd/docs/handoff-context.md"
mkdir -p "$(dirname "$out")"
prompt='Read this Claude Code session transcript JSONL. Produce concise handoff for resumption. Sections: ## Task, ## Done, ## Current state, ## Files touched, ## Open questions, ## Next step. Caveman ultra style — drop articles/filler/hedging. Fragments OK. Code/paths exact. Under 500 words.'
tail -n 2000 "$transcript" \
  | timeout 60 claude -p --bare --append-system-prompt "$prompt" 2>/dev/null \
  > "$out.tmp" || { rm -f "$out.tmp"; exit 0; }
[ ! -s "$out.tmp" ] || [ "$(wc -c < "$out.tmp")" -lt 50 ] && { rm -f "$out.tmp"; exit 0; }
mv "$out.tmp" "$out"
jq -n --arg msg "Handoff synthesized: $out" '{systemMessage: $msg}'
