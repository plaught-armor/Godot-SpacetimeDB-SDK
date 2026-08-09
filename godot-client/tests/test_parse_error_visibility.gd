# A parse failure that drops the buffered stream has to stay visible to the caller.
#
# `process_bytes_and_extract_messages()` abandons the rest of the packet when a message
# is malformed, and `SpacetimeDBClient._parse_packet_and_get_resource()` checks
# `has_error()` right after the call to decide whether to discard the batch. That
# check only works if the error survives the function that reported it —
# `get_last_error()` clears the state as a side effect of reading it, so logging the
# failure through it left the deserializer looking like it had parsed cleanly.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_parse_error_visibility.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/wire_snapshot.bin"
# No server message uses tag 0xFF, so this is the shortest fatal input there is.
const UNKNOWN_TAG: int = 0xFF

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _unknown_tag_is_visible()
	f += _error_does_not_stick_to_the_next_packet()
	f += _empty_packet_does_not_report_a_stale_error()
	f += _messages_before_the_bad_one_survive()
	f += _real_frames_still_parse_clean()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _new_deserializer() -> BSATNDeserializer:
	return BSATNDeserializer.new(SpacetimeDBSchema.new("Blackholio"), false)


func _unknown_tag_is_visible() -> int:
	var f: int = 0
	var deserializer: BSATNDeserializer = _new_deserializer()
	var messages: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(PackedByteArray([UNKNOWN_TAG]))
	)
	f += _check("no messages from a bad tag", messages.size(), 0)
	f += _check("has_error() survives the report", deserializer.has_error(), true)
	# Read the message last: get_last_error() is the documented consuming accessor.
	f += _check("the message names the tag", deserializer.get_last_error().contains(
			"Unknown server message type"
		), true)
	f += _check("consuming the message clears it", deserializer.has_error(), false)
	return f


func _error_does_not_stick_to_the_next_packet() -> int:
	var f: int = 0
	var deserializer: BSATNDeserializer = _new_deserializer()
	deserializer.process_bytes_and_extract_messages(PackedByteArray([UNKNOWN_TAG]))
	f += _check("errored on the bad packet", deserializer.has_error(), true)

	# The failure dropped the buffer, so the next packet starts clean. Without this,
	# a single corrupt frame would make every later frame look corrupt too.
	var frames: Array[PackedByteArray] = _frames(FIXTURE)
	if frames.is_empty():
		return f + _check("fixture has frames", false, true)
	deserializer.process_bytes_and_extract_messages(frames[0].slice(1))
	f += _check("next good packet parses clean", deserializer.has_error(), false)
	return f


## An empty packet returns ahead of the parse loop, so it never reaches the
## `clear_error()` that normally resets the state between calls. Without an explicit
## clear on that path, an unconsumed error would be reported against a call that read
## nothing.
func _empty_packet_does_not_report_a_stale_error() -> int:
	var f: int = 0
	var deserializer: BSATNDeserializer = _new_deserializer()
	deserializer.process_bytes_and_extract_messages(PackedByteArray([UNKNOWN_TAG]))
	f += _check("errored on the bad packet", deserializer.has_error(), true)
	var messages: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(PackedByteArray())
	)
	f += _check("empty packet yields nothing", messages.size(), 0)
	f += _check("empty packet reports no error", deserializer.has_error(), false)
	return f


## The failure is at one message, not at the packet. Everything read before it is
## whole and has to reach the client — dropping it would turn one corrupt message
## into a lost batch.
func _messages_before_the_bad_one_survive() -> int:
	var f: int = 0
	var frames: Array[PackedByteArray] = _frames(FIXTURE)
	if frames.is_empty():
		return _check("fixture has frames", false, true)

	# One real frame, then a byte no message tag uses.
	var payload: PackedByteArray = frames[0].slice(1)
	var spliced: PackedByteArray = payload.duplicate()
	spliced.append(UNKNOWN_TAG)

	var deserializer: BSATNDeserializer = _new_deserializer()
	var messages: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(spliced)
	)
	f += _check("the good message came back", messages.size() > 0, true)
	f += _check("and the failure is still visible", deserializer.has_error(), true)
	return f


func _real_frames_still_parse_clean() -> int:
	var f: int = 0
	var frames: Array[PackedByteArray] = _frames(FIXTURE)
	if frames.is_empty():
		return _check("fixture has frames", false, true)

	var deserializer: BSATNDeserializer = _new_deserializer()
	var count: int = 0
	for frame: PackedByteArray in frames:
		# Byte 0 is the compression tag; the capture used NONE.
		count += deserializer.process_bytes_and_extract_messages(frame.slice(1)).size()
	f += _check("captured frames decode", count > 0, true)
	f += _check("captured frames raise no error", deserializer.has_error(), false)
	return f


func _frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while file.get_position() < file.get_length():
		var size: int = file.get_32()
		out.append(file.get_buffer(size))
	file.close()
	return out


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
