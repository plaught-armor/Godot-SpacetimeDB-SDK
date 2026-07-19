# Captures frames the SERVER compressed, which the main capture cannot produce.
#
# _capture_wire_fixture.gd asks for compression NONE on purpose, so its fixtures
# stay raw BSATN that any test can replay without a decompress step. The cost is
# that the decompressors have never seen a real server frame: test_decompress
# round-trips our own gzip and test_brotli_decompress decodes a blob from the
# `brotli` CLI. Both prove the codec, neither proves the SDK reads what
# SpacetimeDB actually emits — the tag byte, the framing around it, and the
# BSATN that comes back out.
#
# The server only compresses a message once it exceeds 1 KiB (COMPRESS_THRESHOLD
# in websocket_building.rs), so this subscribes to the whole entity table, which
# the module's food spawner keeps well past that.
#
#   spacetime start ... && cd blackholio-server && ./publish.sh
#   cd godot-client && <godot> --headless --path . res://tests/_capture_wire_compressed.tscn
#
# Writes tests/fixtures/wire_snapshot_gzip.bin and wire_snapshot_brotli.bin.
# Underscore-prefixed so run_tests.sh skips it.
extends Node

const GZIP_PATH: String = "res://tests/fixtures/wire_snapshot_gzip.bin"
const BROTLI_PATH: String = "res://tests/fixtures/wire_snapshot_brotli.bin"
## Wire tag bytes, as the server writes them (ws_common::SERVER_MSG_COMPRESSION_TAG_*).
const TAG_BROTLI: int = 1
const TAG_GZIP: int = 2
## The server compresses above 1 KiB, so the fixture is worthless below it.
const MIN_USEFUL_BYTES: int = 1024

# C1: never const a Packed*Array.
var _queries: PackedStringArray = ["SELECT * FROM entity"]
var _file: FileAccess
var _fails: int = 0


func _ready() -> void:
	await _capture(SpacetimeDBConnection.CompressionPreference.GZIP, GZIP_PATH, TAG_GZIP)
	await _capture(SpacetimeDBConnection.CompressionPreference.BROTLI, BROTLI_PATH, TAG_BROTLI)
	get_tree().quit(_fails)


## One connection per compression preference: the preference is sent in the
## handshake, so switching it means a new socket.
func _capture(
	preference: SpacetimeDBConnection.CompressionPreference,
	path: String,
	want_tag: int,
) -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = preference
	options.one_time_token = true
	options.save_token = false
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)
	await SpacetimeDB.Blackholio.connected

	# The world is empty right after publish.sh's --delete-data, so wait for the
	# scheduled food spawner to seed enough rows to cross the compression
	# threshold. Without this the server sends the snapshot uncompressed and the
	# fixture silently proves nothing.
	await get_tree().create_timer(5.0).timeout

	_file = FileAccess.open(path, FileAccess.WRITE)
	SpacetimeDB.Blackholio._connection.message_received.connect(_on_packet)
	var sub: SpacetimeDBSubscription = SpacetimeDB.Blackholio.subscribe(_queries)
	await sub.wait_for_applied(20.0)
	await get_tree().create_timer(0.5).timeout

	SpacetimeDB.Blackholio._connection.message_received.disconnect(_on_packet)
	_file.close()
	_file = null
	SpacetimeDB.Blackholio.disconnect_db()
	await get_tree().create_timer(1.0).timeout
	_verify(path, want_tag)


## A capture that came back uncompressed is worse than none: it looks like
## coverage and asserts nothing about the decompress path. Delete it and say so.
func _verify(path: String, want_tag: int) -> void:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	var compressed: bool = false
	if bytes.size() > 5:
		compressed = bytes.decode_u8(4) == want_tag and bytes.size() >= MIN_USEFUL_BYTES

	if compressed:
		print("[capture] %s: %d bytes, tag %d" % [path, bytes.size(), want_tag])
		return

	printerr(
		"[capture] %s carries no compressed frame (tag %d, %d bytes) — the world may "
		% [path, want_tag, bytes.size()]
		+ "not have grown past the server's 1 KiB threshold yet. Discarded."
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_fails += 1


func _on_packet(bytes: PackedByteArray) -> void:
	if _file == null:
		return
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)
