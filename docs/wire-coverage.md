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
| `TransactionUpdateMessage` | yes | **partial** — only nested inside a reducer result |
| `ProcedureResultData` | yes | **yes** — `wire_procedure.bin`, `wire_procedure_err.bin` |
| `IdentityTokenMessage` | yes | no |
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

`TransactionUpdateMessage` is marked partial deliberately: a caller's own row
changes arrive **inside** the reducer response, so the fixture exercises that
path but never a standalone broadcast of another client's transaction.

## Client API surface

| Call | Real wire bytes |
|---|---|
| `subscribe` | **yes** |
| `call_reducer` | **yes** |
| `call_procedure` | **yes** (both `Result` arms) |
| `unsubscribe` | **yes** |
| `query_sql` | **yes** |
| `connect_db` / reconnect + resubscribe | no |

## Data shapes

Covered by real bytes: a nested struct (`DbVector2` on an entity), a
synthesized `Result<T, E>` in both arms, and a native array-like payload
(`vector3[f32,f32,f32]`).

Procedure **parameters** are covered indirectly but strongly: the module's
`probe_params` computes its result from its arguments, so decoding the expected
value proves all three (a native array-like, a scalar, a string) crossed the wire
intact. The response is the receipt for the request.

Not covered by real bytes: `Option` fields, enum/sum columns on a table, btree
and unique index reads, and `Identity`/`u128`/`u256` scalars.

## Regenerating the fixtures

The fixtures pin what one server version sends. They will not catch a wire
format change until someone recaptures:

```sh
spacetime start --data-dir ~/.local/share/spacetime-blackholio
cd blackholio-server && ./publish.sh
cd ../godot-client && <godot> --headless --path . res://tests/_capture_wire_fixture.tscn
```

Captured against SpacetimeDB **2.7.0**. Note the `spacetime` CLI reports its own
version, which may lag the server binary it launches — check the server log line
`spacetimedb-standalone version:` for the truth.
