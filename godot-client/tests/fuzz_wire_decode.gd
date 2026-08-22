# Mutation fuzzer over the captured wire frames. Not part of the suite — a hunting
# tool. Every mutation is a byte sequence the SDK could be handed by a hostile or
# broken server, so the decoder must set its error flag rather than crash, hang, or
# allocate without bound.
#
#   cd godot-client && timeout 300 <godot> --headless --path . \
#       --script tests/fuzz_wire_decode.gd
#
# The mutation stream is seeded, so a bare run reproduces the same cases every time —
# right for confirming a fix, useless for finding anything new. Set STDB_FUZZ_SEED to an
# integer to walk fresh ground; the seed actually used is printed, so a run that finds
# something can be replayed exactly.
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
const MAX_COMPRESSED_CASES_PER_FRAME: int = 64
const MAX_RECOMPRESSED_CASES_PER_FRAME: int = 24
# Captures of the same subscription the uncompressed fixture holds, so a mutation that
# still inflates produces bytes the reader will genuinely try to parse.
## A plain `var`, never `const` — a const Packed*Array reads back wrong (C1, #88753).
## No `make_read_only()` either: that is an `Array`/`Dictionary` API, and
## `Packed*Array` does not have it (C2a does not reach this type).
static var COMPRESSED_FIXTURES: PackedStringArray = [
	"wire_snapshot_gzip.bin",
	"wire_snapshot_brotli.bin",
]
# Compression tags as the server writes them (ws_common::SERVER_MSG_COMPRESSION_TAG_*).
const TAG_NONE: int = 0
const TAG_BROTLI: int = 1
const TAG_GZIP: int = 2
# Anything past this from a ~7 KiB capture means a mutation hit the decoder's own
# length fields, which is worth seeing even when it stays under the 128 MiB cap.
const MAX_SANE_OUTPUT: int = 8 * 1024 * 1024

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Built once: the schema is read-only here, and its constructor walks the generated
# scripts. Rebuilding it per case cost more than every decode in the run combined.
var _schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
var _cases: int = 0
var _errors_flagged: int = 0
var _clean_decodes: int = 0
var _decompressed: int = 0
var _decompress_empty: int = 0


# STDB_FUZZ_SEED overrides the built-in seed. `is_valid_int` first: `to_int` answers 0 for
# anything unparseable, and silently fuzzing seed 0 after a typo would look like a run that
# covered new ground when it covered one fixed stream.
func _seed() -> int:
	var raw: String = OS.get_environment("STDB_FUZZ_SEED")
	if raw.is_valid_int():
		return raw.to_int()
	if not raw.is_empty():
		printerr('STDB_FUZZ_SEED="%s" is not an integer; using the built-in seed' % raw)
	return SEED


func _initialize() -> void:
	_rng.seed = _seed()
	var names: PackedStringArray = _fixture_names()
	print("fuzzing %d fixtures, seed %d" % [names.size(), _rng.seed])

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

	_fuzz_compressed()
	_fuzz_recompressed()

	print(
		"cases=%d error_flagged=%d decoded_without_error=%d"
		% [_cases, _errors_flagged, _clean_decodes]
	)
	print("decompressed=%d empty=%d" % [_decompressed, _decompress_empty])
	print("SURVIVED")
	quit(0)


## The other half of the receive path: the bytes reach `DataDecompressor` before the
## reader ever sees them, and a corrupt compressed frame is the cheapest thing for a
## hostile server to send — the decoder is Godot's, the size cap is ours, and a bomb
## or a truncated member has to end in an empty return rather than an allocation the
## game cannot survive. Mutations here deliberately include the compression tag byte,
## which selects the branch.
func _fuzz_compressed() -> void:
	for name: String in COMPRESSED_FIXTURES:
		var frames: Array[PackedByteArray] = _frames("%s/%s" % [FIXTURE_DIR, name])
		var frame_count: int = mini(frames.size(), MAX_FRAMES_PER_FIXTURE)
		for i: int in frame_count:
			var frame: PackedByteArray = frames[i]
			if frame.size() < 2:
				continue
			for _n: int in MAX_COMPRESSED_CASES_PER_FRAME:
				var mutated: PackedByteArray = frame.duplicate()
				var at: int = _rng.randi_range(0, mutated.size() - 1)
				var run: int = mini(_rng.randi_range(1, 16), mutated.size() - at)
				for k: int in run:
					mutated[at + k] = _rng.randi_range(0, 255)
				if _rng.randi_range(0, 3) == 0:
					mutated = mutated.slice(0, _rng.randi_range(1, mutated.size() - 1))
				_decompress_and_decode("%s#%d comp@%d+%d" % [name, i, at, run], mutated)


## The GZIP HALF of the arm above no longer reaches the BSATN reader (its brotli half
## still does): a mutation inside the deflate data shifts the inflated length, the ISIZE
## trailer stops matching, and `decompress_packet` refuses the frame — measured, 13 gzip
## payloads reached the reader when a truncated member was delivered with a warning, 0
## once it was refused. That half now measures what it should, that a corrupted member is
## refused without allocating, and none of the 13 was a payload a healthy server could
## send — but the reader lost its only gzip-path coverage, which is what this restores:
## mutate the PLAINTEXT and re-gzip it, so the frame is a legal member carrying hostile
## BSATN and the decode is measured rather than skipped.
func _fuzz_recompressed() -> void:
	for name: String in _fixture_names():
		var frames: Array[PackedByteArray] = _frames("%s/%s" % [FIXTURE_DIR, name])
		var frame_count: int = mini(frames.size(), MAX_FRAMES_PER_FIXTURE)
		for i: int in frame_count:
			var frame: PackedByteArray = frames[i]
			if frame.size() < 2 or frame[0] != TAG_NONE:
				continue # only the uncompressed captures carry bare BSATN to mutate
			for _n: int in MAX_RECOMPRESSED_CASES_PER_FRAME:
				var mutated: PackedByteArray = frame.slice(1)
				var at: int = _rng.randi_range(0, mutated.size() - 1)
				var run: int = mini(_rng.randi_range(1, 8), mutated.size() - at)
				for k: int in run:
					mutated[at + k] = _rng.randi_range(0, 255)
				var recompressed: PackedByteArray = _gzip(mutated)
				if recompressed.is_empty():
					continue
				var reframed: PackedByteArray = [TAG_GZIP]
				reframed.append_array(recompressed)
				_decompress_and_decode("%s#%d regzip@%d+%d" % [name, i, at, run], reframed)


# One shot: the StreamPeerGZIP drain form emits a ten-byte stub for input that does not
# compress well, and a mutated capture is exactly that kind of input — a stub would make
# every case here a decompressor refusal instead of the reader exercise it exists to be.
func _gzip(data: PackedByteArray) -> PackedByteArray:
	return data.compress(FileAccess.COMPRESSION_GZIP)


## Mirrors SpacetimeDBClient._decompress_and_parse: read the tag, run the matching
## decoder, then hand whatever came out to the reader. Deliberately NOT mirrored: the
## client's `raw_bytes.size() < 2` guard, since a sub-2-byte frame is the client's
## business and the callers here always pass a tag plus a payload.
func _decompress_and_decode(label: String, frame: PackedByteArray) -> void:
	_note(label)
	var tag: int = frame[0]
	var payload: PackedByteArray = frame.slice(1)
	if tag == TAG_BROTLI:
		payload = DataDecompressor.decompress_brotli(payload)
	elif tag == TAG_GZIP:
		payload = DataDecompressor.decompress_packet(payload)
	elif tag != TAG_NONE:
		return # the client drops an unknown tag without decoding
	if payload.is_empty():
		_decompress_empty += 1
		return
	_decompressed += 1
	if payload.size() > MAX_SANE_OUTPUT:
		printerr("%s: decompressed to %d bytes" % [label, payload.size()])
	_decode(label, payload)


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
