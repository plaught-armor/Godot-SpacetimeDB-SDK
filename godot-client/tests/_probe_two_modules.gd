# Probe: two DIFFERENT generated modules driven at once in one process.
#
# The sixteenth pass ran two clients of the SAME module. This one runs clients whose
# schemas are different modules — the shape a game gets when one project talks to a lobby
# database and a match database, or to two modules that both happen to define a table
# called `entity`. Read-only reasoning said it holds (the schema filter believes each row
# script's `module_name`, class names are module-prefixed, the static caches are
# Script-keyed); nothing had driven it.
#
# The oracle that makes cross-talk visible: module Beta's `entity` row is laid out FLAT
# (entity_id, pos_x, pos_y, mass) where Blackholio's is (entity_id, position{x,y}, mass).
# A BSATN product is inline, so both row types decode the SAME bytes — and every decoded
# value can be compared across the two mirrors field by field. A mirror that picked up the
# other module's row type, or a plan cache keyed by anything but the script, shows up as a
# wrong class or a wrong number here rather than as "no rows".
#
# Beta and BetaExtra share one schema directory on purpose: that is what codegen actually
# produces for a two-module project (one `spacetime_bindings/schema`), and their names
# prefix each other, which is the case a filename prefix cannot separate.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_two_modules.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const CONFIG_FIXTURE: String = "res://tests/fixtures/wire_snapshot.bin"
const ENTITY_FIXTURE: String = "res://tests/fixtures/wire_snapshot_brotli.bin"
const TMP: String = "user://two_modules_schema"
const MAX_WAIT_FRAMES: int = 900

## Beta's `entity`: the same wire bytes as Blackholio's, flattened. A BSATN product type
## carries no tag and no length, so `position: DbVector2 {f32, f32}` and a pair of bare
## f32 columns are byte-identical — which is what lets one capture feed both row types.
const BETA_ENTITY: String = """extends _ModuleTableType

const module_name: String = "%s"
const table_names: Array[StringName] = [&"entity"]
const PRIMARY_KEY: StringName = &"entity_id"
const BSATN_TYPES: Dictionary[StringName, StringName] = {
	&"entity_id": &"i32", &"pos_x": &"f32", &"pos_y": &"f32", &"mass": &"i32",
}

@export var entity_id: int
@export var pos_x: float
@export var pos_y: float
@export var mass: int
"""

const BETA_CONFIG: String = """extends _ModuleTableType

const module_name: String = "%s"
const table_names: Array[StringName] = [&"config"]
const PRIMARY_KEY: StringName = &"id"
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"i32", &"world_size": &"i64" }

@export var id: int
@export var world_size: int
"""

## A table only this module declares. Nothing on the wire names it; it is here so the
## probe can say that a module's table set is its own.
const BETA_ONLY: String = """extends _ModuleTableType

const module_name: String = "%s"
const table_names: Array[StringName] = [&"beta_only"]
const PRIMARY_KEY: StringName = &"id"
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32" }

@export var id: int
"""

var _total: int = 0
var _fails: int = 0
var _server: TCPServer = TCPServer.new()
var _sides: Array[_Side] = []


## One client plus the server side of its socket.
class _Side:
	extends RefCounted

	var label: String
	var client: SpacetimeDBClient
	var peer: WebSocketPeer
	var stream: StreamPeerTCP
	var connected: int = 0


	func send(frames: Array[PackedByteArray]) -> void:
		for frame: PackedByteArray in frames:
			peer.put_packet(frame)
		peer.poll()


	func _on_connected(_identity: PackedByteArray, _token: String) -> void:
		connected += 1


	func rows(table: StringName) -> Array[_ModuleTableType]:
		var db: LocalDatabase = client.get_local_database()
		if db == null:
			return []
		return db.get_all_rows(table)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_write_fixtures()
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		quit(1)
		return

	# Blackholio comes from the committed res:// bindings — a real generated module, not a
	# fixture. Beta and BetaExtra share one directory, as codegen would write them.
	var a: _Side = await _stand_up("Blackholio", "res://spacetime_bindings/schema")
	var b: _Side = await _stand_up("Beta", TMP)
	var c: _Side = await _stand_up("BetaExtra", TMP)
	if a == null or b == null or c == null:
		printerr("could not stand up all three clients")
		_bail()
		return

	_check_int("Blackholio handshook once", a.connected, 1)
	_check_int("Beta handshook once", b.connected, 1)
	_check_int("BetaExtra handshook once", c.connected, 1)

	await _scenario_table_sets(a, b, c)
	await _scenario_same_table_different_rows(a, b, c)
	await _scenario_values_agree(a, b, c)
	await _scenario_one_module_leaves(a, b, c)

	for side: _Side in [a, b, c]:
		_tear_down(side)
	_server.stop()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


# Each client's schema must carry its own module's tables and nothing else — the static
# half of this is tests/test_schema_module_isolation.gd; here it is asserted on the schema
# a live client actually built for itself.
func _scenario_table_sets(a: _Side, b: _Side, c: _Side) -> void:
	_check_bool("Blackholio's db knows `entity`", _knows_table(a, &"entity"), true)
	_check_bool("Blackholio's db knows `player`", _knows_table(a, &"player"), true)
	_check_bool("Beta's db knows `beta_only`", _knows_table(b, &"beta_only"), true)
	_check_bool("Blackholio's db does not know `beta_only`", _knows_table(a, &"beta_only"), false)
	# BetaExtra declares only `entity`: the shared directory must not hand it Beta's tables
	# just because every Beta file is also prefixed `beta`.
	_check_bool("BetaExtra's db knows `entity`", _knows_table(c, &"entity"), true)
	_check_bool("BetaExtra did not inherit Beta's config", _knows_table(c, &"config"), false)
	_check_bool("BetaExtra did not inherit beta_only", _knows_table(c, &"beta_only"), false)
	# Blackholio's own tables must not have reached the fixture modules either, and they
	# share nothing but the directory their captures came from.
	_check_bool("Beta did not inherit Blackholio's player", _knows_table(b, &"player"), false)


# The same capture into three mirrors: each row must be its OWN module's row type.
func _scenario_same_table_different_rows(a: _Side, b: _Side, c: _Side) -> void:
	var entity: Array[PackedByteArray] = _load_frames(ENTITY_FIXTURE)
	var config: Array[PackedByteArray] = _load_frames(CONFIG_FIXTURE)
	for side: _Side in [a, b, c]:
		side.send(entity)
		side.send(config)
	await _settle()

	var expected: int = _expected_entity_rows()
	_check_bool("the capture carries entity rows at all", expected > 1, true)
	_check_int("Blackholio decoded every entity row", a.rows(&"entity").size(), expected)
	_check_int("Beta decoded every entity row", b.rows(&"entity").size(), expected)
	_check_int("BetaExtra decoded every entity row", c.rows(&"entity").size(), expected)

	_check_str(
		"Blackholio's rows are Blackholio's type",
		_row_class(a, &"entity"),
		"BlackholioEntity",
	)
	# The fixture row types declare no class_name (nothing in user:// is registered
	# project-wide), so the module constant is what names them.
	_check_str("Beta's rows are Beta's type", _row_module(b, &"entity"), "Beta")
	_check_str("BetaExtra's rows are BetaExtra's type", _row_module(c, &"entity"), "BetaExtra")
	_check_bool(
		"the three mirrors hold three different row scripts",
		_distinct_scripts([a, b, c], &"entity"),
		true,
	)

	# Beta declares `config`; Blackholio declares `config`; BetaExtra does not.
	_check_int("Blackholio applied the config row", a.rows(&"config").size(), 1)
	_check_int("Beta applied the config row", b.rows(&"config").size(), 1)
	_check_int("BetaExtra ignored a table it does not have", c.rows(&"config").size(), 0)
	_check_int("beta_only stayed empty", b.rows(&"beta_only").size(), 0)


# Field-by-field across two different row shapes decoding one capture. A plan cache that
# confused the two scripts would land here as a wrong number, not a missing row.
func _scenario_values_agree(a: _Side, b: _Side, _c: _Side) -> void:
	var blackholio: Dictionary[int, Vector3] = { }
	for row: _ModuleTableType in a.rows(&"entity"):
		var position: Resource = row.get(&"position")
		if position == null:
			continue
		blackholio[int(row.get(&"entity_id"))] = Vector3(
			float(position.get(&"x")),
			float(position.get(&"y")),
			float(row.get(&"mass")),
		)

	var matched: int = 0
	var mismatched: int = 0
	for row: _ModuleTableType in b.rows(&"entity"):
		var id: int = int(row.get(&"entity_id"))
		if not blackholio.has(id):
			mismatched += 1
			continue
		var want: Vector3 = blackholio[id]
		var got: Vector3 = Vector3(
			float(row.get(&"pos_x")),
			float(row.get(&"pos_y")),
			float(row.get(&"mass")),
		)
		if got.is_equal_approx(want):
			matched += 1
		else:
			mismatched += 1

	_check_int(
		"every Blackholio entity row decoded a position",
		blackholio.size(),
		a.rows(&"entity").size(),
	)
	_check_int("Beta's flat columns equal Blackholio's nested ones", matched, blackholio.size())
	_check_int("no Beta row disagreed with Blackholio", mismatched, 0)


# One module's client going away must not disturb the others.
func _scenario_one_module_leaves(a: _Side, b: _Side, c: _Side) -> void:
	var before: int = a.rows(&"entity").size()
	b.client.disconnect_db()
	await _settle()
	_check_bool("Blackholio is still connected", a.client.is_connected_db(), true)
	_check_bool("BetaExtra is still connected", c.client.is_connected_db(), true)
	_check_int("Blackholio kept its rows", a.rows(&"entity").size(), before)
	c.send(_load_frames(CONFIG_FIXTURE))
	await _settle()
	_check_int("Blackholio still applies traffic", a.rows(&"config").size(), 1)

# --- harness ---


func _stand_up(module: String, schema_path: String) -> _Side:
	var side: _Side = _Side.new()
	side.label = module
	_sides.append(side)
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.threading = true
	options.auto_reconnect = false
	options.one_time_token = false
	options.token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
	options.save_token = false

	side.client = SpacetimeDBClient.new()
	side.client.module_name = module
	side.client.schema_path = schema_path
	side.client.auto_connect = false
	side.client.name = "TwoModuleClient%s" % module
	root.add_child(side.client)
	side.client.connected.connect(side._on_connected)
	side.client.connect_db(
		"http://127.0.0.1:%d" % _server.get_local_port(),
		"probedb%s" % module.to_lower(),
		options,
	)

	var identity_sent: bool = false
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		_poll_peers()
		if side.peer == null and _server.is_connection_available():
			side.stream = _server.take_connection()
			side.peer = WebSocketPeer.new()
			side.peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			side.peer.outbound_buffer_size = 8 * 1024 * 1024
			if side.peer.accept_stream(side.stream) != OK:
				printerr("accept_stream failed for %s" % module)
				return null
		if side.peer == null:
			continue
		side.peer.poll()
		if side.peer.get_ready_state() == WebSocketPeer.STATE_OPEN and not identity_sent:
			identity_sent = true
			side.send(_load_frames(IDENTITY_FIXTURE))
		if side.connected > 0 and side.client.is_connected_db():
			return side
	return null


## Whether this client's LocalDatabase was built with [param table] — an unknown table
## reads the same as an empty one through get_all_rows, so ask the database itself.
## `_tables` is seeded from the schema's raw_table_names for every declared table, PK or
## not, and tests are exempt from the private-access gate.
func _knows_table(side: _Side, table: StringName) -> bool:
	var db: LocalDatabase = side.client.get_local_database()
	if db == null:
		return false
	return db._tables.has(table) or db._pk_less_tables.has(table)


## The `class_name` of whatever script this mirror's rows are, or "" if there are none.
func _row_class(side: _Side, table: StringName) -> String:
	var script: GDScript = _row_script(side, table)
	if script == null:
		return ""
	return String(script.get_global_name())


## The `module_name` constant the mirror's row script declares — how a fixture row type
## (which declares no class_name) names itself.
func _row_module(side: _Side, table: StringName) -> String:
	var script: GDScript = _row_script(side, table)
	if script == null:
		return ""
	return str(script.get_script_constant_map().get("module_name", ""))


func _row_script(side: _Side, table: StringName) -> GDScript:
	var rows: Array[_ModuleTableType] = side.rows(table)
	if rows.is_empty():
		return null
	return rows[0].get_script() as GDScript


func _distinct_scripts(sides: Array, table: StringName) -> bool:
	var seen: Array[GDScript] = []
	for side: _Side in sides:
		var script: GDScript = _row_script(side, table)
		if script == null or seen.has(script):
			return false
		seen.append(script)
	return true


func _settle() -> void:
	for _i: int in 120:
		await physics_frame
		_poll_peers()


func _poll_peers() -> void:
	for side: _Side in _sides:
		if side.peer != null:
			side.peer.poll()


func _tear_down(side: _Side) -> void:
	if side == null:
		return
	if is_instance_valid(side.client):
		side.client.disconnect_db()
		side.client.queue_free()
	if side.stream != null:
		side.stream.disconnect_from_host()


func _bail() -> void:
	for side: _Side in _sides:
		_tear_down(side)
	_server.stop()
	quit(1)


## The entity rows the capture carries, decoded offline by the SDK's own deserializer.
func _expected_entity_rows() -> int:
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	var rows: int = 0
	for frame: PackedByteArray in _load_frames(ENTITY_FIXTURE):
		var payload: PackedByteArray = DataDecompressor.decompress_brotli(frame.slice(1))
		for message: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			payload
		):
			if message is not SubscribeAppliedMessage:
				continue
			for table: TableUpdateData in message.tables:
				if table.table_name == &"entity":
					rows += table.inserts.size()
	return rows


func _load_frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while file.get_position() < file.get_length():
		var size: int = file.get_32()
		out.append(file.get_buffer(size))
	file.close()
	return out


## Two modules whose names prefix each other, written into ONE directory — what codegen
## produces for a two-module project.
func _write_fixtures() -> void:
	var types_dir: String = "%s/types" % TMP
	_rm_rf(TMP)
	DirAccess.make_dir_recursive_absolute(types_dir)
	_write("%s/beta_entity.gd" % types_dir, BETA_ENTITY % "Beta")
	_write("%s/beta_config.gd" % types_dir, BETA_CONFIG % "Beta")
	_write("%s/beta_only.gd" % types_dir, BETA_ONLY % "Beta")
	_write("%s/beta_extra_entity.gd" % types_dir, BETA_ENTITY % "BetaExtra")


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("could not write %s" % path)
		return
	file.store_string(text)
	file.close()


func _rm_rf(path: String, depth: int = 0) -> void:
	if depth > 4:
		return
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [path, file_name])
	for sub: String in dir.get_directories():
		_rm_rf("%s/%s" % [path, sub], depth + 1)
	DirAccess.remove_absolute(path)


func _check_int(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	_fails += 1


func _check_str(label: String, got: String, want: String) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	_fails += 1


func _check_bool(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1
