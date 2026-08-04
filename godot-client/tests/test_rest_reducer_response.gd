# What SpacetimeDBRestAPI makes of the responses the server actually sends to
# POST /v1/database/<db>/call/<reducer>.
#
# The shapes are fixed by the server (crates/client-api/src/routes/database.rs):
#   - a reducer that commits    -> 200 with an EMPTY body
#   - a reducer that errors     -> 530 with the module's message as the body
#   - a procedure               -> 200 with its return value as JSON, which is
#                                  an AlgebraicValue and so any JSON value
# Demanding a JSON object turned the first of those into a failure, which left
# reducer_call_completed unable to fire for a reducer at all.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_rest_reducer_response.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _completed_count: int = 0
var _completed_result: Variant = null
var _failed_count: int = 0
var _failed_code: int = 0
var _failed_body: String = ""


func _initialize() -> void:
	var fails: int = 0
	# The case that was inverted: a committed reducer.
	fails += _case("committed reducer", HTTPRequest.RESULT_SUCCESS, 200, "", true, null)
	# Procedure return values — any JSON value, not just an object.
	fails += _case("procedure object", HTTPRequest.RESULT_SUCCESS, 200, '{"a":1}', true, { "a": 1 })
	fails += _case("procedure array", HTTPRequest.RESULT_SUCCESS, 200, "[1,2]", true, [1, 2])
	fails += _case("procedure number", HTTPRequest.RESULT_SUCCESS, 200, "42", true, 42)
	fails += _case("procedure string", HTTPRequest.RESULT_SUCCESS, 200, '"hi"', true, "hi")
	fails += _case("procedure null", HTTPRequest.RESULT_SUCCESS, 200, "null", true, null)
	# Failures must stay failures.
	fails += _failure_case("reducer error 530", HTTPRequest.RESULT_SUCCESS, 530, "no such player")
	fails += _failure_case("not found 404", HTTPRequest.RESULT_SUCCESS, 404, "nope")
	fails += _failure_case("malformed body", HTTPRequest.RESULT_SUCCESS, 200, "{not json")
	fails += _failure_case("transport timeout", HTTPRequest.RESULT_TIMEOUT, 0, "")

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# Drives one response through the completion handler with a REDUCER_CALL pending,
# and returns the API node's observations. Freed per case so no listener leaks
# into the next.
func _drive(result_code: int, response_code: int, body_text: String) -> void:
	_completed_count = 0
	_completed_result = null
	_failed_count = 0
	_failed_code = 0
	_failed_body = ""

	var api: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:3000", false)
	api._pending_request_type = SpacetimeDBRestAPI.RequestType.REDUCER_CALL
	api.reducer_call_completed.connect(_on_completed)
	api.reducer_call_failed.connect(_on_failed)
	api._on_request_completed(
		result_code,
		response_code,
		PackedStringArray(),
		body_text.to_utf8_buffer(),
	)
	api.free()


func _case(
	label: String,
	result_code: int,
	response_code: int,
	body_text: String,
	want_completed: bool,
	want_result: Variant,
) -> int:
	_drive(result_code, response_code, body_text)
	var f: int = 0
	f += _check_i("%s: completed fired" % label, _completed_count, 1 if want_completed else 0)
	f += _check_i("%s: failed did not fire" % label, _failed_count, 0)
	f += _check_b("%s: result" % label, _same(_completed_result, want_result), true)
	return f


# `==` on a Dictionary / Array is a recursive value compare that is strict on each
# element's Variant type, and JSON decodes every number to a float — so a decoded body
# never equals an equivalent literal written with int values. Walk the containers and
# compare the leaves with `==`, which does reconcile a float with an int.
func _same(got: Variant, want: Variant) -> bool:
	if got is Dictionary and want is Dictionary:
		var g: Dictionary = got
		var w: Dictionary = want
		if g.size() != w.size():
			return false
		for k: Variant in w:
			if not g.has(k) or not _same(g[k], w[k]):
				return false
		return true
	if got is Array and want is Array:
		var a: Array = got
		var b: Array = want
		if a.size() != b.size():
			return false
		for i: int in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	return got == want


func _failure_case(label: String, result_code: int, response_code: int, body_text: String) -> int:
	_drive(result_code, response_code, body_text)
	var f: int = 0
	f += _check_i("%s: failed fired" % label, _failed_count, 1)
	f += _check_i("%s: completed did not fire" % label, _completed_count, 0)
	f += _check_i("%s: reported code" % label, _failed_code, response_code)
	return f


func _on_completed(result: Variant) -> void:
	_completed_count += 1
	_completed_result = result


func _on_failed(error_code: int, response_body: String) -> void:
	_failed_count += 1
	_failed_code = error_code
	_failed_body = response_body


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %d, want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
	return 1
