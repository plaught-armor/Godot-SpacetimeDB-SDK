# Unit test for the codegen-time duplicate-member gate.
#
# Every name escape in codegen.gd guarantees its result is free on the BASE class, but
# none of them can see a SIBLING that escaped to the same string: a module with a
# reducer `set` (escaped to `set_`, because `Object.set` is taken) and a reducer
# literally named `set_` emits `func set_()` twice. Godot then refuses the script —
# "Parse Error: Function "set_" has the same name as a previously declared function",
# verified against 4.8.dev — and since a module's reducers all live in one class, every
# reducer in the module goes down with it. `find_duplicate_members` turns that into a
# codegen-time error naming the file and the identifier.
#
# Two layers:
#   1. SpacetimeCodegen.find_duplicate_members — the pure scan over emitted source.
#   2. End-to-end: the real generator over tests/fixtures/vcollide.json (reducers `set`
#      and `set_`) must produce a file the scan flags, and a normal fixture must not.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_member_collision_gate.gd
extends SceneTree

const FIXTURE_DIR: String = "res://tests/fixtures"
const TMP_ROOT: String = "user://collision_gate_gen"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_scan()
	f += _test_generated_collision()
	f += _test_autoload_alias_collision()
	f += _test_clean_module()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_scan() -> int:
	var f: int = 0

	# The shape this gate exists for: two reducers landing on one method.
	f += _check_one(
		"duplicate func",
		"class_name X extends RefCounted\n\n\nfunc set_() -> void:\n\tpass\n\n\nfunc set_() -> void:\n\tpass\n",
		"set_",
	)
	# The column-side equivalent, which is an @export var on the row type.
	f += _check_one(
		"duplicate @export var",
		"class_name R extends Resource\n@export var count_: int = 0\n@export var count_: int = 0\n",
		"count_",
	)
	# A var against a func of the same name is just as fatal, and just as invisible
	# to the per-site escapes.
	f += _check_one(
		"var vs func",
		"class_name X extends RefCounted\nvar iter_: int = 0\nfunc iter_() -> void:\n\tpass\n",
		"iter_",
	)
	f += _check_one("duplicate const", "const A: int = 1\nconst A: int = 2\n", "A")
	f += _check_one(
		"duplicate signal",
		"signal changed(a: int)\nsignal changed(b: int)\n",
		"changed",
	)
	f += _check_one("duplicate static var", "static var T: int = 1\nstatic var T: int = 2\n", "T")
	f += _check_one(
		"duplicate static func",
		"static func make() -> void:\n\tpass\nstatic func make() -> void:\n\tpass\n",
		"make",
	)
	f += _check_one("duplicate enum", "enum Kind { A }\nenum Kind { B }\n", "Kind")

	# Reported once, however many times it repeats — one error per name, not per hit.
	var thrice: PackedStringArray = SpacetimeCodegen.find_duplicate_members(
		"var x: int = 0\nvar x: int = 1\nvar x: int = 2\n"
	)
	f += _check_i("triple occurrence reported once", thrice.size(), 1)

	# Locals are not members: the same name in two function bodies is legal, and a
	# scan that flagged it would fail every real binding.
	f += _check_empty(
		"indented locals",
		"func a() -> void:\n\tvar row: int = 0\n\nfunc b() -> void:\n\tvar row: int = 1\n",
	)
	# Header lines declare no member — `class_name` in particular must not read as a
	# `class` declaration.
	f += _check_empty(
		"header lines",
		"@tool\nclass_name Thing\nextends Resource\n## doc\n# comment\n",
	)
	f += _check_empty(
		"distinct members",
		"@export var a: int = 0\nvar b: int = 0\nfunc c() -> void:\n\tpass\n",
	)

	return f


func _test_generated_collision() -> int:
	var f: int = 0
	var files: PackedStringArray = _generate("vcollide")
	if files.is_empty():
		return f + _fail("vcollide: generator produced no files")

	var flagged: Dictionary[String, PackedStringArray] = { }
	for path: String in files:
		var dups: PackedStringArray = SpacetimeCodegen.find_duplicate_members(
			FileAccess.get_file_as_string(path)
		)
		if not dups.is_empty():
			flagged[path.get_file()] = dups

	f += _check_i("vcollide: exactly one file flagged", flagged.size(), 1)
	var reducers: String = "module_vcollide_reducers.gd"
	f += _check("vcollide: the reducers file is the one flagged", flagged.has(reducers), true)
	if flagged.has(reducers):
		f += _check("vcollide: `set_` is the duplicate", flagged[reducers].has("set_"), true)
	return f


## The autoload is emitted from the configured module ALIASES, PascalCased with no
## escape applied — so two aliases that differ only in how they are spelled
## (`my_module` / `myModule`) both become `var MyModule`. Nothing in the alias-handling
## path can catch that; the scan over the emitted file is what does.
func _test_autoload_alias_collision() -> int:
	var f: int = 0
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new("%s/autoload" % TMP_ROOT)

	var colliding: PackedStringArray = ["myModule", "my_module"]
	var dups: PackedStringArray = SpacetimeCodegen.find_duplicate_members(
		codegen._generate_autoload_gdscript(colliding)
	)
	f += _check("autoload: colliding aliases flagged", dups.has("MyModule"), true)

	var distinct: PackedStringArray = ["blackholio", "my_module"]
	var clean: PackedStringArray = SpacetimeCodegen.find_duplicate_members(
		codegen._generate_autoload_gdscript(distinct)
	)
	f += _check("autoload: distinct aliases clean", clean.is_empty(), true)
	return f


func _test_clean_module() -> int:
	# A fixture with no colliding names must stay silent — a scan that flags ordinary
	# output would block every codegen run.
	var f: int = 0
	var files: PackedStringArray = _generate("vtypes")
	if files.is_empty():
		return f + _fail("vtypes: generator produced no files")

	for path: String in files:
		var dups: PackedStringArray = SpacetimeCodegen.find_duplicate_members(
			FileAccess.get_file_as_string(path)
		)
		f += _check("vtypes: %s clean" % path.get_file(), dups.is_empty(), true)
	return f


func _generate(module: String) -> PackedStringArray:
	var fixture_path: String = "%s/%s.json" % [FIXTURE_DIR, module]
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	if not (json is Dictionary):
		_fail("%s: fixture missing or not a JSON object" % module)
		return PackedStringArray()

	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(json, module, { })
	var tmp: String = "%s/%s" % [TMP_ROOT, module]
	DirAccess.make_dir_recursive_absolute("%s/types" % tmp)
	DirAccess.make_dir_recursive_absolute("%s/tables" % tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = module
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	config.module_configs[module] = module_config
	codegen._plugin_config = config
	return codegen._generate_gdscript_from_schema(module, schema)


func _check_one(label: String, source: String, want: String) -> int:
	var got: PackedStringArray = SpacetimeCodegen.find_duplicate_members(source)
	_total += 1
	if got.size() == 1 and got[0] == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want [%s]" % [label, got, want])
	return 1


func _check_empty(label: String, source: String) -> int:
	var got: PackedStringArray = SpacetimeCodegen.find_duplicate_members(source)
	_total += 1
	if got.is_empty():
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — expected no duplicates, got %s" % [label, got])
	return 1


func _check(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %d want %d" % [label, got, want])
	return 1


func _fail(message: String) -> int:
	_total += 1
	printerr("FAIL  %s" % message)
	return 1
