# Regression test for a row column whose value is NaN.
#
# GDScript says `NAN == NAN` is false while `hash(NAN)` is a single value (Godot's
# hash_djb2_one_float normalizes NaN and -0.0 before hashing). LocalDatabase's row
# hash is built on that hash and its row equality was built on `==`, so the two
# disagreed for any row carrying a NaN float:
#
#   * PK-less table — the hash bucket was found and then never matched, so every
#     delivery of the row cached ANOTHER copy and every delete of it was dropped.
#     The row could not leave the mirror for the rest of the session.
#   * PK table — an unchanged re-delivery (what overlapping subscriptions produce)
#     was reported as row_updated, every time.
#
# The server holds one such row: sats types a float column as `decorum::Total<f32>`
# (crates/sats/src/algebraic_value.rs), a total order in which NaN equals itself.
#
# Each NaN case is paired with the same shape carrying an ordinary float, so a fix
# that broke normal rows fails here too, and with a negative control that NaN is not
# equal to everything.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_nan_column_equality.gd
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
	f += _test_gdscript_premise()
	f += _case_pk_less("float NaN", _FloatRow, NAN)
	f += _case_pk_less("float 1.5 (control)", _FloatRow, 1.5)
	f += _case_pk_less("float -0.0", _FloatRow, -0.0)
	f += _case_pk_less("Vector2 with a NaN component", _VectorRow, NAN)
	f += _case_pk_less("Vector2 ordinary (control)", _VectorRow, 1.5)
	f += _case_pk_less("Color with a NaN component", _ColorRow, NAN)
	f += _case_pk_less("Quaternion with a NaN component", _QuatRow, NAN)
	f += _case_pk_less("nested record holding NaN", _NestedRow, NAN)
	f += _case_pk_less("Array[float] holding NaN", _ArrayRow, NAN)
	f += _case_pk_less("Option holding NaN", _OptionRow, NAN)
	f += _case_pk_less("sum-type payload holding NaN", _EnumRow, NAN)
	f += _test_distinct_values_stay_distinct()
	f += _test_pk_unchanged_redelivery()
	f += _test_pk_real_change_still_reported()
	return f


# The engine behaviour the branch exists for. If a future Godot makes `NAN == NAN`
# true, this fails and the branch can go.
func _test_gdscript_premise() -> int:
	var f: int = 0
	var a: float = NAN
	var b: float = 0.0 / 0.0
	f += _check_b("NAN == NAN is false", a == b, false)
	f += _check_b("hash(NAN) == hash(NAN) is true", hash(a) == hash(b), true)
	f += _check_b("hash(-0.0) == hash(0.0) is true", hash(-0.0) == hash(0.0), true)
	return f


# A PK-less table refcounts by row VALUE: two subscriptions delivering the same row
# hold ONE cached entry with count 2, the first delete leaves it, the second evicts it
# and reports it.
func _case_pk_less(label: String, row_script: GDScript, value: float) -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(row_script)
	var deletes: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		&"t",
		func(_r: _ModuleTableType) -> void:
			deletes[0] += 1,
	)

	_apply(db, [row_script.new(1, value)], [])
	_apply(db, [row_script.new(1, value)], [])
	f += _check_i("%s: two deliveries are one row" % label, db.get_all_rows(&"t").size(), 1)

	_apply(db, [], [row_script.new(1, value)])
	f += _check_i("%s: one delete leaves the shared row" % label, db.get_all_rows(&"t").size(), 1)
	f += _check_i("%s: nothing reported deleted yet" % label, deletes[0], 0)

	_apply(db, [], [row_script.new(1, value)])
	f += _check_i("%s: the second delete evicts it" % label, db.get_all_rows(&"t").size(), 0)
	f += _check_i("%s: the eviction was reported" % label, deletes[0], 1)

	db.free()
	return f


# The negative control: NaN is equal to NaN, not to everything, and not in any
# position. Rows that really differ — a vector whose OTHER component differs, or one
# carrying its NaN in a different slot — stay distinct. This case passed before the fix
# too (everything with a NaN was distinct, for the wrong reason); it is here to fail an
# over-reaching fix, not the original bug. Same for the "(control)" cases above and for
# [method _test_pk_real_change_still_reported]: the cases that discriminate broken from
# fixed are the NaN [method _case_pk_less] runs and
# [method _test_pk_unchanged_redelivery].
func _test_distinct_values_stay_distinct() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_FloatRow)
	_apply(db, [_FloatRow.new(1, NAN), _FloatRow.new(1, 0.0), _FloatRow.new(2, NAN)], [])
	f += _check_i("NaN, 0.0 and a different id are three rows", db.get_all_rows(&"t").size(), 3)
	db.free()

	var vdb: LocalDatabase = _mk_db(_VectorRow)
	_apply(vdb, [_VectorRow.new(1, Vector2(NAN, 1.0)), _VectorRow.new(1, Vector2(NAN, 2.0))], [])
	f += _check_i(
		"two vectors sharing a NaN but differing elsewhere are two rows",
		vdb.get_all_rows(&"t").size(),
		2,
	)
	vdb.free()

	# The NaN is in a different component in each, so neither component pairs up.
	var pdb: LocalDatabase = _mk_db(_VectorRow)
	_apply(pdb, [_VectorRow.new(1, Vector2(NAN, 1.0)), _VectorRow.new(1, Vector2(1.0, NAN))], [])
	f += _check_i(
		"two vectors with their NaN in different components are two rows",
		pdb.get_all_rows(&"t").size(),
		2,
	)
	pdb.free()
	return f


# A PK table must not report an unchanged re-delivery as an update.
func _test_pk_unchanged_redelivery() -> int:
	var f: int = 0
	for value: float in [NAN, 1.5]:
		var db: LocalDatabase = _mk_db(_KeyedFloatRow)
		var updates: Array[int] = [0] # gdlint: ignore[S6]
		db.subscribe_to_updates(
			&"t",
			func(_p: _ModuleTableType, _n: _ModuleTableType) -> void:
				updates[0] += 1,
		)
		_apply(db, [_KeyedFloatRow.new(1, value)], [])
		_apply(db, [_KeyedFloatRow.new(1, value)], [])
		f += _check_i("pk %s: unchanged re-delivery is not an update" % value, updates[0], 0)
		db.free()
	return f


# The other half: a column that really changed to or from NaN is still an update.
func _test_pk_real_change_still_reported() -> int:
	var f: int = 0
	var pairs: Array[Array] = [[NAN, 1.0], [1.0, NAN]]
	for pair: Array in pairs:
		var db: LocalDatabase = _mk_db(_KeyedFloatRow)
		var updates: Array[int] = [0] # gdlint: ignore[S6]
		db.subscribe_to_updates(
			&"t",
			func(_p: _ModuleTableType, _n: _ModuleTableType) -> void:
				updates[0] += 1,
		)
		_apply(db, [_KeyedFloatRow.new(1, pair[0])], [])
		_apply(db, [_KeyedFloatRow.new(1, pair[1])], [_KeyedFloatRow.new(1, pair[0])])
		f += _check_i("pk %s -> %s is reported as an update" % [pair[0], pair[1]], updates[0], 1)
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


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


# Each row shape below is what codegen emits for a table with no primary key
# (BSATN_TYPES, no PRIMARY_KEY) carrying one float-bearing column, plus the keyed
# variant for the PK cases. The second constructor argument is the value under test,
# widened to the column's own type.
class _FloatRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"x": &"f32" }
	@export var id: int = 0
	@export var x: float = 0.0


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		x = p_x


class _KeyedFloatRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"x": &"f32" }
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var x: float = 0.0


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		x = p_x


class _VectorRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"id": &"u32",
		&"p": &"vector2[f32,f32]",
	}
	@export var id: int = 0
	@export var p: Vector2 = Vector2.ZERO


	func _init(p_id: int = 0, p_p: Variant = 0.0) -> void:
		id = p_id
		p = p_p if p_p is Vector2 else Vector2(p_p, 0.0)


class _ColorRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"id": &"u32",
		&"c": &"color[f32,f32,f32,f32]",
	}
	@export var id: int = 0
	@export var c: Color = Color.BLACK


	func _init(p_id: int = 0, p_c: float = 0.0) -> void:
		id = p_id
		c = Color(p_c, 0.0, 0.0, 1.0)


class _QuatRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"id": &"u32",
		&"q": &"quaternion[f32,f32,f32,f32]",
	}
	@export var id: int = 0
	@export var q: Quaternion = Quaternion.IDENTITY


	func _init(p_id: int = 0, p_q: float = 0.0) -> void:
		id = p_id
		q = Quaternion(p_q, 0.0, 0.0, 1.0)


# A nested product column: the walk into it goes through _values_equal, not the
# inline primitive compare in _rows_equal.
class _Inner:
	extends Resource
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"v": &"f32" }
	@export var v: float = 0.0


	func _init(p_v: float = 0.0) -> void:
		v = p_v


class _NestedRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"inner": &"_Inner" }
	@export var id: int = 0
	@export var inner: Resource = null


	func _init(p_id: int = 0, p_v: float = 0.0) -> void:
		id = p_id
		inner = _Inner.new(p_v)


# Vec<f32> — codegen emits Array[float], compared element by element.
class _ArrayRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"xs": &"vec_f32" }
	@export var id: int = 0
	@export var xs: Array[float] = [] # gdlint: ignore[S6] — codegen emits Array[T] for Vec<T>


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		xs = [1.0, p_x]


# The two SDK wrapper columns that keep their payload in a named member: both descend
# through _values_equal, so a NaN payload reaches the same leaf compare.
class _OptionRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"o": &"opt_f32" }
	@export var id: int = 0
	@export var o: Option = null


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		o = Option.some(p_x)


class _EnumRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"e": &"_Payload" }
	@export var id: int = 0
	@export var e: RustEnum = null


	func _init(p_id: int = 0, p_x: float = 0.0) -> void:
		id = p_id
		e = RustEnum.new()
		e.value = 1
		e.data = p_x
