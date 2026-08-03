extends SceneTree


func _initialize() -> void:
	var registry: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
	for name: StringName in [&"BlackholioProbeKind", &"BlackholioDbVector2", &"Option", &"RustEnum"]:
		print("%s -> by_class=%s  normalized=%s" % [
			name,
			registry.get_type_by_class(name) != null,
			registry.types.has(StringName(String(name).to_lower().replace("_", ""))),
		])
	print("types_by_class size=%d  types size=%d" % [registry.types_by_class.size(), registry.types.size()])
	var missing: PackedStringArray = []
	for key: StringName in registry.types:
		var s: GDScript = registry.types[key]
		if s.get_global_name().is_empty():
			missing.append(s.resource_path.get_file())
	print("scripts with no global name: ", missing)
	quit(0)
