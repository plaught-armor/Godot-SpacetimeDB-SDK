# Mutation fuzzer over the captured wire frames. Not part of the suite — a hunting
# tool. Every mutation is a byte sequence the SDK could be handed by a hostile or
# broken server, so the decoder must set its error flag rather than crash, hang, or
# allocate without bound.
#
#   cd godot-client && timeout 300 <godot> --headless --path . \
#       --script tests/fuzz_wire_decode.gd
#
# Writes the case it is about to decode to user://fuzz_last_case.txt before decoding,
# so a hard crash still names the input that caused it.
extends SceneTree

const FIXTURE_DIR: String = "res://tests/fixtures"
const PROGRESS_PATH: String = "user://fuzz_last_case.txt"
const SEED: int = 0x5CA1AB1E
# Bounds (NASA rule 2): every loop below is capped by one of these.
const MAX_FIXTURES: int = 32
const MAX_FRAMES_PER_FIXTURE: int = 24
const MAX_FLIPS_PER_FRAME: int = 48
const MAX_TRUNCATIONS_PER_FRAME: int = 24
const MAX_SPLICES_PER_FRAME: int = 24

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Built once: the schema is read-only here, and its constructor walks the generated
# scripts. Rebuilding it per case cost more than every decode in the run combined.
var _schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
var _cases: int = 0
var _errors_flagged: int = 0
var _clean_decodes: int = 0


func _initialize() -> void:
	_rng.seed = SEED
	var names: PackedStringArray = _fixture_names()
	print("fuzzing %d fixtures" % names.size())

	for name: String in names:
		var frames: Array[PackedByteArray] = _frames("%s/%s" % [FIXTURE_DIR, name])
		var frame_count: int = mini(frames.size(), MAX_FRAMES_PER_FIXTURE)
		for i: int in frame_count:
			var frame: PackedByteArray = frames[i]
			if frame.size() < 2:
				continue
			# The client strips the compression tag before parsing; do the same, so
			# the fuzzer exercises the BSATN reader rather than the decompressor.
			var payload: PackedByteArray = frame.slice(1)
			_fuzz_flips(name, i, payload)
			_fuzz_truncations(name, i, payload)
			_fuzz_splices(name, i, payload)

	print(
		"cases=%d error_flagged=%d decoded_without_error=%d"
		% [_cases, _errors_flagged, _clean_decodes]
	)
	print("SURVIVED")
	quit(0)


func _fixture_names() -> PackedStringArray:
	var out: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(FIXTURE_DIR)
	if dir == null:
		printerr("cannot open %s" % FIXTURE_DIR)
		return out
	for name: String in dir.get_files():
		if out.size() >= MAX_FIXTURES:
			break
		if name.ends_with(".bin"):
			out.append(name)
	out.sort()
	return out


func _frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while f.get_position() < f.get_length():
		var size: int = f.get_32()
		if size <= 0 or size > f.get_length():
			break
		out.append(f.get_buffer(size))
	f.close()
	return out


## Single-byte corruption: the classic way a length prefix or a sum tag turns into
## something the reader was never written for.
func _fuzz_flips(fixture: String, frame_index: int, payload: PackedByteArray) -> void:
	for _n: int in MAX_FLIPS_PER_FRAME:
		var mutated: PackedByteArray = payload.duplicate()
		var at: int = _rng.randi_range(0, mutated.size() - 1)
		mutated[at] = _rng.randi_range(0, 255)
		_decode("%s#%d flip@%d=%d" % [fixture, frame_index, at, mutated[at]], mutated)


## Truncation: a short read must stop, not walk off the end of the buffer.
func _fuzz_truncations(fixture: String, frame_index: int, payload: PackedByteArray) -> void:
	for _n: int in MAX_TRUNCATIONS_PER_FRAME:
		var keep: int = _rng.randi_range(0, payload.size() - 1)
		_decode("%s#%d trunc@%d" % [fixture, frame_index, keep], payload.slice(0, keep))


## Splice: overwrite a run with garbage, which is how a corrupted length field ends
## up asking for a vector far larger than the bytes that follow it.
func _fuzz_splices(fixture: String, frame_index: int, payload: PackedByteArray) -> void:
	for _n: int in MAX_SPLICES_PER_FRAME:
		var mutated: PackedByteArray = payload.duplicate()
		var at: int = _rng.randi_range(0, mutated.size() - 1)
		var run: int = mini(_rng.randi_range(1, 8), mutated.size() - at)
		for k: int in run:
			mutated[at + k] = _rng.randi_range(0, 255)
		_decode("%s#%d splice@%d+%d" % [fixture, frame_index, at, run], mutated)


func _decode(label: String, bytes: PackedByteArray) -> void:
	_cases += 1
	_note(label)
	# A fresh deserializer per case: a sticky error from the previous mutation would
	# otherwise mask whatever this one does.
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(_schema, false)
	var messages: Array[SpacetimeDBServerMessage] = (
		deserializer.process_bytes_and_extract_messages(bytes)
	)
	if deserializer.has_error():
		_errors_flagged += 1
	else:
		_clean_decodes += 1
	# Touch what came back: a message that decoded into a half-built resource should
	# fail here rather than in a game's callback.
	for msg: SpacetimeDBServerMessage in messages:
		var _spelled: String = msg.get_class()


func _note(label: String) -> void:
	var f: FileAccess = FileAccess.open(PROGRESS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("%d %s\n" % [_cases, label])
	f.close()
