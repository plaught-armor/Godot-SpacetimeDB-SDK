# Regression test: one module's schema must not pick up another module's row types.
#
# SpacetimeDBSchema selects a module's generated scripts by FILENAME prefix, and a
# filename prefix cannot separate two modules whose names prefix each other: `game` and
# `game_extra` both emit files that begin `game_`, so module `game`'s schema loaded
# `game_extra_user.gd` too. Both scripts legitimately declare the table `user`, so
# `tables[&"user"]` kept whichever loaded last (directory order) and rows for one
# module's table decoded against the other module's row type; `raw_table_names` carried
# the name twice on top of that. The row type declares which module it came from, so
# that constant decides now.
#
# Fixtures are written at runtime rather than committed: they have to sit in a directory
# laid out like `spacetime_bindings/schema`, and committed .gd files under tests/ would
# be parsed by the editor as project scripts.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_schema_module_isolation.gd
extends SceneTree

const TMP: String = "user://schema_module_isolation"

## A row type as codegen emits one: `module_name` names the module, `table_names` the
## wire tables. Both modules below declare the same table name, which is legal — they
## are different databases.
const ROW: String = """extends _ModuleTableType

const module_name: String = "%s"
const table_names: Array[StringName] = [&"user"]
const PRIMARY_KEY: StringName = &"id"
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u64" }

@export var id: int = 0
"""

## A sum-type payload as codegen emits one: no `module_name`, no `table_names`. It names
## no table, so it cannot collide — and it has to stay loadable, since a nested column
## resolves its type through this registry.
const PAYLOAD: String = """extends RustEnum

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"circle": &"u32" }
"""

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	_write_fixtures()
	f += _test_module_sees_only_its_own_rows("game")
	f += _test_module_sees_only_its_own_rows("game_extra")
	f += _test_payload_still_loads()
	f += _test_unrelated_module_is_empty()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_module_sees_only_its_own_rows(module: String) -> int:
	var f: int = 0
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new(module, TMP, false)
	var row: GDScript = schema.get_table(&"user")

	f += _check("%s: table user resolves" % module, row != null, true)
	if row != null:
		var constants: Dictionary = row.get_script_constant_map()
		f += _check(
			"%s: table user is this module's row type" % module,
			str(constants.get("module_name", "")),
			module,
		)
	# The duplicate is what made the foreign registration visible downstream:
	# LocalDatabase builds its tables from this list.
	f += _check("%s: table name registered once" % module, schema.raw_table_names.size(), 1)
	return f


func _test_payload_still_loads() -> int:
	# Declares no module_name, so the module filter must not touch it.
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("game", TMP, false)
	return _check("payload type still registered", schema.get_type(&"gameshape") != null, true)


func _test_unrelated_module_is_empty() -> int:
	# A module with no files of its own sees no tables — the filename prefix already
	# separated this case, and the module filter must not have widened it.
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("chat", TMP, false)
	return _check("unrelated module has no tables", schema.raw_table_names.size(), 0)


func _write_fixtures() -> void:
	var types_dir: String = "%s/types" % TMP
	_rm_rf(TMP)
	DirAccess.make_dir_recursive_absolute(types_dir)
	_write("%s/game_user.gd" % types_dir, ROW % "game")
	_write("%s/game_extra_user.gd" % types_dir, ROW % "game_extra")
	_write("%s/game_shape.gd" % types_dir, PAYLOAD)


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


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
