# Live check: an anonymous inline Result<T, E> column round-trips as a synthesized
# RustEnum. Module: verify_enum_column_module (res_row.r: Result<i32, String>),
# published as `vsum`. The parser synthesizes a named `VsumResultI32String` RustEnum
# type (Options{ok, err}, ENUM_OPTIONS [i32, string]) so the field rides the standard
# enum-with-payload codegen + BSATN path.
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
	var s: SpacetimeDBSubscription = c.subscribe(["SELECT * FROM res_row"])
	await s.applied
	await c.reducers.add_res(1, true).wait_for_response(5.0)   # Ok(42)
	await c.reducers.add_res(2, false).wait_for_response(5.0)  # Err("bad")
	var ok_row: Variant = c.db.res_row.first_where(func(r): return r.id == 1)
	var err_row: Variant = c.db.res_row.first_where(func(r): return r.id == 2)
	var okr: RustEnum = ok_row.get(&"r") if ok_row else null
	var errr: RustEnum = err_row.get(&"r") if err_row else null
	var ok_pass: bool = okr != null and okr.value == 0 and okr.data == 42
	var err_pass: bool = errr != null and errr.value == 1 and errr.data == "bad"
	print("%s Result Ok: value=%s data=%s" % ["PASS" if ok_pass else "FAIL", str(okr.value), str(okr.data)])
	print("%s Result Err: value=%s data=%s" % ["PASS" if err_pass else "FAIL", str(errr.value), str(errr.data)])
	c.disconnect_db()
	quit(0)
