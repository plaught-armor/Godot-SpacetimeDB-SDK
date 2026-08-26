# The generated surface of an enum-with-payload type, as `docs/api.md` teaches it: the
# module's type registry is the global `<Module>Types` class, variant tags live on the
# generated class's inner `Options` enum, and each variant has a `create_<variant>` /
# `get_<variant>` pair.
#
# The codec round-trip is covered by test_rust_enum_roundtrip.gd, which drives the tag
# field directly and so never touches any of the above. That left the accessor surface
# untested and let the documented example drift into two forms that cannot run:
# `SpacetimeDB.MyModule.Types.CharacterClass` (the module client has no `Types` member)
# and `cc.Warrior` (a named enum's values are not members of the instance). This pins
# what the docs now show.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_generated_enum_surface.gd
#
# The out-of-bounds parse_enum_name case prints the generated class's own complaint on
# stderr; that line is the assertion passing, not a failure.
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _check_registry()
	fails += _check_variant_tags()
	fails += _check_payload_accessors()
	fails += _check_tags_are_not_instance_members()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("FAILED %d of %d" % [fails, _total])
	quit(fails)


# The registry the docs name is a global class_name, and it hands back the same script
# the global row class does. `<Module>Types.<Type>` is the documented spelling.
func _check_registry() -> int:
	var fails: int = 0
	var from_registry: GDScript = BlackholioTypes.ProbeKind
	fails += _check_b("registry const resolves", from_registry != null, true)
	fails += _check_b(
		"registry const is the generated class",
		from_registry == BlackholioProbeKind,
		true,
	)
	# The other half of the same doc line: the registry is NOT reached through the module
	# client. Read off the script rather than an instance — the client is a Node, so an
	# instance made here would have to be freed, and the script's list already carries the
	# inherited SpacetimeDBClient properties this needs to see.
	#
	# Both member kinds are asked, because either would make the old doc form work again:
	# the property list carries declared `var`s only, and a registry handed out as
	# `const Types = ...` would sit in the constant map instead and pass a property-only
	# check. get_script_constant_map returns a BARE Dictionary, so the local stays untyped.
	var client_script: GDScript = BlackholioModuleClient
	var has_types: bool = false
	for prop: Dictionary in client_script.get_script_property_list():
		if prop.get("name", "") == "Types":
			has_types = true
			break
	var client_constants: Dictionary = client_script.get_script_constant_map()
	if client_constants.has(&"Types"):
		has_types = true
	fails += _check_b("module client exposes no `Types` member", has_types, false)
	return fails


# Each create_<variant> stamps the tag its inner Options entry carries.
func _check_variant_tags() -> int:
	var fails: int = 0
	var unit: BlackholioProbeKind = BlackholioProbeKind.create_unit()
	var scalar: BlackholioProbeKind = BlackholioProbeKind.create_scalar(7)
	var text: BlackholioProbeKind = BlackholioProbeKind.create_text("hi")

	fails += _check_i("create_unit tag", unit.value, BlackholioProbeKind.Options.unit)
	fails += _check_i("create_scalar tag", scalar.value, BlackholioProbeKind.Options.scalar)
	fails += _check_i("create_text tag", text.value, BlackholioProbeKind.Options.text)

	# The form the docs show for matching: the tag read off the instance's own Options.
	fails += _check_i("instance-qualified Options", scalar.value, scalar.Options.scalar)

	# parse_enum_name is the name side of the same table, and out of range is a named
	# fallback rather than an index fault.
	fails += _check_s("parse_enum_name(0)", BlackholioProbeKind.parse_enum_name(0), &"unit")
	fails += _check_s("parse_enum_name(2)", BlackholioProbeKind.parse_enum_name(2), &"text")
	fails += _check_s("parse_enum_name(99)", BlackholioProbeKind.parse_enum_name(99), &"Unknown")
	return fails


# get_<variant> returns the payload the matching create_<variant> took.
func _check_payload_accessors() -> int:
	var fails: int = 0
	var scalar: BlackholioProbeKind = BlackholioProbeKind.create_scalar(7)
	var text: BlackholioProbeKind = BlackholioProbeKind.create_text("hi")
	fails += _check_i("get_scalar payload", scalar.get_scalar(), 7)
	fails += _check_s("get_text payload", text.get_text(), "hi")
	# A unit variant carries nothing; the docs' pairing is per variant, not per class.
	var unit: BlackholioProbeKind = BlackholioProbeKind.create_unit()
	fails += _check_b("unit variant has no payload", unit.data == null, true)
	return fails


# The defect this file exists for: a named enum's values are reachable only through the
# enum, so the variant name is not a property of the instance. `cc.Warrior` reads as an
# invalid property access at runtime, which is what the old doc example did.
func _check_tags_are_not_instance_members() -> int:
	var fails: int = 0
	var scalar: BlackholioProbeKind = BlackholioProbeKind.create_scalar(7)
	fails += _check_b("variant name is not an instance member", &"scalar" in scalar, false)
	fails += _check_b("variant name is not a property", scalar.get("scalar") != null, false)
	return fails


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: expected %s, got %s" % [label, want, got])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: expected %d, got %d" % [label, want, got])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		return 0
	printerr('FAIL %s: expected "%s", got "%s"' % [label, want, got])
	return 1
