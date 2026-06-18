# One-shot capture tool: records raw inbound WebSocket packets from a live Blackholio
# stream to a fixture file (bench_workload.bin), which replay_workload.gd then replays
# in-process. Run with bench_load.gd providing bot load in another process, against a
# server with the Blackholio module published. Connects with compression NONE so the
# fixture is replayable without a decompression step.
#
#   <godot> --headless --path . --script res://benchmark/capture_workload.gd -- <max_packets>
extends SceneTree

const OUT_PATH: String = "res://benchmark/bench_workload.bin"

var _client: BlackholioModuleClient
var _file: FileAccess
var _count: int = 0
var _max: int = 4000


func _initialize() -> void:
	_run()


func _on_packet(bytes: PackedByteArray) -> void:
	if _count >= _max:
		return
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)
	_count += 1


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0:
		_max = int(args[0])
	_file = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if _file == null:
		printerr("cannot open %s" % OUT_PATH)
		quit(1)
		return

	_client = BlackholioModuleClient.new()
	root.add_child(_client)
	await process_frame
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.compression = SpacetimeDBConnection.CompressionPreference.NONE
	_client.connect_db("http://127.0.0.1:3000", "blackholio", opts)
	await _client.connected
	_client._connection.message_received.connect(_on_packet)
	_client.subscribe(
		[
			"SELECT * FROM entity",
			"SELECT * FROM circle",
			"SELECT * FROM food",
			"SELECT * FROM player",
			"SELECT * FROM config",
		],
	)

	# Time-bounded: capture for up to CAPTURE_MS of stream, or _max packets, whichever
	# first (v3 framing batches many messages per packet, so packet rate is low).
	const CAPTURE_MS: int = 25000
	var t0: int = Time.get_ticks_msec()
	while _count < _max and Time.get_ticks_msec() - t0 < CAPTURE_MS:
		await process_frame

	_file.flush()
	_file.close()
	print("CAPTURED %d packets, %d bytes -> %s" % [_count, FileAccess.get_file_as_bytes(OUT_PATH).size(), OUT_PATH])
	_client.disconnect_db()
	quit(0)
