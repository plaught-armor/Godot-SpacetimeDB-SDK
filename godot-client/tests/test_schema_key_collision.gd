# Unit test for table lookup when two table names differ only by an underscore.
#
# `SpacetimeDBSchema.types` is keyed by name.to_lower().replace("_", ""). The strip is
# load-bearing for nested columns — a column typed `VsumShape` has to find the file that
# declares it, `vsum_shape.gd` — but it is lossy, and `user_data` / `userdata` are both
# legal SpacetimeDB table names that collapse onto one entry. Before `tables` got its own
# exact key, the second one to load silently displaced the first, so its rows decoded
# against the wrong row type and `_get_primary_key_field` handed back the wrong column:
# every insert for that table looked like an update of a row that did not exist.
#
# The fixtures under tests/fixtures/schema_key_collision/types/ stand in for generated
# row types — the registry only reads `table_names` / `PRIMARY_KEY` / the storage
# properties off a script, so they need no codegen and no global class_name.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_schema_key_collision.gd
extends SceneTree

const FIXTURE_PATH: String = "res://tests/fixtures/schema_key_collision"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_both_tables_survive()
	f += _test_primary_keys_do_not_cross()
	f += _test_get_table_does_not_guess()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _make_registry() -> SpacetimeDBSchema:
	# debug_mode off: the collision warning is not what is under test here, and the
	# registry prints it either way.
	return SpacetimeDBSchema.new("vunder", FIXTURE_PATH, false)


func _test_both_tables_survive() -> int:
	var f: int = 0
	var registry: SpacetimeDBSchema = _make_registry()

	# Keyed by the exact wire name, so neither displaces the other.
	f += _check("user_data registered", registry.tables.has(&"user_data"), true)
	f += _check("userdata registered", registry.tables.has(&"userdata"), true)

	var user_data: GDScript = registry.get_table(&"user_data")
	var userdata: GDScript = registry.get_table(&"userdata")
	f += _check("user_data resolves", user_data != null, true)
	f += _check("userdata resolves", userdata != null, true)
	f += _check("the two are different scripts", user_data != userdata, true)
	f += _check_s(
		"user_data -> its own file",
		user_data.resource_path.get_file(),
		"vunder_user_data.gd",
	)
	f += _check_s(
		"userdata -> its own file",
		userdata.resource_path.get_file(),
		"vunder_userdata.gd",
	)
	return f


func _test_primary_keys_do_not_cross() -> int:
	# The consequence that made this worth fixing: LocalDatabase resolves the PK column
	# through the schema, so a displaced table got the other table's primary key.
	var f: int = 0
	var registry: SpacetimeDBSchema = _make_registry()
	var db: LocalDatabase = LocalDatabase.new(registry)

	f += _check_s("user_data PK", db._get_primary_key_field(&"user_data"), "id")
	f += _check_s("userdata PK", db._get_primary_key_field(&"userdata"), "other_id")

	# Row properties come off the same lookup and must not cross either.
	var user_data_props: Array[StringName] = db._get_row_properties(&"user_data")
	var userdata_props: Array[StringName] = db._get_row_properties(&"userdata")
	f += _check("user_data has id", user_data_props.has(&"id"), true)
	f += _check("user_data lacks other_id", user_data_props.has(&"other_id"), false)
	f += _check("userdata has other_id", userdata_props.has(&"other_id"), true)
	f += _check("userdata lacks id", userdata_props.has(&"id"), false)

	db.free() # LocalDatabase is a Node; nothing parents this one (C13)
	return f


func _test_get_table_does_not_guess() -> int:
	# get_table answers only from the exact-keyed table map. Falling back to the
	# normalized `types` key would hand back whichever colliding script loaded last —
	# the very answer this fix removes — so a miss has to stay a miss.
	var f: int = 0
	var registry: SpacetimeDBSchema = _make_registry()

	# A non-table type (no `table_names` const) is in `types` under its filename alias
	# but must not be reachable as a table.
	f += _check("non-table type is in types", registry.types.has(&"vunderplain"), true)
	f += _check("non-table type is not a table", registry.get_table(&"vunder_plain") == null, true)

	# The shape the fallback would have gotten wrong: `user_data` absent from `tables`
	# must NOT resolve to the `userdata` script just because the stripped keys agree.
	registry.tables.erase(&"user_data")
	f += _check("miss does not fall through", registry.get_table(&"user_data") == null, true)

	f += _check("unknown name still null", registry.get_table(&"nope_not_here") == null, true)
	return f


func _check(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1


func _check_s(label: String, got: StringName, want: String) -> int:
	_total += 1
	if String(got) == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got '%s' want '%s'" % [label, got, want])
	return 1
