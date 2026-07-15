class_name SpacetimeAuthResult
extends RefCounted
## Outcome of a [SpacetimeAuth] token exchange. POD (D1): the [SpacetimeAuth]
## node and the stateless [SpacetimeAuthProtocol] both produce it; the
## classification behavior lives in the protocol transforms, not here.
## [method is_successful] is a pure query over the fields, no mutation.

## The issued SpacetimeAuth id_token (a JWT) on success; empty on failure.
var id_token: String = ""
## Token lifetime in seconds, as reported by the endpoint (0 if absent).
var expires_in: int = 0
## Human-readable failure reason; empty when the exchange succeeded.
var error: String = ""


## True when the exchange produced a token (i.e. [member error] is empty).
func is_successful() -> bool:
	return error.is_empty()
