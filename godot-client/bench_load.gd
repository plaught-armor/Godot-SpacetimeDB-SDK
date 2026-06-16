# Load generator: spawns K bot connections that enter the game and continuously
# send random movement input, so the server's move_all_players tick produces a
# high-volume entity-update stream — the workload the drain/parse optimizations
# target. Run in the background while bench_measure.gd records.
#
#   <godot> --headless --path . --script res://bench_load.gd
extends SceneTree

const RUN_FRAMES: int = 60 * 90 # ~90s ceiling
const INPUT_EVERY: int = 6 # send input ~10x/sec at 60fps

var _bots: Array[BlackholioModuleClient] = []


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var K: int = int(args[0]) if args.size() > 0 else 40
	for i: int in K:
		var c: BlackholioModuleClient = BlackholioModuleClient.new()
		root.add_child(c)
		_bots.append(c)
	# Children must be in-tree before connect_db (its REST node calls request()).
	await process_frame
	for c: BlackholioModuleClient in _bots:
		var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
		# Bots only send input; no per-bot parse thread (avoids a thread per bot
		# at high counts). Does not change the server-side load they generate.
		opts.threading = false
		c.connect_db("http://127.0.0.1:3000", "blackholio", opts)

	# Let connections + the server-side connect reducer (creates player rows) settle.
	var w: int = 0
	while w < 240:
		await process_frame
		w += 1

	var entered: int = 0
	for i: int in _bots.size():
		if _bots[i].is_connected_db():
			_bots[i].reducers.enter_game("Bot_%d" % i)
			entered += 1
	print("LOAD entered %d/%d bots" % [entered, K])

	var frame: int = 0
	while frame < RUN_FRAMES:
		await process_frame
		frame += 1
		if frame % INPUT_EVERY == 0:
			for c: BlackholioModuleClient in _bots:
				if c.is_connected_db():
					var d: BlackholioDbVector2 = BlackholioDbVector2.create(
						randf_range(-1.0, 1.0),
						randf_range(-1.0, 1.0),
					)
					c.reducers.update_player_input(d)
	print("LOAD done")
	quit(0)
