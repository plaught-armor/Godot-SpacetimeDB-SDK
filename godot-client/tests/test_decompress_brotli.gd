# A truncated Brotli frame must fail, not hang.
#
# `PackedByteArray.decompress_dynamic(..., COMPRESSION_BROTLI)` never returns on a
# stream it cannot finish: its growth loop (Godot `core/io/compression.cpp`) exits on
# BROTLI_DECODER_RESULT_SUCCESS or on passing the size cap, and a truncated stream
# reaches neither — Brotli keeps answering NEEDS_MORE_INPUT with no input left, the
# total output stops growing, so the cap is never passed and the buffer grows by
# 64 KiB (copying all of it each time) until the process dies. Measured on 4.8.dev
# with the cap as low as 1 MiB. Brotli is the server's default compression mode, so
# any client that enables compression is one corrupt frame away from that.
#
# `DataDecompressor.decompress_brotli` uses the bounded one-shot decoder instead,
# guessing an output size and doubling to the same ceiling. These cases pin both
# halves: real frames still decode, and a stream that cannot finish comes back empty
# in bounded time.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_decompress_brotli.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/wire_snapshot_brotli.bin"
# Generous: the bounded walk to the 128 MiB ceiling is well under a second here, and
# the failure this guards against is unbounded, not slow.
const HANG_BUDGET_MS: int = 20000
# 484 bytes of Brotli that decode to 2 MiB — a ratio far past the decoder's first
# guess, so it exercises the doubling retry.
const HIGH_RATIO_FIXTURE: String = "res://tests/fixtures/brotli_high_ratio.br"
const HIGH_RATIO_SIZE: int = 2 * 1024 * 1024
# 10 KB decoding to 340 KB — a 34x ratio, above the 8x cold-start guess and below the
# 64x clamp, which is where a row-heavy payload actually sits.
const MID_RATIO_FIXTURE: String = "res://tests/fixtures/brotli_mid_ratio.br"
const MID_RATIO_SIZE: int = 340000

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	var payload: PackedByteArray = _first_frame_payload()
	f += _check("fixture loaded", payload.is_empty(), false)
	if payload.is_empty():
		quit(f)
		return

	# Control: an intact frame decodes, and to the same bytes the streaming path
	# would have produced.
	var whole: PackedByteArray = DataDecompressor.decompress_brotli(payload)
	f += _check("intact frame decodes", whole.size() > 0, true)
	f += _check(
		"matches the reference decoder",
		whole == payload.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_BROTLI),
		true,
	)

	# A frame cut in half: the decoder can never finish it. This is the case that
	# used to hang.
	f += _bounded("half a frame", payload.slice(0, payload.size() / 2))
	# One byte short — the smallest possible truncation, and the likeliest.
	f += _bounded("one byte short", payload.slice(0, payload.size() - 1))
	# Only the header: too little to infer anything from.
	f += _bounded("first 8 bytes", payload.slice(0, 8))
	# Not Brotli at all.
	f += _bounded("garbage", PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))

	# Empty in, empty out, no decoder call at all.
	f += _check("empty input", DataDecompressor.decompress_brotli(PackedByteArray()).size(), 0)

	f += _high_ratio_frame_still_decodes()
	f += _learned_ratio_removes_the_retries()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## The bounded decoder has to size its output buffer up front, so it guesses from the
## compressed size and doubles on failure. A frame that compresses far harder than the
## guess is the case that walks that loop: `brotli_high_ratio.br` is 484 bytes and
## decodes to 2 MiB, five doublings past the first attempt. Without the retry it would
## come back empty, which the caller cannot tell from a corrupt frame — a legitimate
## payload would look like an attack.
func _high_ratio_frame_still_decodes() -> int:
	var file: FileAccess = FileAccess.open(HIGH_RATIO_FIXTURE, FileAccess.READ)
	if file == null:
		return _check("high-ratio fixture loaded", false, true)
	var compressed: PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	var start: int = Time.get_ticks_msec()
	var out: PackedByteArray = DataDecompressor.decompress_brotli(compressed)
	var elapsed: int = Time.get_ticks_msec() - start
	var f: int = _check("high-ratio: decodes to 2 MiB", out.size(), HIGH_RATIO_SIZE)
	f += _check(
		"high-ratio: ratio is past the first guess",
		out.size() > compressed.size() * 8,
		true,
	)
	f += _check("high-ratio: retries stay quick (%d ms)" % elapsed, elapsed < HANG_BUDGET_MS, true)
	# Content, not just length: a buffer that was resized but never filled would pass
	# a size check.
	if out.size() == HIGH_RATIO_SIZE:
		f += _check("high-ratio: first byte", out[0], 0)
		f += _check(
			"high-ratio: last byte",
			out[HIGH_RATIO_SIZE - 1],
			(2097151 * 7 + 2097151 / 251) % 256,
		)
	return f


## Each failed attempt prints an engine error (Godot reports the one-shot decoder's
## failure through `ERR_FAIL_COND_V`), so a game whose frames compress harder than the
## static guess would print one per frame forever. The decoder remembers the largest
## ratio that worked, so the second frame of a given shape guesses right.
##
## `brotli_mid_ratio.br` is 10 KB decoding to 340 KB — a 34x ratio, above the 8x
## starting guess and below the 64x clamp, which is where a real row-heavy payload
## sits. The first decode retries; the second must not.
func _learned_ratio_removes_the_retries() -> int:
	var file: FileAccess = FileAccess.open(MID_RATIO_FIXTURE, FileAccess.READ)
	if file == null:
		return _check("mid-ratio fixture loaded", false, true)
	var compressed: PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	DataDecompressor._brotli_learned_ratio = 8 # back to the cold-start guess
	var before: int = DataDecompressor._brotli_retries
	var first: PackedByteArray = DataDecompressor.decompress_brotli(compressed)
	var first_retries: int = DataDecompressor._brotli_retries - before

	var second: PackedByteArray = DataDecompressor.decompress_brotli(compressed)
	var second_retries: int = DataDecompressor._brotli_retries - before - first_retries

	var f: int = _check("mid-ratio decodes", first.size(), MID_RATIO_SIZE)
	f += _check("second decode matches the first", second == first, true)
	f += _check("cold start had to retry (%d)" % first_retries, first_retries > 0, true)
	f += _check("warm decode retries none", second_retries, 0)
	f += _check("learned ratio stays clamped", DataDecompressor._brotli_learned_ratio <= 64, true)
	return f


## Asserts the call returns empty AND returns at all. A regression here does not fail
## the assertion — it hangs the run — so `run_tests.sh`'s per-test timeout is the
## real backstop and this budget is the readable one.
func _bounded(label: String, bytes: PackedByteArray) -> int:
	var start: int = Time.get_ticks_msec()
	var out: PackedByteArray = DataDecompressor.decompress_brotli(bytes)
	var elapsed: int = Time.get_ticks_msec() - start
	var f: int = _check("%s: no output" % label, out.size(), 0)
	f += _check("%s: returned in %d ms" % [label, elapsed], elapsed < HANG_BUDGET_MS, true)
	return f


func _first_frame_payload() -> PackedByteArray:
	var file: FileAccess = FileAccess.open(FIXTURE, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var size: int = file.get_32()
	var frame: PackedByteArray = file.get_buffer(size)
	file.close()
	# Byte 0 is the compression tag the client strips before decoding.
	return frame.slice(1)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
