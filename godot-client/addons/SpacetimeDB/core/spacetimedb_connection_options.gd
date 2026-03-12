## Configuration resource passed to [method SpacetimeDBClient.connect_db].
##
## Controls WebSocket behaviour, threading, authentication, reconnection
## strategy, and performance monitoring. Create one, tweak the members, and
## hand it to [code]connect_db()[/code].
class_name SpacetimeDBConnectionOptions extends Resource

const CompressionPreference = SpacetimeDBConnection.CompressionPreference

## WebSocket payload compression mode. Brotli is not supported and falls back to Gzip.
var compression: CompressionPreference = CompressionPreference.NONE
## If [code]true[/code], BSATN deserialization runs on a background thread.
var threading: bool = true
## If [code]true[/code], the SDK requests a fresh token on every connection.
var one_time_token: bool = true
## Pre-set authentication token. If empty, the SDK will request one automatically.
var token: String = ""
## Enables verbose logging in the SDK's connection and client classes.
var debug_mode: bool = false
## Registers custom Godot [Performance] monitors for packet/byte throughput.
var monitor_mode: bool = false
## Maximum size in bytes of the WebSocket inbound buffer (default 2 MB).
var inbound_buffer_size: int = 1024 * 1024 * 2
## Maximum size in bytes of the WebSocket outbound buffer (default 2 MB).
var outbound_buffer_size: int = 1024 * 1024 * 2

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

## Convenience setter — sets both [member inbound_buffer_size] and [member outbound_buffer_size].
func set_all_buffer_size(size: int) -> void:
	inbound_buffer_size = size
	outbound_buffer_size = size
