# Regression test: editing a module's alias in the plugin dock cannot delete another
# module's configuration.
#
# The alias is the KEY of plugin_config.module_configs, and the dock used to re-key on
# every KEYSTROKE (erase old key, set new). Typing "alpha" into a second module's alias
# field therefore walked the dictionary through every prefix of what was typed, and the
# final step landed on the entry named "alpha": measured, two configured modules became
# ONE, keyed "alpha" but carrying the other module's name — the first module's name,
# flags and schema gone, written to disk on the same keystroke, with both rows still on
# screen. Adding a module under an already-configured alias reached into that entry the
# same way.
#
# The alias now commits when the edit ends and is refused if it is empty or already
# taken; the field goes back to what it was.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_plugin_ui_module_config.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const UI_PATH: String = "res://addons/SpacetimeDB/ui/ui.tscn"
const ALIAS_INPUT: String = "VBoxContainer/HBoxContainer/VBoxContainer/ModuleAliasInput"

var _total: int = 0
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

	var f: int = 0
	f += _test_colliding_alias_refused()
	f += _test_empty_alias_refused()
	f += _test_rename_applies()
	f += _test_duplicate_add_refused()
	f += _test_nameless_add_refused()
	f += _test_commit_on_focus_loss()

	_ui.queue_free()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## The clobber itself: renaming beta to alpha must leave both modules alone.
func _test_colliding_alias_refused() -> int:
	var config: SpacetimeDBPluginConfig = _show(["alpha", "beta"])
	var field: LineEdit = _alias_input(1)
	_type(field, "alpha")

	var f: int = 0
	f += _check_i("collision: both modules survive", config.module_configs.size(), 2)
	f += _check_s("collision: alpha keeps its own name", _name_of(config, "alpha"), "alpha")
	f += _check_s("collision: beta keeps its key", _name_of(config, "beta"), "beta")
	f += _check_s("collision: the field goes back", field.text, "beta")
	return f


## An emptied alias would key the config under "" — no module is named that, and
## codegen cannot spell a class from it.
func _test_empty_alias_refused() -> int:
	var config: SpacetimeDBPluginConfig = _show(["alpha", "beta"])
	var field: LineEdit = _alias_input(1)
	_type(field, "")

	var f: int = 0
	f += _check_b("empty: no empty key", config.module_configs.has(""), false)
	f += _check_i("empty: both modules survive", config.module_configs.size(), 2)
	f += _check_s("empty: the field goes back", field.text, "beta")
	return f


## The gate must not cost the feature: a free alias still re-keys, and the module
## keeps everything else it was configured with.
func _test_rename_applies() -> int:
	var config: SpacetimeDBPluginConfig = _show(["alpha", "beta"])
	var field: LineEdit = _alias_input(1)
	_type(field, "gamma")

	var f: int = 0
	f += _check_b("rename: new key present", config.module_configs.has("gamma"), true)
	f += _check_b("rename: old key gone", config.module_configs.has("beta"), false)
	f += _check_i("rename: still two modules", config.module_configs.size(), 2)
	f += _check_s("rename: the module name is untouched", _name_of(config, "gamma"), "beta")
	f += _check_s(
		"rename: the config carries the new alias",
		config.module_configs["gamma"].alias,
		"gamma",
	)
	return f


## Adding under an already-configured alias overwrote that entry's name and flags.
func _test_duplicate_add_refused() -> int:
	var config: SpacetimeDBPluginConfig = _show(["alpha"])
	_ui._new_module_name_input.text = "somethingelse"
	_ui._new_module_alias_input.text = "alpha"
	_ui._on_new_module()

	var f: int = 0
	f += _check_i("duplicate add: still one module", config.module_configs.size(), 1)
	f += _check_s("duplicate add: name untouched", _name_of(config, "alpha"), "alpha")
	return f


## Empty name and empty alias means no key at all.
func _test_nameless_add_refused() -> int:
	var config: SpacetimeDBPluginConfig = _show(["alpha"])
	_ui._new_module_name_input.text = ""
	_ui._new_module_alias_input.text = ""
	_ui._on_new_module()
	return _check_i("nameless add: still one module", config.module_configs.size(), 1)


## The other end-of-edit path: clicking away rather than pressing Enter. Also the
## one that re-enters _commit_alias, since update_module_ui frees the focused field.
func _test_commit_on_focus_loss() -> int:
	var config: SpacetimeDBPluginConfig = _show(["alpha", "beta"])
	var field: LineEdit = _alias_input(1)
	field.text = "delta"
	field.text_changed.emit("delta")
	field.focus_exited.emit()

	var f: int = 0
	f += _check_b("focus loss: renamed", config.module_configs.has("delta"), true)
	f += _check_b("focus loss: old key gone", config.module_configs.has("beta"), false)
	f += _check_i("focus loss: still two modules", config.module_configs.size(), 2)
	return f


func _show(aliases: PackedStringArray) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	for alias: String in aliases:
		var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
		module_config.name = alias
		module_config.alias = alias
		config.module_configs[alias] = module_config
	_ui._plugin_config = config
	_ui.update_module_ui()
	return config


## Types [param text] the way a user does — one keystroke at a time, each raising
## text_changed — and then commits with Enter. Typing the prefixes is the point: the
## per-keystroke re-key is what walked one module's config over another's.
func _type(field: LineEdit, text: String) -> void:
	for i: int in text.length():
		var typed: String = text.substr(0, i + 1)
		field.text = typed
		field.text_changed.emit(typed)
	if text.is_empty():
		field.text = ""
		field.text_changed.emit("")
	field.text_submitted.emit(field.text)


func _alias_input(index: int) -> LineEdit:
	return _ui._modules_container.get_child(index).get_node(ALIAS_INPUT) as LineEdit


func _name_of(config: SpacetimeDBPluginConfig, key: String) -> String:
	if not config.module_configs.has(key):
		return "<missing>"
	return config.module_configs[key].name


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1
