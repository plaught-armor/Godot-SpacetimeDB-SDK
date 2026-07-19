# Drives a real reconnect against a live server and checks the recovery.
#
# Reconnect is the last big path with no live coverage, and the one players hit
# most: `_resubscribe_saved_queries` has only ever run against synthetic tests, and
# it is the path where subscription handles go permanently ENDED. None of that is
# observable from replayed bytes — it is client state machine behaviour — so this
# is a live harness rather than a suite test. Underscore-prefixed so run_tests.sh
# skips it; the suite must stay runnable with no server.
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


func _on_reconnected() -> void:
	_reconnected_seen += 1


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
	var sub: SpacetimeDBSubscription = SpacetimeDB.Blackholio.subscribe(_queries)
	_check("initial subscription applied", await sub.wait_for_applied(10.0) == OK, true)
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
	# Documented contract, not evidence of recovery: _prepare_for_reconnect ends
	# every handle the moment the socket drops, so this passes long before any
	# resubscribe is attempted. It is here because anyone holding a handle across a
	# reconnect must see it go dead — the two checks below are what prove recovery.
	_check("the pre-drop handle is ENDED (before any resubscribe)", sub.ended, true)
	_check(
		"a live subscription replaced it",
		SpacetimeDB.Blackholio.current_subscriptions.is_empty(),
		false,
	)
	# The real question: did the resubscribe actually refill the cache the reconnect
	# cleared, or did it just reopen a socket? _prepare_for_reconnect calls
	# clear_all_tables(), and only a SubscribeApplied refills it.
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
