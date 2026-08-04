#!/usr/bin/env bash
# Run the SpacetimeDB SDK test suite headless and report pass/fail.
#
# Each test_*.gd extends SceneTree, self-asserts, and quit(fails) — exit code
# is the failure count (0 = pass). One Godot process per test isolates crashes.
#
# Usage:
#   ./run_tests.sh                 # run every test_*.gd
#   ./run_tests.sh test_row_parse  # run one (name with or without .gd)
#   GODOT_BIN=/path/to/godot ./run_tests.sh
#   VERBOSE=1 ./run_tests.sh       # stream each test's full output
#
# Excludes _*.gd helpers and bench_*.gd by globbing test_*.gd only.

set -u

GODOT_BIN="${GODOT_BIN:-/mnt/based_backup/Repos/godot/bin/godot.linuxbsd.editor.x86_64}"
# Per-test wall-clock ceiling. The slowest test in the suite runs in a few
# seconds; anything near this is stuck, not slow.
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="tests"

if [ ! -x "$GODOT_BIN" ]; then
	echo "error: GODOT_BIN not executable: $GODOT_BIN" >&2
	echo "set GODOT_BIN=/path/to/godot and retry" >&2
	exit 2
fi

cd "$HERE" || exit 2

# Build/refresh the import cache so tests resolve class_name globals and load()
# resources. Reimport when .godot is absent OR any .gd is newer than the global
# class cache — adding a new class_name to an existing checkout otherwise leaves
# the cache stale, and every script depending on the new type fails to compile.
class_cache=".godot/global_script_class_cache.cfg"
if [ ! -f "$class_cache" ] || \
	[ -n "$(find . -name '*.gd' -newer "$class_cache" -not -path './.godot/*' -print -quit)" ]; then
	echo "import cache missing or stale — importing..."
	"$GODOT_BIN" --headless --path . --import >/dev/null 2>&1 || true
fi

# Select tests: a name arg runs one, else every test_*.gd and test_*.tscn.
# A .tscn test boots a normal main loop instead of --script, which is the only
# way a test can touch code naming an autoload singleton (row_receiver.gd does):
# under --script those identifiers do not resolve and the script fails to
# compile. Its root node self-asserts in _ready and calls get_tree().quit(fails).
tests=()
if [ "$#" -gt 0 ]; then
	name="${1%.gd}"
	name="${name%.tscn}"
	if [ -f "$TESTS_DIR/$name.tscn" ]; then
		tests+=("$TESTS_DIR/$name.tscn")
	else
		tests+=("$TESTS_DIR/$name.gd")
	fi
else
	for t in "$TESTS_DIR"/test_*.gd "$TESTS_DIR"/test_*.tscn; do
		[ -f "$t" ] && tests+=("$t")
	done
fi

total=0
failed=0
failed_names=()
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for t in "${tests[@]}"; do
	base="$(basename "$t")"
	if [ ! -f "$t" ]; then
		echo "MISS  $base (no such file)"
		failed=$((failed + 1))
		failed_names+=("$base")
		continue
	fi
	total=$((total + 1))
	# A scene test quits itself; one whose script failed to load never does, and
	# Godot would sit in an empty main loop forever. Bound every run so a broken
	# test fails the suite instead of hanging it.
	case "$t" in
		*.tscn) timeout "$TEST_TIMEOUT" "$GODOT_BIN" --headless --path . "$t" >"$log" 2>&1 ;;
		*) timeout "$TEST_TIMEOUT" "$GODOT_BIN" --headless --path . --script "$t" >"$log" 2>&1 ;;
	esac
	code=$?
	if [ "$code" -eq 124 ]; then
		echo "timed out after ${TEST_TIMEOUT}s" >>"$log"
	fi
	# A GDScript runtime fault (calling a method that does not exist, indexing past
	# the end, dereferencing null) aborts the function it happened in but not the
	# process: the test's own quit(fails) still runs, with whatever count it had
	# reached before the fault. Exit code 0, "ALL PASS" printed, and every assertion
	# the fault skipped counted as passing. Godot writes "SCRIPT ERROR" for exactly
	# that case — a push_error from test code prints "ERROR"/"USER ERROR" instead, and
	# several tests raise those deliberately — so it is the marker to fail on. A parse
	# error already exits non-zero on its own.
	faulted=0
	if [ "$code" -eq 0 ] && grep -q 'SCRIPT ERROR' "$log"; then
		faulted=1
	fi
	summary="$(grep -E "ALL PASS|FAIL" "$log" | tail -1)"
	if [ "$code" -eq 0 ] && [ "$faulted" -eq 0 ]; then
		printf 'PASS  %-34s %s\n' "$base" "$summary"
	else
		failed=$((failed + 1))
		failed_names+=("$base")
		if [ "$faulted" -eq 1 ]; then
			printf 'FAIL  %-34s runtime error  %s\n' "$base" "$summary"
			grep -m3 'SCRIPT ERROR' "$log" | sed 's/^/      | /'
		else
			printf 'FAIL  %-34s exit=%d  %s\n' "$base" "$code" "$summary"
			tail -8 "$log" | sed 's/^/      | /'
		fi
	fi
	if [ "${VERBOSE:-0}" != "0" ]; then
		sed 's/^/      | /' "$log"
	fi
done

echo "----------------------------------------------------------------"
if [ "$failed" -eq 0 ]; then
	echo "ALL GREEN — $total/$total test files passed"
	exit 0
fi
echo "$failed/$total test files FAILED:"
for n in "${failed_names[@]}"; do
	echo "  - $n"
done
exit 1
