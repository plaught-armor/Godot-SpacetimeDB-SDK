# Probe: the plugin dock's module list, driven headlessly.
#
# ui.gd re-keys plugin_config.module_configs on every KEYSTROKE in a module's alias
# field (erase old key, set new). Two questions this answers: what happens when the
# typed alias collides with another configured module, and what an emptied field
# leaves behind.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_plugin_ui_alias.gd
extends SceneTree

const UI_PATH: String = "res://addons/SpacetimeDB/ui/ui.tscn"

var _ui: Control


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load(UI_PATH) as PackedScene
	if scene == null:
		printerr("could not load %s" % UI_PATH)
		quit(1)
		return
	_ui = scene.instantiate() as Control
	root.add_child(_ui)
	await process_frame

	_scenario_alias_collision()
	_scenario_alias_emptied()
	quit(0)


func _scenario_alias_collision() -> void:
	var config: SpacetimeDBPluginConfig = _config(["alpha", "beta"])
	_ui._plugin_config = config
	_ui.update_module_ui()

	print("\n=== before: %s" % [config.module_configs.keys()])
	# Type "alpha" into beta's alias field, one keystroke at a time, as a user would.
	var alias_input: LineEdit = _alias_input_of(1)
	for i: int in 5:
		var typed: String = "alpha".substr(0, i + 1)
		alias_input.text = typed
		alias_input.text_changed.emit(typed)
	alias_input.text_submitted.emit(alias_input.text)
	print("=== after typing 'alpha' into beta's alias: %s" % [config.module_configs.keys()])
	for key: String in config.module_configs:
		var module_config: SpacetimeDBModuleConfig = config.module_configs[key]
		print("    key=%-8s name=%-8s alias=%s" % [key, module_config.name, module_config.alias])


func _scenario_alias_emptied() -> void:
	var config: SpacetimeDBPluginConfig = _config(["alpha", "beta"])
	_ui._plugin_config = config
	_ui.update_module_ui()

	var alias_input: LineEdit = _alias_input_of(1)
	alias_input.text = ""
	alias_input.text_changed.emit("")
	alias_input.text_submitted.emit("")
	print("\n=== after clearing beta's alias: %s" % [config.module_configs.keys()])
	for key: String in config.module_configs:
		var module_config: SpacetimeDBModuleConfig = config.module_configs[key]
		print("    key=%-8s name=%-8s alias=%s" % [key, module_config.name, module_config.alias])


func _alias_input_of(index: int) -> LineEdit:
	var row: Node = _ui._modules_container.get_child(index)
	return row.get_node("VBoxContainer/HBoxContainer/VBoxContainer/ModuleAliasInput") as LineEdit


func _config(aliases: PackedStringArray) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	for alias: String in aliases:
		var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
		module_config.name = alias
		module_config.alias = alias
		config.module_configs[alias] = module_config
	return config
