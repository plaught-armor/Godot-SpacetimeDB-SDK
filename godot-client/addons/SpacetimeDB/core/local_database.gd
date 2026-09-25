## Client-side in-memory mirror of SpacetimeDB tables.
##
## Stores rows keyed by primary key (or in flat arrays for PK-less tables).
## Processes [TableUpdateData] batches from the server, resolves inserts vs
## updates via PK matching, and dispatches per-table listener callbacks and
## signals. Game code normally interacts via [_ModuleTable] wrappers rather
## than calling [LocalDatabase] directly.
##
## [b]The rows this mirror hands out are the instances it stores.[/b] Every accessor
## ([method get_all_rows], [method get_row_by_pk], [method find_by], [method find_where],
## the generated table wrappers) and every listener callback returns the cached row
## object itself, not a copy — rows are [Resource]s, so writing to one writes into the
## mirror. The mirror is the server's state; a local write makes it disagree with the
## server and nothing brings it back:
## [br][br]
## - A table with no primary key is refcounted by row VALUE (hash + field compare), so a
##   mutated row no longer matches the row the server later deletes. The delete is
##   dropped, no [signal row_deleted] fires, and the row stays cached for the session
##   while every re-delivery caches another copy.
## - A keyed table recovers on the next delivery of that row, but reports the correction
##   as a [signal row_updated] the server never made, with an `old_row` carrying the
##   local value.
## [br][br]
## Mutate a copy instead — [method Resource.duplicate] for a flat row,
## [method Resource.duplicate_deep] when the row carries nested records, [Option]s or
## arrays, since a shallow copy shares those with the cached row.
class_name LocalDatabase
extends Node

var _tables: Dictionary[StringName, Dictionary] = { }
var _primary_key_cache: Dictionary[StringName, StringName] = { }
var _schema: SpacetimeDBSchema
var _cached_normalized_table_names: Dictionary[StringName, StringName] = { }
var _insert_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _update_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _before_delete_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _delete_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _transactions_completed_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
## Shared read-only sentinel returned by [method _listener_snapshot] when a table
## has no listeners — avoids allocating an empty Array per snapshot on the common
## no-listener path. Read-only so a stray mutation fails loud (C2a).
static var _EMPTY_LISTENERS: Array = []
## Column-name list per generated record [Script], cached from its BSATN_TYPES const.
## [method Script.get_script_constant_map] allocates a fresh Dictionary and `.keys()` a
## fresh Array on every call, and [method _values_equal] needs that list once per nested
## column per row compared — uncached, it dominated nested-row change detection. Keyed by
## [Script] (process-lived, bounded by the generated record count); entries are read-only
## (C2a). Reached only from the main-thread [method _apply_batch] path — NOT
## synchronized, so moving row equality or hashing onto the deserializer worker needs a
## mutex here or a per-thread cache.
static var _record_columns_cache: Dictionary[Script, Array] = { }
## Shared read-only empty column list for objects that are not generated records.
static var _EMPTY_COLUMNS: Array = []
## Component count per column type that can hold a NaN — every entry of
## [constant BSATNDeserializer.NATIVE_ARRAYLIKE] built from floats (the i-suffixed
## vectors hold ints and are absent). Components read as floats through `v[i]`.
## Used by [method _nan_components_equal]; a type absent here carries no float to compare.
## Most messages one [method _apply_batch] applies from its queue before it gives up: a
## callback that applies a message every time it runs would otherwise never let the queue
## drain.
const _MAX_QUEUED_MESSAGES: int = 4096
const _NAN_CARRYING_COMPONENTS: Dictionary[int, int] = {
	TYPE_VECTOR2: 2,
	TYPE_VECTOR3: 3,
	TYPE_VECTOR4: 4,
	TYPE_QUATERNION: 4,
	TYPE_COLOR: 4,
}
var _pk_less_tables: Dictionary[StringName, Array] = { } ## Array[_ModuleTableType]
var _row_property_cache: Dictionary[StringName, Array] = { } ## Array[StringName] — storage props per table
## Tables already reported as having no registered row script, so the error in
## [method _get_row_properties] fires once each instead of once per update.
var _unresolved_row_scripts: Dictionary[StringName, bool] = { }
## Tables already reported as having taken a delete for a row the mirror does not hold,
## so [method _warn_unmatched_delete] fires once each rather than once per row. The
## server only deletes rows it delivered, so a miss means the cached row no longer looks
## like the row it was delivered as — a local write into a handed-out row (see the class
## note), or a value the mirror's own hash/compare pair disagrees about.
var _unmatched_delete_warned: Dictionary[StringName, bool] = { }
## Per-table refcount of cached PK rows: table -> { pk -> int }. A row shared by N
## overlapping query sets has count N; on_insert fires on 0->positive, on_delete on
## positive->0. Lets an unsubscribe drop only rows no longer held by another query.
var _ref_counts: Dictionary[StringName, Dictionary] = { }
## PK-less analogue of _ref_counts. Rows have no key, so they're refcounted by value:
## table -> { row_hash -> Array of [row, count] } (hash bucket + _rows_equal tiebreak).
## A distinct row value held by N overlapping subscriptions has count N; on_insert fires
## on 0->1, on_delete on 1->0. Mirrors the per-row entries in _pk_less_tables.
var _pk_less_counts: Dictionary[StringName, Dictionary] = { }
## Per-query row membership: query_id -> { table -> (PK: { pk -> row | [row, count] }) |
## (PK-less: { hash -> [[row, count]] }) }. Both shapes carry a COUNT, because one query
## set can deliver the same row more than once: the server evaluates each query in a
## subscribe independently (execute_plans in crates/core/src/subscription/mod.rs emits one
## TableUpdate per query, with no dedupe across the set). The count is exactly the number
## of references this query contributed to _ref_counts, so a prune can hand every one of
## them back. On the PK side a single reference is stored as the bare row and only a
## repeat widens the entry to a pair, which keeps the common subscribe path
## allocation-free.
##
## This membership is what lets a SubscriptionError on an already-applied query be pruned
## precisely, since the server sends no dropped rows on an error, unlike unsubscribe.
var _query_rows: Dictionary[int, Dictionary] = { }
## Bumped by every cache wipe — [method clear_local_db] and [method clear_all_tables]
## both. A wipe is reachable from INSIDE a row callback (a listener that calls
## [method SpacetimeDBClient.connect_db] wipes the mirror synchronously), so
## [method _apply_batch] reads this before it calls game code and checks it after each
## call. A wipe from a before-delete ends the message before anything of it is applied;
## one from a later callback ends the inserts and updates still to be reported (see
## [method _dispatch_plan]).
var _generation: int = 0
## Bumped by [method clear_local_db] ONLY, i.e. by the wipe that marks a session
## boundary. [method clear_all_tables] detaches the same containers (so it bumps
## [member _generation] and a batch under it is still abandoned) but says nothing about
## the connection: a caller rebuilding its own view mid-session must not make the client
## drop the rest of a live transaction.
var _session_generation: int = 0
## Cache-emptying [Callable]s registered by the generated index accessors through
## [method register_index_invalidator]. Fired by [method clear_all_tables], the one wipe
## that drops rows without reporting a delete for them.
var _index_invalidators: Array[Callable] = []
## The generated index caches' upkeep, per table: Array of [on_insert, on_update,
## on_delete] registered through [method register_index_hooks]. Called while a message is
## APPLIED, before any game callback runs, so an index read from a row callback already
## reflects the whole message — the same guarantee the rows themselves carry.
var _index_hooks_by_table: Dictionary[StringName, Array] = { }
## Plans of the message whose callbacks are being reported right now (one at most: a
## message applied from a callback is queued, see [method _apply_batch]). Their rows are
## already in the mirror, so a wipe from one of those callbacks reads this to leave out
## what the message has not announced yet — see [method _unannounced_rows].
var _undispatched: Array[_TablePlan] = []
## How many rows the insert or update loop now running in [method _dispatch_plan] has
## reported. Its plan holds -1 in the matching sent count until the loop ends: a counter
## here costs ~20 ns/row, one on the plan ~42.
var _in_flight_sent: int = 0
## Instance ids of rows whose before-delete a message in phase 1 has fully reported, still
## cached until phase 2 evicts them. A wipe from a later before-delete reports these rows
## deleted without announcing them a second time.
var _before_delete_sent: Dictionary[int, bool] = { }
## Messages applied while another is being applied — from inside one of its callbacks —
## as [code][updates, query_ids, session_generation][/code], run in order once it
## finishes. See [method _apply_batch].
var _queued_batches: Array[Array] = []
var _applying: bool = false

## Emitted after a row is inserted into a table.
signal row_inserted(table_name: StringName, row: _ModuleTableType)
## Emitted after a row is updated (PK match found in inserts + existing data).
signal row_updated(table_name: StringName, old_row: _ModuleTableType, new_row: _ModuleTableType)
## Emitted just before a row is removed from the cache (row still queryable).
signal row_before_delete(table_name: StringName, row: _ModuleTableType)
## Emitted after a row is deleted from a table.
signal row_deleted(table_name: StringName, row: _ModuleTableType)
## Emitted once per table after a message's inserts, updates and deletes for it have all
## been reported.
signal row_transactions_completed(table_name: StringName)


static func _static_init() -> void:
	if not _EMPTY_LISTENERS.is_read_only():
		_EMPTY_LISTENERS.make_read_only()
	if not _EMPTY_COLUMNS.is_read_only():
		_EMPTY_COLUMNS.make_read_only()


func _init(p_schema: SpacetimeDBSchema) -> void:
	_schema = p_schema
	for raw_name: StringName in p_schema.raw_table_names:
		_tables[raw_name.to_lower()] = { }
	p_schema.raw_table_names.clear() # consumed — free the memory


## Snapshot a table's listener list for safe iteration during dispatch. A listener
## may unsubscribe inside its own callback, so the list it mutates must not be the
## one being iterated — hence duplicate. Duplicate only when non-empty; the common
## no-listener case returns the shared read-only empty (zero alloc).
##
## The snapshot is what makes the [code]is_valid()[/code] guard at every
## [code]listener.call[/code] site below necessary: a callback that frees ANOTHER
## subscriber leaves that object's Callable in this already-taken copy, and calling it is
## a GDScript runtime error that unwinds the whole apply (measured: freeing a second
## receiver from an insert handler applied 1 of a 3-row batch, fired no
## transactions_completed, and the server never resends). Skipping a dead listener matches
## how the engine treats a signal whose receiver was freed. The guard covers a method
## Callable, which is what every subscriber in this SDK registers; a LAMBDA that captured
## a node stays valid after that node is freed, so a lambda subscriber must check its own
## captures. [method Object.queue_free] is unaffected (the free lands after the batch), and
## a callback that frees its OWN object is refused by the engine.
func _listener_snapshot(by_table: Dictionary, key: StringName) -> Array:
	var live: Array = by_table.get(key, _EMPTY_LISTENERS)
	return live.duplicate() if not live.is_empty() else _EMPTY_LISTENERS


# --- Normalization helper (#2) ---
# Single shared cache for both the apply path and access methods
func _normalize(table_name: StringName) -> StringName:
	if _cached_normalized_table_names.has(table_name):
		return _cached_normalized_table_names[table_name]
	var normalized: StringName = table_name.to_lower()
	_cached_normalized_table_names[table_name] = normalized
	return normalized


# Adds [param callable] to a table's listener array, dropping any listener whose object
# has since been freed. A subscriber that goes away without calling the matching
# unsubscribe leaves its Callable in the array for good: the dispatch loops skip an
# invalid one, so it is not a correctness problem, but a pool subscribing raw callbacks
# per instance would grow the array without bound. Pruning here rather than per update
# keeps the cost on the cold path.
func _add_listener(by_table: Dictionary, key: StringName, callable: Callable) -> void:
	if not by_table.has(key):
		by_table[key] = []
	var listeners: Array = by_table[key]
	for i: int in range(listeners.size() - 1, -1, -1):
		if not (listeners[i] as Callable).is_valid():
			listeners.remove_at(i)
	if not listeners.has(callable):
		listeners.append(callable)


## Registers the upkeep of one generated index cache on [param table_name]. The three
## [Callable]s are called with the rows a message inserted, updated
## ([code](old_row, new_row)[/code]) and deleted, while the message is applied and before
## any row callback runs. They must only maintain the cache — never mutate this database.
## Dead entries are pruned here, the same shape as [method _add_listener].
func register_index_hooks(
		table_name: StringName,
		on_insert: Callable,
		on_update: Callable,
		on_delete: Callable,
) -> void:
	var key: StringName = _normalize(table_name)
	if not _index_hooks_by_table.has(key):
		_index_hooks_by_table[key] = []
	var hooks: Array = _index_hooks_by_table[key]
	for i: int in range(hooks.size() - 1, -1, -1):
		if not (hooks[i][0] as Callable).is_valid():
			hooks.remove_at(i)
	for hook: Array in hooks:
		if hook[0] == on_insert:
			return
	hooks.append([on_insert, on_update, on_delete])


## Registers [param invalidator] to be called when a wipe empties this database. Both
## wipes drop rows outside the apply path the index hooks ride on, so both empty the
## index caches through this: [method clear_local_db] before it reports the rows it
## dropped, [method clear_all_tables] without reporting them. An index left holding the
## previous contents answers [code]find()[/code] / [code]filter()[/code] with rows the
## mirror no longer has.
##
## Dead [Callable]s are pruned here, the same shape as [method _add_listener], and again at
## the top of [method clear_all_tables] — one of the two is the cold path whichever way an
## index is released. A [Callable] bound to a method holds its target by
## [code]ObjectID[/code], so registering here does not keep an index alive.
##
## [param invalidator] is expected to empty a cache and nothing else — it must not mutate
## this database. Wiping again is the dangerous shape: the list is a registry no wipe
## empties, so a re-entrant [method clear_all_tables] would fire every entry again.
func register_index_invalidator(invalidator: Callable) -> void:
	for i: int in range(_index_invalidators.size() - 1, -1, -1):
		if not _index_invalidators[i].is_valid():
			_index_invalidators.remove_at(i)
	if not _index_invalidators.has(invalidator):
		_index_invalidators.append(invalidator)


## Registers [param callable] to be called with the inserted row for [param table_name].
func subscribe_to_inserts(table_name: StringName, callable: Callable) -> void:
	_add_listener(_insert_listeners_by_table, _normalize(table_name), callable)


## Removes an insert listener for [param table_name].
func unsubscribe_from_inserts(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _insert_listeners_by_table.has(key):
		_insert_listeners_by_table[key].erase(callable)
		if _insert_listeners_by_table[key].is_empty():
			_insert_listeners_by_table.erase(key)


## Registers [param callable] to be called with [code](old_row, new_row)[/code] for [param table_name].
func subscribe_to_updates(table_name: StringName, callable: Callable) -> void:
	_add_listener(_update_listeners_by_table, _normalize(table_name), callable)


## Removes an update listener for [param table_name].
func unsubscribe_from_updates(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _update_listeners_by_table.has(key):
		_update_listeners_by_table[key].erase(callable)
		if _update_listeners_by_table[key].is_empty():
			_update_listeners_by_table.erase(key)


## Registers [param callable] to be called with the row about to be deleted for
## [param table_name]. Fires before the message that deletes it is applied at all, so the
## callback reads the row, and every other table, at their state before that message.
##
## A message reports every before-delete, across all its tables, before any of its other
## callbacks. Each evicted row still gets exactly one before-delete and, later, one delete.
func subscribe_to_before_deletes(table_name: StringName, callable: Callable) -> void:
	_add_listener(_before_delete_listeners_by_table, _normalize(table_name), callable)


## Removes a before-delete listener for [param table_name].
func unsubscribe_from_before_deletes(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _before_delete_listeners_by_table.has(key):
		_before_delete_listeners_by_table[key].erase(callable)
		if _before_delete_listeners_by_table[key].is_empty():
			_before_delete_listeners_by_table.erase(key)


## Registers [param callable] to be called with the deleted row for [param table_name].
func subscribe_to_deletes(table_name: StringName, callable: Callable) -> void:
	_add_listener(_delete_listeners_by_table, _normalize(table_name), callable)


## Removes a delete listener for [param table_name].
func unsubscribe_from_deletes(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _delete_listeners_by_table.has(key):
		_delete_listeners_by_table[key].erase(callable)
		if _delete_listeners_by_table[key].is_empty():
			_delete_listeners_by_table.erase(key)


## Registers [param callable] to be called (no args) after all changes in a batch for [param table_name].
func subscribe_to_transactions_completed(table_name: StringName, callable: Callable) -> void:
	_add_listener(_transactions_completed_listeners_by_table, _normalize(table_name), callable)


## Removes a transactions-completed listener for [param table_name].
func unsubscribe_from_transactions_completed(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _transactions_completed_listeners_by_table.has(key):
		_transactions_completed_listeners_by_table[key].erase(callable)
		if _transactions_completed_listeners_by_table[key].is_empty():
			_transactions_completed_listeners_by_table.erase(key)


# --- Primary Key Handling (#5) ---
# _primary_key_cache now serves both roles — _cached_pk_fields removed
func _get_primary_key_field(table_name_lower: StringName) -> StringName:
	if _primary_key_cache.has(table_name_lower):
		return _primary_key_cache[table_name_lower]

	var schema: GDScript = _resolve_row_script(table_name_lower)
	if schema == null:
		return &""
	# The generated row script's PRIMARY_KEY const is the whole answer: codegen emits it
	# for every table the schema gives a primary key and omits it for every table it does
	# not. Nothing may guess a key from a property named `id` or `identity` — such a column
	# on an unkeyed table carries no uniqueness promise, and two rows sharing one would
	# collapse into a single cached entry. A table with no primary key is refcounted by row
	# value instead.
	var constants: Dictionary = schema.get_script_constant_map()
	# One row type can back several tables that disagree about the key — a procedural view
	# returning a table's row type has a primary key only when the module declared one, so
	# the table may be keyed while the view is not. Codegen spells that case out per table;
	# PRIMARY_KEY is the answer for every row type whose tables agree.
	# Codegen keys that map by the LOWER-CASED table name, which is what this function is
	# handed, so a table missing from it simply has no key.
	var pk_by_table: Dictionary = constants.get(&"PRIMARY_KEY_BY_TABLE", { })
	var pk_field: StringName = &""
	if pk_by_table.is_empty():
		pk_field = constants.get(&"PRIMARY_KEY", &"")
	else:
		pk_field = pk_by_table.get(table_name_lower, &"")
	_primary_key_cache[table_name_lower] = pk_field
	return pk_field


# The row script registered for a table, or null. Reports a missing one ONCE per table:
# both callers below need it on every update, so a per-call report would repeat for the
# life of the connection.
#
# What goes wrong without it is not a degraded lookup but a wrong answer: with no column
# list _rows_equal reports every row equal and _row_hash sends them all to one bucket, so a
# table with no primary key collapses into a single cached entry and its deletes release
# the wrong row. Nothing is cached here, so a script registered later still resolves.
#
# Exact wire name, not the underscore-stripped type key: `user_data` and `userdata` are
# both legal table names and collapse onto one entry in schema.types.
func _resolve_row_script(table_name_lower: StringName) -> GDScript:
	var schema: GDScript = _schema.get_table(table_name_lower)
	if schema != null:
		return schema
	if not _unresolved_row_scripts.has(table_name_lower):
		_unresolved_row_scripts[table_name_lower] = true
		push_error(
			(
				"LocalDatabase: no row script registered for table '%s'. Its primary key "
				+ "and columns are unknown, so rows in it cannot be told apart and a table "
				+ "without a primary key will collapse into one cached entry."
			)
			% table_name_lower
		)
	return null


# --- PK-less Row Helpers ---
func _get_row_properties(table_name_lower: StringName) -> Array[StringName]:
	if _row_property_cache.has(table_name_lower):
		return _row_property_cache[table_name_lower]
	var schema: GDScript = _resolve_row_script(table_name_lower)
	if schema == null:
		return []
	var props: Array[StringName] = []
	for prop: Dictionary in schema.get_script_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE:
			props.append(prop.name)
	_row_property_cache[table_name_lower] = props
	return props


# The column names of a generated row/record Object, from its authoritative
# BSATN_TYPES const (the same list the serializer/deserializer enumerate). Empty
# for anything that is not a generated record (plain Object, no BSATN_TYPES).
static func _record_columns(obj: Object) -> Array:
	var script: Script = obj.get_script()
	if script == null:
		return _EMPTY_COLUMNS
	if _record_columns_cache.has(script):
		return _record_columns_cache[script]
	return _build_record_columns(script)


# Cache miss path for [method _record_columns] — reads BSATN_TYPES off the script
# once, freezes the list, and stores it (including the empty result, so a
# non-record script costs one constant-map read for the process, not one per row).
static func _build_record_columns(script: Script) -> Array:
	var cols: Array = _EMPTY_COLUMNS
	var bt: Variant = script.get_script_constant_map().get(&"BSATN_TYPES", null)
	if bt is Dictionary:
		var types: Dictionary = bt
		cols = types.keys()
		cols.make_read_only()
	_record_columns_cache[script] = cols
	return cols


# Value-equality that descends into nested Resource columns (product/sum-type wrappers)
# and Arrays. Variant `==` compares two Objects by identity, and every row/nested record is
# a fresh `.new()` per delivery, so an identity compare reports two structurally-equal rows
# unequal — firing spurious row_updated on the PK path and missing dedup on the PK-less
# path. Columns come from the record's BSATN_TYPES; primitives / Packed*Array
# short-circuit on the final `a == b`. Not free: ~1.6x an identity compare on an
# all-primitive row and ~2.9x on a nested one (tests/bench_rows_equal.gd), which is why
# [method _rows_equal] compares primitive columns inline and only calls this for the
# Object / Array columns that need the walk.
static func _values_equal(a: Variant, b: Variant) -> bool:
	var ta: int = typeof(a)
	if ta != typeof(b):
		return false
	if ta == TYPE_OBJECT:
		# typeof already guarantees non-null (null is TYPE_NIL); is_instance_valid
		# additionally guards a freed ref (H8).
		if not (is_instance_valid(a) and is_instance_valid(b)):
			return a == b
		var cols: Array = _record_columns(a)
		if not cols.is_empty():
			for col: StringName in cols:
				if not _values_equal(a.get(col), b.get(col)):
					return false
			return true
		# No BSATN_TYPES. The SDK's own wrapper types carry their payload in named members
		# instead, so each needs its own descent, or it compares by identity and two
		# structurally equal rows never match. These three are every wrapper the
		# deserializer can put in a column (option.gd, rust_enum.gd — the base of every
		# generated sum type — and schedule_at.gd); a fourth would have to be added here
		# and to [method _value_hash] together.
		if a is Option:
			if b is Option:
				return _values_equal(a.data, b.data)
			return false
		if a is RustEnum:
			if b is RustEnum:
				return a.value == b.value and _values_equal(a.data, b.data)
			return false
		if a is ScheduleAt:
			if b is ScheduleAt:
				return a.kind == b.kind and a.micros == b.micros
			return false
		return a == b # not a record and not a wrapper — nothing to descend into
	if ta == TYPE_ARRAY:
		var aa: Array = a
		var ba: Array = b
		if aa.size() != ba.size():
			return false
		for i: int in aa.size():
			if not _values_equal(aa[i], ba[i]):
				return false
		return true
	if a == b:
		return true
	# The NaN gate, kept in step with the one in [method _rows_equal].
	if ta == TYPE_INT:
		return false
	if ta == TYPE_FLOAT:
		return is_nan(a) and is_nan(b)
	var components: int = _NAN_CARRYING_COMPONENTS.get(ta, 0)
	if components == 0:
		return false
	return _nan_components_equal(a, b, components)


# Two values Variant `==` calls different are still the same row value when the only
# difference is NaN. `NAN == NAN` is false in GDScript, while `hash(NAN)` is a single value
# (Godot's hash_djb2_one_float normalizes NaN and -0.0), and [method _value_hash] is built
# on that hash. Without this the two disagree: a PK-less row carrying NaN is found by hash
# and then never matched, so every delivery caches another copy and every delete is
# dropped; a PK row carrying NaN is reported as an update on every unchanged re-delivery.
#
# It also follows the server, which holds ONE such row: sats types a float column as
# `decorum::Total<f32>` (crates/sats/src/algebraic_value.rs), a total order in which NaN
# equals itself.
#
# Covers the float-vector types only. [method _values_equal] and [method _rows_equal]
# settle int and float columns inline and call this for [constant _NAN_CARRYING_COMPONENTS]
# types alone, and so does the `_eq` that codegen emits on every record type. The gate
# runs on every differing column of every update, and a call there per column cost
# ~100 ns on an update whose changed column is an int
# (tests/bench_rows_equal.gd, differing case). An equal row pays nothing for any of it.
static func _nan_components_equal(a: Variant, b: Variant, components: int) -> bool:
	for i: int in components:
		var ca: float = a[i]
		var cb: float = b[i]
		if ca != cb and not (is_nan(ca) and is_nan(cb)):
			return false
	return true


# Value-hash consistent with [method _values_equal] (equal values hash equal).
# Nested Resource / Array values hash by contained value, not Object identity.
static func _value_hash(v: Variant) -> int:
	var t: int = typeof(v)
	# null is TYPE_NIL (not TYPE_OBJECT) so it skips to hash(v) below.
	if t == TYPE_OBJECT and is_instance_valid(v):
		var cols: Array = _record_columns(v)
		if not cols.is_empty():
			var h: int = 17
			for col: StringName in cols:
				h = h * 31 + _value_hash(v.get(col))
			return h
		# Mirrors the wrapper descent in [method _values_equal] — equal values must
		# hash equal, or the PK-less bucket lookup never finds the entry it matches.
		# The per-type seeds keep two wrappers holding the same payload apart.
		if v is Option:
			return 5 * 31 + _value_hash(v.data)
		if v is RustEnum:
			return (11 * 31 + hash(v.value)) * 31 + _value_hash(v.data)
		if v is ScheduleAt:
			return (23 * 31 + hash(v.kind)) * 31 + hash(v.micros)
		return hash(v)
	if t == TYPE_ARRAY:
		var h: int = 7
		for e: Variant in (v as Array):
			h = h * 31 + _value_hash(e)
		return h
	return hash(v)


# The generic column walk behind [method _ModuleTableType._row_eq]. A generated row type
# overrides that method with a comparison typed to its own columns, which must answer
# exactly what this answers (tests/test_typed_row_equality.gd holds the two together);
# this walk remains for row scripts that carry no override, bindings generated before
# there was one included.
static func _rows_equal(a: _ModuleTableType, b: _ModuleTableType, props: Array[StringName]) -> bool:
	for prop_name: StringName in props:
		# Primitive columns (the majority of every row) compare inline — the per-field
		# [method _values_equal] call is itself the dominant cost of an all-primitive row.
		# Semantics stay identical: differing types are unequal, no `==` coercion.
		var av: Variant = a.get(prop_name)
		var bv: Variant = b.get(prop_name)
		var ta: int = typeof(av)
		if ta != typeof(bv):
			return false
		if ta == TYPE_OBJECT or ta == TYPE_ARRAY:
			if not _values_equal(av, bv):
				return false
		elif av != bv:
			# Nested rather than `and`-ed into the branch above: a compound condition
			# materializes both operands per column even when the first short-circuits,
			# once per column of every compared row (+17% on an all-primitive row,
			# tests/bench_rows_equal.gd). The NaN gate, kept in step with the one in
			# [method _values_equal]; ordered int first, the commonest column.
			if ta == TYPE_INT:
				return false
			if ta == TYPE_FLOAT:
				if not (is_nan(av) and is_nan(bv)):
					return false
			else:
				var components: int = _NAN_CARRYING_COMPONENTS.get(ta, 0)
				if components == 0:
					return false
				if not _nan_components_equal(av, bv, components):
					return false
	return true


func _row_hash(row: _ModuleTableType, props: Array[StringName]) -> int:
	var h: int = 0
	for prop_name: StringName in props:
		h = h * 31 + _value_hash(row.get(prop_name))
	return h


# --- PK-less refcount helpers (counts: { hash -> Array of [row, count] }) ---
# Finds the [row, count] entry for a value, or returns an empty Array if absent
# (a real entry is always [row, count], size 2 — so .is_empty() means "not found").
func _pk_less_find(counts: Dictionary, h: int, row: _ModuleTableType, props: Array[StringName]) -> Array:
	if not counts.has(h):
		return []
	for entry: Array in counts[h]:
		var cached: _ModuleTableType = entry[0]
		if cached._row_eq(row, props):
			return entry
	return []


func _pk_less_add(counts: Dictionary, h: int, row: _ModuleTableType) -> void:
	if not counts.has(h):
		counts[h] = []
	counts[h].append([row, 1])


func _pk_less_remove(counts: Dictionary, h: int, entry: Array) -> void:
	if not counts.has(h):
		return
	counts[h].erase(entry)
	if counts[h].is_empty():
		counts.erase(h)


## Reports ONCE per table that a delete arrived for a row value the mirror does not hold.
## The delete is dropped and the row it meant to remove stays cached for the session — the
## shape a local write into a handed-out row produces (see the class note). Once per table
## because the same mutated row is re-delivered by every later subscription.
func _warn_unmatched_delete(table_name_lower: StringName) -> void:
	if _unmatched_delete_warned.has(table_name_lower):
		return
	_unmatched_delete_warned[table_name_lower] = true
	push_warning(
		(
			"LocalDatabase: a delete for table '%s' matched no cached row, so the row it "
			+ "removes stays in the mirror. This table has no primary key, so rows are "
			+ "matched by value: the usual cause is game code writing to a row the mirror "
			+ "handed it (rows are the cached instances — duplicate before mutating)."
		)
		% table_name_lower
	)


# --- Per-query membership (for prune_query) ---
## Records one MORE reference to [param pk] for a query that already holds it, keeping
## the newest row. The single-reference case is a bare row (written inline on the hot
## insert path); only a repeat allocates the [code][row, count][/code] pair, so a
## subscribe that delivers each row once pays nothing for this.
func _qmem_add_repeat(qmem: Dictionary, pk: Variant, row: _ModuleTableType) -> void:
	var entry: Variant = qmem.get(pk)
	if entry == null:
		qmem[pk] = row
	elif entry is Array:
		entry[0] = row
		entry[1] += 1
	else:
		qmem[pk] = [row, 2]


## Hands one reference back; drops the entry when this query holds no more.
func _qmem_release(qmem: Dictionary, pk: Variant) -> void:
	var entry: Variant = qmem.get(pk)
	if entry is Array:
		entry[1] -= 1
		if entry[1] <= 1:
			qmem[pk] = entry[0]
	elif entry != null:
		qmem.erase(pk)


func _query_table_pk_mem(query_id: int, table: StringName) -> Dictionary:
	if not _query_rows.has(query_id):
		_query_rows[query_id] = { }
	var tables: Dictionary = _query_rows[query_id]
	if not tables.has(table):
		tables[table] = { } # pk -> [row, count]
	return tables[table]


func _query_table_pkless_mem(query_id: int, table: StringName) -> Dictionary:
	if not _query_rows.has(query_id):
		_query_rows[query_id] = { }
	var tables: Dictionary = _query_rows[query_id]
	if not tables.has(table):
		tables[table] = { } # hash -> [[row, count]] (same shape as _pk_less_counts)
	return tables[table]


## Drops every row contributed by [param query_id] from the cache. Used on a
## SubscriptionError for an already-applied subscription (the server sends no dropped
## rows on an error): decrements each row's refcount via the normal delete path and
## evicts only rows no other subscription holds — the same effect as an unsubscribe,
## reconstructed from locally-tracked per-query membership. Every table of the query goes
## through one [method _apply_batch], so the prune is reported as one message (queued, when
## called from inside a row callback).
func prune_query(query_id: int) -> void:
	if not _query_rows.has(query_id):
		return
	var tables: Dictionary = _query_rows[query_id]
	# Built in full before anything applies: applying releases entries of this membership.
	var drops: Array[TableUpdateData] = []
	for table_name_lower: StringName in tables:
		var membership: Dictionary = tables[table_name_lower]
		var drop: TableUpdateData = TableUpdateData.new()
		drop.table_name = table_name_lower
		if _get_primary_key_field(table_name_lower).is_empty():
			# PK-less membership { hash -> [[row, count]] }: emit `count` deletes per value.
			for h: int in membership:
				for entry: Array in membership[h]:
					for _i: int in entry[1]:
						drop.deletes.append(entry[0])
		else:
			# PK membership { pk -> row | [row, count] }: one delete per reference this
			# query contributed.
			for pk: Variant in membership:
				var entry: Variant = membership[pk]
				if entry is Array:
					for _i: int in entry[1]:
						drop.deletes.append(entry[0])
				else:
					drop.deletes.append(entry)
		if not drop.deletes.is_empty():
			drops.append(drop)
	# Erased first and the drops applied untracked: the membership is going away, and a
	# drop queued behind another message (a prune from inside a row callback) would
	# otherwise re-create it after this returns.
	_query_rows.erase(query_id)
	apply_table_updates(drops)


## The session-boundary wipe counter — see [member _session_generation]. A caller that
## loops over several updates of its own (the client walks a transaction's query sets,
## an UnsubscribeApplied's tables, a subscribe snapshot) reads this before the first one
## and stops when it moves: the remaining updates belong to a session whose mirror has
## already been thrown away, and applying them into the new one strands their rows there
## for good. Deliberately NOT [member _generation] — a mid-session
## [method clear_all_tables] must not truncate a live transaction.
func session_generation() -> int:
	return _session_generation


## Drops the per-query membership index for [param query_id] without touching the cache
## (the rows were already removed via the normal delete path, e.g. an unsubscribe whose
## dropped rows the server echoed). Prevents the index from growing unbounded.
func forget_query(query_id: int) -> void:
	_query_rows.erase(query_id)


## Applies the rows of a [SubscribeAppliedMessage] to the local store as one message.
func apply_database_subscription_applied(db_update: SubscribeAppliedMessage) -> void:
	if not db_update:
		return
	apply_table_updates(db_update.tables, db_update.query_set_id.id)


## Applies one query set's [DatabaseUpdateData] to the local store as one message.
func apply_database_update(db_update: DatabaseUpdateData) -> void:
	if not db_update:
		return
	apply_table_updates(db_update.tables, db_update.query_id.id)


## Applies every query set of a [TransactionUpdateMessage] to the local store as ONE
## message, the way the official SDKs do: the sets' rows are merged per table before
## anything is applied, so a row that leaves one set and enters another in the same
## transaction (an entity crossing between two separately subscribed cells) is an update,
## not a delete followed by an insert.
func apply_transaction_update(tx_update: TransactionUpdateMessage) -> void:
	if not tx_update:
		return
	var updates: Array[TableUpdateData] = []
	var query_ids: PackedInt64Array = []
	for dataset: DatabaseUpdateData in tx_update.query_sets:
		var qid: int = dataset.query_id.id
		for table_update: TableUpdateData in dataset.tables:
			updates.append(table_update)
			query_ids.append(qid)
	_apply_batch(updates, query_ids)


## Applies [param tables], all sent for [param query_id] (-1 records no query
## membership), as one message.
func apply_table_updates(tables: Array[TableUpdateData], query_id: int = -1) -> void:
	var query_ids: PackedInt64Array = []
	query_ids.resize(tables.size())
	query_ids.fill(query_id)
	_apply_batch(tables, query_ids)


## Applies a single [TableUpdateData] as a message of its own. [param query_id] (>= 0)
## records which subscription contributed each row, so a [method prune_query] can later
## drop exactly that query's rows on a SubscriptionError.
func apply_table_update(table_update: TableUpdateData, query_id: int = -1) -> void:
	var updates: Array[TableUpdateData] = [table_update]
	var query_ids: PackedInt64Array = [query_id]
	_apply_batch(updates, query_ids)


## One table's share of a message: every [TableUpdateData] the message carries for it with
## the query each came from, the per-key counts a table with deletes is applied from, and
## the events applying it produced. Built and consumed inside one [method _apply_batch].
class _TablePlan:
	extends RefCounted

	var table: StringName
	var pk_field: StringName
	var is_event: bool = false
	var has_inserts: bool = false
	var has_deletes: bool = false
	var updates: Array[TableUpdateData] = []
	var query_ids: PackedInt64Array = []
	## Keyed table with inserts AND deletes: pk -> deletes across the whole message not yet
	## paired with an insert, and the running total of those.
	var del_count: Dictionary = { }
	var unpaired_deletes: int = 0
	## pk -> deletes beyond the references the mirror holds for it. They release nothing;
	## see [method _apply_pk_counted] for the inserts they pair with.
	var void_deletes: Dictionary = { }
	## Unkeyed table with deletes: row hash -> Array of [row, inserts, deletes, hash], and
	## every such group in first-seen order. Groups are told apart by value, like the cache.
	var groups: Dictionary = { }
	var group_order: Array = []
	## Cached rows this message will evict, read before anything is applied.
	var before_delete: Array[_ModuleTableType] = []
	## Untyped, and read back into Variant loop variables: a typed append costs ~125 ns/row
	## against ~53, and a Variant loop variable skips the per-row class check (~110 ns)
	## that reading an untyped Array into a `_ModuleTableType` variable costs.
	var inserted: Array = []
	## Flattened [old, new, old, new, ...].
	var updated: Array = []
	var deleted: Array = []
	## How many [member inserted] rows and [member updated] pairs have been reported so far;
	## -1 while their loop runs, which counts in [member LocalDatabase._in_flight_sent].
	var inserts_sent: int = 0
	var updates_sent: int = 0


## The whole apply path. A message is applied in three phases, matching the official
## SDKs (C# PreApply / Apply / PostApply; Rust and TypeScript apply, then invoke):
## [br]1. Plan: merge the message per table and read which cached rows it will evict, then
## report those to [method subscribe_to_before_deletes] while the mirror is untouched.
## [br]2. Apply: every table's rows, refcounts, query membership and index caches. No game
## code runs here.
## [br]3. Dispatch: insert, update and delete callbacks, then one transactions-completed,
## per table.
## [br][br]
## So a callback always sees the message fully applied — a row inserted into another table
## by the same transaction is already there — and never a half-applied one.
## [br][br]
## Messages are applied one at a time, as the official SDKs process them: one applied from
## inside a callback of another is queued and applied when that one has finished, so no
## message starts while another is between its phases.
func _apply_batch(updates: Array[TableUpdateData], query_ids: PackedInt64Array) -> void:
	if _applying:
		_queued_batches.append([updates, query_ids, _session_generation])
		return
	_applying = true
	_apply_message(updates, query_ids)
	# Grows while it drains: a queued message's callbacks can queue more. One queued in a
	# session that has since ended ([method clear_local_db] ran after it was queued) is
	# dropped: applying it would strand the old session's rows in the new mirror.
	var i: int = 0
	while i < _queued_batches.size():
		if i == _MAX_QUEUED_MESSAGES:
			push_error(
				(
					"LocalDatabase: %d messages applied from inside row callbacks, and they "
					+ "keep applying more. Dropping the remaining %d."
				)
				% [i, _queued_batches.size() - i]
			)
			break
		var queued: Array = _queued_batches[i]
		if queued[2] == _session_generation:
			_apply_message(queued[0], queued[1])
		i += 1
	_queued_batches.clear()
	_applying = false


## One message, through the three phases of [method _apply_batch].
func _apply_message(updates: Array[TableUpdateData], query_ids: PackedInt64Array) -> void:
	var plans: Array[_TablePlan] = _plan_batch(updates, query_ids)
	if plans.is_empty():
		return
	for plan: _TablePlan in plans:
		if plan.has_deletes and not plan.is_event:
			var predict: bool = _has_before_delete_consumers(plan.table)
			if plan.pk_field.is_empty():
				_count_pkless_plan(plan, predict)
			elif plan.has_inserts:
				_count_pk_plan(plan, predict)
			elif predict:
				_predict_pk_deletes(plan)
	var gen: int = _generation
	if not _fire_before_deletes(plans, gen):
		return # a before-delete wiped the mirror; nothing of this message is left to apply
	for plan: _TablePlan in plans:
		_apply_plan(plan)
		_update_indexes(plan)
	var base: int = _undispatched.size()
	_undispatched.append_array(plans)
	var wiped: bool = false
	for plan: _TablePlan in plans:
		wiped = _dispatch_plan(plan, gen, wiped)
	_undispatched.resize(base)


## Groups [param updates] by table, in the order each table first appears. An update for a
## table the schema does not know is reported and dropped.
func _plan_batch(updates: Array[TableUpdateData], query_ids: PackedInt64Array) -> Array[_TablePlan]:
	var plans: Array[_TablePlan] = []
	var by_table: Dictionary = { }
	for i: int in updates.size():
		var table_update: TableUpdateData = updates[i]
		var table_name_lower: StringName = _normalize(table_update.table_name)
		if not _tables.has(table_name_lower):
			printerr(
				"LocalDatabase: Received update for unknown table '",
				table_update.table_name,
				"' (normalized: '",
				table_name_lower,
				"')",
			)
			continue
		var plan: _TablePlan = by_table.get(table_name_lower)
		if plan == null:
			plan = _TablePlan.new()
			plan.table = table_name_lower
			plan.pk_field = _get_primary_key_field(table_name_lower)
			by_table[table_name_lower] = plan
			plans.append(plan)
		plan.is_event = plan.is_event or table_update.is_event
		plan.has_inserts = plan.has_inserts or not table_update.inserts.is_empty()
		plan.has_deletes = plan.has_deletes or not table_update.deletes.is_empty()
		plan.updates.append(table_update)
		plan.query_ids.append(query_ids[i])
	return plans


## A HELD keyed row's refcount ([param old] > 0) after a message that inserted it
## [param ins] times and deleted it [param del] times ([param del] <= [param old], see
## [method _count_pk_plan]): every insert pairs with a delete first, so only the difference
## moves it. Used to predict evictions, which only a held row can have.
static func _pk_new_ref(old: int, ins: int, del: int) -> int:
	return maxi(0, old + ins - del)


## Whether anything hears a before-delete for [param table_name]. Reading which rows a
## message will evict costs a lookup per deleted key, paid only when someone listens.
func _has_before_delete_consumers(table_name_lower: StringName) -> bool:
	return (
		_before_delete_listeners_by_table.has(table_name_lower)
		or not row_before_delete.get_connections().is_empty()
	)


## Counts a keyed table's deletes per pk across the whole message and hands each deleting
## query its references back (membership is per delivery: a row leaving set A for set B
## leaves A's membership here and joins B's in [method _apply_pk_counted]). When
## [param predict], also reads which cached rows the message will evict. Null pks are
## reported and skipped.
func _count_pk_plan(plan: _TablePlan, predict: bool) -> void:
	var pk_field: StringName = plan.pk_field
	var del_count: Dictionary = plan.del_count
	var void_deletes: Dictionary = plan.void_deletes
	# A delete can only release a reference the mirror holds. The surplus (the server's
	# update encoding for a row this mirror never got) is set aside as void.
	var ref_table: Dictionary = _ref_counts.get(plan.table, { })
	var unpaired: int = 0
	for i: int in plan.updates.size():
		var qid: int = plan.query_ids[i]
		var track_query: bool = qid >= 0
		var qmem: Dictionary = _query_table_pk_mem(qid, plan.table) if track_query else { }
		for row: Variant in plan.updates[i].deletes:
			var pk: Variant = row.get(pk_field)
			if pk == null:
				push_warning(
					"LocalDatabase: Deleted row for table '%s' has null PK '%s'. Skipping."
					% [plan.table, pk_field]
				)
				continue
			var wanted: int = del_count.get(pk, 0) + 1
			if wanted > ref_table.get(pk, 0):
				void_deletes[pk] = void_deletes.get(pk, 0) + 1
			else:
				del_count[pk] = wanted
				unpaired += 1
			if track_query:
				_qmem_release(qmem, pk)
	plan.unpaired_deletes = unpaired
	if predict:
		_predict_pk_mixed(plan)


## Which cached rows a message that inserts and deletes will take to zero, from the net
## count per pk. Only paid when something listens for before-deletes.
func _predict_pk_mixed(plan: _TablePlan) -> void:
	var ins_count: Dictionary = { }
	for table_update: TableUpdateData in plan.updates:
		for row: Variant in table_update.inserts:
			var pk: Variant = row.get(plan.pk_field)
			if pk != null:
				ins_count[pk] = ins_count.get(pk, 0) + 1
	var ref_table: Dictionary = _ref_counts.get(plan.table, { })
	var table_dict: Dictionary = _tables[plan.table]
	for pk: Variant in plan.del_count:
		var old: int = ref_table.get(pk, 0)
		if old > 0 and _pk_new_ref(old, ins_count.get(pk, 0), plan.del_count[pk]) == 0:
			var cached: Variant = table_dict.get(pk)
			if cached != null:
				plan.before_delete.append(cached)


## [method _count_pk_plan]'s prediction for a message that only deletes from the table:
## the cached rows its deletes take to zero, counted without touching the mirror.
func _predict_pk_deletes(plan: _TablePlan) -> void:
	var ref_table: Dictionary = _ref_counts.get(plan.table, { })
	var table_dict: Dictionary = _tables[plan.table]
	var pending: Dictionary = { }
	for table_update: TableUpdateData in plan.updates:
		for row: Variant in table_update.deletes:
			var pk: Variant = row.get(plan.pk_field)
			if pk == null:
				continue
			var left: int = pending.get(pk, ref_table.get(pk, 0))
			pending[pk] = left - 1
			if left == 1:
				var cached: Variant = table_dict.get(pk)
				if cached != null:
					plan.before_delete.append(cached)


## Counts an unkeyed table's inserts and deletes per row value across the whole message,
## and when [param predict] reads which cached rows the message will evict.
func _count_pkless_plan(plan: _TablePlan, predict: bool) -> void:
	var props: Array[StringName] = _get_row_properties(plan.table)
	for table_update: TableUpdateData in plan.updates:
		for row: _ModuleTableType in table_update.inserts:
			_pkless_group(plan, row, props)[1] += 1
		for row: _ModuleTableType in table_update.deletes:
			_pkless_group(plan, row, props)[2] += 1
	if not predict:
		return
	var counts: Dictionary = _pk_less_counts.get(plan.table, { })
	for group: Array in plan.group_order:
		if group[2] == 0:
			continue
		var entry: Array = _pk_less_find(counts, group[3], group[0], props)
		if not entry.is_empty() and entry[1] > 0 and entry[1] + group[1] - group[2] <= 0:
			plan.before_delete.append(entry[0])


## The [code][row, inserts, deletes, hash][/code] group holding [param row]'s value,
## created on first sight.
func _pkless_group(plan: _TablePlan, row: _ModuleTableType, props: Array[StringName]) -> Array:
	var h: int = _row_hash(row, props)
	var groups: Dictionary = plan.groups
	if groups.has(h):
		for group: Array in groups[h]:
			var member: _ModuleTableType = group[0]
			if member._row_eq(row, props):
				return group
	else:
		groups[h] = []
	var created: Array = [row, 0, 0, h]
	groups[h].append(created)
	plan.group_order.append(created)
	return created


## Phase 1's callbacks. Returns false when one of them wiped the mirror, which ends the
## message: the wipe emptied the store the plans were read from, and reported (or, for
## [method clear_all_tables], deliberately did not report) every row still in it. Each
## table that announced a before-delete is still terminated then, since a silent wipe
## leaves the announced rows with no delete and no close otherwise.
func _fire_before_deletes(plans: Array[_TablePlan], gen: int) -> bool:
	var sent: PackedInt64Array = []
	var intact: bool = true
	for i: int in plans.size():
		var plan: _TablePlan = plans[i]
		if plan.before_delete.is_empty():
			continue
		if not _fire_table_before_deletes(plan, gen, sent):
			for j: int in i + 1:
				var announced: _TablePlan = plans[j]
				var tx_listeners: Array = _listener_snapshot(
					_transactions_completed_listeners_by_table,
					announced.table,
				)
				_end_table_transaction(announced.table, tx_listeners, not announced.before_delete.is_empty())
			intact = false
			break
	for id: int in sent:
		_before_delete_sent.erase(id)
	return intact


## One table's before-deletes. Each row whose listeners all heard it goes into
## [param sent] and [member _before_delete_sent]. Returns false as soon as a listener wiped the mirror: the
## wipe reports the row in hand itself, so neither the remaining listeners nor the signal
## hear it from here.
func _fire_table_before_deletes(plan: _TablePlan, gen: int, sent: PackedInt64Array) -> bool:
	var listeners: Array = _listener_snapshot(_before_delete_listeners_by_table, plan.table)
	for row: _ModuleTableType in plan.before_delete:
		for listener: Callable in listeners:
			if listener.is_valid():
				listener.call(row)
				if _generation != gen:
					return false
		# Recorded before the signal: an emit reaches every connection even when one of
		# them wipes, so the row is fully reported once the emit starts.
		var id: int = row.get_instance_id()
		_before_delete_sent[id] = true
		sent.append(id)
		row_before_delete.emit(plan.table, row)
		if _generation != gen:
			return false
	return true


## Phase 2 for one table: writes the message into the store and records the events it
## produced. Calls no listener.
func _apply_plan(plan: _TablePlan) -> void:
	if plan.is_event:
		# Event tables carry ephemeral rows: reported as inserts, never stored, no refcount.
		# The deserializer flattens the server's EventTable row lists into inserts.
		for table_update: TableUpdateData in plan.updates:
			plan.inserted.append_array(table_update.inserts)
		return
	if plan.pk_field.is_empty():
		if not _pk_less_tables.has(plan.table):
			_pk_less_tables[plan.table] = []
		if not _pk_less_counts.has(plan.table):
			_pk_less_counts[plan.table] = { }
		if plan.has_deletes:
			_apply_pkless_counted(plan)
		else:
			_apply_pkless_inserts(plan)
		return
	if not _ref_counts.has(plan.table):
		_ref_counts[plan.table] = { }
	if not plan.has_deletes:
		_apply_pk_inserts(plan)
	elif not plan.has_inserts:
		_apply_pk_deletes(plan)
	else:
		_apply_pk_counted(plan)


## A keyed table with no deletes in this message — every subscribe snapshot, and most
## inserts. Applied row by row: a pk nothing holds is an insert, a held one is another
## query's overlapping delivery (refcount + 1, an update only if the value differs).
func _apply_pk_inserts(plan: _TablePlan) -> void:
	var table_dict: Dictionary = _tables[plan.table]
	var ref_table: Dictionary = _ref_counts[plan.table]
	var props: Array[StringName] = _get_row_properties(plan.table)
	var pk_field: StringName = plan.pk_field
	var inserted: Array = plan.inserted
	var updated: Array = plan.updated
	# While every row of a lone delivery is new, the delivery's own array is the insert
	# report: new_rows counts them instead of copying each one (~53 ns/row), and the first
	# row that is not new copies the ones before it and stops the aliasing.
	var aliasing: bool = plan.updates.size() == 1
	var new_rows: int = 0
	for i: int in plan.updates.size():
		var qid: int = plan.query_ids[i]
		var track_query: bool = qid >= 0
		var qmem: Dictionary = _query_table_pk_mem(qid, plan.table) if track_query else { }
		var rows: Array = plan.updates[i].inserts
		for row: Variant in rows:
			var pk: Variant = row.get(pk_field)
			if pk != null:
				var old_ref: int = ref_table.get(pk, 0)
				ref_table[pk] = old_ref + 1
				if old_ref == 0:
					if track_query:
						qmem[pk] = row
					table_dict[pk] = row
					if aliasing:
						new_rows += 1
					else:
						inserted.append(row)
					continue
			if aliasing:
				inserted.append_array(rows.slice(0, new_rows))
				aliasing = false
			if pk == null:
				push_error(
					"LocalDatabase: Inserted row for table '%s' has null PK '%s'. Skipping."
					% [plan.table, pk_field]
				)
				continue
			if track_query:
				_qmem_add_repeat(qmem, pk, row)
			var prev: Variant = table_dict.get(pk)
			if prev == null:
				# Referenced but not cached (a desync): insert, so no null `old` reaches
				# an update listener.
				table_dict[pk] = row
				inserted.append(row)
			elif props.is_empty() or not prev._row_eq(row, props):
				table_dict[pk] = row
				updated.append(prev)
				updated.append(row)
	if aliasing:
		plan.inserted = plan.updates[0].inserts


## A keyed table whose message only deletes — every unsubscribe echo, and rows leaving.
## Applied row by row: each delete releases one reference, and the one that takes a row
## to zero evicts it. A delete for a pk nothing holds is dropped.
func _apply_pk_deletes(plan: _TablePlan) -> void:
	var table_dict: Dictionary = _tables[plan.table]
	var ref_table: Dictionary = _ref_counts[plan.table]
	var pk_field: StringName = plan.pk_field
	var deleted: Array = plan.deleted
	for i: int in plan.updates.size():
		var qid: int = plan.query_ids[i]
		var track_query: bool = qid >= 0
		var qmem: Dictionary = _query_table_pk_mem(qid, plan.table) if track_query else { }
		for row: Variant in plan.updates[i].deletes:
			var pk: Variant = row.get(pk_field)
			if pk == null:
				push_warning(
					"LocalDatabase: Deleted row for table '%s' has null PK '%s'. Skipping."
					% [plan.table, pk_field]
				)
				continue
			var old: int = ref_table.get(pk, 0)
			if old <= 0:
				continue
			if track_query:
				_qmem_release(qmem, pk)
			if old > 1:
				ref_table[pk] = old - 1
				continue
			ref_table.erase(pk)
			var prev: Variant = table_dict.get(pk)
			if prev != null:
				table_dict.erase(pk)
				deleted.append(prev)


## A keyed table whose message carries inserts and deletes, merged across every query
## set. Each insert first pairs with a pending delete of its pk anywhere in the message —
## an update, refcount unchanged, so a row leaving one set for another is one update —
## and only the surplus is a new reference or a real delete ([method _pk_new_ref] for a
## held row). on_update fires only when the value differs. [method _count_pk_plan] has
## already set aside the deletes of references the mirror does not hold; an insert paired
## with one of those goes through [method _pair_void_delete].
func _apply_pk_counted(plan: _TablePlan) -> void:
	var table_dict: Dictionary = _tables[plan.table]
	var ref_table: Dictionary = _ref_counts[plan.table]
	var props: Array[StringName] = _get_row_properties(plan.table)
	var pk_field: StringName = plan.pk_field
	var del_count: Dictionary = plan.del_count
	var void_deletes: Dictionary = plan.void_deletes
	var inserted: Array = plan.inserted
	var updated: Array = plan.updated
	var unpaired: int = plan.unpaired_deletes
	for i: int in plan.updates.size():
		var qid: int = plan.query_ids[i]
		var track_query: bool = qid >= 0
		var qmem: Dictionary = _query_table_pk_mem(qid, plan.table) if track_query else { }
		for row: Variant in plan.updates[i].inserts:
			var pk: Variant = row.get(pk_field)
			if pk == null:
				push_error(
					"LocalDatabase: Inserted row for table '%s' has null PK '%s'. Skipping."
					% [plan.table, pk_field]
				)
				continue
			var pending: int = del_count.get(pk, 0)
			if pending > 0:
				del_count[pk] = pending - 1
				unpaired -= 1
				if track_query:
					_qmem_add_repeat(qmem, pk, row)
			elif void_deletes.get(pk, 0) > 0:
				_pair_void_delete(void_deletes, ref_table, pk, qmem if track_query else null, row)
			else:
				ref_table[pk] = ref_table.get(pk, 0) + 1
				if track_query:
					_qmem_add_repeat(qmem, pk, row)
			var prev: Variant = table_dict.get(pk)
			if prev == null:
				table_dict[pk] = row
				inserted.append(row)
			elif props.is_empty() or not prev._row_eq(row, props):
				table_dict[pk] = row
				updated.append(prev)
				updated.append(row)
	if unpaired > 0:
		_apply_unpaired_pk_deletes(plan)


## An insert paired with a void delete: the server's update encoding for a row the mirror
## holds no reference to. Each query that delivers such a pair holds ONE reference to the
## row however many pairs it sends: under-counting self-heals on the first later delete,
## while over-counting caches a row no delete ever evicts. A second query's pair is its own
## reference, recorded in its own membership, so [method prune_query] of the first leaves
## the row to the second. [param qmem] is null when the delivery records no query; such a
## pair takes a reference only when nothing holds one.
func _pair_void_delete(
		void_deletes: Dictionary,
		ref_table: Dictionary,
		pk: Variant,
		qmem: Variant,
		row: _ModuleTableType,
) -> void:
	void_deletes[pk] -= 1
	if qmem == null:
		if ref_table.get(pk, 0) == 0:
			ref_table[pk] = 1
		return
	var membership: Dictionary = qmem
	var entry: Variant = membership.get(pk)
	if entry == null:
		ref_table[pk] = ref_table.get(pk, 0) + 1
		membership[pk] = row
	elif entry is Array:
		entry[0] = row
	else:
		membership[pk] = row


## The deletes of a mixed message no insert paired with: each releases one reference, and
## the one that takes a row to zero evicts it.
func _apply_unpaired_pk_deletes(plan: _TablePlan) -> void:
	var table_dict: Dictionary = _tables[plan.table]
	var ref_table: Dictionary = _ref_counts[plan.table]
	var deleted: Array = plan.deleted
	for pk: Variant in plan.del_count:
		var left: int = plan.del_count[pk]
		if left <= 0:
			continue
		var old: int = ref_table.get(pk, 0)
		if old <= 0:
			continue
		if old > left:
			ref_table[pk] = old - left
			continue
		ref_table.erase(pk)
		var prev: Variant = table_dict.get(pk)
		if prev != null:
			table_dict.erase(pk)
			deleted.append(prev)


## An unkeyed table with no deletes in this message: a value nothing holds is an insert,
## a held one only gains a reference.
func _apply_pkless_inserts(plan: _TablePlan) -> void:
	var rows_array: Array = _pk_less_tables[plan.table]
	var counts: Dictionary = _pk_less_counts[plan.table]
	var props: Array[StringName] = _get_row_properties(plan.table)
	var inserted: Array = plan.inserted
	for i: int in plan.updates.size():
		var qid: int = plan.query_ids[i]
		var track_query: bool = qid >= 0
		var qmem: Dictionary = _query_table_pkless_mem(qid, plan.table) if track_query else { }
		for row: _ModuleTableType in plan.updates[i].inserts:
			var h: int = _row_hash(row, props)
			var entry: Array = _pk_less_find(counts, h, row, props)
			if entry.is_empty():
				_pk_less_add(counts, h, row)
				rows_array.append(row)
				inserted.append(row)
			else:
				entry[1] += 1
			if track_query:
				_pkless_member_add(qmem, h, row, props)


## An unkeyed table whose message carries deletes. Each value's multiplicity moves by its
## net count across every query set; 0 -> positive is an insert, positive -> 0 a delete.
## A delete for a value the mirror does not hold is reported once per table and dropped.
func _apply_pkless_counted(plan: _TablePlan) -> void:
	var props: Array[StringName] = _get_row_properties(plan.table)
	for i: int in plan.updates.size():
		var qid: int = plan.query_ids[i]
		if qid < 0:
			continue
		var qmem: Dictionary = _query_table_pkless_mem(qid, plan.table)
		for row: _ModuleTableType in plan.updates[i].inserts:
			_pkless_member_add(qmem, _row_hash(row, props), row, props)
		for row: _ModuleTableType in plan.updates[i].deletes:
			var h: int = _row_hash(row, props)
			var member: Array = _pk_less_find(qmem, h, row, props)
			if not member.is_empty():
				member[1] -= 1
				if member[1] == 0:
					_pk_less_remove(qmem, h, member)
	var counts: Dictionary = _pk_less_counts[plan.table]
	var rows_array: Array = _pk_less_tables[plan.table]
	var inserted: Array = plan.inserted
	var deleted: Array = plan.deleted
	var evicted: Dictionary[int, bool] = { }
	for group: Array in plan.group_order:
		var h: int = group[3]
		var entry: Array = _pk_less_find(counts, h, group[0], props)
		var old: int = 0 if entry.is_empty() else entry[1]
		var new_count: int = old + group[1] - group[2]
		if new_count < 0:
			_warn_unmatched_delete(plan.table)
			new_count = 0
		if old == 0:
			if new_count > 0:
				_pk_less_add(counts, h, group[0])
				_pk_less_find(counts, h, group[0], props)[1] = new_count
				rows_array.append(group[0])
				inserted.append(group[0])
		elif new_count == 0:
			var cached: _ModuleTableType = entry[0]
			_pk_less_remove(counts, h, entry)
			evicted[cached.get_instance_id()] = true
			deleted.append(cached)
		else:
			entry[1] = new_count
	if not evicted.is_empty():
		_compact_pkless(plan.table, evicted)


## Records one more reference to [param row]'s value in an unkeyed query membership.
func _pkless_member_add(qmem: Dictionary, h: int, row: _ModuleTableType, props: Array[StringName]) -> void:
	var member: Array = _pk_less_find(qmem, h, row, props)
	if member.is_empty():
		_pk_less_add(qmem, h, row)
	else:
		member[1] += 1


## Drops the rows whose instance ids are in [param evicted] from an unkeyed table's row
## list, in one pass.
func _compact_pkless(table_name_lower: StringName, evicted: Dictionary[int, bool]) -> void:
	var rows_array: Array = _pk_less_tables[table_name_lower]
	var write_idx: int = 0
	for read_idx: int in rows_array.size():
		var row: _ModuleTableType = rows_array[read_idx]
		if evicted.has(row.get_instance_id()):
			continue
		rows_array[write_idx] = row
		write_idx += 1
	rows_array.resize(write_idx)


## Keeps the generated index caches in step with what [method _apply_plan] just wrote,
## before any game callback can read them. Updates run before deletes: when one message
## hands a unique value from one row to another, the index's holder checks keep the
## successor either way.
func _update_indexes(plan: _TablePlan) -> void:
	var hooks: Array = _index_hooks_by_table.get(plan.table, _EMPTY_LISTENERS)
	if hooks.is_empty() or plan.is_event:
		return
	for hook: Array in hooks:
		var on_insert: Callable = hook[0]
		var on_update: Callable = hook[1]
		var on_delete: Callable = hook[2]
		if not on_insert.is_valid():
			continue # the index was freed; pruned on the next registration
		for row: Variant in plan.inserted:
			on_insert.call(row)
		for i: int in range(0, plan.updated.size(), 2):
			on_update.call(plan.updated[i], plan.updated[i + 1])
		for row: Variant in plan.deleted:
			on_delete.call(row)


## Phase 3 for one table: the insert, update and delete callbacks, then the terminator.
## Returns whether the mirror has been wiped by now ([param wiped] carries that across
## tables).
##
## A wipe from inside a callback ends the inserts and updates still to be reported. The
## wipe reports only what a consumer was told about ([method _unannounced_rows]): an
## unreported insert is dropped silently, an unreported update is reported gone as the row
## it replaced. The deletes are reported regardless. Their rows left the mirror in phase 2,
## before the wipe took its snapshot, so this is the only record a consumer gets of them.
func _dispatch_plan(plan: _TablePlan, gen: int, wiped: bool) -> bool:
	var table_name_lower: StringName = plan.table
	var tx_listeners: Array = _listener_snapshot(
		_transactions_completed_listeners_by_table,
		table_name_lower,
	)
	var dispatched: bool = false
	var inserted: Array = plan.inserted
	var updated: Array = plan.updated
	var deleted: Array = plan.deleted
	if not wiped and not inserted.is_empty():
		var insert_listeners: Array = _listener_snapshot(_insert_listeners_by_table, table_name_lower)
		# Each loop sets this on entry: its first row is always reported, since the only game
		# code run before it is the loop above, and that one reported a row to run any.
		dispatched = true
		plan.inserts_sent = -1
		_in_flight_sent = 0
		for row: Variant in inserted:
			if _generation != gen:
				wiped = true
				break
			_in_flight_sent += 1
			for listener: Callable in insert_listeners:
				if listener.is_valid():
					listener.call(row)
			row_inserted.emit(table_name_lower, row)
		plan.inserts_sent = _in_flight_sent
	if not wiped and not updated.is_empty():
		var update_listeners: Array = _listener_snapshot(_update_listeners_by_table, table_name_lower)
		dispatched = true
		plan.updates_sent = -1
		_in_flight_sent = 0
		for i: int in range(0, updated.size(), 2):
			if _generation != gen:
				wiped = true
				break
			_in_flight_sent += 1
			var old_row: Variant = updated[i]
			var new_row: Variant = updated[i + 1]
			for listener: Callable in update_listeners:
				if listener.is_valid():
					listener.call(old_row, new_row)
			row_updated.emit(table_name_lower, old_row, new_row)
		plan.updates_sent = _in_flight_sent
	if not deleted.is_empty():
		var delete_listeners: Array = _listener_snapshot(_delete_listeners_by_table, table_name_lower)
		dispatched = true
		for row: Variant in deleted:
			for listener: Callable in delete_listeners:
				if listener.is_valid():
					listener.call(row)
			row_deleted.emit(table_name_lower, row)
	_end_table_transaction(table_name_lower, tx_listeners, dispatched)
	return wiped or _generation != gen


## Closes out one table's share of a message: the [signal row_transactions_completed]
## terminator plus its listeners, emitted only when [param dispatched] says the message
## reported something for this table. It is owed even after a wipe cut the reporting
## short: a consumer that redraws on it would otherwise hold a view it was told to update
## and never told to finish.
func _end_table_transaction(table_name_lower: StringName, tx_listeners: Array, dispatched: bool) -> void:
	if not dispatched:
		return
	for listener: Callable in tx_listeners:
		if listener.is_valid():
			listener.call()
	row_transactions_completed.emit(table_name_lower)


## Wipes every cached row from all tables, emitting a delete callback per row and a
## transactions-completed callback per non-empty table. This is how the client resets
## the mirror before a reconnect's resubscribe refills it: the resubscribe re-delivers
## only the rows that still exist, so reporting the wipe is what lets a consumer drop
## whatever it built for a row that was deleted while the client was away.
func clear_local_db() -> void:
	# Snapshot the rows, then clear the INNER containers, THEN run the delete callbacks, so
	# a listener that applies a message lands in the freshly-cleared maps
	# instead of rows about to be wiped (M4). Inner, not outer: the outer table keys are
	# what _init pre-populates and _plan_batch's known-table guard relies on, so
	# reassigning to {} would make every later PK-table update an "unknown table". The
	# snapshot loops invoke no listeners, so they cannot mutate the dicts mid-iteration.
	var unannounced: Dictionary[int, Variant] = _unannounced_rows()
	var pk_rows: Array = [] # of [table_name, rows]
	for table_name_lower: StringName in _tables:
		var inner: Dictionary = _tables[table_name_lower]
		pk_rows.append([table_name_lower, _announced(inner.values(), unannounced)])
		inner.clear()
	var pk_less_rows: Array = [] # of [table_name, rows]
	for table_name_lower: StringName in _pk_less_tables:
		var arr: Array = _pk_less_tables[table_name_lower]
		pk_less_rows.append([table_name_lower, _announced(arr.duplicate(), unannounced)])
		arr.clear()
	_ref_counts.clear()
	_pk_less_counts.clear()
	_query_rows.clear()
	# Bumped with the containers, before the first callback goes out: an
	# _apply_batch frame further up the stack (a listener that reconnects wipes
	# from inside its own dispatch) has to see this on its very next check.
	_generation += 1
	_session_generation += 1 # this wipe IS the session boundary; clear_all_tables is not
	# Emptied before the delete callbacks below, so an index read from one of them agrees
	# with the mirror it indexes.
	_invalidate_indexes()
	# The loops below do NOT stop on a re-entrant wipe, unlike the dispatch in
	# _apply_batch: a nested clear_local_db() finds the containers already emptied
	# above, so this snapshot is the only record of the rows that were dropped.
	for entry: Array in pk_rows:
		_emit_clear_for_table(entry[0], entry[1])
	for entry: Array in pk_less_rows:
		_emit_clear_for_table(entry[0], entry[1])


## Rows a message in [member _undispatched] applied but has not reported yet, by instance
## id: an unreported insert maps to null, an unreported update's new row to the row it
## replaced — the one its consumers still know. Empty outside a dispatch.
func _unannounced_rows() -> Dictionary[int, Variant]:
	var unannounced: Dictionary[int, Variant] = { }
	for plan: _TablePlan in _undispatched:
		var inserts_sent: int = plan.inserts_sent if plan.inserts_sent >= 0 else _in_flight_sent
		var updates_sent: int = plan.updates_sent if plan.updates_sent >= 0 else _in_flight_sent
		for k: int in range(inserts_sent, plan.inserted.size()):
			unannounced[plan.inserted[k].get_instance_id()] = null
		for k: int in range(updates_sent * 2, plan.updated.size(), 2):
			unannounced[plan.updated[k + 1].get_instance_id()] = plan.updated[k]
	return unannounced


## [param rows] as a wipe reports them: each one in [param unannounced] swapped for the
## row its consumers know, or left out when they know none.
func _announced(rows: Array, unannounced: Dictionary[int, Variant]) -> Array:
	if unannounced.is_empty():
		return rows
	var known: Array = []
	for row: _ModuleTableType in rows:
		var id: int = row.get_instance_id()
		if not unannounced.has(id):
			known.append(row)
		elif unannounced[id] != null:
			known.append(unannounced[id])
	return known


## Emits delete + transactions-completed callbacks for every row in [param rows].
func _emit_clear_for_table(table_name_lower: StringName, rows: Array) -> void:
	if rows.is_empty():
		return
	var before_delete_listeners: Array = _listener_snapshot(
		_before_delete_listeners_by_table,
		table_name_lower,
	)
	var delete_listeners: Array = _listener_snapshot(_delete_listeners_by_table, table_name_lower)
	var tx_listeners: Array = _listener_snapshot(
		_transactions_completed_listeners_by_table,
		table_name_lower,
	)
	for row: _ModuleTableType in rows:
		if not _before_delete_sent.has(row.get_instance_id()):
			for listener: Callable in before_delete_listeners:
				if listener.is_valid():
					listener.call(row)
			row_before_delete.emit(table_name_lower, row)
		for listener: Callable in delete_listeners:
			if listener.is_valid():
				listener.call(row)
		row_deleted.emit(table_name_lower, row)
	for listener: Callable in tx_listeners:
		if listener.is_valid():
			listener.call()
	row_transactions_completed.emit(table_name_lower)


## Returns a single row by its primary key [param primary_key_value], or [code]null[/code].
func get_row_by_pk(table_name: StringName, primary_key_value: Variant) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if not _tables.has(key):
		return null
	return _tables[key].get(primary_key_value, null)


## Returns all rows in [param table_name] as a typed array.
func get_all_rows(table_name: StringName) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		var result: Array[_ModuleTableType] = []
		result.assign(_pk_less_tables[key])
		return result
	if not _tables.has(key):
		return []
	var pk_result: Array[_ModuleTableType] = []
	pk_result.assign(_tables[key].values())
	return pk_result


## Returns the number of rows in [param table_name].
func count_all_rows(table_name: StringName) -> int:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		return _pk_less_tables[key].size()
	if not _tables.has(key):
		return 0
	return _tables[key].size()


## Returns all rows in [param table_name] for which [param predicate] returns [code]true[/code].
func find_where(table_name: StringName, predicate: Callable) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	var result: Array[_ModuleTableType] = []
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if predicate.call(row):
				result.append(row)
	elif _tables.has(key):
		var t: Dictionary = _tables[key]
		for pk: Variant in t:
			var row: _ModuleTableType = t[pk]
			if predicate.call(row):
				result.append(row)
	return result


## Returns the first row matching [param predicate], or [code]null[/code].
func first_where(table_name: StringName, predicate: Callable) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if predicate.call(row):
				return row
	elif _tables.has(key):
		var t: Dictionary = _tables[key]
		for pk: Variant in t:
			var row: _ModuleTableType = t[pk]
			if predicate.call(row):
				return row
	return null


## Returns all rows where [param field] equals [param value].
func find_by(table_name: StringName, field: StringName, value: Variant) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	var result: Array[_ModuleTableType] = []
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if row.get(field) == value:
				result.append(row)
	elif _tables.has(key):
		var t: Dictionary = _tables[key]
		for pk: Variant in t:
			var row: _ModuleTableType = t[pk]
			if row.get(field) == value:
				result.append(row)
	return result


## Returns the first row where [param field] equals [param value], or [code]null[/code].
func first_by(table_name: StringName, field: StringName, value: Variant) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if row.get(field) == value:
				return row
	elif _tables.has(key):
		var t: Dictionary = _tables[key]
		for pk: Variant in t:
			var row: _ModuleTableType = t[pk]
			if row.get(field) == value:
				return row
	return null


## Returns the count of rows matching [param predicate].
func count_where(table_name: StringName, predicate: Callable) -> int:
	var key: StringName = _normalize(table_name)
	var c: int = 0
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if predicate.call(row):
				c += 1
	elif _tables.has(key):
		var t: Dictionary = _tables[key]
		for pk: Variant in t:
			var row: _ModuleTableType = t[pk]
			if predicate.call(row):
				c += 1
	return c


## Erases all rows from every table WITHOUT reporting them: no delete callback, no
## signal, no transactions-completed. Row listeners are left believing they still hold
## rows that are gone, so reach for [method clear_local_db] unless the caller is itself
## rebuilding every consumer's view.
##
## The generated index caches are the exception, and are emptied here: they answer
## [code]find()[/code] / [code]filter()[/code] / the range queries, so they are part of
## this database's own read path rather than a consumer of it, and nothing outside the SDK
## can rebuild them. Left standing they answer with rows [method get_all_rows] no longer
## yields.
func clear_all_tables() -> void:
	# Whether this call is the one that dropped the rows, read BEFORE the containers are
	# emptied. It is what ends a re-entrant wipe — see the invalidator loop below.
	var dropped_rows: bool = false
	for table_name: StringName in _tables:
		var inner: Dictionary = _tables[table_name]
		dropped_rows = dropped_rows or not inner.is_empty()
		inner.clear()
	for table_name: StringName in _pk_less_tables:
		var rows: Array = _pk_less_tables[table_name]
		dropped_rows = dropped_rows or not rows.is_empty()
		rows.clear()
	_ref_counts.clear()
	_pk_less_counts.clear()
	_query_rows.clear()
	# Same containers as clear_local_db, so the same hazard: this is public and can be
	# called from a row callback. Without this bump the rest of the batch stays cached with
	# an empty _ref_counts, i.e. rows no later delete can evict. See [member _generation].
	_generation += 1
	# The `dropped_rows` gate is load-bearing, not an optimisation: it is what makes a
	# re-entrant wipe terminate. clear_local_db()'s emit loops stop on their own because
	# what they report comes from containers the outer call already emptied; the
	# invalidator list is a registry no wipe empties, so an invalidator that calls back into
	# clear_all_tables() would re-fire every entry including itself without bound. An
	# already-emptied database has nothing left to invalidate, so the nested call returns.
	if dropped_rows:
		_invalidate_indexes()


## Empties every generated index cache. Fired after the containers, so an invalidator that
## reads this database sees an emptied one — and from a COPY, like every other dispatch
## loop in this class, since an invalidator may register or release another index. Dead
## entries are dropped first: calling an invalid Callable is a runtime error.
func _invalidate_indexes() -> void:
	for i: int in range(_index_invalidators.size() - 1, -1, -1):
		if not _index_invalidators[i].is_valid():
			_index_invalidators.remove_at(i)
	for invalidator: Callable in _index_invalidators.duplicate():
		if invalidator.is_valid():
			invalidator.call()
