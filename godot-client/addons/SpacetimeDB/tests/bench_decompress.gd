# Benchmark: gzip decompression chunk_size + input-feeding strategy in
# DataDecompressor.decompress_packet. Picks a chunk_size and tests whether
# feeding the whole compressed payload via put_data (no per-iteration input
# slice) beats the current slice-per-iteration loop.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/bench_decompress.gd
extends SceneTree

const REPS: int = 50
const SIZES: Array[int] = [4096, 16384, 65536, 262144, 1048576]


func _initialize() -> void:
	for payload_size: int in [16384, 262144, 1048576]:
		var compressed: PackedByteArray = _gzip(_make_payload(payload_size))
		print("--- payload %d B → compressed %d B ---" % [payload_size, compressed.size()])
		# Validate correctness once.
		var ref: PackedByteArray = _decompress_chunked(compressed, 4096)
		if ref.size() != payload_size:
			printerr("DECOMPRESS MISMATCH: got %d want %d" % [ref.size(), payload_size])
		for cs: int in SIZES:
			var us: int = _best(_decompress_chunked.bind(compressed, cs))
			print("  chunked   chunk=%7d : %6.1f us" % [cs, us])
		var us_pd: int = _best(_decompress_putdata.bind(compressed, 65536))
		# put_data is NOT correct here: feeding all input at once lets the decoder
		# overrun the stream's output buffer, dropping data when the decompressed
		# size exceeds it. The apparent speedup is an artifact of an early-bailing,
		# incomplete decode — always validate output before trusting a time.
		var pd_out: PackedByteArray = _decompress_putdata(compressed, 65536)
		var pd_ok: String = "OK" if pd_out.size() == payload_size else "WRONG (got %d/%d — incomplete decode)" % [pd_out.size(), payload_size]
		print("  put_data  (out=65536)   : %6.1f us  [%s]" % [us_pd, pd_ok])
	quit(0)


# Semi-compressible payload: repeating-ish but with variation.
func _make_payload(n: int) -> PackedByteArray:
	var p: PackedByteArray = PackedByteArray()
	p.resize(n)
	for i: int in n:
		p[i] = (i * 31 + (i >> 5)) & 0xFF
	return p


func _gzip(data: PackedByteArray) -> PackedByteArray:
	var s: StreamPeerGZIP = StreamPeerGZIP.new()
	s.start_compression()
	s.put_data(data)
	s.finish()
	var out: PackedByteArray = PackedByteArray()
	while true:
		var r: Array = s.get_partial_data(65536)
		if r[0] != OK or (r[1] as PackedByteArray).is_empty():
			break
		out.append_array(r[1])
	return out


func _best(thunk: Callable) -> int:
	var best: int = 1 << 62
	for _r: int in REPS:
		var t0: int = Time.get_ticks_usec()
		var v: Variant = thunk.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best:
			best = dt
	return best


# Current strategy: slice the input per iteration.
func _decompress_chunked(compressed: PackedByteArray, chunk_size: int) -> PackedByteArray:
	var s: StreamPeerGZIP = StreamPeerGZIP.new()
	s.start_decompression()
	var pos: int = 0
	var out: PackedByteArray = PackedByteArray()
	while true:
		var ir: Array = s.put_partial_data(compressed.slice(pos, pos + chunk_size))
		if ir[0] != OK:
			break
		pos += ir[1]
		var r: Array = s.get_partial_data(chunk_size)
		var status: Error = r[0]
		var chunk: PackedByteArray = r[1]
		if status == OK:
			if chunk.is_empty():
				break
			out.append_array(chunk)
		elif status == ERR_UNAVAILABLE:
			break
		else:
			return PackedByteArray()
	return out


# Candidate: feed all input once (put_data), then drain output.
func _decompress_putdata(compressed: PackedByteArray, out_chunk: int) -> PackedByteArray:
	var s: StreamPeerGZIP = StreamPeerGZIP.new()
	s.start_decompression()
	if s.put_data(compressed) != OK:
		return PackedByteArray()
	var out: PackedByteArray = PackedByteArray()
	while true:
		var r: Array = s.get_partial_data(out_chunk)
		var status: Error = r[0]
		var chunk: PackedByteArray = r[1]
		if status == OK:
			if chunk.is_empty():
				break
			out.append_array(chunk)
		elif status == ERR_UNAVAILABLE:
			break
		else:
			return PackedByteArray()
	return out
