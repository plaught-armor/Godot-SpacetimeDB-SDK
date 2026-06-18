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
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="tests"

if [ ! -x "$GODOT_BIN" ]; then
	echo "error: GODOT_BIN not executable: $GODOT_BIN" >&2
	echo "set GODOT_BIN=/path/to/godot and retry" >&2
	exit 2
fi

cd "$HERE" || exit 2

# Build the import cache on first run so tests that load() resources resolve.
if [ ! -d ".godot" ]; then
	echo "no .godot cache — importing once..."
	"$GODOT_BIN" --headless --path . --import >/dev/null 2>&1 || true
fi

# Select tests: a name arg runs one, else every test_*.gd.
tests=()
if [ "$#" -gt 0 ]; then
	name="${1%.gd}"
	tests+=("$TESTS_DIR/$name.gd")
else
	for t in "$TESTS_DIR"/test_*.gd; do
		tests+=("$t")
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
	"$GODOT_BIN" --headless --path . --script "$t" >"$log" 2>&1
	code=$?
	summary="$(grep -E "ALL PASS|FAIL" "$log" | tail -1)"
	if [ "$code" -eq 0 ]; then
		printf 'PASS  %-34s %s\n' "$base" "$summary"
	else
		failed=$((failed + 1))
		failed_names+=("$base")
		printf 'FAIL  %-34s exit=%d  %s\n' "$base" "$code" "$summary"
		tail -8 "$log" | sed 's/^/      | /'
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
