# Unit test for telling a failed decode apart from "nothing to decode".
#
# `decode()` returns null for three different reasons — a unit reducer, no declared
# return type, and bytes that failed to parse — and before `has_decode_error()` a caller
# could not tell the last one from the rest: corrupt or truncated return bytes read
# exactly like a reducer that returned nothing. (An `opt_` return is not one of them; it
# decodes to an Option whose is_none() is true, never to a bare null.)
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_decode_error_visibility.gd
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_reducer_nothing_to_decode()
	f += _test_reducer_good_bytes()
	f += _test_reducer_truncated_bytes()
	f += _test_reducer_error_is_reset_between_decodes()
	f += _test_procedure()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## A client with only the decode path wired: `decode()` reaches for
## `_decode_deserializer` and nothing else, and a null schema is enough for the
## primitive types used here.
func _make_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client._decode_deserializer = BSATNDeserializer.new(null, false)
	return client


func _u32_bytes(value: int) -> PackedByteArray:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(value)
	return spb.data_array


func _test_reducer_nothing_to_decode() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _make_client()

	# Unit reducer: bytes are empty, so there is nothing to decode and nothing wrong.
	var unit: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 1, &"u32")
	f += _check("unit: decode is null", unit.decode() == null, true)
	f += _check("unit: has_return_value false", unit.has_return_value(), false)
	f += _check("unit: no decode error", unit.has_decode_error(), false)

	# Bytes but no declared type — a hand-written call_reducer. Same story.
	var untyped: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 2)
	untyped.ret_value = _u32_bytes(7)
	f += _check("untyped: decode is null", untyped.decode() == null, true)
	f += _check("untyped: has_return_value false", untyped.has_return_value(), false)
	f += _check("untyped: no decode error", untyped.has_decode_error(), false)

	# A fail() handle carries no client at all; decode() must not reach through it.
	var failed: SpacetimeDBReducerCall = SpacetimeDBReducerCall.fail(ERR_UNAVAILABLE)
	failed.ret_value = _u32_bytes(7)
	f += _check("fail(): decode is null", failed.decode() == null, true)
	f += _check("fail(): has_return_value false", failed.has_return_value(), false)

	# fail() leaves the type empty too, so the check above passes on the type alone and
	# never reaches the null-client guard. Build the one shape that does: bytes AND a
	# declared type AND no client. Not reachable through the public API — create()
	# always sets a client — but decode() dereferences _client, so the guard is what
	# stands between an internal misuse and a crash.
	var clientless: SpacetimeDBReducerCall = SpacetimeDBReducerCall.new()
	clientless._ret_bsatn_type = &"u32"
	clientless.ret_value = _u32_bytes(7)
	f += _check("no client: has_return_value false", clientless.has_return_value(), false)
	f += _check("no client: decode is null, no crash", clientless.decode() == null, true)

	client.free()
	return f


func _test_reducer_good_bytes() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _make_client()
	var call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 3, &"u32")
	call.ret_value = _u32_bytes(4242)

	f += _check("ok: has_return_value true", call.has_return_value(), true)
	f += _check_i("ok: decodes the value", call.decode(), 4242)
	f += _check("ok: no decode error", call.has_decode_error(), false)
	f += _check("ok: message empty", call.decode_error_message.is_empty(), true)

	client.free()
	return f


func _test_reducer_truncated_bytes() -> int:
	# The shape this exists for: two bytes where a u32 was promised. Before, this was
	# indistinguishable from a unit reducer — same null, no signal anywhere.
	var f: int = 0
	var client: SpacetimeDBClient = _make_client()
	var call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 4, &"u32")
	call.ret_value = _u32_bytes(4242).slice(0, 2)

	f += _check("truncated: has_return_value true", call.has_return_value(), true)
	f += _check("truncated: decode is null", call.decode() == null, true)
	f += _check("truncated: decode error reported", call.has_decode_error(), true)
	f += _check("truncated: message non-empty", call.decode_error_message.is_empty(), false)

	client.free()
	return f


func _test_reducer_error_is_reset_between_decodes() -> int:
	# The handle outlives the call, so a stale error would make every later decode look
	# broken — and the deserializer is shared, so a stale one there would poison the
	# next handle's decode entirely.
	var f: int = 0
	var client: SpacetimeDBClient = _make_client()

	var bad: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 5, &"u32")
	bad.ret_value = _u32_bytes(1).slice(0, 1)
	bad.decode()
	f += _check("reset: first decode errored", bad.has_decode_error(), true)

	# Same handle, now given whole bytes.
	bad.ret_value = _u32_bytes(9)
	f += _check_i("reset: second decode succeeds", bad.decode(), 9)
	f += _check("reset: error cleared", bad.has_decode_error(), false)

	# A different handle on the same client must not inherit the earlier failure.
	var other: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 6, &"u32")
	other.ret_value = _u32_bytes(11)
	f += _check_i("reset: other handle decodes", other.decode(), 11)
	f += _check("reset: other handle clean", other.has_decode_error(), false)

	client.free()
	return f


func _test_procedure() -> int:
	# Procedures carry the same decode path against `return_bytes`.
	var f: int = 0
	var client: SpacetimeDBClient = _make_client()

	var empty: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.create(client, 7, &"u32")
	f += _check("procedure empty: decode is null", empty.decode() == null, true)
	f += _check("procedure empty: no decode error", empty.has_decode_error(), false)

	var ok: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.create(client, 8, &"u32")
	ok.return_bytes = _u32_bytes(77)
	f += _check_i("procedure ok: decodes the value", ok.decode(), 77)
	f += _check("procedure ok: no decode error", ok.has_decode_error(), false)

	var bad: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.create(client, 9, &"u32")
	bad.return_bytes = _u32_bytes(77).slice(0, 3)
	f += _check("procedure bad: decode is null", bad.decode() == null, true)
	f += _check("procedure bad: decode error reported", bad.has_decode_error(), true)

	var failed: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.fail(ERR_UNAVAILABLE)
	failed.return_bytes = _u32_bytes(77)
	f += _check("procedure fail(): decode is null", failed.decode() == null, true)

	client.free()
	return f


func _check(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: Variant, want: int) -> int:
	_total += 1
	if got is int and got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %d" % [label, got, want])
	return 1
