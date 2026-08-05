## Low-level WebSocket transport for SpacetimeDB.
##
## Manages the WebSocket lifecycle (connect, poll, send, close) and emits raw
## packet data via [signal message_received]. [SpacetimeDBClient] owns an
## instance and wires its signals for higher-level message handling.
#@tool
class_name SpacetimeDBConnection
extends Node

## Emitted when the WebSocket handshake completes.
signal connected
## Emitted on a clean close (normal code).
signal disconnected
## Emitted on abnormal close or connection failure.
signal connection_error(code: int, reason: String)
## Emitted when an abnormal close (code -1) lands right after a main-thread stall
## long enough for the engine heartbeat to have falsely declared the socket dead.
## The close is real (the engine already closed the peer), but its cause is local,
## so the client can reconnect immediately instead of treating it as a network drop.
signal connection_stalled(code: int)
## Emitted for each raw BSATN packet received from the server.
signal message_received(data: PackedByteArray)
## Emitted after every send/receive with cumulative totals.
signal total_messages(sent: int, received: int)
## Emitted after every send/receive with cumulative byte totals.
signal total_bytes(sent: int, received: int)

## Payload compression modes for the WebSocket connection.
enum CompressionPreference {
	## No compression.
	NONE = 0,
	## Brotli compression (decoded via Godot's built-in Brotli decoder).
	BROTLI = 1,
	## Gzip compression.
	GZIP = 2,
}

## The BSATN sub-protocol sent during the WebSocket handshake (SpacetimeDB 2.2.0+).
## A single WebSocket frame may carry several consecutive BSATN messages; the receive
## path already drains concatenated frames, and one-message-per-frame sends remain
## valid, so this is the only protocol the client advertises. The legacy v2
## sub-protocol (servers below 2.2.0) is no longer offered — see the 2.0 changelog.
const BSATN_PROTOCOL_V3 = "v3.bsatn.spacetimedb"

## WebSocket close code 1009. Godot hands [member WebSocketPeer.inbound_buffer_size]
## to wslay as the maximum receivable message length, so a server message larger than
## that buffer is never delivered: wslay stops reading and closes the socket itself
## with this code and the reason "Message too big". The server's own ceiling is 32 MiB
## (`WebSocketConfig::max_message_size` in `crates/client-api`), well above this
## client's default buffer, so a large enough subscription or transaction update is a
## message the server considers perfectly legal and this client cannot receive.
const CLOSE_MESSAGE_TOO_BIG: int = 1009

var version: String = "v1"
## Sub-protocol the server selected during the handshake (e.g. "v3.bsatn.spacetimedb").
var negotiated_protocol: String = ""
var preferred_compression: CompressionPreference = CompressionPreference.NONE # Default to None
var _websocket: WebSocketPeer = WebSocketPeer.new()
var _target_url: String
var _token: String
var _is_connected: bool = false
var _connection_requested: bool = false
var _options: SpacetimeDBConnectionOptions
var _db_name: String
var _debug_mode: bool = false
var _total_bytes_sent: int = 0
var _second_bytes_sent: int = 0
var _total_bytes_received: int = 0
var _second_bytes_received: int = 0
var _total_messages_sent: int = 0
var _second_messages_sent: int = 0
var _total_messages_received: int = 0
var _second_messages_received: int = 0

## How many polls a stall keeps the abnormal-close guard armed. The engine may
## close on the same poll the stall is observed or the next, so cover both.
const STALL_GUARD_POLLS: int = 2
## Wall-clock ms of the previous poll (Time.get_ticks_msec). 0 = no prior poll.
var _last_poll_ms: int = 0
## Poll gap (ms) at or above which a stall could have tripped the engine heartbeat.
## Set from heartbeat_interval at connect; 0 disables stall detection (heartbeat off).
var _stall_threshold_ms: int = 0
## Polls remaining in the post-stall guard window; >0 means a stall was just seen.
var _post_stall_polls: int = 0

## Poll gap (ms) beyond which the main thread was frozen rather than merely running
## slowly, so a handshake in flight is credited that time back. Deliberately its own
## number rather than the heartbeat window: switching keepalive off must not quietly
## harden the connect budget. 1 s is six frames at 10 fps — past any frame pacing.
const HANDSHAKE_STALL_GAP_MS: int = 1000

## Wall-clock ms at which the current attempt entered the handshake, or -1 for no
## attempt in flight. Not 0 — [method Time.get_ticks_msec] can legitimately read 0
## on the first frames, and that value has to mean "timing", not "idle". See
## [member SpacetimeDBConnectionOptions.connect_timeout_seconds] for why the SDK
## has to time the handshake itself.
var _connect_started_ms: int = -1
## Handshake budget in ms, from connect_timeout_seconds. 0 disables the timeout.
var _connect_timeout_ms: int = 0
## Stall time already credited back to the current handshake, capped at one budget
## so a frame loop crawling below 1 fps cannot postpone the timeout indefinitely.
var _handshake_credit_ms: int = 0


func _init(options: SpacetimeDBConnectionOptions, db_name: String) -> void:
	_db_name = db_name
	apply_options(options)
	set_physics_process(false) # Don't process until connect is called


## Applies the settings from [param options]. Called from [method _init] and again
## whenever the client reconnects with a fresh options object: the connection
## outlives a disconnect_db()/connect_db() pair, so without this the second call's
## compression, buffer sizes and heartbeat would silently stay at whatever the
## first call asked for.
func apply_options(options: SpacetimeDBConnectionOptions) -> void:
	# Monitor registration is a side effect on the Performance singleton, so it
	# follows the options rather than the constructor: leaving it behind would make
	# _options.monitor_mode disagree with what is actually registered, and predelete
	# would then either leak the monitors or remove names that were never added.
	var was_monitoring: bool = _options != null and _options.monitor_mode
	if was_monitoring and not options.monitor_mode:
		_unregister_monitors()
	elif not was_monitoring and options.monitor_mode:
		_register_monitors()
	_options = options
	_websocket.inbound_buffer_size = options.inbound_buffer_size
	_websocket.outbound_buffer_size = options.outbound_buffer_size
	# Keepalive: peer pings every interval and closes (code -1) if a pong is missed,
	# surfacing a dead socket as STATE_CLOSED so the reconnect path can fire.
	_websocket.heartbeat_interval = options.heartbeat_interval_seconds
	_stall_threshold_ms = int(options.heartbeat_interval_seconds * 1000.0)
	_connect_timeout_ms = int(options.connect_timeout_seconds * 1000.0)
	set_compression_preference(options.compression)
	self._debug_mode = options.debug_mode


func _physics_process(_delta: float) -> void:
	_track_stall()
	_websocket.poll()
	var state: WebSocketPeer.State = _websocket.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _is_connected:
			negotiated_protocol = _websocket.get_selected_protocol()
			_print_log(
				"SpacetimeDBConnection: Connection established (protocol: %s)."
				% negotiated_protocol
			)
			_is_connected = true
			_connection_requested = false
			_connect_started_ms = -1 # the handshake is over; stop timing it
			connected.emit()

		# Process incoming packets
		var rx_before: int = _total_messages_received
		while _websocket.get_available_packet_count() > 0:
			var packet_bytes: PackedByteArray = _websocket.get_packet()
			if packet_bytes.is_empty():
				continue

			_total_bytes_received += packet_bytes.size()
			_second_bytes_received += packet_bytes.size()
			_total_messages_received += 1
			_second_messages_received += 1

			message_received.emit(packet_bytes)

		# Stat signals carry cumulative counters — last value per frame is all a
		# display consumer needs. Emit once after draining, not per packet, so a
		# burst of N packets costs one stat emit pair instead of N.
		if _total_messages_received != rx_before:
			total_messages.emit(_total_messages_sent, _total_messages_received)
			total_bytes.emit(_total_bytes_sent, _total_bytes_received)
	elif state == WebSocketPeer.STATE_CONNECTING:
		var waiting_ms: int = (
			(Time.get_ticks_msec() - _connect_started_ms) if _connect_started_ms >= 0 else 0
		)
		if is_handshake_expired(waiting_ms, _connect_timeout_ms):
			_abort_stalled_handshake(waiting_ms)
	elif state == WebSocketPeer.STATE_CLOSING:
		# Connection is closing
		_print_log("SpacetimeDBConnection: connection closing")
	elif state == WebSocketPeer.STATE_CLOSED:
		var code: int = _websocket.get_close_code()
		var reason: String = _websocket.get_close_reason()
		if _is_connected or _connection_requested: # Only report if we were connected or trying
			if code == -1: # Abnormal closure
				if _post_stall_polls > 0: # heartbeat tripped by a local stall, not a network drop
					push_warning(
						"SpacetimeDBConnection: abnormal close right after a main-thread stall — stall-induced, fast reconnect"
					)
					_post_stall_polls = 0
					connection_stalled.emit(code)
				else:
					printerr(
						"SpacetimeDBConnection: connection_error %d, abnormal closure. Reason: %s"
						% [code, reason]
					)
					connection_error.emit(code, "Abnormal closure: %s" % reason)
			else:
				# Some close codes are a configuration failure the game cannot work out
				# from the number: they get pushed as errors, because debug_mode (which
				# gates _print_log) is off by default and a silent close that repeats
				# every reconnect is the worst way to learn about one. Reconnect is NOT
				# suppressed for them — a 1009 raised by one oversized transaction
				# update is survivable, and only the caller knows whether its
				# subscription is the kind that will reproduce it.
				var diagnostic: String = close_diagnostic(code, _options.inbound_buffer_size)
				if diagnostic.is_empty():
					_print_log(
						"SpacetimeDBConnection: Connection closed (Code: %d, Reason: %s)"
						% [code, reason]
					)
				else:
					push_error(diagnostic)
				disconnected.emit() # Normal closure signal
		_is_connected = false
		_connection_requested = false
		_connect_started_ms = -1
		set_physics_process(false) # Stop polling


## Updates the post-stall guard window. A poll gap at or beyond the heartbeat
## window means the main thread was frozen long enough for the engine to falsely
## close the socket on a missed pong; arm the guard so the next abnormal close is
## classified as stall-induced rather than a network drop.
func _track_stall() -> void:
	var now_ms: int = Time.get_ticks_msec()
	var gap_ms: int = (now_ms - _last_poll_ms) if _last_poll_ms > 0 else 0
	_last_poll_ms = now_ms
	# Time the main thread spent frozen is not time the remote spent failing to
	# answer, so a handshake in flight gets that gap back rather than being abandoned
	# for a local freeze. Kept out of the keepalive branch below on purpose: that one
	# is disabled outright when heartbeat_interval_seconds is 0.
	if _connect_started_ms >= 0:
		var credit_ms: int = handshake_stall_credit(
			gap_ms,
			_handshake_credit_ms,
			_connect_timeout_ms,
		)
		_connect_started_ms += credit_ms
		_handshake_credit_ms += credit_ms
	if is_stall_gap(gap_ms, _stall_threshold_ms):
		_post_stall_polls = STALL_GUARD_POLLS
	elif _post_stall_polls > 0:
		_post_stall_polls -= 1


## True when the wall-clock gap between two polls is large enough that the engine
## heartbeat could have falsely declared the socket dead. threshold_ms == 0
## (heartbeat disabled) → never a stall.
static func is_stall_gap(gap_ms: int, threshold_ms: int) -> bool:
	return threshold_ms > 0 and gap_ms >= threshold_ms


## True when a handshake has been waiting longer than its budget. timeout_ms == 0
## (the timeout is switched off) → never expired. Pure, so the decision is testable
## without a socket.
static func is_handshake_expired(waiting_ms: int, timeout_ms: int) -> bool:
	return timeout_ms > 0 and waiting_ms >= timeout_ms


## Milliseconds of [param gap_ms] to give back to a handshake that was in flight
## across a frozen frame loop, given the [param credited_ms] already returned to it
## and the budget it runs under. Nothing is credited below
## [constant HANDSHAKE_STALL_GAP_MS] (that is frame pacing, not a freeze), nothing
## when the timeout is off, and never more than one budget in total — a loop running
## slower than one frame per second would otherwise postpone the timeout forever.
## Pure, so the arithmetic is testable without a socket.
static func handshake_stall_credit(gap_ms: int, credited_ms: int, budget_ms: int) -> int:
	if budget_ms <= 0 or gap_ms < HANDSHAKE_STALL_GAP_MS:
		return 0
	return mini(gap_ms, maxi(budget_ms - credited_ms, 0))


## Ends an attempt that never got past the handshake. The peer is replaced rather
## than reused: [method WebSocketPeer.connect_to_url] refuses a peer that is not
## [constant WebSocketPeer.STATE_CLOSED], and the one being abandoned here is still
## connecting, so the reconnect this error triggers would otherwise fail to start.
##
## The signal goes out last, after the state is settled, because a listener may
## connect again from inside it — and that fresh attempt must not be the one this
## call switches processing off for.
func _abort_stalled_handshake(waiting_ms: int) -> void:
	# The query string is cut off, not printed: on Web the token travels in it (the
	# handshake there cannot carry an Authorization header), and this line is not
	# gated behind debug_mode, so the full URL would put a credential in the console.
	printerr(
		(
			"SpacetimeDBConnection: handshake to %s did not complete within %.1fs "
			+ "(the socket never opened); giving up on this attempt."
		)
		% [_target_url.get_slice("?", 0), waiting_ms / 1000.0]
	)
	_reset_peer()
	_is_connected = false
	_connection_requested = false
	_connect_started_ms = -1
	set_physics_process(false)
	connection_error.emit(
		ERR_TIMEOUT,
		"WebSocket handshake timed out after %.1fs" % (waiting_ms / 1000.0),
	)


## Drops the current peer and puts a fresh one in its place, carrying over the
## settings [method apply_options] applied — a new [WebSocketPeer] starts with the
## engine defaults, and a heartbeat_interval left at 0 would silently disable both
## keepalive and the stall detection that reads it.
func _reset_peer() -> void:
	if _websocket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_websocket.close()
	_websocket = WebSocketPeer.new()
	_websocket.inbound_buffer_size = _options.inbound_buffer_size
	_websocket.outbound_buffer_size = _options.outbound_buffer_size
	_websocket.heartbeat_interval = _options.heartbeat_interval_seconds


## Monitor name suffix to the getter [Performance] samples for it. Built per call
## rather than held as a constant because the values are bound to this instance.
## Every caller is cold: construct, rename, teardown.
func _monitor_getters() -> Dictionary[String, Callable]:
	return {
		"_second_received_packets": get_second_received_packets,
		"_second_received_bytes": get_second_received_bytes,
		"_total_received_packets": get_received_packets,
		"_total_received_kbytes": get_received_kbytes,
		"_second_sent_packets": get_second_sent_packets,
		"_second_sent_bytes": get_second_sent_bytes,
		"_total_sent_packets": get_sent_packets,
		"_total_sent_kbytes": get_sent_kbytes,
	}


func _register_monitors() -> void:
	var getters: Dictionary[String, Callable] = _monitor_getters()
	for suffix: String in getters:
		Performance.add_custom_monitor("spacetime/" + _db_name + suffix, getters[suffix])


func _unregister_monitors() -> void:
	for suffix: String in _monitor_getters():
		Performance.remove_custom_monitor("spacetime/" + _db_name + suffix)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _options and _options.monitor_mode:
			_unregister_monitors()
	elif what == NOTIFICATION_CRASH or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_websocket_active():
			get_tree().auto_accept_quit = false
			_handle_game_closing()


func get_second_sent_bytes() -> int:
	var amount: int = _second_bytes_sent
	_second_bytes_sent = 0
	return amount


func get_second_received_bytes() -> int:
	var amount: int = _second_bytes_received
	_second_bytes_received = 0
	return amount


func get_second_sent_packets() -> int:
	var amount: int = _second_messages_sent
	_second_messages_sent = 0
	return amount


func get_second_received_packets() -> int:
	var amount: int = _second_messages_received
	_second_messages_received = 0
	return amount


func get_sent_kbytes() -> float:
	return _total_bytes_sent / 1000.0


func get_received_kbytes() -> float:
	return _total_bytes_received / 1000.0


func get_sent_packets() -> int:
	return _total_messages_sent


func get_received_packets() -> int:
	return _total_messages_received


## Why [param token] cannot be spliced into the handshake, or [code]""[/code] when it
## can. Pure, so the check is testable without a socket.
##
## The token reaches the wire as an [code]Authorization: Bearer <token>[/code] entry in
## [member WebSocketPeer.handshake_headers], and Godot writes those out verbatim —
## [code]request += handshake_headers[i] + "\r\n"[/code] in [code]wsl_peer.cpp[/code],
## with no validation of its own. A CR or LF inside the token therefore ends the header
## line early and everything after it becomes further request headers (verified against
## a local socket: a token of [code]abc\r\nX-Injected: yes[/code] produces an
## [code]X-Injected[/code] header, and truncates the credential to [code]abc[/code]).
## Tokens are not always the game's own: [SpacetimeAuth] returns one parsed from a
## third-party OIDC host's JSON, the client can read one from a file on disk, and the
## server supplies one in its IdentityToken message.
static func token_reject_reason(token: String) -> String:
	if token.is_empty():
		return "it is empty"
	for i: int in token.length():
		var c: int = token.unicode_at(i)
		if c < 0x20 or c == 0x7F:
			return "it contains a control character (0x%02X at index %d)" % [c, i]
	return ""


func set_token(token: String) -> void:
	var reason: String = token_reject_reason(token)
	if not reason.is_empty():
		# Dropped rather than sanitized: a token this SDK had to edit is not the token
		# the issuer signed, and connecting with a mangled credential would fail at the
		# server with a less useful message than this one.
		push_error("SpacetimeDBConnection: refusing the auth token — %s." % reason)
		self._token = ""
		return
	self._token = token


func set_compression_preference(preference: CompressionPreference) -> void:
	self.preferred_compression = preference


## Sends [param bytes] over the WebSocket. Returns [constant OK] on success.
func send_bytes(bytes: PackedByteArray) -> Error:
	var err: Error = _websocket.send(bytes)
	if err == OK:
		_second_bytes_sent += bytes.size()
		_total_bytes_sent += bytes.size()
		_second_messages_sent += 1
		_total_messages_sent += 1
		total_messages.emit(_total_messages_sent, _total_messages_received)
		total_bytes.emit(_total_bytes_sent, _total_bytes_received)
	return err


## The operator-facing explanation for a close code that a game cannot diagnose from
## the code alone, or [code]""[/code] for one that needs no explanation. Pure, so
## which codes carry a diagnostic is testable without a socket, and so the number the
## game is actually running with appears in the text rather than the default.
static func close_diagnostic(code: int, inbound_buffer_size: int) -> String:
	if code != CLOSE_MESSAGE_TOO_BIG:
		return ""
	return (
		(
			"SpacetimeDBConnection: the server sent a message larger than "
			+ "inbound_buffer_size (%d bytes), so the socket was closed with 1009 "
			+ "(Message too big) before the message could be read. If auto-reconnect "
			+ "is on, the resubscribe that follows will meet the same message again "
			+ "unless one of these changes: raise "
			+ "SpacetimeDBConnectionOptions.inbound_buffer_size (the server allows "
			+ "itself up to 32 MiB per message), turn on "
			+ "SpacetimeDBConnectionOptions.compression so large payloads arrive "
			+ "compressed, or narrow the subscription that produced it."
		)
		% inbound_buffer_size
	)


## The [code]?...[/code] query string for the subscribe endpoint. Pure, so the wire
## spelling of every connection knob is testable without a socket.
##
## [param confirmed_reads] is always written out, even at its default. The server picks
## its own default for a v3 connection that omits the parameter ([code]confirmed[/code]
## is an [code]Option<bool>[/code] there), and the Rust and C# SDKs do omit it — sending
## it means this SDK's consistency guarantee is decided here rather than by the server
## build a game happens to connect to.
##
## The [code]token[/code] parameter is NOT added here: it is only used on Web, where the
## handshake cannot carry an Authorization header, and appending it is the caller's job.
static func build_query_params(
	connection_id: String,
	compression: CompressionPreference,
	confirmed_reads: bool,
	light_mode: bool,
) -> String:
	var compression_str: String
	if compression == CompressionPreference.NONE:
		compression_str = "None" # matches the server's Compression enum spelling
	elif compression == CompressionPreference.BROTLI:
		compression_str = "Brotli"
	elif compression == CompressionPreference.GZIP:
		compression_str = "Gzip"
	else:
		compression_str = "None" # unreachable; the server rejects an unknown value

	var query_params: String = "?connection_id=%s" % connection_id
	query_params += "&compression=%s" % compression_str
	query_params += "&confirmed=%s" % ("true" if confirmed_reads else "false")
	if light_mode:
		query_params += "&light=true"
	return query_params


## Builds the `subscribe` WebSocket URL for [param database_name] under
## [param base_url], with the scheme rewritten to `ws`/`wss`.
##
## Trailing slashes on [param base_url] are dropped first. `String.path_join` concatenates
## when either side already carries the separator, so a host written with the trailing
## slash a browser shows (`http://127.0.0.1:3000/`) produced `//v1/database/...`, and the
## server routes that as a path with an empty first segment: measured against 2.7.x,
## `/v1/ping` answers 200 and `//v1/ping` answers 404. The handshake failed with nothing
## pointing at the extra character.
static func build_socket_url(base_url: String, version: String, database_name: String) -> String:
	var ws_url_base: String = base_url.rstrip("/")
	# Rewrite only the leading scheme — a stray "http://" elsewhere in base_url
	# (a path or query segment) must be left alone. begins_with anchors at index 0;
	# .replace() would rewrite every occurrence. https checked first — "http" is a
	# prefix of "https".
	if ws_url_base.begins_with("https://"):
		ws_url_base = "wss://" + ws_url_base.substr(8)
	elif ws_url_base.begins_with("http://"):
		ws_url_base = "ws://" + ws_url_base.substr(7)
	return ws_url_base \
			.path_join("/" + version + "/database") \
			.path_join(database_name) \
			.path_join("subscribe")


## Initiates a WebSocket connection to the SpacetimeDB [param database_name]
## at [param base_url] using the given [param connection_id].
func connect_to_database(base_url: String, database_name: String, connection_id: String) -> void:
	if _is_connected:
		_print_log("SpacetimeDBConnection: Already connected.")
		return

	# The client reuses one connection across reconnects, so a caller that points it
	# at a different database would otherwise keep reporting under the original
	# name's monitors — and leak them, since teardown removes by the current name.
	if database_name != _db_name:
		var rename_monitors: bool = _options.monitor_mode
		if rename_monitors:
			_unregister_monitors()
		_db_name = database_name
		if rename_monitors:
			_register_monitors()

	if _connection_requested:
		_print_log("SpacetimeDBConnection: Previous attempt still in progress, resetting.")
		_reset_peer()
		_is_connected = false
		_connection_requested = false

	if _token.is_empty():
		# Loud, and reported: the caller asked for a connection that is not going to
		# happen, and this arm is also where a token set_token refused lands, which
		# print_log would have hidden outside debug_mode.
		printerr("SpacetimeDBConnection: Cannot connect without auth token.")
		# Deferred for the same reason as SpacetimeDBClient._report_connection_error: this
		# arm and the connect_to_url one below are decided inside the call, so emitting
		# inline reached only the listeners that were already wired — and the client's own
		# handler re-emits, so the game heard nothing either.
		connection_error.emit.call_deferred(ERR_UNAUTHORIZED, "No auth token")
		return

	if connection_id.is_empty():
		printerr("SpacetimeDBConnection: Cannot connect without Connection ID.")
		return

	var ws_url_base: String = build_socket_url(base_url, version, database_name)

	var query_params: String = build_query_params(
		connection_id,
		preferred_compression,
		_options.confirmed_reads,
		_options.light_mode,
	)

	if OS.get_name() == "Web":
		# Percent-encoded: this one goes into a URL, where an unescaped `&` or `#` in the
		# token would end the parameter and rewrite the rest of the query string. A JWT is
		# base64url and survives encoding unchanged apart from any `=` padding.
		query_params += "&token=%s" % _token.uri_encode()
	else:
		var auth_header: String = "Authorization: Bearer %s" % _token
		_websocket.handshake_headers = [auth_header]

	_target_url = "%s%s" % [ws_url_base, query_params]
	_print_log("SpacetimeDBConnection: Attempting to connect to: " + _target_url)

	# v3 only — servers below 2.2.0 (which speak just v2) will fail the handshake.
	_websocket.supported_protocols = [BSATN_PROTOCOL_V3]

	var err: Error = _websocket.connect_to_url(_target_url)
	if err != OK:
		printerr("SpacetimeDBConnection: Error initiating connection: ", err)
		# connect_to_url refuses a URL it cannot use (a host_url whose scheme survived
		# build_socket_url's http/https rewrite, say) without any I/O, so this lands in the
		# caller's frame. Deferred, like the no-token arm above.
		connection_error.emit.call_deferred(err, "Failed to initiate connection")
	else:
		_print_log("SpacetimeDBConnection: Connection initiated.")
		_connection_requested = true
		_last_poll_ms = 0 # fresh poll clock — first poll sets the baseline, no false stall
		_post_stall_polls = 0
		_connect_started_ms = Time.get_ticks_msec() # the handshake budget starts here
		_handshake_credit_ms = 0
		set_physics_process(true)


## Closes the WebSocket connection with the given [param code] and [param reason].
func disconnect_from_server(code: int = 1000, reason: String = "Client initiated disconnect") -> void:
	if is_websocket_active():
		_print_log("SpacetimeDBConnection: Closing connection...")
		_websocket.close(code, reason)
	_is_connected = false
	_connection_requested = false
	_connect_started_ms = -1


## Returns [code]true[/code] if the WebSocket is currently open.
func is_connected_db() -> bool:
	return _is_connected


## Returns [code]true[/code] if the WebSocket peer exists and is not closed.
func is_websocket_active() -> bool:
	return _websocket.get_ready_state() != WebSocketPeer.STATE_CLOSED


func _print_log(log_message: String) -> void:
	if _debug_mode:
		print(log_message)


func _handle_game_closing() -> void:
	disconnect_from_server()
	var tree: SceneTree = get_tree()
	var physics_dt: float = 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	var max_wait: float = 3.0
	var elapsed: float = 0.0
	while _websocket.get_ready_state() == WebSocketPeer.STATE_CLOSING:
		_print_log("SpacetimeDBConnection: WS closing")
		await tree.physics_frame
		if not is_instance_valid(self):
			return
		elapsed = minf(elapsed + physics_dt, max_wait + 1.0)
		if elapsed >= max_wait:
			_print_log("SpacetimeDBConnection: WS close wait exceeded cap, forcing quit")
			break
	tree.auto_accept_quit = true
	tree.quit()
