# Guards the signal arity that SpacetimeDBClient._wait_for_response depends on.
#
# That helper connects a two-argument handler, (request_id, payload), to whichever
# response signal it awaits. `one_off_query_received` carries a third argument
# (error_message), so connecting the handler directly is an arity mismatch: Godot
# refuses the call, the handler never runs, and the caller waits out its whole
# timeout and gets null. query_sql returned an empty array for every query because
# of this, and had no test of any kind to catch it.
#
# The fix drops the extra argument with Callable.unbind, told how many to drop by
# a `trailing_args_to_drop` argument at each call site.
#
# This test reads those call sites out of the source and checks each one against
# the real arity of the signal it passes. Asserting arity against a table kept in
# this file would only be a tripwire — someone could update the table and not the
# call site, and the bug would come straight back.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_response_signal_arity.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const CLIENT_SOURCE: String = "res://addons/SpacetimeDB/core/spacetimedb_client.gd"

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_call_sites_match_signal_arity()
	fails += _test_unbind_lets_the_handler_run()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# Every _wait_for_response call must drop exactly the arguments its signal carries
# beyond (request_id, payload).
func _test_call_sites_match_signal_arity() -> int:
	var arities: Dictionary[StringName, int] = _client_signal_arities()
	var call_sites: Array[Dictionary] = _wait_for_response_call_sites()

	var f: int = _check_b("found the call sites", call_sites.is_empty(), false)
	for site: Dictionary in call_sites:
		var signal_name: StringName = site["signal"]
		var arity: int = arities.get(signal_name, -1)
		f += _check_i(
			"%s: drops %d for a %d-arg signal" % [signal_name, site["drop"], arity],
			site["drop"],
			maxi(arity - 2, 0),
		)
	return f


func _client_signal_arities() -> Dictionary[StringName, int]:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var out: Dictionary[StringName, int] = { }
	for entry: Dictionary in client.get_signal_list():
		out[StringName(entry["name"])] = (entry["args"] as Array).size()
	client.free()
	return out


# Pulls each `_wait_for_response(...)` CALL out of the client source and reports
# the signal it passes plus its trailing_args_to_drop (0 when omitted).
func _wait_for_response_call_sites() -> Array[Dictionary]:
	var source: String = FileAccess.get_file_as_string(CLIENT_SOURCE)
	var out: Array[Dictionary] = []
	var from: int = 0
	while true:
		var at: int = source.find("_wait_for_response(", from)
		if at == -1:
			break
		from = at + 1
		# Skip the declaration itself; only calls carry arguments to check.
		var line_start: int = source.rfind("\n", at) + 1
		if source.substr(line_start, at - line_start).contains("func "):
			continue
		var args: PackedStringArray = _split_args(source, source.find("(", at))
		if args.size() < 3:
			continue
		var signal_name: StringName = StringName(args[2])
		var drop: int = int(args[4]) if args.size() >= 5 else 0
		out.append({ "signal": signal_name, "drop": drop })
	return out


# Splits a call's argument list on top-level commas, trimming comments.
func _split_args(source: String, open_paren: int) -> PackedStringArray:
	var depth: int = 0
	var args: PackedStringArray = []
	var current: String = ""
	for i: int in range(open_paren, source.length()):
		var c: String = source[i]
		if c == "(" or c == "[":
			depth += 1
			if depth == 1:
				continue
		elif c == ")" or c == "]":
			depth -= 1
			if depth == 0:
				args.append(_clean_arg(current))
				return args
		if depth == 1 and c == ",":
			args.append(_clean_arg(current))
			current = ""
			continue
		current += c
	return args


func _clean_arg(raw: String) -> String:
	var text: String = raw
	var comment: int = text.find("#")
	if comment != -1:
		text = text.substr(0, comment)
	return text.strip_edges()


# The mechanism itself: a two-argument handler must still fire for a
# three-argument signal once the extra argument is unbound, and must receive the
# LEADING arguments (unbind drops from the end).
func _test_unbind_lets_the_handler_run() -> int:
	var relay: _ArityRelay = _ArityRelay.new()
	var seen: Array = [0, ""]
	var handler: Callable = func(rid: int, payload: Variant) -> void:
		seen[0] = rid
		seen[1] = str(payload)

	var bound: Callable = handler.unbind(1)
	relay.three_arg.connect(bound)
	relay.three_arg.emit(7, "payload", "an error message")
	relay.three_arg.disconnect(bound)

	var f: int = _check_i("handler received the request id", seen[0], 7)
	f += _check_s("handler received the payload, not the error", str(seen[1]), "payload")
	return f


class _ArityRelay:
	extends RefCounted
	signal three_arg(request_id: int, payload: Variant, error_message: String)


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
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1
