#!/usr/bin/env bash
# Guards what a release ships. `release.yml` packages `godot-client/addons/` from a fresh
# checkout, so the zip is exactly this repo's tracked files under that path — nothing
# reviews that set, and nothing did when v2.0.0 through v2.2.0 shipped the entire test
# suite inside the addon (100 scripts: benches, fuzzers and golden fixtures, in three
# releases). v2.3.0 moved them out. This is the check that would have caught it.
#
# Run from the repo root. Exit code 0 = the package is what it should be.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fails=0

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	fails=$((fails + 1))
}

# What the zip will hold. `git ls-files` rather than a directory walk: an untracked file
# in a working tree (plugin_config.tres, a scratch probe) is not in a CI checkout and does
# not ship, so treating it as package contents would report a problem nobody can hit.
mapfile -t package < <(git ls-files godot-client/addons)

if [ "${#package[@]}" -eq 0 ]; then
	fail "no tracked files under godot-client/addons — is this the repo root?"
	exit 1
fi

# The same list as a set, for the membership tests below. Not a convenience: the
# `printf '%s\n' "${package[@]}" | grep -q` form this replaces is a race under
# `set -o pipefail` — `grep -q` exits at the match, `printf` takes SIGPIPE, and the
# pipeline reports 141, which reads as "not found" for a file that is right there.
# Observed once in thirteen runs, blaming a sidecar that was present and tracked.
declare -A in_package=()
for path in "${package[@]}"; do
	in_package["$path"]=1
done

# One addon, named for the plugin. A second directory here would be packaged with it.
mapfile -t addon_dirs < <(printf '%s\n' "${package[@]}" | cut -d/ -f3 | sort -u)
if [ "${#addon_dirs[@]}" -ne 1 ] || [ "${addon_dirs[0]}" != "SpacetimeDB" ]; then
	fail "expected only addons/SpacetimeDB, found: ${addon_dirs[*]}"
fi

# Development files. The names are the ones this repo actually uses for them — the test
# runner collects `test_*.gd`, benches and fuzzers carry their own prefixes, and codegen
# goldens live under a `golden/` directory.
for path in "${package[@]}"; do
	base="${path##*/}"
	case "$path" in
		*/tests/* | */golden/*)
			fail "development directory in the package: $path"
			continue
			;;
	esac
	case "$base" in
		test_* | bench_* | fuzz_* | _probe_* | _bench_* | _fuzz_*)
			fail "development file in the package: $path"
			;;
	esac
done

# Kinds a Godot addon is made of. An extension outside this set is not necessarily wrong,
# but it has never shipped before and should be a deliberate choice rather than a stray
# file — a `.zip`, a `.json` dump or an editor backup reaching a release is the shape this
# catches.
for path in "${package[@]}"; do
	base="${path##*/}"
	case "$base" in
		*.gd | *.uid | *.tscn | *.svg | *.import | *.cfg | LICENSE) ;;
		*) fail "unexpected file kind in the package: $path" ;;
	esac
done

# The two files that make it an installable, redistributable addon.
for required in \
	godot-client/addons/SpacetimeDB/plugin.cfg \
	godot-client/addons/SpacetimeDB/LICENSE; do
	if [ -z "${in_package[$required]+set}" ]; then
		fail "missing from the package: $required"
	fi
done

# Every `.gd` carries the `.uid` Godot writes beside it. A missing one makes the editor
# mint a fresh id on the installing machine, which is how two copies of the same script
# end up with different ids across a team.
for path in "${package[@]}"; do
	case "$path" in
		*.gd)
			if [ -z "${in_package[$path.uid]+set}" ]; then
				fail "script without its .uid sidecar: $path"
			fi
			;;
	esac
done

if [ "$fails" -ne 0 ]; then
	printf '\n%d problem(s) in the release package (%d files).\n' "$fails" "${#package[@]}" >&2
	exit 1
fi

printf 'Package OK — %d files under godot-client/addons.\n' "${#package[@]}"
