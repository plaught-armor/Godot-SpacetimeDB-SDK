# Probe: two live clients in one process.
#
# Every socket-level probe so far drove ONE client. A game with two module clients (or
# one module and two databases — a lobby and a match) runs two of everything: two
# deserializer worker threads, two local databases, two stats trackers, and one shared
# set of process-global statics underneath them (the Brotli sizing state in
# DataDecompressor, the per-Script column cache in LocalDatabase).
#
# Both clients are driven at once from real sockets, one on Brotli frames and one on
# uncompressed frames, and the questions are: does either client's traffic reach the
# other's mirror, does either worker thread corrupt what the other decodes, and does
# tearing one down disturb the other.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_multi_module.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const PLAIN_FIXTURE: String = "res://tests/fixtures/wire_snapshot.bin"
const BROTLI_FIXTURE: String = "res://tests/fixtures/wire_snapshot_brotli.bin"
const MAX_WAIT_FRAMES: int = 900
const COPIES: int = 40

var _total: int = 0
var _fails: int = 0
var _server: TCPServer = TCPServer.new()
## Every side stood up so far — the settle loop polls each one's peer, since a
## WebSocketPeer only moves bytes when it is polled.
var _sides: Array[_Side] = []


## One client plus the server side of its socket.
class _Side:
	extends RefCounted

	var client: SpacetimeDBClient
	var peer: WebSocketPeer
	var stream: StreamPeerTCP
	var connected: int = 0


	func send(frames: Array[PackedByteArray], copies: int) -> void:
		# Polled per copy, not once at the end: a WebSocketPeer's outbound queue is
		# bounded by packet COUNT as well as bytes, and a burst that overruns it is
		# dropped silently — which would read here as "the SDK lost them".
		for _i: int in copies:
			for frame: PackedByteArray in frames:
				peer.put_packet(frame)
			peer.poll()


	func _on_connected(_identity: PackedByteArray, _token: String) -> void:
		connected += 1


	func rows(table: StringName) -> int:
		var db: LocalDatabase = client.get_local_database()
		if db == null:
			return -1
		return db.get_all_rows(table).size()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		quit(1)
		return

	var a: _Side = await _stand_up("A")
	var b: _Side = await _stand_up("B")
	if a == null or b == null:
		printerr("could not stand up both clients")
		quit(1)
		return
	_check("A handshook once", a.connected, 1)
	_check("B handshook once", b.connected, 1)
	# The whole point is two independent stacks: without these, a build that quietly
	# fell back to one shared database or to main-thread decoding would still pass
	# every row assertion below.
	_check("A has its own deserializer thread", 1 if a.client.deserializer_worker != null else 0, 1)
	_check("B has its own deserializer thread", 1 if b.client.deserializer_worker != null else 0, 1)
	_check(
		"the two clients hold different databases",
		1 if a.client.get_local_database() != b.client.get_local_database() else 0,
		1,
	)

	# Order matters: each scenario builds on the mirrors the previous one filled, and
	# the Brotli scenario deliberately runs against an already-converged sizing ratio
	# which it resets itself. Reordering these changes what they assert.
	await _scenario_isolation(a, b)
	await _scenario_concurrent_decode(a, b)
	await _scenario_brotli_contention(a, b)
	await _scenario_one_disconnects(a, b)

	_tear_down(a)
	_tear_down(b)
	_server.stop()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


# A's rows must land in A's mirror and nowhere else.
func _scenario_isolation(a: _Side, b: _Side) -> void:
	var frames: Array[PackedByteArray] = _load_frames(PLAIN_FIXTURE)
	a.send(frames, 1)
	await _settle()
	_check("A holds the config row", a.rows(&"config"), 1)
	_check("B's mirror is untouched", b.rows(&"config"), 0)


# Both worker threads decode at once, one of them Brotli — the shared sizing state in
# DataDecompressor is what this is really aimed at.
func _scenario_concurrent_decode(a: _Side, b: _Side) -> void:
	var plain: Array[PackedByteArray] = _load_frames(PLAIN_FIXTURE)
	var brotli: Array[PackedByteArray] = _load_frames(BROTLI_FIXTURE)
	if brotli.is_empty():
		printerr("no brotli fixture frames")
		_fails += 1
		_total += 1
		return
	# Interleaved on purpose: both sockets carry traffic in the same frame, so the two
	# deserializer threads are decoding at the same time.
	for _i: int in COPIES:
		a.send(plain, 1)
		b.send(brotli, 1)
	await _settle()
	# Both captures are snapshots, so re-delivery is refcounted rather than duplicated.
	# They cover different tables: the plain capture is `config`, the Brotli one is the
	# `entity` snapshot (see tests/test_wire_fixture_decode.gd), which is what makes the
	# cross-talk question answerable at all.
	_check("A still holds exactly its row", a.rows(&"config"), 1)
	# Counted against the SDK's own offline parse of the same bytes, not against a
	# "greater than zero" that a truncating decoder would also satisfy.
	_check(
		"B decoded every entity row the capture carries",
		b.rows(&"entity"),
		_expected_entity_rows(),
	)
	# A's own capture carries one entity row, so the question is whether B's much larger
	# entity snapshot leaked into it: A stays at exactly the one row it was sent.
	_check("A's entity table untouched by B's traffic", a.rows(&"entity"), 1)
	_check("B holds its own, larger entity snapshot", 1 if b.rows(&"entity") > 1 else 0, 1)
	_check("B's snapshot is still whole", b.rows(&"entity"), _expected_entity_rows())
	_check("B never saw A's config row", b.rows(&"config"), 0)
	_check("A's identity survived", a.client.get_local_identity().size(), 32)
	_check("B's identity survived", b.client.get_local_identity().size(), 32)


# Both worker threads on Brotli at once — the only configuration in which the
# process-global sizing state in DataDecompressor is touched by two threads. What that
# proves and what it does not is spelled out at the reset below.
func _scenario_brotli_contention(a: _Side, b: _Side) -> void:
	var brotli: Array[PackedByteArray] = _load_frames(BROTLI_FIXTURE)
	# Reset to the guess so both threads at least READ the shared value while the other
	# is in the decoder.
	#
	# What this canNOT reach, stated plainly: the value is only WRITTEN when a first
	# attempt undershoots, and the first attempt is floored at _BROTLI_MIN_ATTEMPT
	# (64 KiB), so only a frame that expands past 64 KiB can make it ratchet. Every
	# committed fixture is far smaller — forcing the ratio to 1 still produced zero
	# retries, measured — and Godot ships a Brotli decoder but no encoder, so a bigger
	# frame cannot be built here. The write path under contention is therefore
	# unexercised by this probe; it would take a capture from a module whose snapshot
	# clears 64 KiB decompressed.
	DataDecompressor._brotli_learned_ratio = DataDecompressor._BROTLI_SIZE_GUESS
	var retries_before: int = DataDecompressor._brotli_retries
	var a_before: int = a.rows(&"entity")
	for _i: int in COPIES:
		a.send(brotli, 1)
		b.send(brotli, 1)
	await _settle()
	var retries: int = DataDecompressor._brotli_retries - retries_before
	print("       first-attempt retries across %d Brotli frames: %d" % [COPIES * 2, retries])
	_check("A decoded the contended Brotli snapshot", 1 if a.rows(&"entity") > a_before else 0, 1)
	_check("B kept its rows", 1 if b.rows(&"entity") > 1 else 0, 1)
	# The ratio only ratchets upward, so once it has converged no further frame of the
	# same shape may retry — a racing pair that clobbered it would keep retrying.
	# With both threads reading the shared value mid-decode, the frames still decode and
	# nothing thrashes.
	_check("no first-attempt thrashing while both threads decode", 1 if retries <= 4 else 0, 1)


# Tearing one client down must leave the other's socket and mirror alone.
func _scenario_one_disconnects(a: _Side, b: _Side) -> void:
	a.client.disconnect_db()
	await _settle()
	_check("B is still connected", 1 if b.client.is_connected_db() else 0, 1)
	var frames: Array[PackedByteArray] = _load_frames(BROTLI_FIXTURE)
	b.send(frames, 1)
	await _settle()
	_check("B still applies traffic", 1 if b.rows(&"entity") > 0 else 0, 1)

# --- harness ---


func _stand_up(label: String) -> _Side:
	var side: _Side = _Side.new()
	_sides.append(side)
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.threading = true
	options.auto_reconnect = false
	options.one_time_token = false
	options.token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
	options.save_token = false

	side.client = SpacetimeDBClient.new()
	side.client.module_name = "Blackholio"
	side.client.auto_connect = false
	side.client.name = "MultiProbeClient%s" % label
	root.add_child(side.client)
	side.client.connected.connect(side._on_connected)
	side.client.connect_db(
		"http://127.0.0.1:%d" % _server.get_local_port(),
		"probedb%s" % label.to_lower(),
		options,
	)

	var identity_sent: bool = false
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		_poll_peers()
		if side.peer == null and _server.is_connection_available():
			side.stream = _server.take_connection()
			side.peer = WebSocketPeer.new()
			side.peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			side.peer.outbound_buffer_size = 8 * 1024 * 1024
			if side.peer.accept_stream(side.stream) != OK:
				printerr("accept_stream failed for %s" % label)
				return null
		if side.peer == null:
			continue
		side.peer.poll()
		if side.peer.get_ready_state() == WebSocketPeer.STATE_OPEN and not identity_sent:
			# Once: the connected counter only flips after the client has drained the
			# message, so gating on it would put several copies on the wire first.
			identity_sent = true
			for frame: PackedByteArray in _load_frames(IDENTITY_FIXTURE):
				side.peer.put_packet(frame)
			side.peer.poll()
		if side.connected > 0 and side.client.is_connected_db():
			return side
	return null


## Lets both sides' traffic finish crossing: the client drains a bounded number of
## messages per frame, so a burst needs frames, not just a poll.
func _settle() -> void:
	for _i: int in 90:
		await physics_frame
		_poll_peers()


## A WebSocketPeer moves bytes only while it is polled, so a burst that is put on the
## wire in one frame still needs the server side pumped for the frames that follow.
func _poll_peers() -> void:
	for side: _Side in _sides:
		if side.peer != null:
			side.peer.poll()


func _tear_down(side: _Side) -> void:
	if side == null:
		return
	if is_instance_valid(side.client):
		side.client.disconnect_db()
		side.client.queue_free()
	if side.stream != null:
		side.stream.disconnect_from_host()


## The entity rows the Brotli capture actually carries, decoded offline by the SDK's own
## deserializer — the oracle the live counts are compared against.
func _expected_entity_rows() -> int:
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	var rows: int = 0
	for frame: PackedByteArray in _load_frames(BROTLI_FIXTURE):
		var payload: PackedByteArray = DataDecompressor.decompress_brotli(frame.slice(1))
		for message: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			payload
		):
			if message is not SubscribeAppliedMessage:
				continue
			for table: TableUpdateData in (message as SubscribeAppliedMessage).tables:
				if table.table_name == &"entity":
					rows += table.inserts.size()
	return rows


func _load_frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while file.get_position() < file.get_length():
		var size: int = file.get_32()
		out.append(file.get_buffer(size))
	file.close()
	return out


func _check(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	_fails += 1
