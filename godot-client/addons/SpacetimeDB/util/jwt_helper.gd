class_name JwtHelper
extends RefCounted
## Tiny JWT payload decoder. JWT = base64url(header).base64url(payload).signature.
##
## Handy for reading claims out of a SpacetimeAuth id_token client-side, e.g. to
## key a per-identity token cache off the JWT's [code]login_method[/code] claim so
## tokens from different login providers don't overwrite each other.
##
## [b]SECURITY:[/b] the payload is NOT signature-verified here. Do NOT use this
## for any authorization decision on the client — the SpacetimeDB server verifies
## the signature on connect. This is purely for reading claims for local
## bookkeeping and diagnostics.

# Claims dumped by summarize(), in display order. static var (not const) — a
# const Packed*Array reports byte-count size and reads back empty (C1). No
# make_read_only() (C2a): Packed*Array has no freeze API, and it's copy-on-write
# anyway, so a consumer that mutates gets its own copy — the shared table is safe.
static var _summary_claims: PackedStringArray = [
	"iss",
	"sub",
	"aud",
	"login_method",
	"provider_id",
	"preferred_username",
	"exp",
	"iat",
]


## Decode a JWT's payload segment to a [Dictionary] of claims. Returns an empty
## dictionary on a malformed token or a payload that isn't a JSON object. The
## signature is NOT checked — see the class SECURITY note.
static func decode_payload(jwt: String) -> Dictionary:
	# A well-formed JWT is exactly header.payload.signature (3 segments). Reject
	# anything else — defense-in-depth so a truncated/garbage token can't be read
	# as if it carried valid claims (the server remains the real trust boundary).
	var parts: PackedStringArray = jwt.split(".")
	if parts.size() != 3:
		return { }
	var payload_b64url: String = parts[1]
	# base64url -> base64: the URL-safe alphabet uses `-_` instead of `+/` and drops padding.
	var padded: String = payload_b64url.replace("-", "+").replace("_", "/")
	while padded.length() % 4 != 0:
		padded += "="
	var bytes: PackedByteArray = Marshalls.base64_to_raw(padded)
	if bytes.is_empty():
		return { }
	# A JWT payload that decodes to a JSON array / scalar / null would fail a
	# direct typed-Dictionary assignment, so parse to Variant and guard.
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not (parsed is Dictionary):
		return { }
	return parsed


## The JWT's [code]login_method[/code] claim, set by SpacetimeAuth (e.g.
## [code]"anonymous"[/code] or a provider name). Returns [code]""[/code] for an
## empty / malformed JWT or a token with no such claim.
static func login_method(jwt: String) -> String:
	if jwt.is_empty():
		return ""
	return String(decode_payload(jwt).get("login_method", ""))


## Human-readable dump of common claims for diagnostic logging. Returns
## [code]"<empty>"[/code] / [code]"<malformed...>"[/code] or a multi-line string
## of the claims that are present.
static func summarize(jwt: String) -> String:
	if jwt.is_empty():
		return "<empty>"
	var payload: Dictionary = decode_payload(jwt)
	if payload.is_empty():
		return "<malformed jwt or non-json payload>"
	var lines: PackedStringArray = []
	for key: String in _summary_claims:
		if payload.has(key):
			lines.append("    %s = %s" % [key, payload[key]])
	return "\n".join(lines)
