# Unit test for two reconnect-state correctness fixes in SpacetimeDBClient:
#
#   1. disconnect_db() while the socket is already closed (e.g. cancelled mid-backoff
#      during a reconnect) must still emit `disconnected` — disconnect_from_server()
#      would be a no-op and emit nothing, so the client surfaces it directly. It must
#      also clear the intentional-disconnect flag so it can't poison a later event.
#   2. _finish_resubscribe(epoch) must only clear the saved queries and emit
#      `reconnected` when its epoch is still current — a superseded reconnect cycle's
#      late settle does nothing.
#
# The client is built with SpacetimeDBClient.new() and never added to the tree, so
# _ready (and any auto-connect / threads) never runs.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_reconnect_state.gd
extends SceneTree

var _total: int = 0
var _disconnected_count: int = 0
var _reconnected_count: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_disconnect_while_closed()
	f += _test_finish_resubscribe_epoch_guard()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_disconnect_while_closed() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	_disconnected_count = 0
	client.disconnected.connect(_on_disconnected)

	# No _connection assigned → socket is "closed"; disconnect_db must self-emit.
	client.disconnect_db()
	f += _check_i("disconnect while closed → disconnected once", _disconnected_count, 1)
	f += _check_b("intentional flag cleared", client._intentional_disconnect, false)

	client.disconnected.disconnect(_on_disconnected)
	client.free()
	return f


func _test_finish_resubscribe_epoch_guard() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	_reconnected_count = 0
	client.reconnected.connect(_on_reconnected)

	client._saved_subscription_queries = [PackedStringArray(["SELECT * FROM x"])]
	client._resubscribe_epoch = 5

	# Stale epoch: a superseded cycle's settle must do nothing.
	client._finish_resubscribe(3)
	f += _check_i("stale epoch → no reconnected", _reconnected_count, 0)
	f += _check_i("stale epoch → saved kept", client._saved_subscription_queries.size(), 1)

	# Current epoch: completes the cycle — clears saved, emits reconnected.
	client._finish_resubscribe(5)
	f += _check_i("current epoch → reconnected once", _reconnected_count, 1)
	f += _check_i("current epoch → saved cleared", client._saved_subscription_queries.size(), 0)

	client.reconnected.disconnect(_on_reconnected)
	client.free()
	return f


func _on_disconnected() -> void:
	_disconnected_count += 1


func _on_reconnected() -> void:
	_reconnected_count += 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
