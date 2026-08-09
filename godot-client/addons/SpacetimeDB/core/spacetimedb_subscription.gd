## Handle returned by [method SpacetimeDBClient.subscribe].
##
## Tracks a subscription's lifecycle from registration through server
## confirmation and eventual unsubscription. Connect to [signal applied] or
## [code]await[/code] [method wait_for_applied] to know when the initial
## row snapshot has been processed.
##
## [b]A handle is scoped to one connection.[/b] When the client reconnects it ends
## every outstanding handle and re-subscribes the saved queries under fresh ones,
## so a handle held across a reconnect stays [constant State.ENDED] permanently even
## though the underlying query is live again. The rows keep flowing — only this
## object is stale. Code that needs a handle after a drop should take a fresh one
## from a [method SpacetimeDBClient.subscribe] call made in response to
## [signal SpacetimeDBClient.reconnected], not cache one from before the drop.
class_name SpacetimeDBSubscription
extends RefCounted

## Emitted when the server confirms the subscription and the initial rows are applied.
signal applied
## Emitted when the subscription is ended (unsubscribed or errored).
signal end

## Deadline both waiters default to, and the one they fall back to when the caller's
## cannot be waited out ([method SpacetimeDBClient.resolve_wait_timeout]). Shorter than the
## client's own default because a subscription settles on the server's first response,
## not on a round trip that carries a reducer's work.
const DEFAULT_WAIT_SECONDS: float = 5.0

## Client-assigned query set id.
var query_id: int = -1
## The SQL queries registered with this subscription.
var queries: PackedStringArray
## Immediate error from subscribe, or [constant OK].
var error: Error = OK
## Human-readable error from a [SubscriptionErrorMessage], if any.
var error_message: String = ""
## Subscription lifecycle, single source of truth. PENDING until the server
## confirms ([constant State.ACTIVE]) or it unsubscribes/errors
## ([constant State.ENDED]). States are mutually exclusive by construction.
enum State { PENDING, ACTIVE, ENDED }
## [code]true[/code] after [signal applied] fires and before [signal end] fires.
var active: bool:
	get:
		return _state == State.ACTIVE
## [code]true[/code] after [signal end] fires.
var ended: bool:
	get:
		return _state == State.ENDED
var _client: SpacetimeDBClient
var _state: State = State.PENDING


static func create(
		p_client: SpacetimeDBClient,
		p_query_id: int,
		p_queries: PackedStringArray,
) -> SpacetimeDBSubscription:
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.new()
	subscription._client = p_client
	subscription.query_id = p_query_id
	subscription.queries = p_queries

	subscription.applied.connect(subscription._on_applied)
	subscription.end.connect(subscription._on_end)
	return subscription


## Creates a pre-failed subscription handle for an immediate client-side error.
static func fail(error: Error) -> SpacetimeDBSubscription:
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.new()
	subscription.error = error
	subscription._state = State.ENDED
	return subscription


## Awaits until the subscription is applied or [param timeout_sec] elapses.[br]
## [param timeout_sec] is resolved before it is waited on — see
## [method SpacetimeDBClient.resolve_wait_timeout].[br]
## Returns [constant OK] on success, [constant ERR_TIMEOUT] on timeout, or
## [constant ERR_DOES_NOT_EXIST] if the subscription ended before applying.
func wait_for_applied(timeout_sec: float = DEFAULT_WAIT_SECONDS) -> Error:
	# Resolved before the state short-circuits below, not after them: a caller
	# that always passes a deadline the loop cannot be paced by would otherwise be told so
	# or not depending on whether the subscription happened to have settled already.
	var deadline: float = SpacetimeDBClient.resolve_wait_timeout(
		timeout_sec,
		DEFAULT_WAIT_SECONDS,
		"timeout_sec",
	)
	if _state == State.ACTIVE:
		return OK
	if _state == State.ENDED:
		return ERR_DOES_NOT_EXIST
	# The owner may have been freed while the caller held this handle (H8): _client is a
	# Node, so touching it faults, and a fault unwinds the function to its default — Error
	# 0, i.e. OK, which reads as "applied" for a subscription that never was. Below the
	# state checks on purpose: a handle that really did settle before its owner died keeps
	# reporting what happened.
	if not is_instance_valid(_client):
		return ERR_DOES_NOT_EXIST
	var tree: SceneTree = _client.get_tree()
	if tree == null:
		return ERR_DOES_NOT_EXIST
	# Per-await LOCAL timer + poll. Concurrent awaiters on the same handle each get
	# their own deadline instead of clobbering a shared timer/broadcast signal (which
	# let a short-timeout caller resolve a long-timeout caller early).
	# A deadline the loop cannot be paced by was refused above the state checks: NaN and
	# anything <= 0 fail `time_left > 0.0` on the first pass, so the caller would get
	# ERR_TIMEOUT without ever yielding, and INF would make this loop unbounded.
	# Wall clock (ignore_time_scale): the deadline is about the server answering, so a
	# game frozen with Engine.time_scale = 0 must not suspend it for the whole freeze.
	var timer: SceneTreeTimer = tree.create_timer(deadline, true, false, true)
	while _state == State.PENDING and timer.time_left > 0.0:
		await tree.process_frame
		if not is_instance_valid(_client): # client freed mid-await (C5 / H8)
			return ERR_DOES_NOT_EXIST
	if _state == State.ACTIVE:
		return OK
	if _state == State.ENDED:
		return ERR_DOES_NOT_EXIST
	return ERR_TIMEOUT


## Awaits until the subscription ends or [param timeout_sec] elapses, resolved as in
## [method wait_for_applied].
func wait_for_end(timeout_sec: float = DEFAULT_WAIT_SECONDS) -> Error:
	# Resolved up front — see wait_for_applied.
	var deadline: float = SpacetimeDBClient.resolve_wait_timeout(
		timeout_sec,
		DEFAULT_WAIT_SECONDS,
		"timeout_sec",
	)
	if _state == State.ENDED:
		return OK
	# Freed owner — see wait_for_applied. Here the unwound default would be OK, which for
	# this waiter means "the subscription ended cleanly".
	if not is_instance_valid(_client):
		return ERR_DOES_NOT_EXIST
	var tree: SceneTree = _client.get_tree()
	if tree == null:
		return ERR_DOES_NOT_EXIST
	# Wall clock — see wait_for_applied above.
	var timer: SceneTreeTimer = tree.create_timer(deadline, true, false, true)
	while _state != State.ENDED and timer.time_left > 0.0:
		await tree.process_frame
		if not is_instance_valid(_client): # client freed mid-await (C5 / H8)
			return ERR_DOES_NOT_EXIST
	if _state == State.ENDED:
		return OK
	return ERR_TIMEOUT


## Sends an unsubscribe request to the server. Returns [constant ERR_DOES_NOT_EXIST] if already ended.
func unsubscribe() -> Error:
	if _state == State.ENDED:
		return ERR_DOES_NOT_EXIST

	return _client.unsubscribe(query_id)


## Marks a still-PENDING subscription ended without emitting [signal end] — for
## immediate send/connection failures surfaced before any caller awaits the
## handle. No-op once ACTIVE or already ENDED: a confirmed subscription must go
## through [method _on_end] so awaiters are unblocked.
func mark_ended() -> void:
	if _state != State.PENDING:
		return
	_state = State.ENDED


func _on_applied() -> void:
	# ENDED is terminal: a late/out-of-order applied (e.g. an error ended the
	# subscription, then a stray SubscribeApplied arrives) must not resurrect it.
	# Awaiters observe _state directly (poll loop), so no signal to re-emit here.
	if _state == State.ENDED:
		return
	_state = State.ACTIVE


func _on_end() -> void:
	_state = State.ENDED
