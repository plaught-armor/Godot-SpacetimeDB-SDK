class_name SpacetimeParsedSchema
extends Resource

## The module's class-name prefix: the module key already put through
## [method SpacetimeSchemaParser.module_class_prefix]. Use it as written — every generated
## `class_name`, the `module_name` constant on each row type, and `<module>.to_snake_case()`
## for file names all derive from this one string. Re-applying `to_pascal_case` to it is a
## bug: the transform is not idempotent, so a key like `a-b` yields two different prefixes
## depending on how many times it has been applied.
var module: String = ""
var types: Array[Dictionary] = []
var reducers: Array[Dictionary] = []
var procedures: Array[Dictionary] = []
var tables: Array[Dictionary] = []
var type_map: Dictionary[String, String] = { }
var meta_type_map: Dictionary[String, String] = { }
var typespace: Array = []

## True when the parse reported a problem and carried on — a table whose row type did not
## resolve, an index column out of range, a view whose return type is unsupported. The
## schema is then only PART of the module: everything the parser skipped is missing from
## the lists above, so codegen would emit fewer files than the module has and the pruning
## pass would delete the bindings for what went missing (see
## [method SpacetimePlugin.finalize_bindings]). Callers must treat a `true` here as a
## failed run and leave the existing bindings alone.
var incomplete: bool = false


func is_empty() -> bool:
	return types.is_empty() and reducers.is_empty()


func to_dictionary() -> Dictionary:
	return {
		"module": module,
		"types": types,
		"reducers": reducers,
		"procedures": procedures,
		"tables": tables,
		"type_map": type_map,
		"meta_type_map": meta_type_map,
		"typespace": typespace,
		"incomplete": incomplete,
	}
