# Live verification of token persistence → stable identity across reconnects.
#
# With one_time_token = false + save_token = true the SDK writes the auth token to
# token_save_path on first connect and reloads it on the next, so a client (or a
# restarted app) resumes the SAME identity. This is what lets the Blackholio
# example auto-rejoin an existing player instead of spawning a fresh one. Connect
# twice with persistence on and assert the identity matches.
#
# Requires the `blackholio` module published to a local server (the example's
# committed bindings already cover it — no regen needed):
#   spacetime publish -s local blackholio --yes   (from demo/Blackholio/server-rust)
# Then copy this file into godot-client/ and run it there (same pattern as
# verify_live.gd — the script must live under res://):
#   cp integration-tests/verify_live_reconnect.gd godot-client/
#   cd godot-client && <godot> --headless --path . --script verify_live_reconnect.gd
#   (remove the copy afterward)
extends SceneTree

func _initialize() -> void:
	_run()


func _run() -> void:
	var id1: PackedByteArray = await _connect_get_identity()
	if id1.is_empty():
		printerr("FAIL: first connect produced no identity")
		quit(1)
		return

	var id2: PackedByteArray = await _connect_get_identity()
	if id2.is_empty():
		printerr("FAIL: second connect produced no identity")
		quit(1)
		return

	if id1 == id2:
		print("PASS  identity persisted across reconnect: 0x%s" % id1.hex_encode())
		print("ALL PASS (1/1)")
		quit(0)
	else:
		printerr("FAIL  identity changed: 0x%s != 0x%s" % [id1.hex_encode(), id2.hex_encode()])
		quit(1)


# Connects once with token persistence enabled and returns the identity from the
# connected signal. The first call requests + saves a token (or loads an existing
# one); the second loads the saved token — both must yield the same identity.
func _connect_get_identity() -> PackedByteArray:
	var client: BlackholioModuleClient = BlackholioModuleClient.new()
	root.add_child(client)
	await process_frame # client + its HTTPRequest must be in-tree before connecting

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = false
	options.save_token = true
	client.connect_db("http://127.0.0.1:3000", "blackholio", options)

	# connected(identity: PackedByteArray, token: String) — awaiting a multi-arg
	# signal yields an Array of its arguments.
	var res: Array = await client.connected
	var identity: PackedByteArray = res[0] if res.size() >= 1 else PackedByteArray()

	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame
	return identity
