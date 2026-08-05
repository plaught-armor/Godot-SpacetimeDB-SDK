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
	}
