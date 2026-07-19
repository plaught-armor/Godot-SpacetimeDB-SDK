#!/usr/bin/env bash
# Runs the broadcast check: an observer client that only subscribes, and a second
# client with its own identity that changes a row. What the observer receives is a
# standalone TransactionUpdate — the one transaction shape no fixture had, because
# a caller's own row changes arrive nested inside its reducer response instead.
#
#   GODOT=/path/to/godot tests/_live_broadcast.sh
#
# Exit code is the observer's fail count. Needs a running server with the module
# published; nothing is killed or restarted.
set -euo pipefail

GODOT="${GODOT:-godot}"
OBSERVER="res://tests/_live_broadcast_check.tscn"
ACTOR="res://tests/_live_broadcast_actor.tscn"
CUE="START_THE_ACTOR_NOW"

cd "$(dirname "$0")/.."

observer_log="$(mktemp)"
actor_log="$(mktemp)"
observer_pid=""
actor_pid=""

cleanup() {
    [[ -n "$actor_pid" ]] && kill "$actor_pid" 2>/dev/null || true
    [[ -n "$observer_pid" ]] && kill "$observer_pid" 2>/dev/null || true
    rm -f "$observer_log" "$actor_log"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

"$GODOT" --headless --path . "$OBSERVER" > "$observer_log" 2>&1 &
observer_pid=$!

# The observer has to be subscribed before the actor changes anything, or the
# change arrives in the subscription snapshot instead of as a broadcast.
for _ in $(seq 1 60); do
    if grep -q "$CUE" "$observer_log"; then break; fi
    if ! kill -0 "$observer_pid" 2>/dev/null; then
        echo "[driver] observer exited before the cue:" >&2
        cat "$observer_log" >&2
        exit 1
    fi
    sleep 1
done

if ! grep -q "$CUE" "$observer_log"; then
    echo "[driver] observer never reached the cue" >&2
    cat "$observer_log" >&2
    exit 1
fi

echo "[driver] starting the second client"
"$GODOT" --headless --path . "$ACTOR" > "$actor_log" 2>&1 &
actor_pid=$!

status=0
wait "$observer_pid" || status=$?
observer_pid=""
wait "$actor_pid" || true
actor_pid=""

cat "$observer_log"
echo "--- second client ---"
cat "$actor_log"
exit "$status"
