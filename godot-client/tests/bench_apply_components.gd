extends SceneTree
signal row_sig(table: StringName, row: Resource)
const N: int = 100000
const REPS: int = 7


func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for r: int in REPS:
		var s: int = Time.get_ticks_usec()
		fn.call()
		var el: int = Time.get_ticks_usec() - s
		if el < best:
			best = el
	return best


func _noop(_t: StringName, _r: Resource) -> void:
	pass


func _initialize() -> void:
	var rows: Array = []
	for i: int in N:
		rows.append(Resource.new())
	var keys: Array = []
	for i: int in N:
		keys.append(i)

	# (a) Variant-keyed dict set (pk_value is Variant) x N
	var d: Dictionary = { }
	var a_us: int = _best(
		func() -> void:
			d.clear()
			for i: int in N:
				d[keys[i]] = rows[i]
	)

	# (b) dict.get(pk) lookup x N (the prev fetch in update path)
	var b_us: int = _best(
		func() -> void:
			var sink: int = 0
			for i: int in N:
				if d.get(keys[i]) != null:
					sink += 1
	)

	# (c)/(c2)/(d) per-row signal emit x N.
	# A signal that has NEVER been connected emits ~1.8x slower (~145 ns) than the
	# same signal after one connect+disconnect cycle (~80 ns) — the connection slot
	# is allocated lazily on first connect, and emit hits the cheaper path once it
	# exists. It is not a warmup or measurement-order effect: a discard pass before
	# timing does not close the gap, and the cheap number only appears after a
	# disconnect. Both are reported because neither alone is "the" 0-listener cost.
	# The SDK's own row signals always have the client forwarder attached, so (d) is
	# the figure that describes production; (c2) is the floor if it ever detaches.
	var emit_all: Callable = func() -> void:
		for i: int in N:
			row_sig.emit(&"entity", rows[i])
	var c0_virgin_us: int = _best(emit_all)
	row_sig.connect(_noop)
	var c1_us: int = _best(emit_all)
	row_sig.disconnect(_noop)
	var c0_us: int = _best(emit_all)

	# (e) Resource.get(StringName) property fetch x N
	var ent: Resource = rows[0]
	var e_us: int = _best(
		func() -> void:
			var sink: int = 0
			for i: int in N:
				if ent.get(&"resource_name") != null:
					sink += 1
	)

	print("per-N=%d, ns/op:" % N)
	print("  (a) dict[var]=row set     : %.0f" % [a_us * 1000.0 / N])
	print("  (b) dict.get(var)         : %.0f" % [b_us * 1000.0 / N])
	print("  (c) signal.emit 0 listener, never connected : %.0f" % [c0_virgin_us * 1000.0 / N])
	print("  (c2) signal.emit 0 listener, after disconnect: %.0f" % [c0_us * 1000.0 / N])
	print("  (d) signal.emit 1 listener: %.0f" % [c1_us * 1000.0 / N])
	print("  (e) Resource.get(SName)   : %.0f" % [e_us * 1000.0 / N])
	quit()
