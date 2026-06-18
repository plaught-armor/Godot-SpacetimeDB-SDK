# Adversarial coverage for the nested-plan hoist (_read_nested_hoisted). Hardens
# the just-shipped hot-path code against malformed input:
#   A) Deep nesting (FuzzRoot -> FuzzMid -> FuzzLeaf) parses correctly — exercises
#      the hoist's recursion through >1 nested level.
#   B) Truncation sweep: every prefix length of a nested-bearing row must set the
#      error flag and never crash; the full length must parse with a clean trailing
#      desync canary.
#   C) Garbage fuzz: thousands of random-length random-byte buffers through a reused
#      deserializer must never crash, hang, or leave inconsistent error state
#      (proves the lazy nested_plan_ready flag + error recovery survive repetition).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_nested_hoist_fuzz.gd
#
# Exit code = number of failed checks (0 = all pass). A crash/hang (nonzero exit
# without the summary line) is itself a failure surfaced by CI.
extends SceneTree

const GARBAGE_ITERS: int = 4000
const MAX_GARBAGE_LEN: int = 48

var _total: int = 0
var _rng_state: int = 0x1234567


func _initialize() -> void:
	var fails: int = 0
	fails += _test_deep_nest_correct()
	fails += _test_truncation_entity()
	fails += _test_truncation_deep()
	fails += _test_garbage_no_crash()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# Schema knows the blackholio + core types AND the injected fuzz chain, so the hoist
# resolves FuzzMid/FuzzLeaf via _schema.get_type at plan-build.
func _schema() -> SpacetimeDBSchema:
	var s: SpacetimeDBSchema = SpacetimeDBSchema.new("blackholio")
	s.types[&"fuzzroot"] = FuzzRoot
	s.types[&"fuzzmid"] = FuzzMid
	s.types[&"fuzzleaf"] = FuzzLeaf
	return s


func _reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var r: StreamPeerBuffer = StreamPeerBuffer.new()
	r.data_array = bytes
	r.seek(0)
	return r


# A) FuzzRoot wire = mid{leaf{v:i32}} + tail:i32. No length prefixes (pure products).
func _test_deep_nest_correct() -> int:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_32(777) # mid.leaf.v
	w.put_32(12345) # tail

	var d: BSATNDeserializer = BSATNDeserializer.new(_schema(), false)
	var root: FuzzRoot = FuzzRoot.new()
	d._populate_resource_from_bytes(root, _reader(w.data_array))

	var f: int = 0
	f += _check_b("deep: no error", d.has_error(), false)
	f += _check_b("deep: mid non-null", root.mid != null, true)
	if root.mid != null:
		f += _check_b("deep: mid.leaf non-null", root.mid.leaf != null, true)
		if root.mid.leaf != null:
			f += _check_i("deep: mid.leaf.v", root.mid.leaf.v, 777)
	f += _check_i("deep: tail canary", root.tail, 12345)
	return f


# B) BlackholioEntity (16B: i32 + DbVector2{f32,f32} + i32). Every truncated prefix
#    must error without crashing; full length must parse clean.
func _test_truncation_entity() -> int:
	var full: PackedByteArray = _build_entity(5, 1.5, -2.5, 99)
	var f: int = 0
	for n: int in range(full.size()): # 0..15 — all short
		var d: BSATNDeserializer = BSATNDeserializer.new(_schema(), false)
		var e: BlackholioEntity = BlackholioEntity.new()
		d._populate_resource_from_bytes(e, _reader(full.slice(0, n)))
		f += _check_b("trunc-entity len=%d errors" % n, d.has_error(), true)

	var d2: BSATNDeserializer = BSATNDeserializer.new(_schema(), false)
	var e2: BlackholioEntity = BlackholioEntity.new()
	d2._populate_resource_from_bytes(e2, _reader(full))
	f += _check_b("trunc-entity full: no error", d2.has_error(), false)
	f += _check_i("trunc-entity full: mass canary", e2.mass, 99)
	return f


# B2) Deep chain truncation: a short read inside the nested chain must error, not
#     silently return a half-built object or desync the tail.
func _test_truncation_deep() -> int:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_32(777)
	w.put_32(12345)
	var full: PackedByteArray = w.data_array
	var f: int = 0
	for n: int in range(full.size()): # 0..7
		var d: BSATNDeserializer = BSATNDeserializer.new(_schema(), false)
		var root: FuzzRoot = FuzzRoot.new()
		d._populate_resource_from_bytes(root, _reader(full.slice(0, n)))
		f += _check_b("trunc-deep len=%d errors" % n, d.has_error(), true)
	return f


# C) Random buffers through a REUSED deserializer: must never crash/hang and must
#    leave queryable, consistent state every iteration.
func _test_garbage_no_crash() -> int:
	var d: BSATNDeserializer = BSATNDeserializer.new(_schema(), false)
	var clean: bool = true
	var i: int = 0
	while i < GARBAGE_ITERS: # bounded loop — no while-true
		i += 1
		var bytes: PackedByteArray = _garbage()
		# Alternate the two nested-bearing shapes so both hoist paths see garbage.
		var target: Object = BlackholioEntity.new() if (i & 1) == 0 else FuzzRoot.new()
		d._populate_resource_from_bytes(target, _reader(bytes))
		# State must be a real bool either way; a short buffer must have errored.
		var errored: bool = d.has_error()
		if bytes.size() < 8 and not errored:
			clean = false
		d.clear_error() # reset for next iteration (also exercises error recovery)
	return _check_b("garbage: %d iters, no crash + consistent state" % GARBAGE_ITERS, clean, true)


func _build_entity(eid: int, x: float, y: float, mass: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_32(eid)
	w.put_float(x)
	w.put_float(y)
	w.put_32(mass)
	return w.data_array


# Deterministic LCG (Math.random would be non-reproducible). Returns a random-length
# buffer of random bytes.
func _rand() -> int:
	_rng_state = (_rng_state * 1103515245 + 12345) & 0x7fffffff
	return _rng_state


func _garbage() -> PackedByteArray:
	var n: int = _rand() % (MAX_GARBAGE_LEN + 1)
	var b: PackedByteArray = PackedByteArray()
	b.resize(n)
	for j: int in range(n):
		b[j] = _rand() & 0xFF
	return b


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1
