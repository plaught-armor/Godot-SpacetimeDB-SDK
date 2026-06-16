# Measures one client's inbound throughput + frame health under the bot load.
# Headless fps = how fast the main loop runs with no vsync, so it directly
# reflects whether the per-frame drain/parse keeps up: heavy inbound that the
# client can't process cheaply tanks fps. Reports rows/sec applied + fps stats.
#
#   <godot> --headless --path . --script res://bench_measure.gd
extends SceneTree

const WARMUP_FRAMES: int = 240
const WINDOW_FRAMES: int = 60 * 15 # ~15s sample

const SUB_QUERIES: PackedStringArray = [
	"SELECT * FROM entity",
	"SELECT * FROM circle",
	"SELECT * FROM food",
	"SELECT * FROM player",
	"SELECT * FROM config",
]

var _rows: int = 0
var _client: BlackholioModuleClient


func _initialize() -> void:
	Engine.max_fps = 0 # uncap: fps then reflects per-frame cost under load
	_client = BlackholioModuleClient.new()
	root.add_child(_client)
	await process_frame # in-tree before connect_db
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	_client.connect_db("http://127.0.0.1:3000", "blackholio", opts)
	_client.row_inserted.connect(_on_ins)
	_client.row_updated.connect(_on_upd)
	_client.row_deleted.connect(_on_del)

	var cw: int = 0
	while not _client.is_connected_db() and cw < 600:
		await process_frame
		cw += 1
	_client.subscribe(SUB_QUERIES)

	var w: int = 0
	while w < WARMUP_FRAMES:
		await process_frame
		w += 1
	print("MEASURE connected=%s, sampling %d frames..." % [_client.is_connected_db(), WINDOW_FRAMES])

	var start_rows: int = _rows
	var t0: int = Time.get_ticks_msec()
	var fps_min: float = 100000.0
	var fps_sum: float = 0.0
	var max_pending: int = 0
	var i: int = 0
	while i < WINDOW_FRAMES:
		await process_frame
		var f: float = Engine.get_frames_per_second()
		fps_sum += f
		if f > 0.0 and f < fps_min:
			fps_min = f
		# Unapplied backlog: queued results + the in-flight drain batch remainder.
		# If this grows across the window, the drain can't keep up = ceiling hit.
		var pending: int = (
				_client._result_queue.size()
				+ maxi(0, _client._drain_batch.size() - _client._drain_cursor)
		)
		if pending > max_pending:
			max_pending = pending
		i += 1
	var dt: float = (Time.get_ticks_msec() - t0) / 1000.0
	var rows_applied: int = _rows - start_rows
	var end_pending: int = (
			_client._result_queue.size()
			+ maxi(0, _client._drain_batch.size() - _client._drain_cursor)
	)
	print(
		"RESULT bots=%s rows_per_sec=%.0f avg_fps=%.0f min_fps=%.0f max_backlog=%d end_backlog=%d" % [
			OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "?",
			rows_applied / dt,
			fps_sum / i,
			fps_min,
			max_pending,
			end_pending,
		],
	)
	quit(0)


func _on_ins(_t: StringName, _r: Resource) -> void:
	_rows += 1


func _on_upd(_t: StringName, _o: Resource, _n: Resource) -> void:
	_rows += 1


func _on_del(_t: StringName, _r: Resource) -> void:
	_rows += 1
