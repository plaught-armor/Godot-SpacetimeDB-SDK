class_name SpacetimeDBConnectionOptions extends Resource

const CompressionPreference = SpacetimeDBConnection.CompressionPreference

var compression: CompressionPreference = CompressionPreference.NONE
var threading: bool = true
var one_time_token: bool = true
var token: String = ""
var debug_mode: bool = false
var monitor_mode: bool = false
var inbound_buffer_size: int = 1024 * 1024 * 2 # 2MB
var outbound_buffer_size: int = 1024 * 1024 * 2 # 2MB

# --- Auto-Reconnection ---
var auto_reconnect: bool = false
var max_reconnect_attempts: int = 10       # 0 = infinite
var reconnect_initial_delay: float = 1.0   # seconds
var reconnect_max_delay: float = 30.0      # cap
var reconnect_backoff_multiplier: float = 2.0
var reconnect_jitter_fraction: float = 0.5 # 0.0–1.0

func set_all_buffer_size(size: int):
	inbound_buffer_size = size
	outbound_buffer_size = size
