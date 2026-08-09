## High-level SpacetimeDB client node.
##
## Orchestrates connection, authentication, BSATN (de)serialization, the local
## database mirror, subscriptions, reducer/procedure calls, and automatic
## reconnection. Generated module clients (e.g. [code]WorldModuleClient[/code])
## extend this with typed database and reducer accessors.
#@tool
class_name SpacetimeDBClient
extends Node

## Emitted after the server sends [IdentityTokenMessage] confirming the connection.
signal connected(identity: PackedByteArray, token: String)
## Emitted when the WebSocket is cleanly closed.
signal disconnected
## Emitted on connection failure or abnormal close.
signal connection_error(code: int, reason: String)
## Emitted after the first [SubscribeAppliedMessage] is processed.
signal database_initialized
## Re-emitted from [LocalDatabase] when a row is inserted.
signal row_inserted(table_name: StringName, row: Resource)
## Re-emitted from [LocalDatabase] when a row is updated.
signal row_updated(table_name: StringName, old_row: Resource, new_row: Resource)
## Re-emitted from [LocalDatabase] just before a row is deleted (still queryable).
signal row_before_delete(table_name: StringName, row: Resource)
## Re-emitted from [LocalDatabase] when a row is deleted.
signal row_deleted(table_name: StringName, row: Resource)
## Re-emitted from [LocalDatabase] after a batch of changes completes.
signal row_transactions_completed(table_name: StringName)
## Emitted for every [TransactionUpdateMessage] applied to the local database.
signal transaction_update_received(update: TransactionUpdateMessage)
## Emitted when a [ReducerResultMessage] arrives. [param tx_update] is [code]null[/code] for okEmpty/err.
signal reducer_result_received(request_id: int, tx_update: TransactionUpdateMessage)
## Emitted when a [ProcedureResultData] arrives. [param return_bytes] is empty on error.
signal procedure_result_received(request_id: int, return_bytes: PackedByteArray)
## Emitted when a [OneOffQueryResponseMessage] arrives.
signal one_off_query_received(
	request_id: int,
	tables: Array[TableUpdateData],
	error_message: String,
)
## Emitted before each reconnect attempt.
signal reconnecting(attempt: int, max_attempts: int)
## Emitted after a successful reconnect and all re-subscriptions are applied.
signal reconnected
## Emitted when all reconnect attempts are exhausted.
signal reconnect_failed
## Internal: fired when the socket drops so pending [method _wait_for_response] awaiters
## (one-off queries, the deprecated reducer/procedure wait helpers) wake immediately
## instead of blocking out their full timeout.
signal _response_wait_aborted

# --- Configuration ---
## Base URL of the SpacetimeDB server (e.g. [code]http://127.0.0.1:3000[/code]).
@export var base_url: String = "http://127.0.0.1:3000"
## Name of the database to connect to.
@export var database_name: String = "quickstart-chat"
## Path to the generated schema directory (tables, types, reducers).
@export var schema_path: String = "res://spacetime_bindings/schema"
## If [code]true[/code], calls [method initialize_and_connect] automatically in [method _ready].
@export var auto_connect: bool = false
## If [code]true[/code], automatically requests a new auth token from the REST API when none is saved.
@export var auto_request_token: bool = true
## File path where authentication tokens are persisted between sessions.
##
## The file holds one token per [member module_name], so several generated clients in
## one project (the multi-module autoload codegen emits) keep their own identity even
## though they share this default path. Point two clients at the same path deliberately
## and they still keep separate entries; give one client its own path to isolate it
## completely.
@export var token_save_path: String = "user://spacetimedb_token.dat"
## If [code]true[/code], the token is not saved to disk (single-use session).
@export var one_time_token: bool = false
## If [code]false[/code], the acquired token is never written to [member token_save_path].
## Pair with [member one_time_token] = [code]true[/code] (request a fresh token each
## connection) to avoid persisting a token that is then ignored on the next connect.
@export var save_token: bool = true
## WebSocket compression preference negotiated with the server.
@export var compression: SpacetimeDBConnection.CompressionPreference
## If [code]true[/code], enables verbose logging from the client.
@export var debug_mode: bool = true
## Active subscriptions keyed by query set id.
var current_subscriptions: Dictionary[int, SpacetimeDBSubscription]
## If [code]true[/code], BSATN deserialization runs on a background thread.
@export var use_threading: bool = true

## Module name used for schema resolution (set by generated subclasses).
var module_name: String = ""
## Background thread running the BSATN deserializer (only when [member use_threading] is [code]true[/code]).
var deserializer_worker: Thread
## Connection options controlling threading, compression, and reconnection behaviour.
##
## Assigning resolves the reconnect pacing (see [method _resolve_reconnect_pacing]), so a
## knob the SDK cannot use is reported at the assignment that set it as well as at the drop
## that would have run on it. The value a cycle actually runs on is re-resolved when the
## cycle starts, so mutating a field on an options object already assigned here is honoured
## — what the setter buys is the early diagnostic, not the value.
var connection_options: SpacetimeDBConnectionOptions:
	set(value):
		connection_options = value
		_resolve_reconnect_pacing(value)
## Subscriptions waiting for a [SubscribeAppliedMessage], keyed by query set id.
var pending_subscriptions: Dictionary[int, SpacetimeDBSubscription]
var _packet_queue: Array[PackedByteArray] = []
var _packet_semaphore: Semaphore
var _result_queue: Array[SpacetimeDBServerMessage] = []
# Drain batch held across frames + a cursor into it (main thread only). A batch
# is refilled from _result_queue only once fully drained, and the cursor advances
# in place — so a multi-frame backlog is never re-sliced/re-queued (O(1)/frame
# instead of O(remaining) copy/frame). Newly parsed messages wait in
# _result_queue until the current batch finishes, preserving arrival order.
var _drain_batch: Array[SpacetimeDBServerMessage] = []
var _drain_cursor: int = 0
var _result_mutex: Mutex
var _packet_mutex: Mutex
var _thread_should_exit: bool = false
## Incremented (under _packet_mutex) on every reconnect prep. The deserializer
## worker captures it when draining and re-checks it before flushing results, so
## packets parsed under a prior session are discarded instead of being applied to
## the fresh post-reconnect database.
var _session_epoch: int = 0
# Per-frame apply drain limits: time budget (primary) + hard message ceiling
# (bounded-loop backstop). Set from SpacetimeDBConnectionOptions in connect_db.
# _frame_budget_us is a live value when auto-tuning is on (mutated by
# _auto_tune_budget), otherwise the fixed configured budget.
var _frame_budget_us: int = 4000
var _max_msgs_per_frame: int = 256
var _auto_tune_budget_enabled: bool = true
var _frame_budget_min_us: int = 1000
var _frame_budget_max_us: int = 8000
var _auto_tune_target_fps: int = 0
const _MAX_RESULT_CACHE_SIZE: int = 256
## Cap on outstanding call handles retained, applied per kind (reducer, procedure).
## A response that never arrives strands its handle: the pending maps are cleared by a
## matching response or by a disconnect, and neither happens when a packet is lost while
## the socket stays up (the parser drops a corrupt buffer and keeps the connection).
## Same number as [constant SpacetimeDBStats.MAX_PENDING], which bounds the four-category
## total rather than any one kind — the constant is shared, the running counts are not.
const _MAX_PENDING_CALLS: int = SpacetimeDBStats.MAX_PENDING
# Cache of reducer results that arrived before anyone called wait_for_reducer_response
var _reducer_result_cache: Dictionary[int, TransactionUpdateMessage] = { } # request_id -> TransactionUpdateMessage (or null)
var _pending_reducer_calls: Dictionary[int, SpacetimeDBReducerCall] = { }
var _pending_procedure_calls: Dictionary[int, SpacetimeDBProcedureCall] = { }
var _procedure_result_cache: Dictionary[int, PackedByteArray] = { }
# Per-request round-trip latency, keyed by category. Always-on diagnostics.
var _stats: SpacetimeDBStats = SpacetimeDBStats.new()
var _one_off_query_cache: Dictionary[int, Array] = { }
# --- Components ---
var _connection: SpacetimeDBConnection
var _deserializer: BSATNDeserializer
# Separate deserializer for main-thread SpacetimeDBReducerCall/ProcedureCall
# decode(): the worker thread mutates _deserializer's status/pending/plan/name
# caches while parsing, so a user handler calling decode() on the main thread must
# NOT touch the same instance (unguarded concurrent Dictionary writes = corruption).
# decode() is always main-thread + synchronous, so a single dedicated instance is
# race-free without a lock.
var _decode_deserializer: BSATNDeserializer
var _serializer: BSATNSerializer
var _local_db: LocalDatabase
var _rest_api: SpacetimeDBRestAPI # Optional, for token/REST calls
# --- State ---
var _connection_id: PackedByteArray
var _identity: PackedByteArray
var _token: String
var _is_initialized: bool = false
var _received_initial_subscription: bool = false
var _next_query_id: int = 0
var _next_request_id: int = 0
# --- Reconnection State ---
enum _ReconnectState {
	IDLE,
	RECONNECTING,
}
var _reconnect_state: _ReconnectState = _ReconnectState.IDLE
var _reconnect_attempt: int = 0

## Shortest reconnect delay the SDK will pace a cycle at — enforced on the computed backoff
## itself, not only on the knobs it is computed from.
##
## The backoff runs on a [SceneTreeTimer], which cannot resolve finer than a frame, so a
## delay under this is not a shorter wait — it is no wait at all, and the cycle degenerates
## into one connection attempt per frame for as long as the budget allows (measured against
## a closed port: 50 attempts in 120 frames, and with the documented
## [code]max_reconnect_attempts = 0[/code] that never ends). A delay below it is refused for
## the default rather than raised to it — see [method _resolve_reconnect_delay].
##
## It is a frame-resolution floor, not a politeness one, so it is also the SDK's fastest
## sustained retry: a caller who sets [member SpacetimeDBConnectionOptions.reconnect_max_delay]
## to this value and [member SpacetimeDBConnectionOptions.max_reconnect_attempts] to
## [code]0[/code] gets an unbounded cycle at 1/this — ten attempts a second — because both
## values are legal and mean what they say. Raise this constant, not the resolvers, if that
## ceiling ever needs to be lower.
const MIN_RECONNECT_DELAY_SECONDS: float = 0.1
## Longest reconnect delay the SDK will wait out, and the ceiling both delay knobs clamp to.
##
## Bounding the top is what keeps the computed backoff finite: an infinite or NaN delay
## reaches [method SceneTree.create_timer], which answers a non-finite wait by either never
## timing out (INF — the cycle then has no next attempt, no [signal reconnect_failed] and no
## [signal disconnected], i.e. a wedge with no signal at all) or by firing on the next frame
## (NaN — the storm above).
const MAX_RECONNECT_DELAY_SECONDS: float = 3600.0
## Largest per-attempt multiplier accepted. Anything above this saturates
## [member SpacetimeDBConnectionOptions.reconnect_max_delay] on the second attempt anyway,
## so the ceiling costs no reachable behaviour and keeps [method @GlobalScope.pow] finite.
const MAX_BACKOFF_MULTIPLIER: float = 1000.0
## Delay before the first reconnect attempt, and the fallback for one that cannot have
## been meant. See [member SpacetimeDBConnectionOptions.reconnect_initial_delay].
const DEFAULT_RECONNECT_INITIAL_DELAY: float = 1.0
## Ceiling the escalating backoff saturates at. See
## [member SpacetimeDBConnectionOptions.reconnect_max_delay].
const DEFAULT_RECONNECT_MAX_DELAY: float = 30.0
## Per-attempt multiplier. See
## [member SpacetimeDBConnectionOptions.reconnect_backoff_multiplier].
const DEFAULT_BACKOFF_MULTIPLIER: float = 2.0
## Attempts before the cycle gives up. See
## [member SpacetimeDBConnectionOptions.max_reconnect_attempts].
const DEFAULT_MAX_RECONNECT_ATTEMPTS: int = 10
## Share of the delay used as random jitter. See
## [member SpacetimeDBConnectionOptions.reconnect_jitter_fraction]. Unlike its siblings this
## is not a fallback — the resolver clamps rather than refusing — but the member default has
## to agree with the option default, so it is named here for both to use.
const DEFAULT_JITTER_FRACTION: float = 0.5
## Shortest response deadline a caller can ask an await for, and the floor
## [method resolve_wait_timeout] refuses below.
##
## Every awaited call in the public surface — [method query_sql],
## [method wait_for_reducer_response], [method wait_for_procedure_response],
## [method SpacetimeDBReducerCall.wait_for_response],
## [method SpacetimeDBProcedureCall.wait_for_response],
## [method SpacetimeDBSubscription.wait_for_applied] and
## [method SpacetimeDBSubscription.wait_for_end] — measures out on a [SceneTreeTimer], so a
## deadline under a frame is not a shorter wait but no wait at all: the response the server
## is already sending arrives after the caller has been told it never came. Three frames at
## 60 fps is the smallest deadline that can survive a frame of scheduling jitter.
const MIN_RESPONSE_TIMEOUT_SECONDS: float = 0.05
## Longest response deadline the SDK will wait out, and the ceiling
## [method resolve_wait_timeout] clamps to.
##
## [code]INF[/code] is the obvious way to spell "no timeout" and is the one value
## [method SceneTree.create_timer] never answers: the await is suspended for the life of the
## process, and with it the caller's coroutine, its signal connection and its entry in the
## response cache. Bounding the top turns that into a wait that ends.
const MAX_RESPONSE_TIMEOUT_SECONDS: float = 3600.0
## Deadline an await falls back to when the caller's is not one that can be waited out.
## Matches the default argument of the client's own waiters, so a refused deadline behaves
## as if the caller had passed nothing. The subscription handle's waiters default to a
## different number and pass their own — see
## [constant SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS].
const DEFAULT_RESPONSE_TIMEOUT_SECONDS: float = 10.0
# Reconnect pacing resolved from SpacetimeDBConnectionOptions (see
# _resolve_reconnect_pacing), so a degenerate knob is refused loudly rather than silently
# shaping every attempt. Defaults mirror the option defaults for a client that was never
# given any.
var _reconnect_initial_delay: float = DEFAULT_RECONNECT_INITIAL_DELAY
var _reconnect_max_delay: float = DEFAULT_RECONNECT_MAX_DELAY
var _reconnect_backoff_multiplier: float = DEFAULT_BACKOFF_MULTIPLIER
var _reconnect_jitter_fraction: float = DEFAULT_JITTER_FRACTION
var _max_reconnect_attempts: int = DEFAULT_MAX_RECONNECT_ATTEMPTS
## Set when the next reconnect should skip the backoff delay (stall-induced close —
## the socket dropped from a local freeze, not a network fault). Consumed on the
## first scheduled attempt.
var _reconnect_immediate: bool = false
# `disconnected` means "terminally disconnected" (not a transient drop that
# auto-reconnect recovers), so it must fire at most once per session. Guards
# against a server close + a cleanup disconnect_db(), or an exhausted reconnect +
# disconnect_db(), double-firing. Re-armed when a fresh connect is requested.
var _disconnected_emitted: bool = false
## Watchdog bound for a resubscribe cycle: if the server accepts the Subscribe but
## never delivers a settle (SubscribeApplied/SubscriptionError) for some query set,
## the cycle would never complete and `reconnected` would never fire. After this it
## is force-completed (epoch-guarded, so a finished/superseded cycle is a no-op).
const RESUBSCRIBE_TIMEOUT_SECONDS: float = 15.0

## Key the token store keeps a pre-store token under — the single bare token a file
## written before the store existed holds, which belongs to no module because every
## module read it. No module can claim it: a generated [member module_name] is a GDScript
## identifier derived from the database name, and [method token_store_write] refuses this
## key outright for a client that sets the property by hand. An EMPTY module name is a
## normal key, not a reserved one — a client built by hand rather than by codegen has no
## module name, and two of those share one entry the way every client used to.
const TOKEN_STORE_LEGACY_KEY: String = "*"

var _saved_subscription_queries: Array[PackedStringArray] = []
## Query ids whose Unsubscribe has gone out but whose UnsubscribeApplied has not come
## back. Membership, not a flag on the handle: the server owns when a subscription
## really ends, and until it answers the entry has to stay in current/pending (that is
## where its rows and its handle live). What this set adds is that a drop in that window
## must not carry the query into the reconnect — without it, a query the caller
## explicitly dropped comes back on the new socket and can never be dropped again,
## because the resubscribe makes a fresh internal handle the caller has no reference to.
## Only ever holds ids that were in current/pending when the Unsubscribe was sent, so it
## is bounded by the live subscription count; cleared with those maps.
var _unsubscribing_query_ids: Dictionary[int, bool] = { }
## Bumped on every new reconnect cycle (start/cancel/resubscribe). A resubscribe
## settle-callback captures the epoch live when it was armed and bails if the epoch
## has since moved on, so a superseded cycle's late `applied`/`end` can't clear the
## saved queries or spuriously emit `reconnected` on a cycle that already moved past it.
var _resubscribe_epoch: int = 0
## Bumped by every call that states what the caller wants the connection to be doing —
## [method connect_db] and [method disconnect_db]. [method connect_db] captures it before
## reporting its cache wipe, which is game code, and stops if the number has moved by the
## time the wipe returns: a listener that disconnected or started its own connect has
## replaced this call's intent, and carrying on would connect against a disconnect or
## clobber the newer call's host and options. [method _attempt_reconnect] makes the same
## re-check against [member _reconnect_state] after its own wipe.
var _session_intent: int = 0
var _reconnect_timer: SceneTreeTimer = null
## Set when a reconnect cycle was in flight as the client left the tree, so
## [method _enter_tree] can pick it up again. See [method _suspend_reconnection].
var _reconnect_suspended: bool = false
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_apply_process_mode()
	if auto_connect:
		initialize_and_connect()


## Puts the client (and with it every child: the connection, the REST handler, the
## local database) on a process mode that survives [member SceneTree.paused], unless
## [member SpacetimeDBConnectionOptions.process_while_paused] says otherwise.
##
## The socket is polled from [method Node._physics_process], and that poll is what
## sends the keepalive ping, reads inbound frames and flushes outbound ones. On the
## default process mode a paused game stops polling altogether and the server closes
## the idle connection. The children stay on [constant Node.PROCESS_MODE_INHERIT], so
## they follow this node.
##
## Opting out selects [constant Node.PROCESS_MODE_PAUSABLE] rather than INHERIT: the
## option promises the SDK freezes with the game, and INHERIT would quietly hand that
## decision to an ancestor — a client parented under an always-process node would keep
## running despite the opt-out.
func _apply_process_mode() -> void:
	var keep_running: bool = connection_options == null or connection_options.process_while_paused
	process_mode = Node.PROCESS_MODE_ALWAYS if keep_running else Node.PROCESS_MODE_PAUSABLE


# --- WebSocket Message Handling ---
func _physics_process(_delta: float) -> void:
	_process_results_asynchronously()


func _notification(what: int) -> void:
	# All three mean "the frame loop is running again", and which one the platform
	# sends varies: FOCUS_IN on desktop/mobile, RESUMED on Android/iOS, the window-level
	# one on web. Handling all three is free — the handler is a no-op unless a reconnect
	# is actually waiting out a backoff.
	if (
		what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED
		or what == NOTIFICATION_WM_WINDOW_FOCUS_IN
	):
		_on_app_resumed()


## Re-arms what [method _exit_tree] tore down, for a client that comes BACK.
##
## [method Node._ready] runs once per node; [method Node._exit_tree] and this run once
## per tree entry. A client moved between parents — reparented under a level, pulled out
## and put back by a pool, `remove_child` then `add_child` — therefore leaves with its
## deserializer worker joined and any reconnect backoff dropped, and nothing else ever
## put either back: [method connect_db] and [method initialize_and_connect] are the only
## other callers of [method _setup_threading] and neither runs again on re-entry.
## Measured (tests/_probe_client_reparent.gd): the socket stayed open,
## [method is_connected_db] kept answering true, and every message after the reparent was
## queued for a worker that no longer existed — 0 of 40 delivered, in silence. Threadless
## clients were unaffected, which is what named the worker as the cause.
## A suspended cycle implies an initialized client — RECONNECTING is only reachable from
## a connection error, which needs [method initialize_and_connect] to have run — so the
## two branches below cannot disagree today. Stated because they read as independent.
func _enter_tree() -> void:
	if _is_initialized:
		_setup_threading()
	if _reconnect_suspended:
		_reconnect_suspended = false
		# Deferred, not called here: Godot enters the parent before its children, so at
		# this point the client's own _connection, _local_db and _rest_api are still out
		# of the tree — and _schedule_next_reconnect_attempt emits `reconnecting`
		# (or, on the last attempt, `reconnect_failed` + `disconnected`) straight into
		# game code, which may call back in. One frame later the client is whole.
		#
		# The attempt counter is deliberately not reset: a client that leaves and
		# re-enters repeatedly must still run out of attempts. The flip side is that
		# tree churn spends them — a client detached and re-attached max_reconnect_attempts
		# times while a cycle is in flight reaches `reconnect_failed` without the network
		# having been tried that often.
		_resume_suspended_reconnect.call_deferred()


func _exit_tree() -> void:
	# Suspended, not cancelled. A detached client polls no socket, so the attempt this
	# backoff leads to could not be serviced — but cancelling drops the saved
	# subscription queries with it, so a client moved between parents mid-backoff never
	# reconnected and silently lost the set it would have restored. _enter_tree schedules
	# the next attempt instead.
	_suspend_reconnection()
	if deserializer_worker:
		_thread_should_exit = true
		_packet_semaphore.post()
		deserializer_worker.wait_to_finish()
		deserializer_worker = null
		# Cleared for the next worker: the flag is what the loop runs on, so leaving it
		# set made a restarted worker exit on its first check — alive for an instant,
		# then gone, with the queue still filling.
		_thread_should_exit = false


## Prints [param log_message] to the output console when [member debug_mode] is enabled.
func print_log(log_message: String) -> void:
	if debug_mode:
		print(log_message)


## Initializes the schema, serializers, local database, REST API, and connection,[br]
## then loads or requests a token and connects to the server.[br]
## Safe to call multiple times — subsequent calls are ignored if already initialized.
func initialize_and_connect() -> void:
	if _is_initialized:
		return

	_disconnected_emitted = false # re-arm the terminal signal for this session
	print_log("SpacetimeDBClient: Initializing...")

	# 1. Load Schema
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new(module_name, schema_path, debug_mode)

	# 2. Initialize Parser
	_deserializer = BSATNDeserializer.new(schema, debug_mode)
	_decode_deserializer = BSATNDeserializer.new(schema, debug_mode)
	_serializer = BSATNSerializer.new(debug_mode)

	# 3. Initialize Local Database
	_local_db = LocalDatabase.new(schema)
	_init_db(_local_db)

	# Re-emit LocalDatabase signals as the client's own (named methods, not lambdas —
	# the formatter mangles inline-lambda indentation; see project rule S1).
	_local_db.row_inserted.connect(_forward_row_inserted)
	_local_db.row_updated.connect(_forward_row_updated)
	_local_db.row_before_delete.connect(_forward_row_before_delete)
	_local_db.row_deleted.connect(_forward_row_deleted)
	_local_db.row_transactions_completed.connect(_forward_row_transactions_completed)
	_local_db.name = "LocalDatabase"
	add_child(_local_db) # Add as child if it needs signals

	# Covers the path connect_db does not: base_url set in the inspector and
	# initialize_and_connect() called directly. Both consumers strip the trailing slash
	# themselves, but the property is public, so it reads back as what will be used.
	base_url = base_url.rstrip("/")

	# 4. Initialize REST API Handler (optional, mainly for token)
	_rest_api = SpacetimeDBRestAPI.new(base_url, debug_mode)
	_rest_api.token_received.connect(_on_token_received)
	_rest_api.token_request_failed.connect(_on_token_request_failed)
	_rest_api.name = "RestAPI"
	add_child(_rest_api)

	# 5. Initialize Connection Handler
	_connection = SpacetimeDBConnection.new(connection_options, database_name)
	_connection.disconnected.connect(_on_connection_disconnected)
	_connection.connection_error.connect(_on_connection_error)
	_connection.connection_stalled.connect(_on_connection_stalled)
	_connection.message_received.connect(_on_websocket_message_received)
	_connection.name = "Connection"
	add_child(_connection)

	# Ensure the deserializer thread + sync primitives exist before any WS frame
	# arrives. connect_db() already calls this, but initialize_and_connect() can be
	# invoked directly, in which case use_threading defaults true and the message
	# handler would hit a null _packet_mutex on the first frame.
	_setup_threading()

	_is_initialized = true
	print_log("SpacetimeDBClient: Initialization complete.")

	# 6. Get Token and Connect
	_load_token_or_request()


## Connects to a SpacetimeDB [param database_name] at [param host_url].[br]
## Pass a [SpacetimeDBConnectionOptions] to configure threading, compression, and reconnection.
##
## Call [method disconnect_db] first if a session is already live: this method starts a
## session, it does not re-point one, and on a connected client it is refused outright.
## "Connected" here is [method is_connected_db] — the socket is open. A call made while
## a handshake is still running is allowed and supersedes that attempt, since there is
## no session yet for it to splice itself into.
func connect_db(
	host_url: String,
	database_name: String,
	options: SpacetimeDBConnectionOptions = null,
) -> void:
	if is_connected_db():
		# Refused rather than half-applied. The old shape of this call wrote host,
		# database and options over the live session's and then returned without
		# opening a socket or handing the options to the connection — so the socket
		# kept the previous buffers, heartbeat and compression while the client
		# reported the new target, and the next drop auto-reconnected to a host the
		# caller never connected to, carrying the old session's subscriptions.
		# Nothing here is changed, so a caller that ignores this error keeps a
		# coherent session rather than a spliced one.
		push_error(
			(
				"SpacetimeDBClient: already connected to '%s' — call disconnect_db() "
				+ "before connecting to '%s' at %s. Nothing was changed."
			)
			% [self.database_name, database_name.to_lower(), host_url]
		)
		return

	_cancel_reconnection()
	_disconnected_emitted = false # re-arm the terminal signal for this session
	# A call that starts a session, rather than reconfiguring a live one, has to leave the
	# last session's mirror behind. disconnect_db deliberately keeps those rows so a game
	# can still read last-known state while offline, but they cannot be the floor the next
	# session builds on: the resubscribe lands on top of them, so every re-delivered row
	# comes back one refcount high and its own unsubscribe can no longer evict it, while a
	# row deleted server-side in the meantime stays cached with no on_delete to report it.
	# The wipe reports every row as deleted, exactly as the auto-reconnect one does, and
	# re-arms database_initialized so the new session announces itself.
	_session_intent += 1
	var intent: int = _session_intent
	# Unconditional: the connected case returned above, so by here there is no live
	# session whose mirror this would be pulling out from under a running game.
	# Queues first, then the rows — the same order (and the same reason) as
	# _prepare_for_reconnect: the wipe is the step that runs game code, so everything
	# it might observe has to be settled before it does.
	_drop_dead_session_traffic()
	if _local_db != null:
		_local_db.clear_local_db()
	_received_initial_subscription = false
	# Reporting the wipe runs game code, so by here a listener may have called
	# disconnect_db() or started its own connect_db(). Either one supersedes this
	# call: finishing it would open a socket the listener asked to close, or write
	# this call's host and options over the newer one's. Same countermand check
	# _attempt_reconnect makes after its wipe.
	if intent != _session_intent:
		print_log("SpacetimeDBClient: connect_db superseded while the cache wipe was reported.")
		return
	if not options:
		options = SpacetimeDBConnectionOptions.new()
	# Resolves the reconnect pacing on the way in — see the setter.
	connection_options = options
	# This call may be the first to supply options, or may replace the ones _ready saw.
	_apply_process_mode()
	# Normalized on the way in, so the property reads back as the URL the SDK will
	# actually use — the REST and socket paths both drop the trailing slash themselves.
	# initialize_and_connect() normalizes again for the caller that skips this method.
	self.base_url = host_url.rstrip("/")
	self.database_name = database_name.to_lower()
	self.compression = options.compression
	self.one_time_token = options.one_time_token
	self.save_token = options.save_token
	if not options.token.is_empty():
		# Checked before it is stored, not only where it is used: an unusable token kept
		# in _token survives this call, and a later drop would then spend the whole
		# auto-reconnect budget re-refusing it, one attempt at a time, when the real
		# answer is that the caller handed over a token nothing can connect with.
		var opt_token_reason: String = SpacetimeDBConnection.token_reject_reason(options.token)
		if not opt_token_reason.is_empty():
			push_error("SpacetimeDBClient: refusing options.token — %s." % opt_token_reason)
			_report_connection_error(ERR_UNAUTHORIZED, "Auth token rejected: %s" % opt_token_reason)
			return
		self._token = options.token
	self.debug_mode = options.debug_mode
	self.use_threading = options.threading
	self._auto_tune_budget_enabled = options.auto_tune_frame_budget
	# Resolve + clamp the drain limits in one pure step (unit-tested).
	var cfg: PackedInt32Array = _resolve_drain_config(
		options.max_messages_per_frame,
		options.frame_budget_min_us,
		options.frame_budget_max_us,
		options.frame_budget_us,
		options.auto_tune_target_fps,
	)
	self._max_msgs_per_frame = cfg[0]
	self._frame_budget_min_us = cfg[1]
	self._frame_budget_max_us = cfg[2]
	self._frame_budget_us = cfg[3]
	self._auto_tune_target_fps = cfg[4]

	_setup_threading()

	if not _is_initialized:
		initialize_and_connect()
	else:
		# Already initialized, and — since the connected case returned above — not on a
		# live socket. The connection object survives a disconnect, so hand it this
		# call's options rather than leaving it on the first call's compression, buffer
		# sizes and heartbeat.
		_connection.apply_options(options)
		# Just need token and connect
		_load_token_or_request()


## Intentionally disconnects from the database. Does not trigger auto-reconnect.[br]
## Every outstanding [SpacetimeDBSubscription] ends with it — [signal SpacetimeDBSubscription.end]
## fires for each before [signal disconnected], and the next session starts with none.
## The mirror is deliberately left in place as last-known state.
func disconnect_db() -> void:
	_cancel_reconnection()
	# States an intent, so a connect_db still reporting its cache wipe stops rather than
	# connecting the socket this call just asked to close. See _session_intent.
	_session_intent += 1
	_token = ""
	# Close the socket whenever the peer is live — including mid-handshake
	# (STATE_CONNECTING), which is_connected_db() (== _is_connected, set only on
	# STATE_OPEN) misses. Leaving a handshake running lets it emit connected after
	# the user asked to stop, or trigger an auto-reconnect they cancelled.
	# disconnect_from_server() clears the connection flags, so the later
	# STATE_CLOSED tick stays silent (no rogue connection signal) — that is why the
	# terminal signal is surfaced here instead of via the connection layer.
	if _connection and _connection.is_websocket_active():
		_connection.disconnect_from_server()
	# Wake response waiters and stamp in-flight calls DISCONNECTED so an awaiter
	# gets that outcome rather than a misleading TIMEOUT.
	_response_wait_aborted.emit()
	_fail_pending_calls_disconnected()
	_emit_disconnected()


# Idempotent terminal `disconnected`. See _disconnected_emitted: `disconnected`
# fires at most once per session, so a server-initiated close (or an exhausted
# reconnect) followed by a cleanup disconnect_db() does not double-fire it.
#
# This is the third session boundary, alongside _prepare_for_reconnect and
# connect_db, and it needs the same queue drop they do: the socket is closed but
# packets received from it are still queued, results parsed out of it are still
# waiting, and a batch may be halfway through being applied. Without this they keep
# landing for frames after the terminal signal — row callbacks and transaction
# updates for a session the game has already been told is over, mutating a mirror
# disconnect_db deliberately leaves in place as last-known state. Dropped before the
# signal, so a listener that inspects the client sees a settled one; the call runs
# no game code of its own.
func _emit_disconnected() -> void:
	if _disconnected_emitted:
		return
	_disconnected_emitted = true
	_drop_dead_session_traffic()
	# The session is over, so its subscriptions are too. Left standing, they were still
	# in current/pending when a later connect_db started a NEW session — and the first
	# drop of that session rebuilt its saved query set from them, resubscribing the dead
	# session's queries on top of the live one's. Ending them here also stops
	# `sub.ended` reading false for a subscription nothing can deliver to any more.
	_end_all_subscriptions()
	disconnected.emit()


# Stamps every still-PENDING reducer/procedure call DISCONNECTED and clears the
# pending maps. Shared by disconnect_db and the reconnect path.
func _fail_pending_calls_disconnected() -> void:
	for call_id: int in _pending_reducer_calls:
		var handle: SpacetimeDBReducerCall = _pending_reducer_calls[call_id]
		if handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING:
			handle.outcome = SpacetimeDBReducerCall.Outcome.DISCONNECTED
			handle.error_message = "Connection lost during reducer call"
	_pending_reducer_calls.clear()
	for call_id: int in _pending_procedure_calls:
		var handle: SpacetimeDBProcedureCall = _pending_procedure_calls[call_id]
		if handle.outcome == SpacetimeDBProcedureCall.Outcome.PENDING:
			handle.outcome = SpacetimeDBProcedureCall.Outcome.DISCONNECTED
			handle.error_message = "Connection lost during procedure call"
	_pending_procedure_calls.clear()
	# Subscribes and one-off queries have no handle map to stamp, but their sends are
	# just as dead — the latency tracker holds all four kinds, so retire them together
	# here rather than leaving the in_flight gauge above zero on an idle client.
	_stats.retire_pending()


## Returns [code]true[/code] if the WebSocket is currently open.
func is_connected_db() -> bool:
	return _connection and _connection.is_connected_db()


## Returns the raw [LocalDatabase] instance. Prefer the generated [code].Db[/code] property for typed access.
func get_local_database() -> LocalDatabase:
	return _local_db


## Returns the 32-byte identity assigned to this client by the server.
func get_local_identity() -> PackedByteArray:
	return _identity


## Returns the current authentication token, or an empty string if none acquired yet.
func get_token() -> String:
	return _token


## Returns the per-request latency [SpacetimeDBStats] (reducer / procedure / one-off /
## subscribe round-trip times). Read-only diagnostics; call [code]get_stats().summary()[/code]
## for a quick dump or [code]get_stats().get_tracker(cat)[/code] for a category's numbers.
func get_stats() -> SpacetimeDBStats:
	return _stats


## Subscribes to one or more SQL [param queries]. Returns a [SpacetimeDBSubscription] handle.
func subscribe(queries: PackedStringArray) -> SpacetimeDBSubscription:
	if not is_connected_db():
		push_warning("SpacetimeDBClient: Cannot subscribe, not connected.")
		return SpacetimeDBSubscription.fail(ERR_CONNECTION_ERROR)

	# 1. Generate a request ID
	var request_id: int = _next_request_id
	_next_request_id += 1
	var query_id: int = _next_query_id
	_next_query_id += 1
	# 2. Create the correct payload Resource
	var payload_data: SubscribeMessage = SubscribeMessage.new(request_id, query_id, queries)

	# 3. Serialize the complete ClientMessage using the universal function
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.SUBSCRIBE,
		payload_data,
	)

	if _serializer.has_error():
		printerr(
			"SpacetimeDBClient: Failed to serialize Subscribe message: %s"
			% _serializer.get_last_error()
		)
		return SpacetimeDBSubscription.fail(ERR_PARSE_ERROR)

	# 4. Create subscription handle
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
		self,
		query_id,
		queries,
	)

	# 5. Send the binary message via WebSocket
	if _connection and _connection.is_websocket_active():
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			printerr(
				"SpacetimeDBClient: Error sending Subscribe BSATN message: %s" % error_string(err)
			)
			subscription.error = err
			subscription.mark_ended()
		else:
			print_log(
				"SpacetimeDBClient: Subscribe request sent successfully (BSATN), Query ID: %d"
				% query_id
			)
			pending_subscriptions.set(query_id, subscription)
			_stats.record_send(request_id, SpacetimeDBStats.Category.SUBSCRIBE)

		return subscription

	printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	subscription.error = ERR_CONNECTION_ERROR
	subscription.mark_ended()
	return subscription


## Unsubscribes from the query set identified by [param query_id].[br]
## Returns [constant OK] on success, or an [enum Error] code on failure.
func unsubscribe(query_id: int) -> Error:
	if not is_connected_db():
		push_warning("SpacetimeDBClient: Cannot unsubscribe, not connected.")
		return ERR_CONNECTION_ERROR

	var request_id: int = _next_request_id
	_next_request_id += 1
	# 1. Create the correct payload Resource. SendDroppedRows makes the server echo
	#    the rows being removed so LocalDatabase can decrement the refcount and evict
	#    only rows no longer held by any other active subscription.
	var payload_data: UnsubscribeMessage = UnsubscribeMessage.new(
		request_id,
		query_id,
		UnsubscribeMessage.UnsubscribeFlags.SendDroppedRows,
	)

	# 2. Serialize the complete ClientMessage using the universal function
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.UNSUBSCRIBE,
		payload_data,
	)

	if _serializer.has_error():
		printerr(
			"SpacetimeDBClient: Failed to serialize Unsubscribe message: %s"
			% _serializer.get_last_error()
		)
		return ERR_PARSE_ERROR

	# 3. Send the binary message via WebSocket
	if _connection and _connection.is_websocket_active():
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			printerr(
				"SpacetimeDBClient: Error sending Unsubscribe BSATN message: %s" % error_string(err)
			)
			return err

		print_log(
			"SpacetimeDBClient: Unsubscribe request sent successfully (BSATN), Query ID: %d"
			% query_id
		)
		# Recorded only for a query this client holds a handle for (applied or still
		# pending), so a caller passing an id the client never issued cannot grow the
		# set. See _unsubscribing_query_ids.
		if current_subscriptions.has(query_id) or pending_subscriptions.has(query_id):
			_unsubscribing_query_ids[query_id] = true
		return OK

	printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	return ERR_CONNECTION_ERROR


## Calls a reducer named [param reducer_name] with the given [param args] and BSATN [param types].[br]
## [param ret_bsatn_type] (optional) lets the returned handle BSATN-decode the reducer's ok return
## value via [method SpacetimeDBReducerCall.decode]; empty for reducers that return nothing.[br]
## Returns a [SpacetimeDBReducerCall] handle that resolves when the server responds.
func call_reducer(
	reducer_name: String,
	args: Array = [],
	types: Array = [],
	ret_bsatn_type: StringName = &"",
) -> SpacetimeDBReducerCall:
	if not is_connected_db():
		push_warning("SpacetimeDBClient: Cannot call reducer '%s', not connected." % reducer_name)
		return SpacetimeDBReducerCall.fail(ERR_CONNECTION_ERROR)

	var args_bytes: PackedByteArray = _serializer._serialize_arguments(args, types)

	if _serializer.has_error():
		printerr(
			"Failed to serialize args for %s: %s" % [reducer_name, _serializer.get_last_error()]
		)
		return SpacetimeDBReducerCall.fail(ERR_PARSE_ERROR)

	var request_id: int = _next_request_id
	_next_request_id += 1

	var call_data: CallReducerMessage = CallReducerMessage.new(
		reducer_name,
		args_bytes,
		request_id,
		0,
	)
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.CALL_REDUCER,
		call_data,
	)

	if _serializer.has_error():
		printerr(
			"SpacetimeDBClient: Failed to serialize CallReducer message: %s"
			% _serializer.get_last_error()
		)
		return SpacetimeDBReducerCall.fail(ERR_PARSE_ERROR)

	if _connection and _connection.is_websocket_active():
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			printerr("SpacetimeDBClient: Error sending CallReducer message: %s" % error_string(err))
			return SpacetimeDBReducerCall.fail(err)

		var handle: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(
			self,
			request_id,
			ret_bsatn_type,
		)
		_track_reducer_call(request_id, handle)
		_stats.record_send(request_id, SpacetimeDBStats.Category.REDUCER)
		return handle

	printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	return SpacetimeDBReducerCall.fail(ERR_CONNECTION_ERROR)


## Calls a stored procedure named [param procedure_name] with the given [param args] and BSATN [param types].[br]
## [param return_bsatn_type] is used by the handle to deserialize the return value.[br]
## Returns a [SpacetimeDBProcedureCall] handle that resolves when the server responds.
func call_procedure(
	procedure_name: String,
	args: Array = [],
	types: Array = [],
	return_bsatn_type: StringName = &"",
) -> SpacetimeDBProcedureCall:
	if not is_connected_db():
		push_warning("SpacetimeDBClient: Cannot call procedure, not connected.")
		return SpacetimeDBProcedureCall.fail(ERR_CONNECTION_ERROR)

	var args_bytes: PackedByteArray = _serializer._serialize_arguments(args, types)
	if _serializer.has_error():
		printerr(
			"Failed to serialize args for %s: %s" % [procedure_name, _serializer.get_last_error()]
		)
		return SpacetimeDBProcedureCall.fail(ERR_PARSE_ERROR)

	var request_id: int = _next_request_id
	_next_request_id += 1

	var call_data: CallProcedureMessage = CallProcedureMessage.new(
		procedure_name,
		args_bytes,
		request_id,
		0,
	)
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.CALL_PROCEDURE,
		call_data,
	)

	if _serializer.has_error():
		printerr(
			"SpacetimeDBClient: Failed to serialize CallProcedure message: %s"
			% _serializer.get_last_error()
		)
		return SpacetimeDBProcedureCall.fail(ERR_PARSE_ERROR)

	if _connection and _connection.is_websocket_active():
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			printerr(
				"SpacetimeDBClient: Error sending CallProcedure message: %s" % error_string(err)
			)
			return SpacetimeDBProcedureCall.fail(err)

		var handle: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.create(
			self,
			request_id,
			return_bsatn_type,
		)
		_track_procedure_call(request_id, handle)
		_stats.record_send(request_id, SpacetimeDBStats.Category.PROCEDURE)
		return handle

	printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	return SpacetimeDBProcedureCall.fail(ERR_CONNECTION_ERROR)


## Executes a single SQL query without creating a subscription.[br]
## Returns an [Array] of [TableUpdateData] with the result rows, or an empty array on error/timeout.[br]
## Use [signal one_off_query_received] for non-blocking access.
func query_sql(query: String, timeout_seconds: float = DEFAULT_RESPONSE_TIMEOUT_SECONDS) -> Array[TableUpdateData]:
	if not is_connected_db():
		push_warning("SpacetimeDBClient: Cannot run one-off query, not connected.")
		return []

	var request_id: int = _next_request_id
	_next_request_id += 1

	var payload: OneOffQueryMessage = OneOffQueryMessage.new(request_id, query)
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.ONEOFF_QUERY,
		payload,
	)

	if _serializer.has_error():
		printerr(
			"SpacetimeDBClient: Failed to serialize OneOffQuery message: %s"
			% _serializer.get_last_error()
		)
		return []

	if not (_connection and _connection.is_websocket_active()):
		printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
		return []

	var err: Error = _connection.send_bytes(message_bytes)
	if err != OK:
		printerr("SpacetimeDBClient: Error sending OneOffQuery message: %s" % error_string(err))
		return []

	print_log("SpacetimeDBClient: OneOffQuery sent (request_id=%d): %s" % [request_id, query])
	_stats.record_send(request_id, SpacetimeDBStats.Category.ONE_OFF)

	# Wait for response
	var result: Variant = await _wait_for_response(
		request_id,
		_one_off_query_cache,
		one_off_query_received,
		timeout_seconds,
		1, # one_off_query_received also carries error_message
	)
	if not (result is Array):
		return []
	# `result as Array[TableUpdateData]` would be a silent no-op (C14): the value came
	# from an untyped Dictionary[int, Array], so the cast leaves it runtime-untyped.
	# assign() actually produces a typed Array the caller's `: Array[TableUpdateData]`
	# can rely on.
	var rows: Array[TableUpdateData] = []
	rows.assign(result)
	return rows


## Awaits the reducer result for [param request_id_to_match], returning the [TransactionUpdateMessage] or [code]null[/code] on timeout.
## [br][b]Warning:[/b] a [code]null[/code] return is ambiguous — it can mean a timeout, an [code]okEmpty[/code] outcome, or a server-side error.
## Callers that need the actual outcome should use the [SpacetimeDBReducerCall] returned by generated reducer wrappers and call [code]SpacetimeDBReducerCall.wait_for_response[/code] instead.
func wait_for_reducer_response(
	request_id_to_match: int,
	timeout_seconds: float = DEFAULT_RESPONSE_TIMEOUT_SECONDS,
) -> TransactionUpdateMessage:
	if request_id_to_match < 0:
		return null
	return await _wait_for_response(
		request_id_to_match,
		_reducer_result_cache,
		reducer_result_received,
		timeout_seconds,
	)


## Awaits the procedure result for [param request_id_to_match], returning the BSATN [PackedByteArray] or empty on timeout.
func wait_for_procedure_response(
	request_id_to_match: int,
	timeout_seconds: float = DEFAULT_RESPONSE_TIMEOUT_SECONDS,
) -> PackedByteArray:
	if request_id_to_match < 0:
		return PackedByteArray()
	var result: Variant = await _wait_for_response(
		request_id_to_match,
		_procedure_result_cache,
		procedure_result_received,
		timeout_seconds,
	)
	return result if result != null else PackedByteArray()


## [param timeout_seconds] if it is a deadline an await can be measured out by, else
## [param fallback]. [param setting] names the caller for the diagnostic. Argument order
## matches its siblings [method _resolve_reconnect_delay] and
## [method SpacetimeAuthProtocol.resolve_retry_delay].
##
## [param fallback] is the CALLER's default, not one number for the whole SDK: a refused
## deadline has to behave as if the caller had passed nothing, and the subscription handle's
## waiters default to a shorter one than the client's.
##
## Clamped at the top, refused at the bottom, the same split the socket limits
## ([method SpacetimeDBConnection.resolve_buffer_size]) and the reconnect delays
## ([method _resolve_reconnect_delay]) take, and for the same reason: above
## [constant MAX_RESPONSE_TIMEOUT_SECONDS] the intent is unambiguous (wait longer, and
## [code]INF[/code] means wait forever, which [method SceneTree.create_timer] answers by
## never firing at all); below [constant MIN_RESPONSE_TIMEOUT_SECONDS] it is not. Zero,
## negative and NaN all land in the bottom branch and all mean the same thing to the engine
## — the timer fires on the very next frame — so the caller is handed a timeout before the
## server could answer, which reads as "the server did not answer" for a server that did.
## [code]0[/code] is the shape worth naming: [HTTPRequest] reads it as "no timeout", so it
## is the value a caller reaches for meaning the opposite of what it does here.
static func resolve_wait_timeout(timeout_seconds: float, fallback: float, setting: String) -> float:
	if timeout_seconds > MAX_RESPONSE_TIMEOUT_SECONDS:
		push_error(
			(
				"SpacetimeDBClient: %s = %s is above the %.0f-second maximum (INF lands here "
				+ "too, and an infinite wait never times out at all); using %.0f instead."
			)
			% [setting, timeout_seconds, MAX_RESPONSE_TIMEOUT_SECONDS, MAX_RESPONSE_TIMEOUT_SECONDS]
		)
		return MAX_RESPONSE_TIMEOUT_SECONDS
	if timeout_seconds >= MIN_RESPONSE_TIMEOUT_SECONDS:
		return timeout_seconds
	push_error(
		(
			"SpacetimeDBClient: %s = %s is not a deadline that can be waited out — under the "
			+ "%.2f-second minimum the wait ends on the next frame, before any answer could "
			+ "arrive, and zero, negative and NaN all do the same; using %s instead."
		)
		% [setting, timeout_seconds, MIN_RESPONSE_TIMEOUT_SECONDS, fallback]
	)
	return fallback


## [param trailing_args_to_drop] is the number of signal arguments past
## (request_id, payload) that the internal handler does not take — 1 for
## [signal one_off_query_received], which also carries an error message. Without
## it the connect arity mismatches, the handler is never invoked, and the caller
## waits out the full timeout and receives null.
func _wait_for_response(
	request_id: int,
	cache: Dictionary,
	sig: Signal,
	timeout_seconds: float,
	trailing_args_to_drop: int = 0,
) -> Variant:
	# Resolved here rather than at each public entry point: this is the one place the
	# caller's float reaches the engine, so a deadline that cannot be waited out is named
	# once no matter which waiter was called. Before the cache check, not after, or a
	# caller that always passes a refused deadline would be told about it or not depending
	# on whether the response happened to have landed already.
	var deadline: float = resolve_wait_timeout(
		timeout_seconds,
		DEFAULT_RESPONSE_TIMEOUT_SECONDS,
		"timeout_seconds",
	)
	if cache.has(request_id):
		var cached: Variant = cache[request_id]
		cache.erase(request_id)
		print_log("SpacetimeDBClient: Cache hit for Req ID: %d" % request_id)
		return cached
	# Wall clock (ignore_time_scale): a response timeout measures the server, and a game
	# frozen with Engine.time_scale = 0 would otherwise leave this await suspended for
	# the whole freeze — indefinitely, for a pause menu that holds the scale at zero.
	var timer: SceneTreeTimer = get_tree().create_timer(deadline, true, false, true)
	var result_container: Array = [null]
	# done lives in a container because GDScript lambdas capture local primitives
	# by value (godot#69014); a bare `var done` would never reflect the mutation.
	var done_ref: Array[bool] = [false]
	var connection: Callable = func(rid: int, data: Variant) -> void:
		if rid == request_id and not done_ref[0]:
			done_ref[0] = true
			result_container[0] = data
			cache.erase(rid)
			timer.time_left = 0
	# Wakes the wait early when the connection drops; leaves result null so the caller
	# gets the same empty/null it would on timeout, but without the full delay.
	var abort: Callable = func() -> void:
		if not done_ref[0]:
			done_ref[0] = true
			timer.time_left = 0
	var handler: Callable = (
		connection if trailing_args_to_drop == 0 else connection.unbind(trailing_args_to_drop)
	)
	sig.connect(handler)
	_response_wait_aborted.connect(abort)
	await timer.timeout
	# The client may have been freed during the wait (disconnect + queue_free).
	# Touching self's signals/dicts after that crashes (engine bug #72629).
	if not is_instance_valid(self):
		return null
	sig.disconnect(handler)
	_response_wait_aborted.disconnect(abort)
	if result_container[0] == null:
		if not done_ref[0]:
			printerr("SpacetimeDBClient: Timeout waiting for response for Req ID: %d" % request_id)
		return null
	print_log("SpacetimeDBClient: Received matching response for Req ID: %d" % request_id)
	return result_container[0]


func _init_db(_local_db: LocalDatabase) -> void:
	pass


# --- LocalDatabase signal forwarders (re-emit as the client's own signals) ---
func _forward_row_inserted(tn: StringName, r: _ModuleTableType) -> void:
	row_inserted.emit(tn, r)


func _forward_row_updated(tn: StringName, p: _ModuleTableType, r: _ModuleTableType) -> void:
	row_updated.emit(tn, p, r)


func _forward_row_before_delete(tn: StringName, r: _ModuleTableType) -> void:
	row_before_delete.emit(tn, r)


func _forward_row_deleted(tn: StringName, r: _ModuleTableType) -> void:
	row_deleted.emit(tn, r)


func _forward_row_transactions_completed(tn: StringName) -> void:
	row_transactions_completed.emit(tn)


func _load_token_or_request() -> void:
	if _token:
		# If token is already set, use it
		_on_token_received(_token)
		return

	if one_time_token == false:
		# Try loading saved token
		if FileAccess.file_exists(token_save_path):
			var file: FileAccess = FileAccess.open(token_save_path, FileAccess.READ)
			if file:
				var saved_token: String = token_store_read(file.get_as_text(), module_name)
				file.close()
				if not saved_token.is_empty():
					print_log("SpacetimeDBClient: Using saved token.")
					_on_token_received(saved_token) # Directly use the saved token
					return

	# If no valid saved token, request a new one if auto-request is enabled
	if auto_request_token:
		print_log("SpacetimeDBClient: No valid saved token found, requesting new one.")
		_rest_api.request_new_token()
	else:
		printerr("SpacetimeDBClient: No token available and auto_request_token is false.")
		_report_connection_error(-1, "Authentication token unavailable")


## Reports a connection failure that was decided WITHOUT touching the network, deferred
## by one frame.
##
## Everything else that ends a connection attempt — DNS, the socket, the identity
## request — reports from a later frame by construction. These three do not: a token
## refused because it carries a control character (from the options, or read back from
## token_save_path) is decided inside connect_db, so emitting inline reached only the
## listeners that were already wired. That is the opposite order from the one every
## caller writes, and it is the order the Blackholio example shipped with — connect
## first, wire the handlers on the next lines — which lost the report entirely and left
## the game waiting on a connection the SDK had already given up on. Deferring makes the
## signal arrive the same way in every case, so wiring order stops mattering.
##
## A caller that frees the client in the same frame never sees it: the deferred call is
## dropped when its object is gone, which is the correct outcome.
func _report_connection_error(code: int, reason: String) -> void:
	_emit_connection_error_deferred.call_deferred(code, reason, _session_intent)


## Emits the deferred report unless the session it belongs to is gone. connect_db and
## disconnect_db both bump _session_intent, so a caller that immediately retries or tears
## the attempt down does not get a frame-late error about the attempt it already
## abandoned — the same supersede rule connect_db applies to its own cache wipe.
func _emit_connection_error_deferred(code: int, reason: String, intent: int) -> void:
	if intent != _session_intent:
		print_log("SpacetimeDBClient: dropping a connection error from a superseded session.")
		return
	connection_error.emit(code, reason)


func _generate_connection_id() -> String:
	var random_bytes: PackedByteArray = []
	random_bytes.resize(16)
	for i: int in 16:
		random_bytes[i] = _rng.randi_range(0, 255)
	return random_bytes.hex_encode() # Return as hex string


func _on_token_received(received_token: String) -> void:
	# Every token this client connects with funnels through here — one set in the
	# options, one read back from token_save_path, and one issued by the REST identity
	# endpoint — and none of the three is necessarily the game's own text. A token
	# carrying a CR or LF would split the `Authorization: Bearer ...` handshake header
	# and turn whatever follows into further request headers, so it is refused here,
	# before it can be stored, written to disk, or connected with.
	var reject_reason: String = SpacetimeDBConnection.token_reject_reason(received_token)
	if not reject_reason.is_empty():
		push_error("SpacetimeDBClient: refusing the auth token — %s." % reject_reason)
		_report_connection_error(ERR_UNAUTHORIZED, "Auth token rejected: %s" % reject_reason)
		return

	print_log("SpacetimeDBClient: Token acquired.")
	self._token = received_token
	if save_token:
		_save_token(received_token)
	var conn_id: String = _generate_connection_id()
	# Pass token to components that need it
	_connection.set_token(self._token)
	_rest_api.set_token(self._token) # REST API might also need it

	# Now attempt to connect WebSocket
	_connection.connect_to_database(base_url, database_name, conn_id)


func _on_token_request_failed(error_code: int, _response_body: String) -> void:
	printerr("SpacetimeDBClient: Failed to acquire token. Cannot connect.")
	connection_error.emit(error_code, "Failed to acquire authentication token")


func _save_token(token_to_save: String) -> void:
	var dir_path: String = token_save_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var err: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			printerr("SpacetimeDBClient: Failed to create directory for token: ", dir_path)
			return
	# Read-modify-write: every client in the process shares this path by default, so a
	# plain overwrite would drop whichever module wrote last time. Both clients run on
	# the main thread and FileAccess is synchronous, so two saves in one frame are
	# sequential — the second one reads what the first just wrote.
	var existing: String = ""
	if FileAccess.file_exists(token_save_path):
		var read_file: FileAccess = FileAccess.open(token_save_path, FileAccess.READ)
		if read_file == null:
			# The file is there and this process cannot read it (permissions, too many
			# open handles). Carrying on would rebuild the store out of nothing and put
			# it over entries that are merely unreadable HERE — every other module's
			# identity, lost to a transient. Refuse the save instead.
			printerr(
				"SpacetimeDBClient: the token file exists but could not be read (%s): %s. "
				% [token_save_path, error_string(FileAccess.get_open_error())]
				+ "Not saving, so the tokens already in it are left alone."
			)
			return
		existing = read_file.get_as_text()
		read_file.close()
	# Nothing to write when this module already resolves to this token — the common case
	# on a reconnect, where the token came out of this very file. One file now carries
	# every module's credential, so the cheapest way not to damage it is not to rewrite
	# it. (Resolves through the pre-store fallback too: a module still living off that
	# entry keeps doing so rather than minting a duplicate under its own name.)
	if _token_store_read(existing, module_name, false) == token_to_save:
		return
	var contents: String = token_store_write(existing, module_name, token_to_save)
	if contents == existing:
		return # nothing to change (a refused write hands the store back as it was)
	# Written to a sibling and renamed over the real path, so a crash between truncating
	# the file and filling it cannot leave an empty or half-written one — which, now that
	# one file carries every module's token, would cost all of them at once instead of
	# one. The rename is atomic on POSIX; on Windows Godot's DirAccess implements it as
	# delete-then-move, which leaves a much narrower window than writing in place but not
	# no window. The sibling name carries the process AND this client's instance id: two
	# copies of the same game share one user:// directory, and a fixed name would let
	# them truncate each other's half-written file and then rename the result into place.
	# The instance id is what covers Web, where OS.get_process_id() is a hardcoded 0 and
	# two browser tabs are the easiest way to get two instances over one user:// — though
	# there each tab syncs its own filesystem overlay to IndexedDB wholesale, so a
	# cross-tab save race is last-writer-wins whatever this file does.
	var tmp_path: String = (
		"%s.%d.%d.tmp" % [token_save_path, OS.get_process_id(), get_instance_id()]
	)
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file != null:
		# store_string reports a short write (a full disk, a quota). Renaming after one
		# would install a truncated store over the intact one — the failure this whole
		# dance exists to prevent — so the sibling is removed and the save refused.
		var stored: bool = file.store_string(contents)
		file.close()
		if not stored:
			DirAccess.remove_absolute(tmp_path)
			printerr(
				"SpacetimeDBClient: could not write the token file (%s) — it is unchanged."
				% token_save_path
			)
			return
		var rename_err: Error = DirAccess.rename_absolute(tmp_path, token_save_path)
		if rename_err == OK:
			return
		# Nothing reads the sibling, and it holds every module's token.
		DirAccess.remove_absolute(tmp_path)
		printerr(
			"SpacetimeDBClient: could not move the token file into place (%s): %s"
			% [token_save_path, error_string(rename_err)]
		)
	# The path above is the one that should run. Writing in place is the fallback for a
	# filesystem where the sibling or the rename is refused (an exported platform whose
	# user:// is not a real directory), so persistence keeps working there — at the cost
	# of the guarantee above, which is why it is not the first choice.
	var direct: FileAccess = FileAccess.open(token_save_path, FileAccess.WRITE)
	if direct == null:
		printerr("SpacetimeDBClient: Failed to save token to path: ", token_save_path)
		return
	if not direct.store_string(contents):
		printerr(
			"SpacetimeDBClient: the token file (%s) was written short and may be damaged."
			% token_save_path
		)
	direct.close()


## This module's token out of the persisted store's [param text], or [code]""[/code].
##
## The store is a JSON object keyed by [member module_name], because
## [member token_save_path] has one default and a project may run a client per module —
## an unkeyed file let two clients overwrite each other, so the identity a module
## reconnected with was whichever client saved last (measured: two modules issued two
## identities on the first run and both came back as one of them on the second, with
## every row the other identity owned then invisible and nothing reporting it).
##
## Three shapes of [param text], deliberately distinguished:
## [br]- a JSON object: the store. This module's entry, else the pre-store token kept
## under [constant TOKEN_STORE_LEGACY_KEY], else [code]""[/code].
## [br]- anything else that is not empty: the pre-store format, one bare token, returned
## to whichever module asks so an existing installation keeps its identity across the
## upgrade instead of silently starting a new one.
## [br]- text that opens like an object but does not parse: a corrupt store. Reported and
## answered [code]""[/code], so the client asks for a fresh token rather than sending the
## file's bytes as a bearer credential — which is what folding this case into "pre-store"
## did.
static func token_store_read(text: String, p_module_name: String) -> String:
	return _token_store_read(text, p_module_name, true)


## [method token_store_read] with the corrupt-store report under the caller's control.
## The save path resolves the same text a moment after the load path did, and a corrupt
## store reported from both is two messages per connect for one file.
static func _token_store_read(text: String, p_module_name: String, report: bool) -> String:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return ""
	# Only a "{...}" file can be the store. Parsing everything else would push a JSON
	# error for every pre-store file read — a bare token is not JSON and never was.
	if not trimmed.begins_with("{"):
		return trimmed
	var parsed: Variant = _token_store_parse(trimmed, report)
	if parsed == null:
		return ""
	var stored: Variant = parsed.get(p_module_name)
	if stored is String:
		return stored
	# No entry of this module's own: fall back to a pre-store token carried over by an
	# earlier save. Every module read that one bare token before the store existed, so
	# every module's rows live under it — handing it to each module until each has its
	# own entry is what keeps those rows reachable after the upgrade.
	var legacy: Variant = parsed.get(TOKEN_STORE_LEGACY_KEY)
	if legacy is String:
		return legacy
	return ""


## The persisted store's [param text] with [param p_module_name]'s entry set to
## [param token]. Entries for other modules are carried over; anything that is not a
## string value is dropped.
##
## Pre-store text (a bare token, owned by no module) is preserved under
## [constant TOKEN_STORE_LEGACY_KEY] rather than discarded: the module that writes first
## is not necessarily the only one that was using it, and a module that has not connected
## yet still needs it to find its rows. A corrupt store cannot be merged into — its
## entries are already unreadable — so it is replaced, having been reported on the read.
##
## A refused write returns [param text] unchanged, so a caller must compare before
## writing rather than treat the result as always-new.
static func token_store_write(text: String, p_module_name: String, token: String) -> String:
	# The reserved key is only unclaimable because module names are identifiers, and
	# module_name is a plain String nothing validates. A client that set it to the
	# reserved key would turn its own token into the one handed to every module without
	# an entry — the leak the key exists to bound — so the write is refused and the store
	# comes back as it was.
	if p_module_name == TOKEN_STORE_LEGACY_KEY:
		push_error(
			"SpacetimeDBClient: module_name '%s' is reserved by the token store; "
			% TOKEN_STORE_LEGACY_KEY
			+ "this client's token was not saved."
		)
		return text
	var store: Dictionary[String, String] = { }
	var trimmed: String = text.strip_edges()
	if not trimmed.is_empty():
		if not trimmed.begins_with("{"):
			store[TOKEN_STORE_LEGACY_KEY] = trimmed
		else:
			# Same guard as token_store_read: no parse attempt on an absent file. Quiet
			# on a corrupt store — the read that preceded this write already reported it,
			# and a client that never reads (one_time_token) is overwriting it anyway.
			var parsed: Variant = _token_store_parse(trimmed, false)
			if parsed != null:
				for key: String in parsed:
					var value: Variant = parsed[key]
					if value is String:
						store[key] = value
	store[p_module_name] = token
	return JSON.stringify(store)


## The token store's [param text] as a [Dictionary], or [code]null[/code] when it opens
## like a JSON object and does not parse — a torn or truncated file. Uses [JSON]'s
## instance parse rather than [method JSON.parse_string], which pushes an engine error
## naming neither the file nor the SDK; [param report] turns that into one message the
## reader can act on.
static func _token_store_parse(text: String, report: bool) -> Variant:
	var json: JSON = JSON.new()
	var err: Error = json.parse(text)
	if err == OK and json.data is Dictionary:
		return json.data
	if report:
		push_error(
			(
				"SpacetimeDBClient: the saved token store is corrupt (%s) and is being "
				+ "ignored; a fresh token will be requested."
			)
			% json.get_error_message()
		)
	return null


## Allocates the deserializer thread + sync primitives when threading is enabled.
## Idempotent: safe to call from both connect_db() and initialize_and_connect().
func _setup_threading() -> void:
	if deserializer_worker != null:
		return
	if use_threading and not OS.has_feature("threads"):
		push_error("Threads are not supported on this build. Threading has been disabled.")
		use_threading = false
	if not use_threading:
		return
	# Reused, not replaced, because this also runs on a re-entry into the tree: the
	# packet queue can already hold bytes that arrived before the previous worker was
	# joined, and a fresh mutex would leave them behind a lock nothing else takes.
	if _packet_mutex == null:
		_packet_mutex = Mutex.new()
	if _packet_semaphore == null:
		_packet_semaphore = Semaphore.new()
	if _result_mutex == null:
		_result_mutex = Mutex.new()
	deserializer_worker = Thread.new()
	deserializer_worker.start(_thread_loop)
	# Those queued bytes have no post waiting for them — the one that was pending was
	# consumed by the worker on its way out — so the new worker would sit on the
	# semaphore until the next packet happened to arrive. (The reverse trade is that a
	# reused semaphore can carry counts the previous worker never spent, so a new one
	# may take a few empty wakes; the loop handles an empty queue by looping, and losing
	# queued bytes would be the worse half of the trade.)
	_packet_mutex.lock()
	var has_pending: bool = not _packet_queue.is_empty()
	_packet_mutex.unlock()
	if has_pending:
		_packet_semaphore.post()


func _on_websocket_message_received(raw_bytes: PackedByteArray) -> void:
	if not _is_initialized:
		return
	if use_threading:
		_packet_mutex.lock()
		_packet_queue.append(raw_bytes)
		_packet_mutex.unlock()
		_packet_semaphore.post()
	else:
		_result_queue.append_array(_parse_packet_and_get_resource(_decompress_and_parse(raw_bytes)))


func _thread_loop() -> void:
	var last_epoch: int = 0
	while not _thread_should_exit:
		_packet_semaphore.wait()
		if _thread_should_exit:
			break

		# Drain all pending packets in one lock acquisition
		_packet_mutex.lock()
		if _packet_queue.is_empty():
			_packet_mutex.unlock()
			continue
		var local_packets: Array[PackedByteArray] = []
		local_packets.assign(_packet_queue)
		_packet_queue.clear()
		var batch_epoch: int = _session_epoch
		_packet_mutex.unlock()

		# Fresh session (reconnect bumped the epoch): clear the parse state the prior
		# session left. No bytes are carried between packets — the parser drops a short
		# packet where it reads it — and the parse loop clears the error at every
		# message, so this is belt and braces rather than the load-bearing step it was
		# when a partial message was retained across packets.
		# _deserializer is worker-thread-only, so this needs no lock.
		if batch_epoch != last_epoch:
			_deserializer.reset_stream_state()
			last_epoch = batch_epoch

		# Parse all packets without holding any lock
		var local_results: Array[SpacetimeDBServerMessage] = []
		for packet: PackedByteArray in local_packets:
			var payload: PackedByteArray = _decompress_and_parse(packet)
			local_results.append_array(_parse_packet_and_get_resource(payload))

		# Flush parsed results in one lock acquisition — but only if a reconnect
		# hasn't bumped the session epoch while we were parsing, otherwise these
		# results belong to a dead session and must not touch the fresh database.
		if not local_results.is_empty():
			_packet_mutex.lock()
			var still_current: bool = batch_epoch == _session_epoch
			_packet_mutex.unlock()
			if still_current:
				_result_mutex.lock()
				_result_queue.append_array(local_results)
				_result_mutex.unlock()
			else:
				print_log(
					"SpacetimeDBClient: discarded %d stale results from a prior session."
					% local_results.size()
				)


func _process_results_asynchronously() -> void:
	if use_threading and not _result_mutex:
		return

	# Refill the held batch only when the previous one is fully drained. While a
	# batch is in flight (cursor < size) no lock is taken at all — newly parsed
	# messages stay in _result_queue and are picked up in arrival order once the
	# batch finishes, so a multi-frame backlog drains via an advancing cursor,
	# never re-sliced (O(1)/frame vs O(remaining) copy/frame).
	if _drain_cursor >= _drain_batch.size():
		if use_threading:
			_result_mutex.lock()
		if _result_queue.is_empty():
			if use_threading:
				_result_mutex.unlock()
			return
		# COW handoff under the lock the parser appends under: _drain_batch takes
		# the queued messages, _result_queue is reset for the parser to fill anew.
		_drain_batch = _result_queue
		_result_queue = []
		if use_threading:
			_result_mutex.unlock()
		_drain_cursor = 0

	var remaining: int = _drain_batch.size() - _drain_cursor

	# Adapt the budget from this frame's backlog + current fps before draining.
	_auto_tune_budget(remaining)

	# Drain under a per-frame time budget, bounded by a hard message ceiling.
	# Stop rule is pure (_should_stop_drain) and checked with elapsed measured
	# AFTER each handle, so at least one message always makes progress even if a
	# single message exceeds the whole budget.
	var start_us: int = Time.get_ticks_usec()
	var processed: int = 0
	# The cursor bound is not redundant with `remaining`: _handle_parsed_message runs
	# game code, and a listener that ends the session (disconnect_db from a row
	# callback, say) drops the dead session's traffic — including this very batch —
	# out from under the loop. Without this check the next iteration indexes an
	# emptied array and the frame dies on an out-of-bounds read.
	while (
		_drain_cursor < _drain_batch.size()
		and not _should_stop_drain(
			processed,
			remaining,
			_max_msgs_per_frame,
			Time.get_ticks_usec() - start_us,
			_frame_budget_us,
		)
	):
		_handle_parsed_message(_drain_batch[_drain_cursor])
		_drain_cursor += 1
		processed += 1

	# Release the batch once fully drained so its memory frees and the next frame
	# refills from the queue. Partially-drained batches persist with their cursor.
	if _drain_cursor >= _drain_batch.size():
		_drain_batch = []
		_drain_cursor = 0


## AIMD feedback loop for [member _frame_budget_us]. Drain runs on the main
## thread, so an oversized budget steals frame time and drops fps. While a
## backlog exists and fps is healthy, additively grow the budget; the moment
## fps dips below target, multiplicatively back off. Clamped to the configured
## min/max. [param pending] is this frame's pre-drain backlog size.
func _auto_tune_budget(pending: int) -> void:
	if not _auto_tune_budget_enabled:
		return
	var fps: float = Engine.get_frames_per_second()
	var target_fps: int = resolve_target_fps(
		_auto_tune_target_fps,
		Engine.max_fps,
		Engine.physics_ticks_per_second,
		fps,
	)
	_frame_budget_us = _compute_tuned_budget(
		_frame_budget_us,
		fps,
		target_fps,
		pending,
		_frame_budget_min_us,
		_frame_budget_max_us,
	)


## The frame rate the tuner defends, from the configured target, the engine's frame
## cap, and the physics tick rate. Pure, so the resolution is testable without an
## engine.
##
## The signal the tuner reads is [method Engine.get_frames_per_second] — the RENDERED
## frame rate — so the target has to be a rendered rate too. It used to fall back to
## the physics tick rate, which is a different loop: a game that caps itself at 30 fps
## while physics runs at the default 60 read as permanently below target, so the budget
## collapsed to its floor and stayed there (measured: 4000us to the 1000us floor within
## twelve ticks) even though nothing was struggling. A cap is the rate the game asked
## for, so it is the rate to defend.
##
## The physics rate remains the last resort, which keeps the old behaviour for an
## uncapped game — there, a render rate below the physics rate really is the frame loop
## falling behind, and handing time back to it is the point of the controller. A game
## capped by vsync rather than [member Engine.max_fps] should set
## [member SpacetimeDBConnectionOptions.auto_tune_target_fps] explicitly.
##
## Note the remaining blind spot, which no target can fix: a cap far below the physics
## rate (a 10 fps battery-saver mode) means the rendered rate no longer answers "is the
## drain costing too much" — the engine sleeps out the difference, so the budget ramps
## to [member SpacetimeDBConnectionOptions.frame_budget_max_us] and spends that every
## physics tick regardless. A game that caps that low to save power should lower
## [member SpacetimeDBConnectionOptions.frame_budget_max_us] or turn
## [member SpacetimeDBConnectionOptions.auto_tune_frame_budget] off.
static func resolve_target_fps(configured: int, max_fps: int, physics_tps: int, measured_fps: float) -> int:
	if configured > 0:
		return configured
	# The cap counts as the target only once the game is actually reaching it. A cap is
	# what the game PERMITS, not what it achieves, and capping above what the hardware
	# delivers is a common idiom ("cap at the refresh rate, we will never hit it") — so
	# adopting an unreached cap would compare 60 against 240 and pin the budget at the
	# floor, which is the very failure this resolution exists to remove, mirrored. Cold
	# start reads 0 fps and falls through; the controller holds on a 0 reading anyway,
	# so the first real frame arms the target a tick later.
	if max_fps > 0 and measured_fps >= max_fps * 0.9:
		return max_fps
	return physics_tps


## Pure AIMD step — returns the next budget for the given state, so the controller
## is unit-testable without engine fps. [param fps]<=0 (cold start) or
## [param target_fps]<=0 → unchanged. fps below 95% of target → ×0.8 (back off);
## fps at/above 99% of target with pending work → +500us (ramp). Result clamped
## to [param min_us]/[param max_us]. The 95–99% gap is intentional hysteresis.
static func _compute_tuned_budget(
	current: int,
	fps: float,
	target_fps: int,
	pending: int,
	min_us: int,
	max_us: int,
) -> int:
	if target_fps <= 0 or fps <= 0.0:
		return current
	if fps < target_fps * 0.95:
		return maxi(min_us, int(current * 0.8))
	if pending > 0 and fps >= target_fps * 0.99:
		return mini(max_us, current + 500)
	return current


## Pure resolve+clamp of the per-frame drain limits from raw option values, so
## the clamping is unit-testable without a live connection. Returns a
## [PackedInt32Array] [code][max_msgs, min_us, max_us, budget_us, target_fps][/code].
## [param max_msgs] clamped to [1, 8192] — floor 1 keeps the loop progressing,
## ceiling keeps the hard ceiling a real bounded-loop backstop even if
## misconfigured huge. [param min_us] floored at 100: a 0 budget makes the drain
## time-check true after the first message, capping drain at 1/frame and starving
## the backlog (reviewer MEDIUM). [param max_us] floored at the resolved min so the
## clamp range is never inverted. [param budget_us] clamped into the resolved
## [min, max]. [param target_fps] floored at 0 (0 = use physics tick rate).
static func _resolve_drain_config(
	max_msgs: int,
	min_us: int,
	max_us: int,
	budget_us: int,
	target_fps: int,
) -> PackedInt32Array:
	var r_min: int = maxi(100, min_us)
	var r_max: int = maxi(r_min, max_us)
	var r_budget: int = clampi(maxi(0, budget_us), r_min, r_max)
	return PackedInt32Array(
		[clampi(max_msgs, 1, 8192), r_min, r_max, r_budget, maxi(0, target_fps)],
	)


## Resolves [param options]' reconnect pacing into the members the cycle is driven from.
##
## Two callers, two roles. [method _start_reconnection] is the AUTHORITATIVE one — it
## resolves at the top of every cycle, so the values the cycle runs on are read from the
## options object as it stands at the drop, and a field mutated after the object was handed
## over is honoured. The [member connection_options] setter is the DIAGNOSTIC one — it
## resolves on assignment so a knob the SDK cannot use is reported at the call that set it
## rather than only at a drop hours later.
##
## Both report. A configuration the SDK refuses is therefore named once when it is set and
## once per drop for as long as it stays that way, which is the intended trade: a wrong knob
## that keeps costing the cycle its pacing keeps saying so. Not once per ATTEMPT — the
## direct [method _schedule_next_reconnect_attempt] callers inside a live cycle do not
## re-resolve.
func _resolve_reconnect_pacing(options: SpacetimeDBConnectionOptions) -> void:
	if options == null:
		return
	_reconnect_initial_delay = _resolve_reconnect_delay(
		options.reconnect_initial_delay,
		DEFAULT_RECONNECT_INITIAL_DELAY,
		"reconnect_initial_delay",
	)
	# A cap BELOW the starting delay is left alone, unlike the min/max pair
	# [method _resolve_drain_config] squares up. Those two bound one quantity, so an
	# inverted pair there is an empty range; these two are different quantities — where the
	# backoff starts, and how long it may ever get — and a caller who writes a cap under the
	# starting delay has said something coherent ("never wait more than this"). Honouring it
	# costs nothing, because the floor below is what keeps even a tiny cap a real wait.
	_reconnect_max_delay = _resolve_reconnect_delay(
		options.reconnect_max_delay,
		DEFAULT_RECONNECT_MAX_DELAY,
		"reconnect_max_delay",
	)
	_reconnect_backoff_multiplier = _resolve_backoff_multiplier(
		options.reconnect_backoff_multiplier
	)
	_reconnect_jitter_fraction = _resolve_jitter_fraction(options.reconnect_jitter_fraction)
	_max_reconnect_attempts = _resolve_max_reconnect_attempts(options.max_reconnect_attempts)


## [param value] if it is a delay the reconnect cycle can be paced by, else a usable one.
##
## Clamped at the top, refused at the bottom, for the reason the socket limits split the
## same way ([method SpacetimeDBConnection.resolve_buffer_size]): above
## [constant MAX_RECONNECT_DELAY_SECONDS] the intent is unambiguous — a longer wait, and the
## ceiling is also what keeps the computed backoff finite — while below
## [constant MIN_RECONNECT_DELAY_SECONDS] it is not. A sub-frame delay is not a shorter
## wait: the backoff runs on a [SceneTreeTimer], so anything under a frame is no wait at all,
## and the cycle opens a connection per frame until the attempt budget runs out (with the
## documented [code]max_reconnect_attempts = 0[/code], never). Instant retry is not what this
## knob offers — that is the stall path, which sets [member _reconnect_immediate] once — so
## an unusable value falls back to the default rather than being read as a request for it.
##
## Negative and NaN land in the same branch, both deliberately: a negative delay computes a
## zero backoff, and NaN fails every comparison, which is exactly the value that makes
## [method SceneTree.create_timer] time out on the next frame.
static func _resolve_reconnect_delay(value: float, fallback: float, setting: String) -> float:
	if value > MAX_RECONNECT_DELAY_SECONDS:
		push_error(
			(
				"SpacetimeDBClient: %s = %s is above the %.0f-second maximum; using %.0f "
				+ "instead."
			)
			% [setting, value, MAX_RECONNECT_DELAY_SECONDS, MAX_RECONNECT_DELAY_SECONDS]
		)
		return MAX_RECONNECT_DELAY_SECONDS
	if value >= MIN_RECONNECT_DELAY_SECONDS:
		return value
	push_error(
		(
			"SpacetimeDBClient: %s = %s is not a usable reconnect delay — under the %.2f-second "
			+ "minimum the cycle retries every frame, and a negative or NaN one computes a zero "
			+ "backoff; using the default %s instead."
		)
		% [setting, value, MIN_RECONNECT_DELAY_SECONDS, fallback]
	)
	return fallback


## [param value] if it is a multiplier that escalates, else
## [constant DEFAULT_BACKOFF_MULTIPLIER].
##
## Below 1.0 the delay SHRINKS with each failed attempt, which is not a backoff: 0.0 pins
## every attempt after the first at zero, a negative one alternates between zero and a
## growing delay (the sign flips with the exponent), and a fraction converges on zero after
## a handful of attempts. All three end at the same per-frame storm the floor in
## [method _resolve_reconnect_delay] exists to prevent, so a multiplier that cannot
## escalate is refused rather than clamped. NaN fails both comparisons and lands here too.
static func _resolve_backoff_multiplier(value: float) -> float:
	if value > MAX_BACKOFF_MULTIPLIER:
		push_error(
			(
				"SpacetimeDBClient: reconnect_backoff_multiplier = %s is above the maximum "
				+ "%.0f; using %.0f instead."
			)
			% [value, MAX_BACKOFF_MULTIPLIER, MAX_BACKOFF_MULTIPLIER]
		)
		return MAX_BACKOFF_MULTIPLIER
	if value >= 1.0:
		return value
	push_error(
		(
			"SpacetimeDBClient: reconnect_backoff_multiplier = %s does not escalate (below "
			+ "1.0 the delay shrinks with every failed attempt, reaching a per-frame retry); "
			+ "using the default %s instead."
		)
		% [value, DEFAULT_BACKOFF_MULTIPLIER]
	)
	return DEFAULT_BACKOFF_MULTIPLIER


## [param value] clamped into the documented 0.0–1.0 jitter range.
##
## Both ends are clamped rather than refused because both have an unambiguous reading, and
## both are wrong in a way the caller cannot see: above 1.0 the random offset can exceed the
## delay it is subtracted from, so attempts land on zero at random; below 0.0 it is ADDED,
## so the backoff runs past [member SpacetimeDBConnectionOptions.reconnect_max_delay]
## (measured 32.4 s against a 30 s cap). NaN takes the same branch as a negative one and
## disables jitter, which is the only reading that leaves a usable delay — an unclamped NaN
## makes every backoff NaN, and a NaN wait fires on the next frame.
static func _resolve_jitter_fraction(value: float) -> float:
	if value > 1.0:
		push_error(
			(
				"SpacetimeDBClient: reconnect_jitter_fraction = %s is above 1.0, which lets "
				+ "the jitter cancel the whole delay; using 1.0 instead."
			)
			% value
		)
		return 1.0
	if value >= 0.0:
		return value
	push_error(
		(
			"SpacetimeDBClient: reconnect_jitter_fraction = %s is not in 0.0–1.0 (a negative "
			+ "fraction ADDS to the delay, past reconnect_max_delay); using 0.0 instead."
		)
		% value
	)
	return 0.0


## [param value] if it is a documented attempt budget, else
## [constant DEFAULT_MAX_RECONNECT_ATTEMPTS].
##
## Zero is legal and documented — it means retry forever — so only a negative value is
## refused. It reads as infinite too ([method _schedule_next_reconnect_attempt] gates
## exhaustion on [code]max_attempts > 0[/code]), but nothing says so, and a sign slip
## asking for an unbounded cycle is the one input where the bounded default is the safer
## reading of what was meant.
static func _resolve_max_reconnect_attempts(value: int) -> int:
	if value >= 0:
		return value
	push_error(
		(
			"SpacetimeDBClient: max_reconnect_attempts = %d is negative, which would retry "
			+ "forever (0 is the documented way to ask for that); using the default %d instead."
		)
		% [value, DEFAULT_MAX_RECONNECT_ATTEMPTS]
	)
	return DEFAULT_MAX_RECONNECT_ATTEMPTS


## Pure stop rule for the per-frame drain loop, so the bounded-loop + at-least-one
## progress guarantees are unit-testable without wall-clock time. Stop when the
## batch is exhausted, the hard message ceiling is reached, or the time budget is
## spent — but never before the first message ([param processed] == 0 always
## proceeds), so a single message costlier than the whole budget still makes
## progress. Checked with [param elapsed_us] measured AFTER each handle.
static func _should_stop_drain(
	processed: int,
	batch_size: int,
	max_msgs: int,
	elapsed_us: int,
	budget_us: int,
) -> bool:
	if processed >= batch_size:
		return true
	if processed == 0:
		return false
	if processed >= max_msgs:
		return true
	return elapsed_us >= budget_us


func _decompress_and_parse(raw_bytes: PackedByteArray) -> PackedByteArray:
	if raw_bytes.size() < 2:
		printerr(
			"SpacetimeDBClient: Received packet too small (%d bytes), ignoring." % raw_bytes.size()
		)
		return PackedByteArray()
	var compression: int = raw_bytes.get(0)
	var payload: PackedByteArray = raw_bytes.slice(1)
	if compression == 0:
		pass
	elif compression == 1:
		payload = DataDecompressor.decompress_brotli(payload)
		if payload.is_empty():
			printerr("SpacetimeDBClient: Brotli decompression failed, dropping frame.")
			return PackedByteArray()
	elif compression == 2:
		payload = DataDecompressor.decompress_packet(payload)
		if payload.is_empty():
			# Gzip failures used to come back as whatever had inflated before the
			# break; they return empty now, same as Brotli, so they get the same
			# one-line "this frame is gone" report rather than a silent no-op parse.
			# The cause is not asserted here: the decompressor already named it, and
			# some of these frames decompressed fine and were refused for what came
			# after the member.
			printerr("SpacetimeDBClient: Gzip frame refused by the decompressor, dropping it.")
			return PackedByteArray()
	else:
		printerr("SpacetimeDBClient: Unknown compression tag %d, dropping frame." % compression)
		return PackedByteArray()
	return payload


func _parse_packet_and_get_resource(bsatn_bytes: PackedByteArray) -> Array[SpacetimeDBServerMessage]:
	if not _deserializer:
		return []

	var result: Array[SpacetimeDBServerMessage] = _deserializer.process_bytes_and_extract_messages(
		bsatn_bytes
	)

	if _deserializer.has_error():
		printerr(
			"SpacetimeDBClient: Failed to parse BSATN packet: ",
			_deserializer.get_last_error(),
		)
	# Whatever parsed is still delivered. A packet carries several complete server
	# messages and the failure is at one of them: the ones read before it are whole,
	# ordered, and indistinguishable from the same messages arriving in their own
	# packet. Dropping them would discard uncorrupted transaction updates on top of
	# the ones the error already cost.
	return result


func _handle_parsed_message(message: SpacetimeDBServerMessage) -> void:
	if message == null:
		printerr("SpacetimeDBClient: Parser returned null message.")
		return

	# Handle known message types. Arms ordered hottest-first: TransactionUpdate +
	# ReducerResult are the steady-state firehose, so they win the `is`-chain
	# without walking past one-shot setup arms (IdentityToken fires once per
	# session). Arms are type-disjoint — order is behavior-neutral, perf-only.
	if message is TransactionUpdateMessage:
		_handle_transaction_update(message)
	elif message is ReducerResultMessage:
		var rid: int = message.request_id
		var outcome: ReducerOutcomeEnum = message.reducer_result
		var tx_update: TransactionUpdateMessage = null
		var handle: SpacetimeDBReducerCall = _pending_reducer_calls.get(rid)
		# Only stamp the handle if it's still PENDING (avoids overwriting a TIMEOUT verdict)
		var can_stamp: bool = handle and handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING
		var _outcome_value: int = outcome.value
		if _outcome_value == ReducerOutcomeEnum.Options.ok:
			tx_update = outcome.get_ok()
			if tx_update != null:
				_handle_transaction_update(tx_update)
			if can_stamp:
				handle.outcome = SpacetimeDBReducerCall.Outcome.OK
				handle.transaction_update = tx_update
				handle.ret_value = message.ret_value
		elif _outcome_value == ReducerOutcomeEnum.Options.okEmpty:
			if can_stamp:
				handle.outcome = SpacetimeDBReducerCall.Outcome.OK_EMPTY
		elif _outcome_value == ReducerOutcomeEnum.Options.err:
			var err_bytes: PackedByteArray = outcome.get_err()
			var err_msg: String = _decode_reducer_error(err_bytes)
			print_log("SpacetimeDBClient: Reducer returned error: %s" % err_msg)
			if can_stamp:
				handle.outcome = SpacetimeDBReducerCall.Outcome.ERROR
				handle.error_message = err_msg
		elif _outcome_value == ReducerOutcomeEnum.Options.internalError:
			var err_msg: String = outcome.get_internal_error()
			printerr("SpacetimeDBClient: Reducer internal error: ", err_msg)
			if can_stamp:
				handle.outcome = SpacetimeDBReducerCall.Outcome.INTERNAL_ERROR
				handle.error_message = err_msg
		else:
			push_error("SpacetimeDBClient: unknown status_tag %d" % outcome.value)
			if can_stamp:
				handle.outcome = SpacetimeDBReducerCall.Outcome.INTERNAL_ERROR
				handle.error_message = "unknown reducer outcome tag %d" % outcome.value
		_pending_reducer_calls.erase(rid)
		_stats.record_response(rid)
		_reducer_result_cache[rid] = tx_update
		_evict_oldest(_reducer_result_cache)
		reducer_result_received.emit(rid, tx_update)
	elif message is OneOffQueryResponseMessage:
		var rid: int = message.request_id
		_stats.record_response(rid)
		if message.is_error:
			printerr(
				"SpacetimeDBClient: OneOffQuery error (request_id=%d): %s"
				% [rid, message.error_message]
			)
			var no_tables: Array[TableUpdateData] = []
			_one_off_query_cache[rid] = no_tables
			_evict_oldest(_one_off_query_cache)
			one_off_query_received.emit(rid, no_tables, message.error_message)
		else:
			print_log(
				"SpacetimeDBClient: OneOffQuery result (request_id=%d): %d tables"
				% [rid, message.tables.size()]
			)
			_one_off_query_cache[rid] = message.tables
			_evict_oldest(_one_off_query_cache)
			one_off_query_received.emit(rid, message.tables, "")
	elif message is ProcedureResultData:
		var rid: int = message.request_id
		var handle: SpacetimeDBProcedureCall = _pending_procedure_calls.get(rid)
		var can_stamp: bool = handle and handle.outcome == SpacetimeDBProcedureCall.Outcome.PENDING
		var ret_bytes: PackedByteArray = PackedByteArray()

		var _status_tag: int = message.status_tag
		if _status_tag == 0: # Returned
			ret_bytes = message.return_bytes
			if can_stamp:
				handle.outcome = SpacetimeDBProcedureCall.Outcome.RETURNED
				handle.return_bytes = ret_bytes
		elif _status_tag == 1: # InternalError
			printerr("SpacetimeDBClient: Procedure internal error: ", message.error_message)
			if can_stamp:
				handle.outcome = SpacetimeDBProcedureCall.Outcome.INTERNAL_ERROR
				handle.error_message = message.error_message
		else:
			push_error("SpacetimeDBClient: unknown status_tag %d" % message.status_tag)
			if can_stamp:
				handle.outcome = SpacetimeDBProcedureCall.Outcome.INTERNAL_ERROR
				handle.error_message = "unknown procedure status_tag %d" % message.status_tag

		_pending_procedure_calls.erase(rid)
		_stats.record_response(rid)
		_procedure_result_cache[rid] = ret_bytes
		_evict_oldest(_procedure_result_cache)
		procedure_result_received.emit(rid, ret_bytes)

	# --- Cold arms: setup / one-shot / rare. Kept after the hot path above. ---
	elif message is SubscribeAppliedMessage:
		_stats.record_response(message.request_id)
		print_log(
			"SpacetimeDBClient: SubscribeApplied — tables: %d, query_set_id: %d"
			% [message.tables.size(), message.query_set_id.id]
		)
		for t: TableUpdateData in message.tables:
			print_log(
				"  Table: '%s' inserts=%d deletes=%d"
				% [t.table_name, t.inserts.size(), t.deletes.size()]
			)
		_local_db.apply_database_subscription_applied(message)
		if not _received_initial_subscription:
			_received_initial_subscription = true
			self.database_initialized.emit()
		var qid: int = message.query_set_id.id
		if pending_subscriptions.has(qid):
			var sub: SpacetimeDBSubscription = pending_subscriptions[qid]
			pending_subscriptions.erase(qid)
			current_subscriptions[qid] = sub
			sub.applied.emit()
	elif message is SubscriptionErrorMessage:
		printerr("SpacetimeDBClient: Subscription error: %s" % message.error_message)
		# The error IS the response to that subscribe — without this the send stayed
		# pending and its in_flight never came back down. The id is optional on this
		# message; when the server omits it the send is only released by the next
		# disconnect (or MAX_PENDING eviction).
		if message.has_request_id():
			_stats.record_response(message.request_id)
		if message.has_query_id():
			var qid: int = message.query_id.id
			# The error ends the subscription either way, so an unsubscribe still in
			# flight for it has nothing left to answer for.
			_unsubscribing_query_ids.erase(qid)
			if pending_subscriptions.has(qid):
				var sub: SpacetimeDBSubscription = pending_subscriptions[qid]
				pending_subscriptions.erase(qid)
				sub.error_message = message.error_message
				sub.end.emit()
			elif current_subscriptions.has(qid):
				var sub: SpacetimeDBSubscription = current_subscriptions[qid]
				current_subscriptions.erase(qid)
				sub.error_message = message.error_message
				sub.end.emit()
				# Already-applied subscription: prune exactly its rows. The server sends no
				# dropped rows on an error, so LocalDatabase reconstructs them from per-query
				# membership and decrements their refcounts — rows still held by another
				# subscription survive. No disconnect/rebuild needed, regardless of auto_reconnect.
				_local_db.prune_query(qid)
				print_log(
					"SpacetimeDBClient: SubscriptionError on applied query_id %d; pruned its rows."
					% qid
				)
	elif message is UnsubscribeAppliedMessage:
		var qid: int = message.query_id.id
		if not message.tables.is_empty():
			for table_update: TableUpdateData in message.tables:
				_local_db.apply_table_update(table_update, qid)
		_local_db.forget_query(qid)
		_unsubscribing_query_ids.erase(qid)
		# Also handle a query unsubscribed before its SubscribeApplied arrived: its
		# handle still sits in pending_subscriptions, and without this it would leak
		# there forever and its `end` would never fire.
		var sub: SpacetimeDBSubscription = null
		if current_subscriptions.has(qid):
			sub = current_subscriptions[qid]
			current_subscriptions.erase(qid)
		elif pending_subscriptions.has(qid):
			sub = pending_subscriptions[qid]
			pending_subscriptions.erase(qid)
		if sub:
			sub.end.emit()
		print_log("SpacetimeDBClient: Unsubscribe applied for query_id %d." % qid)
	elif message is IdentityTokenMessage:
		print_log("SpacetimeDBClient: Received Identity Token.")
		# Guard FIRST — a late IdentityToken from a socket the user already tore
		# down (disconnect_db mid-handshake) must be a full no-op. In particular it
		# must not restore _token, which disconnect_db deliberately wiped to force a
		# fresh token on the next connect. Legit reconnect is unaffected: STATE_OPEN
		# sets _is_connected before any packet is delivered, so is_connected_db() is
		# true by the time this token is processed.
		if _connection == null or not _connection.is_connected_db():
			print_log("SpacetimeDBClient: IdentityToken for a closed connection — ignoring.")
			return
		_identity = message.identity
		if not _token and message.token:
			# Checked like every other token source: this one is kept and spliced into
			# the handshake header of the NEXT reconnect, so a control character in it
			# would inject headers into a later request rather than this one.
			var token_reason: String = SpacetimeDBConnection.token_reject_reason(message.token)
			if token_reason.is_empty():
				_token = message.token
			else:
				# Reported, not just logged: this session keeps working on the socket the
				# server already accepted, but _token stays unset, so the reconnect that
				# needs it will bail. The game has to hear that now, while it can still
				# fetch a usable token, rather than at the first drop.
				push_error(
					"SpacetimeDBClient: refusing the token from the IdentityToken message — %s."
					% token_reason
				)
				connection_error.emit(
					ERR_UNAUTHORIZED,
					"IdentityToken rejected: %s (a later reconnect will have no token)"
					% token_reason,
				)
		_connection_id = message.connection_id
		self.connected.emit(_identity, _token)

		# Handle reconnection completion
		if _reconnect_state == _ReconnectState.RECONNECTING:
			print_log(
				"SpacetimeDBClient: Reconnected. Re-subscribing to %d query sets."
				% _saved_subscription_queries.size()
			)
			_reconnect_state = _ReconnectState.IDLE
			_reconnect_attempt = 0
			if _saved_subscription_queries.is_empty():
				reconnected.emit()
			else:
				_resubscribe_saved_queries()
	else:
		print_log("SpacetimeDBClient: Unhandled message type: " + message.get_class())


## Decodes the BSATN payload of a reducer `err` outcome into a readable message.
## The payload is a BSATN value of the reducer's declared error type; the common case
## (Result<_, String>) is a u32-length-prefixed UTF-8 string, so strip that prefix.
## Falls back to raw UTF-8, then a hex dump, for non-string / malformed payloads.
func _decode_reducer_error(err_bytes: PackedByteArray) -> String:
	if err_bytes.is_empty():
		return ""
	if err_bytes.size() >= 4:
		var n: int = err_bytes.decode_u32(0)
		if n == err_bytes.size() - 4:
			return err_bytes.slice(4).get_string_from_utf8()
	var raw: String = err_bytes.get_string_from_utf8()
	if not raw.is_empty():
		return raw
	return "raw error bytes: " + err_bytes.hex_encode()


func _handle_transaction_update(update_sets: TransactionUpdateMessage) -> void:
	for dataset: DatabaseUpdateData in update_sets.query_sets:
		_local_db.apply_database_update(dataset)
		if not _received_initial_subscription:
			_received_initial_subscription = true
			self.database_initialized.emit()
	# Emit the full transaction update signal regardless of status
	self.transaction_update_received.emit(update_sets)

# --- Reconnection ---


func _on_connection_disconnected() -> void:
	# Only unintentional closes reach here: disconnect_db() closes via
	# disconnect_from_server(), which clears the connection flags so the connection
	# layer stays silent (no signal to this handler). So there is no intentional
	# case to special-case.
	_response_wait_aborted.emit()
	# Stamp in-flight calls DISCONNECTED now (not later in _prepare_for_reconnect,
	# after the backoff) so an awaiter that resumes next frame gets DISCONNECTED
	# instead of self-stamping TIMEOUT. The request ids won't survive the reconnect.
	_fail_pending_calls_disconnected()

	# A graceful server close (normal WS code) that lands during a reconnect
	# attempt routes here, not through _on_connection_error (which only fires on
	# code -1). Without this branch _start_reconnection() early-returns on the
	# RECONNECTING state and the machine wedges — no timer, no reconnect_failed.
	# Mirror _on_connection_error / _on_connection_stalled: advance the attempt.
	if _reconnect_state == _ReconnectState.RECONNECTING:
		print_log(
			"SpacetimeDBClient: Reconnect attempt %d closed by server, scheduling next."
			% _reconnect_attempt
		)
		_schedule_next_reconnect_attempt()
	elif connection_options and connection_options.auto_reconnect:
		print_log("SpacetimeDBClient: Unintentional disconnect, starting auto-reconnect.")
		_start_reconnection()
	else:
		_emit_disconnected()


func _on_connection_error(code: int, reason: String) -> void:
	_response_wait_aborted.emit()
	_fail_pending_calls_disconnected() # awaiters get DISCONNECTED, not a late TIMEOUT
	if _reconnect_state == _ReconnectState.RECONNECTING:
		print_log(
			"SpacetimeDBClient: Reconnect attempt %d failed: %s (code %d)"
			% [_reconnect_attempt, reason, code]
		)
		_schedule_next_reconnect_attempt()
	elif connection_options and connection_options.auto_reconnect:
		print_log(
			"SpacetimeDBClient: Connection error, starting auto-reconnect. Reason: %s" % reason
		)
		connection_error.emit(code, reason)
		_start_reconnection()
	else:
		connection_error.emit(code, reason)


## Handles a stall-induced abnormal close. The socket really did close, but the
## cause was a local main-thread freeze (the engine heartbeat missed a pong while
## the thread was stalled), not a network fault — so reconnect immediately without
## the escalating backoff a genuine drop would warrant.
func _on_connection_stalled(code: int) -> void:
	_response_wait_aborted.emit()
	_fail_pending_calls_disconnected() # awaiters get DISCONNECTED, not a late TIMEOUT
	if _reconnect_state == _ReconnectState.RECONNECTING:
		_reconnect_immediate = true # a stall during reconnect keeps the fast path
		_schedule_next_reconnect_attempt()
	elif connection_options and connection_options.auto_reconnect:
		print_log(
			"SpacetimeDBClient: stall-induced close (code %d) — fast reconnect, no backoff." % code
		)
		_start_reconnection(true)
	else:
		connection_error.emit(code, "Abnormal closure (stall)")


func _start_reconnection(immediate: bool = false) -> void:
	if _reconnect_state == _ReconnectState.RECONNECTING:
		return

	# Re-resolved per cycle, not only when the options object was assigned. Two of the
	# knobs on that object are read LIVE every time the cycle consults them
	# (auto_reconnect just above, reconnect_on_app_resume in _on_app_resumed), so a
	# snapshot taken at assignment made "assign the options, then set a field on them" —
	# an idiom this repo's own tests use — silently run the cycle on the defaults while
	# honouring the fields still read live. Once per drop, not once per attempt, so a
	# refused knob is reported at a bounded rate.
	_resolve_reconnect_pacing(connection_options)

	_reconnect_state = _ReconnectState.RECONNECTING
	_reconnect_attempt = 0
	_reconnect_immediate = immediate
	# Supersede any in-flight resubscribe cycle so its late settles bail (see _resubscribe_epoch).
	_resubscribe_epoch += 1

	# Only rebuild the saved set when it's empty. A re-drop that lands mid-resubscribe
	# must keep the queries from the interrupted cycle — at that moment they sit in
	# pending_subscriptions (not yet applied), so rebuilding from current_subscriptions
	# alone would lose them.
	# A query whose Unsubscribe was still in flight when the socket died is NOT saved:
	# the caller already dropped it, and the server having never answered is not consent
	# to bring it back. See _unsubscribing_query_ids.
	if _saved_subscription_queries.is_empty():
		for sub_id: int in current_subscriptions:
			var sub: SpacetimeDBSubscription = current_subscriptions[sub_id]
			if not sub.queries.is_empty() and not _unsubscribing_query_ids.has(sub_id):
				_saved_subscription_queries.append(sub.queries.duplicate())
		for sub_id: int in pending_subscriptions:
			var sub: SpacetimeDBSubscription = pending_subscriptions[sub_id]
			if not sub.queries.is_empty() and not _unsubscribing_query_ids.has(sub_id):
				_saved_subscription_queries.append(sub.queries.duplicate())
	print_log(
		"SpacetimeDBClient: Saved %d subscription query sets for re-subscription."
		% _saved_subscription_queries.size()
	)

	_schedule_next_reconnect_attempt()


func _schedule_next_reconnect_attempt() -> void:
	var max_attempts: int = _max_reconnect_attempts

	if max_attempts > 0 and _reconnect_attempt >= max_attempts:
		print_log("SpacetimeDBClient: All %d reconnect attempts exhausted." % max_attempts)
		_reconnect_state = _ReconnectState.IDLE
		_reconnect_attempt = 0
		_saved_subscription_queries.clear()
		reconnect_failed.emit()
		_emit_disconnected()
		return

	_reconnect_attempt += 1
	var backoff: float = 0.0 if _reconnect_immediate else _calculate_backoff(_reconnect_attempt)
	_reconnect_immediate = false # one-shot: only the first stall-induced attempt skips backoff
	var max_str: String = str(max_attempts) if max_attempts > 0 else "inf"
	print_log(
		"SpacetimeDBClient: Reconnect attempt %d/%s in %.2f seconds."
		% [_reconnect_attempt, max_str, backoff]
	)

	reconnecting.emit(_reconnect_attempt, max_attempts)

	var tree: SceneTree = get_tree()
	if not tree:
		printerr("SpacetimeDBClient: Cannot schedule reconnect — not in scene tree.")
		_reconnect_state = _ReconnectState.IDLE
		reconnect_failed.emit()
		_emit_disconnected()
		return

	# Wall clock (ignore_time_scale), like every other timer in the SDK: a backoff is a
	# statement about the network, not about game time, and a game frozen with
	# Engine.time_scale = 0 (the usual pause idiom) would otherwise never retry — the
	# same stalled-backoff failure reconnect_on_app_resume exists for, from a different
	# cause. Slow motion would stretch it just as wrongly.
	_reconnect_timer = tree.create_timer(backoff, true, false, true)
	if _reconnect_timer:
		_reconnect_timer.timeout.connect(_attempt_reconnect, CONNECT_ONE_SHOT)
	else:
		printerr("SpacetimeDBClient: Failed to create reconnect timer.")
		_reconnect_state = _ReconnectState.IDLE
		reconnect_failed.emit()
		_emit_disconnected()


## True when regaining focus should pull a waiting reconnect attempt forward: the
## option is on, a reconnect cycle is in flight, and its backoff timer still has time
## left to run. Pure so the decision is testable without a scene tree or a socket.
static func should_resume_reconnect(enabled: bool, is_reconnecting: bool, timer_time_left: float) -> bool:
	return enabled and is_reconnecting and timer_time_left > 0.0


## Fires a reconnect attempt whose backoff timer stalled while the app was in the
## background. A backgrounded frame loop is throttled (web) or stopped (mobile
## suspend), so the [SceneTreeTimer] the backoff runs on barely advances; without
## this, a drop that happens off-screen waits out the rest of that delay after the
## player is already looking at the game again.
func _on_app_resumed() -> void:
	var enabled: bool = (connection_options != null and connection_options.reconnect_on_app_resume)
	var time_left: float = 0.0
	if _reconnect_timer != null:
		time_left = _reconnect_timer.time_left
	var is_reconnecting: bool = _reconnect_state == _ReconnectState.RECONNECTING
	if not should_resume_reconnect(enabled, is_reconnecting, time_left):
		return

	print_log("SpacetimeDBClient: App resumed — firing the pending reconnect attempt now.")
	if _reconnect_timer.timeout.is_connected(_attempt_reconnect):
		_reconnect_timer.timeout.disconnect(_attempt_reconnect)
	_reconnect_timer = null
	# The pending attempt is re-scheduled under its own number rather than consuming a
	# new one, so alt-tabbing can neither burn through max_reconnect_attempts nor reset
	# it — only the remaining wait is skipped.
	_reconnect_attempt = maxi(_reconnect_attempt - 1, 0)
	_reconnect_immediate = true
	_schedule_next_reconnect_attempt()


func _calculate_backoff(attempt: int) -> float:
	var base_delay: float = _reconnect_initial_delay * pow(
		_reconnect_backoff_multiplier,
		attempt - 1,
	)
	base_delay = minf(base_delay, _reconnect_max_delay)

	var jitter_range: float = base_delay * _reconnect_jitter_fraction
	var jitter_offset: float = randf() * jitter_range
	# The floor belongs on the PRODUCT, not only on the knobs it is computed from. Every
	# input can pass its own resolver and the result still land under a frame: the
	# documented full jitter (1.0) makes the offset uniform over the whole delay, and a
	# flat multiplier (1.0) means the delay never climbs away from wherever it started —
	# measured with initial = the minimum, multiplier 1.0, jitter 1.0, a mean of 49.5 ms
	# and 17% of attempts under a frame, i.e. the same storm at a third of the rate. The
	# instant-retry path does not come through here: the stall case sets its backoff to
	# zero directly (see _reconnect_immediate).
	return maxf(MIN_RECONNECT_DELAY_SECONDS, base_delay - jitter_offset)


func _attempt_reconnect() -> void:
	_reconnect_timer = null

	if _reconnect_state != _ReconnectState.RECONNECTING:
		return

	if not _connection or _token.is_empty():
		printerr("SpacetimeDBClient: Cannot reconnect — missing connection or token.")
		_reconnect_state = _ReconnectState.IDLE
		reconnect_failed.emit()
		_emit_disconnected()
		return

	_prepare_for_reconnect()

	# Re-checked because _prepare_for_reconnect reports the cache wipe to row listeners,
	# and a listener is game code: one that calls disconnect_db() has cancelled this
	# cycle, and opening the socket anyway would be reconnecting against the caller's
	# wishes.
	if _reconnect_state != _ReconnectState.RECONNECTING:
		print_log("SpacetimeDBClient: Reconnect cancelled while the cache wipe was reported.")
		return

	var conn_id: String = _generate_connection_id()
	_connection.set_token(_token)

	print_log("SpacetimeDBClient: Attempting reconnect (attempt %d)." % _reconnect_attempt)
	_connection.connect_to_database(base_url, database_name, conn_id)


# Everything the dying session left in flight, dropped so none of it lands in the mirror
# the next session is about to fill: packets not yet parsed, results parsed but not
# drained, the batch a frame was midway through, and the parse state of the packet the
# socket died partway into. Runs no game code, so a caller can call it before its own wipe
# (which does) and know the queues are already settled.
#
# Both session boundaries need this — the automatic one in _prepare_for_reconnect and the
# manual one in connect_db. They used to disagree about it, and the manual path drained
# the old session's messages into the new session's mirror.
func _drop_dead_session_traffic() -> void:
	if use_threading and _packet_mutex:
		_packet_mutex.lock()
		# Bump the epoch under the same lock the worker drains under, so any batch
		# it has already pulled will fail its post-parse epoch check and be dropped.
		_session_epoch += 1
		_packet_queue.clear()
		_packet_mutex.unlock()

		_result_mutex.lock()
		_result_queue.clear()
		_result_mutex.unlock()
	else:
		# Same boundary, without a worker to enforce it. Threadless is not an exotic setup
		# — _setup_threading disables threading on a build with no thread support, so every
		# threadless web export lands here.
		#
		# The queued results were parsed out of the dying session and would otherwise be
		# drained into the fresh mirror, which is exactly what the worker's epoch check
		# prevents on the threaded side. The deserializer reset beside it is belt and
		# braces — the parse loop clears its error at every message, so nothing observes
		# a stale one — but the worker does it on an epoch change and this path had no
		# equivalent at all, which is the asymmetry that let the bug above live here.
		_result_queue.clear()
		if _deserializer:
			_deserializer.reset_stream_state()

	# Main-thread-only state, so no lock: the batch a frame was partway through draining.
	_drain_batch = []
	_drain_cursor = 0


func _prepare_for_reconnect() -> void:
	_reducer_result_cache.clear()
	_procedure_result_cache.clear()
	# Cleared so a post-reconnect request_id (counter resets to 0 below) can't read a
	# stale pre-disconnect one-off result out of the cache.
	_one_off_query_cache.clear()
	_fail_pending_calls_disconnected()

	_end_all_subscriptions()

	_received_initial_subscription = false
	_next_query_id = 0
	_next_request_id = 0

	_drop_dead_session_traffic()

	# The cache wipe goes LAST, because it is the step here most likely to be observed
	# from game code (the subscription `end` signals above are the other one that runs
	# any): clear_local_db reports every cached row as deleted, and a listener that
	# reads client state (or calls back in) has to see the finished reconnect-prep state,
	# not a half-reset one. Reporting the rows is the point — the resubscribe only
	# re-delivers rows that still exist, so a row deleted server-side while the
	# client was away would otherwise leave the mirror with nothing to tell a
	# consumer keyed by primary key, which would hold what it spawned for that row
	# for the rest of the session. Rows that do come back arrive as inserts again.
	if _local_db:
		_local_db.clear_local_db()


# Ends every subscription handle this session held and drops the bookkeeping that goes
# with them. A handle is connection-scoped (see SpacetimeDBSubscription), so both session
# boundaries — the reconnect prep and the terminal `disconnected` — pass through here.
#
# The maps are emptied BEFORE the first `end` goes out, because emitting is game code: a
# handler that calls disconnect_db() re-enters this function through _emit_disconnected,
# and on the reconnect path (where `disconnected` has not fired, so its once-per-session
# guard is not yet set) it would find both maps still populated and emit `end` a second
# time on every handle the outer call had not reached. Clearing first makes the re-entrant
# call a no-op, so each handle ends exactly once.
func _end_all_subscriptions() -> void:
	var ending: Array[SpacetimeDBSubscription] = []
	ending.append_array(pending_subscriptions.values())
	ending.append_array(current_subscriptions.values())
	pending_subscriptions.clear()
	current_subscriptions.clear()
	# Every id it could hold belonged to one of those two maps.
	_unsubscribing_query_ids.clear()
	for sub: SpacetimeDBSubscription in ending:
		sub.end.emit()


func _cancel_reconnection() -> void:
	if _reconnect_state == _ReconnectState.IDLE:
		return

	print_log("SpacetimeDBClient: Cancelling reconnection.")
	_reconnect_state = _ReconnectState.IDLE
	_reconnect_attempt = 0
	_reconnect_immediate = false
	_resubscribe_epoch += 1 # supersede any in-flight resubscribe settles
	_saved_subscription_queries.clear()

	# No time_left check: a zero-delay timer (a stall-induced fast reconnect, or one
	# pulled forward by _on_app_resumed) has not fired yet either, and leaving it
	# connected lets it call _attempt_reconnect after the cancel — which would null a
	# *newer* cycle's _reconnect_timer and connect a second time. is_connected already
	# makes this a no-op for a timer that has fired.
	if _reconnect_timer != null and _reconnect_timer.timeout.is_connected(_attempt_reconnect):
		_reconnect_timer.timeout.disconnect(_attempt_reconnect)
	_reconnect_timer = null
	# A cancelled cycle is over; nothing for _enter_tree to pick up.
	_reconnect_suspended = false


## Picks up a cycle [method _exit_tree] suspended, a frame after the client is back in
## the tree. Re-checks everything that could have changed in that frame: a
## [method connect_db] or [method disconnect_db] from the re-entry frame cancels the
## cycle (leaving [member _reconnect_state] IDLE), and the client may have left the tree
## again before this ran.
func _resume_suspended_reconnect() -> void:
	if _reconnect_state != _ReconnectState.RECONNECTING or not is_inside_tree():
		return
	_schedule_next_reconnect_attempt()


## Drops the pending backoff timer but KEEPS the cycle — state, attempt count and saved
## subscription queries — so [method _enter_tree] can schedule the next attempt when the
## client is back in the tree. Called only from [method _exit_tree]; every other path
## that ends a cycle uses [method _cancel_reconnection], which discards all of it.
func _suspend_reconnection() -> void:
	if _reconnect_state == _ReconnectState.IDLE:
		return
	print_log("SpacetimeDBClient: Suspending reconnection (left the tree).")
	_reconnect_suspended = true
	# Same reasoning as the cancel path: a timer left connected would call
	# _attempt_reconnect against a client that is no longer in the tree.
	if _reconnect_timer != null and _reconnect_timer.timeout.is_connected(_attempt_reconnect):
		_reconnect_timer.timeout.disconnect(_attempt_reconnect)
	_reconnect_timer = null


func _resubscribe_saved_queries() -> void:
	_resubscribe_epoch += 1
	var epoch: int = _resubscribe_epoch
	# Snapshot so a re-entrant _start_reconnection rebuilding _saved_subscription_queries
	# (on a drop mid-resubscribe) can't disturb this loop (mutation-during-iteration).
	var query_sets: Array[PackedStringArray] = _saved_subscription_queries.duplicate()
	var total_sets: int = query_sets.size()
	var applied_count: Array[int] = [0]

	if total_sets == 0:
		_finish_resubscribe(epoch)
		return

	for queries: PackedStringArray in query_sets:
		var sub: SpacetimeDBSubscription = subscribe(queries)
		if sub.error != OK:
			printerr(
				"SpacetimeDBClient: Failed to re-subscribe during reconnection: %s"
				% error_string(sub.error)
			)
			applied_count[0] += 1
			if applied_count[0] >= total_sets:
				_finish_resubscribe(epoch)
			continue

		var settled: Array[bool] = [false]
		var on_settled: Callable = func() -> void:
			# Bail if this sub already settled, or a newer reconnect cycle superseded us.
			if settled[0] or epoch != _resubscribe_epoch:
				return
			settled[0] = true
			applied_count[0] += 1
			print_log(
				"SpacetimeDBClient: Re-subscription settled (%d/%d)."
				% [applied_count[0], total_sets]
			)
			if applied_count[0] >= total_sets:
				_finish_resubscribe(epoch)
		sub.applied.connect(on_settled, CONNECT_ONE_SHOT)
		sub.end.connect(on_settled, CONNECT_ONE_SHOT)

	# Watchdog: a server that accepts a Subscribe but never settles one set would
	# otherwise hang the cycle (reconnected never fires, saved set never clears).
	# Force-complete after a timeout. Epoch-guarded via _finish_resubscribe, so a
	# cycle that already settled or was superseded by a fresh reconnect is a no-op.
	# Routed through a bound method-ref (not a lambda) so the timeout Callable carries
	# Godot's freed-instance check — if the client is freed before the timer fires,
	# the call safely no-ops instead of invoking on a dangling self.
	var tree: SceneTree = get_tree()
	if tree:
		# Wall clock — see the reconnect timer above.
		var watchdog: SceneTreeTimer = tree.create_timer(
			RESUBSCRIBE_TIMEOUT_SECONDS,
			true,
			false,
			true,
		)
		watchdog \
				.timeout \
				.connect(
			_on_resubscribe_watchdog.bind(epoch, applied_count, total_sets),
			CONNECT_ONE_SHOT,
		)


# Watchdog timeout for a resubscribe cycle. Bound with the cycle's captured epoch,
# shared applied-count, and total set count. Force-completes the cycle only if it is
# still current and unsettled; _finish_resubscribe is epoch-guarded so a settled or
# superseded cycle is a no-op.
# S6 ignored: applied_count is a shared mutable counter (`[0]`) read by reference so
# the watchdog sees live on_settled updates; PackedInt32Array is copy-on-write and
# would capture a stale copy at bind() time.
func _on_resubscribe_watchdog(epoch: int, applied_count: Array[int], total_sets: int) -> void: # gdlint: ignore[S6]
	if epoch == _resubscribe_epoch and applied_count[0] < total_sets:
		push_warning(
			(
				"SpacetimeDBClient: resubscribe timed out (%d/%d settled) — completing anyway."
				% [applied_count[0], total_sets]
			)
		)
		_finish_resubscribe(epoch)


## Completes a resubscribe cycle: clears the saved set and emits [signal reconnected],
## but only if [param epoch] is still current — a superseded cycle does nothing.
func _finish_resubscribe(epoch: int) -> void:
	if epoch != _resubscribe_epoch:
		return
	# Supersede this cycle so a late settle OR the watchdog timer that also calls
	# _finish_resubscribe can't re-fire reconnected (both compare their captured
	# epoch to _resubscribe_epoch and bail once it moves).
	_resubscribe_epoch += 1
	_saved_subscription_queries.clear()
	reconnected.emit()


# Registers a reducer handle, dropping the oldest outstanding one first when the map is
# at its cap. See _MAX_PENDING_CALLS: without this, a call whose response is lost while
# the socket stays up holds its handle (and whatever the caller closed over) for the
# life of the connection.
func _track_reducer_call(request_id: int, handle: SpacetimeDBReducerCall) -> void:
	if _pending_reducer_calls.size() >= _MAX_PENDING_CALLS:
		# First key = oldest (dict iteration is insertion-order); no keys() alloc.
		for oldest: int in _pending_reducer_calls:
			var dropped: SpacetimeDBReducerCall = _pending_reducer_calls[oldest]
			# Stamped rather than silently dropped: an awaiter would otherwise sit on a
			# handle nothing can ever complete, and the message names why it ended.
			if dropped.outcome == SpacetimeDBReducerCall.Outcome.PENDING:
				dropped.outcome = SpacetimeDBReducerCall.Outcome.TIMEOUT
				dropped.error_message = (
					"Dropped: more than %d reducer calls outstanding" % _MAX_PENDING_CALLS
				)
			_pending_reducer_calls.erase(oldest)
			break
	_pending_reducer_calls[request_id] = handle


# Procedure-side twin of _track_reducer_call.
func _track_procedure_call(request_id: int, handle: SpacetimeDBProcedureCall) -> void:
	if _pending_procedure_calls.size() >= _MAX_PENDING_CALLS:
		for oldest: int in _pending_procedure_calls:
			var dropped: SpacetimeDBProcedureCall = _pending_procedure_calls[oldest]
			if dropped.outcome == SpacetimeDBProcedureCall.Outcome.PENDING:
				dropped.outcome = SpacetimeDBProcedureCall.Outcome.TIMEOUT
				dropped.error_message = (
					"Dropped: more than %d procedure calls outstanding" % _MAX_PENDING_CALLS
				)
			_pending_procedure_calls.erase(oldest)
			break
	_pending_procedure_calls[request_id] = handle


func _evict_oldest(cache: Dictionary) -> void:
	while cache.size() > _MAX_RESULT_CACHE_SIZE and not cache.is_empty():
		# Grab the first (oldest-inserted) key via iteration — no keys() array alloc.
		for oldest_key: Variant in cache:
			cache.erase(oldest_key)
			break
