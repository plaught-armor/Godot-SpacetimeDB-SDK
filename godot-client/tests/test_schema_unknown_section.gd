# Guards what the schema parser does with a section it does not implement.
#
# The parser walks the v10 section list twice, and each pass is an if/elif chain with no
# final else. An unrecognised tag therefore matched nothing and the parse carried on with
# no trace. `Submodules` was the case that surfaced it — a module's submodule tables and
# reducers vanished from the generated bindings while the run still reported success, which
# reads as a codegen bug rather than an unimplemented feature. That section is implemented
# now, so the cases below use the ones that are still unread: `HttpHandlers` and
# `HttpRoutes` (both real `RawModuleDefV10Section` variants, neither with a client
# consumer). A submodule's OWN section list is walked too, so a section only a submodule
# carries is reported the same way rather than being the one that stays silent.
#
# Carrying on is still the right call: the SDK cannot invent a meaning for a section a
# newer server added, and refusing the whole schema would strand a client on a server it
# otherwise speaks to perfectly. What changed is that the skip is now recorded on the
# parsed schema (and logged), so a caller can tell it apart from a genuine fault.
#
# Builds minimal synthetic v10 schemas and runs the real parser.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_schema_unknown_section.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_known_schema_reports_no_skips()
	fails += _test_unknown_section_is_recorded()
	fails += _test_unknown_section_does_not_fail_the_parse()
	fails += _test_every_unknown_section_is_recorded_in_order()
	fails += _test_unknown_section_inside_a_submodule_is_recorded()
	fails += _test_handled_sections_is_locked()
	fails += _test_handled_sections_covers_what_the_parser_reads()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# One product type, one table over it, one reducer — enough that a parse which drops
# everything is distinguishable from one that carries on.
func _known_sections() -> Array:
	var row_type: Dictionary = {
		"Product": { "elements": [{ "name": { "some": "id" }, "algebraic_type": { "U64": [] } }] },
	}
	return [
		{ "Typespace": { "types": [row_type] } },
		{ "Types": [{ "source_name": { "scope": [], "source_name": "Widget" }, "ty": 0 }] },
		{
			"Tables": [
				{
					"source_name": "widget",
					"product_type_ref": 0,
					"primary_key": [0],
					"indexes": [],
					"constraints": [],
					"sequences": [],
					"table_type": { "User": [] },
					"table_access": { "Public": [] },
				},
			],
		},
		{
			"Reducers": [
				{
					"source_name": "add_widget",
					"params": { "elements": [] },
					# A reducer returning nothing still carries the unit product. An absent
					# key parses as an empty algebraic type and fails the whole schema.
					"ok_return_type": { "Product": { "elements": [] } },
					"err_return_type": { "String": [] },
				},
			],
		},
	]


# A section this SDK does not read. Real variant, no client consumer.
func _unknown_section() -> Dictionary:
	return { "HttpHandlers": [{ "source_name": "handle_thing" }] }


# Shaped like the real thing: RawSubmoduleV10 carries the namespace it is registered under
# and a whole nested module def. This one's sections include one the SDK does not read.
func _submodule_with_unknown_section() -> Dictionary:
	return {
		"Submodules": [{ "namespace": "lib", "module": { "sections": [{ "HttpRoutes": [] }] } }],
	}


func _parse(sections: Array) -> SpacetimeParsedSchema:
	return SpacetimeSchemaParser.parse_schema({ "sections": sections }, "test_mod")


func _test_known_schema_reports_no_skips() -> int:
	var f: int = 0
	var schema: SpacetimeParsedSchema = _parse(_known_sections())
	f += _check("nothing skipped", schema.skipped_sections.size(), 0)
	f += _check("the table parsed", schema.tables.size(), 1)
	f += _check("the reducer parsed", schema.reducers.size(), 1)
	return f


func _test_unknown_section_is_recorded() -> int:
	var f: int = 0
	var sections: Array = _known_sections()
	sections.append(_unknown_section())
	var schema: SpacetimeParsedSchema = _parse(sections)

	f += _check("one section skipped", schema.skipped_sections.size(), 1)
	f += _check_s("the skipped section is named", _at(schema.skipped_sections, 0), "HttpHandlers")
	# The point of carrying on: everything the SDK does understand is still generated.
	f += _check("the table still parsed", schema.tables.size(), 1)
	f += _check("the reducer still parsed", schema.reducers.size(), 1)
	return f


func _test_unknown_section_does_not_fail_the_parse() -> int:
	var f: int = 0
	var sections: Array = _known_sections()
	sections.append(_unknown_section())
	var schema: SpacetimeParsedSchema = _parse(sections)

	# `incomplete` gates codegen's pruning pass, so an unimplemented section must NOT set
	# it — a module that uses one would otherwise never prune a stale binding again.
	f += _check("the parse is not marked incomplete", schema.incomplete, false)
	return f


func _test_every_unknown_section_is_recorded_in_order() -> int:
	var f: int = 0
	var sections: Array = _known_sections()
	sections.append({ "HttpHandlers": [] })
	sections.append({ "HttpRoutes": [] })
	var schema: SpacetimeParsedSchema = _parse(sections)

	f += _check("both sections skipped", schema.skipped_sections.size(), 2)
	f += _check_s("first in wire order", _at(schema.skipped_sections, 0), "HttpHandlers")
	f += _check_s("second in wire order", _at(schema.skipped_sections, 1), "HttpRoutes")
	return f


# A submodule carries its own section list, and a section only IT carries used to be the
# one skip nothing could report — the submodule itself was skipped before its sections were
# ever looked at.
func _test_unknown_section_inside_a_submodule_is_recorded() -> int:
	var f: int = 0
	var sections: Array = _known_sections()
	sections.append(_submodule_with_unknown_section())
	var schema: SpacetimeParsedSchema = _parse(sections)

	f += _check("the submodule's own unread section is skipped", schema.skipped_sections.size(), 1)
	f += _check_s(
		"the submodule's unread section is named",
		_at(schema.skipped_sections, 0),
		"HttpRoutes",
	)
	f += _check("Submodules itself is not reported", schema.skipped_sections.has("Submodules"), false)
	return f


# One table shared by every parse in the process, so an accidental append during a later
# fix would silently change which sections count as known for the rest of the run.
func _test_handled_sections_is_locked() -> int:
	return _check(
		"the table is locked against mutation",
		SpacetimeSchemaParser.HANDLED_SECTIONS.is_read_only(),
		true,
	)


# The table is hand-maintained, so it can drift from the chains it describes: a section
# added to the parser but not to the table would be parsed AND reported as skipped. Every
# name in it must be one the parser actually reads.
func _test_handled_sections_covers_what_the_parser_reads() -> int:
	var f: int = 0
	var source: String = FileAccess.get_file_as_string(
		"res://addons/SpacetimeDB/codegen/schema_parser.gd"
	)
	f += _check("parser source readable", source.is_empty(), false)

	for tag: String in SpacetimeSchemaParser.HANDLED_SECTIONS:
		f += _check(
			'parser reads section "%s"' % tag,
			source.contains('section.has("%s")' % tag),
			true,
		)
	return f


# Reading past the end would abort the test run instead of failing the case, and a case
# that asserts on position N is exactly the one that runs when N is missing.
func _at(names: PackedStringArray, i: int) -> String:
	if i < 0 or i >= names.size():
		return ""
	return names[i]


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s, want %s" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr('FAIL  %s: got "%s", want "%s"' % [label, got, want])
	return 1
