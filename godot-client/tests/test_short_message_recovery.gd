# A packet that does not end on a message boundary must not cost the packets after it.
#
# The framing loop used to file a read that ran off the end of the buffer as an
# "incomplete trailing message": it cleared the error and kept the tail, expecting the
# rest to arrive in a later packet. Nothing ever sends it — ws v3 says a payload carries
# one or more WHOLE consecutive ServerMessages (client-api-messages/src/websocket/v3.rs),
# so a short packet is a truncated one and its continuation is not coming — and the kept
# bytes only ever prefixed the NEXT packet with bytes belonging to nothing.
#
# Measured on the old code with a real client on a real socket
# (tests/_probe_truncated_frame.gd): one capture frame cut a byte short delivered 0 of
# the 40 transaction updates that followed it, for the rest of the session, while
# has_error() stayed false and the carried buffer grew by the size of every packet.
# A shorter cut was worse in a quieter way: 25 of 40 arrived, so the mirror was
# silently missing a third of the traffic.
#
# What this pins is the contract that replaced it: the packet is where a message lives
# or dies. A short read is reported, the rest of that packet goes with it, and the next
# packet is parsed on its own terms.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_short_message_recovery.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/wire_snapshot.bin"
const BROADCAST_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
## Healthy packets fed after a corrupt one.
const HEALTHY_PACKETS: int = 20
## Short packets fed in a row before them. Odd — see the run test.
const SHORT_PACKETS: int = 21

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_short_packet_is_reported()
	f += _test_next_packet_is_whole()
	f += _test_every_cut_recovers()
	f += _test_repeated_short_packets_accumulate_nothing()
	f += _test_messages_before_the_short_one_survive()
	f += _test_trailing_garbage_is_not_carried()
	f += _test_session_boundary_clears_the_error()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _new_deserializer() -> BSATNDeserializer:
	return BSATNDeserializer.new(SpacetimeDBSchema.new("Blackholio"), false)


# The old path cleared the error before returning, so a caller checking has_error()
# could not tell a short packet from a clean one. That is what made the wedge silent.
func _test_short_packet_is_reported() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(FIXTURE)
	var deserializer: BSATNDeserializer = _new_deserializer()
	var messages: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(payload.slice(0, payload.size() - 1))
	)
	f += _check_i("a short packet yields no message", messages.size(), 0)
	f += _check_b("and says so", deserializer.has_error(), true)
	# NEEDS_MORE rather than ERROR: the reader still distinguishes "ran off the end"
	# from "malformed", which is what the diagnostic is built from. Only the framing
	# loop's answer to the two is the same now. Cutting the LAST byte is what makes
	# this deterministic — the read that runs short is the final field's, so no length
	# prefix is mangled into a value that would come back ERROR instead.
	f += _check_i(
		"filed as a short read, not a malformed one",
		deserializer._status,
		BSATNDeserializer.ParseStatus.NEEDS_MORE,
	)
	f += _check_b("with a message behind it", deserializer.get_last_error().is_empty(), false)
	return f


# The whole of the bug: what the packet AFTER the short one is worth.
func _test_next_packet_is_whole() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(BROADCAST_FIXTURE)
	var whole: int = _offline_count(payload)
	f += _check_b("the capture carries messages", whole > 0, true)

	var deserializer: BSATNDeserializer = _new_deserializer()
	deserializer.process_bytes_and_extract_messages(payload.slice(0, payload.size() - 1))
	deserializer.clear_error()
	var after: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(payload)
	)
	f += _check_i("the next packet is parsed in full", after.size(), whole)
	f += _check_b("and raises nothing of its own", deserializer.has_error(), false)
	return f


# Not one cut in particular: EVERY prefix of a real capture has to leave the parser able
# to read the next packet whole. The old code failed 39 of the 131 cuts of this fixture
# outright and delivered short counts on 113 of them.
func _test_every_cut_recovers() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(FIXTURE)
	var whole: int = _offline_count(payload)
	var short_after: int = 0
	var carried: int = 0
	for cut: int in range(1, payload.size()):
		var deserializer: BSATNDeserializer = _new_deserializer()
		deserializer.process_bytes_and_extract_messages(payload.slice(0, cut))
		deserializer.clear_error()
		if deserializer.process_bytes_and_extract_messages(payload).size() != whole:
			short_after += 1
		deserializer.clear_error()
		# Twice over: a carry-over that survives one packet would show up here as the
		# second healthy packet coming back short as well.
		if deserializer.process_bytes_and_extract_messages(payload).size() != whole:
			carried += 1
		deserializer.clear_error()
	f += _check_i("no cut costs the next packet a message", short_after, 0)
	f += _check_i("no cut costs the packet after that one either", carried, 0)
	return f


# A run of short packets must leave the parser exactly where one does. The count is ODD
# on purpose: on the old code the carried tail alternated (a retained prefix plus the
# next short packet parsed as one message and cleared, the packet after that retained
# again), so an even run ended clean and this passed for the wrong reason.
func _test_repeated_short_packets_accumulate_nothing() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(BROADCAST_FIXTURE)
	var whole: int = _offline_count(payload)
	var deserializer: BSATNDeserializer = _new_deserializer()
	for _i: int in SHORT_PACKETS:
		deserializer.process_bytes_and_extract_messages(payload.slice(0, payload.size() - 1))
		deserializer.clear_error()
	var delivered: int = 0
	for _i: int in HEALTHY_PACKETS:
		delivered += deserializer.process_bytes_and_extract_messages(payload).size()
		deserializer.clear_error()
	f += _check_i(
		"healthy packets after a run of short ones all arrive",
		delivered,
		HEALTHY_PACKETS * whole,
	)
	return f


# The failure is at one message, not at the packet: v3 framing packs several messages
# into one packet, and the ones read before the short tail are whole.
func _test_messages_before_the_short_one_survive() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(FIXTURE)
	var whole: int = _offline_count(payload)
	var spliced: PackedByteArray = payload.duplicate()
	spliced.append_array(payload.slice(0, payload.size() - 1))

	var deserializer: BSATNDeserializer = _new_deserializer()
	var messages: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(spliced)
	)
	f += _check_i("the complete messages came back", messages.size(), whole)
	f += _check_b("and the short tail is still reported", deserializer.has_error(), true)
	return f


# The same contract from the other side: bytes the parser never got to are dropped with
# the packet that carried them, not saved for the next one.
func _test_trailing_garbage_is_not_carried() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(FIXTURE)
	var whole: int = _offline_count(payload)
	var with_tail: PackedByteArray = payload.duplicate()
	# A tag byte the parser recognises, then one byte of a message that needs many.
	with_tail.append(SpacetimeDBServerMessage.Type.INITIAL_CONNECTION)
	with_tail.append(0x01)

	var deserializer: BSATNDeserializer = _new_deserializer()
	deserializer.process_bytes_and_extract_messages(with_tail)
	deserializer.clear_error()
	f += _check_i(
		"the packet after a trailing stub is whole",
		deserializer.process_bytes_and_extract_messages(payload).size(),
		whole,
	)
	return f


# A short packet now leaves the error set rather than clearing it, which is exactly what
# the session boundary has to wipe: the new session must not be judged by the dying
# one's last packet.
func _test_session_boundary_clears_the_error() -> int:
	var f: int = 0
	var payload: PackedByteArray = _payload(FIXTURE)
	var deserializer: BSATNDeserializer = _new_deserializer()
	deserializer.process_bytes_and_extract_messages(payload.slice(0, payload.size() - 1))
	# The discriminating half is the setup: on the old code the short packet cleared its
	# own error, so there was nothing for the boundary to clear.
	f += _check_b("setup: the short packet is still reported", deserializer.has_error(), true)
	deserializer.reset_stream_state()
	f += _check_b("and the session boundary clears it", deserializer.has_error(), false)
	return f

# --- helpers ---


# The oracle every count assertion is measured against. It fails LOUD rather than
# quietly shrinking: swallowing its own error would let a fixture that stopped parsing
# clean drag every expectation down with it, and the tests would still pass.
func _offline_count(payload: PackedByteArray) -> int:
	var deserializer: BSATNDeserializer = _new_deserializer()
	var count: int = deserializer.process_bytes_and_extract_messages(payload).size()
	if deserializer.has_error():
		printerr(
			"ORACLE BROKEN: the intact fixture does not parse clean — %s"
			% (deserializer.get_last_error())
		)
		return -1
	return count


# The capture's frames concatenated with their compression tag bytes stripped, i.e. what
# the client hands the parser for one packet.
func _payload(path: String) -> PackedByteArray:
	var out: PackedByteArray = []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while file.get_position() < file.get_length():
		var size: int = file.get_32()
		out.append_array(file.get_buffer(size).slice(1))
	file.close()
	return out


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s (%d)" % [label, got])
		return 0
	printerr("FAIL  %s — got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
