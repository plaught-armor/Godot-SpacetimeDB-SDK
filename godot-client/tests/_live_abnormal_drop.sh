#!/usr/bin/env bash
# Runs _live_reconnect_check.gd against a server this script kills mid-session, so
# the client sees an abnormal closure (code -1) rather than a clean one. That is
# the branch a yanked network takes, and the only way to reach it is to really
# take the server away.
#
#   GODOT=/path/to/godot tests/_live_abnormal_drop.sh
#
# The server is restarted from its own /proc entry — same executable, same argv,
# same working directory — and no --delete-data is involved, so the published
# module and its rows survive. The restart also runs from an EXIT trap, so an
# interrupt between the kill and the restart still brings the server back.
set -euo pipefail

GODOT="${GODOT:-godot}"
DOWNTIME="${DOWNTIME:-5}"
SCENE="res://tests/_live_reconnect_check.tscn"
CUE="KILL_THE_SERVER_NOW"
RESTART_LOG="${RESTART_LOG:-/tmp/stdb-restart.log}"

cd "$(dirname "$0")/.."

pid="$(pgrep -f spacetimedb-standalone | head -1)"
if [[ -z "$pid" ]]; then
    echo "no spacetimedb-standalone process found — start the server first" >&2
    exit 1
fi
# Capture everything needed to put the server back BEFORE killing it. Resolve the
# executable and working directory rather than trusting argv[0], which may be
# relative to a directory this script has already cd'd away from.
exe="$(readlink -f "/proc/$pid/exe")"
cwd="$(readlink -f "/proc/$pid/cwd")"
mapfile -d '' argv < "/proc/$pid/cmdline"
echo "[driver] server pid $pid: ${argv[*]}"
echo "[driver] cwd $cwd"

killed=""
restarted=""
log="$(mktemp)"

restart_server() {
    echo "[driver] restarting the server (log: $RESTART_LOG)"
    (cd "$cwd" && setsid "$exe" "${argv[@]:1}" > "$RESTART_LOG" 2>&1 &)
    restarted="yes"
    # Confirm it actually came back: a failed bind or a moved data dir would
    # otherwise leave the machine serverless with the reason buried in a log.
    for _ in $(seq 1 30); do
        if pgrep -f spacetimedb-standalone > /dev/null; then
            echo "[driver] server is back"
            return 0
        fi
        sleep 1
    done
    echo "[driver] SERVER DID NOT COME BACK — see $RESTART_LOG" >&2
    return 1
}

# Covers the interrupt case: Ctrl-C after the kill and before the restart would
# otherwise leave the user without a server.
cleanup() {
    if [[ -n "$killed" && -z "$restarted" ]]; then
        echo "[driver] interrupted after the kill — restoring the server" >&2
        restart_server || true
    fi
    rm -f "$log"
}
# INT/TERM get their own trap that exits: a handler that only cleans up leaves the
# shell resuming its `wait`, so the script would ignore Ctrl-C and `timeout`.
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

STDB_KILL_SERVER=1 "$GODOT" --headless --path . "$SCENE" > "$log" 2>&1 &
godot_pid=$!

# Wait for the harness to say it is subscribed and ready to lose the server.
for _ in $(seq 1 60); do
    if grep -q "$CUE" "$log"; then break; fi
    if ! kill -0 "$godot_pid" 2>/dev/null; then
        echo "[driver] harness exited before the cue:" >&2
        cat "$log" >&2
        exit 1
    fi
    sleep 1
done

if ! grep -q "$CUE" "$log"; then
    echo "[driver] harness never reached the cue" >&2
    cat "$log" >&2
    kill "$godot_pid" 2>/dev/null || true
    exit 1
fi

# SIGKILL, not SIGTERM: a clean shutdown would close the WebSocket properly and
# the client would see a normal closure — the branch the default run covers.
echo "[driver] killing the server"
kill -9 "$pid"
killed="yes"
sleep "$DOWNTIME"
restart_server

status=0
wait "$godot_pid" || status=$?
cat "$log"
exit "$status"
