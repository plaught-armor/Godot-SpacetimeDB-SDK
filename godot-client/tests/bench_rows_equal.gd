extends SceneTree

# Synthetic all-primitive row (maximizes full-field walk — no object field to bail early).
class Row:
	extends RefCounted
	var a: int
	var b: int
	var c: float
	var d: float
	var e: String
	var f: int
	func _row_eq(o: Row) -> bool:
		return a == o.a and b == o.b and c == o.c and d == o.d and e == o.e and f == o.f

# Exact copy of LocalDatabase._rows_equal dynamic path.
static func rows_equal_dynamic(x: Object, y: Object, props: Array[StringName]) -> bool:
	for prop_name: StringName in props:
		if x.get(prop_name) != y.get(prop_name):
			return false
	return true

func _make() -> Row:
	var r: Row = Row.new()
	r.a = 7; r.b = 42; r.c = 1.5; r.d = 2.5; r.e = "hello"; r.f = 99
	return r

func _init() -> void:
	var x: Row = _make()
	var y: Row = _make()   # equal values, distinct instance — worst case (full walk, returns true)
	var props: Array[StringName] = [&"a", &"b", &"c", &"d", &"e", &"f"]
	const N: int = 3_000_000
	const TRIALS: int = 7

	var best_dyn: int = 1 << 62
	var best_typed: int = 1 << 62
	var sink: int = 0
	for t: int in TRIALS:
		var s0: int = Time.get_ticks_usec()
		for i: int in N:
			if rows_equal_dynamic(x, y, props): sink += 1
		var e0: int = Time.get_ticks_usec() - s0
		if e0 < best_dyn: best_dyn = e0

		var s1: int = Time.get_ticks_usec()
		for i: int in N:
			if x._row_eq(y): sink += 1
		var e1: int = Time.get_ticks_usec() - s1
		if e1 < best_typed: best_typed = e1

	print("rows: 6 primitive fields, equal case (full walk), N=%d best-of-%d" % [N, TRIALS])
	print("  dynamic .get() loop : %6.1f ms  (%.1f ns/call)" % [best_dyn/1000.0, best_dyn*1000.0/N])
	print("  typed _row_eq()     : %6.1f ms  (%.1f ns/call)" % [best_typed/1000.0, best_typed*1000.0/N])
	print("  speedup             : %.2fx" % [float(best_dyn)/float(best_typed)])
	print("  per-call saved      : %.1f ns" % [(best_dyn-best_typed)*1000.0/N])
	print("  (sink=%d)" % sink)
	quit()
