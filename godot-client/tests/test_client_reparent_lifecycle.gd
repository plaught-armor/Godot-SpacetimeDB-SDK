# Regression test: a SpacetimeDBClient that leaves the tree and comes back still works.
#
# `_ready` runs once per NODE; `_exit_tree` runs once per tree ENTRY. The client tore
# down its deserializer worker and its reconnect cycle on the way out and rebuilt
# neither on the way back in, so a client moved between parents (reparented under a
# level, pooled, `remove_child` then `add_child`) came back deaf:
#
#   * the worker was joined and `_thread_should_exit` left set, so every arriving packet
#     was queued for a thread that no longer existed. Measured against a real socket
#     (tests/_probe_client_reparent.gd): 0 of 40 messages delivered after the reparent,
#     silently, with `is_connected_db()` still answering true. The threadless client was
#     unaffected, which is what named the worker.
#   * a reconnect cycle in flight was cancelled, taking the saved subscription queries
#     with it, and nothing restarted it — so the client never reconnected either.
#
# This drives the same lifecycle without a socket: the probe owns the end-to-end proof,
# this owns the invariant. Both halves fail against the old code.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_client_reparent_lifecycle.gd
extends SceneTree

const BROADCAST_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
const MAX_WAIT_FRAMES: int = 300

var _total: int = 0
var _fails: int = 0
var _n_reconnecting: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_worker_restarts()
	await _test_queued_packets_are_not_stranded()
	await _test_reconnect_cycle_resumes()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _test_worker_restarts() -> void:
	var client: SpacetimeDBClient = _threaded_client()
	_check_b("worker running", _worker_alive(client), true)

	root.remove_child(client)
	_check_b("worker joined on the way out", client.deserializer_worker == null, true)
	# The flag the loop runs on: left set, a restarted worker exits on its first check.
	_check_b("exit flag cleared for the next worker", client._thread_should_exit, false)

	root.add_child(client)
	await _pump(2)
	_check_b("worker running again", _worker_alive(client), true)

	await _teardown(client)


# Bytes that arrived before the join are still in the queue, and the post that would
# have woken a worker was consumed by the one on its way out. The restart has to wake
# the new worker itself, or those packets sit there until the next one happens to
# arrive — a reconnect's first message, or never.
func _test_queued_packets_are_not_stranded() -> void:
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	if frames.is_empty():
		printerr("no fixture frames")
		_fails += 1
		_total += 1
		return

	var client: SpacetimeDBClient = _threaded_client()
	# The drain is the main thread's job and needs a live database; this test is about
	# the worker, so leave the results where the worker puts them.
	client.set_physics_process(false)

	root.remove_child(client)
	client._packet_queue.append(frames[0])
	root.add_child(client)

	var drained: bool = false
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		client._packet_mutex.lock()
		drained = client._packet_queue.is_empty()
		client._packet_mutex.unlock()
		if drained:
			break
	_check_b("the queued packet is picked up after re-entry", drained, true)

	# The worker empties the queue under the lock and only then parses, so the result
	# lands a moment after the queue reads empty — poll for it rather than sampling.
	var produced: int = 0
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		client._result_mutex.lock()
		produced = client._result_queue.size()
		client._result_mutex.unlock()
		if produced > 0:
			break
	_check_b("and it was actually parsed", produced > 0, true)

	await _teardown(client)


func _test_reconnect_cycle_resumes() -> void:
	var client: SpacetimeDBClient = _threaded_client()
	client.connection_options = SpacetimeDBConnectionOptions.new()
	client.connection_options.auto_reconnect = true
	client.connection_options.max_reconnect_attempts = 10
	client.connection_options.reconnect_initial_delay = 0.05
	client.connection_options.reconnect_max_delay = 0.05
	client.connection_options.reconnect_jitter_fraction = 0.0
	client.reconnecting.connect(_on_reconnecting)

	# The state a client is in while it waits out a backoff.
	client._reconnect_state = client._ReconnectState.RECONNECTING
	client._reconnect_attempt = 1
	var saved: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
		client,
		0,
		PackedStringArray(["SELECT * FROM entity"]),
	)
	saved.mark_suspended()
	client._saved_subscriptions.append(saved)

	root.remove_child(client)
	_check_b("cycle marked suspended, not cancelled", client._reconnect_suspended, true)
	_check_b(
		"the saved subscription set survives the detach",
		not client._saved_subscriptions.is_empty(),
		true,
	)
	_check_b(
		"still in the reconnecting state",
		client._reconnect_state == client._ReconnectState.RECONNECTING,
		true,
	)

	_n_reconnecting = 0
	root.add_child(client)
	await _pump(2)
	_check_b("the suspend flag is consumed", client._reconnect_suspended, false)
	_check_b("the next attempt is scheduled on re-entry", _n_reconnecting > 0, true)
	# Not reset by the round trip: a client that leaves and re-enters repeatedly must
	# still run out of attempts.
	_check_b("the attempt counter kept counting", client._reconnect_attempt > 1, true)

	await _teardown(client)

# --- harness ---


func _threaded_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.use_threading = true
	client.name = "ReparentTestClient"
	root.add_child(client)
	# _enter_tree only rebuilds a worker for a client that got as far as initializing;
	# stand in for that here rather than opening a socket.
	client._is_initialized = true
	# A real deserializer, so the worker can do its whole job in every scenario — not
	# only the one that queues bytes. Without it a later change that reads _deserializer
	# outside the epoch-mismatch branch would fault the worker while these assertions
	# still passed.
	client._deserializer = BSATNDeserializer.new(SpacetimeDBSchema.new("Blackholio"), false)
	client._setup_threading()
	return client


func _worker_alive(client: SpacetimeDBClient) -> bool:
	return client.deserializer_worker != null and client.deserializer_worker.is_alive()


func _pump(frames: int) -> void:
	for _i: int in frames:
		await physics_frame


func _teardown(client: SpacetimeDBClient) -> void:
	if client.get_parent() != null:
		client.get_parent().remove_child(client)
	client.queue_free()
	await _pump(2)


func _load_frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while f.get_position() < f.get_length():
		var size: int = f.get_32()
		out.append(f.get_buffer(size))
	f.close()
	return out


func _on_reconnecting(_attempt: int, _max_attempts: int) -> void:
	_n_reconnecting += 1

# --- assertions ---


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		return
	_fails += 1
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
