# Regression test: a ScheduleAt column is recognised by its TYPE, never by its name.
#
# Codegen used to decide a column was the `ScheduleAt` sum by asking whether it was
# called `scheduled_at`, which is wrong in both directions and reachable from ordinary
# module source:
#
#   * `#[table(accessor = job2, scheduled(run_job2, at = fire_at))]` puts the ScheduleAt
#     column under another name. It was typed `int` / BSATN `i64`, so the reader took
#     eight bytes where the row carries nine (a u8 tag + an i64) and every field after it
#     was read from the wrong offset. Measured against a live 2.8.0 server: "Attempted to
#     read 1536 bytes past end of buffer".
#   * An ordinary, unscheduled table is free to carry a column named `scheduled_at` — a
#     `Timestamp` say. It was typed `ScheduleAt`, and the reader ate the first byte of the
#     i64 as a sum tag: "Invalid ScheduleAt tag 143".
#
# Neither is a one-row problem. A row that fails to parse fails the whole packet, so the
# subscription never applied and the client's buffer was cleared — one such column takes
# down every table in the session.
#
# The parser now matches SpacetimeDB's own `SumType::is_schedule_at` (two variants,
# `Interval(TimeDuration)` then `Time(Timestamp)`) and hands codegen a type name, so the
# column's name has nothing to do with it.
#
# The `vsched` fixture is the real schema of a module published to SpacetimeDB 2.8.0
# carrying all three shapes: `job` (ScheduleAt named `scheduled_at`, the control),
# `job_2` (ScheduleAt named `fire_at`) and `plain` (a Timestamp named `scheduled_at`),
# plus a reducer taking a bare ScheduleAt argument.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_schedule_at_by_type.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vsched.json"
const MODULE: String = "vsched"
const TMP: String = "user://schedule_at_gen"

## Micros the wire-half rows carry. Distinct values so a field read at the wrong offset
## cannot coincidentally match, and large enough to occupy all eight bytes.
const PLAIN_MICROS: int = 1786046741683343
const JOB2_MICROS: int = 1786047719707073

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
	f += _test_codegen_types()
	f += _test_wire_shapes()
	return f

# --- Codegen half ---------------------------------------------------------------


func _test_codegen_types() -> int:
	var f: int = 0
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (json is Dictionary):
		printerr("FAIL  fixture is not a JSON object: %s" % FIXTURE)
		_total += 1
		return 1
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(json, MODULE, { })
	f += _check_b("fixture parses", not schema.is_empty(), true)

	# The fixture is only meaningful while the server keeps naming the renamed column
	# something else — a republish that lost the `at = fire_at` would make the job_2 half
	# a duplicate of the control and quietly stop testing anything.
	f += _check_b(
		"fixture: job_2's schedule column is not called scheduled_at",
		_field_names(schema, "Job2").has("fire_at"),
		true,
	)
	f += _check_b(
		"fixture: plain carries an unrelated column called scheduled_at",
		_field_names(schema, "Plain").has("scheduled_at"),
		true,
	)

	_reset_dir(TMP)
	DirAccess.make_dir_recursive_absolute("%s/types" % TMP)
	DirAccess.make_dir_recursive_absolute("%s/tables" % TMP)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(TMP)
	codegen._plugin_config = _build_config(MODULE)
	var written: int = codegen._generate_gdscript_from_schema(MODULE, schema).size()
	f += _check_b("codegen wrote files", written > 0, true)

	var job: String = FileAccess.get_file_as_string("%s/types/vsched_job.gd" % TMP)
	var job2: String = FileAccess.get_file_as_string("%s/types/vsched_job_2.gd" % TMP)
	var plain: String = FileAccess.get_file_as_string("%s/types/vsched_plain.gd" % TMP)

	# Control: the ordinary spelling still resolves to ScheduleAt.
	f += _check_b(
		"job.scheduled_at is a ScheduleAt",
		job.contains("@export var scheduled_at: ScheduleAt"),
		true,
	)
	f += _check_b(
		"job.scheduled_at reads as the sum",
		job.contains('&"scheduled_at": &"scheduled_at"'),
		true,
	)

	# The renamed schedule column.
	f += _check_b(
		"job_2.fire_at is a ScheduleAt",
		job2.contains("@export var fire_at: ScheduleAt"),
		true,
	)
	f += _check_b(
		"job_2.fire_at reads as the sum",
		job2.contains('&"fire_at": &"scheduled_at"'),
		true,
	)

	# The unrelated column that merely shares the name.
	f += _check_b(
		"plain.scheduled_at is an int",
		plain.contains("@export var scheduled_at: int"),
		true,
	)
	f += _check_b(
		"plain.scheduled_at reads as an i64",
		plain.contains('&"scheduled_at": &"i64"'),
		true,
	)

	# A ScheduleAt column is a Resource, so an `==` finder over it could never match; a
	# plain timestamp column is an int and gets one. The old code skipped `scheduled_at`
	# by name, which got both of these backwards.
	var plain_table: String = FileAccess.get_file_as_string("%s/tables/vsched_plain_table.gd" % TMP)
	var job_table: String = FileAccess.get_file_as_string("%s/tables/vsched_job_table.gd" % TMP)
	f += _check_b(
		"the timestamp column gets a typed finder",
		plain_table.contains("func find_by_scheduled_at("),
		true,
	)
	f += _check_b(
		"the ScheduleAt column gets none",
		job_table.contains("func find_by_scheduled_at("),
		false,
	)

	# The reducer-argument path resolves the same way, and it was wrong there too: the
	# name-based override only ever ran over struct fields, so a reducer taking a bare
	# ScheduleAt took an `int` and wrote eight bytes for a nine-byte argument.
	var reducers: String = FileAccess.get_file_as_string("%s/module_vsched_reducers.gd" % TMP)
	f += _check_b(
		"a ScheduleAt reducer argument is typed",
		reducers.contains("func take_sched(s: ScheduleAt"),
		true,
	)
	f += _check_b(
		"a ScheduleAt reducer argument is written as the sum",
		reducers.contains("[&'scheduled_at', &'string']"),
		true,
	)

	_rm_rf(TMP)
	return f

# --- Wire half: the bytes each shape actually carries ----------------------------


## Decodes a server-shaped row of each table through the same resource-populate path a
## generated row hits at runtime, using the BSATN types codegen now emits. Under the old
## mapping each of these rows failed: the plain one on the ScheduleAt tag, the job_2 one
## by reading eight bytes of a nine-byte value and taking the string length from the tail
## of the timestamp.
func _test_wire_shapes() -> int:
	var f: int = 0

	# plain: u64 id, i64 timestamp micros, string label.
	var plain_bytes: PackedByteArray = []
	plain_bytes.append_array(_u64(7))
	plain_bytes.append_array(_i64(PLAIN_MICROS))
	plain_bytes.append_array(_string("hello"))
	var plain_row: Object = _row(
		'{ &"id": &"u64", &"scheduled_at": &"i64", &"label": &"string" }',
		"@export var id: int\n@export var scheduled_at: int\n@export var label: String\n",
	)
	var d1: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb1: StreamPeerBuffer = _buffer(plain_bytes)
	var ok1: bool = d1._populate_resource_from_bytes(plain_row, spb1)
	f += _check_b("plain row decodes", ok1 and not d1.has_error(), true)
	f += _check_i("plain id", plain_row.id, 7)
	f += _check_i("plain timestamp micros", plain_row.scheduled_at, PLAIN_MICROS)
	f += _check_b("plain label", plain_row.label == "hello", true)
	f += _check_i("plain row consumed every byte", spb1.get_position(), plain_bytes.size())

	# job_2: u64 scheduled_id, ScheduleAt (u8 tag + i64), string note.
	var job2_bytes: PackedByteArray = []
	job2_bytes.append_array(_u64(5))
	job2_bytes.append(ScheduleAt.Kind.TIME)
	job2_bytes.append_array(_i64(JOB2_MICROS))
	job2_bytes.append_array(_string("note-a"))
	var job2_row: Object = _row(
		'{ &"scheduled_id": &"u64", &"fire_at": &"scheduled_at", &"note": &"string" }',
		"@export var scheduled_id: int\n@export var fire_at: ScheduleAt\n@export var note: String\n",
	)
	var d2: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb2: StreamPeerBuffer = _buffer(job2_bytes)
	var ok2: bool = d2._populate_resource_from_bytes(job2_row, spb2)
	f += _check_b("job_2 row decodes", ok2 and not d2.has_error(), true)
	f += _check_i("job_2 scheduled_id", job2_row.scheduled_id, 5)
	f += _check_b("job_2 fire_at is a ScheduleAt", job2_row.fire_at is ScheduleAt, true)
	f += _check_i("job_2 fire_at kind", job2_row.fire_at.kind, ScheduleAt.Kind.TIME)
	f += _check_i("job_2 fire_at micros", job2_row.fire_at.micros, JOB2_MICROS)
	f += _check_b("job_2 note", job2_row.note == "note-a", true)
	f += _check_i("job_2 row consumed every byte", spb2.get_position(), job2_bytes.size())

	# The same bytes under the OLD mapping, to tie this half to the fix: a name-based
	# codegen typed job_2's column `i64` and plain's column `scheduled_at`, and neither
	# reads the row the server sent.
	var old_job2: Object = _row(
		'{ &"scheduled_id": &"u64", &"fire_at": &"i64", &"note": &"string" }',
		"@export var scheduled_id: int\n@export var fire_at: int\n@export var note: String\n",
	)
	var d3: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb3: StreamPeerBuffer = _buffer(job2_bytes)
	d3._populate_resource_from_bytes(old_job2, spb3)
	f += _check_b(
		"reading the ScheduleAt column as an i64 does not recover the row",
		d3.has_error() or old_job2.note != "note-a",
		true,
	)
	var old_plain: Object = _row(
		'{ &"id": &"u64", &"scheduled_at": &"scheduled_at", &"label": &"string" }',
		"@export var id: int\n@export var scheduled_at: ScheduleAt\n@export var label: String\n",
	)
	var d4: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb4: StreamPeerBuffer = _buffer(plain_bytes)
	d4._populate_resource_from_bytes(old_plain, spb4)
	f += _check_b(
		"reading a timestamp column as a ScheduleAt does not recover the row",
		d4.has_error() or old_plain.label != "hello",
		true,
	)

	# The nine-vs-eight byte difference is the whole defect: price both row lengths so a
	# future change to either side cannot make the two shapes the same size.
	# plain:  8 (u64) + 8 (i64) + 4 + 5 (string "hello")  = 25
	# job_2:  8 (u64) + 1 + 8 (ScheduleAt) + 4 + 6 ("note-a") = 27
	f += _check_i("the timestamp row is 25 bytes", plain_bytes.size(), 25)
	f += _check_i("the ScheduleAt row is 27 bytes", job2_bytes.size(), 27)
	return f

# --- Helpers --------------------------------------------------------------------


## A row script built at runtime rather than committed: these two exist to pin one
## mapping each, and a committed `.gd` under tests/ is parsed as a project script.
func _row(bsatn_types: String, fields: String) -> Object:
	var script: GDScript = GDScript.new()
	script.source_code = (
		"extends Resource\nconst BSATN_TYPES: Dictionary = %s\n%s" % [bsatn_types, fields]
	)
	var err: Error = script.reload()
	if err != OK:
		printerr("row script failed to compile: %d" % err)
		return null
	return script.new()


func _buffer(bytes: PackedByteArray) -> StreamPeerBuffer:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	return spb


func _u64(v: int) -> PackedByteArray:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u64(v)
	return spb.data_array


func _i64(v: int) -> PackedByteArray:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_64(v)
	return spb.data_array


## BSATN string: u32 little-endian length, then the utf8 bytes.
func _string(v: String) -> PackedByteArray:
	var utf8: PackedByteArray = v.to_utf8_buffer()
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(utf8.size())
	var out: PackedByteArray = spb.data_array
	out.append_array(utf8)
	return out


func _field_names(schema: SpacetimeParsedSchema, type_name: String) -> PackedStringArray:
	var names: PackedStringArray = []
	for type_def: Dictionary in schema.types:
		if type_def.get("name", "") != type_name:
			continue
		for field: Dictionary in type_def.get("struct", []):
			names.append(field.get("name", ""))
	return names


func _build_config(module: String) -> SpacetimeDBPluginConfig:
	var cfg: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var mc: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	mc.name = module
	mc.hide_private_tables = false
	mc.hide_scheduled_reducers = false
	cfg.module_configs[module] = mc
	return cfg


func _reset_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		_rm_rf(path)
	DirAccess.make_dir_recursive_absolute(path)


func _rm_rf(path: String, depth: int = 0) -> void:
	if depth > 8:
		return
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var entry: String = d.get_next()
	while not entry.is_empty():
		var child: String = "%s/%s" % [path, entry]
		if d.current_is_dir():
			_rm_rf(child, depth + 1)
		else:
			DirAccess.remove_absolute(child)
		entry = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s, want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %d, want %d" % [label, got, want])
	return 1
