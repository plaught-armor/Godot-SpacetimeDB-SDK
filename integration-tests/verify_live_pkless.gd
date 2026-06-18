# Live check: a PK-less table refcounts rows by value across overlapping subscriptions.
# Module: verify_enum_column_module (note: pk-less table), published as `vsum`.
# Subscribes "SELECT * FROM note" twice (so the row is held by two query sets),
# inserts one note, and confirms on_insert fires once, the row survives the first
# unsubscribe, and on_delete fires only on the last.
extends SceneTree
var c: VsumModuleClient
var ins: int = 0
var dels: int = 0
func _initialize() -> void: _run()
func _oi(_r: _ModuleTableType) -> void: ins += 1
func _od(_r: _ModuleTableType) -> void: dels += 1
func _p(label: String, cond: bool) -> void: print("%s %s" % ["PASS" if cond else "FAIL", label])
func _run() -> void:
	c = VsumModuleClient.new()
	root.add_child(c)
	await process_frame
	var o: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	o.compression = SpacetimeDBConnection.CompressionPreference.NONE
	o.one_time_token = true
	o.save_token = false
	c.connect_db("http://127.0.0.1:3000", "vsum", o)
	await c.connected
	c.db.note.on_insert(_oi)
	c.db.note.on_delete(_od)
	var a: SpacetimeDBSubscription = c.subscribe(["SELECT * FROM note"])
	await a.applied
	var b: SpacetimeDBSubscription = c.subscribe(["SELECT * FROM note"])
	await b.applied
	await c.reducers.add_note("hello").wait_for_response(5.0)
	_p("shared insert fires once", ins == 1 and c.db.note.count() == 1)
	a.unsubscribe()
	await a.end
	_p("survives first unsubscribe", c.db.note.count() == 1 and dels == 0)
	b.unsubscribe()
	await b.end
	_p("evicted on last unsubscribe", c.db.note.count() == 0 and dels == 1)
	c.disconnect_db()
	quit(0)
