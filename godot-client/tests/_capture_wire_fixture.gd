# Regenerates tests/fixtures/wire_snapshot.bin — the real inbound frames that
# test_wire_fixture_decode.gd replays. Needs a running server with the Blackholio
# module published. Underscore-prefixed so run_tests.sh skips it, and a scene
# rather than --script because it needs the generated autoload.
#
#   spacetime start ... && cd blackholio-server && ./publish.sh
#   cd godot-client && <godot> --headless --path . res://tests/_capture_wire_fixture.tscn
#
# Frames are stored length-prefixed, raw (compression NONE), including the leading
# compression tag byte the client strips at parse time.
extends Node

const OUT_PATH: String = "res://tests/fixtures/wire_snapshot.bin"

var _file: FileAccess
var _count: int = 0


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	# NONE so the fixture is raw BSATN framing, replayable without a decompress step.
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	SpacetimeDB.Blackholio.connected.connect(_on_connected)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_file = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	SpacetimeDB.Blackholio._connection.message_received.connect(_on_packet)
	SpacetimeDB.Blackholio.subscribe(["SELECT * FROM config"])
	await get_tree().create_timer(4.0).timeout
	_file.close()
	print("[capture] packets=%d bytes=%d" % [_count, FileAccess.get_file_as_bytes(OUT_PATH).size()])
	get_tree().quit()


func _on_packet(bytes: PackedByteArray) -> void:
	# length-prefixed frames so the test can replay them in order
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)
	_count += 1
