# Differential test: the mirror, its refcounts and its callbacks against a brute-force
# model of what the server holds.
#
# Reading found the refcount bugs one shape at a time; this drives the shapes instead.
# A seeded random walk mutates a server-side table, computes what a real SpacetimeDB
# would send for it — one fragment per query, per query set, with a row that stays in a
# query's result reported as delete(old) + insert(new) (crates/core/src/subscription's
# eval_delta applies the predicate to the tx's insert and delete deltas separately) — and
# after every transaction asserts:
#
#   1. the cached rows equal the rows the server's queries match, values included;
#   2. every pk's refcount equals the number of (query set, query) pairs matching it,
#      which is what makes a later unsubscribe or prune release it exactly;
#   3. the per-query membership index carries those same counts AND points at the current
#      row — the index a prune rebuilds its deletes from, which nothing else observes
#      until a prune actually fires;
#   4. the row callbacks describe those transitions: a shadow table built only from
#      on_insert / on_update / on_delete equals the mirror at every step, and on the
#      PK-less side every on_before_delete is followed by its own on_delete.
#
# The same traffic drives a PK table and a PK-less one, which are separate code paths in
# LocalDatabase reached by identical wire data. Set 1's three queries overlap on purpose —
# that is what makes the server report one row several times in one update — and set 2's
# two cross them. Two interludes punctuate the walk: a prune (the SubscriptionError path,
# which reconstructs its deletes from per-query membership) and an unsubscribe (the server
# echoes the dropped rows, once per query that delivered them), each followed by a fresh
# subscribe snapshot.
#
# This is a regression net, not a one-shot probe: it fails 7112 checks against the code
# before fix/duplicate-update-inflates-refcount, and it runs in under a second.
#
# What it does NOT reach, so that a later reader does not read a pass as more than it is:
# event tables, unknown tables, null PKs, a row script that fails to resolve (both caches
# are seeded), clear_local_db, a listener freed mid-dispatch, and the desync branches that
# need a delete for a pk the mirror never held. Every column here is an int, so
# _values_equal / _value_hash never descend into an Option, a sum type or a nested record
# — that surface is tests/test_option_column_equality.gd's.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_local_db_oracle.gd
#
# Exit code = number of failed checks (0 = all pass).
extends SceneTree

## Transactions per run. The walk is seeded, so a failure reproduces exactly.
const _STEPS: int = 600
## Id space. Small enough that inserts, updates and deletes all keep hitting rows that
## several queries already hold — the overlap is the point.
const _MAX_ID: int = 14
## Transactions between the prune-and-resubscribe interludes.
const _PRUNE_EVERY: int = 97
## One walk per seed. Different seeds reach different interleavings of the same shapes.
var _seeds: PackedInt64Array = [0x5DA7A, 0xC0FFEE, 0x1D0A, 0x9E77]

var _total: int = 0
var _failed: int = 0
var _db: LocalDatabase
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# id -> [val, grp]: what the server holds.
var _server: Dictionary[int, Array] = { }
# Query sets, as (set id -> array of query indices). Set 1's three queries overlap, so a
# row matching all three is reported three times in one update — which is what widens the
# per-query membership entry past a counted pair. They have to be DISTINCT predicates:
# add_subscription_v2 dedupes a query set by query hash ("Deduping queries within this
# single call"), so the same SQL twice in one subscribe is one fragment, not two.
var _sets: Dictionary[int, PackedInt32Array] = { 1: [0, 1, 4], 2: [2, 3] }
# Set ids currently subscribed. A pruned set stops contributing until it resubscribes.
var _live_sets: PackedInt32Array = [1, 2]
# pk -> [val, grp], rebuilt only from the row callbacks.
var _shadow: Dictionary[int, Array] = { }
var _shadow_error: String = ""
# The PK-less table's rows, rebuilt only from its callbacks, plus the rows whose
# on_before_delete has fired and whose on_delete has not. Keyed by the WHOLE row value,
# not by id: a keyless table has no key, and the path applies a batch's inserts before its
# deletes, so an updated row's old and new values are both legitimately present mid-batch.
var _pkless_shadow: Dictionary[String, bool] = { }
var _pkless_pending_delete: Dictionary[String, bool] = { }
var _prunes: int = 0
var _unsubs: int = 0


class _Row:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var val: int = 0
	@export var grp: int = 0


	static func make(p_id: int, p_val: int, p_grp: int) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		r.val = p_val
		r.grp = p_grp
		return r


func _initialize() -> void:
	for seed_value: int in _seeds:
		_rng.seed = seed_value
		_fresh()
		for step: int in _STEPS:
			_mutate_server()
			for set_id: int in _live_sets:
				_deliver(set_id)
			_verify("seed %x step %d" % [seed_value, step])
			if step % _PRUNE_EVERY == _PRUNE_EVERY - 1:
				_prune_and_resubscribe(step)
			elif step % _PRUNE_EVERY == _PRUNE_EVERY / 2:
				_unsubscribe_and_resubscribe(step)
	_db.free()
	print("interludes: %d prunes, %d unsubscribes" % [_prunes, _unsubs])
	if _failed == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_failed, _total])
	quit(_failed)

# --- the model ---


## True when query [param query] matches a row holding [param fields] = [val, grp].
func _matches(query: int, fields: Array) -> bool:
	if query == 0:
		return fields[1] == 0 # grp == 0
	if query == 1:
		return fields[0] < 50 # val < 50
	if query == 2:
		return fields[0] % 2 == 0 # even val
	if query == 3:
		return fields[1] == 1 # grp == 1
	return fields[0] >= 90 # val >= 90, overlapping queries 0 and 2 but not 1


## One transaction against the server's table: insert, update or delete.
func _mutate_server() -> void:
	var id: int = _rng.randi_range(1, _MAX_ID)
	var roll: int = _rng.randi_range(0, 9)
	if not _server.has(id):
		# Nothing there to update or delete; an insert is the only move that changes
		# anything, and skipping the step would waste it.
		_server[id] = [_rng.randi_range(0, 99), _rng.randi_range(0, 2)]
		return
	if roll < 3:
		_server.erase(id)
		return
	# Update. Half the time only `val` moves (which crosses queries 1 and 2), so both
	# single-query and multi-query membership changes get exercised.
	var fields: Array = _server[id]
	if roll < 7:
		_server[id] = [_rng.randi_range(0, 99), fields[1]]
	else:
		_server[id] = [fields[0], _rng.randi_range(0, 2)]


## What [param set_id]'s queries deliver for the transaction just applied, and applies it.
## Mirrors the server: one fragment per query, a row that stays in a query's result but
## changed is a delete of the old row plus an insert of the new one, and the fragments
## for one table are concatenated into a single update.
func _deliver(set_id: int) -> void:
	var inserts: Array[Resource] = []
	var deletes: Array[Resource] = []
	for query: int in _sets[set_id]:
		var seen: Dictionary[int, bool] = { }
		for id: int in _mirror_of_query(set_id, query):
			seen[id] = true
		for id: int in _server:
			seen[id] = true
		for id: int in seen:
			var was: Array = _query_rows[set_id][query].get(id, [])
			var now: Array = _server[id] if _server.has(id) else []
			var matched_before: bool = not was.is_empty()
			var matched_after: bool = not now.is_empty() and _matches(query, now)
			if matched_before and matched_after:
				if was[0] != now[0] or was[1] != now[1]:
					deletes.append(_Row.make(id, was[0], was[1]))
					inserts.append(_Row.make(id, now[0], now[1]))
			elif matched_before:
				deletes.append(_Row.make(id, was[0], was[1]))
			elif matched_after:
				inserts.append(_Row.make(id, now[0], now[1]))
		_refresh_query_rows(set_id, query)
	if inserts.is_empty() and deletes.is_empty():
		return
	_apply_both(set_id, inserts, deletes)


## The same traffic against both tables. The PK-less table declares the same columns and
## no primary key, so its rows are told apart by value — a different code path in
## LocalDatabase with its own per-query membership, reached by identical wire data.
func _apply_both(set_id: int, inserts: Array[Resource], deletes: Array[Resource]) -> void:
	for table: StringName in [&"pk", &"pkless"]:
		var update: TableUpdateData = TableUpdateData.new()
		update.table_name = table
		# Fresh instances per table: LocalDatabase caches the instance it was handed, and
		# one shared between the two mirrors would let a later assert read the wrong one.
		var ins: Array[Resource] = []
		for row: _Row in inserts:
			ins.append(_Row.make(row.id, row.val, row.grp))
		var del: Array[Resource] = []
		for row: _Row in deletes:
			del.append(_Row.make(row.id, row.val, row.grp))
		update.inserts = ins
		update.deletes = del
		_db.apply_table_update(update, set_id)


# (set id, query) -> {id: [val, grp]} last delivered. The server tracks this to compute
# the incremental delta; so must the model, since a pruned set's queries start empty.
var _query_rows: Dictionary[int, Dictionary] = { }


func _mirror_of_query(set_id: int, query: int) -> Dictionary:
	return _query_rows[set_id][query]


func _refresh_query_rows(set_id: int, query: int) -> void:
	var rows: Dictionary[int, Array] = { }
	for id: int in _server:
		if _matches(query, _server[id]):
			rows[id] = _server[id].duplicate()
	_query_rows[set_id][query] = rows


func _reset_query_rows(set_id: int, matched: bool) -> void:
	var per_query: Dictionary[int, Dictionary] = { }
	for query: int in _sets[set_id]:
		var rows: Dictionary[int, Array] = { }
		if matched:
			for id: int in _server:
				if _matches(query, _server[id]):
					rows[id] = _server[id].duplicate()
		per_query[query] = rows
	_query_rows[set_id] = per_query

# --- the checks ---


## Rebuilds the expected mirror and refcounts from the model and compares.
func _verify(label: String) -> void:
	var want_rows: Dictionary[int, Array] = { }
	var want_refs: Dictionary[int, int] = { }
	for set_id: int in _live_sets:
		for query: int in _sets[set_id]:
			for id: int in _query_rows[set_id][query]:
				want_rows[id] = _query_rows[set_id][query][id]
				want_refs[id] = want_refs.get(id, 0) + 1

	var got_rows: Dictionary[int, Array] = { }
	for row: _ModuleTableType in _db.get_all_rows(&"pk"):
		got_rows[row.id] = [row.val, row.grp]
	_check(label + ": cached rows", _describe(got_rows), _describe(want_rows))

	# The PK-less mirror holds the same rows: a server table is a set (crates/table's
	# pointer map exists to "prevent duplicate rows"), so value-keyed storage loses
	# nothing, and every count here is subscription multiplicity, never a duplicate row.
	var got_pkless: Dictionary[int, Array] = { }
	for row: _ModuleTableType in _db.get_all_rows(&"pkless"):
		got_pkless[row.id] = [row.val, row.grp]
	_check(label + ": pk-less cached rows", _describe(got_pkless), _describe(want_rows))
	_check(label + ": pk-less multiplicity", _describe_pkless_counts(), _describe_counts(want_refs))

	var got_refs: Dictionary = _db._ref_counts.get(&"pk", { })
	var refs_line: PackedStringArray = []
	for id: int in got_refs:
		refs_line.append("%d=%d" % [id, got_refs[id]])
	refs_line.sort()
	_check(label + ": refcounts", " ".join(refs_line), _describe_counts(want_refs))

	if not _shadow_error.is_empty():
		_check(label + ": callback sequence", _shadow_error, "")
		_shadow_error = ""
	_check(label + ": callbacks describe the mirror", _describe(_shadow), _describe(got_rows))
	var shadow_keys: PackedStringArray = []
	for key: String in _pkless_shadow:
		shadow_keys.append(key)
	shadow_keys.sort()
	_check(
		label + ": pk-less callbacks describe its mirror",
		" ".join(shadow_keys),
		_describe(got_pkless),
	)
	_check(
		label + ": every pk-less before_delete was followed by its delete",
		str(_pkless_pending_delete.size()),
		"0",
	)
	# The per-query membership index is what a prune rebuilds its deletes from, and the
	# only job of the refresh on an update is to leave it pointing at the current row. A
	# prune fires every _PRUNE_EVERY steps, so without this the index could drift for a
	# hundred transactions before anything read it.
	_check(
		label + ": per-query membership rows",
		_describe_membership(),
		_describe_want_membership(),
	)


## Drops one set the way a SubscriptionError does, checks the other set's rows survive,
## then resubscribes it as a fresh snapshot and checks the mirror comes back.
func _prune_and_resubscribe(step: int) -> void:
	var set_id: int = 1 if step % (_PRUNE_EVERY * 2) < _PRUNE_EVERY else 2
	_prunes += 1
	_db.prune_query(set_id)
	_reset_query_rows(set_id, false)
	var live: PackedInt32Array = []
	for s: int in _live_sets:
		if s != set_id:
			live.append(s)
	_live_sets = live
	_verify("step %d after pruning set %d" % [step, set_id])

	_resubscribe(set_id)
	_verify("step %d after resubscribing set %d" % [step, set_id])


## The other way a set ends: the client unsubscribes and the server echoes the dropped
## rows, once per query that delivered them. Those deletes have to balance the refcount
## exactly — no prune reconstructs it here.
func _unsubscribe_and_resubscribe(step: int) -> void:
	var set_id: int = 2 if step % (_PRUNE_EVERY * 2) < _PRUNE_EVERY else 1
	_unsubs += 1
	var deletes: Array[Resource] = []
	for query: int in _sets[set_id]:
		for id: int in _query_rows[set_id][query]:
			var fields: Array = _query_rows[set_id][query][id]
			deletes.append(_Row.make(id, fields[0], fields[1]))
	_reset_query_rows(set_id, false)
	var live: PackedInt32Array = []
	for s: int in _live_sets:
		if s != set_id:
			live.append(s)
	_live_sets = live
	if not deletes.is_empty():
		_apply_both(set_id, [] as Array[Resource], deletes)
	_db.forget_query(set_id)
	_verify("step %d after unsubscribing set %d" % [step, set_id])
	_resubscribe(set_id)
	_verify("step %d after resubscribing set %d" % [step, set_id])


## A fresh subscribe snapshot for [param set_id]: every matching row, once per query that
## matches it.
func _resubscribe(set_id: int) -> void:
	var inserts: Array[Resource] = []
	for query: int in _sets[set_id]:
		for id: int in _server:
			if _matches(query, _server[id]):
				inserts.append(_Row.make(id, _server[id][0], _server[id][1]))
	_reset_query_rows(set_id, true)
	_live_sets.append(set_id)
	if not inserts.is_empty():
		_apply_both(set_id, inserts, [] as Array[Resource])

# --- harness ---


func _fresh() -> void:
	if is_instance_valid(_db):
		_db.free()
	_server.clear()
	_shadow.clear()
	_pkless_shadow.clear()
	_pkless_pending_delete.clear()
	_shadow_error = ""
	_live_sets = [1, 2]
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk", &"pkless"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"pk"] = &"id"
	_db._primary_key_cache[&"pkless"] = &""
	# No row script is registered, so seed the column list _rows_equal reads; without it
	# every re-delivery would look like a change and the update callbacks would lie.
	var props: Array[StringName] = [&"id", &"val", &"grp"]
	_db._row_property_cache[&"pk"] = props
	_db._row_property_cache[&"pkless"] = props
	_db.subscribe_to_inserts(&"pk", _on_insert)
	_db.subscribe_to_updates(&"pk", _on_update)
	_db.subscribe_to_deletes(&"pk", _on_delete)
	# The PK-less path splits before_delete from delete around its own array compaction and
	# reports a changed row as a delete plus an insert (it has no update callback at all),
	# so it gets its own shadow rather than sharing the PK one.
	_db.subscribe_to_inserts(&"pkless", _on_pkless_insert)
	_db.subscribe_to_before_deletes(&"pkless", _on_pkless_before_delete)
	_db.subscribe_to_deletes(&"pkless", _on_pkless_delete)
	for set_id: int in _sets:
		_reset_query_rows(set_id, false)


func _on_insert(row: _ModuleTableType) -> void:
	if _shadow.has(row.id):
		_note("on_insert for pk %d, which the shadow already holds" % row.id)
	_shadow[row.id] = [row.val, row.grp]


func _on_update(prev: _ModuleTableType, row: _ModuleTableType) -> void:
	if not _shadow.has(row.id):
		_note("on_update for pk %d, which the shadow does not hold" % row.id)
	elif _shadow[row.id] != [prev.val, prev.grp]:
		_note(
			(
				"on_update for pk %d handed prev [%d, %d], shadow holds [%d, %d]"
				% [row.id, prev.val, prev.grp, _shadow[row.id][0], _shadow[row.id][1]]
			)
		)
	_shadow[row.id] = [row.val, row.grp]


func _on_delete(row: _ModuleTableType) -> void:
	if not _shadow.has(row.id):
		_note("on_delete for pk %d, which the shadow does not hold" % row.id)
	_shadow.erase(row.id)


func _on_pkless_insert(row: _ModuleTableType) -> void:
	var key: String = _row_key(row)
	if _pkless_shadow.has(key):
		_note("pk-less on_insert for %s, which its shadow already holds" % key)
	_pkless_shadow[key] = true


## Fires while the row is still listed, and must be followed by its own on_delete.
func _on_pkless_before_delete(row: _ModuleTableType) -> void:
	var key: String = _row_key(row)
	if not _pkless_shadow.has(key):
		_note("pk-less on_before_delete for %s, which its shadow does not hold" % key)
	_pkless_pending_delete[key] = true


func _on_pkless_delete(row: _ModuleTableType) -> void:
	var key: String = _row_key(row)
	if not _pkless_pending_delete.erase(key):
		_note("pk-less on_delete for %s with no preceding on_before_delete" % key)
	_pkless_shadow.erase(key)


## The whole row value, in the same spelling _describe uses for one entry.
func _row_key(row: _ModuleTableType) -> String:
	return "%d:[%d,%d]" % [row.id, row.val, row.grp]


func _note(message: String) -> void:
	# Every violation, not the first: two misfires in one transaction are two different
	# bugs, and reporting one would let the second ride along to the next release.
	if _shadow_error.is_empty():
		_shadow_error = message
	else:
		_shadow_error += " | " + message


## Every (query set, pk) the SDK records as this set's membership, with the row value it
## points at — the shape prune_query reads.
func _describe_membership() -> String:
	var parts: PackedStringArray = []
	for set_id: int in _db._query_rows:
		var tables: Dictionary = _db._query_rows[set_id]
		if not tables.has(&"pk"):
			continue
		var membership: Dictionary = tables[&"pk"]
		for pk: int in membership:
			var entry: Variant = membership[pk]
			var row: _ModuleTableType = entry[0] if entry is Array else entry
			var count: int = entry[1] if entry is Array else 1
			parts.append("%d/%d:[%d,%d]x%d" % [set_id, pk, row.val, row.grp, count])
	parts.sort()
	return " ".join(parts)


## The same, from the model.
func _describe_want_membership() -> String:
	var parts: PackedStringArray = []
	for set_id: int in _live_sets:
		var counts: Dictionary[int, int] = { }
		for query: int in _sets[set_id]:
			for id: int in _query_rows[set_id][query]:
				counts[id] = counts.get(id, 0) + 1
		for id: int in counts:
			var fields: Array = _server[id]
			parts.append("%d/%d:[%d,%d]x%d" % [set_id, id, fields[0], fields[1], counts[id]])
	parts.sort()
	return " ".join(parts)


## The PK-less table's per-value multiplicity, keyed back to the row's id so it lines up
## with the PK table's refcounts.
func _describe_pkless_counts() -> String:
	var parts: PackedStringArray = []
	var buckets: Dictionary = _db._pk_less_counts.get(&"pkless", { })
	for hash_key: int in buckets:
		for entry: Array in buckets[hash_key]:
			parts.append("%d=%d" % [entry[0].id, entry[1]])
	parts.sort()
	return " ".join(parts)


## Stable one-line rendering of {id: count}.
func _describe_counts(counts: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id: int in counts:
		parts.append("%d=%d" % [id, counts[id]])
	parts.sort()
	return " ".join(parts)


## Stable one-line rendering of {id: [val, grp]} so a mismatch prints readably.
func _describe(rows: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id: int in rows:
		parts.append("%d:[%d,%d]" % [id, rows[id][0], rows[id][1]])
	parts.sort()
	return " ".join(parts)


func _check(label: String, got: String, want: String) -> void:
	_total += 1
	if got == want:
		return
	_failed += 1
	printerr("FAIL  %s\n        got  %s\n        want %s" % [label, got, want])
