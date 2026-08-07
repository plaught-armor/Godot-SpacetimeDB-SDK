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
## that buffer is never delivered. The server's own ceiling is 32 MiB
## (`WebSocketConfig::max_message_size` in `crates/client-api`), well above this
## client's default buffer, so a large enough subscription or transaction update is a
## message the server considers perfectly legal and this client cannot receive.[br]
## [br]
## An oversized message arrives one of TWO ways, and only the first announces itself:[br]
## - Sent as a SINGLE frame, wslay compares the frame's payload length against the
##   limit and closes the socket itself with this code and the reason "Message too
##   big".[br]
## - Sent as FRAGMENTS (what a real server does with a large snapshot), the limit is
##   never reached: Godot runs wslay with `no_buffering`, and the running message
##   length is only accumulated by the chunk-append call that no-buffering skips
##   (`wslay_event.c`), so each fragment is measured on its own. The message is
##   reassembled into a ring sized `Math::nearest_shift(inbound_buffer_size)` — the
##   next power of two AT OR ABOVE it, so up to twice the number set here — while the
##   buffer it is read out into is exactly this size. A message between the two is
##   assembled, queued, and then refused by `PacketBuffer::read_packet`;
##   `WSLPeer::get_packet` ignores that failure and returns OK with a zero-length
##   packet — no close, no error, no packet. Worse, the refused read has already
##   consumed the packet's queue slot without draining its payload, so the frames
##   after it are read at the wrong offset (measured against a live 2.8.0 server:
##   "Unknown compression tag 120" for several frames afterwards).[br]
## - Past the ring as well, nothing is assembled at all: no packet, no error, no
##   close, and nothing for this SDK to notice. That band is beyond reach from here —
##   the caller sees it as a subscribe that never applies. Pinned by
##   `tests/test_oversized_inbound_message.gd` so a future engine that does report it
##   shows up as a failing test.[br]
## [br]
## The second shape is why an empty inbound packet is treated as fatal rather than
## skipped — see [method dropped_message_diagnostic].
const CLOSE_MESSAGE_TOO_BIG: int = 1009

## Default size of both WebSocket buffers, and what an unusable one falls back to.
## [SpacetimeDBConnectionOptions] declares its defaults from here so there is one number.
const DEFAULT_BUFFER_SIZE: int = 1024 * 1024 * 2

## Smallest socket buffer this SDK will hand the engine.
##
## Below this a buffer cannot carry a SpacetimeDB message, and the engine answers a
## degenerate one by breaking rather than complaining — measured on 4.8.dev
## (`tests/_probe_socket_limits.gd`):[br]
## - [b]0[/b] is accepted by the setter and by [method WebSocketPeer.connect_to_url]. The
##   socket OPENS, [method SpacetimeDBClient.is_connected_db] reads true, and every
##   inbound message is dropped in silence — no packet, no close, no error. The client
##   waits on a handshake that can never complete and reports nothing.[br]
## - [b]negative[/b] is also accepted by the setter, and then trips
##   `Condition "p_size < 0" is true` inside `CowData::resize` on the first poll, and the
##   headless process HANGS.[br]
## [br]
## So a bad value is refused here rather than passed on. The floor is deliberately low —
## it exists to catch a value that is broken (0, negative, a byte count that was meant to
## be kilobytes), not to second-guess a small one. It is NOT a recommendation: the
## practical minimum is tens of KiB, because a buffer only has to be smaller than one
## server message for the silent band above it to swallow every subscription.
const MIN_BUFFER_SIZE: int = 4096

## Largest socket buffer this SDK will hand the engine.
##
## [method WebSocketPeer.set_inbound_buffer_size] takes a C++ 32-bit int and a GDScript
## int is 64-bit, so a large enough number does not fail — it TRUNCATES, straight back
## into the two failures [constant MIN_BUFFER_SIZE] describes. Measured on 4.8.dev:
## [code]1 << 31[/code] reads back as -2147483648 (the hang) and [code]1 << 32[/code]
## reads back as 0 (the silent drop), so "give it plenty" is the dangerous input here.
## [br]
## The ceiling is the server's own message limit (`WebSocketConfig::max_message_size` in
## `crates/client-api`), which no legal SpacetimeDB message exceeds as of 2.7.1 — check
## that before raising this, since a server that lifted its limit would make the SDK the
## one refusing the message. A value over the ceiling is CLAMPED rather than defaulted —
## a caller asking for more wants as much as possible, and answering that with the 2 MiB
## default would be a cut of three orders of magnitude.[br]
## [br]
## Note what a big buffer costs. The engine allocates a reassembly ring of
## `nearest_shift(size)` — for an exact power of two, TWICE the size — plus a packet
## buffer of the full size, so roughly 3× the number set, per direction. Measured on
## 4.8.dev across a completed handshake: 2 MiB in + 2 MiB out costs ~6.2 MiB, and this
## ceiling both ways costs ~90 MiB. Reach for [member
## SpacetimeDBConnectionOptions.compression] before reaching for the ceiling.
const MAX_BUFFER_SIZE: int = 1024 * 1024 * 32

## Default keepalive interval, and what a negative one falls back to.
const DEFAULT_HEARTBEAT_SECONDS: float = 15.0

## Default handshake budget, and what a negative one falls back to.
const DEFAULT_CONNECT_TIMEOUT_SECONDS: float = 15.0

## Largest interval [method resolve_interval_seconds] accepts, in seconds (one day).
##
## Both callers turn seconds into milliseconds as an [code]int[/code], and a float→int
## conversion that does not fit produces INT64_MIN — measured on 4.8.dev, anything from
## about 9.3e15 seconds up, and [code]INF[/code] with it. Negative is exactly what every
## threshold reads as "off", so an interval meant to be enormous switched off the timeout
## it was meant to stretch. A day is far past any sane keepalive or handshake budget, and
## nothing is lost by refusing more: [code]0.0[/code] is the documented way to say never.
const MAX_INTERVAL_SECONDS: float = 86400.0

## Smallest keepalive interval [method apply_options] accepts, in seconds.
##
## The heartbeat is also the SDK's stall threshold ([member _stall_threshold_ms]), so a
## sub-second value reproduces the same silent failures from the other end — measured on
## 4.8.dev:[br]
## - [b]0.001[/b] gives a 1 ms threshold, which an ordinary 60 Hz frame gap (~16 ms)
##   clears on every poll. The stall guard is then permanently armed, so a real network
##   drop is diagnosed as a local freeze and answered with a no-backoff reconnect —
##   forever, and the `and _is_connected` half of that branch exists to prevent exactly
##   this misclassification.[br]
## - [b]0.0001[/b] truncates to a 0 ms threshold, which reads as "heartbeat disabled", so
##   stall detection is off while the engine pings at poll rate.[br]
## [br]
## Below a second a keepalive means nothing against the server's own idle timeout anyway,
## and the derived threshold stops being distinguishable from a frame gap. [code]0.0[/code]
## is still accepted — that is the documented way to turn keepalive off.
const MIN_HEARTBEAT_SECONDS: float = 1.0

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
## Socket limits as actually applied — [method apply_options] resolves them once so a
## refused value is reported once, and [method _reset_peer] restores what is in force
## rather than re-reading (and re-reporting) the raw option.
var _inbound_buffer_size: int = DEFAULT_BUFFER_SIZE
var _outbound_buffer_size: int = DEFAULT_BUFFER_SIZE
var _heartbeat_seconds: float = DEFAULT_HEARTBEAT_SECONDS
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
	# Resolved once and kept, so _reset_peer restores the same numbers and a refused
	# value is reported once per apply rather than once per reconnect.
	_inbound_buffer_size = resolve_buffer_size(options.inbound_buffer_size, "inbound_buffer_size")
	_outbound_buffer_size = resolve_buffer_size(
		options.outbound_buffer_size,
		"outbound_buffer_size",
	)
	_heartbeat_seconds = resolve_interval_seconds(
		options.heartbeat_interval_seconds,
		MIN_HEARTBEAT_SECONDS,
		DEFAULT_HEARTBEAT_SECONDS,
		"heartbeat_interval_seconds",
	)
	# No floor on the handshake budget: an aggressively short one is a deliberate choice
	# on a LAN, and getting it wrong fails loudly (every attempt times out) rather than
	# silently — which is the line this whole resolution draws.
	var timeout_seconds: float = resolve_interval_seconds(
		options.connect_timeout_seconds,
		0.0,
		DEFAULT_CONNECT_TIMEOUT_SECONDS,
		"connect_timeout_seconds",
	)
	_websocket.inbound_buffer_size = _inbound_buffer_size
	_websocket.outbound_buffer_size = _outbound_buffer_size
	# Keepalive: peer pings every interval and closes (code -1) if a pong is missed,
	# surfacing a dead socket as STATE_CLOSED so the reconnect path can fire.
	_websocket.heartbeat_interval = _heartbeat_seconds
	_stall_threshold_ms = int(_heartbeat_seconds * 1000.0)
	_connect_timeout_ms = int(timeout_seconds * 1000.0)
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
				# The peer counted a packet and then handed over nothing. No
				# SpacetimeDB frame is empty — every one carries a compression byte
				# and a payload — so this is the engine dropping a message that did
				# not fit inbound_buffer_size (see CLOSE_MESSAGE_TOO_BIG). Skipping
				# it, which is what this branch used to do, left the session running
				# on a stream that had silently lost a message AND been left at the
				# wrong offset, with nothing reported to the game at all.
				_abort_on_dropped_message()
				return

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
				# `and _is_connected`: the engine keepalive only pings an OPEN socket, so
				# a stall can only ever have false-killed one that was up. Without that
				# half, a frame-loop freeze that happens to overlap a refused handshake
				# was diagnosed as a stall and answered with a no-backoff reconnect into
				# the same refusal.
				if _post_stall_polls > 0 and _is_connected:
					push_warning(
						"SpacetimeDBConnection: abnormal close right after a main-thread stall — stall-induced, fast reconnect"
					)
					_post_stall_polls = 0
					connection_stalled.emit(code)
				elif not _is_connected:
					# The socket never opened, so nothing was closed mid-session. What
					# ended it is not knowable from here (Godot keeps neither the HTTP
					# status nor a transport error), so the report says that and names
					# both families of cause — "Abnormal closure:" with an empty reason,
					# which is what this used to say, asserts a network drop and sends
					# the reader looking in the wrong place for a typo'd database name.
					var refusal: String = handshake_refused_diagnostic(_target_url, _db_name)
					printerr(refusal)
					connection_error.emit(code, refusal)
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
				var diagnostic: String = close_diagnostic(code, _inbound_buffer_size)
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


## Ends the session after the engine dropped an inbound message, reporting what the
## game has to change. The socket is not salvageable: the drop consumed the packet's
## queue slot without draining its payload, so every later frame is read at the wrong
## offset. A fresh peer is the only way back to a coherent stream, and the mirror needs
## a fresh snapshot anyway — whatever the lost message carried is never resent.
##
## Reported as a connection error rather than a clean disconnect so auto-reconnect
## applies exactly as it does for any other mid-session failure. The reconnect meets
## the same message again if the subscription reproduces it, which is loud, bounded by
## max_reconnect_attempts, and preferable to a client that sits connected and silent.
func _abort_on_dropped_message() -> void:
	var diagnostic: String = dropped_message_diagnostic(_inbound_buffer_size)
	push_error(diagnostic)
	# State first, signal last: a handler is free to call disconnect_db() or start a
	# new connect_db(), and it must not find this peer half torn down.
	_reset_peer()
	_is_connected = false
	_connection_requested = false
	_connect_started_ms = -1
	set_physics_process(false)
	connection_error.emit(CLOSE_MESSAGE_TOO_BIG, "Inbound message dropped (too big to receive)")


## The target URL with its query string cut off. On Web the token travels in that
## query string (the handshake there cannot carry an Authorization header), so every
## line that prints the URL — the connect log, the stalled-handshake report, the
## refusal diagnostic — has to drop it or a credential lands in the console.
func _url_without_query() -> String:
	return _target_url.get_slice("?", 0)


## The operator-facing explanation for a handshake that ended before the socket opened.
## Pure, so the text is testable without a socket.
##
## Says what was observed, not what caused it: Godot's WebSocketPeer keeps neither the
## HTTP status nor a transport error, so a 404 for an unknown database, a 401 for a
## rejected token, a DNS miss and a proxy that dropped the connection all arrive here
## as the same close code -1 with an empty reason. Both families are named, and so is
## the one command that tells them apart.
static func handshake_refused_diagnostic(target_url: String, database_name: String) -> String:
	return (
		(
			"SpacetimeDBConnection: the handshake for '%s' at %s ended without the socket "
			+ "opening, so nothing was dropped mid-session. Godot's WebSocketPeer keeps "
			+ "neither the HTTP status nor a transport error, so the cause is either "
			+ "server-side (no database by that name — 404; the auth token was rejected "
			+ "— 401; or the server is too old to speak %s, which SpacetimeDB 2.2.0 and "
			+ "up do) or transport-side (DNS did not resolve, a proxy or firewall closed "
			+ "the connection, the host accepted the TCP connection and then reset it). "
			+ "`curl -v` against the same URL tells the two apart."
		)
		% [database_name, target_url.get_slice("?", 0), BSATN_PROTOCOL_V3]
	)


## The operator-facing explanation for a message the engine dropped instead of
## delivering. Pure, so the text — including the buffer size the game is actually
## running with — is testable without a socket.
static func dropped_message_diagnostic(inbound_buffer_size: int) -> String:
	return (
		(
			"SpacetimeDBConnection: the server sent a message larger than "
			+ "inbound_buffer_size (%d bytes) and the engine dropped it — a fragmented "
			+ "message never trips wslay's own limit, so no 1009 close is raised and "
			+ "the packet arrives empty instead. The session is being ended because the "
			+ "frames after a dropped one are read at the wrong offset. Raise "
			+ "SpacetimeDBConnectionOptions.inbound_buffer_size (the server allows "
			+ "itself up to 32 MiB per message), turn on "
			+ "SpacetimeDBConnectionOptions.compression so large payloads arrive "
			+ "compressed, or narrow the subscription that produced it."
		)
		% inbound_buffer_size
	)


## Drops the current peer and puts a fresh one in its place, carrying over the
## settings [method apply_options] applied — a new [WebSocketPeer] starts with the
## engine defaults, and a heartbeat_interval left at 0 would silently disable both
## keepalive and the stall detection that reads it.
func _reset_peer() -> void:
	if _websocket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_websocket.close()
	_websocket = WebSocketPeer.new()
	_websocket.inbound_buffer_size = _inbound_buffer_size
	_websocket.outbound_buffer_size = _outbound_buffer_size
	_websocket.heartbeat_interval = _heartbeat_seconds


## [param size] if the engine can work with it, else [constant DEFAULT_BUFFER_SIZE].
##
## The engine takes a degenerate buffer size and breaks quietly rather than refusing it:
## 0 opens the socket and drops every message with no packet, no close and no error, and
## a negative one hangs the process on the first poll (see [constant MIN_BUFFER_SIZE]).
## Neither is something a game can diagnose from what it observes, so the value is
## refused here — loudly, and once per [method apply_options].
static func resolve_buffer_size(size: int, setting: String) -> int:
	if size > MAX_BUFFER_SIZE:
		push_error(
			(
				"SpacetimeDBConnection: %s = %d is above the %d-byte maximum, which the "
				+ "engine would truncate to a 32-bit int; using %d instead."
			)
			% [setting, size, MAX_BUFFER_SIZE, MAX_BUFFER_SIZE]
		)
		return MAX_BUFFER_SIZE
	if size >= MIN_BUFFER_SIZE:
		return size
	push_error(
		(
			"SpacetimeDBConnection: %s = %d is below the %d-byte minimum and cannot carry "
			+ "a message; using the default %d instead."
		)
		% [setting, size, MIN_BUFFER_SIZE, DEFAULT_BUFFER_SIZE]
	)
	return DEFAULT_BUFFER_SIZE


## [param value] if it is a usable interval, else [param fallback].
##
## Zero is legal and documented for both callers — it disables keepalive / the handshake
## budget. Negative is not: [method WebSocketPeer.set_heartbeat_interval] refuses it
## (`ERR_FAIL_COND p_interval < 0`) and leaves the property at whatever it already held —
## 0 on a fresh peer, the previous session's interval on a re-applied one — and the SDK's own
## thresholds derived from the same number go negative and stop firing — so asking for a
## SHORTER interval than the default silently turned dead-socket detection off entirely.
## Falling back keeps the protection on, which is the safer reading of a value that
## cannot have been meant.
static func resolve_interval_seconds(value: float, minimum: float, fallback: float, setting: String) -> float:
	# Zero first, and on its own: it is the documented way to turn the matching timeout
	# off, so it has to survive a minimum that would otherwise refuse it.
	if value == 0.0:
		return 0.0
	# The upper bound is load-bearing, not defensive: both callers turn the result into
	# milliseconds as an int, and a conversion that does not fit gives INT64_MIN — so an
	# interval too large to represent stopped every threshold derived from it, which is
	# the opposite of what asking for a large one means. NaN fails this test too (every
	# comparison against it is false), which is the intent, not an accident.
	if value >= minimum and value <= MAX_INTERVAL_SECONDS:
		return value
	push_error(
		(
			"SpacetimeDBConnection: %s = %f is not a usable interval (outside %.1f to %.1f "
			+ "seconds, or NaN) and would leave the matching timeout mis-set; using %.1f "
			+ "instead. Set 0.0 to disable it deliberately."
		)
		% [setting, value, minimum, MAX_INTERVAL_SECONDS, fallback]
	)
	return fallback


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
	# Query string cut off: on Web the token travels in it (the handshake there cannot
	# carry an Authorization header), so the full URL would put a credential in the
	# console for anyone running with debug_mode on. Same cut as the two diagnostics.
	_print_log("SpacetimeDBConnection: Attempting to connect to: " + _url_without_query())

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
