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

	while true:
		var input_result = gzip_stream.put_partial_data(compressed_bytes.slice(last_slice_position, last_slice_position + _CHUNK_SIZE))
		if input_result[0] != OK:
			printerr("DataDecompressor Error: Failed to input partial data: " + error_string(input_result[0]))
			break
		last_slice_position += input_result[1]
		var result: Array = gzip_stream.get_partial_data(_CHUNK_SIZE)
		var status: Error = result[0]
		var chunk: PackedByteArray = result[1]
		if status == OK:
			if chunk.is_empty():
				break
			decompressed_data.append_array(chunk)
		elif status == ERR_UNAVAILABLE:
			break
		else:
			printerr("DataDecompressor Error: Failed while getting partial data.")
			return PackedByteArray()
	return decompressed_data


## Decompresses a raw Brotli stream [param compressed_bytes].[br]
## Uses Godot's built-in Brotli decoder (Godot 4.x ships decode support).[br]
## Returns an empty [PackedByteArray] on failure.
static func decompress_brotli(compressed_bytes: PackedByteArray) -> PackedByteArray:
	if compressed_bytes.is_empty():
		return PackedByteArray()
	# decompress_dynamic grows the output buffer as needed (-1 = no preset cap),
	# so the decoded size doesn't need to be known up front.
	var out: PackedByteArray = compressed_bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_BROTLI)
	if out.is_empty():
		printerr("DataDecompressor Error: Brotli decompression failed or produced no output.")
	return out
