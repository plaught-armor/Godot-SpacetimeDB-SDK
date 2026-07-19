# Wire coverage

Which parts of the protocol are validated against **bytes a real server sent**,
versus bytes this SDK authored itself.

## Why this file exists

Most of the suite builds its wire bytes by hand, or round-trips the SDK's
serializer against its own deserializer. Both are self-consistent: if our model
of BSATN diverges from what SpacetimeDB actually sends, those tests still pass.

That is not theoretical. Value-returning procedures could not be decoded **at
all** — `Result<T, E>` returns failed with "Unsupported BSATN type" — while the
full suite and the byte-identical codegen goldens stayed green. It was found by
calling a procedure against a live server, not by a test.

So: synthetic coverage is necessary but proves less than it looks like. This
table tracks the difference.

## Server message types

| Message | Synthetic test | Real wire bytes |
|---|---|---|
| `SubscribeAppliedMessage` | yes | **yes** — `wire_snapshot.bin` |
| `ReducerResultMessage` | yes | **yes** — `wire_txn.bin` |
| `TransactionUpdateMessage` | yes | **yes** — nested (`wire_txn.bin`) and standalone (`wire_broadcast_txn.bin`) |
| `ProcedureResultData` | yes | **yes** — `wire_procedure.bin`, `wire_procedure_err.bin` |
| `IdentityTokenMessage` | yes | **yes** — `wire_identity_token.bin` |
| `OneOffQueryResponseMessage` | yes | **yes** — `wire_one_off_query.bin` |
| `SubscriptionErrorMessage` | yes | **yes** — `wire_subscription_error.bin` |
| `UnsubscribeAppliedMessage` | yes | **yes** — `wire_unsubscribe.bin` |

Chasing the `query_sql` gap immediately found it broken: its awaiter connected a
two-argument handler to a three-argument signal, so every call dropped its result
and returned an empty array. It had no test of any kind. That is the second
shipped-and-broken public API this table has turned up.

Chasing `unsubscribe` and `SubscriptionError` next found both working correctly —
worth recording, since a coverage gap means "unverified", not "broken". They are
captured so a regression on the teardown and error paths surfaces here.

`IdentityTokenMessage` was the last message type with no real bytes, only because
it arrives mid-handshake — the capture attached its hook in the `connected`
handler, by which point the frame had already been consumed. Hooking the socket
immediately after `connect_db` (which builds the connection synchronously, then
goes async for the token) catches it. It works, and it drags the first real-wire
bytes for a 32-byte identity and a 16-byte connection id along with it.

That message also carries a live JWT, minted without an expiry by whatever key
signed the capture — so the capture blanks it in place, byte for byte, before the
fixture is written. Lengths are unchanged, so the frame still decodes exactly as
the server framed it; only the token's characters are filler.

`TransactionUpdateMessage` has two shapes and needed two fixtures. A caller's own
row changes arrive **inside** its reducer response; another client's arrive as a
standalone broadcast. Producing the second means running a second client with its
own identity, so that is what the broadcast check does — an observer that only
subscribes, and an actor that connects and calls a reducer:

```sh
GODOT=<godot> tests/_live_broadcast.sh
```

It passes: the broadcast decodes and the other client's row lands in the local
cache. The observer never calls a reducer, so the fixture it captures cannot
contain a reducer response — which is what the offline test asserts before it
looks for the row.

## Client API surface

| Call | Real wire bytes |
|---|---|
| `subscribe` | **yes** |
| `call_reducer` | **yes** |
| `call_procedure` | **yes** (both `Result` arms) |
| `unsubscribe` | **yes** |
| `query_sql` | **yes** |
| `connect_db` | **yes** |
| reconnect + resubscribe | **yes** — live, `_live_reconnect_check.gd` (both close kinds) |

## Reconnect

Recovery is the one path a fixture cannot prove. What matters is not the bytes
but what the client does with them: clear the cache, re-subscribe under fresh
query ids, end the handles the caller was holding, and start accepting reducer
calls again. So it is covered by a live harness instead — the socket is dropped
underneath a connected client and the recovery is asserted end to end:

```sh
cd godot-client && <godot> --headless --path . res://tests/_live_reconnect_check.tscn
echo $?   # number of failed checks
```

It passes today: the cache refills, the pre-drop handle reports `ended`, and a
reducer call succeeds afterwards. It also writes `wire_resubscribe.bin`, so the
offline suite keeps a replayable copy of the snapshot the server sends a
re-subscribing client — with any frame carrying a token dropped rather than
captured and scrubbed.

That run closes the socket cleanly, which is the graceful-close branch. A yanked
network is a different one: the socket dies with no close handshake (code -1) and
routes through `_on_connection_error`. Reaching it means really taking the server
away, so a driver script does exactly that — SIGKILL, wait, restart:

```sh
GODOT=<godot> tests/_live_abnormal_drop.sh
```

It restarts the server with the argv it was already running and never passes
`--delete-data`, so the published module survives. This also passes: the client
reports the abnormal closure, retries through the downtime, and recovers the same
way once the server is back.

## Data shapes

Covered by real bytes: a nested struct (`DbVector2` on an entity), a
synthesized `Result<T, E>` in both arms, and a native array-like payload
(`vector3[f32,f32,f32]`).

Procedure **parameters** are covered indirectly but strongly: the module's
`probe_params` computes its result from its arguments, so decoding the expected
value proves all three (a native array-like, a scalar, a string) crossed the wire
intact. The response is the receipt for the request.

The handshake fixture adds an `Identity` (32 bytes) and a connection id (16), so
those two widths decode off real bytes now.

Covered since the probe table landed: `Option` columns in both arms (including
`Some("")` and `Some(0)`, the two values a sloppy check cannot tell from `None`),
a sum/enum column in each of its variants (no payload, a scalar, a string), and
`u128`/`u256`/`i128` as **table columns** at their extremes — `MAX`, `MIN`, and
an asymmetric byte pattern a wrong width or endianness cannot decode by accident.
Stock Blackholio has none of those shapes, which is why the module carries a
`probe_row` table that nothing in the game reads.

That leaves no column shape this module can express without real-bytes coverage;
what is still missing is listed under Remaining gaps below.

## Index reads

The generated index accessors (`db.<table>.<column>.find()` / `.filter()`) are
not a wire shape at all: they are caches built from `LocalDatabase`'s
insert/update/delete callbacks, so no fixture can exercise them and every test
before this one fed them synthetic rows. The btree index shipped in v2.5.0
without ever being read against a live server. A live harness covers them:

```sh
GODOT=<godot> tests/_live_index.sh
```

Every index read is asserted against a linear `iter()` scan of the same table —
the scan is the ground truth, the index is what is under test — across insert,
update and delete, plus the miss cases and each range bound. The driver starts a
second client first: with one player the btree holds a single key and the range
accessors return everything or nothing, so the check **fails on purpose** if it
finds a single-player world rather than reporting a green run that proved
nothing. It passes today, including through `suicide()` emptying a bucket and
unregistering its key.

## Remaining gaps

Every message type and every column shape the module can express is now covered
by real bytes. What is left is narrower:

| Gap | What it needs | Notes |
|---|---|---|
| Server-**compressed** frames | A second capture pass with `CompressionPreference.GZIP` / `BROTLI` | Every fixture is captured with compression `NONE` on purpose, so the files stay replayable BSATN. The decompressors are tested (`test_decompress`, `test_brotli_decompress`) but against a gzip round trip and a `brotli` CLI blob — never against a frame SpacetimeDB itself compressed. |
| Container columns (`Vec<T>`, `Vec<Struct>`) | Columns of those types on the probe table | A native array-like is covered as a procedure *return* (`vector3`), not as a table column. |

## Regenerating the fixtures

The fixtures pin what one server version sends. They will not catch a wire
format change until someone recaptures:

```sh
spacetime start --data-dir ~/.local/share/spacetime-blackholio
cd blackholio-server && ./publish.sh
cd ../godot-client && <godot> --headless --path . res://tests/_capture_wire_fixture.tscn
```

Two fixtures come from the live harnesses rather than that capture —
`wire_resubscribe.bin` from the reconnect check and `wire_broadcast_txn.bin` from
the broadcast check — because each needs a situation the capture cannot stage. A
failed run of either deletes its fixture rather than leaving a plausible-looking
one behind.

Captured against SpacetimeDB **2.7.0**. Note the `spacetime` CLI reports its own
version, which may lag the server binary it launches — check the server log line
`spacetimedb-standalone version:` for the truth.
