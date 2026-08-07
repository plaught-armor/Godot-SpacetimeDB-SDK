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
## [method Script.get_script_constant_map] allocates a fresh Dictionary and `.keys()`
## a fresh Array on every call, and [method _values_equal] needs that list once per
## nested column per row compared — uncached, it dominated nested-row change
## detection. Keyed by [Script] (process-lived, bounded by the generated record
## count). Entries are read-only so a caller cannot mutate the shared list (C2a).
## Reached only from the main-thread [method apply_table_update] path — NOT
## synchronized. Moving row equality or row hashing onto the deserializer worker
## needs either a mutex here or a per-thread cache.
static var _record_columns_cache: Dictionary[Script, Array] = { }
## Shared read-only empty column list for objects that are not generated records.
static var _EMPTY_COLUMNS: Array = []
## Component count per column type that can hold a NaN — every entry of
## [constant BSATNDeserializer.NATIVE_ARRAYLIKE] built from floats (the i-suffixed
## vectors hold ints and are absent). Components read as floats through `v[i]`.
## Used by [method _nan_equal]; a type absent here carries no float to compare.
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
## TableUpdate per query, with no dedupe across the set), so overlapping queries in one
## subscribe each contribute a reference. The count is exactly the number of references
## this query contributed to _ref_counts, so a prune can hand every one of them back. On
## the PK side a single reference is stored as the bare row and only a repeat widens the
## entry to a pair, which keeps the common subscribe path allocation-free.
## Records which rows each subscription contributes so a SubscriptionError on an already-
## applied query can be pruned precisely (decrement those rows' refcounts, evict any that
## no other query holds) — the server sends no dropped rows on an error, unlike unsubscribe.
var _query_rows: Dictionary[int, Dictionary] = { }

## Emitted after a row is inserted into a table.
signal row_inserted(table_name: StringName, row: _ModuleTableType)
## Emitted after a row is updated (PK match found in inserts + existing data).
signal row_updated(table_name: StringName, old_row: _ModuleTableType, new_row: _ModuleTableType)
## Emitted just before a row is removed from the cache (row still queryable).
signal row_before_delete(table_name: StringName, row: _ModuleTableType)
## Emitted after a row is deleted from a table.
signal row_deleted(table_name: StringName, row: _ModuleTableType)
## Emitted once after all inserts/deletes in a single [TableUpdateData] are processed.
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
## subscriber (its node, or any object holding a subscribed [Callable]) leaves that
## object's Callable in this already-taken copy. Calling it is a GDScript runtime
## error, which unwinds the whole apply — measured: freeing a second receiver from
## an insert handler applied 1 of a 3-row batch, dropped the rest of the transaction
## from the mirror and fired no transactions_completed, and the server never resends.
## Skipping a dead listener instead matches how the engine treats a signal whose
## receiver was freed. The guard covers a method Callable ([code]obj.method[/code]),
## which is what every subscriber in this SDK registers; a LAMBDA that captured a
## node stays valid after that node is freed, so a lambda subscriber still has to
## check its own captures. [method Object.queue_free] was never affected (the free lands
## after the batch), and a callback that frees its OWN object is refused by the
## engine ("Object is locked and can't be freed").
func _listener_snapshot(by_table: Dictionary, key: StringName) -> Array:
	var live: Array = by_table.get(key, _EMPTY_LISTENERS)
	return live.duplicate() if not live.is_empty() else _EMPTY_LISTENERS


# --- Normalization helper (#2) ---
# Single shared cache for both apply_table_update and access methods
func _normalize(table_name: StringName) -> StringName:
	if _cached_normalized_table_names.has(table_name):
		return _cached_normalized_table_names[table_name]
	var normalized: StringName = table_name.to_lower()
	_cached_normalized_table_names[table_name] = normalized
	return normalized


# Adds [param callable] to a table's listener array, dropping any listener whose object
# has since been freed. A subscriber that goes away without calling the matching
# unsubscribe leaves its Callable in the array for good: the dispatch loops skip an
# invalid one, so it is not a correctness problem, but nothing ever removed it and a
# pool that subscribes raw callbacks per instance grew the array without bound. Pruning
# here rather than per update keeps the cost on the cold path — the next subscriber on
# that table clears the previous generation's dead entries.
func _add_listener(by_table: Dictionary, key: StringName, callable: Callable) -> void:
	if not by_table.has(key):
		by_table[key] = []
	var listeners: Array = by_table[key]
	for i: int in range(listeners.size() - 1, -1, -1):
		if not (listeners[i] as Callable).is_valid():
			listeners.remove_at(i)
	if not listeners.has(callable):
		listeners.append(callable)


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
## [param table_name]. Fires before the row leaves the cache, so the callback can
## still read it (and related rows) at their pre-delete state.
##
## Pairing with [method subscribe_to_deletes] is per row, not per batch: on a PK table a
## row's before-delete is immediately followed by its delete, while on a PK-less table a
## batch reports every before-delete first and then every delete. Each row still gets
## exactly one of each, in the order the batch evicted them.
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
	# not. There used to be a fallback here that took a storage property named `id` or
	# `identity` as the key when the const was absent — but the const is absent precisely
	# because the table HAS no primary key, and such a table's `id` column carries no
	# uniqueness promise. Two rows sharing one (a log or junction table keyed by an entity,
	# `identity` appearing once per row rather than once per player) collapsed into a
	# single cached entry, so the mirror silently showed one row where the server held
	# several. A table with no primary key is refcounted by row value instead.
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
# both callers below need it on every update, so the old per-call printerr repeated for
# the life of the connection, and neither said what goes wrong when it is absent.
#
# What goes wrong is not a degraded lookup but a wrong answer. Without the script there is
# no column list, so _rows_equal reports every row equal and _row_hash sends them all to
# one bucket: a table with no primary key collapses into a single cached entry and its
# deletes release the wrong row. Nothing is cached here, so a script registered later
# still resolves.
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
		cols = (bt as Dictionary).keys()
		cols.make_read_only()
	_record_columns_cache[script] = cols
	return cols


# Value-equality that descends into nested Resource columns (product/sum-type
# wrappers) and Arrays. Variant `==` compares two Objects by identity, and every
# row/nested record is a fresh `.new()` per delivery (no interning), so an identity
# compare reports two structurally-equal rows unequal — firing spurious row_updated
# on the PK path and missing dedup on the PK-less path. Columns come from the
# record's BSATN_TYPES; primitives / Packed*Array short-circuit on the final
# `a == b`. That short-circuit is not free: value equality costs ~1.6x an identity
# compare on an all-primitive row and ~2.9x on a nested one (tests/bench_rows_equal.gd).
# It is the price of not firing spurious row_updated, not a no-op — which is why
# [method _rows_equal] compares primitive columns inline and only calls this for
# the Object / Array columns that actually need the walk.
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
		# No BSATN_TYPES. The SDK's own wrapper types carry their payload in named
		# members instead, so each needs its own descent — without it an Option, a
		# sum-type or a scheduled_at column compares by identity, and every delivery
		# builds a fresh instance, so two structurally equal rows never match. These
		# three are every wrapper the deserializer can put in a column (option.gd,
		# rust_enum.gd — the base of every generated sum type — and schedule_at.gd);
		# a fourth would have to be added here and to [method _value_hash] together.
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
	return _nan_equal(a, b, ta)


# Two values Variant `==` calls different are still the same row value when the only
# difference is NaN. `NAN == NAN` is false in GDScript, while `hash(NAN)` is a single
# value — Godot's hash_djb2_one_float normalizes NaN (and -0.0) before hashing — and
# [method _value_hash] is built on that hash. Without this the two disagree: a PK-less
# row carrying NaN is found by hash and then never matched, so every delivery cached
# another copy and every delete was dropped (the row could never leave the mirror), and
# a PK row carrying NaN was reported as an update on every unchanged re-delivery.
#
# It also follows the server, which holds ONE such row: sats types a float column as
# `decorum::Total<f32>` (crates/sats/src/algebraic_value.rs), a total order in which NaN
# equals itself.
#
# Reached only from the values-differ path of [method _values_equal] /
# [method _rows_equal], so an equal row that carries no NaN pays nothing for it. An equal
# row that DOES carry one walks this, because a NaN makes even `Vector2 == Vector2` false.
static func _nan_equal(a: Variant, b: Variant, t: int) -> bool:
	if t == TYPE_FLOAT:
		return is_nan(a) and is_nan(b)
	var components: int = _NAN_CARRYING_COMPONENTS.get(t, 0)
	if components == 0:
		return false
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


func _rows_equal(a: _ModuleTableType, b: _ModuleTableType, props: Array[StringName]) -> bool:
	for prop_name: StringName in props:
		# Primitive columns (the majority of every row) compare inline — the
		# per-field [method _values_equal] call is itself the dominant cost of an
		# all-primitive row. Only Object/Array columns need the recursive walk.
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
			# materializes both operands' results per column even when the first
			# short-circuits, and this runs once per column of every compared row
			# (measured +17% on an all-primitive row, tests/bench_rows_equal.gd).
			if not _nan_equal(av, bv, ta):
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
		if _rows_equal(entry[0], row, props):
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


## Reports ONCE per table that a delete arrived for a row value the mirror does not
## hold. Silent before: the delete was dropped, the row it was meant to remove stayed
## cached for the rest of the session, and nothing said so — the shape both the NaN
## column bug and a local write into a handed-out row produce (see the class note).
## Once per table because the same mutated row is re-delivered by every later
## subscription, and the second line adds nothing to the first.
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


## Points this query's existing reference at a newer row without taking another one.
func _qmem_refresh(qmem: Dictionary, pk: Variant, row: _ModuleTableType) -> void:
	var entry: Variant = qmem.get(pk)
	if entry is Array:
		entry[0] = row
	elif entry != null:
		qmem[pk] = row


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
## reconstructed from locally-tracked per-query membership.
func prune_query(query_id: int) -> void:
	if not _query_rows.has(query_id):
		return
	var tables: Dictionary = _query_rows[query_id]
	# Direct key iteration (no .keys() alloc). apply_table_update below mutates the inner
	# membership containers but never adds/removes a table key here, so this is safe.
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
			apply_table_update(drop, query_id)
	_query_rows.erase(query_id)


## Drops the per-query membership index for [param query_id] without touching the cache
## (the rows were already removed via the normal delete path, e.g. an unsubscribe whose
## dropped rows the server echoed). Prevents the index from growing unbounded.
func forget_query(query_id: int) -> void:
	_query_rows.erase(query_id)


## Applies all table updates from a [SubscribeAppliedMessage] to the local store.
func apply_database_subscription_applied(db_update: SubscribeAppliedMessage) -> void:
	if not db_update:
		return
	for table_update: TableUpdateData in db_update.tables:
		apply_table_update(table_update, db_update.query_set_id.id)


## Applies all table updates from a [DatabaseUpdateData] to the local store.
func apply_database_update(db_update: DatabaseUpdateData) -> void:
	if not db_update:
		return
	for table_update: TableUpdateData in db_update.tables:
		apply_table_update(table_update, db_update.query_id.id)


## Applies a single [TableUpdateData] — processes inserts then deletes, dispatches
## listener callbacks and signals, and handles both PK-keyed and PK-less tables.
## [param query_id] (>= 0) records which subscription contributed each row, so a
## [method prune_query] can later drop exactly that query's rows on a SubscriptionError.
func apply_table_update(table_update: TableUpdateData, query_id: int = -1) -> void:
	var table_name_lower: StringName = _normalize(table_update.table_name)

	if not _tables.has(table_name_lower):
		printerr(
			"LocalDatabase: Received update for unknown table '",
			table_update.table_name,
			"' (normalized: '",
			table_name_lower,
			"')",
		)
		return

	var pk_field: StringName = _get_primary_key_field(table_name_lower)

	# Hoist listener array lookups once per table_update, not per row. Snapshot
	# guards against a listener unsubscribing mid-dispatch; the no-listener case
	# allocs nothing (shared read-only empty).
	var insert_listeners: Array = _listener_snapshot(_insert_listeners_by_table, table_name_lower)
	var update_listeners: Array = _listener_snapshot(_update_listeners_by_table, table_name_lower)
	var before_delete_listeners: Array = _listener_snapshot(
		_before_delete_listeners_by_table,
		table_name_lower,
	)
	var delete_listeners: Array = _listener_snapshot(_delete_listeners_by_table, table_name_lower)
	var tx_listeners: Array = _listener_snapshot(
		_transactions_completed_listeners_by_table,
		table_name_lower,
	)
	var has_insert_listeners: bool = not insert_listeners.is_empty()
	var has_update_listeners: bool = not update_listeners.is_empty()
	var has_before_delete_listeners: bool = not before_delete_listeners.is_empty()
	var has_delete_listeners: bool = not delete_listeners.is_empty()

	# Event tables carry ephemeral rows: fire on_insert, never store. count()/iter()
	# stay empty and there is no update/delete/refcount tracking. The server only
	# sends these as EventTable row lists, which the deserializer flattens into
	# inserts with is_event set.
	if table_update.is_event:
		var fired_event: bool = false
		for event_row: _ModuleTableType in table_update.inserts:
			fired_event = true
			if has_insert_listeners:
				for listener: Callable in insert_listeners:
					if listener.is_valid():
						listener.call(event_row)
			row_inserted.emit(table_name_lower, event_row)
		if fired_event:
			for listener: Callable in tx_listeners:
				if listener.is_valid():
					listener.call()
			row_transactions_completed.emit(table_name_lower)
		return

	var table_dict: Dictionary = _tables[table_name_lower]
	var had_any_change: bool = false

	if pk_field.is_empty():
		# PK-less table: refcounted by row value (rows have no key). A distinct value held
		# by N overlapping subscriptions has count N; on_insert fires only on 0->1 and
		# on_delete only on 1->0, so a shared row survives one subscription's unsubscribe.
		# _pk_less_tables holds each present row once (for iteration/queries); _pk_less_counts
		# holds the multiplicity, keyed by row hash with an _rows_equal tiebreak.
		if not _pk_less_tables.has(table_name_lower):
			_pk_less_tables[table_name_lower] = []
		if not _pk_less_counts.has(table_name_lower):
			_pk_less_counts[table_name_lower] = { }
		var rows_array: Array = _pk_less_tables[table_name_lower]
		var counts: Dictionary = _pk_less_counts[table_name_lower]
		var props: Array[StringName] = _get_row_properties(table_name_lower)
		# Per-query membership for pk-less is itself a hash-bucket count map (same shape as
		# _pk_less_counts), hoisted out of the row loops. O(bucket) add/remove instead of an
		# O(n) array scan per delete.
		var track_pkless_query: bool = query_id >= 0
		var pkless_qmem: Dictionary = _query_table_pkless_mem(query_id, table_name_lower) if track_pkless_query else { }

		for inserted_row: _ModuleTableType in table_update.inserts:
			var ins_hash: int = _row_hash(inserted_row, props)
			var ins_entry: Array = _pk_less_find(counts, ins_hash, inserted_row, props)
			if ins_entry.is_empty():
				# Globally new value (0->1). It's therefore also new to this query's
				# membership, so add directly — no membership find needed.
				_pk_less_add(counts, ins_hash, inserted_row)
				rows_array.append(inserted_row)
				had_any_change = true
				if has_insert_listeners:
					for listener: Callable in insert_listeners:
						if listener.is_valid():
							listener.call(inserted_row)
				row_inserted.emit(table_name_lower, inserted_row)
				if track_pkless_query:
					_pk_less_add(pkless_qmem, ins_hash, inserted_row)
			else:
				ins_entry[1] += 1 # already present (overlap / multiplicity) — bump silently
				# Already present globally; this query may or may not hold it yet (overlap).
				if track_pkless_query:
					var mem_ins: Array = _pk_less_find(pkless_qmem, ins_hash, inserted_row, props)
					if mem_ins.is_empty():
						_pk_less_add(pkless_qmem, ins_hash, inserted_row)
					else:
						mem_ins[1] += 1

		if not table_update.deletes.is_empty():
			# instance_id -> the cached row, for a single-pass array compact and for the
			# delete callbacks that follow it. The two delete callbacks split on whether the
			# row is still in the cache, so on_before_delete fires here (row still listed)
			# and on_delete only after the compaction below — matching the PK path, which
			# erases from the table dict between the two. Firing both from this loop left
			# on_delete able to find the row in iter(), so a listener that rebuilt its view
			# from the cache kept showing what it was just told had been deleted.
			#
			# One difference from the PK path remains, and it follows from the compaction
			# being a single pass over the array: a batch evicting several rows reports
			# every before_delete first, then every delete, where the PK path interleaves
			# them per row. Both orders keep each row's own pair in order and keep the
			# cache state each callback promises; only the cross-row interleaving differs.
			var evicted: Dictionary[int, _ModuleTableType] = { }
			for deleted_row: _ModuleTableType in table_update.deletes:
				var del_hash: int = _row_hash(deleted_row, props)
				var del_entry: Array = _pk_less_find(counts, del_hash, deleted_row, props)
				if del_entry.is_empty() or del_entry[1] <= 0:
					_warn_unmatched_delete(table_name_lower)
					continue
				del_entry[1] -= 1
				if track_pkless_query:
					var mem_del: Array = _pk_less_find(pkless_qmem, del_hash, deleted_row, props)
					if not mem_del.is_empty():
						mem_del[1] -= 1
						if mem_del[1] == 0:
							_pk_less_remove(pkless_qmem, del_hash, mem_del)
				if del_entry[1] == 0:
					var cached_row: _ModuleTableType = del_entry[0]
					_pk_less_remove(counts, del_hash, del_entry)
					evicted[cached_row.get_instance_id()] = cached_row
					had_any_change = true
					if has_before_delete_listeners:
						for listener: Callable in before_delete_listeners:
							if listener.is_valid():
								listener.call(cached_row)
					row_before_delete.emit(table_name_lower, cached_row)
			if not evicted.is_empty():
				# Single pass compact — the stored row is the same instance appended on 0->1.
				var write_idx: int = 0
				for read_idx: int in rows_array.size():
					var row: _ModuleTableType = rows_array[read_idx]
					if evicted.has(row.get_instance_id()):
						continue
					rows_array[write_idx] = row
					write_idx += 1
				rows_array.resize(write_idx)
				# Now the rows are actually gone. Reported in the order the batch evicted
				# them (dict iteration is insertion-order), so a consumer sees the same
				# sequence it saw from on_before_delete.
				for gone_id: int in evicted:
					var gone: _ModuleTableType = evicted[gone_id]
					if has_delete_listeners:
						for listener: Callable in delete_listeners:
							if listener.is_valid():
								listener.call(gone)
					row_deleted.emit(table_name_lower, gone)

		if had_any_change:
			for listener: Callable in tx_listeners:
				if listener.is_valid():
					listener.call()
			row_transactions_completed.emit(table_name_lower)
		return

	# PK table: refcounted single pass. One pk may appear several times in each list —
	# every query of a set that matches the row contributes its own copy — so the
	# insert/delete pairing below counts rather than flags. on_insert fires on
	# refcount 0->1, on_delete on 1->0; a delete+insert of the same pk in one update is
	# an update (net refcount 0, value may change). A row delivered by N overlapping
	# query sets has refcount N; an identical re-delivery bumps it silently. When
	# query_id >= 0, membership records this query's pks for precise SubscriptionError
	# pruning (dict lookup hoisted out of the row loops).
	if not _ref_counts.has(table_name_lower):
		_ref_counts[table_name_lower] = { }
	var ref_table: Dictionary = _ref_counts[table_name_lower]
	var props: Array[StringName] = _get_row_properties(table_name_lower)
	var track_query: bool = query_id >= 0
	var qmem: Dictionary = _query_table_pk_mem(query_id, table_name_lower) if track_query else { }

	# Update detection (delete+insert of the same pk) only matters when this update has
	# BOTH inserts and deletes. Pure inserts (subscribe) and pure deletes (rows leaving)
	# skip the pk-count build entirely. Null PKs are warned in the delete pass below,
	# which a batch whose every delete pairs with an insert skips — so such a row is
	# dropped silently, the same as it always was.
	var detect_updates: bool = (
		not table_update.inserts.is_empty() and not table_update.deletes.is_empty()
	)
	# pk -> deletes not yet paired with an insert, plus the running total of those. A row
	# held by N overlapping queries of one set is reported N times in a single update (the
	# server groups every fragment's rows under one TableUpdate, flattened into these two
	# lists above), so a COUNT is what pairs them: min(inserts, deletes) of a pk are one
	# update delivered N times, and only the surplus is a new reference or a real delete.
	# A set here consumed one delete and dropped the rest, which both inflated the refcount
	# and skipped the delete pass — a row that outlived its own deletion.
	var deleted_pks: Dictionary = { }
	var unpaired_deletes: int = 0
	if detect_updates:
		for deleted_row: _ModuleTableType in table_update.deletes:
			var del_pk: Variant = deleted_row.get(pk_field)
			if del_pk != null:
				deleted_pks[del_pk] = deleted_pks.get(del_pk, 0) + 1
				unpaired_deletes += 1

	for inserted_row: _ModuleTableType in table_update.inserts:
		var pk_value: Variant = inserted_row.get(pk_field)
		if pk_value == null:
			push_error(
				"LocalDatabase: Inserted row for table '%s' has null PK '%s'. Skipping."
				% [table_name_lower, pk_field]
			)
			continue
		var old_ref: int = ref_table.get(pk_value, 0)
		var pending_deletes: int = deleted_pks.get(pk_value, 0) if detect_updates else 0
		if pending_deletes > 0:
			# Update: delete+insert of the same pk. Refcount unchanged; consume one delete
			# so the delete pass skips exactly this pairing. Fire on_update only when the
			# value differs.
			deleted_pks[pk_value] = pending_deletes - 1
			unpaired_deletes -= 1
			if old_ref == 0:
				# Nothing held this pk yet, so "unchanged" would leave the row cached at
				# refcount 0: the matching delete is consumed here, so the delete pass
				# never records this delivery's reference. An unreferenced cached row is
				# permanent — a later delete reads refcount 0 and skips it, so the row
				# never leaves the cache and no on_delete ever fires. Record ONE reference,
				# whatever the pair count: this only happens on a desync (a delete for a pk
				# the mirror never held), and under-counting self-heals — the first later
				# delete evicts the row — while over-counting is the ghost above.
				ref_table[pk_value] = 1
				if track_query:
					qmem[pk_value] = inserted_row
			elif track_query:
				# Refcount unchanged — this delivery is an update, not a new reference, so
				# this query's membership only points at a newer row. Recording a reference
				# here would let a later prune hand back one this query never took.
				_qmem_refresh(qmem, pk_value, inserted_row)
			var prev_u: _ModuleTableType = table_dict.get(pk_value)
			if prev_u == null:
				# No prior cached row → this is an insert, not an update. Firing the
				# update path here would hand listeners a null `prev` (the index
				# listeners dereference it and crash). Refcount stays as the branch
				# intends (the matching delete pass is skipped via deleted_pks).
				table_dict[pk_value] = inserted_row
				had_any_change = true
				if has_insert_listeners:
					for listener: Callable in insert_listeners:
						if listener.is_valid():
							listener.call(inserted_row)
				row_inserted.emit(table_name_lower, inserted_row)
			elif props.is_empty() or not _rows_equal(prev_u, inserted_row, props):
				table_dict[pk_value] = inserted_row
				had_any_change = true
				if has_update_listeners:
					for listener: Callable in update_listeners:
						if listener.is_valid():
							listener.call(prev_u, inserted_row)
				row_updated.emit(table_name_lower, prev_u, inserted_row)
		elif old_ref == 0:
			ref_table[pk_value] = 1
			if track_query:
				qmem[pk_value] = inserted_row
			table_dict[pk_value] = inserted_row
			had_any_change = true
			if has_insert_listeners:
				for listener: Callable in insert_listeners:
					if listener.is_valid():
						listener.call(inserted_row)
			row_inserted.emit(table_name_lower, inserted_row)
		else:
			# Overlapping re-delivery: bump refcount; on_update only if the value differs.
			ref_table[pk_value] = old_ref + 1
			if track_query:
				# Already held — by this query (overlapping queries in one subscribe) or by
				# another. Only the first case widens the entry to a counted pair.
				_qmem_add_repeat(qmem, pk_value, inserted_row)
			var prev_o: _ModuleTableType = table_dict.get(pk_value)
			if prev_o == null:
				# Refcount bumped above but no cached row (desync / first sight under
				# an existing ref) → insert semantics, not update. Avoids a null `prev`
				# reaching listeners (the index listeners would crash on it).
				table_dict[pk_value] = inserted_row
				had_any_change = true
				if has_insert_listeners:
					for listener: Callable in insert_listeners:
						if listener.is_valid():
							listener.call(inserted_row)
				row_inserted.emit(table_name_lower, inserted_row)
			elif props.is_empty() or not _rows_equal(prev_o, inserted_row, props):
				table_dict[pk_value] = inserted_row
				had_any_change = true
				if has_update_listeners:
					for listener: Callable in update_listeners:
						if listener.is_valid():
							listener.call(prev_o, inserted_row)
				row_updated.emit(table_name_lower, prev_o, inserted_row)

	# Delete pass: skip entirely when there are no deletes, or (when detecting updates)
	# when every delete was consumed as an update above.
	if not table_update.deletes.is_empty() and not (detect_updates and unpaired_deletes == 0):
		for deleted_row2: _ModuleTableType in table_update.deletes:
			var pk_value: Variant = deleted_row2.get(pk_field)
			if pk_value == null:
				push_warning(
					"LocalDatabase: Deleted row for table '%s' has null PK '%s'. Skipping."
					% [table_name_lower, pk_field]
				)
				continue
			if detect_updates:
				var unpaired: int = deleted_pks.get(pk_value, 0)
				if unpaired <= 0:
					continue # consumed as an update above
				deleted_pks[pk_value] = unpaired - 1
			var old_ref: int = ref_table.get(pk_value, 0)
			if old_ref <= 0:
				continue
			if track_query:
				# One delete releases ONE reference, matching the single decrement below.
				# Dropping the whole entry here would leave a doubly-referenced pk with a
				# live refcount and no membership, so a later prune of this same query
				# would hand back nothing and strand the row.
				_qmem_release(qmem, pk_value)
			if old_ref > 1:
				ref_table[pk_value] = old_ref - 1
				continue
			ref_table.erase(pk_value)
			var cached_row: _ModuleTableType = table_dict.get(pk_value)
			if cached_row != null:
				had_any_change = true
				if has_before_delete_listeners:
					for listener: Callable in before_delete_listeners:
						if listener.is_valid():
							listener.call(cached_row)
				row_before_delete.emit(table_name_lower, cached_row)
				table_dict.erase(pk_value)
				if has_delete_listeners:
					for listener: Callable in delete_listeners:
						if listener.is_valid():
							listener.call(cached_row)
				row_deleted.emit(table_name_lower, cached_row)

	if had_any_change:
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
	# Snapshot the rows, then clear the INNER containers (keeping the outer table keys
	# that _init pre-populates and apply_table_update's known-table guard relies on —
	# reassigning the outer dicts to {} would drop those keys and every later PK-table
	# update would be rejected as "unknown table"), THEN run the delete callbacks. So a
	# listener that re-enters apply_table_update lands in the freshly-cleared maps
	# instead of rows we're about to wipe (M4). The snapshot loops invoke no listeners,
	# so they can't mutate the dicts mid-iteration.
	var pk_rows: Array = [] # of [table_name, rows]
	for table_name_lower: StringName in _tables:
		var inner: Dictionary = _tables[table_name_lower]
		pk_rows.append([table_name_lower, inner.values()])
		inner.clear()
	var pk_less_rows: Array = [] # of [table_name, rows]
	for table_name_lower: StringName in _pk_less_tables:
		var arr: Array = _pk_less_tables[table_name_lower]
		pk_less_rows.append([table_name_lower, arr.duplicate()])
		arr.clear()
	_ref_counts.clear()
	_pk_less_counts.clear()
	_query_rows.clear()
	for entry: Array in pk_rows:
		_emit_clear_for_table(entry[0], entry[1])
	for entry: Array in pk_less_rows:
		_emit_clear_for_table(entry[0], entry[1])


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
func clear_all_tables() -> void:
	for table_name: StringName in _tables:
		_tables[table_name].clear()
	for table_name: StringName in _pk_less_tables:
		_pk_less_tables[table_name].clear()
	_ref_counts.clear()
	_pk_less_counts.clear()
	_query_rows.clear()
