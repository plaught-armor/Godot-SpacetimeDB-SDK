# Drives a real reconnect against a live server and checks the recovery.
#
# Reconnect is the one big path players hit most, and `_resubscribe_saved_queries`
# otherwise only ever runs against synthetic tests with a fake socket. None of it is
# observable from replayed bytes — it is client state machine behaviour — so this
# is a live harness rather than a suite test. Underscore-prefixed so run_tests.sh
# skips it; the suite must stay runnable with no server.
#
# It carries the only end-to-end proof of the subscription-handle contract: a drop
# SUSPENDS the caller's handle and the reconnect re-registers that same object under a
# fresh query set id, rather than ending it and restoring the query under an internal
# handle nothing outside the client can reach. The offline suite pins that against a
# fake connection; only a real server can show that the pre-drop handle's unsubscribe
# actually reaches it and stops the rows — which is the defect the whole contract
# exists for, and the one thing a synthetic test cannot demonstrate.
#
#   spacetime start ... && cd blackholio-server && ./publish.sh
#   cd godot-client && <godot> --headless --path . res://tests/_live_reconnect_check.tscn
#   echo $?   # number of failed checks
#
# By default the drop is a socket close from this side, which reaches the client
# the same way a graceful server-side close does: the connection layer only ever
# sees STATE_CLOSED, and the client routes through _on_connection_disconnected.
#
# A yanked network is a different branch — the socket dies with no close handshake
# (code -1) and lands in _on_connection_error. Reaching it means really killing the
# server, so that lives behind _live_abnormal_drop.sh, which sets STDB_KILL_SERVER
# and kills the server when this harness prints its cue.
#
# Also writes tests/fixtures/wire_resubscribe.bin — the frames the server sends
# while recovering — so the offline suite gets a permanent artifact out of the run.
extends Node

const RESUB_PATH: String = "res://tests/fixtures/wire_resubscribe.bin"
# C1: never const a Packed*Array.
var _queries: PackedStringArray = ["SELECT * FROM config"]
## Long enough to cover the reconnect delay below plus a resubscribe round trip.
const RECOVERY_TIMEOUT: float = 20.0
## Kill mode also has to outlast the server being down and booting again.
const KILL_MODE_RECOVERY_TIMEOUT: float = 90.0

## Printed when the harness is ready for the driver script to kill the server.
const KILL_CUE: String = "[live-reconnect] KILL_THE_SERVER_NOW"

## Set by _live_abnormal_drop.sh: wait for the server to be killed rather than
## closing the socket here, so the abnormal-closure branch runs.
var _kill_mode: bool = not OS.get_environment("STDB_KILL_SERVER").is_empty()
var _abnormal_close_seen: bool = false
## The handle taken before the drop — the object the whole contract is about.
var _sub: SpacetimeDBSubscription = null
## Sampled inside `reconnecting`, which is the only moment the suspended state is
## observable: by the time `reconnected` fires the handle has been re-registered.
var _suspended_while_reconnecting: bool = false
## The query set id the suspended handle carried, sampled at the same moment. A
## suspended handle carries none — the ids are handed out from a counter the new session
## resets, so the old value would name whatever query set lands there next.
var _query_id_while_reconnecting: int = 0
## Counts `applied` on the pre-drop handle. 1 before the drop, 2 after recovery — the
## same handle being confirmed by the server a second time.
var _applied_seen: int = 0
var _fails: int = 0
var _total: int = 0
var _reconnecting_seen: int = 0
var _reconnected_seen: int = 0
var _file: FileAccess


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	options.auto_reconnect = true # off by default — this harness is about that path
	options.reconnect_initial_delay = 0.5
	options.reconnect_jitter_fraction = 0.0 # deterministic timing for a test run
	if _kill_mode:
		# The server goes away for a while, so allow enough attempts to outlast it.
		options.max_reconnect_attempts = 30
	SpacetimeDB.Blackholio.reconnecting.connect(_on_reconnecting)
	SpacetimeDB.Blackholio.reconnected.connect(_on_reconnected)
	SpacetimeDB.Blackholio.connection_error.connect(_on_connection_error)
	# `connected` fires again on every reconnect; only the first run drives the test.
	SpacetimeDB.Blackholio.connected.connect(_run, CONNECT_ONE_SHOT)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


func _on_reconnecting(_attempt: int, _max_attempts: int) -> void:
	_reconnecting_seen += 1
	# Sticky: a kill-mode run makes many attempts, and the handle is suspended for all
	# of them. One sample that ever saw it is the evidence; a later attempt cannot
	# un-see it.
	if _sub != null and _sub.suspended:
		_suspended_while_reconnecting = true
		_query_id_while_reconnecting = _sub.query_id


func _on_reconnected() -> void:
	_reconnected_seen += 1


func _on_applied() -> void:
	_applied_seen += 1


## Code -1 is Godot's "the socket died without a close handshake" — what a killed
## server, a yanked cable, or a dropped route looks like from here.[br]
## Caveat for a busy host: the connection layer reclassifies a -1 close as
## stall-induced (routing it to `connection_stalled` instead) when the previous
## poll gap reached the heartbeat interval. A main-thread stall that long around
## the kill would make the abnormal-closure check fail without the SDK being wrong.
func _on_connection_error(code: int, _reason: String) -> void:
	if code == -1:
		_abnormal_close_seen = true


func _run(_identity: PackedByteArray, _token: String) -> void:
	_sub = SpacetimeDB.Blackholio.subscribe(_queries)
	# Connected before the wait, so the count covers the first confirmation too — the
	# assertion after recovery is that it fired AGAIN, which needs both.
	_sub.applied.connect(_on_applied)
	_check("initial subscription applied", await _sub.wait_for_applied(10.0) == OK, true)
	_check("config row cached before the drop", SpacetimeDB.Blackholio.db.config.count(), 1)

	# Capture what the server sends during the recovery, from the drop onward.
	_file = FileAccess.open(RESUB_PATH, FileAccess.WRITE)
	SpacetimeDB.Blackholio._connection.message_received.connect(_on_packet)

	if _kill_mode:
		# The driver script is waiting on this line before it kills the server. A
		# process death gives no close handshake, so the socket dies abnormally
		# (code -1) and the client routes through _on_connection_error instead.
		print(KILL_CUE)
	else:
		# Close the socket underneath the client. The connection layer sees only
		# STATE_CLOSED, exactly as it would for a graceful server-side close, so
		# this enters _on_connection_disconnected and auto-reconnect with it.
		SpacetimeDB.Blackholio._connection._websocket.close(1000, "harness drop")

	var recovered: bool = await _wait_for_reconnect()
	_check("reconnected within %.0fs" % _recovery_timeout(), recovered, true)
	if not recovered:
		_finish()
		return

	_check("emitted reconnecting at least once", _reconnecting_seen >= 1, true)
	if _kill_mode:
		# The point of this mode: a killed server produces an abnormal closure, which
		# is a different branch from the graceful close the default run exercises.
		_check("the drop was reported as an abnormal closure", _abnormal_close_seen, true)
	# The handle contract, against a real socket. Suspended for the whole outage and
	# never ended: a drop is not the subscription being over.
	_check("the handle was suspended while reconnecting", _suspended_while_reconnecting, true)
	_check("and was never ended by the drop", _sub.ended, false)
	_check("it is live again after recovery", _sub.active, true)
	_check("and no longer suspended", _sub.suspended, false)
	# The same OBJECT, re-registered — not a replacement the caller cannot reach. Pinned
	# as "it gave the id up and got one back", NOT as "the number changed": the counter
	# resets with the session, so a client holding one subscription is legitimately handed
	# id 0 again, and asserting on the value would fail against correct behaviour.
	_check("it carried no query set id while suspended", _query_id_while_reconnecting, -1)
	_check("and carries a live one again", _sub.query_id >= 0, true)
	_check(
		"and it is the handle the client holds for that id",
		SpacetimeDB.Blackholio.current_subscriptions.get(_sub.query_id) == _sub,
		true,
	)
	_check("the server confirmed it a second time", _applied_seen, 2)
	# The real question: did the resubscribe actually refill the cache the reconnect
	# cleared, or did it just reopen a socket? _prepare_for_reconnect calls
	# clear_local_db(), and only a SubscribeApplied refills it.
	_check("config row is back in the cache", SpacetimeDB.Blackholio.db.config.count(), 1)

	# Everything the fixture needs is captured; the reducer call below is a
	# liveness check, not part of the recovery, so keep its frames out.
	SpacetimeDB.Blackholio._connection.message_received.disconnect(_on_packet)

	# And the session is usable, not merely open. Passes on a bare reopened socket
	# too, so it adds liveness, not evidence for the two checks above.
	var call: SpacetimeDBReducerCall = SpacetimeDB.Blackholio.reducers.enter_game("ReconnectCheck")
	var _settled: SpacetimeDBReducerCall = await call.wait_for_response(10.0)
	_check(
		"a reducer call succeeds after recovery",
		call.outcome,
		SpacetimeDBReducerCall.Outcome.OK,
	)

	# The defect this contract exists for, proved against the server rather than a fake
	# socket: the handle taken BEFORE the drop can still stop the query. When the
	# reconnect handed back an internal handle instead, this call had nothing to name —
	# the query kept streaming for the rest of the session with nothing able to end it.
	_check("the pre-drop handle can still unsubscribe", _sub.unsubscribe(), OK)
	_check("the server confirmed the unsubscribe", await _sub.wait_for_end(10.0), OK)
	_check("and the handle is ended now, for real", _sub.ended, true)
	# UnsubscribeFlags::SendDroppedRows makes the server echo the rows being removed, so
	# a confirmed unsubscribe empties the mirror for that query. The rows leaving are what
	# prove the SERVER stopped, rather than the client merely forgetting.
	_check("the rows it owned left the cache", SpacetimeDB.Blackholio.db.config.count(), 0)

	_finish()


func _recovery_timeout() -> float:
	return KILL_MODE_RECOVERY_TIMEOUT if _kill_mode else RECOVERY_TIMEOUT


## Resolves true once `reconnected` has fired, false if the timeout wins.
func _wait_for_reconnect() -> bool:
	var deadline: SceneTreeTimer = get_tree().create_timer(_recovery_timeout())
	while _reconnected_seen == 0 and deadline.time_left > 0.0:
		await get_tree().process_frame
	# `reconnected` fires from _finish_resubscribe, after every re-subscription has
	# settled — and the cache is applied before `applied` is emitted — so the cache
	# is already refilled here. No settling wait needed.
	return _reconnected_seen > 0


func _finish() -> void:
	if _file != null:
		_file.close()
		_file = null
		# A failed run did not capture a recovery, whatever else it captured. Delete
		# the file rather than leave a plausible-looking artifact to be committed.
		if _fails > 0:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(RESUB_PATH))
			print("[live-reconnect] discarded %s (run failed)" % RESUB_PATH)
		else:
			print("[live-reconnect] wrote %s" % RESUB_PATH)
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	get_tree().quit(_fails)


func _on_packet(bytes: PackedByteArray) -> void:
	if _file == null:
		return
	# The reconnect re-runs the handshake, so an IdentityToken — carrying a live,
	# never-expiring JWT — is the first thing through. This fixture is about the
	# resubscribe that follows, so drop any frame carrying a token rather than
	# committing a credential and scrubbing it afterwards.
	if _carries_a_token(bytes):
		print("[live-reconnect] skipped a frame carrying a token")
		return
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)


## Every JWT is compact-serialized, so it starts with the base64 of '{"typ"...' —
## the ASCII run "eyJ". PackedByteArray.find() matches one byte, not a run.
func _carries_a_token(bytes: PackedByteArray) -> bool:
	var needle: PackedByteArray = "eyJ".to_ascii_buffer()
	for i: int in range(0, bytes.size() - needle.size() + 1):
		if bytes.slice(i, i + needle.size()) == needle:
			return true
	return false


func _check(label: String, got: Variant, want: Variant) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1
