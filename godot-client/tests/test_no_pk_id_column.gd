# Regression test for how LocalDatabase decides a table's primary key.
#
# The generated row script carries a PRIMARY_KEY const exactly when the schema gives the
# table a primary key (verified against codegen: a fixture with `primary_key: []` emits
# BSATN_TYPES and no PRIMARY_KEY). _get_primary_key_field used to fall back, when the
# const was absent, to "the storage property named `id` or `identity`" — but the const is
# absent precisely because there IS no primary key, and such a column carries no
# uniqueness promise. A log or junction table (`id` = the entity a row is about,
# `identity` = the player it belongs to, many rows per value) was therefore keyed by a
# duplicate value, and the rows collapsed into one cached entry: the mirror showed one
# row where the server held several, and it stayed wrong for the session.
#
# Asserts that such a table is refcounted by row value, that the same shape with a
# PRIMARY_KEY const still takes the PK path, and that a differently-named column was never
# affected (the control that isolates the fallback as the cause).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_no_pk_id_column.gd
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
	f += _case_no_pk("id column", _IdRow, &"id")
	f += _case_no_pk("identity column", _IdentityRow, &"identity")
	f += _case_no_pk("unrelated column name (control)", _OtherRow, &"entity_id")
	f += _test_declared_pk_still_keys()
	return f


# A table whose row script has no PRIMARY_KEY const has no primary key, whatever its
# columns are called: rows are held by value, so two rows sharing one column's value are
# two rows, and each delete releases one of them.
func _case_no_pk(label: String, row_script: GDScript, field: StringName) -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(row_script)
	f += _check_s("%s: no pk field resolved" % label, db._get_primary_key_field(&"t"), &"")

	_apply(db, [_mk(row_script, 1, 10), _mk(row_script, 1, 20)], [])
	f += _check_i(
		"%s: two rows sharing a value are both cached" % label,
		db.get_all_rows(&"t").size(),
		2,
	)

	_apply(db, [_mk(row_script, 2, 30)], [])
	f += _check_i("%s: a third row with its own value" % label, db.get_all_rows(&"t").size(), 3)
	f += _check_i(
		"%s: both rows are findable by the shared value" % label,
		db.find_by(&"t", field, 1).size(),
		2,
	)

	# Deleting one of the pair leaves the other, which the PK path could not express.
	_apply(db, [], [_mk(row_script, 1, 10)])
	f += _check_i(
		"%s: deleting one of the pair leaves the other" % label,
		db.get_all_rows(&"t").size(),
		2,
	)
	f += _check_i(
		"%s: the survivor is the one not deleted" % label,
		db.find_by(&"t", &"score", 20).size(),
		1,
	)

	db.free()
	return f


# The opt-in half: a row that declares PRIMARY_KEY is still keyed by it, so a second row
# with the same key is an update of the first, not a second row.
func _test_declared_pk_still_keys() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_KeyedRow)
	f += _check_s("declared pk resolves", db._get_primary_key_field(&"t"), &"id")

	var updates: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_updates(
		&"t",
		func(_p: _ModuleTableType, _n: _ModuleTableType) -> void:
			updates[0] += 1,
	)

	_apply(db, [_KeyedRow.new(1, 10)], [])
	_apply(db, [_KeyedRow.new(1, 20)], [_KeyedRow.new(1, 10)])
	f += _check_i("declared pk: one cached row", db.get_all_rows(&"t").size(), 1)
	f += _check_i("declared pk: the change reported as an update", updates[0], 1)

	_apply(db, [], [_KeyedRow.new(1, 20)])
	f += _check_i("declared pk: the delete landed", db.get_all_rows(&"t").size(), 0)
	db.free()
	return f


func _mk(row_script: GDScript, key: int, score: int) -> _ModuleTableType:
	return row_script.new(key, score)


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


func _check_s(label: String, got: StringName, want: StringName) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


# The three shapes below are what codegen emits for a table with no primary key:
# BSATN_TYPES, no PRIMARY_KEY. Only the first column's NAME differs.
class _IdRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"score": &"u32" }
	@export var id: int = 0
	@export var score: int = 0


	func _init(p_id: int = 0, p_score: int = 0) -> void:
		id = p_id
		score = p_score


class _IdentityRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"identity": &"u32",
		&"score": &"u32",
	}
	@export var identity: int = 0
	@export var score: int = 0


	func _init(p_identity: int = 0, p_score: int = 0) -> void:
		identity = p_identity
		score = p_score


class _OtherRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = {
		&"entity_id": &"u32",
		&"score": &"u32",
	}
	@export var entity_id: int = 0
	@export var score: int = 0


	func _init(p_entity_id: int = 0, p_score: int = 0) -> void:
		entity_id = p_entity_id
		score = p_score


# What codegen emits when the schema DOES give the table a primary key.
class _KeyedRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"score": &"u32" }
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var score: int = 0


	func _init(p_id: int = 0, p_score: int = 0) -> void:
		id = p_id
		score = p_score
