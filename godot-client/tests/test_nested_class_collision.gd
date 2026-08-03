# Unit test for nested column types whose class names normalize to the same string.
#
# Sibling of test_schema_key_collision.gd: that one covers TABLE names, this one covers
# the other half of the same lossy key. `SpacetimeDBSchema.types` is keyed by
# name.to_lower().replace("_", ""), and a module with types `FooBar` and `Foobar`
# generates `VnestFooBar` (in vnest_foo_bar.gd) and `VnestFoobar` (in vnest_foobar.gd) —
# both of which normalize to `vnestfoobar` on both the class-name and the filename side.
# The second to load displaced the first, so a column typed `VnestFooBar` decoded as
# `VnestFoobar`: wrong fields, wrong values, no error.
#
# A nested column names its type by the exact `class_name` spelling — a BSATN_TYPES entry
# reads `&"shape": &"VsumShape"`, and an @export var's class_name hint is the same string
# — and Godot already enforces those are unique project-wide, so the registry keys them
# that way now.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_nested_class_collision.gd
extends SceneTree

const FIXTURE_PATH: String = "res://tests/fixtures/nested_class_collision"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_the_normalized_key_really_does_collide()
	f += _test_class_name_key_keeps_them_apart()
	f += _test_nested_decode_picks_the_right_type()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _make_registry() -> SpacetimeDBSchema:
	return SpacetimeDBSchema.new("vnest", FIXTURE_PATH, false)


func _test_the_normalized_key_really_does_collide() -> int:
	# Pins the reason the class-name key exists. If normalization ever stops collapsing
	# these two, this failing is the signal to revisit — not a regression by itself.
	var f: int = 0
	var registry: SpacetimeDBSchema = _make_registry()

	var normalized: GDScript = registry.get_type(&"vnestfoobar")
	f += _check("both fixtures share one normalized key", normalized != null, true)
	f += _check("the collided key exists", registry.types.has(&"vnestfoobar"), true)
	f += _check("no separate key for the other", registry.types.has(&"vnestfoo_bar"), false)
	return f


func _test_class_name_key_keeps_them_apart() -> int:
	var f: int = 0
	var registry: SpacetimeDBSchema = _make_registry()

	var foo_bar: GDScript = registry.get_type_by_class(&"VnestFooBar")
	var foobar: GDScript = registry.get_type_by_class(&"VnestFoobar")
	f += _check("VnestFooBar resolves", foo_bar != null, true)
	f += _check("VnestFoobar resolves", foobar != null, true)
	f += _check("they are different scripts", foo_bar != foobar, true)
	f += _check_s(
		"VnestFooBar -> its own file",
		foo_bar.resource_path.get_file(),
		"vnest_foo_bar.gd",
	)
	f += _check_s("VnestFoobar -> its own file", foobar.resource_path.get_file(), "vnest_foobar.gd")
	f += _check("an unknown class stays null", registry.get_type_by_class(&"Nope") == null, true)

	# The plan lowercases BSATN_TYPES values before resolving them, so most lookups
	# arrive without their original casing. That form is enough for every ordinary type
	# — but not for these two, and refusing to answer beats answering with the wrong one.
	# (This prints a Godot error; that is the point.)
	f += _check(
		"the lowercased form of a colliding pair refuses to guess",
		registry.get_type_by_class(&"vnestfoobar") == null,
		true,
	)
	return f


func _test_nested_decode_picks_the_right_type() -> int:
	# The consequence, on the real path: _read_value_from_bsatn_type resolves a nested
	# column by the BSATN_TYPES spelling, which is the class name.
	var f: int = 0
	var registry: SpacetimeDBSchema = _make_registry()
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(registry, false)

	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(99)
	spb.seek(0)

	var decoded: Variant = deserializer._read_value_from_bsatn_type(
		spb,
		&"VnestFooBar",
		&"nested_column",
	)
	f += _check("decode produced something", decoded != null, true)
	# Identified by script rather than `is VnestFooBar`: tests/fixtures carries a
	# .gdignore, so these class names are never registered globally and cannot be named
	# statically here. That is deliberate — fixtures must not add project-wide symbols —
	# and the registry reads their declared names off the script either way.
	if decoded != null:
		var obj: Object = decoded
		var script: GDScript = obj.get_script()
		f += _check_s(
			"decoded as the right type",
			script.resource_path.get_file(),
			"vnest_foo_bar.gd",
		)
		f += _check_s("and it knows its own name", String(script.get_global_name()), "VnestFooBar")
		f += _check_i("the field decoded", obj.get(&"which"), 99)
	f += _check("no deserializer error", deserializer.has_error(), false)
	return f


func _check(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got '%s' want '%s'" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %d want %d" % [label, got, want])
	return 1
