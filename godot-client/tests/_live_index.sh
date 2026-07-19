#!/usr/bin/env bash
# Runs the index-read check with a second player in the world.
#
# The check reads the generated btree and unique index accessors back against a
# linear scan. With a single client the btree holds one key, so every range
# accessor returns either everything or nothing and the sorted-key window is never
# exercised — the check refuses to pass in that state. This driver starts a
# bystander client under its own identity first, then runs the check.
#
#   GODOT=/path/to/godot tests/_live_index.sh
#
# Exit code is the check's fail count. Needs a running server with the module
# published; nothing is killed or restarted.
set -euo pipefail

GODOT="${GODOT:-godot}"
BYSTANDER="res://tests/_live_index_bystander.tscn"
CHECK="res://tests/_live_index_check.tscn"
CUE="IN_THE_GAME"

cd "$(dirname "$0")/.."

bystander_log="$(mktemp)"
bystander_pid=""

cleanup() {
    [[ -n "$bystander_pid" ]] && kill "$bystander_pid" 2>/dev/null || true
    rm -f "$bystander_log"
}
trap cleanup EXIT
# A cleanup-only trap would let bash resume its wait, so these have to exit.
trap 'cleanup; exit 130' INT TERM

"$GODOT" --headless --path . "$BYSTANDER" > "$bystander_log" 2>&1 &
bystander_pid=$!

# The bystander's circle has to exist before the check reads the index, or the
# check sees one key and fails on purpose.
for _ in $(seq 1 60); do
    if grep -q "$CUE" "$bystander_log"; then break; fi
    if ! kill -0 "$bystander_pid" 2>/dev/null; then
        echo "[driver] bystander exited before the cue:" >&2
        cat "$bystander_log" >&2
        exit 1
    fi
    sleep 1
done

if ! grep -q "$CUE" "$bystander_log"; then
    echo "[driver] bystander never entered the game" >&2
    cat "$bystander_log" >&2
    exit 1
fi

echo "[driver] starting the index check"
status=0
"$GODOT" --headless --path . "$CHECK" || status=$?

echo "--- bystander ---"
cat "$bystander_log"
exit "$status"
