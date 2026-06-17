# Unit test for SpacetimeCodegen._gd_type_from_nested — the codegen helper that
# maps a nested-wrapper list to a GDScript field type. Guards the fix that emits
# Array[Array] (not an untyped Array) for two-level array nesting, which is what
# lets BSATNDeserializer._read_array resolve a typed element reader.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_nested_array_type.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	# No wrapper → the base type passes through.
	fails += _check("scalar", SpacetimeCodegen._gd_type_from_nested([], "int"), "int")
	# Single Array wrapper → typed Array[T].
	fails += _check("vec", SpacetimeCodegen._gd_type_from_nested(["Array"], "int"), "Array[int]")
	# Two Array wrappers → Array[Array] (GDScript can't express Array[Array[int]]).
	fails += _check("vec_vec", SpacetimeCodegen._gd_type_from_nested(["Array", "Array"], "int"), "Array[Array]")
	# Array of Option → Array[Option].
	fails += _check("vec_opt", SpacetimeCodegen._gd_type_from_nested(["Array", "Option"], "int"), "Array[Option]")
	# Bare Option → Option.
	fails += _check("opt", SpacetimeCodegen._gd_type_from_nested(["Option"], "int"), "Option")

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1
