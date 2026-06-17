# Live check: a named enum-with-payload column (Shape) round-trips as a RustEnum.
# Module: verify_enum_column_module, published as `vsum`. Read path only (the
# reducer constructs the enum server-side). Confirms RustEnum-as-Resource lets the
# generated `@export var shape: VsumShape` field deserialize via the nested-resource
# -> is-RustEnum path.
extends SceneTree
func _initialize() -> void: _run()
func _run() -> void:
	var c: VsumModuleClient = VsumModuleClient.new()
	root.add_child(c)
	await process_frame
	var o: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	o.compression = SpacetimeDBConnection.CompressionPreference.NONE
	o.one_time_token = true
	o.save_token = false
	c.connect_db("http://127.0.0.1:3000", "vsum", o)
	await c.connected
	var s: SpacetimeDBSubscription = c.subscribe(["SELECT * FROM shape_row"])
	await s.applied
	await c.reducers.add_shape(1, 7).wait_for_response(5.0)
	var rows: Array = c.db.shape_row.iter()
	if rows.is_empty():
		printerr("FAIL: no shape row")
	else:
		var sh: RustEnum = rows[0].get(&"shape")
		var ok: bool = sh != null and sh is RustEnum and sh.value == 0 and sh.data == 7
		print("%s enum-with-payload column: value=%s data=%s" % ["PASS" if ok else "FAIL", str(sh.value), str(sh.data)])
	c.disconnect_db()
	quit(0)
