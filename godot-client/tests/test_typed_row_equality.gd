# The `_eq` / `_row_eq` codegen emits on every record type must answer exactly what the
# generic LocalDatabase._rows_equal walk answers, column for column. It replaces that walk
# on every generated row, so a disagreement silently changes which re-deliveries fire
# row_updated, which rows a table without a primary key treats as the same row, and
# whether equal rows still hash equal under _row_hash.
#
# Three parts:
#   1. The committed Blackholio bindings, which hold every column shape the example module
#      has — nested record, float, String, identity bytes, Option, arrays, a sum type, wide
#      ints, ScheduleAt — each changed one column at a time, NaN and null included. Every
#      case also states the expected answer, so the two paths cannot agree on a wrong one.
#   2. Every type in SpacetimeCodegen._EQ_VALUE_TYPES. No committed binding has a native
#      vector, Color or Plane column, so the check codegen emits for each type is compiled
#      into a one-column record and held against the walk over every pair of samples.
#   3. The columns whose check follows the parsed schema type — a record, a wrapped record,
#      a record with no columns, a sum type, a plain enum — the last two also compiled.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_typed_row_equality.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_check_generated_overrides()
	_check_circle()
	_check_player_and_config()
	_check_schedule_at()
	_check_probe_row()
	_check_value_types()
	_check_schema_routed_columns()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _record(label: String, ok: bool, detail: String) -> void:
	_total += 1
	if ok:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — %s" % [label, detail])


# The column list LocalDatabase._get_row_properties builds from a row script.
static func _columns(row: _ModuleTableType) -> Array[StringName]:
	var cols: Array[StringName] = []
	var script: Script = row.get_script()
	for prop: Dictionary in script.get_script_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE:
			cols.append(prop.name)
	return cols


# The walk, the generated comparison and the generated comparison run the other way round
# must all give [param want].
func _agree(label: String, lhs: _ModuleTableType, rhs: _ModuleTableType, want: bool) -> void:
	var cols: Array[StringName] = _columns(lhs)
	var walk: bool = LocalDatabase._rows_equal(lhs, rhs, cols)
	var gen: bool = lhs._row_eq(rhs, cols)
	var gen_back: bool = rhs._row_eq(lhs, cols)
	_record(
		label,
		walk == want and gen == want and gen_back == want,
		"walk=%s generated=%s reversed=%s want=%s" % [walk, gen, gen_back, want],
	)


# A row without its generated _row_eq falls back to the base walk, and every case below
# then passes while testing nothing; this is what tells the two apart. A script's method
# list also names the methods it inherits, so a row overrides _row_eq only when its list
# names the method more often than its base script's list does.
func _check_generated_overrides() -> void:
	var rows: Array[Script] = [
		BlackholioCircle,
		BlackholioEntity,
		BlackholioPlayer,
		BlackholioConfig,
		BlackholioSpawnFoodTimer,
		BlackholioProbeRow,
	]
	for script: Script in rows:
		var own: int = _count_methods(script, &"_row_eq")
		var inherited: int = _count_methods(script.get_base_script(), &"_row_eq")
		_record(
			"%s overrides _row_eq" % script.get_global_name(),
			own > inherited,
			"falls back to the base walk",
		)
		_record(
			"%s carries a generated _eq" % script.get_global_name(),
			_count_methods(script, &"_eq") > 0,
			"not emitted",
		)
	# A nested record is no row, so it carries _eq alone.
	_record(
		"BlackholioDbVector2 carries a generated _eq",
		_count_methods(BlackholioDbVector2, &"_eq") > 0,
		"not emitted",
	)


static func _count_methods(script: Script, method_name: StringName) -> int:
	var count: int = 0
	for method: Dictionary in script.get_script_method_list():
		if method.name == method_name:
			count += 1
	return count


static func _circle() -> BlackholioCircle:
	return BlackholioCircle.create(7, 3, BlackholioDbVector2.create(0.6, 0.8), 1.25, 1700000000000)


func _check_circle() -> void:
	_agree("circle: equal values, distinct instances", _circle(), _circle(), true)
	var c: BlackholioCircle = _circle()
	c.entity_id = 8
	_agree("circle: entity_id differs", _circle(), c, false)
	c = _circle()
	c.player_id = 4
	_agree("circle: player_id differs", _circle(), c, false)
	c = _circle()
	c.direction.x = 0.7
	_agree("circle: nested direction.x differs", _circle(), c, false)
	c = _circle()
	c.direction.y = 0.9
	_agree("circle: nested direction.y differs", _circle(), c, false)
	var nan_a: BlackholioCircle = _circle()
	var nan_b: BlackholioCircle = _circle()
	nan_a.direction.x = NAN
	nan_b.direction.x = NAN
	_agree("circle: nested NaN on both sides", nan_a, nan_b, true)
	_agree("circle: nested NaN on one side", nan_a, _circle(), false)
	var null_a: BlackholioCircle = _circle()
	var null_b: BlackholioCircle = _circle()
	null_a.direction = null
	null_b.direction = null
	_agree("circle: nested record null on both sides", null_a, null_b, true)
	_agree("circle: nested record null on one side", null_a, _circle(), false)
	nan_a = _circle()
	nan_b = _circle()
	nan_a.speed = NAN
	nan_b.speed = NAN
	_agree("circle: float NaN on both sides", nan_a, nan_b, true)
	_agree("circle: float NaN on one side", nan_a, _circle(), false)
	c = _circle()
	var z: BlackholioCircle = _circle()
	c.speed = 0.0
	z.speed = -0.0
	_agree("circle: 0.0 against -0.0", c, z, true)
	c = _circle()
	c.last_split_time += 1
	_agree("circle: last column differs", _circle(), c, false)
	var e: BlackholioEntity = BlackholioEntity.create(7, BlackholioDbVector2.create(1.0, 2.0), 42)
	var e2: BlackholioEntity = BlackholioEntity.create(7, BlackholioDbVector2.create(1.0, 2.0), 42)
	_agree("entity: equal values, distinct instances", e, e2, true)
	e2.mass = 43
	_agree("entity: last column differs", e, e2, false)


static func _player() -> BlackholioPlayer:
	var identity: PackedByteArray = []
	identity.resize(32)
	identity.fill(7)
	return BlackholioPlayer.create(identity, 3, "player")


func _check_player_and_config() -> void:
	_agree("player: equal bytes in distinct arrays", _player(), _player(), true)
	var p: BlackholioPlayer = _player()
	p.identity[31] = 8
	_agree("player: one identity byte differs", _player(), p, false)
	p = _player()
	p.name = "other"
	_agree("player: String differs", _player(), p, false)
	var empty_a: BlackholioPlayer = _player()
	var empty_b: BlackholioPlayer = _player()
	empty_a.name = ""
	empty_b.name = ""
	_agree("player: empty Strings", empty_a, empty_b, true)
	_agree(
		"config: equal",
		BlackholioConfig.create(1, 1000),
		BlackholioConfig.create(1, 1000),
		true,
	)
	_agree(
		"config: last int differs",
		BlackholioConfig.create(1, 1000),
		BlackholioConfig.create(1, 1001),
		false,
	)


func _check_schedule_at() -> void:
	var a: BlackholioSpawnFoodTimer = BlackholioSpawnFoodTimer.create(1, ScheduleAt.interval(500))
	_agree(
		"timer: equal interval",
		a,
		BlackholioSpawnFoodTimer.create(1, ScheduleAt.interval(500)),
		true,
	)
	_agree(
		"timer: micros differ",
		a,
		BlackholioSpawnFoodTimer.create(1, ScheduleAt.interval(501)),
		false,
	)
	_agree(
		"timer: kind differs",
		a,
		BlackholioSpawnFoodTimer.create(1, ScheduleAt.at_time(500)),
		false,
	)
	var null_a: BlackholioSpawnFoodTimer = BlackholioSpawnFoodTimer.create(1, null)
	var null_b: BlackholioSpawnFoodTimer = BlackholioSpawnFoodTimer.create(1, null)
	_agree("timer: ScheduleAt null on both sides", null_a, null_b, true)
	_agree("timer: ScheduleAt null on one side", null_a, a, false)


static func _bytes(size: int, fill: int) -> PackedByteArray:
	var out: PackedByteArray = []
	out.resize(size)
	out.fill(fill)
	return out


static func _probe() -> BlackholioProbeRow:
	var numbers: Array[int] = [1, 2, 3] # gdlint: ignore[S6] — the generated create() takes Array[int]
	var words: Array[String] = ["a", "b"] # gdlint: ignore[S6] — the generated create() takes Array[String]
	var points: Array[BlackholioDbVector2] = [BlackholioDbVector2.create(1.0, 2.0)]
	return BlackholioProbeRow.create(
		1,
		Option.some("hi"),
		Option.none(),
		BlackholioProbeKind.create(1, 5),
		_bytes(16, 1),
		_bytes(32, 2),
		_bytes(16, 3),
		_bytes(32, 4),
		numbers,
		words,
		points,
	)


func _check_probe_row() -> void:
	_agree("probe: equal values, distinct instances", _probe(), _probe(), true)
	var p: BlackholioProbeRow = _probe()
	p.maybe_text = Option.some("ho")
	_agree("probe: Option payload differs", _probe(), p, false)
	p = _probe()
	p.maybe_text = Option.none()
	_agree("probe: Option some against none", _probe(), p, false)
	p = _probe()
	p.maybe_count = Option.some(0)
	_agree("probe: Option none against some", _probe(), p, false)
	p = _probe()
	p.kind = BlackholioProbeKind.create(2, "5")
	_agree("probe: sum variant differs", _probe(), p, false)
	p = _probe()
	p.kind = BlackholioProbeKind.create(1, 6)
	_agree("probe: sum payload differs", _probe(), p, false)
	var unit_a: BlackholioProbeRow = _probe()
	var unit_b: BlackholioProbeRow = _probe()
	unit_a.kind = BlackholioProbeKind.create(0)
	unit_b.kind = BlackholioProbeKind.create(0)
	_agree("probe: unit variant on both sides", unit_a, unit_b, true)
	p = _probe()
	p.wide_signed[0] = 9
	_agree("probe: wide int byte differs", _probe(), p, false)
	p = _probe()
	p.numbers.append(4)
	_agree("probe: array length differs", _probe(), p, false)
	p = _probe()
	p.words[1] = "c"
	_agree("probe: array element differs", _probe(), p, false)
	var nan_a: BlackholioProbeRow = _probe()
	var nan_b: BlackholioProbeRow = _probe()
	nan_a.points[0].x = NAN
	nan_b.points[0].x = NAN
	_agree("probe: NaN inside an array of records", nan_a, nan_b, true)
	_agree("probe: NaN inside an array of records, one side", nan_a, _probe(), false)


# Samples per _EQ_VALUE_TYPES entry. A type added to that table without samples here fails.
static func _samples() -> Dictionary[String, Array]:
	var empty_bytes: PackedByteArray = []
	var one_byte: PackedByteArray = [1]
	var two_bytes: PackedByteArray = [1, 2]
	return {
		"int": [0, 1, -1, 1 << 62],
		"bool": [true, false],
		"float": [0.0, -0.0, 1.5, NAN, INF, -INF],
		"String": ["", "a", "b"],
		"StringName": [&"", &"a", &"b"],
		"PackedByteArray": [empty_bytes, one_byte, two_bytes],
		"Vector2": [Vector2(), Vector2(1, 2), Vector2(NAN, 2), Vector2(1, NAN), Vector2(NAN, NAN)],
		"Vector2i": [Vector2i(), Vector2i(1, 2)],
		"Vector3": [Vector3(), Vector3(1, 2, 3), Vector3(NAN, 2, 3), Vector3(1, 2, NAN)],
		"Vector3i": [Vector3i(), Vector3i(1, 2, 3)],
		"Vector4": [Vector4(), Vector4(1, 2, 3, 4), Vector4(NAN, 2, 3, 4), Vector4(1, 2, 3, NAN)],
		"Vector4i": [Vector4i(), Vector4i(1, 2, 3, 4)],
		"Quaternion": [Quaternion(), Quaternion(NAN, 0, 0, 1), Quaternion(0, 0, 0, NAN)],
		"Color": [Color(), Color(1, 0, 0, 1), Color(NAN, 0, 0, 1), Color(0, 0, 0, NAN)],
		"Plane": [Plane(), Plane(1, 0, 0, 2), Plane(NAN, 0, 0, 1)],
	}


func _check_value_types() -> void:
	var samples: Dictionary[String, Array] = _samples()
	for type_name: String in SpacetimeCodegen._EQ_VALUE_TYPES:
		if not samples.has(type_name):
			_record("%s: has samples" % type_name, false, "add samples for the new type")
			continue
		_agree_compiled(type_name, "", type_name, type_name, { }, samples[type_name])


# The check codegen emits for a plain column of [param gd_type] inside `_eq`.
static func _lines(gd_type: String, type_def: Dictionary, wrapped: bool) -> String:
	return SpacetimeCodegen._eq_check_lines("p_lhs.c", "p_rhs.c", gd_type, type_def, wrapped)


# Columns whose check follows the parsed schema type rather than the declared GDScript
# type. No committed binding has a plain enum column, a record with no columns or a native
# vector column.
func _check_schema_routed_columns() -> void:
	var record: Dictionary = { "struct": [{ "name": "x", "type": "f32" }] }
	var unit: Dictionary = { "struct": [] }
	var plain_enum: Dictionary = {
		"enum": [{ "name": "A" }, { "name": "B" }],
		"is_sum_type": false,
	}
	var sum_type: Dictionary = { "enum": [{ "name": "A", "type": "u32" }], "is_sum_type": true }
	# A native type carries its components as a struct too; it must keep its value check,
	# since Vector2 has no _eq to call.
	var native: Dictionary = {
		"gd_native": true,
		"gd_arraylike": true,
		"struct": [{ "name": "x", "type": "f32" }, { "name": "y", "type": "f32" }],
	}
	var generic: String = _lines("Rec", { }, false)
	_record(
		"record column calls the record's _eq",
		_lines("Rec", record, false).contains("not Rec._eq("),
		_lines("Rec", record, false),
	)
	_record(
		"wrapped record column keeps _values_equal",
		_lines("Array[Rec]", record, true) == _lines("Array[Rec]", { }, false),
		_lines("Array[Rec]", record, true),
	)
	_record(
		"record with no columns keeps _values_equal",
		_lines("Rec", unit, false) == generic,
		_lines("Rec", unit, false),
	)
	_record(
		"sum type column keeps _values_equal",
		_lines("Rec", sum_type, false) == generic,
		_lines("Rec", sum_type, false),
	)
	_record(
		"native Vector2 column keeps its value check",
		_lines("Vector2", native, false) == _lines("Vector2", { }, false),
		_lines("Vector2", native, false),
	)
	_record(
		"plain enum column emits the int check",
		_lines("Holder.Kind", plain_enum, false) == _lines("int", { }, false),
		_lines("Holder.Kind", plain_enum, false),
	)
	_agree_compiled("plain enum", "", "Kind", "Holder.Kind", plain_enum, [0, 1, 2])
	# The walk finds no columns on Marker and compares it by identity: the same instance is
	# equal, two instances are not.
	var marker_prelude: String = "class Marker:\n\textends Resource\n\n\n"
	_agree_compiled("record with no columns", marker_prelude, "Marker", "Marker", unit, [])


# Compiles the `_eq` and `_row_eq` codegen emits for one column, declared [param column_type]
# after [param prelude] and routed as [param check_type] / [param type_def], into a row type,
# and holds both against the walk over every pair of [param values]. Empty [param values]
# stand for two instances of the prelude's Marker and null.
func _agree_compiled(
	label: String,
	prelude: String,
	column_type: String,
	check_type: String,
	type_def: Dictionary,
	values: Array,
) -> void:
	var generated: String = SpacetimeCodegen._generate_eq_gdscript(
		"Holder",
		SpacetimeCodegen._eq_check_lines("p_lhs.c", "p_rhs.c", check_type, type_def, false),
		SpacetimeCodegen._eq_check_lines("self.c", "p_rhs.c", check_type, type_def, false),
		true,
	)
	# Indented one level, so both functions land inside Holder as they do in a binding.
	var source: String = (
		"extends RefCounted\n\n\n%sclass Holder:\n\textends _ModuleTableType\n\tenum Kind { A, B, C }\n\t@export var c: %s\n"
		% [prelude, column_type]
		+ generated.replace("\n", "\n\t")
	)
	var script: GDScript = GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		_record("%s: emitted check compiles" % label, false, source)
		return
	var constants: Dictionary = script.get_script_constant_map()
	if values.is_empty():
		var marker: GDScript = constants["Marker"]
		values = [marker.new(), marker.new(), null]
	var holder: GDScript = constants["Holder"]
	var cols: Array[StringName] = [&"c"]
	var mismatches: PackedStringArray = []
	for i: int in values.size():
		for j: int in values.size():
			var lhs: _ModuleTableType = holder.new()
			var rhs: _ModuleTableType = holder.new()
			lhs.set(&"c", values[i])
			rhs.set(&"c", values[j])
			var walk: bool = LocalDatabase._rows_equal(lhs, rhs, cols)
			var eq: bool = holder.call(&"_eq", lhs, rhs)
			var row: bool = lhs._row_eq(rhs, cols)
			var row_back: bool = rhs._row_eq(lhs, cols)
			if eq != walk or row != walk or row_back != walk:
				mismatches.append(
					"%s vs %s: walk=%s _eq=%s _row_eq=%s reversed=%s"
					% [values[i], values[j], walk, eq, row, row_back]
				)
	_record(
		"%s: _eq and _row_eq agree with the walk on %d pairs"
		% [label, values.size() * values.size()],
		mismatches.is_empty(),
		"; ".join(mismatches),
	)
