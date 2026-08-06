# Regression test for how LocalDatabase compares a column whose value is an Option or a
# sum type (a RustEnum subclass).
#
# _values_equal / _value_hash descend into a nested record by reading its BSATN_TYPES
# const. Option and RustEnum carry their payload in named members and declare no such
# const, so the walk fell through to `a == b` / hash(v) — Object identity — and every
# delivery builds a fresh instance. Consequences, both measured before the fix:
#
#   - PK-less table: two deliveries of one value cached TWO rows, and a delete (also a
#     fresh instance) hashed into a bucket holding nothing, so it was skipped and the row
#     stayed in the mirror for the rest of the session. Silent, permanent divergence.
#   - PK table: an unchanged re-delivery — what overlapping queries produce — reported
#     row_updated with a `prev` that equalled `next`.
#
# The int and nested-record cases are controls: they were correct before and pin that the
# fix did not change them. The discriminating cases pin the other direction — a fix that
# made unequal wrapper values compare equal would collapse distinct rows into one, which
# is worse than the bug.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_option_column_equality.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	f += _case_pkless("int column (control)", _mk_int_row)
	f += _case_pkless("nested record column (control)", _mk_nested_row)
	f += _case_pkless("Option column", _mk_option_row)
	f += _case_pkless("RustEnum column", _mk_enum_row)
	f += _case_pkless("ScheduleAt column", _mk_schedule_row)

	f += _case_pk("int column (control)", _mk_int_keyed)
	f += _case_pk("nested record column (control)", _mk_nested_keyed)
	f += _case_pk("Option column", _mk_option_keyed)
	f += _case_pk("RustEnum column", _mk_enum_keyed)
	f += _case_pk("ScheduleAt column", _mk_schedule_keyed)

	f += _test_distinct_values_stay_distinct()
	f += _test_a_real_change_still_reports()
	return f


# PK-less: two deliveries of the same VALUE must refcount to one cached row, and a delete
# built from the wire (a fresh instance) must find and release it.
func _case_pkless(label: String, mk: Callable) -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	var deletes: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		&"flat",
		func(_r: _ModuleTableType) -> void:
			deletes[0] += 1,
	)

	_apply(db, &"flat", [mk.call()], [])
	_apply(db, &"flat", [mk.call()], [])
	f += _check_i(
		"pkless/%s: one cached row after two equal deliveries" % label,
		db.get_all_rows(&"flat").size(),
		1,
	)

	_apply(db, &"flat", [], [mk.call()])
	f += _check_i(
		"pkless/%s: still cached after one of two holders left" % label,
		db.get_all_rows(&"flat").size(),
		1,
	)
	f += _check_i("pkless/%s: no delete reported yet" % label, deletes[0], 0)

	_apply(db, &"flat", [], [mk.call()])
	f += _check_i(
		"pkless/%s: gone after the last holder left" % label,
		db.get_all_rows(&"flat").size(),
		0,
	)
	f += _check_i("pkless/%s: delete reported once" % label, deletes[0], 1)

	db.free()
	return f


# PK: re-delivering the same pk with an unchanged value must not report an update.
func _case_pk(label: String, mk: Callable) -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	var updates: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_updates(
		&"keyed",
		func(_prev: _ModuleTableType, _next: _ModuleTableType) -> void:
			updates[0] += 1,
	)

	_apply(db, &"keyed", [mk.call()], [])
	_apply(db, &"keyed", [mk.call()], []) # overlapping query re-delivery, same value
	f += _check_i("pk/%s: unchanged re-delivery reports no update" % label, updates[0], 0)

	# The server's shape for a real update: delete + insert of the same pk in one batch.
	_apply(db, &"keyed", [mk.call()], [mk.call()])
	f += _check_i("pk/%s: unchanged delete+insert reports no update" % label, updates[0], 0)

	db.free()
	return f


# The other direction: wrapper values that differ must not be merged. Each pair goes into
# one PK-less table, which caches one row per distinct value.
func _test_distinct_values_stay_distinct() -> int:
	var f: int = 0
	f += _check_distinct("Some(5) vs Some(6)", Option.some(5), Option.some(6))
	f += _check_distinct("Some(5) vs None", Option.some(5), Option.none())
	f += _check_distinct("Some(5) vs Some('5')", Option.some(5), Option.some("5"))
	f += _check_distinct("enum tags differ", _enum(1, 42), _enum(2, 42))
	f += _check_distinct("enum payloads differ", _enum(1, 42), _enum(1, 43))
	f += _check_distinct("Option vs RustEnum", Option.some(42), _enum(1, 42))
	# Same micros, different variant: a comparison that read only the payload would
	# merge a repeating interval into an absolute time.
	f += _check_distinct("schedule kinds differ", ScheduleAt.interval(5), ScheduleAt.at_time(5))
	f += _check_distinct("schedule micros differ", ScheduleAt.interval(5), ScheduleAt.interval(6))
	f += _check_distinct("ScheduleAt vs RustEnum", ScheduleAt.interval(0), _enum(0, null))
	return f


func _check_distinct(label: String, a: Resource, b: Resource) -> int:
	var db: LocalDatabase = _mk_db()
	_apply(db, &"flat", [_FlatRow.new(0, a), _FlatRow.new(0, b)], [])
	var got: int = db.get_all_rows(&"flat").size()
	db.free()
	return _check_i("distinct/%s: cached as two rows" % label, got, 2)


# A column that really changed must still report, with the old value as `prev`.
func _test_a_real_change_still_reports() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	var seen: Array = [] # gdlint: ignore[S6]
	db.subscribe_to_updates(
		&"keyed",
		func(prev: _ModuleTableType, next: _ModuleTableType) -> void:
			seen.append([prev.get(&"extra"), next.get(&"extra")]),
	)

	_apply(db, &"keyed", [_KeyedRow.new(1, 0, Option.some(5))], [])
	_apply(
		db,
		&"keyed",
		[_KeyedRow.new(1, 0, Option.some(6))],
		[_KeyedRow.new(1, 0, Option.some(5))],
	)
	f += _check_i("changed Option reports one update", seen.size(), 1)
	if seen.size() == 1:
		f += _check_i("update carried the old value as prev", (seen[0][0] as Option).unwrap(), 5)
		f += _check_i("update carried the new value as next", (seen[0][1] as Option).unwrap(), 6)
	db.free()
	return f


func _enum(tag: int, payload: Variant) -> RustEnum:
	var e: RustEnum = RustEnum.new()
	e.value = tag
	e.data = payload
	return e


func _mk_int_row() -> _FlatRow:
	return _FlatRow.new(7, null)


func _mk_nested_row() -> _FlatRow:
	return _FlatRow.new(0, _Nested.new(3, 4))


func _mk_option_row() -> _FlatRow:
	return _FlatRow.new(0, Option.some(5))


func _mk_enum_row() -> _FlatRow:
	return _FlatRow.new(0, _enum(1, 42))


func _mk_schedule_row() -> _FlatRow:
	return _FlatRow.new(0, ScheduleAt.interval(1_000_000))


func _mk_int_keyed() -> _KeyedRow:
	return _KeyedRow.new(1, 7, null)


func _mk_nested_keyed() -> _KeyedRow:
	return _KeyedRow.new(1, 0, _Nested.new(3, 4))


func _mk_option_keyed() -> _KeyedRow:
	return _KeyedRow.new(1, 0, Option.some(5))


func _mk_enum_keyed() -> _KeyedRow:
	return _KeyedRow.new(1, 0, _enum(1, 42))


func _mk_schedule_keyed() -> _KeyedRow:
	return _KeyedRow.new(1, 0, ScheduleAt.interval(1_000_000))


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"flat", &"keyed"]
	schema.types[&"flat"] = _FlatRow
	schema.tables[&"flat"] = _FlatRow
	schema.types[&"keyed"] = _KeyedRow
	schema.tables[&"keyed"] = _KeyedRow
	return LocalDatabase.new(schema)


func _apply(db: LocalDatabase, table_name: StringName, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	db.apply_table_update(u)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


# A nested generated record: carries BSATN_TYPES, so the value walk descends into it.
class _Nested:
	extends Resource
	const BSATN_TYPES: Dictionary = { &"x": &"i32", &"y": &"i32" }
	@export var x: int = 0
	@export var y: int = 0


	func _init(p_x: int = 0, p_y: int = 0) -> void:
		x = p_x
		y = p_y


class _FlatRow:
	extends _ModuleTableType
	@export var value: int = 0
	@export var extra: Variant = null


	func _init(p_value: int = 0, p_extra: Variant = null) -> void:
		value = p_value
		extra = p_extra


class _KeyedRow:
	extends _ModuleTableType
	@export var id: int = 0
	@export var value: int = 0
	@export var extra: Variant = null


	func _init(p_id: int = 0, p_value: int = 0, p_extra: Variant = null) -> void:
		id = p_id
		value = p_value
		extra = p_extra
