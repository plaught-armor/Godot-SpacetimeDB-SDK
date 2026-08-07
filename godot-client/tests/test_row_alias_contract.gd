# Pins the ownership contract for rows the mirror hands out, and the diagnostic that
# fires when a local write breaks it.
#
# LocalDatabase's accessors and listener callbacks return the row instances the mirror
# stores — rows are Resources, so writing to one writes into the mirror. On a table with
# no primary key rows are matched by VALUE, so a mutated row stops matching the row the
# server later deletes: the delete is dropped, no on_delete fires, and the row is stuck
# in the mirror for the session. That used to be completely silent; it now reports once
# per table (_unmatched_delete_warned), which is what the tests below read, since
# push_warning has no in-process capture.
#
# The cases here are the contract, not a wish list: the identity of the handed-out row,
# the consequence of writing to it, the copy-first pattern the docs prescribe, and the
# negative control that ordinary traffic never trips the diagnostic.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_row_alias_contract.gd
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
	f += _test_accessors_hand_back_the_cached_instance()
	f += _test_pk_less_local_write_strands_the_row()
	f += _test_pk_less_copy_first_keeps_the_mirror_correct()
	f += _test_pk_local_write_converges_but_reports_an_update()
	f += _test_clean_traffic_never_warns()
	f += _test_duplicate_depth()
	return f


# The premise every other case rests on: one instance, shared by the cache, the
# accessors and the callbacks.
func _test_accessors_hand_back_the_cached_instance() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_KeyedRow)
	var seen: Array[_ModuleTableType] = []
	db.subscribe_to_inserts(
		&"t",
		func(r: _ModuleTableType) -> void:
			seen.append(r),
	)
	var delivered: _KeyedRow = _KeyedRow.new(1, 1.0)
	_apply(db, [delivered], [])

	f += _check_b("the insert listener got the delivered instance", seen[0] == delivered, true)
	f += _check_b(
		"get_row_by_pk returns that same instance",
		db.get_row_by_pk(&"t", 1) == delivered,
		true,
	)
	f += _check_b(
		"get_all_rows returns that same instance",
		db.get_all_rows(&"t")[0] == delivered,
		true,
	)
	f += _check_b(
		"find_by returns that same instance",
		db.find_by(&"t", &"id", 1)[0] == delivered,
		true,
	)
	db.free()
	return f


# The consequence, on the storage path that cannot recover from it.
func _test_pk_less_local_write_strands_the_row() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_PlainRow)
	var deletes: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		&"t",
		func(_r: _ModuleTableType) -> void:
			deletes[0] += 1,
	)
	_apply(db, [_PlainRow.new(1, 1.0)], [])
	db.get_all_rows(&"t")[0].x = 99.0

	_apply(db, [], [_PlainRow.new(1, 1.0)])
	f += _check_i("the delete does not land", db.get_all_rows(&"t").size(), 1)
	f += _check_i("nothing is reported deleted", deletes[0], 0)
	f += _check_b("the miss is reported", db._unmatched_delete_warned.has(&"t"), true)

	# Once per table: a stranded row is re-delivered by every later subscription, and
	# the second line says nothing the first did not.
	_apply(db, [], [_PlainRow.new(1, 1.0)])
	f += _check_i("reported once, not once per row", db._unmatched_delete_warned.size(), 1)
	db.free()
	return f


# The pattern the docs prescribe: copy, then write to the copy.
func _test_pk_less_copy_first_keeps_the_mirror_correct() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_PlainRow)
	var deletes: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		&"t",
		func(_r: _ModuleTableType) -> void:
			deletes[0] += 1,
	)
	_apply(db, [_PlainRow.new(1, 1.0)], [])
	var mine: _PlainRow = db.get_all_rows(&"t")[0].duplicate()
	mine.x = 99.0

	f += _check_f("the mirror still holds the server's value", db.get_all_rows(&"t")[0].x, 1.0)
	_apply(db, [], [_PlainRow.new(1, 1.0)])
	f += _check_i("the delete lands", db.get_all_rows(&"t").size(), 0)
	f += _check_i("the delete is reported", deletes[0], 1)
	f += _check_b("nothing to report", db._unmatched_delete_warned.is_empty(), true)
	db.free()
	return f


# A keyed table is matched by pk, so the next delivery corrects the mirror — but the
# correction is reported as an update the server never made.
func _test_pk_local_write_converges_but_reports_an_update() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_KeyedRow)
	var updates: Array[int] = [0] # gdlint: ignore[S6]
	var old_x: Array[float] = [0.0] # gdlint: ignore[S6]
	db.subscribe_to_updates(
		&"t",
		func(p: _ModuleTableType, _n: _ModuleTableType) -> void:
			updates[0] += 1
			old_x[0] = p.x,
	)
	_apply(db, [_KeyedRow.new(1, 1.0)], [])
	db.get_row_by_pk(&"t", 1).x = 99.0
	_apply(db, [_KeyedRow.new(1, 1.0)], [])

	f += _check_i("an unchanged re-delivery is reported as an update", updates[0], 1)
	f += _check_f("the reported old row carries the local write", old_x[0], 99.0)
	f += _check_f("the mirror converges on the server's value", db.get_row_by_pk(&"t", 1).x, 1.0)
	db.free()
	return f


# Negative control: the diagnostic must stay silent for traffic that matches, including
# the shared-row case (two subscriptions, two deletes) that legitimately drops nothing.
func _test_clean_traffic_never_warns() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_PlainRow)
	_apply(db, [_PlainRow.new(1, 1.0)], [])
	_apply(db, [_PlainRow.new(1, 1.0)], [])
	_apply(db, [], [_PlainRow.new(1, 1.0)])
	_apply(db, [], [_PlainRow.new(1, 1.0)])
	f += _check_i("both deletes landed", db.get_all_rows(&"t").size(), 0)
	f += _check_b("no diagnostic", db._unmatched_delete_warned.is_empty(), true)
	db.free()
	return f


# What the docs promise about copying: duplicate() is shallow — a nested record and an
# array column are still shared with the cached row — and duplicate_deep() is not.
func _test_duplicate_depth() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_NestedRow)
	var row: _NestedRow = _NestedRow.new(1, 1.0)
	_apply(db, [row], [])
	var cached: _NestedRow = db.get_all_rows(&"t")[0]

	var shallow: _NestedRow = cached.duplicate()
	f += _check_b("duplicate() shares the nested record", shallow.inner == cached.inner, true)
	shallow.parts.append(_Inner.new(2.0))
	f += _check_i("duplicate() shares an array column", cached.parts.size(), 2)

	var deep: _NestedRow = cached.duplicate_deep()
	f += _check_b("duplicate_deep() copies the nested record", deep.inner == cached.inner, false)
	deep.parts.append(_Inner.new(3.0))
	f += _check_i("duplicate_deep() copies an array column", cached.parts.size(), 2)
	db.free()
	return f


func _mk_db(row_script: GDScript) -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"t"]
	schema.types[&"t"] = row_script
	schema.tables[&"t"] = row_script
	return LocalDatabase.new(schema)


func _apply(db: LocalDatabase, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"t"
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


func _check_f(label: String, got: float, want: float) -> int:
	_total += 1
	if is_equal_approx(got, want):
		print("PASS  %s = %f" % [label, got])
		return 0
	printerr("FAIL  %s: got %f want %f" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


# Row shapes as codegen emits them: BSATN_TYPES always, PRIMARY_KEY only for a table the
# schema gives a primary key.
class _PlainRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"x": &"f32" }
	@export var id: int = 0
	@export var x: float = 0.0


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		x = p_x


class _KeyedRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"x": &"f32" }
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var x: float = 0.0


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		x = p_x


class _Inner:
	extends Resource
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"y": &"f32" }
	@export var y: float = 0.0


	func _init(p_y: float = 0.0) -> void:
		y = p_y


class _NestedRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"id": &"u32",
		&"inner": &"_Inner",
		&"parts": &"_Inner",
	}
	@export var id: int = 0
	@export var inner: Resource
	## Vec<Struct> column: Array[Struct], the shape that carries object elements. An
	## Array is a reference, so a shallow duplicate shares it — which is the point here.
	@export var parts: Array[Resource] = []


	func _init(p_id: int = 0, p_y: float = 0.0) -> void:
		id = p_id
		inner = _Inner.new(p_y)
		parts = [_Inner.new(p_y)]
