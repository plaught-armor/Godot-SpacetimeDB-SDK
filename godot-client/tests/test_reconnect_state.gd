# Unit test for two reconnect-state correctness fixes in SpacetimeDBClient:
#
#   1. disconnect_db() while the socket is already closed (e.g. cancelled mid-backoff
#      during a reconnect) must still emit `disconnected` — disconnect_from_server()
#      would be a no-op and emit nothing, so the client surfaces it directly. And it
#      must be idempotent: a second disconnect_db() does not re-fire the terminal
#      signal (at-most-once per session).
#   2. _finish_resubscribe(epoch) must only clear the saved queries and emit
#      `reconnected` when its epoch is still current — a superseded reconnect cycle's
#      late settle does nothing.
#
# The client is built with SpacetimeDBClient.new() and never added to the tree, so
# _ready (and any auto-connect / threads) never runs.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_reconnect_state.gd
extends SceneTree

var _total: int = 0
var _disconnected_count: int = 0
var _reconnected_count: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_disconnect_while_closed()
	f += _test_finish_resubscribe_epoch_guard()
	f += _test_disconnect_retires_stats_pending()

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
	# Idempotent: a second disconnect_db must NOT re-fire the terminal signal.
	client.disconnect_db()
	f += _check_i("second disconnect_db → still once", _disconnected_count, 1)

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

	# _finish_resubscribe bumps the epoch, so a repeat (a late settle or the watchdog
	# timer that both call it) must NOT re-fire reconnected.
	client._finish_resubscribe(5)
	f += _check_i("repeat finish → no second reconnected", _reconnected_count, 1)

	client.reconnected.disconnect(_on_reconnected)
	client.free()
	return f


# A request outstanding when the socket dies is answered by nobody: the handle is
# stamped DISCONNECTED and the pending map cleared, so the latency tracker has to let
# go of it too. It used to keep the send, leaving get_stats() reporting requests in
# flight on an idle client for the rest of the session.
func _test_disconnect_retires_stats_pending() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var stats: SpacetimeDBStats = client.get_stats()
	var red: int = SpacetimeDBStats.Category.REDUCER
	var sub: int = SpacetimeDBStats.Category.SUBSCRIBE

	stats.record_send(0, red)
	stats.record_response(0) # completed before the drop — history, not in flight
	stats.record_send(1, red)
	stats.record_send(2, sub)
	f += _check_i("setup: reducer in flight", stats.get_tracker(red).in_flight, 1)

	client._prepare_for_reconnect()
	f += _check_i("reconnect drains reducer in_flight", stats.get_tracker(red).in_flight, 0)
	f += _check_i("reconnect drains subscribe in_flight", stats.get_tracker(sub).in_flight, 0)
	f += _check_i("reconnect keeps completed count", stats.get_tracker(red).count, 1)

	# The id counters restart at 0 after a reconnect, so a fresh request reusing a
	# pre-drop id must not resolve against the dead session's send.
	stats.record_response(1)
	f += _check_i("pre-drop id no longer resolves", stats.get_tracker(red).count, 1)

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
