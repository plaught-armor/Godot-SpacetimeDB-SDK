# Probe: mechanical mutation sweep over the schema JSON the codegen parses.
#
# The parser's input is an HTTP body — a server one version newer, a proxy's error page,
# a truncated response. A FAULT there is the destructive class (32nd pass): GDScript
# unwinds the faulting function and hands the caller its default, so "parsed nothing"
# and "died half way" look the same, and the generator's pruning step deletes the
# user's previous bindings.
#
# Every node of every committed fixture is mutated one at a time (erase, null, 0, "",
# [], {}, "x", -1, [{}]) and fed to SpacetimeSchemaParser.parse_schema. A "BEGIN" line
# with no matching "END" line means that mutant faulted.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_schema_fuzz.gd 2>&1 | tee /tmp/fuzz.log
extends SceneTree

const FIXTURE_DIR: String = "res://tests/fixtures"

## Bounds (NASA rule 2): the largest fixture carries ~415 nodes, so these ceilings are
## above every committed input and exist only to stop a runaway walk.
const MAX_PATHS: int = 2000
const MAX_DEPTH: int = 16

enum Mut {
	ERASE,
	NULL,
	ZERO,
	EMPTY_STR,
	EMPTY_ARR,
	EMPTY_DICT,
	STR_X,
	NEG,
	ARR_DICT,
}

var _begun: int = 0
var _ended: int = 0


func _initialize() -> void:
	var names: PackedStringArray = _fixture_names()
	for fixture_name: String in names:
		_sweep(fixture_name)
	print("SWEEP DONE begun=%d ended=%d" % [_begun, _ended])
	quit(0)


func _fixture_names() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(FIXTURE_DIR)
	if dir == null:
		printerr("cannot open %s" % FIXTURE_DIR)
		return out
	for file_name: String in dir.get_files():
		if file_name.ends_with(".json"):
			out.append(file_name)
	out.sort()
	return out


func _sweep(fixture_name: String) -> void:
	var path: String = "%s/%s" % [FIXTURE_DIR, fixture_name]
	var root: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (root is Dictionary):
		printerr("SKIP %s (not a JSON object)" % fixture_name)
		return
	var module: String = fixture_name.get_basename()

	var paths: Array = []
	_collect(root, [], paths, 0)
	var base_parsed: Variant = SpacetimeSchemaParser.parse_schema(root.duplicate(true), module, { })
	print("FIXTURE %s paths=%d base=%s" % [fixture_name, paths.size(), _counts(base_parsed)])

	for i: int in paths.size():
		for mode: int in Mut.size():
			var mutant: Variant = root.duplicate(true)
			if not _apply(mutant, paths[i], mode):
				continue
			_begun += 1
			print("BEGIN %s %d %d %s" % [fixture_name, i, mode, str(paths[i])])
			var errors_before: int = SpacetimePlugin.error_count
			var parsed: Variant = SpacetimeSchemaParser.parse_schema(mutant, module, { })
			var ok: bool = parsed is SpacetimeParsedSchema
			_ended += 1
			print(
				"END %s %d %d ok=%s pusherr=%d %s"
				% [
					fixture_name,
					i,
					mode,
					str(ok),
					SpacetimePlugin.error_count - errors_before,
					_counts(parsed),
				]
			)


## `types/reducers/procedures/tables/incomplete` of a parse result, as one flat token.
func _counts(parsed: Variant) -> String:
	if not (parsed is SpacetimeParsedSchema):
		return "ty=- rd=- pr=- tb=- inc=-"
	var schema: SpacetimeParsedSchema = parsed
	return (
		"ty=%d rd=%d pr=%d tb=%d inc=%s"
		% [
			schema.types.size(),
			schema.reducers.size(),
			schema.procedures.size(),
			schema.tables.size(),
			str(schema.incomplete),
		]
	)


func _collect(node: Variant, prefix: Array, out: Array, depth: int) -> void:
	if out.size() >= MAX_PATHS or depth > MAX_DEPTH:
		return
	if node is Dictionary:
		for key: Variant in node.keys():
			var child_path: Array = prefix.duplicate()
			child_path.append(key)
			out.append(child_path)
			_collect(node[key], child_path, out, depth + 1)
	elif node is Array:
		for i: int in node.size():
			var child_path: Array = prefix.duplicate()
			child_path.append(i)
			out.append(child_path)
			_collect(node[i], child_path, out, depth + 1)


func _apply(root: Variant, path: Array, mode: int) -> bool:
	var parent: Variant = root
	for i: int in path.size() - 1:
		parent = parent[path[i]]
	var last: Variant = path[path.size() - 1]
	if mode == Mut.ERASE:
		if parent is Dictionary:
			parent.erase(last)
		else:
			parent.remove_at(last)
		return true
	parent[last] = _mut_value(mode)
	return true


func _mut_value(mode: int) -> Variant:
	if mode == Mut.NULL:
		return null
	if mode == Mut.ZERO:
		return 0
	if mode == Mut.EMPTY_STR:
		return ""
	if mode == Mut.EMPTY_ARR:
		return []
	if mode == Mut.EMPTY_DICT:
		return { }
	if mode == Mut.STR_X:
		return "x"
	if mode == Mut.NEG:
		return -1
	return [{ }]
