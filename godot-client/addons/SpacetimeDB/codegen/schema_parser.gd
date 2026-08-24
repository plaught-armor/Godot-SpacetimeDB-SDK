class_name SpacetimeSchemaParser

const GDNATIVE_PRIMITIVE_TYPES: Dictionary[String, String] = {
	"I8": "int",
	"I16": "int",
	"I32": "int",
	"I64": "int",
	"U8": "int",
	"U16": "int",
	"U32": "int",
	"U64": "int",
	"F32": "float",
	"F64": "float",
	"String": "String",
	"Bool": "bool",
	"Nil": "null", # For Option<()>
}
const GDNATIVE_ARRAYLIKE_TYPES: Dictionary[String, String] = {
	"Vector4": "Vector4",
	"Vector4I": "Vector4i",
	"Vector3": "Vector3",
	"Vector3I": "Vector3i",
	"Vector2": "Vector2",
	"Vector2I": "Vector2i",
	"Quaternion": "Quaternion",
	"Color": "Color",
}
const GDNATIVE_DICTLIKE_TYPES: Dictionary[String, String] = {
	"Plane": "Plane",
}
## Type name stood up for the ScheduleAt sum. Not a wire name the server sends — the sum
## is anonymous — so it is spelled like the magic wrapper element names it sits beside in
## the type maps, and cannot collide with a module's own type (a Rust/C# identifier
## cannot look like this).
const SCHEDULE_AT_TYPE_NAME: String = "__schedule_at__"
const DEFAULT_TYPE_MAP: Dictionary[String, String] = {
	"__identity__": "PackedByteArray",
	"__schedule_at__": "ScheduleAt",
	"__connection_id__": "PackedByteArray",
	"__uuid__": "PackedByteArray",
	"__timestamp_micros_since_unix_epoch__": "int",
	"__time_duration_micros__": "int",
	"U128": "PackedByteArray",
	"I128": "PackedByteArray",
	"U256": "PackedByteArray",
	"I256": "PackedByteArray",
}
const DEFAULT_META_TYPE_MAP: Dictionary[String, String] = {
	"I8": "i8",
	"I16": "i16",
	"I32": "i32",
	"I64": "i64",
	"U8": "u8",
	"U16": "u16",
	"U32": "u32",
	"U64": "u64",
	"U128": "u128",
	"I128": "i128",
	"U256": "u256",
	"I256": "i256",
	"F32": "f32",
	"F64": "f64",
	"String": "string", # For BSATN, e.g. option_string or vec_String (if Option<Array<String>>)
	"Bool": "bool", # For BSATN, e.g. option_bool
	"Nil": "nil", # For BSATN Option<()>
	"Vector4": "vector4", # For BSATN, e.g. vector4[f32,f32,f32,f32]
	"Vector4I": "vector4i", # For BSATN, e.g. vector4i[i32,i32,i32,i32]
	"Vector3": "vector3", # For BSATN, e.g. vector3[f32,f32,f32]
	"Vector3I": "vector3i", # For BSATN, e.g. vector3i[i32,i32,i32]
	"Vector2": "vector2", # For BSATN, e.g. vector2[f32,f32]
	"Vector2I": "vector2i", # For BSATN, e.g. vector2i[i32,i32]
	"Quaternion": "quaternion", # For BSATN, e.g. quaternion[f32,f32,f32,f32]
	"Color": "color", # For BSATN, e.g. color[f32,f32,f32,f32]
	"__identity__": "identity",
	"__connection_id__": "connection_id",
	# Uuid is Product { __uuid__: u128 } — wire-identical to u128 (16 bytes, reversed
	# on read yields canonical UUID byte order). Reuse the u128 reader/writer.
	"__uuid__": "u128",
	"__timestamp_micros_since_unix_epoch__": "i64",
	"__time_duration_micros__": "i64",
	# The ScheduleAt sum: u8 tag + i64, read by BSATNDeserializer.read_scheduled_at.
	"__schedule_at__": "scheduled_at",
}


## Every schema-v10 section this parser reads, across both of its passes. A section
## outside this set is skipped — the two passes below are [code]if[/code]/[code]elif[/code]
## chains with no final [code]else[/code], so an unrecognized tag simply matches nothing
## and the parse carries on.
## That is the intended handling of a section a newer server added: the SDK cannot invent
## a meaning for it, and refusing the whole schema over one would strand a client on a
## server it otherwise speaks to perfectly.
##
## What it must not be is silent: a section's tables and reducers falling out of the
## generated bindings with no message reads as a codegen bug rather than an unimplemented
## feature. Anything not listed here gets named in the log, and the walk that reports it
## descends into submodules, so a section only a submodule carries is named too.
##
## [code]Array[String][/code] rather than the [code]PackedStringArray[/code] the element
## type would otherwise ask for, and [code]static var[/code] rather than [code]const[/code].
## One table shared by every parse in the process is exactly what wants locking, and
## [method Array.make_read_only] is the only lock the engine offers — [code]Packed*Array[/code]
## has no such method, and a [code]const[/code] [code]Packed*Array[/code] reads back empty
## on the Godot versions this addon supports (engine issue #88753). The membership check
## below runs once per section per parse, so the packed container's access win is worth
## nothing here and the enforcement is worth having.
static var HANDLED_SECTIONS: Array[String] = [
	"ExplicitNames",
	"LifeCycleReducers",
	"Procedures",
	"Reducers",
	"Schedules",
	"Submodules",
	"Tables",
	"Typespace",
	"Types",
	"ViewPrimaryKeys",
	"Views",
]


static func _static_init() -> void:
	if not HANDLED_SECTIONS.is_read_only():
		HANDLED_SECTIONS.make_read_only()


static func _sort_by_ty(a: Dictionary, b: Dictionary) -> bool:
	return a.get("ty", -1) < b.get("ty", -1)


# Server schema sections are HashMap-backed, so iteration order varies between
# publishes. Sorting the parsed output lists by their stable "name" key makes the
# generated bindings byte-for-byte reproducible across machines and regenerations.
# Names are unique within each list, so the strict `<` required by sort_custom
# (engine bug #58878 — never `<=`) never sees equal keys.
static func _sort_by_name(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("name", "")) < String(b.get("name", ""))


static func _sort_by_constraint_name(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("constraint_name", "")) < String(b.get("constraint_name", ""))


static func _find_type_index(type_name: String, parsed_types_list: Array[Dictionary]) -> int:
	for i: int in parsed_types_list.size():
		if parsed_types_list[i].name == type_name:
			return i
	return -1


## Returns the index of the struct field with [param field_name], or -1 if absent.
static func _find_struct_field_index(struct_fields: Array, field_name: String) -> int:
	for i: int in struct_fields.size():
		if struct_fields[i].get("name", "") == field_name:
			return i
	return -1


# First key of [param d] without allocating its keys() Array — dicts iterate in
# insertion order, so the first yielded key is keys()[0]. For the String-keyed
# schema dicts parsed here (tagged-union tags, lifecycle specs).
static func _first_key(d: Dictionary) -> String:
	for k: String in d:
		return k
	return ""

# NOTE: the synthesized names ("ResultI32String" and friends) are effectively
# RESERVED — a user type declared with the same spelling collides, and the flush
# below appends over it rather than yielding.
# Synthesized sum types for anonymous inline `Result<T, E>` columns, accumulated by
# _parse_field_type during a parse and flushed into the type list afterward. Anonymous
# inline sums (the only ones are Option — handled separately — and Result) have no named
# Typespace entry, so we synthesize a named RustEnum-style type per distinct Result<T, E>
# and let the regular enum-with-payload codegen + BSATN path handle it. Keyed by the
# synthesized bare type name (e.g. "ResultI32String"); reset at the start of each parse.
static var _synth_result_types: Dictionary = { }


## The one spelling every generated name is built from: the module key put through
## [method String.to_pascal_case] EXACTLY ONCE.
##
## `to_pascal_case` is not idempotent — it splits on case boundaries, so a name whose
## segments are single letters comes back with consecutive capitals that a second pass
## re-splits differently: `a-b` (a legal SpacetimeDB database name — `parse_database_name`
## accepts [a-z0-9] with single interior hyphens) gives `AB`, and `AB` gives `Ab`.
## Applying it twice therefore produced two different prefixes inside one run: the
## nested-column type map and the `<Prefix>Types` class said `AB…`, while every emitted
## `class_name` said `Ab…`, and the autoload declared a client class no file wrote.
## Nothing reported it — the run completed, so the pruning pass then deleted the previous,
## working bindings.
##
## Anything deriving a name from the module — a class name, a file name, the autoload
## property — goes through here or through [member SpacetimeParsedSchema.module], which is
## this function's result. Never re-apply the transform to a value that has had it.
static func module_class_prefix(module_key: String) -> String:
	return module_key.to_pascal_case()


## One entry per module in a v10 schema: the root first, then every submodule beneath it,
## depth-first in the order the server sent them. A submodule (SpacetimeDB 2.8.1+) is not a
## flattened list of extra tables — it carries a WHOLE nested module def, with its own
## [code]Typespace[/code], [code]Types[/code], [code]Tables[/code], [code]Reducers[/code]
## and [code]ExplicitNames[/code] — so every per-module lookup below has to be built per
## module rather than once for the schema.
##
## [code]type_offset[/code] is where a module's types land once every module's typespace is
## concatenated into the single list the rest of the parser indexes. Each nested typespace
## numbers its own types from zero, so the offset is what keeps a submodule's
## [code]Ref(0)[/code] pointing at the submodule's type instead of the root's — bind those
## to the wrong type and rows decode as whatever sits at the same index up top, silently.
## See [code]docs/submodules.md[/code].
static func _flatten_modules(root: Dictionary) -> Array[Dictionary]:
	var modules: Array[Dictionary] = []
	_collect_module(root, PackedStringArray(), modules, { })
	var offset: int = 0
	for module: Dictionary in modules:
		module["type_offset"] = offset
		offset += int(module["type_count"])
	return modules


## How deep submodules may nest. The schema is an HTTP response from something that may be
## a newer server, a proxy, or a truncated stream, and a walk over it with no ceiling ends
## a malformed one by exhausting the GDScript call stack rather than by reporting it — the
## same reason [constant _PARSE_FIELD_TYPE_MAX_DEPTH] exists for the type walk. Real
## namespaces nest a handful of levels at most.
const MAX_SUBMODULE_DEPTH: int = 16


## [param seen_namespaces] is shared across the whole walk, keyed by the joined namespace
## path. The server registers submodules BY namespace, so a healthy one never sends two
## under one path; two that did arrive would take each other's generated identifiers and —
## worse — register one wire name for two different row types, which routes a table update
## into the wrong row script.
static func _collect_module(
	module: Dictionary,
	module_namespace: PackedStringArray,
	out: Array[Dictionary],
	seen_namespaces: Dictionary,
	depth: int = 0,
) -> void:
	var sections: Array = module.get("sections", [])
	# Summed, not overwritten: the content pass APPENDS every Typespace section it finds,
	# so an offset taken from only the last of two would under-count and shift every later
	# module's type refs.
	var type_count: int = 0
	for section: Dictionary in sections:
		if section.has("Typespace"):
			type_count += section["Typespace"].get("types", []).size()
	out.append({ "namespace": module_namespace, "sections": sections, "type_count": type_count, "type_offset": 0 })

	if depth >= MAX_SUBMODULE_DEPTH:
		SpacetimePlugin.print_err(
			"Invalid schema: submodules nested deeper than %d levels at '%s'. Anything below that is skipped."
			% [MAX_SUBMODULE_DEPTH, _namespace_label(module_namespace)]
		)
		return

	for section: Dictionary in sections:
		if not section.has("Submodules"):
			continue
		for submodule: Dictionary in section["Submodules"]:
			var ns: String = submodule.get("namespace", "")
			if ns.is_empty():
				SpacetimePlugin.print_err(
					"Invalid schema: a submodule of '%s' has no namespace; its tables and "
					% _namespace_label(module_namespace)
					+ "reducers cannot be addressed and are skipped."
				)
				continue
			var child: PackedStringArray = module_namespace.duplicate()
			child.append(ns)
			var path: String = ".".join(child)
			if seen_namespaces.has(path):
				SpacetimePlugin.print_err(
					"Invalid schema: two submodules are registered under '%s'. Only the first "
					% path
					+ "is generated; the second's tables and reducers are skipped."
				)
				continue
			seen_namespaces[path] = true
			# A submodule entry carries a whole module def. Without one there is nothing to
			# read, and saying so is what keeps the skip from reading later as a codegen
			# fault: every table it would have declared is simply absent.
			var nested: Variant = submodule.get("module", null)
			if not (nested is Dictionary):
				SpacetimePlugin.print_err(
					"Invalid schema: the submodule registered under '%s' carries no module "
					% path
					+ "definition. Its tables and reducers are skipped."
				)
				continue
			_collect_module(nested, child, out, seen_namespaces, depth + 1)


## A namespace path for a message — the root module reads as "the root module" rather than
## as an empty string.
static func _namespace_label(module_namespace: PackedStringArray) -> String:
	return "the root module" if module_namespace.is_empty() else ".".join(module_namespace)


## Returns [param value] with every [code]Ref[/code] in it moved up by [param offset].
## Walks the whole algebraic type — a Ref hides inside Product elements, Sum variants,
## Array element types and Option payloads, at any depth.
##
## Copies rather than mutates: the schema dictionary is the caller's, and a parse that
## rewrote it in place would leave the second parse of the same schema (the plugin parses
## once per configured module) reading indices already shifted once.
static func _offset_type_refs(value: Variant, offset: int, depth: int = 0) -> Variant:
	# Same ceiling, and for the same reason, as _parse_field_type's: this walks an
	# algebraic type of arbitrary nesting that arrived over HTTP.
	#
	# What makes the bail safe is THIS report, not anything downstream. A Ref left
	# unrewritten is a small index read against the concatenated list, so it lands in
	# bounds on another module's type and binds silently — the bounds check in
	# _parse_field_type does not catch it. The error below is what marks the parse
	# incomplete, which is what makes codegen discard the whole module. Never weaken it on
	# the assumption that a later check covers this.
	if depth > _PARSE_FIELD_TYPE_MAX_DEPTH:
		SpacetimePlugin.print_err(
			"_offset_type_refs recursion exceeded %d levels; aborting" % _PARSE_FIELD_TYPE_MAX_DEPTH
		)
		return value
	if value is Array:
		var out_array: Array = []
		for element: Variant in value:
			out_array.append(_offset_type_refs(element, offset, depth + 1))
		return out_array
	if value is Dictionary:
		var out_dict: Dictionary = { }
		for key: Variant in value:
			var entry: Variant = value[key]
			if key == "Ref" and (entry is int or entry is float):
				out_dict[key] = int(entry) + offset
			else:
				out_dict[key] = _offset_type_refs(entry, offset, depth + 1)
		return out_dict
	return value


## The dotted prefix the server registers a submodule's tables and reducers under —
## [code]"lib."[/code], [code]"auth.baz."[/code], empty for the root module. Namespaces
## nest, so a name can carry more than one dot, and the SQL parser rejoins every leading
## part into one catalog name rather than treating them as qualification. The segments are
## spelled exactly as the module declared them; this is a wire name, not an identifier.
static func _namespace_wire_prefix(module_namespace: PackedStringArray) -> String:
	if module_namespace.is_empty():
		return ""
	return ".".join(module_namespace) + "."


## The prefix that makes a submodule's name a legal, unique GDScript identifier —
## [code]"lib_"[/code], [code]"auth_baz_"[/code], empty for the root module. A dot cannot
## appear in an identifier, so the generated class, file and member names carry the
## namespace this way while the wire name keeps its dots.
static func _namespace_identifier_prefix(module_namespace: PackedStringArray) -> String:
	if module_namespace.is_empty():
		return ""
	var parts: PackedStringArray = []
	for segment: String in module_namespace:
		parts.append(segment.to_snake_case())
	return "_".join(parts) + "_"


## The prefix for a submodule TYPE's name — [code]"Lib"[/code], [code]"AuthBaz"[/code].
## Type names are already PascalCase and become a [code]class_name[/code] verbatim, so the
## namespace joins them in the same case rather than through an underscore.
static func _namespace_type_prefix(module_namespace: PackedStringArray) -> String:
	var prefix: String = ""
	for segment: String in module_namespace:
		prefix += segment.to_pascal_case()
	return prefix


## A submodule's type name with its namespace joined on, so two modules that each declare a
## `Point` become two distinct GDScript classes rather than one that silently wins.
##
## A name the SDK maps to an engine type is left alone: those are matched BY NAME
## ([code]Vector3[/code], [code]Color[/code], the [code]__identity__[/code] family), so a
## namespaced spelling would drop a submodule's `Vector3` column back to a generated struct.
static func _qualified_type_name(type_prefix: String, type_name: String) -> String:
	if type_prefix.is_empty() or _is_gd_native(type_name) or DEFAULT_TYPE_MAP.has(type_name):
		return type_name
	return type_prefix + type_name


static func parse_schema(schema: Dictionary, module_name: String, project_enums: Dictionary = { }) -> SpacetimeParsedSchema:
	_synth_result_types.clear()
	# Every "reported it and carried on" path in this parser — a table whose row type did
	# not resolve, an index column out of range, a view with an unsupported return type —
	# leaves the schema describing only PART of the module, and codegen's pruning pass
	# DELETES the bindings for whatever went missing. Snapshotting the plugin's error tally
	# around the parse is what tells the caller that happened, without every site having to
	# remember to set a flag.
	var errors_before: int = SpacetimePlugin.error_count
	var type_map: Dictionary[String, String] = DEFAULT_TYPE_MAP.duplicate() as Dictionary[String, String]
	type_map.merge(GDNATIVE_PRIMITIVE_TYPES)
	type_map.merge(GDNATIVE_ARRAYLIKE_TYPES)
	type_map.merge(GDNATIVE_DICTLIKE_TYPES)
	var meta_type_map: Dictionary = DEFAULT_META_TYPE_MAP.duplicate()

	var schema_tables: Array = []
	var schema_types_raw: Array = []
	var schema_reducers: Array = []
	var typespace: Array = []
	var misc_exports: Array = []

	if not schema.has("sections"):
		SpacetimePlugin.print_err("Schema v10 required (missing 'sections'). Please update SpacetimeDB to 2.1.0+.")
		return SpacetimeParsedSchema.new()

	# Walked before any module is parsed, so the report reaches the log even if a later
	# section makes the parse bail. Each section dict carries exactly one tag key. The walk
	# descends into submodules: a section only a submodule carries would otherwise be the one
	# case that stays silent.
	var modules: Array[Dictionary] = _flatten_modules(schema)
	var skipped_sections: PackedStringArray = []
	for module: Dictionary in modules:
		var module_namespace: String = ".".join(module["namespace"])
		for section: Dictionary in module["sections"]:
			var tag: String = _first_key(section)
			if not tag.is_empty() and not HANDLED_SECTIONS.has(tag):
				skipped_sections.append(tag)
				SpacetimePlugin.print_log(
					(
						"Schema section '%s'%s is not supported by this SDK version and was skipped. "
						+ "Whatever it declares — tables, reducers — is absent from the generated "
						+ "bindings. Everything else in the schema was generated normally."
					)
					% [
						tag,
						"" if module_namespace.is_empty() else " in submodule '%s'" % module_namespace,
					]
				)

	for module: Dictionary in modules:
		var module_namespace: PackedStringArray = module["namespace"]
		var type_offset: int = int(module["type_offset"])
		# Three spellings of the same namespace, because three different things are named from
		# it. The wire prefix keeps the dots the server registers the def under
		# ("lib.lib_data"); the identifier prefix is what a class, file or member name can
		# actually be spelled with ("lib_lib_data"); the type prefix joins a PascalCase type
		# name ("LibLibPoint"). All three are empty for the root module, so a schema without
		# submodules parses to exactly what it did before they existed.
		var wire_prefix: String = _namespace_wire_prefix(module_namespace)
		var identifier_prefix: String = _namespace_identifier_prefix(module_namespace)
		var type_prefix: String = _namespace_type_prefix(module_namespace)

		# Every Ref in this module's sections moved into the shared typespace at once, not
		# just the ones in its Typespace. A Ref reaches a reducer's params, a procedure's or
		# a view's return type as well, and all of them index the module's OWN typespace —
		# rewriting only the type definitions would leave a submodule reducer's `Ref(0)`
		# parameter resolving to the root's first type.
		var sections: Array = module["sections"]
		if type_offset > 0:
			sections = _offset_type_refs(sections, type_offset)

		# Per module, not per schema: each nested module def carries its own ExplicitNames,
		# LifeCycleReducers, Schedules and ViewPrimaryKeys, and a source name is unique only
		# within the module that declared it.
		var lifecycle_map: Dictionary = { } # function_name -> lifecycle spec key
		var schedules_by_table: Dictionary = { } # table source_name -> schedule dict
		var canonical_names: Dictionary = { } # source_name -> canonical_name
		var view_pk_by_view: Dictionary = { } # view source_name -> primary key column name

		# First pass: extract lifecycle, schedules, and explicit names
		for section: Dictionary in sections:
			if section.has("LifeCycleReducers"):
				for lc: Dictionary in section["LifeCycleReducers"]:
					var fn_name: String = lc.get("function_name", "")
					var spec: Dictionary = lc.get("lifecycle_spec", { })
					if not fn_name.is_empty() and not spec.is_empty():
						lifecycle_map[fn_name] = _first_key(spec)
			elif section.has("Schedules"):
				for sched: Dictionary in section["Schedules"]:
					var tbl: String = sched.get("table_name", "")
					if not tbl.is_empty():
						schedules_by_table[tbl] = {
							"reducer_name": sched.get("function_name", ""),
							"schedule_at_col": sched.get("schedule_at_col", 0),
						}
			elif section.has("ExplicitNames"):
				for entry: Dictionary in section["ExplicitNames"].get("entries", []):
					var mapping: Dictionary = entry.get("Table", entry.get("Function", entry.get("Index", { })))
					if not mapping.is_empty():
						canonical_names[mapping.get("source_name", "")] = mapping.get("canonical_name", "")
			elif section.has("ViewPrimaryKeys"):
				# Schema V10 (SpacetimeDB 2.2.0+): primary keys for procedural views.
				# Single-column only for now; columns is a Vec to allow future composites.
				for vpk: Dictionary in section["ViewPrimaryKeys"]:
					var view_src: String = vpk.get("view_source_name", "")
					var pk_cols: Array = vpk.get("columns", [])
					if not view_src.is_empty() and not pk_cols.is_empty():
						view_pk_by_view[view_src] = String(pk_cols[0])

		# Second pass: extract content sections
		for section: Dictionary in sections:
			if section.has("Typespace"):
				# Appended, never assigned: every module's types share the one list the rest
				# of the parser indexes, in the same depth-first order the offsets above were
				# handed out.
				typespace.append_array(section["Typespace"].get("types", []))
			elif section.has("Types"):
				for td: Dictionary in section["Types"]:
					var src: String = td.get("source_name", { }).get("source_name", "")
					var ty_raw: Variant = td.get("ty", -1)
					var ty_idx: int = int(ty_raw) if (ty_raw is int or ty_raw is float) else -1
					if ty_idx >= 0:
						ty_idx += type_offset
					# source_name rides along for the project-enum match further down, which
					# compares against the name the module declared, not the namespaced one.
					schema_types_raw.append({
						"name": { "name": _qualified_type_name(type_prefix, src) },
						"source_name": src,
						"namespace": module_namespace,
						"ty": ty_idx,
					})
			elif section.has("Tables"):
				for td: Dictionary in section["Tables"]:
					var src: String = td.get("source_name", "")
					# canonical_name is the name the server registers the table/reducer under and
					# uses on the wire (TableUpdate identifiers, reducer-call lookup). source_name is
					# only the original Rust spelling. Verified live: reducers resolve ONLY by
					# canonical (e.g. insert_one_u_128, not insert_one_u128).
					var canonical: String = canonical_names.get(src, src)
					var indexes: Array = []
					for idx: Dictionary in td.get("indexes", []):
						indexes.append({ "name": idx.get("source_name", { "some": null }), "accessor_name": idx.get("accessor_name", { "some": null }), "algorithm": idx.get("algorithm", { }) })
					var constraints: Array = []
					for con: Dictionary in td.get("constraints", []):
						constraints.append({ "name": con.get("source_name", { "some": null }), "data": con.get("data", { }) })
					var ref_raw: Variant = td.get("product_type_ref", -1)
					var ref_idx: int = int(ref_raw) if (ref_raw is int or ref_raw is float) else -1
					if ref_idx >= 0:
						ref_idx += type_offset
					var tbl: Dictionary = {
						"name": identifier_prefix + canonical,
						"wire_name": wire_prefix + canonical,
						"namespace": module_namespace,
						"local_name": canonical,
						"product_type_ref": ref_idx,
						"primary_key": td.get("primary_key", []),
						"indexes": indexes,
						"constraints": constraints,
						"sequences": td.get("sequences", []),
						"table_type": td.get("table_type", { "User": [] }),
						"table_access": td.get("table_access", { "Public": [] }),
						"is_event": td.get("is_event", false),
					}
					if schedules_by_table.has(src):
						tbl["schedule"] = { "some": schedules_by_table[src] }
					elif schedules_by_table.has(canonical):
						tbl["schedule"] = { "some": schedules_by_table[canonical] }
					schema_tables.append(tbl)
			elif section.has("Reducers"):
				for rd: Dictionary in section["Reducers"]:
					var src: String = rd.get("source_name", "")
					var canonical: String = canonical_names.get(src, src)
					var r: Dictionary = {
						"name": identifier_prefix + canonical,
						"wire_name": wire_prefix + canonical,
						"namespace": module_namespace,
						"local_name": canonical,
						"params": rd.get("params", { }),
						"ok_return_type": rd.get("ok_return_type", { }),
					}
					if lifecycle_map.has(src) or lifecycle_map.has(canonical):
						r["lifecycle"] = { "some": lifecycle_map.get(src, lifecycle_map.get(canonical, "")) }
					else:
						r["lifecycle"] = { "some": null }
					schema_reducers.append(r)
			elif section.has("Procedures"):
				for pd: Dictionary in section["Procedures"]:
					var src: String = pd.get("source_name", "")
					var canonical: String = canonical_names.get(src, src)
					misc_exports.append({
						"Procedure": {
							"name": identifier_prefix + canonical,
							"wire_name": wire_prefix + canonical,
							"namespace": module_namespace,
							"local_name": canonical,
							"params": pd.get("params", { }),
							"return_type": pd.get("return_type", { }),
						},
					})
			elif section.has("Views"):
				for vd: Dictionary in section["Views"]:
					var src: String = vd.get("source_name", "")
					var canonical: String = canonical_names.get(src, src)
					# ViewPrimaryKeys keys by view source name, so look up by src (not canonical name).
					var view_pk_name: String = view_pk_by_view.get(src, "")
					misc_exports.append({
						"View": {
							"name": identifier_prefix + canonical,
							"wire_name": wire_prefix + canonical,
							"namespace": module_namespace,
							"local_name": canonical,
							"return_type": vd.get("return_type", { }),
							"primary_key_name": view_pk_name,
						},
					})
	schema_types_raw.sort_custom(_sort_by_ty)
	var parsed_schema: SpacetimeParsedSchema = SpacetimeParsedSchema.new()
	parsed_schema.module = module_class_prefix(module_name)
	parsed_schema.skipped_sections = skipped_sections

	var parsed_types_list: Array[Dictionary] = []
	for type_info: Dictionary in schema_types_raw:
		var type_name: String = type_info.get("name", { }).get("name", null)
		if not type_name:
			SpacetimePlugin.print_err("Invalid schema: Type name not found for type: %s" % type_info)
			return parsed_schema
		# The namespace rides along so codegen can tell a name a submodule brought into the
		# module from one the module always had — the two collide differently, and only the
		# first is this feature's to refuse.
		var type_data: Dictionary = {
			"name": type_name,
			"namespace": type_info.get("namespace", PackedStringArray()),
			"source_name": type_info.get("source_name", type_name),
		}
		if _is_gd_native(type_name):
			_set_gd_native(type_name, type_data)

		var ty_idx: int = int(type_info.get("ty", -1))
		# `< 0` (not just `== -1`): any negative would otherwise index typespace from
		# the tail via Godot's negative-index rule and read the wrong type definition.
		if ty_idx < 0:
			SpacetimePlugin.print_err("Invalid schema: Type 'ty' missing/negative for type: %s" % type_info)
			return parsed_schema
		if ty_idx >= typespace.size():
			SpacetimePlugin.print_err("Invalid schema: Type index %d out of bounds for typespace (size %d) for type %s" % [ty_idx, typespace.size(), type_name])
			return parsed_schema

		var current_type_definition: Dictionary = typespace[ty_idx]
		var struct_def: Dictionary = current_type_definition.get("Product", { })
		var sum_type_def: Dictionary = current_type_definition.get("Sum", { })
		if struct_def:
			var struct_elements: Array[Dictionary] = []
			for el: Dictionary in struct_def.get("elements", []):
				# A product element carries an OPTIONAL name (sats `ProductTypeElement.name`
				# is `Option<RawIdentifier>`), and everything downstream — the @export var,
				# the BSATN_TYPES key, the primary-key lookup — spells that name into a
				# String. An unnamed one used to reach `var pk_field_name: String =
				# ...struct[i].name` as a null and fault there, which unwound the parse to a
				# null return and took the module's whole binding set with it. Refuse the
				# schema instead: a column that cannot be named cannot be generated, and the
				# server forbids one on a table outright ("has unnamed column, which is
				# forbidden").
				if not (el.get("name", { }).get("some") is String):
					SpacetimePlugin.print_err(
						(
							"Invalid schema: type '%s' has an element with no name, which "
							+ "cannot be generated. Element: %s"
						)
						% [type_name, el]
					)
					return parsed_schema
				var data: Dictionary = {
					"name": el.get("name", { }).get("some", null),
				}
				var type: String = _parse_field_type(el.get("algebraic_type", { }), data, schema_types_raw)
				if not type.is_empty():
					data["type"] = type
				struct_elements.append(data)
			type_data["struct"] = struct_elements

			if not type_data.has("gd_native"):
				type_map[type_name] = module_class_prefix(module_name) + type_name.to_pascal_case()
				meta_type_map[type_name] = module_class_prefix(module_name) + type_name.to_pascal_case()
			elif not _validate_gd_native(type_name, type_data):
				# Error should be printed in _validate_gd_native
				return parsed_schema
			parsed_types_list.append(type_data)
		elif sum_type_def:
			var parsed_variants: Array[Dictionary] = []
			type_data["is_sum_type"] = _is_sum_type(sum_type_def)
			for v: Dictionary in sum_type_def.get("variants", []):
				var variant_data: Dictionary = { "name": v.get("name", { }).get("some", null) }
				var type: String = _parse_field_type(v.get("algebraic_type", { }), variant_data, schema_types_raw)
				if not type.is_empty():
					variant_data["type"] = type
				parsed_variants.append(variant_data)
			type_data["enum"] = parsed_variants
			parsed_types_list.append(type_data)

			if not type_data.get("is_sum_type"):
				meta_type_map[type_name] = "u8"
				# Matched against the name the module declared: a submodule's enum carries a
				# namespace prefix in `type_name` that a project enum has no way to spell.
				var declared_name: String = type_info.get("source_name", type_name)
				var pascal_name: String = declared_name if project_enums.has(declared_name) else declared_name.to_pascal_case()
				if project_enums.has(pascal_name):
					var project_enum: Dictionary = project_enums[pascal_name]
					var schema_variants: Array[String] = []
					for v: Dictionary in parsed_variants:
						schema_variants.append(v.get("name", "").to_snake_case())
					var project_variants: Array[String] = []
					for pv: String in project_enum["variants"]:
						project_variants.append(pv.to_snake_case())
					if schema_variants == project_variants:
						type_map[type_name] = project_enum["path"]
						type_data["project_enum"] = project_enum["path"]
						SpacetimePlugin.print_log("Enum '%s' matched project enum '%s'" % [pascal_name, project_enum["path"]])
					else:
						type_map[type_name] = "%sTypes.%s" % [module_class_prefix(module_name), pascal_name]
						SpacetimePlugin.print_log("Enum '%s' found in project as '%s' but variants differ, generating standalone" % [pascal_name, project_enum["path"]])
				else:
					type_map[type_name] = "%sTypes.%s" % [module_class_prefix(module_name), pascal_name]
			else:
				type_map[type_name] = module_class_prefix(module_name) + type_name.to_pascal_case()
				meta_type_map[type_name] = module_class_prefix(module_name) + type_name.to_pascal_case()
		else:
			if not type_data.has("gd_native"):
				if type_map.has(type_name) and not _is_gd_native(type_name):
					type_data["struct"] = []
					parsed_types_list.append(type_data)
				else:
					SpacetimePlugin.print_log("Type '%s' has no Product/Sum definition in typespace and is not GDNative. Skipping." % type_name)

	# Flush synthesized Result<T, E> types so codegen emits them (as RustEnum subclasses)
	# and fields referencing them resolve a type_idx below. Done after the main type loop
	# so all inline Results encountered while parsing fields/variants are included.
	for synth_name: String in _synth_result_types:
		parsed_types_list.append(_synth_result_types[synth_name])
		var synth_class: String = module_class_prefix(module_name) + synth_name.to_pascal_case()
		type_map[synth_name] = synth_class
		meta_type_map[synth_name] = synth_class

	for parsed_type: Dictionary in parsed_types_list:
		if not parsed_type.has("struct"):
			continue

		for field_type: Dictionary in parsed_type.get("struct", []):
			var type_name = field_type.get("type", null)
			if not type_name or GDNATIVE_PRIMITIVE_TYPES.has(type_name) or DEFAULT_TYPE_MAP.has(type_name):
				continue

			var type_idx: int = _find_type_index(type_name, parsed_types_list)
			if type_idx >= 0:
				field_type["type_idx"] = type_idx

	var parsed_tables_list: Array[Dictionary] = []
	var scheduled_reducers: Array[String] = []
	for table_info: Dictionary in schema_tables:
		var table_name_str: String = table_info.get("name", "")
		var ref_idx_raw: Variant = table_info.get("product_type_ref", -1)
		# Both of these used to `continue` without a word. Every OTHER skip in this loop
		# reports first, and the report is what marks the parse incomplete — which is what
		# stops codegen writing a module short of a table and the pruning pass deleting
		# that table's previous bindings. Measured on the vtypes fixture: one
		# `product_type_ref: null` generated 17 files instead of 19 with no error at all,
		# so the table wrapper and its unique-index accessor (plus their `.uid` sidecars)
		# were deleted by a run that reported success.
		if table_name_str.is_empty():
			SpacetimePlugin.print_err(
				(
					"Table entry has no name (product_type_ref %s). Nothing can be generated "
					+ "for it."
				)
				% str(ref_idx_raw)
			)
			continue
		# A ref that is not a number cannot index anything. -1 is what an ABSENT key
		# already becomes, and it falls through to the invalid-type report below, so a
		# null / string / object ref takes that same path rather than a silent skip.
		var ref_idx: int = -1
		if ref_idx_raw is int or ref_idx_raw is float:
			ref_idx = int(ref_idx_raw)

		var original_type_name_for_table: String = "UNKNOWN_TYPE_FOR_TABLE"
		# Lower-bound guard: a negative ref would index from the tail via Godot's
		# negative-index rule and silently bind the table to the wrong row type.
		if ref_idx >= 0 and ref_idx < schema_types_raw.size():
			original_type_name_for_table = schema_types_raw[ref_idx].get("name", { }).get("name")
		var target_type_idx: int = _find_type_index(original_type_name_for_table, parsed_types_list)
		var target_type_def: Dictionary = parsed_types_list[target_type_idx] if target_type_idx >= 0 else { }

		if target_type_def.is_empty() or not target_type_def.has("struct"):
			SpacetimePlugin.print_err("Table '%s' refers to an invalid or non-struct type (index %s in original schema, name %s)." % [table_name_str, str(ref_idx), original_type_name_for_table if original_type_name_for_table else "N/A"])
			continue

		# `name` is the identifier every generated class, file and member is spelled from;
		# `wire_name` is what the server registers the table under and the only spelling it
		# answers to (subscription SQL, TableUpdate identifiers). They differ only for a
		# submodule's table, where the wire name carries dots an identifier cannot.
		var table_wire_name: String = table_info.get("wire_name", table_name_str)
		var table_data: Dictionary = {
			"name": table_name_str,
			"wire_name": table_wire_name,
			"namespace": table_info.get("namespace", PackedStringArray()),
			"local_name": table_info.get("local_name", table_name_str),
			"type_idx": target_type_idx,
			"is_event": table_info.get("is_event", false),
		}

		if not target_type_def.has("table_names"):
			target_type_def.table_names = []
		# The row type's `table_names` const is read at runtime to map an incoming
		# TableUpdate to its row script, so these are wire names.
		target_type_def.table_names.append(table_wire_name)
		target_type_def.table_name = table_wire_name

		var pk_col_idx: int = -1
		var primary_key_indices: Array = table_info.get("primary_key", [])
		if primary_key_indices.size() == 1:
			var pk_field_idx: int = int(primary_key_indices[0])
			if pk_field_idx < target_type_def.struct.size():
				var pk_field_name: String = target_type_def.struct[pk_field_idx].name
				pk_col_idx = pk_field_idx
				table_data.primary_key = pk_field_idx
				table_data.primary_key_name = pk_field_name
				target_type_def.primary_key = pk_field_idx
				target_type_def.primary_key_name = pk_field_name
			else:
				SpacetimePlugin.print_err("Primary key index %d out of bounds for table %s (struct size %d)" % [pk_field_idx, table_name_str, target_type_def.struct.size()])

		var parsed_unique_indexes: Array[Dictionary] = []
		var unique_col_set: Dictionary[int, bool] = { }
		var constraints_def = table_info.get("constraints", [])
		for constraint_def: Dictionary in constraints_def:
			var constraint_name_str: String = constraint_def.get("name", { }).get("some", null)
			var column_indices: Array = constraint_def.get("data", { }).get("Unique", { }).get("columns", [])
			if column_indices.size() != 1 or constraint_name_str == null:
				continue

			var unique_field_idx: int = int(column_indices[0])
			if unique_field_idx < target_type_def.struct.size():
				var unique_index: Dictionary = target_type_def.struct[unique_field_idx].duplicate()
				unique_index.constraint_name = constraint_name_str
				parsed_unique_indexes.append(unique_index)
				unique_col_set[unique_field_idx] = true
			else:
				SpacetimePlugin.print_err("Unique field index %d out of bounds for table %s (struct size %d)" % [unique_field_idx, table_name_str, target_type_def.struct.size()])

		parsed_unique_indexes.sort_custom(_sort_by_constraint_name)
		table_data.unique_indexes = parsed_unique_indexes

		# Non-unique btree indexes get a filter() accessor. Single-column only;
		# skip columns already covered by the primary key or a unique index (those
		# expose find() and the auto-created btree mirror would only duplicate them).
		var parsed_btree_indexes: Array[Dictionary] = []
		for index_def: Dictionary in table_info.get("indexes", []):
			var btree_cols: Array = index_def.get("algorithm", { }).get("BTree", [])
			if btree_cols.size() != 1:
				continue
			var btree_col_idx: int = int(btree_cols[0])
			if btree_col_idx == pk_col_idx or unique_col_set.has(btree_col_idx):
				continue
			if btree_col_idx >= target_type_def.struct.size():
				SpacetimePlugin.print_err("BTree index column %d out of bounds for table %s (struct size %d)" % [btree_col_idx, table_name_str, target_type_def.struct.size()])
				continue
			parsed_btree_indexes.append(target_type_def.struct[btree_col_idx].duplicate())

		# Server returns indexes in HashMap order; sort so the *_table.gd wrapper's
		# btree accessor decls emit deterministically (mirrors unique_indexes above).
		parsed_btree_indexes.sort_custom(_sort_by_name)
		table_data.btree_indexes = parsed_btree_indexes

		var is_public: bool = true
		if not target_type_def.has("is_public"):
			target_type_def.is_public = []
		if table_info.get("table_access", { }).has("Private"):
			is_public = false

		table_data.is_public = is_public
		target_type_def.is_public.append(is_public)

		if table_info.get("schedule", { }).has("some"):
			var schedule = table_info.get("schedule", { }).some
			table_data.schedule = schedule
			target_type_def.schedule = schedule
			scheduled_reducers.append(schedule.reducer_name)
		parsed_tables_list.append(table_data)

	var parsed_reducers_list: Array[Dictionary] = []
	for reducer_info: Dictionary in schema_reducers:
		var lifecycle = reducer_info.get("lifecycle", { }).get("some", null)
		if lifecycle:
			continue
		var r_name: String = reducer_info.get("name", "")
		if r_name.is_empty():
			SpacetimePlugin.print_err("Reducer found with no name: %s" % [reducer_info])
			continue
		var reducer_data: Dictionary = {
			"name": r_name,
			"wire_name": reducer_info.get("wire_name", r_name),
			"namespace": reducer_info.get("namespace", PackedStringArray()),
			"local_name": reducer_info.get("local_name", r_name),
		}

		var reducer_raw_params: Array = reducer_info.get("params", { }).get("elements", [])
		var reducer_params: Array[Dictionary] = []
		for raw_param: Dictionary in reducer_raw_params:
			var data: Dictionary = { "name": raw_param.get("name", { }).get("some", null) }
			var type: String = _parse_field_type(raw_param.get("algebraic_type", { }), data, schema_types_raw)
			data["type"] = type

			if type and not (GDNATIVE_PRIMITIVE_TYPES.has(type) or DEFAULT_TYPE_MAP.has(type)):
				var type_idx: int = _find_type_index(type, parsed_types_list)
				if type_idx >= 0:
					data["type_idx"] = type_idx
			reducer_params.append(data)
		reducer_data["params"] = reducer_params

		# Parse the reducer's ok return type (every v10 reducer carries one; a unit
		# return is an empty Product → empty type → no-op decode at the call site).
		var ret_data: Dictionary = { }
		var ret_type: String = _parse_field_type(reducer_info.get("ok_return_type", { }), ret_data, schema_types_raw)
		reducer_data["return_type"] = ret_type
		reducer_data["return_data"] = ret_data
		if ret_type and not (GDNATIVE_PRIMITIVE_TYPES.has(ret_type) or DEFAULT_TYPE_MAP.has(ret_type)):
			var ret_type_idx: int = _find_type_index(ret_type, parsed_types_list)
			if ret_type_idx >= 0:
				reducer_data["return_type_idx"] = ret_type_idx

		if r_name in scheduled_reducers:
			reducer_data["is_scheduled"] = true
		parsed_reducers_list.append(reducer_data)

	var parsed_procedures_list: Array[Dictionary] = []
	for export_dict: Dictionary in misc_exports:
		# --- Procedure exports ---
		var proc: Dictionary = export_dict.get("Procedure", { })
		if not proc.is_empty():
			var proc_name: String = proc.get("name", "")
			if proc_name.is_empty():
				SpacetimePlugin.print_err("Procedure found with no name: %s" % [proc])
				continue
			SpacetimePlugin.print_log("Parsing procedure: %s" % proc_name)
			var proc_data: Dictionary = {
				"name": proc_name,
				"wire_name": proc.get("wire_name", proc_name),
				"namespace": proc.get("namespace", PackedStringArray()),
				"local_name": proc.get("local_name", proc_name),
			}

			# Parse params (same as reducer params)
			var raw_params: Array = proc.get("params", { }).get("elements", [])
			var proc_params: Array[Dictionary] = []
			for raw_param: Dictionary in raw_params:
				var data: Dictionary = { "name": raw_param.get("name", { }).get("some", null) }
				var type: String = _parse_field_type(raw_param.get("algebraic_type", { }), data, schema_types_raw)
				data["type"] = type

				if type and not (GDNATIVE_PRIMITIVE_TYPES.has(type) or DEFAULT_TYPE_MAP.has(type)):
					var type_idx: int = _find_type_index(type, parsed_types_list)
					if type_idx >= 0:
						data["type_idx"] = type_idx
				proc_params.append(data)
			proc_data["params"] = proc_params

			# Parse return type
			var ret_data: Dictionary = { }
			var ret_type: String = _parse_field_type(proc.get("return_type", { }), ret_data, schema_types_raw)
			proc_data["return_type"] = ret_type
			proc_data["return_data"] = ret_data

			# Resolve return type_idx for BSATN type lookup
			if ret_type and not (GDNATIVE_PRIMITIVE_TYPES.has(ret_type) or DEFAULT_TYPE_MAP.has(ret_type)):
				var ret_type_idx: int = _find_type_index(ret_type, parsed_types_list)
				if ret_type_idx >= 0:
					proc_data["return_type_idx"] = ret_type_idx

			parsed_procedures_list.append(proc_data)
			continue

		# --- View exports ---
		var view: Dictionary = export_dict.get("View", { })
		if view.is_empty():
			continue
		var name: String = view.get("name", "")
		if name.is_empty():
			SpacetimePlugin.print_err("View found with no name: %s" % [view])
			continue
		var return_type_dict: Dictionary = view.get("return_type", { })
		if return_type_dict.is_empty():
			SpacetimePlugin.print_err("View '%s' has no return_type" % name)
			continue
		var type_index: int = -1
		var return_type: Dictionary
		# A `Query<T>` view (the `{ __query__: Ref(T) }` product below) inherits the primary
		# key of the table it reads from — the server does that itself in
		# `assign_query_view_primary_keys`, and only for that view kind. A PROCEDURAL view
		# (`Vec<T>` / `Option<T>`) has a primary key only when the module declared one, which
		# reaches us as a ViewPrimaryKeys entry; its rows are whatever the view function
		# returned, so a column that happens to be a table's key promises nothing here.
		var is_query_view: bool = false
		SpacetimePlugin.print_log("parsing return type for view: %s" % name)
		if return_type_dict.get("Array", { }).is_empty():
			if not return_type_dict.get("Sum", { }).is_empty():
				var variants: Array = return_type_dict.get("Sum", { }).get("variants", [])
				if variants.size() == 2:
					if variants[0].get("name", { }).get("some", "") == "some":
						var ref_val = variants[0].get("algebraic_type", { }).get("Ref", null)
						if ref_val != null:
							type_index = int(ref_val)
							if type_index >= 0 and type_index < parsed_types_list.size():
								return_type = parsed_types_list[type_index]
							else:
								SpacetimePlugin.print_err("View '%s': Ref index %d out of bounds (types size %d)" % [name, type_index, parsed_types_list.size()])
								continue
			elif not return_type_dict.get("Product", { }).is_empty():
				# Query<T> views encode their return as a single-element product
				# { __query__: Ref(T) } (QUERY_VIEW_RETURN_TAG). Unwrap to the row type.
				var elements: Array = return_type_dict.get("Product", { }).get("elements", [])
				if elements.size() == 1 and elements[0].get("name", { }).get("some", "") == "__query__":
					var ref_val = elements[0].get("algebraic_type", { }).get("Ref", null)
					if ref_val != null:
						is_query_view = true
						type_index = int(ref_val)
						if type_index >= 0 and type_index < parsed_types_list.size():
							return_type = parsed_types_list[type_index]
						else:
							SpacetimePlugin.print_err("View '%s': Ref index %d out of bounds (types size %d)" % [name, type_index, parsed_types_list.size()])
							continue
				else:
					SpacetimePlugin.print_err("View '%s': unsupported product return type: %s" % [name, return_type_dict])
					continue
			else:
				SpacetimePlugin.print_err("view return type not yet supported in the parser: %s" % [return_type_dict])
				continue
		else:
			var ref_val = return_type_dict.get("Array", { }).get("Ref", null)
			if ref_val == null:
				SpacetimePlugin.print_err("View '%s': Array return type has no Ref" % name)
				continue
			type_index = int(ref_val)
			if type_index < 0 or type_index >= parsed_types_list.size():
				SpacetimePlugin.print_err("View '%s': Ref index %d out of bounds (types size %d)" % [name, type_index, parsed_types_list.size()])
				continue
			return_type = parsed_types_list[type_index]
		if return_type.is_empty():
			SpacetimePlugin.print_err("view return type not found: %s" % [return_type_dict])
			continue

		# Resolve the view's primary key (Schema V10, SpacetimeDB 2.2.0+).
		# ViewPrimaryKeys gives a column name; map it to a field index in the struct.
		var view_pk_name: String = view.get("primary_key_name", "")
		var view_pk_idx: int = 0
		if not view_pk_name.is_empty():
			view_pk_idx = _find_struct_field_index(return_type.get("struct", []), view_pk_name)
			if view_pk_idx < 0:
				SpacetimePlugin.print_err("View '%s': primary key column '%s' not found in struct" % [name, view_pk_name])
				view_pk_idx = 0
				view_pk_name = ""

		var tables_of_same_type: Array = []
		for table: Dictionary in parsed_tables_list:
			if table.get("type_idx", -1) == type_index:
				tables_of_same_type.append(table)

		# A `Query<T>` view with no ViewPrimaryKeys entry takes the primary key of a table
		# built on the same row type — `assign_query_view_primary_keys` does exactly that
		# server-side, and serializes nothing, so the client has to redo it. Its rules,
		# followed here: a table with no key of its own does not count, and two keyed
		# tables naming different columns leave the view without one ("Ambiguous source
		# table: keep the view without a primary key"). A procedural view never inherits.
		if view_pk_name.is_empty() and is_query_view:
			var inherited_pk_name: String = ""
			var inherited_pk_idx: int = 0
			for table: Dictionary in tables_of_same_type:
				var candidate_pk_name: String = String(table.get("primary_key_name", ""))
				if candidate_pk_name.is_empty():
					continue
				if inherited_pk_name.is_empty():
					inherited_pk_name = candidate_pk_name
					inherited_pk_idx = int(table.get("primary_key", 0))
				elif candidate_pk_name != inherited_pk_name:
					inherited_pk_name = ""
					inherited_pk_idx = 0
					break
			view_pk_name = inherited_pk_name
			view_pk_idx = inherited_pk_idx

		# Like a table: the row type's `table_names` is read at runtime against what the
		# server sends, so it takes the view's wire name, dots and all.
		var view_wire_name: String = view.get("wire_name", name)
		if return_type.get("table_names", []).is_empty():
			return_type = {
				"name": return_type["name"],
				"struct": return_type["struct"],
				&"table_names": [
					view_wire_name,
				],
				&"table_name": view_wire_name,
				&"primary_key": view_pk_idx,
				&"primary_key_name": view_pk_name,
				&"is_public": [
					true,
				],
			}
		else:
			var type_table_list = return_type["table_names"]
			type_table_list.append(view_wire_name)
			return_type["table_names"] = type_table_list
			var is_public_list = return_type["is_public"]
			is_public_list.append(true)
			return_type["is_public"] = is_public_list
			# The type_def is shared by every table and view of this row type, so its
			# primary key is only a default for the ones that agree; a disagreement is
			# carried per table (codegen emits PRIMARY_KEY_BY_TABLE). Never overwrite a
			# key that is already there — this view's key is not the table's — and leave
			# the field absent when neither has one, which is what a plain key-less table
			# does.
			if not view_pk_name.is_empty() and String(return_type.get("primary_key_name", "")).is_empty():
				return_type["primary_key"] = view_pk_idx
				return_type["primary_key_name"] = view_pk_name
		parsed_types_list[type_index] = return_type

		# A view's backing table carries ONLY what the view declares: its own primary key
		# (above), no indexes, no constraints, no schedule, and never `is_event` — the
		# server builds it the same way (`TableSchema::from_view_def_for_codegen` passes
		# empty index/constraint/sequence lists and `is_event: false`). Copying the source
		# table's entry instead handed the view an index accessor whose column carries no
		# uniqueness promise, and dropped its accessors entirely when the row type belonged
		# to an event table.
		parsed_tables_list.append({
			"name": name,
			"wire_name": view_wire_name,
			"namespace": view.get("namespace", PackedStringArray()),
			"local_name": view.get("local_name", name),
			"type_idx": type_index,
			"primary_key": view_pk_idx,
			"primary_key_name": view_pk_name,
			"unique_indexes": [],
			"btree_indexes": [],
			"is_event": false,
			"is_public": true,
		})

	# Second flush. The one above runs before reducers and procedures are parsed, so
	# a Result<T, E> first seen in a RETURN type registered after it and was never
	# emitted — codegen still referenced the synthesized name, leaving the decoder to
	# fail with "Unsupported BSATN type 'ResultVector3String'" on every value-returning
	# procedure. Skips names the first flush already took.
	for synth_name: String in _synth_result_types:
		if type_map.has(synth_name):
			continue
		parsed_types_list.append(_synth_result_types[synth_name])
		var synth_class: String = module_class_prefix(module_name) + synth_name.to_pascal_case()
		type_map[synth_name] = synth_class
		meta_type_map[synth_name] = synth_class

	# Return type_idx could not resolve for anything the second flush just added, so
	# fill those in now that the types exist.
	for call_data: Dictionary in parsed_reducers_list + parsed_procedures_list:
		if call_data.has("return_type_idx"):
			continue
		var ret_type: String = call_data.get("return_type", "")
		if ret_type.is_empty() or GDNATIVE_PRIMITIVE_TYPES.has(ret_type) or DEFAULT_TYPE_MAP.has(ret_type):
			continue
		var idx: int = _find_type_index(ret_type, parsed_types_list)
		if idx >= 0:
			call_data["return_type_idx"] = idx

	# Sort the output lists by name so binding generation is deterministic
	# regardless of the server's per-publish section order. Types stay in `ty`
	# order (sorted above) — their positions are referenced by index elsewhere.
	parsed_tables_list.sort_custom(_sort_by_name)
	parsed_reducers_list.sort_custom(_sort_by_name)
	parsed_procedures_list.sort_custom(_sort_by_name)

	SpacetimePlugin.print_log("Schema parser finished")
	parsed_schema.incomplete = SpacetimePlugin.error_count > errors_before
	parsed_schema.types = parsed_types_list
	parsed_schema.reducers = parsed_reducers_list
	parsed_schema.procedures = parsed_procedures_list
	parsed_schema.tables = parsed_tables_list
	parsed_schema.type_map = type_map
	parsed_schema.meta_type_map = meta_type_map
	parsed_schema.typespace = typespace
	return parsed_schema


static func _is_gd_native(type_name: String) -> bool:
	return GDNATIVE_PRIMITIVE_TYPES.has(type_name) or GDNATIVE_ARRAYLIKE_TYPES.has(type_name) or GDNATIVE_DICTLIKE_TYPES.has(type_name)


static func _set_gd_native(type_name: String, type_data: Dictionary) -> void:
	type_data["gd_native"] = true

	if GDNATIVE_PRIMITIVE_TYPES.has(type_name):
		type_data["gd_primitive"] = true
	elif GDNATIVE_ARRAYLIKE_TYPES.has(type_name):
		type_data["gd_arraylike"] = true
	elif GDNATIVE_DICTLIKE_TYPES.has(type_name):
		type_data["gd_dictlike"] = true


static func _validate_gd_native(type_name: String, type_data: Dictionary) -> bool:
	if type_data.has("gd_primitive"):
		return true

	if type_data.has("gd_arraylike"):
		var expected_struct_size = 0
		var expected_primitive_type = "float"
		if type_name == "Vector4":
			expected_struct_size = 4
		elif type_name == "Vector4I":
			expected_struct_size = 4
			expected_primitive_type = "int"
		elif type_name == "Vector3":
			expected_struct_size = 3
		elif type_name == "Vector3I":
			expected_struct_size = 3
			expected_primitive_type = "int"
		elif type_name == "Vector2":
			expected_struct_size = 2
		elif type_name == "Vector2I":
			expected_struct_size = 2
			expected_primitive_type = "int"
		elif type_name == "Quaternion":
			expected_struct_size = 4
		elif type_name == "Color":
			expected_struct_size = 4
		else:
			SpacetimePlugin.print_err("Unsupported array-like GD native type: %s" % [type_name])
			return false

		if type_data.struct.size() != expected_struct_size:
			SpacetimePlugin.print_err("Array-like GD native type '%s' expected length of %d but is %d" % [type_name, expected_struct_size, type_data.struct.size()])
			return false

		for element: Dictionary in type_data.struct:
			var primitive_type = GDNATIVE_PRIMITIVE_TYPES.get(element.type, null)
			if not primitive_type:
				SpacetimePlugin.print_err("Property '%s' in array-like GD native type '%s' must be a primitive type" % [element.name, type_name])
				return false

			if primitive_type != expected_primitive_type:
				SpacetimePlugin.print_err("Property '%s' in array-like GD native type '%s' should map to a '%s' primitive type" % [element.name, type_name, expected_primitive_type])
				return false

	if type_data.has("gd_dictlike"):
		if type_name == "Plane":
			if not type_data.has("struct") or type_data.struct.size() != 4:
				SpacetimePlugin.print_err("Plane type expects 4 struct elements (normal.x, normal.y, normal.z, d), got %d" % (type_data.get("struct", []).size()))
				return false
			for element: Dictionary in type_data.struct:
				var primitive_type = GDNATIVE_PRIMITIVE_TYPES.get(element.type, null)
				if primitive_type != "float":
					SpacetimePlugin.print_err("Plane element '%s' must be a float type, got '%s'" % [element.name, element.type])
					return false

	return true


static func _is_sum_type(sum_def: Dictionary) -> bool:
	var variants = sum_def.get("variants", [])
	for variant: Dictionary in variants:
		var type = variant.get("algebraic_type", { })
		if not type.has("Product"):
			return true
		var elements = type.Product.get("elements", [])
		if not elements.is_empty():
			return true
	return false


static func _is_sum_option(sum_def: Dictionary) -> bool:
	var variants = sum_def.get("variants", [])
	if variants.size() != 2:
		return false

	var found_some: bool = false
	var found_none: bool = false
	var none_is_unit: bool = false

	for v_idx: int in variants.size():
		var v_name = variants[v_idx].get("name", { }).get("some", "")
		if v_name == "some":
			found_some = true
		elif v_name == "none":
			found_none = true
			var none_variant_type = variants[v_idx].get("algebraic_type", { })
			if none_variant_type.has("Product") and none_variant_type.Product.get("elements", []).is_empty():
				none_is_unit = true
			elif none_variant_type.is_empty():
				none_is_unit = true

	return found_some and found_none and none_is_unit


# Structural ScheduleAt: exactly two variants, `Interval` carrying a TimeDuration and
# `Time` carrying a Timestamp — the shape SpacetimeDB's `SumType::is_schedule_at`
# matches (crates/sats/src/sum_type.rs). Recognised by TYPE, never by column name: the
# `#[scheduled]` macro accepts `scheduled(my_reducer, at = other_column)`, so the column
# can be called anything, and an ordinary table is free to carry an unrelated column
# actually named `scheduled_at`. Getting either wrong desyncs the row — a ScheduleAt is
# a tag byte plus an i64, an i64 is eight bytes — and one bad row fails the whole packet.
static func _is_sum_schedule_at(sum_def: Dictionary) -> bool:
	var variants: Array = sum_def.get("variants", [])
	if variants.size() != 2:
		return false
	if variants[0].get("name", { }).get("some", "") != "Interval":
		return false
	if variants[1].get("name", { }).get("some", "") != "Time":
		return false
	return (
		_is_wrapper_product(variants[0].get("algebraic_type", { }), "__time_duration_micros__")
		and _is_wrapper_product(
			variants[1].get("algebraic_type", { }), "__timestamp_micros_since_unix_epoch__"
		)
	)


# True when [param type] is a single-element Product whose element is named
# [param element_name] — the shape SpacetimeDB gives Timestamp, TimeDuration, Identity
# and the other magic wrappers.
static func _is_wrapper_product(type: Dictionary, element_name: String) -> bool:
	var elements: Array = type.get("Product", { }).get("elements", [])
	if elements.size() != 1:
		return false
	return elements[0].get("name", { }).get("some", "") == element_name


# Structural Result: exactly two variants named "ok" then "err" (lowercase, ok first).
# Matches SpacetimeDB's `SumType::is_result`. Option is checked separately and wins.
static func _is_sum_result(sum_def: Dictionary) -> bool:
	var variants: Array = sum_def.get("variants", [])
	if variants.size() != 2:
		return false
	var n0: String = variants[0].get("name", { }).get("some", "")
	var n1: String = variants[1].get("name", { }).get("some", "")
	return n0 == "ok" and n1 == "err"


# Synthesizes a named RustEnum-style sum type for an anonymous inline Result<T, E>,
# returning its bare type name (e.g. "ResultI32String"). The variant payload types are
# parsed exactly like normal enum variants so the standard enum codegen + BSATN path
# (u8 tag + payload) handles it. Deduped by name; flushed into the type list by
# parse_schema via [member _synth_result_types].
static func _synthesize_result_type(sum_def: Dictionary, schema_types: Array, depth: int) -> String:
	var variants: Array = sum_def.get("variants", [])
	var ok_data: Dictionary = { "name": "ok" }
	var ok_type: String = _parse_field_type(variants[0].get("algebraic_type", { }), ok_data, schema_types, depth + 1)
	if not ok_type.is_empty():
		ok_data["type"] = ok_type
	var err_data: Dictionary = { "name": "err" }
	var err_type: String = _parse_field_type(variants[1].get("algebraic_type", { }), err_data, schema_types, depth + 1)
	if not err_type.is_empty():
		err_data["type"] = err_type

	var synth_name: String = "Result%s%s" % [_result_name_part(ok_data), _result_name_part(err_data)]
	if not _synth_result_types.has(synth_name):
		_synth_result_types[synth_name] = {
			"name": synth_name,
			"is_sum_type": true,
			"enum": [ok_data, err_data],
		}
	return synth_name


# Builds a stable identifier fragment for a Result variant, folding in nesting markers
# (Vec/Option) so Result<Vec<i32>, _> and Result<i32, _> get distinct synthesized names.
static func _result_name_part(variant_data: Dictionary) -> String:
	var part: String = ""
	for marker: StringName in variant_data.get("nested_type", []):
		part += String(marker)
	part += variant_data.get("type", "Unit")
	var sanitized: String = ""
	for c: String in part:
		sanitized += c if c.is_valid_identifier() or c.is_valid_int() else "_"
	return sanitized


const _PARSE_FIELD_TYPE_MAX_DEPTH: int = 32


# Recursively parse a field type
static func _parse_field_type(field_type: Dictionary, data: Dictionary, schema_types: Array, depth: int = 0) -> String:
	if depth > _PARSE_FIELD_TYPE_MAX_DEPTH:
		SpacetimePlugin.print_err("_parse_field_type recursion exceeded %d levels; aborting" % _PARSE_FIELD_TYPE_MAX_DEPTH)
		return ""
	if field_type.has("Array"):
		var nested_type = data.get("nested_type", [])
		nested_type.append(&"Array")
		data["nested_type"] = nested_type
		if data.has("is_option"):
			data["is_array_inside_option"] = true
		else:
			data["is_array"] = true
		field_type = field_type.Array
		return _parse_field_type(field_type, data, schema_types, depth + 1)
	if field_type.has("Product"):
		var elements: Array = field_type.Product.get("elements", [])
		if elements.is_empty():
			return ""
		return elements[0].get('name', { }).get('some', null)
	if field_type.has("Sum"):
		# Anonymous inline Result<T, E> — synthesize a named RustEnum-style type and
		# return its name so it rides the enum-with-payload path (must precede the
		# generic collapse below, which would otherwise drop the err variant).
		if _is_sum_result(field_type.Sum):
			return _synthesize_result_type(field_type.Sum, schema_types, depth)
		# ScheduleAt keeps its sum shape on the wire (tag byte + i64), so it cannot ride
		# the collapse below — that would take the Interval variant's payload and read
		# eight bytes where the row carries nine.
		if _is_sum_schedule_at(field_type.Sum):
			return SCHEDULE_AT_TYPE_NAME
		if _is_sum_option(field_type.Sum):
			var nested_type = data.get("nested_type", [])
			nested_type.append(&"Option")
			data["nested_type"] = nested_type
			if data.has("is_array"):
				data["is_option_inside_array"] = true
			else:
				data["is_option"] = true
		field_type = field_type.Sum.variants[0].get('algebraic_type', { })
		return _parse_field_type(field_type, data, schema_types, depth + 1)
	if field_type.has("Ref"):
		var ref_idx: int = int(field_type.Ref)
		if ref_idx < 0 or ref_idx >= schema_types.size():
			SpacetimePlugin.print_err("Invalid schema: Ref index %d out of bounds (typespace size %d)" % [ref_idx, schema_types.size()])
			return ""
		return schema_types[ref_idx].get("name", { }).get("name", null)
	if field_type.is_empty():
		SpacetimePlugin.print_err("Invalid schema: Empty algebraic_type encountered")
		return ""
	return _first_key(field_type)
