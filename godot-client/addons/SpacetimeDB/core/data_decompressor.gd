## Utility for decompressing Gzip-encoded WebSocket payloads.
##
## Used internally by [SpacetimeDBClient] when the server sends
## compressed BSATN packets.
class_name DataDecompressor
extends RefCounted

## Decompresses a Gzip-encoded [param compressed_bytes] payload.[br]
## Returns an empty [PackedByteArray] on failure.
static func decompress_packet(compressed_bytes: PackedByteArray) -> PackedByteArray:
	if compressed_bytes.is_empty():
		return PackedByteArray()

	var gzip_stream := StreamPeerGZIP.new()
	if gzip_stream.start_decompression() != OK:
		printerr("DataDecompressor Error: Failed to start Gzip decompression.")
		return PackedByteArray()

	var last_slice_position: int = 0
	var decompressed_data: PackedByteArray = PackedByteArray()
	var chunk_size: int = 4096

	while true:
		var input_result = gzip_stream.put_partial_data(compressed_bytes.slice(last_slice_position, last_slice_position + chunk_size - 1))
		if input_result[0] != OK:
			printerr("DataDecompressor Error: Failed to input partial data: " + error_string(input_result[0]))
			break
		last_slice_position += input_result[1]
		var result: Array = gzip_stream.get_partial_data(chunk_size)
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
