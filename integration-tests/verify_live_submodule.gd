# Live end-to-end verification of namespaced submodules (SpacetimeDB 2.8.1+) against a
# running server with `integration-tests/verify_submodule_module` published as `vsubmod`.
#
# The generated bindings are what is under test: a submodule's table is reached through a
# namespace member (`db.lib.lib_data`), its reducer through the matching one
# (`reducers.lib.lib_insert`), and both have to address the server by the DOTTED name it
# registered them under. A nested namespace (`auth.baz`) covers a name carrying more than
# one dot, and each module's own typespace covers the type-ref hazard: `lib.lib_data.point`
# and `root_thing.point` sit at the same index in their own modules and are different types.
#
#   spacetime publish -p <repo>/integration-tests/verify_submodule_module \
#       -s http://127.0.0.1:3000 vsubmod --yes
#   # set the plugin config module to `vsubmod`, then:
#   cd godot-client && <godot> --headless --path . --script addons/SpacetimeDB/cli.gd
#   cd godot-client && <godot> --headless --path . --script verify_live_submodule.gd
#   # Expect: ALL PASS (8/8)
extends SceneTree

var _client: VsubmodModuleClient
var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	_client = VsubmodModuleClient.new()
	root.add_child(_client)
	await process_frame # let the client + its HTTPRequest enter the tree before connecting

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	options.save_token = false
	# Wired BEFORE the attempt: auto_reconnect is off by default, so a server that is not
	# running — or a `vsubmod` that was never published, which this file's own setup recipe
	# invites — emits connection_error once and never `connected`. Without this the await
	# below simply never resumes and the run hangs with nothing printed.
	_client.connection_error.connect(_on_connection_error)
	_client.connect_db("http://127.0.0.1:3000", "vsubmod", options)

	await _client.connected
	print("connected")

	# subscribe_all_tables builds `SELECT * FROM <name>` per entry of the generated
	# `table_names`, so a namespaced table only arrives if that list carries wire names.
	# wait_for_applied, not `await sub.applied`: a subscription the server rejects — which
	# is what a wrong table name looks like — ends without ever applying.
	var sub: SpacetimeDBSubscription = _client.subscribe_all_tables()
	var applied: Error = await sub.wait_for_applied(10.0)
	if applied != OK:
		printerr(
			(
				"FAIL  subscribe_all_tables did not apply (error %d): %s"
				% [applied, sub.error_message]
			)
		)
		_client.disconnect_db()
		quit(1)
		return
	print("subscribed")

	_case_table_names()
	await _case_root()
	await _case_submodule()
	await _case_nested_submodule()
	_case_private_table_absent()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	_client.disconnect_db()
	quit(_fails)


func _on_connection_error(code: int, reason: String) -> void:
	printerr("FAIL  connection error %d: %s" % [code, reason])
	quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_total += 1
	if ok:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s%s" % [label, "" if detail.is_empty() else ": " + detail])


# The names the client subscribes and the server dispatches on, dots intact.
func _case_table_names() -> void:
	var names: Array[StringName] = _client.db.table_names
	_check(
		"table_names carry the dotted wire names",
		names.has(&"lib.lib_data") and names.has(&"auth.baz.baz_items") and names.has(&"root_thing"),
		str(names),
	)


func _case_root() -> void:
	var call: SpacetimeDBReducerCall = _client.reducers.root_insert(5)
	await call.wait_for_response(5.0)
	if not call.is_ok():
		_check("root reducer", false, "outcome %d (%s)" % [call.outcome, call.error_message])
		return
	_check("root reducer accepted", true)
	var row: VsubmodRootThing = _client.db.root_thing.first_by_id(5)
	if row == null:
		_check("root row in cache", false, "no row with id 5")
		return
	_check("root row decodes its own type", row.point != null and row.point.x == 5, str(row.point))


# A submodule's table and reducer, reached through the namespace member and addressed by
# the dotted name. `point` is the submodule's own LibPoint (two strings), which shares a
# typespace index with the root's RootPoint (one u64).
func _case_submodule() -> void:
	var call: SpacetimeDBReducerCall = _client.reducers.lib.lib_insert(7)
	await call.wait_for_response(5.0)
	if not call.is_ok():
		_check(
			"submodule reducer lib.lib_insert",
			false,
			"outcome %d (%s)" % [call.outcome, call.error_message],
		)
		return
	_check("submodule reducer lib.lib_insert accepted", true)
	var row: VsubmodLibLibData = _client.db.lib.lib_data.first_by_id(7)
	if row == null:
		_check("submodule row in cache", false, "no row with id 7 in lib.lib_data")
		return
	_check(
		"submodule row binds its OWN typespace entry",
		row.point != null and row.point.a == "a-7" and row.point.b == "b-7",
		str(row.point),
	)


# Namespaces nest, so this table's wire name carries two dots.
func _case_nested_submodule() -> void:
	var call: SpacetimeDBReducerCall = _client.reducers.auth.baz.baz_insert(3)
	await call.wait_for_response(5.0)
	if not call.is_ok():
		_check(
			"nested reducer auth.baz.baz_insert",
			false,
			"outcome %d (%s)" % [call.outcome, call.error_message],
		)
		return
	_check("nested reducer auth.baz.baz_insert accepted", true)
	var row: VsubmodAuthBazBazItems = _client.db.auth.baz.baz_items.first_by_id(3)
	if row == null:
		_check("nested row in cache", false, "no row with id 3 in auth.baz.baz_items")
		return
	_check("nested row round-trips", row.item != null and row.item.label == "baz-3", str(row.item))


# `lib.lib_secret` is private. With the module's hide_private_tables set (the default), it
# is generated for neither the facade nor the subscription list.
func _case_private_table_absent() -> void:
	var names: Array[StringName] = _client.db.table_names
	_check(
		"private submodule table is not generated",
		not names.has(&"lib.lib_secret") and not (&"lib_secret" in _client.db.lib),
		str(names),
	)
