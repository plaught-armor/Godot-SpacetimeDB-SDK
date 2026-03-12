## Handle returned by [method SpacetimeDBClient.subscribe].
##
## Tracks a subscription's lifecycle from registration through server
## confirmation and eventual unsubscription. Connect to [signal applied] or
## [code]await[/code] [method wait_for_applied] to know when the initial
## row snapshot has been processed.
class_name SpacetimeDBSubscription
extends RefCounted

## Emitted when the server confirms the subscription and the initial rows are applied.
signal applied
## Emitted when the subscription is ended (unsubscribed or errored).
signal end
signal _applied_or_timeout(timeout: bool)
signal _ended_or_timeout(timeout: bool)

## Client-assigned query set id.
var query_id: int = -1
## The SQL queries registered with this subscription.
var queries: PackedStringArray
## Immediate error from subscribe, or [constant OK].
var error: Error = OK
## Human-readable error from a [SubscriptionErrorMessage], if any.
var error_message: String = ""
## [code]true[/code] after [signal applied] fires and before [signal end] fires.
var active: bool:
	get:
		return _active
## [code]true[/code] after [signal end] fires.
var ended: bool:
	get:
		return _ended
var _client: SpacetimeDBClient
var _active: bool = false
var _ended: bool = false
var _apply_timer: SceneTreeTimer
var _end_timer: SceneTreeTimer


static func create(
		p_client: SpacetimeDBClient,
		p_query_id: int,
		p_queries: PackedStringArray,
) -> SpacetimeDBSubscription:
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.new()
	subscription._client = p_client
	subscription.query_id = p_query_id
	subscription.queries = p_queries

	subscription.applied.connect(
		func():
			subscription._active = true
			subscription._ended = false
			if subscription._apply_timer:
				subscription._apply_timer.time_left = 0
				subscription._apply_timer = null
			subscription._applied_or_timeout.emit(false)
	)
	subscription.end.connect(
		func():
			subscription._active = false
			subscription._ended = true
			# Cancel apply timer and unblock wait_for_applied() if still waiting
			if subscription._apply_timer:
				subscription._apply_timer.time_left = 0
				subscription._apply_timer = null
			subscription._applied_or_timeout.emit(false)
			if subscription._end_timer:
				subscription._end_timer.time_left = 0
				subscription._end_timer = null
			subscription._ended_or_timeout.emit(false)
	)
	return subscription


## Creates a pre-failed subscription handle for an immediate client-side error.
static func fail(error: Error) -> SpacetimeDBSubscription:
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.new()
	subscription.error = error
	subscription._ended = true
	return subscription


## Awaits until the subscription is applied or [param timeout_sec] elapses.[br]
## Returns [constant OK] on success, [constant ERR_TIMEOUT] on timeout, or
## [constant ERR_DOES_NOT_EXIST] if the subscription ended before applying.
func wait_for_applied(timeout_sec: float = 5) -> Error:
	if _active:
		return OK
	if _ended:
		return ERR_DOES_NOT_EXIST

	_apply_timer = _client.get_tree().create_timer(timeout_sec)
	_apply_timer.timeout.connect(_on_applied_timeout)

	var is_timeout: bool = await _applied_or_timeout
	_apply_timer = null
	if is_timeout:
		return ERR_TIMEOUT
	if _ended and not _active:
		return ERR_DOES_NOT_EXIST
	return OK


## Awaits until the subscription ends or [param timeout_sec] elapses.
func wait_for_end(timeout_sec: float = 5) -> Error:
	if _ended:
		return OK

	_end_timer = _client.get_tree().create_timer(timeout_sec)
	_end_timer.timeout.connect(_on_ended_timeout)

	var is_timeout: bool = await _ended_or_timeout
	_end_timer = null
	if is_timeout:
		return ERR_TIMEOUT
	return OK


## Sends an unsubscribe request to the server. Returns [constant ERR_DOES_NOT_EXIST] if already ended.
func unsubscribe() -> Error:
	if _ended:
		return ERR_DOES_NOT_EXIST

	return _client.unsubscribe(query_id)


func _on_applied_timeout() -> void:
	_apply_timer = null
	_applied_or_timeout.emit(true)


func _on_ended_timeout() -> void:
	_end_timer = null
	_ended_or_timeout.emit(true)
