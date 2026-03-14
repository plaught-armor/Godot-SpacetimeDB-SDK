## Metadata about the reducer invocation that produced a transaction update.
##
## Embedded inside parsed transaction data so the client can identify which
## reducer ran, what arguments were passed, and how long execution took.
@tool
class_name ReducerCallInfoData
extends RefCounted

## BSATN type hints used by the SDK's binary deserializer.
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"reducer_id": &"u32", &"request_id": &"u32", &"execution_time": &"i64" }

## Human-readable name of the reducer that was called.
@export var reducer_name: String
## Server-assigned numeric id of the reducer.
@export var reducer_id: int
## BSATN-encoded arguments that were passed to the reducer.
@export var args: PackedByteArray
## Client-assigned request id from the originating [CallReducerMessage].
@export var request_id: int
## Reducer execution time in microseconds.
@export var execution_time: int
