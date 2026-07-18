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

	while true:
		var input_result: Array = gzip_stream.put_partial_data(compressed_bytes.slice(last_slice_position, last_slice_position + _CHUNK_SIZE))
		if input_result[0] != OK:
			printerr("DataDecompressor Error: Failed to input partial data: " + error_string(input_result[0]))
			input_failed = true
			break
		last_slice_position += input_result[1]
		var result: Array = gzip_stream.get_partial_data(_CHUNK_SIZE)
		var status: Error = result[0]
		var chunk: PackedByteArray = result[1]
		if status == OK:
			if chunk.is_empty():
				break
			decompressed_data.append_array(chunk)
			if decompressed_data.size() > _MAX_DECOMPRESSED_SIZE:
				printerr("DataDecompressor Error: Decompressed output exceeds %d bytes — aborting (malformed or hostile stream)." % _MAX_DECOMPRESSED_SIZE)
				return PackedByteArray()
		elif status == ERR_UNAVAILABLE:
			break
		else:
			printerr("DataDecompressor Error: Failed while getting partial data.")
			return PackedByteArray()

	# Leftover input means trailing bytes after the member, not truncation. An input
	# failure already reported its own cause, and reporting it again here would
	# misattribute it to the wire payload.
	if input_failed:
		return decompressed_data
	if last_slice_position < compressed_bytes.size():
		push_warning(
			"DataDecompressor: %d compressed bytes left unconsumed — trailing bytes after the gzip member." % (compressed_bytes.size() - last_slice_position),
		)
	else:
		_warn_if_truncated(compressed_bytes, decompressed_data.size())
	return decompressed_data


## Cross-checks decompressed output against the gzip ISIZE trailer.[br]
## [br]
## A truncated gzip stream is otherwise silent: [StreamPeerGZIP] consumes every byte
## it was given, emits the partial output it managed to inflate, and reports no error
## — [method StreamPeerGZIP.finish] is compression-only and always returns
## [constant ERR_UNAVAILABLE] here. Without this check a short frame reaches the BSATN
## reader looking like a complete one. Only valid when the payload ends with its
## member trailer, so the caller rules out leftover input first.
static func _warn_if_truncated(compressed_bytes: PackedByteArray, decompressed_size: int) -> void:
	if compressed_bytes.size() < 4:
		return
	var declared_size: int = compressed_bytes.decode_u32(compressed_bytes.size() - 4)
	if declared_size != decompressed_size & 0xFFFFFFFF:
		push_warning(
			"DataDecompressor: decompressed %d bytes but the gzip trailer declares %d — stream is truncated or corrupt." % [decompressed_size, declared_size],
		)


## Decompresses a raw Brotli stream [param compressed_bytes].[br]
## Uses Godot's built-in Brotli decoder (Godot 4.x ships decode support).[br]
## Returns an empty [PackedByteArray] on failure.
static func decompress_brotli(compressed_bytes: PackedByteArray) -> PackedByteArray:
	if compressed_bytes.is_empty():
		return PackedByteArray()
	# decompress_dynamic grows the output buffer as needed; cap it at the sanity
	# ceiling so a bomb can't exhaust memory (decode stops once the cap is reached).
	var out: PackedByteArray = compressed_bytes.decompress_dynamic(_MAX_DECOMPRESSED_SIZE, FileAccess.COMPRESSION_BROTLI)
	if out.is_empty():
		printerr("DataDecompressor Error: Brotli decompression failed or produced no output.")
	return out
