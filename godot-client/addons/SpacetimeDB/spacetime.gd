@tool
class_name SpacetimePlugin
extends EditorPlugin

const ADDON_PATH: String = "res://addons/SpacetimeDB"
const LEGACY_DATA_PATH: String = "res://spacetime_data"
const BINDINGS_PATH: String = "res://spacetime_bindings"
const BINDINGS_SCHEMA_PATH: String = BINDINGS_PATH + "/schema"
const AUTOLOAD_NAME: String = "SpacetimeDB"
const AUTOLOAD_FILE_NAME: String = "spacetime_autoload.gd"
const AUTOLOAD_PATH: String = BINDINGS_SCHEMA_PATH + "/" + AUTOLOAD_FILE_NAME
const SAVE_PATH: String = ADDON_PATH + "/plugin_config.tres"
const CONFIG_PATH: String = ADDON_PATH + "/plugin.cfg"
const UI_PANEL_NAME: String = "SpacetimeDB"
const UI_PATH: String = ADDON_PATH + "/ui/ui.tscn"

static var instance: SpacetimePlugin

var http_request: HTTPRequest = HTTPRequest.new()
var plugin_config: SpacetimeDBPluginConfig
var ui: SpacetimePluginUI
var dock: EditorDock
var ui_logging: bool = true


static func clear_logs():
	if instance != null and is_instance_valid(instance.ui):
		instance.ui.clear_logs()


static func print_log(text: Variant) -> void:
	if instance != null and is_instance_valid(instance.ui) and instance.ui_logging:
		instance.ui.add_log(text)
	else:
		print(text)


## Every error this addon reports, counted. Monotonic for the process — callers snapshot
## it around a step and compare, rather than reading it as a total (see
## [method SpacetimeSchemaParser.parse_schema], which uses it to tell a whole schema from
## one it reported problems in and carried on from). Plain [code]var[/code], never
## [code]const[/code], and never reset: a reset would make one caller's snapshot lie to
## another's.
##
## A snapshot is only as narrow as its window is single-threaded and synchronous: nothing
## called inside one may [code]await[/code], defer, or emit a signal whose handler reports
## an error, or that error lands in someone else's window. True of the parse today. The
## failure direction is the safe one either way — a stray error inside the window makes a
## caller call a good step incomplete, and the incomplete answer is the one that DOESN'T
## delete anything.
static var error_count: int = 0


static func print_err(text: Variant) -> void:
	error_count += 1
	if instance != null and is_instance_valid(instance.ui) and instance.ui_logging:
		instance.ui.add_err(text)
	else:
		printerr(text)


func _enter_tree():
	instance = self

	if not is_instance_valid(dock):
		var scene: PackedScene = load(UI_PATH) as PackedScene
		if scene:
			if not is_instance_valid(ui):
				ui = scene.instantiate() as SpacetimePluginUI
			dock = EditorDock.new()
			dock.title = "SpacetimeDB"
			dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
			dock.default_slot = EditorDock.DOCK_SLOT_BOTTOM
			dock.add_child(ui)
			add_dock(dock)
		else:
			printerr("SpacetimePlugin: Failed to load UI scene: ", UI_PATH)
			return
	else:
		printerr("SpacetimePlugin: UI panel is not valid after instantiation")
		return

	ui.plugin_config_changed.connect(_on_plugin_config_changed)
	ui.check_uri.connect(_on_check_uri)
	ui.generate_schema.connect(_on_generate_schema)
	ui.clear_logs()

	http_request.timeout = 4.0
	add_child(http_request)

	var config_file: ConfigFile = ConfigFile.new()
	var cfg_load_err: int = config_file.load(CONFIG_PATH)
	if cfg_load_err != OK:
		printerr(
			"SpacetimePlugin: Failed to load plugin.cfg (err %d) at %s"
			% [cfg_load_err, CONFIG_PATH]
		)

	var version: String = config_file.get_value("plugin", "version", "0.0.0")
	var author: String = config_file.get_value("plugin", "author", "??")

	print_log("SpacetimeDB SDK v%s (c) 2025-present %s & Contributors" % [version, author])
	print_log(
		"""New modules:
[ul]
Name: Required
Alias: Optional
Hide scheduled reducer: Hides the scheduled reducer from the client.
Hide private tables: Hides private tables from the client.
[/ul]

After generating schema files, please restart Godot.
""",
	)
	load_codegen_data()


func _exit_tree():
	if is_instance_valid(ui):
		ui.destroy()
	ui = null
	if is_instance_valid(dock):
		remove_dock(dock)
		dock.queue_free()
	dock = null
	if is_instance_valid(http_request):
		http_request.queue_free()
	http_request = null

	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)

	# Don't leave the static singleton pointing at a freed plugin instance.
	instance = null


func load_codegen_data() -> void:
	if ResourceLoader.exists(SAVE_PATH, "SpacetimeDBPluginConfig"):
		# `as` yields null (not a crash) on a stale/mistyped .tres from an older
		# SDK; the null branch below then rebuilds a fresh config. Log only on hit.
		plugin_config = ResourceLoader.load(SAVE_PATH) as SpacetimeDBPluginConfig
		if plugin_config != null:
			print_log("Loaded module configs from %s" % [SAVE_PATH])
	if plugin_config == null or plugin_config.module_configs.is_empty():
		plugin_config = SpacetimeDBPluginConfig.new()
	ui._plugin_config = plugin_config
	ui.update_module_ui()


func save_codegen_data() -> void:
	if not plugin_config:
		ui.add_err("Somehow the plugin_config variable is empty")
		plugin_config = SpacetimeDBPluginConfig.new()
		ui._plugin_config = plugin_config
		ui.update_module_ui()
	ResourceSaver.save(plugin_config, SAVE_PATH)


func _on_plugin_config_changed() -> void:
	save_codegen_data()


func _on_check_uri() -> void:
	_sanitize_uri()
	var uri: String = plugin_config.uri + "/v1/ping"
	print_log("Pinging... " + uri)
	var send_err: Error = http_request.request(uri)
	if send_err != OK:
		print_err("Ping failed to start (err %d) — another request may be in flight." % send_err)
		return
	var ping_start: int = Time.get_ticks_usec()
	var result: Array = await http_request.request_completed
	if not is_instance_valid(http_request) or not is_inside_tree():
		return
	if result[1] == 0:
		print_err("Request timeout - " + uri)
	else:
		print_log("Response code: " + str(result[1]))
	print_log("request took: " + str(Time.get_ticks_usec() - ping_start) + " microseconds")


func _on_generate_schema() -> void:
	_sanitize_uri()
	if not await generate_schema(http_request, plugin_config):
		return
	if not is_inside_tree():
		return
	_register_autoload()


static func generate_schema(
	request: HTTPRequest,
	config: SpacetimeDBPluginConfig,
) -> bool:
	if config.uri.ends_with("/"):
		config.uri = config.uri.left(-1)
	# No modules configured means the run would generate nothing but the autoload —
	# and the cleanup below deletes every generated file the run did not name, so it
	# would wipe the existing bindings instead of leaving them alone. A Generate click
	# with an empty module list (a fresh install, or the last module just removed) is
	# one click away, so refuse it here rather than let it through as an empty run.
	if config.module_configs.is_empty():
		print_err("No modules configured — add a module before generating.")
		return false
	print_log("Starting code generation...")
	print_log("Fetching module schemas...")
	var failed: bool = false
	for module_alias: String in config.module_configs:
		var module_config: SpacetimeDBModuleConfig = config.module_configs[module_alias]
		var schema_uri: String = "%s/v1/database/%s/schema?version=10" % [
			config.uri,
			module_config.name,
		]
		var send_err: Error = request.request(schema_uri)
		if send_err != OK:
			print_err(
				"Schema request failed to start for %s (err %d)" % [module_config.name, send_err]
			)
			failed = true
			continue
		var result: Array = await request.request_completed
		if not is_instance_valid(request):
			return false

		if result[1] == 200:
			var json: String = (result[3] as PackedByteArray).get_string_from_utf8()
			module_config.unparsed_module_schema = json
			print_log(
				"Fetched schema for module: %s with alias: %s"
				% [module_config.name, module_config.alias]
			)
			continue

		if result[1] == 404:
			print_err("Module not found - %s" % [schema_uri])
		elif result[1] == 0:
			print_err("Request timeout - %s" % [schema_uri])
		else:
			print_err(
				"Failed to fetch module schema: %s - Response code %s"
				% [module_config.name, result[1]]
			)
		failed = true

	if failed:
		print_err("Code generation failed!")
		return false

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(BINDINGS_SCHEMA_PATH)
	codegen._plugin_config = config
	var generated_files: Array[String] = codegen.generate_bindings()

	if not finalize_bindings(codegen, generated_files, BINDINGS_SCHEMA_PATH):
		return false

	if DirAccess.dir_exists_absolute(LEGACY_DATA_PATH):
		print_log("Removing legacy data directory: %s" % LEGACY_DATA_PATH)
		DirAccess.remove_absolute(LEGACY_DATA_PATH)

	return true


func _register_autoload() -> void:
	var setting_name: String = "autoload/" + AUTOLOAD_NAME
	if ProjectSettings.has_setting(setting_name):
		var current_autoload: String = ProjectSettings.get_setting(setting_name)
		if current_autoload != "*%s" % AUTOLOAD_PATH:
			print_log("Removing old autoload path: %s" % current_autoload)
			ProjectSettings.set_setting(setting_name, null)

	if not ProjectSettings.has_setting(setting_name):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	var filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if filesystem.is_scanning():
		print_log("Waiting for existing filesystem scan to finish...")
		await filesystem.sources_changed
	filesystem.scan()
	print_log("Code generation complete!")


func _sanitize_uri() -> void:
	if plugin_config.uri.ends_with("/"):
		plugin_config.uri = plugin_config.uri.left(-1)
		save_codegen_data()


## Checks a finished codegen run and, only if it produced a complete and loadable set of
## bindings, prunes the files it replaced.
##
## [method SpacetimeCodegen.generate_bindings] is best-effort: a write that fails (a
## read-only checkout, a file the OS has locked, no space) or a module whose schema does
## not parse is reported and the run carries on, so the returned list can name only part
## of the bindings. Cleanup deletes every generated file the list does NOT name, so
## handing it a partial list turns "some files are stale" into "the previous run's output
## for those files is gone, along with the `.uid` sidecars every scene reference resolves
## through". Nothing is pruned unless the run was complete: stale bindings still load, and
## the next successful run replaces them.
##
## Takes [param dir_path] rather than reading [constant BINDINGS_SCHEMA_PATH] so a test
## can point the destructive half at a temp directory.
static func finalize_bindings(
	codegen: SpacetimeCodegen,
	generated_files: Array[String], # gdlint: ignore[S6] — what generate_bindings returns
	dir_path: String,
) -> bool:
	# A run over no modules writes nothing but the autoload and reports no failure, so
	# the incomplete flag cannot catch it — and cleanup against that one-file list
	# deletes every binding in the project. generate_schema refuses the empty config
	# before it gets this far; the invariant is restated here because this is the
	# function that does the deleting.
	if codegen._plugin_config == null or codegen._plugin_config.module_configs.is_empty():
		print_err("Code generation ran over no modules; leaving %s untouched." % dir_path)
		return false

	if codegen.generation_incomplete:
		print_err(
			"Code generation did not finish — see the errors above. The existing bindings "
			+ "in %s were left untouched; fix the cause and generate again." % dir_path
		)
		return false

	# The flag above is only ever set by code that RAN. A GDScript runtime fault unwinds
	# the function it happens in and hands its caller that function's default, so a run
	# that died inside generate_bindings' own frame arrives here with every flag exactly as
	# the last stage left it — indistinguishable from a clean run, and this is the function
	# that deletes files. Reaching its own tail is the only thing the run can say for
	# itself that a fault cannot fake.
	if not codegen.run_reached_return:
		print_err(
			"Code generation stopped before it finished (see the errors above). The existing "
			+ "bindings in %s were left untouched." % dir_path
		)
		return false

	# Both run, then one verdict: a module can hit either kind of collision, and a run
	# that reports only the first leaves the author fixing them one regeneration at a time.
	# The member check runs FIRST on purpose — it is the one that reports a file it could
	# not read back, which the class check then passes over in silence.
	var members_ok: bool = _check_member_collisions(PackedStringArray(generated_files))
	var classes_ok: bool = _check_class_collisions(PackedStringArray(generated_files), dir_path)
	if not (members_ok and classes_ok):
		print_err("Code generation failed!")
		return false

	_cleanup_unused_classes(dir_path, generated_files)
	_check_uid_collisions(dir_path)
	return true


static func _cleanup_unused_classes(dir_path: String = "res://schema", files: Array[String] = []) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if not dir:
		return
	print_log("File Cleanup: Scanning folder: " + dir_path)
	for file: String in dir.get_files():
		if not file.ends_with(".gd"):
			continue
		var full_path: String = "%s/%s" % [dir_path, file]
		if not full_path in files:
			print_log("Removing file: %s" % [full_path])
			DirAccess.remove_absolute(full_path)
			if FileAccess.file_exists("%s.uid" % [full_path]):
				DirAccess.remove_absolute("%s.uid" % [full_path])
	var subfolders: PackedStringArray = dir.get_directories()
	for folder: String in subfolders:
		_cleanup_unused_classes(dir_path + "/" + folder, files)


## Walks [param dir_path] recursively and appends every file ending in
## [param suffix] to [param out].
static func _collect_files_by_suffix(dir_path: String, suffix: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		if file_name.ends_with(suffix):
			out.append("%s/%s" % [dir_path, file_name])
	for sub: String in dir.get_directories():
		_collect_files_by_suffix("%s/%s" % [dir_path, sub], suffix, out)


## Deterministic binding uids share the full 63-bit id space with Godot's
## randomly-minted uids, so a clash is possible (~1e-13) — and because our ids
## are deterministic, a clash would reproduce on every clone. Scan the generated
## bindings for duplicate uid ids and report any that exist. If this ever fires,
## salt SpacetimeCodegen._stable_uid_id (e.g. prefix a version byte) and regenerate.
## Scoped to [param dir_path] (the bindings dir) — only our own ids are
## deterministic, so a wider res:// sweep buys nothing but I/O.
static func _check_uid_collisions(dir_path: String) -> void:
	var uid_files: PackedStringArray = []
	_collect_files_by_suffix(dir_path, ".uid", uid_files)
	var seen: Dictionary[int, String] = { }
	for path: String in uid_files:
		var text: String = FileAccess.get_file_as_string(path).strip_edges()
		if text.is_empty():
			continue
		var id: int = ResourceUID.text_to_id(text)
		if id == ResourceUID.INVALID_ID:
			continue
		if seen.has(id):
			print_err("UID collision (%s): %s <-> %s" % [text, seen[id], path])
		else:
			seen[id] = path


## Fails the run when a generated script declares the same member twice.
##
## Two schema names that differ only by a trailing underscore — a reducer `set` (which
## escapes to `set_`, because `Object.set` is taken) alongside a reducer literally named
## `set_` — land on one GDScript identifier. Godot refuses to load that script, and
## since the binding is one class per module, the whole module goes with it. The engine's
## message names the identifier but neither of the two schema names, and it only appears
## at load, far from the codegen run that caused it. Reported here instead, with the file.
##
## Deliberately fails the codegen rather than renaming one side: any automatic
## disambiguation picks a winner silently, and which of `set` / `set_` gets the mangled
## spelling is the module author's call, not ours.
static func _check_member_collisions(generated_files: PackedStringArray) -> bool:
	var ok: bool = true
	for path: String in generated_files:
		if not path.ends_with(".gd"):
			continue
		var source: String = FileAccess.get_file_as_string(path)
		if source.is_empty():
			# Empty is never legitimate here — codegen wrote every one of these files
			# moments ago, so this is a read that failed.
			print_err(
				"could not read back %s: %s" % [path, error_string(FileAccess.get_open_error())]
			)
			ok = false
			continue
		for variant: String in SpacetimeCodegen.find_duplicate_enum_variants(source):
			print_err(
				(
					"%s declares `%s` more than once. Enum variant names are pascal-cased, "
					+ "which cannot tell `foo_bar` from `fooBar`, and Godot refuses the whole "
					+ "script with \"Name was already in this enum\" — for the types facade "
					+ "that is every type the module declares. Rename one of them in your "
					+ "module."
				)
				% [path, variant]
			)
			ok = false
		for member: String in SpacetimeCodegen.find_duplicate_members(source):
			print_err(
				(
					"%s declares `%s` more than once. Two names in the module escape to "
					+ "the same GDScript identifier — most often a name and the same name "
					+ "with a trailing underscore, where the first was escaped because the "
					+ "bare spelling is taken by Godot or by the SDK base class. Rename one "
					+ "of them in your module."
				)
				% [path, member]
			)
			ok = false
	return ok


## Fails the run when two generated scripts claim the same global class name, or when two
## of them are written to the same path.
##
## Every generated class name is the module prefix plus a name the module author chose,
## and the suffixes the generator adds (`Table`, `UniqueIndex`, `BTreeIndex`, and the
## `Types` / `ModuleDb` / `ModuleClient` / `ModuleReducers` / `ModuleProcedures` facades)
## are ordinary spellings a module type may already end in. So a module carrying both a
## table `score` and a type `ScoreTable` emits `class_name <M>ScoreTable` twice, and Godot
## refuses whichever of the two it registers second — "Class "X" hides a global script
## class" — so that script does not load at all. Measured: the row type behind a column,
## or the db facade the generated client assigns to `db`, silently gone.
##
## The file-name half is quieter still. Paths are built with [method String.to_snake_case]
## and class names with [method String.to_pascal_case], and neither is injective across an
## acronym run: types `AABB` and `Aabb` both land on `<module>_aabb.gd`, so the second
## overwrites the first and one declared type has no bindings anywhere. Nothing errors,
## the run reports success, and [method _cleanup_unused_classes] then prunes the previous,
## working bindings.
##
## Deliberately fails the run rather than mangling a name, for the same reason
## [method _check_member_collisions] does: which of two colliding schema names gets the
## altered spelling is the module author's call, not ours.
static func _check_class_collisions(generated_files: PackedStringArray, dir_path: String) -> bool:
	var ok: bool = true
	var seen_paths: Dictionary[String, bool] = { }
	var path_by_class: Dictionary[String, String] = { }
	var claimed_elsewhere: Dictionary[String, String] = _global_classes_outside(dir_path)
	var autoload_names: Dictionary[String, String] = _autoload_names_outside(dir_path)
	for path: String in generated_files:
		if not path.ends_with(".gd"):
			continue
		# The class-name half below would also catch today's same-path pairs — both list
		# entries read back the one file that survived the overwrite, so its class name
		# looks declared twice. This branch is what makes the report name the actual cause
		# (a file that is simply gone, not two files fighting over a name), and it is the
		# only half that covers an emitted file kind declaring no class name at all.
		if seen_paths.has(path):
			print_err(
				(
					"two schema names both generated %s, so one overwrote the other and has "
					+ "no bindings at all. A file name is the schema name put through "
					+ "to_snake_case, which cannot tell `AABB` from `Aabb`. Rename one of them "
					+ "in your module."
				)
				% path
			)
			ok = false
			continue
		seen_paths[path] = true

		var source: String = FileAccess.get_file_as_string(path)
		if source.is_empty():
			# _check_member_collisions already reported this file as unreadable.
			continue
		var declared: String = SpacetimeCodegen.declared_class_name(source)
		if declared.is_empty():
			continue
		if ClassDB.class_exists(declared) or SpacetimeCodegen.is_builtin_type_name(declared):
			print_err(
				(
					"%s declares `class_name %s`, which is a Godot native class or builtin "
					+ "type — Godot refuses it with \"Class \"%s\" hides a native class\" (or "
					+ "\"a built-in type\"), so that script does not load. Rename the schema "
					+ "name it comes from, or give the module an alias."
				)
				% [path, declared, declared]
			)
			ok = false
			continue
		if autoload_names.has(declared):
			print_err(
				(
					"%s declares `class_name %s`, which is the name of the autoload declared "
					+ "at %s — Godot refuses it with \"Class \"%s\" hides an autoload "
					+ "singleton\", so that script does not load. Rename the schema name it "
					+ "comes from, give the module an alias, or rename the autoload."
				)
				% [path, declared, autoload_names[declared], declared]
			)
			ok = false
			continue
		if claimed_elsewhere.has(declared):
			print_err(
				(
					"%s declares `class_name %s`, which %s already declares. Godot registers "
					+ "one of them and refuses the other, so a script fails to load — the "
					+ "generated one, or the project's own. Rename the schema name it comes "
					+ "from, give the module an alias, or rename the other class."
				)
				% [path, declared, claimed_elsewhere[declared]]
			)
			ok = false
			continue
		if path_by_class.has(declared):
			print_err(
				(
					"%s and %s both declare `class_name %s`. Godot registers only one of them "
					+ "and refuses the other with \"Class \"%s\" hides a global script class\", "
					+ "so that script does not load. A generated class name is the module "
					+ "prefix plus a schema name plus the suffix its kind adds (Table, "
					+ "UniqueIndex, BTreeIndex) — a module type named `ScoreTable` collides "
					+ "with the table `score`, and one named `Types` or `ModuleDb` collides "
					+ "with the module's own facade. Rename one of them in your module."
				)
				% [path_by_class[declared], path, declared, declared]
			)
			ok = false
			continue
		path_by_class[declared] = path
	return ok


## Every global class the project registers from OUTSIDE [param dir_path], as
## name -> script path.
##
## The bindings directory is excluded because the previous run's output is registered
## under exactly the names this run is about to re-declare: comparing against it would
## refuse every regeneration. Everything else is fair game — a project class named
## `GamePlayer` beside a module `game` with a type `Player` is the same collision as two
## generated files claiming one name, and Godot answers it the same way.
##
## A headless run whose global class cache was never written (see docs/codegen.md) sees a
## short list and can only under-report, never refuse a name that is actually free.
static func _global_classes_outside(dir_path: String) -> Dictionary[String, String]:
	var out: Dictionary[String, String] = { }
	# rstrip takes every trailing slash and the format string puts exactly one back, so
	# "x", "x/" and "x//" all yield the same prefix. (A dir_path of "res://" excludes every
	# class in the project — correct by this function's own definition, and not a
	# configuration that exists: the bindings live in BINDINGS_SCHEMA_PATH.)
	var inside: String = "%s/" % dir_path.rstrip("/")
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		var path: String = entry.get("path", "")
		if path.is_empty() or path.begins_with(inside):
			continue
		var declared: String = entry.get("class", "")
		if not declared.is_empty():
			out[declared] = path
	return out


## Every autoload the project registers from OUTSIDE [param dir_path], as name -> the
## path it points at.
##
## A SINGLETON autoload's registered name is a global identifier of its own, so a class
## that reuses it is refused with "hides an autoload singleton" — and an autoload need not
## declare a `class_name`, so [method _global_classes_outside] cannot see it. Reachable: a
## module alias `save` plus a type `System` spells `SaveSystem`, which is the canonical
## name for a save autoload. The bindings directory is excluded for the same reason it is
## there: the generated autoload is registered from inside it.
##
## The leading `*` on the setting's value is the singleton flag, NOT "enabled": the
## analyzer refuses a name only when [code]has_autoload(name)[/code] AND that autoload's
## [code]is_singleton[/code] ([code]gdscript_analyzer.cpp[/code]), and `is_singleton` is
## set by exactly that character ([code]project_settings.cpp[/code]). A plain autoload
## boots as a node and claims no name, so a class may reuse it — measured, accepted.
static func _autoload_names_outside(dir_path: String) -> Dictionary[String, String]:
	var out: Dictionary[String, String] = { }
	var inside: String = "%s/" % dir_path.rstrip("/") # Same normalisation as above.
	for property: Dictionary in ProjectSettings.get_property_list():
		var setting: String = property.get("name", "")
		# Both registration prefixes: `autoload_prepend/` is equally valid and equally a
		# global identifier, though nothing in the engine or editor writes it today.
		if not (setting.begins_with("autoload/") or setting.begins_with("autoload_prepend/")):
			continue
		var raw: String = ProjectSettings.get_setting(setting, "")
		if not raw.begins_with("*"):
			continue
		var path: String = raw.substr(1)
		if path.begins_with("uid://"):
			# get_id_path on an unknown id is an ERR_FAIL that prints to the engine's own
			# output, where a codegen run's reader would never look for it. An unresolved
			# path stays empty, which reads as "outside dir_path" — the direction that
			# reports a collision rather than hiding one.
			var id: int = ResourceUID.text_to_id(path)
			path = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
		if path.begins_with(inside):
			continue
		out[setting.get_slice("/", 1)] = path
	return out
