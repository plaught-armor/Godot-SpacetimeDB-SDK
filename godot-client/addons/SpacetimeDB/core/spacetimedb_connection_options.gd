## Configuration resource passed to [method SpacetimeDBClient.connect_db].
##
## Controls WebSocket behaviour, threading, authentication, reconnection
## strategy, and performance monitoring. Create one, tweak the members, and
## hand it to [code]connect_db()[/code].
class_name SpacetimeDBConnectionOptions
extends Resource

const CompressionPreference = SpacetimeDBConnection.CompressionPreference

## WebSocket payload compression mode. None, Gzip, and Brotli are all supported
## (Brotli decoded via Godot's built-in decoder).
var compression: CompressionPreference = CompressionPreference.NONE
## If [code]true[/code], BSATN deserialization runs on a background thread.
var threading: bool = true
## If [code]true[/code], the SDK requests a fresh token on every connection.
var one_time_token: bool = true
## If [code]false[/code], the acquired token is never persisted to disk.
## Typically paired with [member one_time_token] = [code]true[/code].
var save_token: bool = true
## Pre-set authentication token. If empty, the SDK will request one automatically.
var token: String = ""
## Enables verbose logging in the SDK's connection and client classes.
var debug_mode: bool = false
## Registers custom Godot [Performance] monitors for packet/byte throughput.
var monitor_mode: bool = false
## If [code]true[/code], asks for "light" subscription updates ([code]&light=true[/code]
## on the handshake).
##
## [b]This has no effect on the protocol this SDK speaks.[/b] The server maps the
## parameter to its [code]tx_update_full[/code] client config, which is read in exactly
## one place — the v1 message sender, where it decides between a full
## [code]TransactionUpdate[/code] (reducer name, caller identity, energy) and a
## [code]TransactionUpdateLight[/code]. The v3 wire type carries neither:
## [code]ws_v2::TransactionUpdate[/code] is nothing but its query-set row deltas, so
## every update a v3 client receives is already what v1 called light. Verified against
## the server at 2.8.0; unchanged across every supported version.
##
## Kept, and still sent, because it costs one query parameter and it is what the other
## SDKs send — if a later protocol gives the flag meaning again, a game that already
## sets it keeps working. Do not expect it to change bandwidth today.
var light_mode: bool = false
## If [code]true[/code], the server waits for each transaction to be durably
## committed before sending its update (read-after-commit). Higher latency, stronger
## durability.
##
## Default [code]true[/code], which is what the server applies to a v3 connection that
## does not ask ([code]DEFAULT_CONFIRMED_READS[/code], unchanged across every supported server —
## 2.2.0 through 2.7.1). The Rust and C# SDKs send the parameter only when the caller
## sets it, so this default is also what they effectively connect with; this SDK always
## sends it, so a future change to the server's default cannot silently move the
## consistency guarantee under an existing game. Set [code]false[/code] to trade
## durability for latency: updates then arrive as soon as the transaction commits in
## memory, which means a crash before that write is durable can retract rows the client
## already showed.
var confirmed_reads: bool = true
## Maximum size in bytes of the WebSocket inbound buffer (default 2 MB).
##
## Also the largest message this client can receive at all. A bigger one is never
## delivered: sent as a single frame it closes the socket with 1009, and sent as
## fragments — what a real server does with a large snapshot — the engine drops it and
## the SDK ends the session with an error naming this setting (see
## [constant SpacetimeDBConnection.CLOSE_MESSAGE_TOO_BIG]). The server's own limit is
## 32 MiB, so raise this — or enable [member compression] — for a subscription whose
## initial payload runs large.
var inbound_buffer_size: int = 1024 * 1024 * 2
## Maximum size in bytes of the WebSocket outbound buffer (default 2 MB).
var outbound_buffer_size: int = 1024 * 1024 * 2
## Interval in seconds between WebSocket keepalive pings. The peer sends a PING every
## interval and closes the connection — triggering auto-reconnect if enabled — when no
## PONG arrives before the next one, detecting a dead/half-open socket within ~2 intervals
## instead of waiting out the OS TCP timeout (minutes). [code]0.0[/code] disables keepalive.
var heartbeat_interval_seconds: float = 15.0
## Seconds a connection attempt may sit in the WebSocket handshake (TCP connect plus
## HTTP upgrade) before it is abandoned and reported as [constant ERR_TIMEOUT].
##
## Godot's [WebSocketPeer] has no handshake timeout of its own — [member
## WebSocketMultiplayerPeer.handshake_timeout] belongs to the multiplayer peer, and
## [code]WSLPeer::poll[/code] only ages a socket once it is open. So a remote that
## accepts the TCP connection and never answers the upgrade (a proxy in front of a
## dead upstream, a half-open NAT entry, a server wedged mid-boot) leaves the client
## in [constant WebSocketPeer.STATE_CONNECTING] for as long as it holds the socket:
## no [signal SpacetimeDBClient.connected], no [signal
## SpacetimeDBClient.connection_error], and no auto-reconnect either, because the
## attempt that would have to fail first never ends.
##
## A frozen frame loop is not counted against the handshake: a poll gap over
## [constant SpacetimeDBConnection.HANDSHAKE_STALL_GAP_MS] is credited back to it, up
## to one budget in total. That rule does not read [member heartbeat_interval_seconds],
## so turning keepalive off does not quietly harden this budget.
##
## [code]0.0[/code] disables the timeout and restores that wait-forever behaviour.
var connect_timeout_seconds: float = 15.0

## Per-frame time budget in microseconds for applying parsed server messages.
## Higher values drain bursts (initial subscription, mass updates) faster at the
## cost of more frame time; lower values keep frames smoother but backlog longer.
## When [member auto_tune_frame_budget] is enabled this is the seed value; the
## runtime then adjusts it within [member frame_budget_min_us]/[member frame_budget_max_us].
var frame_budget_us: int = 4000
## Hard ceiling on messages applied per frame, regardless of the time budget.
## Safety backstop against unbounded drain; rarely the binding limit.
var max_messages_per_frame: int = 256

## If [code]true[/code], [member frame_budget_us] is auto-tuned at runtime by an
## fps feedback loop: ramp up while a backlog drains and fps stays healthy, back
## off when fps dips. Finds the largest safe budget for the current hardware/scene.
var auto_tune_frame_budget: bool = true
## Lower clamp for the auto-tuned budget (microseconds).
var frame_budget_min_us: int = 1000
## Upper clamp for the auto-tuned budget (microseconds).
var frame_budget_max_us: int = 8000
## Target fps the auto-tuner defends. [code]0[/code] resolves it: the engine's frame cap
## ([member Engine.max_fps]) once the game is actually reaching it, otherwise
## [member Engine.physics_ticks_per_second].
##
## The tuner reads the RENDERED frame rate, so the target has to be a rendered rate too.
## A cap the game reaches is the rate it asked for — comparing it against the physics
## rate instead made a 30 fps cap on 60 Hz physics read as permanently below target and
## drove the drain budget to its floor. A cap it does not reach is fiction, so it is
## ignored: capping above what the hardware delivers must not do the same thing in
## reverse. Set this explicitly when the cap comes from vsync rather than
## [member Engine.max_fps], or when capping far below the physics rate for power — down
## there the rendered rate stops answering "is the drain costing too much", since the
## engine sleeps out the difference.
var auto_tune_target_fps: int = 0

## If [code]true[/code], the client automatically reconnects after unintentional disconnects.
var auto_reconnect: bool = false
## Maximum reconnect attempts before giving up. [code]0[/code] means infinite.
var max_reconnect_attempts: int = 10
## Initial delay in seconds before the first reconnect attempt.
var reconnect_initial_delay: float = 1.0
## Maximum delay cap in seconds after exponential backoff.
var reconnect_max_delay: float = 30.0
## Multiplier applied to the delay after each failed attempt.
var reconnect_backoff_multiplier: float = 2.0
## Fraction of the computed delay used as random jitter ([code]0.0[/code]–[code]1.0[/code]).
var reconnect_jitter_fraction: float = 0.5
## If [code]true[/code], regaining application focus fires a reconnect attempt that is
## still waiting out its backoff delay, instead of letting the delay run down.
##
## A backgrounded app's frame loop is throttled (heavily so in a web export's
## background tab, and stopped outright while a mobile app is suspended), which stalls
## the [SceneTreeTimer] the backoff runs on: a drop that happens while the app is in
## the background would otherwise sit unreconnected for the remainder of a delay that
## barely ticks. The attempt counter is not reset, so [member max_reconnect_attempts]
## still bounds the cycle.
var reconnect_on_app_resume: bool = true

## Whether the client keeps running while the [SceneTree] is paused.
##
## The socket is polled from [method Node._physics_process], and that is where Godot's
## [WebSocketPeer] sends its keepalive ping, reads inbound frames and flushes outbound
## ones. A node left on the default process mode stops being processed the moment
## [member SceneTree.paused] is set, so a game paused the ordinary way stops polling
## entirely: the server sees an idle connection and closes it (its timeout is 30
## seconds), inbound frames pile up unread, and a reducer call made while paused is
## queued but never flushed.
##
## Left [code]true[/code], the client and its children process regardless of the pause
## state, which is what keeps a paused game connected. The cost is that the client keeps
## delivering while the game is paused: row callbacks and the signals they are re-emitted
## as, but also reducer and procedure results, and the connection signals. Godot runs a
## connected [Callable] whichever process mode its owner has, so a [RowReceiver] left on
## the default mode still forwards rows during the pause. That matches the server's world
## not stopping, which is usually what you want. Set it to [code]false[/code] to freeze
## the SDK with the game and accept that a pause longer than the server's idle timeout
## drops the connection.
var process_while_paused: bool = true


## Convenience setter — sets both [member inbound_buffer_size] and [member outbound_buffer_size].
func set_all_buffer_size(size: int) -> void:
	inbound_buffer_size = size
	outbound_buffer_size = size
