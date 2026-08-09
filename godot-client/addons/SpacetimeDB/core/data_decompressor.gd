## Utility for decompressing Gzip- and Brotli-encoded WebSocket payloads.
##
## Used internally by [SpacetimeDBClient] when the server sends
## compressed BSATN packets.
class_name DataDecompressor
extends RefCounted

## Per-iteration size for feeding compressed input and draining decompressed
## output. Sized so a typical compressed packet is fed in a single slice and its
## output drained in one or two reads — benchmarked ~13% faster than 4 KiB on
## 1 MiB payloads, flat beyond this. The transient 64 KiB buffers are negligible.
const _CHUNK_SIZE: int = 65536

## Hard ceiling on decompressed output. Bounds the otherwise-unbounded decode loop
## (a valid stream can keep emitting output forever — a decompression bomb) and the
## Brotli grow buffer. Set far above any legitimate WS frame; hitting it means a
## malformed or hostile payload, not normal traffic.
const _MAX_DECOMPRESSED_SIZE: int = 128 * 1024 * 1024 # 128 MiB


## Decompresses a Gzip-encoded [param compressed_bytes] payload.[br]
## Returns an empty [PackedByteArray] on failure.
static func decompress_packet(compressed_bytes: PackedByteArray) -> PackedByteArray:
	if compressed_bytes.is_empty():
		return PackedByteArray()

	var gzip_stream: StreamPeerGZIP = StreamPeerGZIP.new()
	if gzip_stream.start_decompression() != OK:
		printerr("DataDecompressor Error: Failed to start Gzip decompression.")
		return PackedByteArray()

	var last_slice_position: int = 0
	var decompressed_data: PackedByteArray = PackedByteArray()
	var input_failed: bool = false

	# Explicitly bounded (NASA rule 2) rather than `while true`. The loop already ends
	# on drained input, on the size ceiling, or on a stream error, but that is
	# StreamPeerGZIP's semantics guaranteeing it, not this code — and the Brotli path
	# above is here precisely because a decoder's loop semantics did not hold. Each
	# pass moves at least one chunk of input or output, so the ceiling divided by the
	# chunk size is the most passes a legitimate stream can need.
	# Doubled rather than "+ 2": a maximal stream needs one pass per output chunk plus
	# one to see the drain, and `get_partial_data` may return short, so an exact budget
	# would reject a legitimate stream that read short even once. Doubling keeps the
	# margin proportional if the ceiling is ever raised.
	var max_passes: int = _MAX_DECOMPRESSED_SIZE / _CHUNK_SIZE * 2 + 2
	var drained: bool = false
	for _pass: int in max_passes:
		var input_result: Array = gzip_stream.put_partial_data(
			compressed_bytes.slice(last_slice_position, last_slice_position + _CHUNK_SIZE)
		)
		if input_result[0] != OK:
			printerr(
				"DataDecompressor Error: Failed to input partial data: "
				+ error_string(input_result[0])
			)
			input_failed = true
			break
		last_slice_position += input_result[1]
		var result: Array = gzip_stream.get_partial_data(_CHUNK_SIZE)
		var status: Error = result[0]
		var chunk: PackedByteArray = result[1]
		if status == OK:
			if chunk.is_empty():
				drained = true
				break
			decompressed_data.append_array(chunk)
			if decompressed_data.size() > _MAX_DECOMPRESSED_SIZE:
				printerr(
					"DataDecompressor Error: Decompressed output exceeds %d bytes — aborting (malformed or hostile stream)."
					% _MAX_DECOMPRESSED_SIZE
				)
				return PackedByteArray()
		elif status == ERR_UNAVAILABLE:
			drained = true
			break
		else:
			printerr("DataDecompressor Error: Failed while getting partial data.")
			return PackedByteArray()

	# An input failure means the stream broke partway: whatever inflated before it is
	# the front of a message whose tail is missing, and handing that to the reader is
	# strictly worse than admitting the frame is gone — it decodes as far as the cut
	# and then reports a corruption that belongs to this layer. Every other failure
	# path here returns empty; so does this one. The cause was already reported above,
	# and repeating it would misattribute it to the wire payload.
	if input_failed:
		return PackedByteArray()
	if not drained:
		# Fell out of the loop on the pass cap rather than on a drained stream, so the
		# output is a prefix, not a message. Same reasoning as the input-failure case:
		# returning it would hand the reader half a message.
		printerr(
			"DataDecompressor Error: gzip stream did not drain in %d passes — treating as malformed."
			% max_passes
		)
		return PackedByteArray()
	# Both remaining ways out are a partial payload, and both are refused rather than
	# delivered, which is the opposite of the policy one layer up (a packet that fails
	# mid-way still delivers the messages read before it). The difference: at this layer
	# a CUT member and a CORRUPTED one are indistinguishable. The only check that
	# separates them is the member's CRC32, computed at member end and swallowed by
	# StreamPeerGZIP — the same swallowing that makes the trailer heuristic below
	# necessary. Deflate's own structure catches most corruption — Godot runs inflate
	# inside put_partial_data, so it exits through THAT error branch above (measured: 40
	# of 40 mid-member corruptions of a valid member) — but a hit inside a stored block's
	# literals, or one that stays a valid Huffman decode, inflates into plausible-but-
	# wrong bytes that only the CRC would have caught, and those can parse as
	# structurally valid BSATN and land wrong values in the mirror. That residual is
	# reasoned, not reproduced. The parse layer's partial delivery is safe
	# because what it delivers was verified by the structure that parsed it; nothing
	# here can make that claim.
	if last_slice_position < compressed_bytes.size():
		# Input the decoder never consumed: everything past the first member's trailer.
		# The SpacetimeDB server writes exactly one gzip member per frame, so this is a
		# re-framing proxy or a corrupt payload, not traffic — and delivering member one
		# alone is a silent short read of a multi-member stream (measured: a 100 + 50
		# byte two-member stream delivered 100 bytes as a success).
		printerr(
			"DataDecompressor Error: %d compressed bytes left unconsumed after the gzip member — dropping the frame."
			% (compressed_bytes.size() - last_slice_position),
		)
		return PackedByteArray()
	if _is_truncated(compressed_bytes, decompressed_data.size()):
		return PackedByteArray()
	return decompressed_data


## Cross-checks decompressed output against the gzip ISIZE trailer. [code]true[/code]
## means the member did not inflate to the size it declares.[br]
## [br]
## A truncated gzip stream is otherwise silent: [StreamPeerGZIP] consumes every byte
## it was given, emits the partial output it managed to inflate, and reports no error
## — [method StreamPeerGZIP.finish] is compression-only and always returns
## [constant ERR_UNAVAILABLE] here. Without this check a short frame reaches the BSATN
## reader looking like a complete one. Only valid when the payload ends with its
## member trailer, so the caller rules out leftover input first.[br]
## [br]
## A HEURISTIC, not a checksum: for the case it exists to catch there IS no trailer,
## so the last four bytes are mid-deflate payload read as a size (a real refusal
## prints numbers like 3942414814 for that reason). It therefore misses a truncation
## roughly one time in 2^32, and a payload under four bytes — which inflates to
## nothing worth delivering anyway — is accepted rather than measured.
static func _is_truncated(compressed_bytes: PackedByteArray, decompressed_size: int) -> bool:
	if compressed_bytes.size() < 4:
		return false
	var declared_size: int = compressed_bytes.decode_u32(compressed_bytes.size() - 4)
	if declared_size == decompressed_size & 0xFFFFFFFF:
		return false
	printerr(
		"DataDecompressor Error: decompressed %d bytes but the gzip trailer declares %d — stream is truncated or corrupt, dropping the frame."
		% [decompressed_size, declared_size],
	)
	return true


## Starting output-size guess for a Brotli frame, as a multiple of the compressed
## size. Brotli on BSATN row data runs a few times over; overshooting costs one
## transient allocation, undershooting costs a retry, so this leans high.
const _BROTLI_SIZE_GUESS: int = 8

## Ceiling on the learned ratio. Keeps one freakishly compressible frame (or a bomb)
## from making every later frame allocate hundreds of times its own size.
const _BROTLI_MAX_LEARNED_RATIO: int = 64

## Ceiling on the FIRST attempt. The retry loop can still climb from here; this only
## stops the guess itself from allocating tens of MiB for a frame that never needed it.
const _BROTLI_MAX_FIRST_ATTEMPT: int = 8 * 1024 * 1024

## Largest expansion ratio seen to succeed this session, used to size the first
## attempt. Godot's one-shot decoder reports failure through `ERR_FAIL_COND_V`, so a
## retry is not just slower — it prints an engine error. A game whose rows compress
## harder than the static guess would print one on every single frame; learning the
## ratio means it pays that once and then guesses right. Never `const` — this is
## mutable state by design.
##
## Process-global, and in threaded mode it is read and written from a client's
## deserializer worker thread, so two clients decoding at once would race on it.
## Guarded by [member _brotli_state_mutex]: the lock is taken once per Brotli frame,
## which is nothing beside the decode it precedes (measured ~29 us for a 7 KiB frame).
## Only ratchets upward, so it never shrinks back after a burst of dense frames — the
## cost of that is a larger first allocation, bounded by
## [constant _BROTLI_MAX_FIRST_ATTEMPT].
static var _brotli_learned_ratio: int = _BROTLI_SIZE_GUESS

## Count of undersized first attempts this session. Each one is a wasted allocation
## and an engine error in the log, so a number that keeps climbing means the learned
## ratio is not converging — worth seeing rather than inferring from log noise.
static var _brotli_retries: int = 0

## Guards the two counters above against concurrent clients' worker threads.
static var _brotli_state_mutex: Mutex = Mutex.new()

## Smallest output buffer to try. Below this the guess is noise — a 200-byte frame
## would otherwise start at 1600 bytes and retry several times to reach a normal
## message size.
const _BROTLI_MIN_ATTEMPT: int = 64 * 1024

## Bound on the doubling loop (NASA rule 2). Twelve doublings from the minimum clear
## the 128 MiB ceiling, so this only ever stops a loop that should already have
## stopped at [constant _MAX_DECOMPRESSED_SIZE]. Coupled to
## [constant _BROTLI_MIN_ATTEMPT]: lowering that minimum without raising this count
## would make the counter, not the ceiling, end the loop — and a frame just under the
## ceiling would stop decoding.
const _BROTLI_MAX_ATTEMPTS: int = 12


## Decompresses a raw Brotli stream [param compressed_bytes].[br]
## Uses Godot's built-in Brotli decoder (Godot 4.x ships decode support).[br]
## Returns an empty [PackedByteArray] on failure.
##
## Deliberately NOT [method PackedByteArray.decompress_dynamic]: that one hangs
## forever on a truncated Brotli stream, which is exactly what a broken or hostile
## server sends. Its growth loop exits on [code]BROTLI_DECODER_RESULT_SUCCESS[/code]
## or on passing the size cap, and a truncated stream reaches neither — Brotli keeps
## answering [code]NEEDS_MORE_INPUT[/code] with no input left, so the total output
## stops growing, the cap is never passed, and the loop keeps extending the buffer by
## 64 KiB (copying all of it each time) until the process dies. Verified on 4.8.dev:
## a half-payload never returns, with the cap set as low as 1 MiB.
##
## [method PackedByteArray.decompress] is the one-shot decoder underneath
## ([code]BrotliDecoderDecompress[/code]) and fails immediately on a stream it cannot
## finish, but it needs the output size up front. So: guess from the compressed size,
## and double on failure up to the same ceiling. A truncated frame now costs a bounded
## walk to the ceiling instead of the process.
static func decompress_brotli(compressed_bytes: PackedByteArray) -> PackedByteArray:
	if compressed_bytes.is_empty():
		return PackedByteArray()

	_brotli_state_mutex.lock()
	var learned_ratio: int = _brotli_learned_ratio
	_brotli_state_mutex.unlock()

	var attempt: int = clampi(
		compressed_bytes.size() * learned_ratio,
		_BROTLI_MIN_ATTEMPT,
		_BROTLI_MAX_FIRST_ATTEMPT,
	)
	for _try: int in _BROTLI_MAX_ATTEMPTS:
		if attempt > _MAX_DECOMPRESSED_SIZE:
			attempt = _MAX_DECOMPRESSED_SIZE
		var out: PackedByteArray = compressed_bytes.decompress(
			attempt,
			FileAccess.COMPRESSION_BROTLI,
		)
		# Empty is treated as failure, which also swallows the case of a valid Brotli
		# frame that decodes to zero bytes — Godot's one-shot decoder reports both the
		# same way. No SpacetimeDB message is empty (every frame is a tagged BSATN
		# sum, and the client drops anything under two bytes before this is reached),
		# so the conflation costs nothing here.
		if not out.is_empty():
			# Remember what this frame actually needed, so the next one of its kind
			# guesses right on the first try and prints no engine error.
			var ratio: int = out.size() / maxi(compressed_bytes.size(), 1) + 1
			_brotli_state_mutex.lock()
			if ratio > _brotli_learned_ratio:
				_brotli_learned_ratio = mini(ratio, _BROTLI_MAX_LEARNED_RATIO)
			_brotli_state_mutex.unlock()
			return out
		# Empty means the decoder did not finish: either the buffer was too small, or
		# the stream is corrupt. The two are indistinguishable from here, so grow and
		# retry until the ceiling — at which point it was corrupt.
		if attempt >= _MAX_DECOMPRESSED_SIZE:
			break
		_brotli_state_mutex.lock()
		_brotli_retries += 1
		_brotli_state_mutex.unlock()
		attempt *= 2

	printerr("DataDecompressor Error: Brotli decompression failed or produced no output.")
	return PackedByteArray()
