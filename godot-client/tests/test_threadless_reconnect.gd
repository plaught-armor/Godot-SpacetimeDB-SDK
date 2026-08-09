# Regression test for the session boundary on a client running without threads.
#
# _prepare_for_reconnect() put its whole session-boundary cleanup behind
# `if use_threading and _packet_mutex:`, so a threadless client kept two things across a
# reconnect:
#
#   1. _result_queue — messages already parsed out of the dying session, drained into the
#      fresh mirror after the reconnect. The threaded path goes to some length (the
#      _session_epoch check in the worker) to make sure exactly those results never touch
#      the new database.
#   2. the deserializer's parse state. A socket that dies mid-message leaves the error
#      that short read raised, unconsumed, for the first packet of the new session to be
#      judged by. reset_stream_state() exists for this and its own docstring says to call
#      it on a session boundary; only the worker thread ever did.
#
# This is not an exotic configuration: _setup_threading() force-disables threading when
# the build reports no thread support, so every threadless web export runs this path.
#
# The client is built with SpacetimeDBClient.new() and never added to the tree, so _ready
# (auto-connect, threads) never runs.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_threadless_reconnect.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_threadless_boundary()
	fails += _test_threaded_boundary_unchanged()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _test_threadless_boundary() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.use_threading = false
	client._deserializer = BSATNDeserializer.new(null, false)

	# Half a message: a tag byte the parser recognises followed by fewer bytes than the
	# message needs, which is what a socket dying mid-frame leaves behind. The bytes go
	# no further than the packet that carried them; the error they raised is what the
	# dying session leaves for the next one to trip over.
	var truncated: PackedByteArray = [SpacetimeDBServerMessage.Type.INITIAL_CONNECTION, 0x01, 0x02]
	var parsed: Array[SpacetimeDBServerMessage] = (
		client._deserializer.process_bytes_and_extract_messages(truncated)
	)
	f += _check_i("setup: nothing parsed from the half message", parsed.size(), 0)
	f += _check_b("setup: the half message is reported", client._deserializer.has_error(), true)

	# And a message parsed out of the dying session that no frame drained yet.
	client._result_queue.append(SubscribeAppliedMessage.new())
	f += _check_i("setup: an undrained result", client._result_queue.size(), 1)

	client._prepare_for_reconnect()

	f += _check_i("undrained results dropped", client._result_queue.size(), 0)
	f += _check_b("parser state reset", client._deserializer.has_error(), false)

	client.free()
	return f


# The threaded path already did this through the session epoch; pinned so the new branch
# cannot be written in a way that takes work away from it.
func _test_threaded_boundary_unchanged() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.use_threading = true
	# The mutexes the threaded branch checks for, without starting a worker.
	client._packet_mutex = Mutex.new()
	client._result_mutex = Mutex.new()
	client._packet_queue.append(PackedByteArray([1, 2, 3]))
	client._result_queue.append(SubscribeAppliedMessage.new())
	var epoch_before: int = client._session_epoch

	client._prepare_for_reconnect()

	f += _check_i("packet queue cleared", client._packet_queue.size(), 0)
	f += _check_i("result queue cleared", client._result_queue.size(), 0)
	f += _check_i("session epoch bumped", client._session_epoch, epoch_before + 1)

	client.free()
	return f


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
