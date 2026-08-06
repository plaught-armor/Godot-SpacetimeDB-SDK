# Regression test: an EVENT table gets no index accessors.
#
# An event table's rows are never resident. LocalDatabase fires on_insert for each row
# and stores nothing, so count() and iter() stay empty and no delete is ever reported.
# The generated index accessors are kept current by exactly those insert/update/delete
# callbacks, so an index over an event table can only grow: codegen emitted one for every
# index the schema declared on such a table, and each event row was appended to a bucket
# nothing would ever release. Measured below on the SDK's own index base classes — 40
# batches of 3 rows leave 120 rows cached while the table reports 0 — and filter()
# answered with rows the table itself says do not exist.
#
# Codegen now emits no unique/btree accessor for an event table, which is what the
# official Rust codegen does ("no resident rows means these would always be empty",
# crates/codegen/src/rust.rs). The typed finders fall back to find_by/first_by, which
# read the empty mirror: still empty, but consistent with count()/iter().
#
# The `vevent` fixture carries an event table and a structurally identical non-event
# table, so the control half fails if codegen ever stops emitting indexes at all.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_event_table_no_index.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vevent.json"
const TMP: String = "user://event_index_gen"
## Event rows pushed per batch, and batches — the product is what an index would cache.
const ROWS_PER_BATCH: int = 3
const BATCHES: int = 40

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
	f += _test_codegen_skips_event_indexes()
	f += _test_event_rows_are_not_resident()
	return f

# --- Codegen half ---------------------------------------------------------------


func _test_codegen_skips_event_indexes() -> int:
	var f: int = 0
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (json is Dictionary):
		printerr("FAIL  fixture is not a JSON object: %s" % FIXTURE)
		_total += 1
		return 1
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(json, "vevent", { })
	f += _check_b("fixture parses", not schema.is_empty(), true)

	# The fixture is only meaningful if the parser still hands codegen the event table's
	# indexes — the fix is codegen declining to emit them, not the schema losing them.
	for table_def: Dictionary in schema.tables:
		if table_def.get("name", "") != "damage":
			continue
		f += _check_b("fixture: damage is an event table", table_def.get("is_event", false), true)
		f += _check_b(
			"fixture: the parser still carries its indexes",
			(
				not (table_def.get("unique_indexes", []) as Array).is_empty()
				and not (table_def.get("btree_indexes", []) as Array).is_empty()
			),
			true,
		)

	_reset_dir(TMP)
	DirAccess.make_dir_recursive_absolute("%s/types" % TMP)
	DirAccess.make_dir_recursive_absolute("%s/tables" % TMP)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(TMP)
	codegen._plugin_config = _build_config("vevent")
	var generated: PackedStringArray = []
	for path: String in codegen._generate_gdscript_from_schema("vevent", schema):
		generated.append(path.get_file())

	f += _check_b(
		"no index file for the event table",
		_any_name_with_both(generated, "vevent_damage_", "_index.gd"),
		false,
	)
	# Control: the non-event table with the same index shape still gets both accessors.
	f += _check_b(
		"the control table still gets its unique index",
		generated.has("vevent_thing_id_unique_index.gd"),
		true,
	)
	f += _check_b(
		"the control table still gets its btree index",
		generated.has("vevent_thing_score_btree_index.gd"),
		true,
	)

	var damage_src: String = FileAccess.get_file_as_string("%s/tables/vevent_damage_table.gd" % TMP)
	f += _check_b("the event table's wrapper was written", not damage_src.is_empty(), true)
	f += _check_b(
		"the event table declares no index member",
		damage_src.contains("UniqueIndex") or damage_src.contains("BTreeIndex"),
		false,
	)
	# The typed finders must still exist — dropping the index must not drop the accessor.
	f += _check_b(
		"its typed finder falls back to the mirror",
		damage_src.contains('return find_by(&"target", value)'),
		true,
	)

	var thing_src: String = FileAccess.get_file_as_string("%s/tables/vevent_thing_table.gd" % TMP)
	f += _check_b(
		"the control table's wrapper still builds its indexes",
		thing_src.contains("UniqueIndex") and thing_src.contains("BTreeIndex"),
		true,
	)
	_rm_rf(TMP)
	return f

# --- Runtime half: why an index over an event table cannot be maintained ---------


func _test_event_rows_are_not_resident() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	var seen: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_inserts(
		&"ev",
		func(_row: _ModuleTableType) -> void:
			seen[0] += 1,
	)
	# A hand-built index of the shape codegen used to emit, wired to the same callbacks.
	var idx: _EvBTree = _EvBTree.new(db)

	for _batch: int in BATCHES:
		var rows: Array[_ModuleTableType] = []
		for i: int in ROWS_PER_BATCH:
			rows.append(_EvRow.new(i, 7))
		_apply_event(db, rows)

	var pushed: int = BATCHES * ROWS_PER_BATCH
	f += _check_i("every event row reached on_insert", seen[0], pushed)
	f += _check_i("the mirror stores none of them", db.count_all_rows(&"ev"), 0)
	f += _check_i("iter() is empty", db.get_all_rows(&"ev").size(), 0)
	f += _check_i("find_by reports nothing", db.find_by(&"ev", &"kind", 7).size(), 0)
	# The measurement the codegen rule rests on: an index subscribed to those same
	# callbacks holds every row ever delivered, because no delete is ever reported.
	# If this ever stops being true (event rows made resident), revisit the codegen rule.
	f += _check_i("an index would hold all of them", idx.bucket_size(7), pushed)
	db.free()
	return f

# --- Helpers --------------------------------------------------------------------


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"ev"]
	schema.types[&"ev"] = _EvRow
	schema.tables[&"ev"] = _EvRow
	return LocalDatabase.new(schema)


func _apply_event(db: LocalDatabase, rows: Array[_ModuleTableType]) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"ev"
	u.is_event = true
	var ins: Array[Resource] = []
	ins.assign(rows)
	u.inserts = ins
	db.apply_table_update(u)


func _build_config(module: String) -> SpacetimeDBPluginConfig:
	var cfg: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var mc: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	mc.name = module
	mc.hide_private_tables = false
	mc.hide_scheduled_reducers = false
	cfg.module_configs[module] = mc
	return cfg


## Whether ONE generated file name contains both needles — a per-name conjunction, not
## two independent searches (`vevent_damage_table.gd` and `vevent_thing_id_unique_index.gd`
## would satisfy those separately while no event-table index file exists).
func _any_name_with_both(names: PackedStringArray, a: String, b: String) -> bool:
	for n: String in names:
		if n.contains(a) and n.contains(b):
			return true
	return false


func _reset_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		_rm_rf(path)
	DirAccess.make_dir_recursive_absolute(path)


func _rm_rf(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		var child: String = "%s/%s" % [path, name]
		if dir.current_is_dir():
			_rm_rf(child)
		else:
			DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


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


## What codegen emits for an event table's row: BSATN_TYPES, no PRIMARY_KEY.
class _EvRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"kind": &"u32" }
	@export var id: int = 0
	@export var kind: int = 0


	func _init(p_id: int = 0, p_kind: int = 0) -> void:
		id = p_id
		kind = p_kind


## The shape a generated btree accessor has, wired to the same live callbacks.
class _EvBTree:
	extends _ModuleTableBTreeIndex
	var _cache: Dictionary[int, Array] = { }


	func _init(p_local_db: LocalDatabase) -> void:
		_table_name = &"ev"
		_field_name = &"kind"
		_connect_cache_to_db(_cache, p_local_db)


	func bucket_size(v: int) -> int:
		return (_cache.get(v, []) as Array).size()
