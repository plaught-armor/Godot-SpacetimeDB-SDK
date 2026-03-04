extends Control


func _ready() -> void:
	var options := SpacetimeDBConnectionOptions.new()
	options.one_time_token = true # <--- anonymous-like. set to false to persist
	options.debug_mode = true # <--- enables lots of additional debug prints and warnings
	options.compression = SpacetimeDBConnection.CompressionPreference.GZIP
	options.threading = false

	# Auto-reconnection with exponential backoff
	options.auto_reconnect = true
	options.max_reconnect_attempts = 10       # 0 = infinite
	options.reconnect_initial_delay = 1.0     # seconds
	options.reconnect_max_delay = 30.0        # cap
	options.reconnect_backoff_multiplier = 2.0
	options.reconnect_jitter_fraction = 0.5   # 0.0–1.0

	SpacetimeDB.Main.connect_db( # WARNING <--- replace 'Main' with your module name
		"http://127.0.0.1:3000", # WARNING <--- replace it with your url
		"main", # WARNING <--- replace it with your database name
		options
	)

	SpacetimeDB.Main.connected.connect(_on_spacetimedb_connected)
	SpacetimeDB.Main.disconnected.connect(_on_spacetimedb_disconnected)
	SpacetimeDB.Main.connection_error.connect(_on_spacetimedb_connection_error)
	SpacetimeDB.Main.database_initialized.connect(_on_spacetimedb_database_init)
	SpacetimeDB.Main.reconnecting.connect(_on_spacetimedb_reconnecting)
	SpacetimeDB.Main.reconnected.connect(_on_spacetimedb_reconnected)
	SpacetimeDB.Main.reconnect_failed.connect(_on_spacetimedb_reconnect_failed)

func _on_spacetimedb_connected(identity: PackedByteArray, _token: String) -> void:
	print("Game: Connected to SpacetimeDB!")
	print("Game: My Identity: 0x%s" % [identity.hex_encode()])

func _on_spacetimedb_disconnected() -> void:
	print("Game: Disconnected from SpacetimeDB.")

func _on_spacetimedb_connection_error(code: int, reason: String) -> void:
	printerr("Game: SpacetimeDB Connection Error: ", reason, " Code: ", code)

func _on_spacetimedb_database_init() -> void:
	print("Game: Database initialised")

func _on_spacetimedb_reconnecting(attempt: int, max_attempts: int) -> void:
	print("Game: Reconnecting... attempt %d/%d" % [attempt, max_attempts])

func _on_spacetimedb_reconnected() -> void:
	print("Game: Reconnected!")

func _on_spacetimedb_reconnect_failed() -> void:
	printerr("Game: Reconnection failed after all attempts.")


func _on_button_pressed() -> void:
	SpacetimeDB.Main.reducers.start_integration_tests()


func _on_button_2_pressed() -> void:
	SpacetimeDB.Main.reducers.clear_integration_tests()
