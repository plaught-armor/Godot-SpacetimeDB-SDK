# Unit test for SpacetimeDBConnection.build_query_params — the wire spelling of every
# connection knob that rides in the subscribe URL.
#
# The `confirmed` cases are the point of the file. The server treats that parameter as
# an `Option<bool>` and applies `DEFAULT_CONFIRMED_READS` (true) to a v3 connection that
# omits it, so a client that sends `confirmed=false` is not agreeing with the server's
# default — it is opting out of durable reads. This SDK writes the value on every
# connect, which is only safe as long as the default it writes stays the server's.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_subscribe_query_params.gd
extends SceneTree

const CID: String = "abc123"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0

	# The default options object is what the overwhelming majority of games connect
	# with, so its query string is the one that has to match the server's default.
	var defaults: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	f += _check("defaults are durable reads", defaults.confirmed_reads, true)
	f += _check(
		"default options string",
		SpacetimeDBConnection.build_query_params(
			CID,
			defaults.compression,
			defaults.confirmed_reads,
			defaults.light_mode,
		),
		"?connection_id=abc123&compression=None&confirmed=true",
	)

	# Opting out is still reachable, and spelled the way the server parses it
	# (serde `bool`, lowercase — "False" would be a 400, not a silent default).
	f += _check(
		"confirmed=false when asked",
		SpacetimeDBConnection.build_query_params(
			CID,
			SpacetimeDBConnection.CompressionPreference.NONE,
			false,
			false,
		),
		"?connection_id=abc123&compression=None&confirmed=false",
	)

	# Compression spellings are the server's `Compression` enum variants verbatim.
	f += _check(
		"brotli",
		SpacetimeDBConnection.build_query_params(
			CID,
			SpacetimeDBConnection.CompressionPreference.BROTLI,
			true,
			false,
		),
		"?connection_id=abc123&compression=Brotli&confirmed=true",
	)
	f += _check(
		"gzip",
		SpacetimeDBConnection.build_query_params(
			CID,
			SpacetimeDBConnection.CompressionPreference.GZIP,
			true,
			false,
		),
		"?connection_id=abc123&compression=Gzip&confirmed=true",
	)

	# `light` is the one parameter the server reads as a bare presence flag, so it is
	# only written when on.
	f += _check(
		"light mode adds the flag",
		SpacetimeDBConnection.build_query_params(
			CID,
			SpacetimeDBConnection.CompressionPreference.GZIP,
			false,
			true,
		),
		"?connection_id=abc123&compression=Gzip&confirmed=false&light=true",
	)

	# No token parameter here on any platform — Web appends it at the call site,
	# and leaking it into this string would put the auth token in every log line
	# that prints the target URL.
	f += _check(
		"token is not this function's job",
		(
			"token"
			in SpacetimeDBConnection.build_query_params(
				CID,
				SpacetimeDBConnection.CompressionPreference.NONE,
				true,
				true,
			)
		),
		false,
	)

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
