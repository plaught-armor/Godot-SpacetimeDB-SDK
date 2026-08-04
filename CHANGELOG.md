# Changelog

All notable changes to the SpacetimeDB Godot SDK will be documented in this file.

## [Unreleased]

### Added
- **Regaining focus fires a stalled reconnect immediately.** A backgrounded app's
  frame loop is throttled (a web export in a background tab) or stopped outright
  (a suspended mobile app), which stalls the `SceneTreeTimer` the reconnect
  backoff runs on — a drop that happens while the player is away would sit
  unreconnected for the remainder of a delay that barely ticks, well after they
  are looking at the game again. The client now listens for
  `NOTIFICATION_APPLICATION_FOCUS_IN` / `NOTIFICATION_APPLICATION_RESUMED` /
  `NOTIFICATION_WM_WINDOW_FOCUS_IN` (which one arrives depends on the platform)
  and re-schedules a waiting attempt with no delay. The attempt keeps its own
  number rather than consuming or resetting one, so `max_reconnect_attempts`
  still bounds the cycle and alt-tabbing cannot extend it. New option
  `SpacetimeDBConnectionOptions.reconnect_on_app_resume` (default `true`) turns
  it off. The decision is a pure `SpacetimeDBClient.should_resume_reconnect()`,
  covered by `tests/test_resume_reconnect.gd`.

- **A failed `decode()` is now distinguishable from nothing to decode.**
  `SpacetimeDBReducerCall.decode()` and `SpacetimeDBProcedureCall.decode()`
  return `null` for three different reasons — a unit reducer, no declared return
  type, and bytes that failed to parse — and a caller could not tell the last one
  from the rest, so a truncated or
  mistyped return payload read exactly like a reducer that returned nothing. Both
  handles gain `has_return_value()`, `has_decode_error()` and
  `decode_error_message`; a failed decode also raises a Godot error rather than
  passing silently. The deserializer's error state is captured per handle, so one
  failed decode can no longer leave a stale error that makes the next handle's
  decode look broken.

### Fixed
- **A connection attempt that stalls in the handshake now ends.** Godot's raw
  `WebSocketPeer` has no handshake timeout — `handshake_timeout` belongs to
  `WebSocketMultiplayerPeer`, and `WSLPeer::poll` only ages a socket that is already
  open — so a remote that accepted the TCP connection and never answered the upgrade
  (a proxy in front of a dead upstream, a half-open NAT entry, a server wedged
  mid-boot) left the client in `STATE_CONNECTING` for as long as it held the socket:
  no `connected`, no `connection_error`, and no auto-reconnect either, because the
  attempt that would have to fail first never ended. One stalled attempt therefore
  also wedged the whole reconnect cycle — `max_reconnect_attempts` was never reached
  and `reconnect_failed` never fired. Attempts are now bounded by the new
  `SpacetimeDBConnectionOptions.connect_timeout_seconds` (default `15.0`, `0.0`
  restores the old wait-forever behaviour) and reported as `connection_error` with
  `ERR_TIMEOUT`, after which auto-reconnect proceeds normally. A frozen frame loop
  cannot fail a healthy connect: a poll gap over a second is credited back to the
  handshake, up to one budget's worth, on a rule that does not read
  `heartbeat_interval_seconds` — turning keepalive off does not harden this budget.
  Covered by `tests/test_connect_timeout.gd`, which drives a real client against a
  listener that accepts and never upgrades; the pre-fix wedge is reproduced by
  `tests/_probe_handshake_wedge.gd`.

- **A column holding a list of vectors decodes again.** A `Vec<Vector3>` column (or
  `Vec<Color>`, `Vec<Vector2i>`, `Vec<Quaternion>`, and every other native array-like
  element type) is emitted as `Array[Vector3]` with the ELEMENT's BSATN type,
  `vector3[f32,f32,f32]` — the component layout lives in that string. The writer
  resolved its element writer with that type; the reader resolved its element reader
  with an empty one, so every such column failed with `Missing BSATN_TYPES entry for
  '<column>' (type Vector3)`, taking the whole row down rather than just the column.
  Only a *populated* list reached the element reader, so an empty one always decoded —
  which is how this survived. Covered by `tests/test_native_vector_array_roundtrip.gd`,
  whose first assertion pins the type pair codegen emits so the round trip is testing
  the real shape.

- **Codegen escapes columns named `namespace` or `trait`.** Both are GDScript reserved
  words that were missing from the escape list, and both are ordinary identifiers on the
  server side — `namespace` in a Rust module, `trait` in a C# one. A module with either
  as a column, parameter, reducer or table name emitted `var namespace: int`, which the
  parser answers with `Expected variable name after "var"`, taking that module's whole
  bindings down rather than just the one field. They are now escaped to `namespace_` /
  `trait_` like every other reserved word. The `vreserved` codegen fixture covers both.

- **A successful REST reducer call is no longer reported as a failure.**
  `SpacetimeDBRestAPI.call_reducer()` required the response body to be a JSON object,
  and a reducer that commits answers `POST /v1/database/<db>/call/<reducer>` with
  `200` and an **empty** body — so every successful call emitted
  `reducer_call_failed(200, "Invalid JSON response")` and `reducer_call_completed`
  could not fire for a reducer at all. A body only comes back for a procedure, and it
  is the JSON encoding of the return value, which is any JSON value rather than
  necessarily an object. `reducer_call_completed` now carries a `Variant`: `null` for
  a reducer, the decoded return value for a procedure. **Breaking for a typed handler:**
  the signal's parameter was declared `Dictionary`, so a listener written as
  `func _on(result: Dictionary)` must widen to `Variant` — connecting is unaffected,
  but dispatch now hands it `null` or a non-object value. Genuine failures are unchanged
  — a reducer that returns an error still answers `530` with its message, which
  routes to `reducer_call_failed` as before. Covered by
  `tests/test_rest_reducer_response.gd`.

- **A `Vec<u8>` read off the wire can be serialized back.** The BSATN reader resolves
  a primitive reader before it looks at the `vec_` / `opt_` type prefixes, so `vec_u8`
  decodes to a `PackedByteArray`; the writer checked the prefix first and rejected
  anything that was not an `Array`. An `Option<Vec<u8>>` field or a `Vec<u8>` enum
  variant therefore could not be written back — reading such a row and handing it to a
  reducer failed with `Expected Array for BSATN type 'vec_u8', got PackedByteArray`.
  Plain `Array` fields of `Vec<u8>` were never affected (codegen labels those with the
  element type). `vec_u8` is the only primitive whose name carries one of those
  prefixes, so this was the only place the two orderings could disagree.

- **A BSATN serialization plan that fails to build no longer caches as an empty one.**
  The plan cache tells "no storage fields" from "not built yet" by key presence, and a
  failed build stored `[]` — so the first attempt to serialize a schema with an
  unsupported property failed loudly and **every later one wrote zero bytes and
  reported success**. Reachable with a user struct passed as a reducer argument: after
  the first send named the offending field, every subsequent send silently shipped an
  empty product in its place. The failure path now leaves the cache untouched, so each
  attempt rebuilds and fails the same way (matching the deserializer, which already
  did).

- **`SpacetimeDBQuery.where_in()` now emits SQL the server can parse.** It produced
  `field IN (v1, v2, ...)`, and SpacetimeDB's SQL has no `IN` operator: its expression
  parser — the same one behind a subscription and a one-off query — accepts comparisons
  (`=`, `!=`, `<`, `<=`, `>`, `>=`) joined by `AND` / `OR` and rejects everything else, so
  every `where_in` query came back as an unsupported expression and failed the whole query
  set. Verified against the SpacetimeDB source: no `InList` arm exists in the parser, and
  none ever did. It now emits the equivalent OR group, `(field = v1 OR field = v2 ...)` —
  same meaning, and it parses. `where_any` already emitted that shape and is unchanged;
  both now share one helper. The practical ceiling on list length is the server's
  expression-recursion guard (1600). `tests/test_query_builder.gd` asserted only the
  generated string, which is why a feature no server could parse had a passing test; it
  now asserts the shape the server accepts.

- **A manual reconnect starts a clean session instead of stacking on the last one.**
  `clear_local_db()` was called from exactly one place, the auto-reconnect path, so a
  `disconnect_db()` followed later by `connect_db()` on the same client began the next
  session on top of the previous session's rows: every re-delivered row came back at
  refcount 2, so that session's own unsubscribe left it cached; a row deleted server-side
  while the client was away stayed cached for good with no `on_delete` to report it; and
  `_received_initial_subscription` was still true, so `database_initialized` never fired
  again and anything awaiting it waited forever. `connect_db()` now wipes and re-arms when
  it is starting a session rather than reconfiguring a live one — `disconnect_db()` still
  leaves the rows alone, since reading last-known state while offline is why it does. The
  wipe reports every row as deleted, and because that is game code, a listener that calls
  `disconnect_db()` or starts its own `connect_db()` from it now supersedes the call in
  progress, the same countermand the auto-reconnect path already honoured. Covered by
  `tests/test_manual_reconnect_session.gd`.

- **A client running without threads now gets the same reconnect boundary as one with
  them.** `_prepare_for_reconnect()` put its whole session-boundary cleanup behind
  `if use_threading`, so a threadless client kept two things across a reconnect: messages
  already parsed out of the dying session, which were then drained into the fresh mirror
  (the epoch check in the worker exists to stop exactly that), and the deserializer's
  partial-message buffer, so the first packet of the new session parsed against a prefix
  belonging to the old one — `reset_stream_state()` was only ever called from the worker
  thread. Threadless is not a corner case: `_setup_threading()` disables threading on any
  build without thread support, so every threadless web export was on this path. Covered
  by `tests/test_threadless_reconnect.gd`.

- **A `RowReceiver` now unsubscribes from the table it subscribed to.** Its listeners are
  registered under the name `_subscribe_to_table()` was called with, but `_exit_tree()`
  unsubscribed whatever `selected_table_name` held at that moment. Assigning
  `table_to_receive` at runtime moves that property (through `on_set`) without
  re-subscribing, so the first table's listeners were never removed — Callables bound to
  a node that is then freed, which `LocalDatabase` goes on calling for every row event on
  that table, for the rest of the session. The receiver now remembers the name it
  subscribed with. Swapping the table while the receiver is in the tree still does not
  re-subscribe, which is now stated on `table_to_receive`: leave the tree and re-enter to
  switch tables. Covered by `tests/test_row_receiver_retable.tscn`.

- **`on_delete` on a PK-less table no longer fires while the row is still in the cache.**
  The two delete callbacks split on exactly one thing: `on_before_delete` runs while the
  row is still queryable, `on_delete` once it is gone. The PK path erases from the table
  dict between them; the PK-less path fired both from inside its refcount-decrement loop
  and only compacted the row array afterwards, so `on_delete` still found the row in
  `iter()` / `get_all_rows()`. A consumer that rebuilds its view from the cache on delete
  — the natural shape for a flat table — kept showing the row it had just been told was
  deleted, until the next event touched that table. Deletes now fire after the
  compaction. One difference from the PK path is deliberate and documented on
  `subscribe_to_before_deletes`: a PK-less batch evicting several rows reports every
  before-delete and then every delete, where the PK path interleaves each row's pair.
  Both orders are pinned in `tests/test_pkless_delete_order.gd`.

- **An outstanding call whose response never arrives no longer strands its handle.**
  `_pending_reducer_calls` / `_pending_procedure_calls` shrank only when the matching
  response arrived or the connection died. Neither happens when a reply is lost while
  the socket stays up — the BSATN parser drops a corrupt buffer and deliberately keeps
  the connection — so that call's handle, and everything it holds, stayed in the map for
  the rest of the session (measured: 4196 entries after 4196 such calls, none evictable).
  Both maps now stop at `SpacetimeDBStats.MAX_PENDING` entries per kind, dropping the
  oldest outstanding handle and stamping it `TIMEOUT` with a reason so an awaiter is not
  left holding one nothing can complete. A handle that already reached an outcome keeps
  it. Covered by `tests/test_pending_call_cap.gd`.

- **A btree index on an Identity column no longer leaks its sorted-key mirror.**
  `Identity`, `ConnectionId`, `u128` and `u256` all arrive as `PackedByteArray`, and
  `PackedByteArray` has no `<` — so `Array.bsearch` landed on an arbitrary slot for
  those keys and `_key_removed()` never found the key it was handed. Every distinct
  value a client saw left one entry in `_sorted_keys` after its bucket was gone, plus
  a duplicate each time the same value came back: a session-long connection to a table
  keyed by identity grew the mirror without bound. Nothing read the stale entries
  (codegen emits `filter_range` / `filter_gte` / … for `int`, `float` and `String`
  columns only), so this cost memory rather than wrong answers. The mirror is now
  maintained only for keys `bsearch` can order, which also drops the pointless
  bsearch-and-insert on every bucket edge of a bytes-keyed index. Covered by
  `tests/test_btree_bytes_keys.gd`.

- **The latency tracker no longer reports requests in flight on an idle client.**
  A reducer call, procedure call, one-off query or subscribe that was outstanding when
  the socket dropped is answered by nobody — the client stamps its handle
  `DISCONNECTED` — but `SpacetimeDBStats` kept the send, so `get_stats()` reported a
  non-zero `in_flight` for the rest of the session after every auto-reconnect, and a
  pre-drop request id could resolve against a post-reconnect request that reused it
  (the id counters restart at zero). `_fail_pending_calls_disconnected()` now retires
  the tracker's pending sends along with the handles, keeping the completed round
  trips' latency history. A `SubscriptionError` that carries a request id also counts
  as that subscribe's response now, instead of leaving it pending until the next
  disconnect. Covered by `tests/test_stats.gd` and `tests/test_reconnect_state.gd`.

- **The drain auto-tuner no longer mistakes a frame-rate cap for a struggling game.**
  `_auto_tune_budget()` compares `Engine.get_frames_per_second()` — the *rendered*
  frame rate — against a target that defaulted to `Engine.physics_ticks_per_second`,
  which is a different loop. A game that caps itself at 30 fps while physics runs at
  the default 60 therefore read as permanently below target, so the AIMD controller
  backed off on every tick: measured, the budget falls from the configured 4000 us to
  the 1000 us floor within twelve ticks and stays there, draining the message backlog
  four times slower than configured while nothing was actually struggling. A 30 fps cap
  is a common mobile configuration. The target now resolves through the new pure
  `SpacetimeDBClient.resolve_target_fps()`: an explicit
  `auto_tune_target_fps` wins, else the engine's frame cap (`Engine.max_fps`) if there
  is one *and the game is actually reaching it*, else the physics tick rate as before —
  so an *uncapped* game rendering below its physics rate still backs off, which is the
  case the controller is for. The "actually reaching it" condition matters as much as
  the cap itself: a cap is what a game permits, not what it achieves, and capping above
  what the hardware delivers is a common idiom, so adopting an unreached 240 fps cap on
  a machine rendering 60 would pin the budget at the floor exactly as the original bug
  did. Two configurations still want an explicit `auto_tune_target_fps`: a game capped
  by vsync rather than `max_fps`, and one capped far below its physics rate (a 10 fps
  battery-saver mode), where the rendered rate stops being evidence about the drain at
  all — the engine sleeps out the difference, so the budget ramps to
  `frame_budget_max_us` and spends it every physics tick. Lower that ceiling or turn
  `auto_tune_frame_budget` off for such a mode. Covered by nine new cases in
  `tests/test_budget_tuner.gd`.

- **A paused game keeps its connection.** The socket is polled from
  `_physics_process`, and no `process_mode` was set anywhere in the addon, so
  `get_tree().paused = true` — the ordinary way to pause a Godot game — stopped the
  poll entirely. Measured against a real socket: the connection's poll clock advanced
  338 ms over 20 unpaused physics frames and 0 ms over 20 paused ones, while 332 ms of
  real time went by. That poll is what sends Godot's keepalive ping, reads inbound
  frames and flushes outbound ones, so a pause menu left open past the server's
  30-second idle timeout lost the session, inbound frames piled up unread, and a
  reducer called while paused was queued but never sent. `SpacetimeDBClient` now sets
  `PROCESS_MODE_ALWAYS` on itself, which its children (the connection, the REST
  handler, the local database) inherit. The trade-off is that row callbacks keep
  arriving while the game is paused, along with every other client signal — the
  server's world does not stop — and the new
  `SpacetimeDBConnectionOptions.process_while_paused` (default `true`) turns it off for
  a game that would rather freeze the SDK too. Opting out selects `PROCESS_MODE_PAUSABLE`
  rather than inherit, so a client parented under an always-process node still freezes as
  the option promises. Covered by `tests/test_pause_processing.gd`.

- **Timeouts and backoffs now run on the wall clock, not the game clock.** Every
  `SceneTree.create_timer()` in the SDK took the default `ignore_time_scale = false`,
  so all of them stopped dead at `Engine.time_scale = 0` — a standard way to pause a
  Godot game. Measured on 4.8.dev: over 255 ms of real time at scale 0, a default timer
  did not move at all while an `ignore_time_scale` one counted down normally. So a
  connection that dropped while the game was paused that way never retried (the backoff
  timer was frozen — the same stalled-backoff failure `reconnect_on_app_resume` exists
  for, reached from a different direction), an `await …wait_for_response()` stayed
  suspended for the length of the freeze, and slow motion stretched every network
  timeout by `1/time_scale`. All six timers — the reducer/procedure/one-off response
  wait, `SpacetimeDBSubscription.wait_for_applied()` / `wait_for_end()`, the reconnect
  backoff, the resubscribe watchdog and the `SpacetimeAuth` retry delay — now ignore the
  time scale, since each one is measuring a server or a network rather than game time.
  They stay pause-immune as before. Covered by `tests/test_timeouts_wall_clock.gd`.

- **A unique index no longer loses a row when a transaction hands its key over.**
  `_ModuleTableUniqueIndex` erased its cache entry by key on delete, without checking
  whose row was sitting there. `LocalDatabase` applies a table update's whole insert
  list before any of its deletes, so a transaction that deletes the holder of a unique
  value and inserts its successor in the same batch — a rename, a seat or slot handed
  from one row to another — arrived with the successor already cached, and the delete
  dropped it. The generated `db.<table>.<column>.find(value)` then returned `null` for
  a row `iter()` still yields, for the rest of the session (nothing re-adds it until
  that row is updated again). The update listener had the same hole for the key it
  gives up. Both now release a key only while this row still holds it. Blackholio never
  hit it because each of its unique columns is also the primary key, which cannot be
  handed over; a unique column that is not the primary key can. Covered by four new
  cases in `tests/test_unique_index_cache.gd`. The btree index was already correct — it
  erases the row from its bucket by identity, which targets the row being deleted, so a
  successor sharing the key survives.

- **An auth token can no longer inject headers into the WebSocket handshake.** The
  token is spliced into an `Authorization: Bearer <token>` entry in
  `WebSocketPeer.handshake_headers`, and Godot writes those out verbatim
  (`request += handshake_headers[i] + "\r\n"` in `wsl_peer.cpp`) with no validation of
  its own, so a CR or LF inside the token ended that header line and turned everything
  after it into further request headers. Verified against a local socket: a token of
  `abc\r\nX-Injected: yes` produced an `X-Injected` header and truncated the credential
  to `abc`. The token is not always the game's own text — `SpacetimeAuth` returns one
  parsed out of a third-party OIDC host's JSON response, the client reloads one from
  `token_save_path` on disk, and the server supplies one in its IdentityToken message —
  and only `SpacetimeDBRestAPI.set_token()` checked for this, which is not the path a
  game connects through. A token carrying any control character (below `0x20`, or DEL)
  is now refused at the client chokepoint before it is stored, written to disk, or
  connected with, reported as `connection_error` with `ERR_UNAUTHORIZED` and a reason
  naming the byte and its index; `SpacetimeDBConnection.set_token()` refuses one too,
  and the empty-token connect arm it lands in now says so rather than returning under a
  `print_log`. On Web, where the token goes into the URL instead of a header, it is
  percent-encoded. The check is the pure
  `SpacetimeDBConnection.token_reject_reason()`, and it is the SDK's only definition of
  an unusable token: `connect_db()` applies it before storing `options.token` (an
  unusable one kept there would otherwise spend a whole auto-reconnect budget being
  re-refused one attempt at a time), `SpacetimeDBRestAPI.set_token()` now defers to it
  instead of its own narrower CR/LF check, and a refused IdentityToken raises
  `connection_error` rather than only a log line, since that session keeps working but
  its reconnect would have no token. Covered by `tests/test_token_header_safety.gd`.

- **A reconnect no longer strands rows that were deleted while the client was away.**
  `_prepare_for_reconnect()` wiped the local cache with
  `LocalDatabase.clear_all_tables()`, which empties the storage and reports nothing.
  The resubscribe that follows re-delivers only the rows that still exist, so a row
  deleted server-side during the outage left the mirror with no `on_delete` and no
  `row_deleted` — and a consumer keyed by primary key kept whatever it had built for
  that row for the rest of the session. In the Blackholio example, food eaten and
  players who left during a drop stayed on screen after every auto-reconnect. The
  wipe now runs through `clear_local_db()`, which reports every cached row as deleted
  and emits one `row_transactions_completed` per non-empty table, so a reconnect
  reads as a teardown followed by a rebuild from the resubscribe. It runs last in
  the reconnect preparation, after the handles are ended and the queues are dropped,
  so a listener that reads client state or calls back in sees the finished state.
  `clear_all_tables()` stays available for a caller that is rebuilding every
  consumer's view itself, with its silence now documented. Because the wipe is last,
  a subscription handle's `end` signal now fires while the pre-drop rows are still
  cached, with the deletes following right after, and a listener that cancels the
  reconnect from inside the wipe no longer has the attempt continue around it.
  Covered by
  `tests/test_reconnect_row_deletes.gd`; the contract is written up under "Row
  callbacks across a reconnect" in `docs/api.md`.

- **A row updated before the client had it can now be deleted.** In
  `LocalDatabase.apply_table_update()`, a delete+insert of the same primary key —
  the server's encoding for an update — for a key the cache did not hold took
  insert semantics but left the reference count untouched, because the delete it
  carries is consumed as part of the update and so the delete pass never records
  the delivery's reference. The row landed in the cache at reference count 0, and
  an unreferenced cached row is permanent: every later delete for that key reads a
  count of 0 and skips the row, so it never leaves the cache, no `on_delete` ever
  fires, and every query helper keeps returning it for the rest of the session.
  The next delivery of that key also fired a second `on_insert` for an
  already-cached row instead of `on_update`. Reachable wherever the cache can be
  behind the server for one key: an insert skipped for a null primary key, an
  update arriving after the reconnect path cleared the mirror, or an update from
  one subscription for a key a `SubscriptionError` just pruned for another. The
  branch now records the reference it holds. Covered by
  `tests/test_update_insert_refcount.gd`.

- **A truncated Brotli frame no longer hangs the client.**
  `DataDecompressor.decompress_brotli()` used
  `PackedByteArray.decompress_dynamic()`, which never returns on a Brotli stream it
  cannot finish. Godot's growth loop (`core/io/compression.cpp`) ends on
  `BROTLI_DECODER_RESULT_SUCCESS` or on passing the size cap; a truncated stream
  reaches neither, because Brotli keeps answering `NEEDS_MORE_INPUT` with no input
  left, so the total output stops growing, the cap is never passed, and the buffer
  grows by 64 KiB — copying all of it each round — until the process dies. Measured
  on 4.8.dev with the cap set as low as 1 MiB: it never returned. Brotli is the
  server's default compression mode, so any client that enabled compression was one
  corrupt frame away from a hung parse thread and unbounded memory growth.
  Decoding now uses the bounded one-shot `PackedByteArray.decompress()`, which
  fails immediately on a stream it cannot finish. It needs the output size up
  front, so the size is guessed from the compressed size and doubled on failure up
  to the same 128 MiB ceiling; the ratio that worked is remembered (clamped, mutex
  guarded, since the decode runs on the deserializer worker thread) so a payload
  shape only pays for the retries once. Truncated, short and non-Brotli inputs now
  return empty in about a millisecond. Found by extending
  `tests/fuzz_wire_decode.gd` to mutate the compressed fixtures; covered by
  `tests/test_decompress_brotli.gd`, including a 484-byte fixture that decodes to
  2 MiB so the retry path stays exercised.

- **A gzip frame that breaks mid-stream is dropped, not half-decoded.**
  `decompress_packet()` returned whatever had inflated before an input failure —
  the front of a message whose tail is missing, which the reader then reported as
  a corruption belonging to the wire rather than to the decoder. It returns empty
  now, like every other failure path in that function, and the client logs the
  dropped frame the way it already did for Brotli. Its `while true` loop also gained
  an explicit pass bound and a drained-cleanly flag, so exhausting that bound
  reports and returns empty instead of yielding a prefix.

- **A message too big for the inbound buffer now says so.** Godot hands
  `WebSocketPeer.inbound_buffer_size` to wslay as the maximum receivable message
  length, so a server message larger than that buffer is never delivered — wslay
  stops reading and closes the socket itself with code `1009`. The server allows
  itself 32 MiB per message, sixteen times this SDK's 2 MB default, so an ordinary
  subscription with a large initial payload can produce a message the server
  considers legal and this client cannot receive. That close arrived as an
  unremarkable non-abnormal closure: it went to `disconnected`, auto-reconnect
  resubscribed the same queries, the same oversized message closed the socket
  again, and the only trace was a `print_log` line that is silent unless
  `debug_mode` is on. A 1009 close now pushes an error naming the buffer the game
  is actually running with and the three ways out — raise `inbound_buffer_size`,
  enable `compression` so the payload arrives compressed, or narrow the
  subscription — and warns that the resubscribe will meet the same message. The
  reconnect itself is deliberately left alone: a 1009 raised by one oversized
  transaction update is survivable, and only the caller knows whether its
  subscription is the kind that reproduces it. Which close codes carry a
  diagnostic is a pure `SpacetimeDBConnection.close_diagnostic()`, covered by
  `tests/test_message_too_big.gd`.

- **A dropped packet no longer looks like a clean parse.** When
  `BSATNDeserializer.process_bytes_and_extract_messages()` hits a malformed
  message it discards the whole buffered stream, and
  `SpacetimeDBClient._parse_packet_and_get_resource()` checks `has_error()`
  immediately afterwards to decide whether to throw the batch away. That check
  could never fire: the branch reported the failure through `get_last_error()`,
  whose documented job is to return the message *and clear the error state*, so
  reporting the problem erased the evidence of it and the deserializer returned
  looking like nothing had gone wrong. A corrupt or truncated frame therefore
  dropped the client's parse buffer silently, and nothing above the parser learned
  the stream had been cut. The branch now reads the message without consuming it,
  so the failure reaches the client and the log. The messages parsed before the bad
  one are still delivered — they are whole and ordered, and indistinguishable from
  the same messages arriving in their own packet, so discarding them would cost
  uncorrupted transaction updates on top of the ones the error already cost. The
  neighbouring "parser consumed 0 bytes" guard, which dropped the same buffer
  without ever setting an error at all, now sets one too. An empty packet clears
  the error state rather than reporting the previous packet's. Found
  by mutation-fuzzing the captured wire frames (`tests/fuzz_wire_decode.gd`,
  committed): 1440 corrupted frames produced 1440 error-free parses. Covered by
  `tests/test_parse_error_visibility.gd`.

- **A redacted field name is treated as a literal, not as a regular
  expression.** `SpacetimeAuthProtocol.redact()` interpolated each name from
  `SpacetimeAuth.redact_fields` straight into a pattern, so a name carrying a
  regex metacharacter either matched the wrong span — `.b` redacting the value of
  `ab` — or failed to compile, and `RegEx.sub()` on a RegEx that failed to
  compile returns an empty `String`, which wiped the entire error body the call
  was meant to scrub one value out of. Names are now escaped before
  interpolation, and the matched name is written back through a capture group
  rather than interpolated into the replacement, where `$` and `\` would read as
  backreferences.

- **A `RowReceiver` that leaves the scene tree and comes back receives rows
  again.** `_exit_tree()` unsubscribes the receiver's four listeners from the
  local database, but `_ready()` — which starts the subscription — runs once per
  node, not once per tree entry, so a receiver that was re-parented, pooled, or
  sat in a scene swapped out and back in stayed unsubscribed for the rest of its
  life: no rows, no signals, and no error to point at it. `_exit_tree()` now
  calls `request_ready()`, so the next entry re-subscribes. Re-subscribing is
  idempotent — the database ignores a listener it already holds — so a receiver
  cycled repeatedly still ends up with exactly one of each. A receiver that
  cycles *while* its subscription pass is suspended (waiting for the database at
  boot, or for the current rows) arms a second pass, and both would have replayed
  every existing row through `insert`; each pass now carries the tree-entry
  generation it was queued under and retires itself — on entry and at every
  resume point — once a newer entry has taken over. The generation is captured
  when the pass is queued rather than when it starts running, because the case a
  pool actually hits has nothing suspended at all: with the database already
  resolved, a remove-then-add with no frame in between simply queues two passes
  that both run at the next flush. The replay itself is unchanged and now documented
  on the `insert` signal: entering the tree replays the rows already present, so
  a handler that spawns per row should key by primary key. Covered by
  `tests/test_row_receiver_reparent.tscn`, the first scene-form test: the
  receiver names the `SpacetimeDB` autoload, whose identifier does not resolve
  under the runner's `--script` mode, and `run_tests.sh` now runs `test_*.tscn`
  as a normal main loop for that case.

- **Two nested column types whose class names differ only in case or underscore
  placement no longer collide.** The other half of the same lossy key: a module
  with types `FooBar` and `Foobar` generates `VnestFooBar` and `VnestFoobar`,
  which both normalize to `vnestfoobar`, so the second to load displaced the
  first and a column typed as one decoded as the other — right field count, wrong
  type, no error. A nested column names its type by the exact `class_name`
  spelling (a `BSATN_TYPES` entry reads `&"shape": &"VsumShape"`, and an
  `@export var`'s class-name hint is the same string) and Godot already enforces
  those are unique project-wide, so the registry now keys types by
  `Script.get_global_name()` and resolves nested columns through
  `SpacetimeDBSchema.get_type_by_class()`. That accepts the lowercased spelling
  too, since the deserialization plan lowercases every `BSATN_TYPES` value so a
  hand-written `"U32"` still finds a primitive reader — and when two class names
  differ only in case, the lowercased lookup now returns null and says so instead
  of picking whichever loaded last.

- **Two tables whose names differ only by an underscore no longer collide.**
  The schema registry keyed everything by `name.to_lower().replace("_", "")` —
  the strip is what lets a nested column typed `VsumShape` find the
  `vsum_shape.gd` that declares it, but it is lossy, and `user_data` / `userdata`
  are both legal SpacetimeDB table names that collapse onto one entry. The second
  to load silently displaced the first, so its rows decoded against the wrong row
  type and `_get_primary_key_field` returned the wrong column — every insert for
  that table looked like an update of a row that did not exist. Tables are now
  keyed by their exact wire name (lowercased, not stripped) and resolved through
  a new `SpacetimeDBSchema.get_table()`, which answers only from that map — a
  miss stays a miss rather than falling back to the lossy key and guessing.
  Types keep the lossy key, since class-name matching needs it, but a genuine
  collision there now warns unconditionally instead of only under `debug_mode`.

- **Codegen now fails loudly when two module names escape to one GDScript
  identifier.** Every name escape guarantees its result is free on the *base*
  class, but none of them could see a *sibling* that escaped to the same string:
  a module with a reducer `set` (escaped to `set_`, because `Object.set` is
  taken) alongside a reducer literally named `set_` emitted `func set_()` twice.
  Godot then refuses the script — `Parse Error: Function "set_" has the same name
  as a previously declared function` — and since a module's reducers share one
  class, every reducer in the module went down with it, at load time, from a
  message naming neither of the two module names. The generated output is now
  scanned for duplicate top-level members and the run fails with the file and the
  identifier. Deliberately not auto-renamed: which of `set` / `set_` gets the
  mangled spelling is the module author's call. Same shape covers column pairs
  (`count` / `count_`), table pairs (`table_names` / `table_names_`), and the
  autoload, whose member names come straight from the configured module aliases
  via `to_pascal_case()` with no escape applied — so aliases `my_module` and
  `myModule` both produced `var MyModule`. New
  `tests/test_member_collision_gate.gd` plus a `vcollide` fixture that reproduces
  it through the real generator, and the autoload now has golden coverage of its
  own (it is emitted per project rather than per schema, so no fixture reached
  it before).

- **Cancelling a reconnection now detaches a zero-delay backoff timer too.**
  `_cancel_reconnection()` only disconnected the pending timer when it still had
  time left, so a zero-delay one — previously only produced by the stall-induced
  fast path, and now by every resume — stayed connected and could call
  `_attempt_reconnect` after the cancel, dropping a newer cycle's timer reference
  and connecting a second time. `is_connected` already makes the disconnect a
  no-op for a timer that has fired, so the time check was doing nothing but
  letting that case through.

### Changed
- **Confirmed reads are on by default**, matching the server and the other SDKs.
  `SpacetimeDBConnectionOptions.confirmed_reads` defaulted to `false` and was
  documented as matching SpacetimeDB's default — it did not. The server treats the
  `confirmed` query parameter as optional and applies `DEFAULT_CONFIRMED_READS`
  (`true`) to any v2/v3 connection that omits it, on every supported server version
  (2.2.0 through 2.7.1), and the Rust and C# SDKs only send the parameter when the
  caller sets it. This SDK sends it on every connect, so it was actively opting out
  of read-after-commit: a Godot client could display rows from a transaction that
  was not yet durable, where a Rust or C# client against the same module would not.
  The default is now `true`; passing `false` keeps the old lower-latency behavior.
  The query string is built by a pure
  `SpacetimeDBConnection.build_query_params()`, covered by
  `tests/test_subscribe_query_params.gd`.
- Verified the SDK end-to-end against **SpacetimeDB 2.7.1**; the tested range is
  now `2.2.0`–`2.7.1`. No code change was needed — the client-facing wire format
  is byte-identical to 2.7.0 (2.7.1 touched metrics, an MCP route, and HTTP
  handler plumbing). Live suites re-run against a 2.7.1 server with modules built
  against the `2.7.1` bindings: types 6/6, behavior 15/15, enum-with-payload 1/1,
  anonymous `Result` 2/2, PK-less refcount 3/3, reconnect identity 1/1.

## [2.6.0] - 2026-07-28

### Fixed
- **`query_sql()` now returns its results.** It returned an empty array for
  every query. `_wait_for_response` connects a two-argument handler,
  `(request_id, payload)`, to whichever response signal it is awaiting, but
  `one_off_query_received` also carries `error_message` — Godot refused the
  call on the arity mismatch, so the handler never ran, the caller waited out
  its full timeout and the result was discarded. Call sites now declare how
  many trailing signal arguments the handler does not take, and the handler is
  connected with `Callable.unbind`. Verified against a live server.

- **A name that collides with a built-in method no longer breaks the whole
  binding.** Godot refuses to load a script whose method overrides a native
  one, so a module exporting a reducer or procedure named `set`,
  `notification` or `connect` — or an enum variant named `class`, which
  generated `get_class()` — produced a binding that failed to parse, taking
  every other table and reducer in the module down with it. Escaping only
  covered GDScript *keywords*, and these names are not keywords. Such names
  now generate `set_`, `notification_`, `get_class_` and so on. The same applies
  to names that come from a column, a table or an index accessor rather than a
  reducer — `script` and `resource_name` are properties on every Resource, and
  `count` and `iter` are methods on the table wrapper's own base — so those
  escape too, consistently across the row property, its `BSATN_TYPES` entry, the
  `create()` parameter and the index that resolves the property by name. The
  check asks the engine and the SDK base classes what is taken, rather than a
  hand-written list, so it stays correct across engine versions. The wire name is unchanged — `call_reducer('set', ...)` — so only
  the GDScript surface is renamed, and no working module could have depended
  on the old spelling because it could not load at all.

- **A reconnect now uses the options it was given.** `SpacetimeDBConnection`
  reads its socket-level settings once, in its constructor, and the client
  builds that object on the first `connect_db` and keeps it — so a later
  `disconnect_db()` / `connect_db(new_options)` pair silently kept the *first*
  call's compression preference, buffer sizes and heartbeat interval while the
  client's own fields reported the new ones. The settings move to
  `SpacetimeDBConnection.apply_options()`, which the client calls on a
  reconnect. Monitor registration moves with them: left behind, it would let
  `monitor_mode` disagree with what is actually registered, and teardown would
  either leak the monitors or remove names that were never added. Found by
  capturing a Brotli wire fixture that came back gzip-tagged.

### Performance
- **Cheaper row-change detection.** Change detection is value-based, which is
  what makes it correct — rows arrive as a fresh `.new()` with no interning, so
  identity compares fired spurious `row_updated` — but that left `_rows_equal`
  as the majority of update cost: ~50% of a primitive-row update and ~70% of a
  nested one. Two behaviour-neutral cuts: `_record_columns` memoizes each
  `Script`'s `BSATN_TYPES` column list, which was re-deriving through
  `get_script_constant_map().keys()` — two allocations — once per nested column
  per row compared; and `_rows_equal` compares primitive columns inline, calling
  `_values_equal` only for the `Object`/`Array` columns that need the recursive
  walk. Semantics are unchanged: differing types stay unequal, no `==` coercion,
  and `_row_hash` stays consistent with equality. Nested-row update 4340 →
  3830 ns/row, primitive 2690 → 2410 (`bench_apply_profile`, N=100k best-of-7).

## [2.5.0] - 2026-07-18

### Added
- **Deterministic binding UIDs + reproducible codegen output.** Generated
  bindings now get a stable `.uid` derived from an FNV-1a-64 hash of their
  `res://` path (masked to 63 bits, always positive), written and registered
  at generation time — so a fresh clone or regen keeps the same UIDs and
  scene/`.tres` references don't break. Schema sections that arrive from the
  server in HashMap order (modules, tables, reducers, procedures, and both
  unique and btree indexes) are sorted by a stable name key before emission,
  so the generated files are byte-for-byte reproducible. A boot-time collision
  scan reports any two bindings that hash to the same UID (astronomically
  unlikely, but deterministic if it ever happened).

- **Value-returning procedures now decode.** A procedure returning Rust's
  idiomatic `Result<T, String>` previously could not be decoded at all: the call
  succeeded and the bytes arrived intact, then decode failed with "Unsupported
  BSATN type `ResultVector3String`". This affected every value-returning
  procedure, not an edge case. `Result<T, E>` has no named Typespace entry, so the
  parser synthesizes one per distinct pair — but that flush ran before returns were
  parsed, leaving codegen pointing the decoder at a type that was never emitted.
  Verified end to end against a live module.
- **Native array-like returns and enum variant payloads.** A `Vector3`, `Color`,
  `Quaternion` or any other native array-like type now carries its component list
  (`vector3[f32,f32,f32]`) when it appears as a return type or as an enum/`Result`
  variant payload; without it the decoder had no component types to read. The
  suffix is applied to the base type before any wrapper prefix, so composed forms
  come out as `opt_vector3[f32,f32,f32]` and decode correctly. Struct fields and
  call parameters already carried it.
  > Note: this is reachable via **procedures only**. The Rust macro rejects a
  > non-unit reducer return outright (`is not a valid reducer return type`), so a
  > reducer cannot return one of these in the first place.

### Fixed
- **Truncated gzip frames are no longer silent.** `StreamPeerGZIP` consumes every
  byte it is handed, emits whatever it managed to inflate, and reports no error,
  and `finish()` is compression-only — so a short frame previously reached the
  BSATN reader looking like a complete one. The decompressed length is now
  cross-checked against the gzip ISIZE trailer. The old "may be truncated"
  warning never fired on truncation at all (it only ever caught trailing bytes
  after the member); it is reworded to say that, and suppressed when an input
  error has already reported its own cause.
- **`BSATN_TYPES` entries are now matched case-insensitively on decode.** The
  serializer already lowercased at its metadata read and the deserializer did
  not, so a hand-written `"U32"` would serialize correctly and then miss every
  lowercase-keyed reader, silently falling back to the `Variant.Type` default
  and decoding an `i64` where a `u32` was meant. Two schema lookups that used raw
  or underscore-only keys now normalize the same way the keys are stored.
- **Performance monitors follow a reconnect to a different database.** The client
  reuses one connection object across reconnects, so pointing it at another
  database left the monitors reporting under the original name — and leaked them,
  since teardown removes by the current name. Registration is now driven from a
  single suffix-to-getter table instead of three hand-maintained copies.
- A non-`RefCounted` instance from the `ClassDB` fallback is freed rather than
  leaked on the error return, and a debug warning no longer fires when a schema
  script is legitimately registered under both its declared and filename keys.

### Changed
- **Tests now run in CI.** The only workflow was release-on-tag, so nothing ran
  the suite on push or pull request. Tests run per push and PR against Godot
  4.7.1-stable; benches get a separate weekly workflow, since they are not
  correctness gates and several take minutes each.
- **Test fixtures now include real wire bytes.** Every test previously built its
  bytes by hand or round-tripped the SDK's serializer against its own
  deserializer — both self-consistent, so a divergence from what the server
  actually sends stayed invisible (which is how the procedure decode bug above
  survived a green suite). Captured frames from a live module now cover a
  subscription snapshot, a nested struct, a reducer result, and a
  value-returning procedure return, replayed without needing a server.

### Performance
- **Gated the native-array-like probe in `_read_value_from_bsatn_type`.** That
  function is recursed into once per element for a `Vec<T>` of non-primitives, so
  an unconditional regex search there was charged to every nested struct element
  in an array. Measured on 4.8.dev: ~152 ns for the search against ~18 ns for the
  trailing-bracket check that now guards it. Only a component list ends in `]`, so
  the gate cannot skip a real match. Both benches are committed
  (`tests/bench_arraylike_probe.gd`, `tests/bench_vec_struct.gd`).

## [2.4.0] - 2026-07-15

### Added
- **SpacetimeAuth OIDC token exchange.** A `SpacetimeAuth` node (thin
  `HTTPRequest` glue with an exponential-backoff retry loop) exchanges a
  provider credential for a SpacetimeDB token. Provider-agnostic — the
  `grant_type` and request fields are caller-supplied — with the endpoint,
  `grant_type`, Steam fields, and `id_token`/`expires_in` contract verified
  against the official SpacetimeDB 2.7.0 docs. Ships alongside
  `SpacetimeAuthProtocol` (pure, network-free transforms: form-encode, retry
  decision, backoff math, response classify, credential redaction),
  `SpacetimeAuthResult` (POD outcome), and a `JwtHelper` for unverified
  client-side JWT payload decode (reading claims such as `login_method` for
  local bookkeeping — not a security boundary).

### Fixed
- Keep the BSATN deserializer worker thread on **threaded** Web exports.
  The guard now gates on `OS.has_feature("threads")` instead of
  `OS.has_feature("web")`, so cross-origin-isolated (SharedArrayBuffer /
  COOP-COEP) Web builds keep the background deserializer instead of being
  forced onto the slower main-thread path; genuinely non-threaded builds
  still fall back cleanly.

### Changed
- Verified the SDK end-to-end against **SpacetimeDB 2.7.0**; tested range is now
  `2.2.0`–`2.7.0`. No code change — the v3 WS sub-protocol, schema v10, and the
  BSATN wire format are unchanged from 2.6.0. Live integration suites
  (extended scalars, cache behaviors, reconnect, enum/`Result` columns) all pass.

## [2.3.3] - 2026-06-21

### Added
- MIT `LICENSE` inside `addons/SpacetimeDB/` so the packaged addon ships its own
  license file, as required by the Godot Asset Store. Same MIT terms as the
  repo-root license (flametime + plaught-armor); no license change.

### Changed
- Inbound apply-path performance (no API or runtime-behavior change): skip
  duplicating an empty listener array when applying a row, coalesce per-packet
  statistics signals into one emission per frame, and order incoming-message
  dispatch hottest-case first.

## [2.3.2] - 2026-06-19

### Changed
- Renamed the plugin to **SpacetimeDB Godot SDK** (was "SpacetimeDB Client SDK")
  in `plugin.cfg`, matching the README heading and the asset listing.
- Code-quality cleanup, no API or runtime-behavior change: value-only `match`
  statements converted to `if/elif` (cheaper dispatch in interpreted GDScript),
  emptiness checks moved to `.is_empty()`, and single-argument `range(n)` loops
  replaced with direct `for i in n` (no intermediate array allocation). The
  codegen template emits the same `if/elif` form for the generated
  `parse_enum_name`; generated output is behavior-identical (goldens updated).

### Added
- Brand logo lockup and a 1920×1080 Asset Store thumbnail under `docs/images/`.
  The README now self-hosts a theme-adaptive logo (`<picture>`) instead of an
  external image attachment.

## [2.3.1] - 2026-06-19

### Fixed
- **Index-listener crash on an update for an uncached row.** A delete+insert of
  the same primary key (the server's "update" encoding) for a pk not currently in
  the local cache fired `row_updated` with a null `prev`; the unique/btree index
  cache listeners dereference `prev` and crashed. Such updates now take the insert
  path (null `prev` = no prior row), so listeners never receive a null.
- **Stall detection silently off after a retry-while-connecting.** Reconnecting
  while a previous attempt was still in progress recreated the `WebSocketPeer` but
  re-applied only the buffer sizes, not `heartbeat_interval` — the retried socket
  ran with keepalive disabled. Heartbeat is now re-applied on the recreate.
- **`u64` values ≥ 2^63 could not be serialized.** `write_u64_le` rejected a
  negative i64, but a u64 with the high bit set arrives as a negative i64 — large
  ids / hashes / `u64` columns were un-encodable. The guard is removed (`put_u64`
  writes the correct 8 bytes for the full u64 range).

### Security / robustness
- **Bounded the row-list deserializer against malformed input.** Row counts
  (`num_rows` / `num_offsets`) are capped before the backing `PackedInt64Array`
  resize (an unchecked u32 could force a multi-GiB allocation), and the row-data
  block is validated against the buffer — a `data_len` past the buffer now yields
  NEEDS_MORE (the framer keeps the tail) instead of seeking past EOF and silently
  dropping every subsequent message.
- **Bounded gzip/Brotli decompression.** The gzip decode loop had no output
  ceiling (a decompression bomb never terminated); added a 128 MiB cap (well above
  any real frame) and applied it to the Brotli buffer. The serializer no longer
  emits zero-filled bytes on a fixed-size mismatch, and `_wait_for_response` guards
  `is_instance_valid(self)` after its `await`.

### Changed
- Internal code-quality cleanup, no API or generated-output change: codegen builds
  each file with a `PackedStringArray` accumulator instead of repeated string
  concatenation; the schema parser and the index/listener code gain consistent
  typing and drop inline lambdas. The codegen golden suite confirms byte-identical
  output.

## [2.3.0] - 2026-06-19

### Added
- **Btree range and bound lookups.** A btree (non-unique) index over an
  *orderable* column (`int` / `float` / `String`) now generates `filter_range(from,
  to)` (inclusive `[from, to]`) plus the one-sided `filter_gte` / `filter_gt` /
  `filter_lte` / `filter_lt`, alongside the existing exact-match `filter(value)`.
  All ride a sorted-key mirror maintained at the index's bucket create/empty edges,
  so a range binary-searches the window (O(log d + k) over d distinct keys) instead
  of scanning. Bytes-backed keys (`Identity`, `u128` / `u256`) keep exact-match
  `filter()` only — `Array.bsearch` has no defined ordering for them. Regenerate
  bindings to pick this up.
- **Per-request latency stats.** `SpacetimeDBClient.get_stats()` returns a
  `SpacetimeDBStats` tracking round-trip time bucketed by request category (reducer
  / procedure / one-off / subscribe): count, min / max / avg / last latency, and an
  in-flight gauge. `get_stats().summary()` dumps all four categories; `.get_tracker(
  SpacetimeDBStats.Category.REDUCER)` reads one. Always-on (one
  `Time.get_ticks_usec` plus two dictionary ops per request), main-thread, with a
  bounded pending set so a never-answered request can't leak. No codegen or wire
  change — works with existing bindings.

### Changed
- **The btree (non-unique) index is now a real multimap cache.** Its `filter()`
  was a linear `find_by` scan of the whole table; it now keeps a per-value bucket
  cache (`Dictionary[value, Array[Row]]`) maintained live by insert/update/delete
  listeners, so a `filter()` is a dictionary lookup plus the *k* matching rows
  instead of an *N*-row scan. The per-field finders for a btree-indexed field now
  route through it (`find_by_<field>` → `filter()`, `first_by_<field>` returns the
  bucket's first row directly); previously they used the linear fallback.
  Regenerate bindings to pick this up.

### Documentation
- **`docs/design-decisions.md`** records the June 2026 four-SDK parity audit: what
  this SDK builds, what's blocked by the v2/v3 wire (caller identity, energy,
  out-of-energy, reducer flags — removed from the wire at the v1 → v2 cut, so no
  client SDK can surface them), and what's deliberately out of scope with the
  trigger that would justify reopening each. Linked from both doc indexes.
- **README "Known Limitations & Caveats"** gains the wire-blocked entries above and
  is split by kind: genuine user-facing limitations stay in the README; design
  choices (`Timestamp` / `TimeDuration` as `int` micros; deferred schema-v10
  `default_values` / namespaces) move to `docs/design-decisions.md`.

## [2.2.0] - 2026-06-18

### Changed
- **Unique-indexed finders are now O(1).** The generated `find_by_<field>` /
  `first_by_<field>` for a field backed by a *unique* index now routes through that
  index's `find()` — a constant-time lookup against the live `Dictionary` cache —
  instead of the linear `find_by` scan. For a table of N rows, a lookup by a
  unique-indexed field drops from N comparisons to a single dictionary get.
  `first_by_<field>` returns the row directly; `find_by_<field>` wraps it in a
  0-or-1 array. Non-unique (btree) and non-indexed fields keep the linear path —
  the btree index's `filter()` is itself a linear `find_by`, so routing there would
  add a hop for no gain. Regenerate bindings to pick this up.

## [2.1.0] - 2026-06-18

Codegen developer-experience release. Generated table classes gain typed change
signals and typed per-field finders. Pure additions to the generated text — no
base-class, runtime, or wire change; regenerate bindings to pick them up.

### Added
- **Typed table change signals.** Each generated table wrapper now exposes
  `inserted(row)`, `updated(old_row, new_row)`, and `deleted(row)` signals typed to
  the concrete row class, wired to the base `on_insert` / `on_update` / `on_delete`
  listeners. A table-scoped, editor-discoverable parallel to the existing Callable
  API.
- **Typed per-field finders.** Each table wrapper generates `find_by_<field>(value)`
  and `first_by_<field>(value)` for every scalar field — a compile-checked field name
  and value type and a typed return, replacing the stringly-typed
  `find_by(&"field", value)`. Generated for non-nested, non-arraylike fields only.

### Notes
- The committed Blackholio example bindings (`godot-client/spacetime_bindings/`) are
  regenerated against a live module and demonstrate the new signals and finders;
  the regenerated bindings compile as part of the project.

## [2.0.0] - 2026-06-18

**Breaking.** The legacy WebSocket v2 sub-protocol is dropped; the client now
advertises only v3. This raises the minimum server to **SpacetimeDB 2.2.0** (the
first release that speaks v3). Connecting an SDK 2.0 client to a server below
2.2.0 fails the handshake — stay on an SDK `1.x` release for those servers.

### Changed
- **WebSocket handshake advertises `[v3.bsatn.spacetimedb]` only.** Previously the
  client offered `[v3, v2]` and let pre-2.2.0 servers negotiate v2. v3 reuses the
  v2 message schema (a single frame may carry several concatenated BSATN messages,
  which the receive path already drains), so this is a transport-advertise change
  only — no message-format, deserializer, or codegen change.

### Removed
- The `BSATN_PROTOCOL` (`v2.bsatn.spacetimedb`) constant and the v2 entry in the
  advertised sub-protocol list.

### Migration
- Server on 2.2.0+: no action — the client already preferred v3, so the negotiated
  protocol is unchanged.
- Server below 2.2.0: upgrade the server to 2.2.0+, or pin the SDK to the latest
  `1.x` release.

## [1.9.0] - 2026-06-18

Connection-robustness release. Hardens auto-reconnect against main-thread stalls
and a set of reconnect/resubscribe edge cases. No breaking changes.

### Added
- **Stall-aware reconnect.** A main-thread stall longer than `heartbeat_interval`
  makes Godot's `WebSocketPeer` miss a pong and close the socket (`code -1`) — the
  close is engine-side and unavoidable, but its cause is local, not a network drop.
  The connection now measures the wall-clock gap between polls; a gap at or beyond
  the heartbeat window arms a short guard, and an abnormal close inside it is
  surfaced on a new `connection_stalled` signal instead of `connection_error`. The
  client reconnects immediately (backoff skipped on the first attempt), reusing the
  existing save/restore-subscriptions path, so a stall recovers near-instantly and
  quietly rather than ramping a multi-second backoff.

### Fixed
- **Re-drop mid-resubscribe could lose subscriptions and double-fire `reconnected`.**
  Queries from an interrupted resubscribe cycle sit in `pending_subscriptions` (not
  yet applied), so rebuilding the saved set from `current_subscriptions` alone
  dropped them; and a superseded cycle's late `applied`/`end` still ran. A
  per-cycle epoch now bails stale settle callbacks, and the saved set is rebuilt
  (from both current and pending subscriptions) only when empty.
- **`_resubscribe_saved_queries` mutated the list it was iterating.** The saved
  array is now snapshotted up front and the clear+emit deferred until after the
  loop.
- **`disconnect_db()` on an already-closed socket emitted nothing.** When cancelled
  mid-backoff during a reconnect, `disconnect_from_server()` was a no-op, leaving
  callers waiting on `disconnected` forever and the intentional-disconnect flag
  stuck. It now self-emits `disconnected` and clears the flag when not connected.
- A stall during an in-flight reconnect now keeps the no-backoff fast path.

## [1.8.0] - 2026-06-18

Test-gate and codegen-coverage release. No runtime SDK behavior change — this
release adds the infrastructure to keep the SDK from regressing: a local test
runner, a pre-push gate, and golden-file coverage that locks the exact text
codegen emits.

### Added
- **Local test runner** (`godot-client/run_tests.sh`). Runs every `test_*.gd`
  headless, one Godot process per test (each `extends SceneTree` and exits with
  its failure count, so the runner's exit code is the signal). Takes a single
  test name, honors `GODOT_BIN` and `VERBOSE`, and builds the import cache on
  first run. Exits `0` on all-green, `1` on any failure.
- **Pre-push hook** (`.githooks/pre-push`). Runs the suite and blocks the push
  on failure. Committed but inert until enabled with
  `git config core.hooksPath .githooks`; override a run with `git push --no-verify`.
- **Codegen golden tests** (`test_codegen_golden.gd`). Parses the captured v10
  schema fixtures, runs the generator, and diffs every emitted file against a
  committed golden (49 files across three modules — types, tables, unique
  indexes, scheduled and event tables, wide ints, `Uuid`, `Result` and sum
  types). Catches both changed output and dropped files; regenerate
  intentionally with `STDB_REGEN_GOLDEN=1`. Codegen *behavior* was already
  covered by roundtrip tests; the generated *source text* was not.
- **`CONTRIBUTING.md`** documenting the test, pre-push, and golden-regen workflow.

### Docs
- The `TimeDuration` / `Timestamp` "surfaced as `int` microseconds" caveat is
  reframed as a deliberate data-oriented choice rather than a missing feature:
  both are an `i64` micro count on the wire, and wrapping either in a per-value
  `Resource` would add heap churn on the hot path to encode a distinction that
  is a transform concern, not a data-shape one. `ScheduleAt` still models the
  one case where the variant tag is real wire data.

## [1.7.0] - 2026-06-18

Inbound-parse performance pass. The BSATN deserializer's per-row hot path is
reworked across four orthogonal layers — no public API change, no codegen change,
behavior unchanged, full suite green. On a captured Blackholio replay
(`godot-client/benchmark/profile_deser.gd`):

- **parse-only** 47,496 → 69,618 rows/s (**1.47x**)
- **parse + apply** 40,738 → 55,197 rows/s (**1.36x**)

### Performance
- **Inlined fixed-width reads.** A decomposition of generic per-row parse showed the
  cost is GDScript function-call depth, not read logic (the `read_*_le → _check_read →
  has_error()` chain was ~32% of parse). Each fixed-width reader (`i8`–`i64`, `u8`–`u64`,
  `f32`/`f64`) now does its bounds compare inline and calls the native `get_*` directly;
  the underflow path moves to a shared `_read_underflow_int` helper so the happy path is
  just compare + read. Standalone: parse-only 1.19x, parse+apply 1.17x. Applies to every
  primitive field of every row.
- **if-elif type-code plan executor.** The plan's per-field `step.reader.call(spb)`
  Callable dispatch (~44% of parse) is replaced by a frequency-ordered if-elif on a
  per-field `type_code` resolved once at plan-build; the 10 fixed-width primitives read
  inline (no `Callable.call`, no per-field re-check). A fair dispatch bench
  (`bench_dispatch_mechanism.gd`) confirmed there is no real jump table in interpreted
  GDScript and that `match` is *slower* than the Callable it would replace (~0.83x) —
  if-elif + inline read is the win (1.44x).
- **Nested-resource plan hoist.** `_read_nested_resource` re-resolved the nested type
  every row (a `_schema.get_type()` + `_get_or_build_plan()` + `_normalize()` per row).
  `_PlanStep` now carries a pre-resolved `nested_script` + lazily-built `nested_plan`;
  the row loop runs it directly. ~1.26x on nested-resource rows, ~1.13x on saturated
  bulk ingest. Gated to the exact generic path it replaces — `ScheduleAt`, `Identity`,
  `RustEnum`, and other custom-reader types keep their own paths.
- **Value-only `match` → if-elif.** A GDScript `match` arm costs ~10 bytecode ops
  (typeof + value compare + bool materialize + branch) vs ~2 for an if branch, so it's
  the wrong construct for pure value dispatch. Four hot-path matches (native vector/color
  field dispatch, primitive reader/writer resolution) plus ~23 cold ones across 8 files
  are converted. On a native-vector schema (4 `Vector3` fields/row): READ 1.36x,
  WRITE 1.27x. Computed subjects are hoisted to a typed local once (as `match` did);
  error semantics, arm order, and bodies unchanged.

### Fixed
- **WebSocket URL scheme rewrite.** `base_url.replace("http","ws")` could rewrite a
  stray `"http"` anywhere in the URL (e.g. in a host, path, or query segment), not just
  the scheme; the trailing `.replace("https","wss")` was also dead (the first replace
  already consumed it). The rewrite now matches only the leading scheme via
  `begins_with` (`https://` checked first, as `http` is a prefix), leaving any later
  `http://` substring untouched.

### Internal
- Removed dead `_call_writer_callable` (zero callers, superseded by the pre-bound
  `CONTEXT_WRITERS` plan dispatch).
- New benches + tests for the above: `bench_dispatch_mechanism`, `bench_native_vector`,
  `bench_vec_ctx`, `bench_e2e_receive`, `bench_specialized_parser`, plus
  `test_inline_reader_bounds`, `test_nested_plan_hoist`, and `test_nested_hoist_fuzz`
  (32/32) — the prior nested tests used a null schema, so the hoist branch never engaged
  and would have masked corruption.

### Docs
- Bumped the tested SpacetimeDB range to 2.6.0.

## [1.6.0] - 2026-06-17

Client-cache and reconnect correctness pass, broader BSATN type coverage, WebSocket
keepalive, and tagged-sum (enum-with-payload / `Result`) column support. The new
serialization types and behaviors are verified end-to-end against a live SpacetimeDB
2.6.0 server — see [`integration-tests/`](integration-tests/).

### Added
- **WebSocket keepalive.** `SpacetimeDBConnectionOptions.heartbeat_interval_seconds`
  (default `15.0`) sends WS pings and surfaces a dead/half-open socket as a close
  (triggering auto-reconnect) within ~2 intervals, instead of waiting out the OS TCP
  timeout. `0.0` disables.
- **Wide BSATN integers** `i128`, `u256`, `i256` (raw `PackedByteArray`, little-endian),
  and **`Uuid`** columns (wire-identical to `u128`).
- **`ScheduleAt`.** New `ScheduleAt` resource (`Interval | Time` + microseconds) with
  full serialize/deserialize; codegen maps `#[scheduled]`-table `scheduled_at` columns
  to it (previously a lossy `i64` that discarded the variant tag).
- **Tagged-sum (enum-with-payload) columns.** Rust enums with per-variant data
  round-trip as `RustEnum` values (`value` = tag, `data` = payload), read and write.
- **Anonymous inline `Result<T, E>` columns.** Codegen synthesizes a named `RustEnum`
  type per distinct `Result<T, E>`.

### Fixed
- **Overlapping-subscription cache correctness.** Rows are now refcounted: a row shared
  by multiple subscriptions fires `on_insert` once (0→1) and `on_delete` only when the
  last holder drops it (1→0). Previously a shared row produced spurious updates/deletes.
  Covers both primary-key tables (keyed by PK) and PK-less tables (keyed by row value,
  multiplicity-counted).
- **Unsubscribe now prunes the cache.** `unsubscribe()` requests dropped rows
  (`SendDroppedRows`) and removes only rows no longer held by another subscription;
  previously a query's rows lingered indefinitely.
- **Event tables.** Event-table rows fire `on_insert` but are no longer stored in the
  cache (`count()` / `iter()` stay empty).
- **`ConnectionId` byte order.** Deserialization now reverses to canonical order,
  matching `Identity` and the serializer (was asymmetric → round-trip mismatch).
- **Fallible-reducer error messages.** The `err` payload (a BSATN length-prefixed
  string for `Result<_, String>`) is now decoded; previously it came through empty.
- **`SubscriptionError` on an applied subscription is now pruned precisely.** The SDK
  tracks per-query row membership, so on an error it drops exactly that query's rows
  (decrementing refcounts; rows still held by another subscription survive) — no
  disconnect or full rebuild, and it works regardless of `auto_reconnect`. Previously
  it reset the connection (reconnect on) or left stale rows (reconnect off).
- **Reducer/procedure `wait_for_response()` returns the handle.** `await
  reducers.foo(args).wait_for_response()` now yields the `SpacetimeDBReducerCall` /
  `SpacetimeDBProcedureCall` itself, so the unambiguous `outcome` (OK / OK_EMPTY / ERROR /
  INTERNAL_ERROR / TIMEOUT / DISCONNECTED), `decode()`, and result are available in one
  step — instead of a bare `TransactionUpdateMessage`/bytes that was `null`/empty on
  timeout, okEmpty, error, and disconnect alike.
- **Removed a per-call array allocation** from the `find_where` / `first_where` /
  `find_by` / `first_by` / `count_where` cache-query helpers (they iterated
  `Dictionary.values()`); they now iterate keys directly, and the `first_*` variants no
  longer allocate the whole table to return a single row.
- **Disconnect no longer blocks pending waits.** `query_sql()` and the
  `wait_for_reducer_response()` / `wait_for_procedure_response()` helpers return
  empty/`null` immediately on disconnect rather than waiting out their timeout.
- **One-off query cache** is cleared on reconnect (a post-reconnect request id could
  otherwise read a stale cached result).
- **Spurious "Bytes remaining" warnings removed.** Under v3 WebSocket message batching
  a single packet carries several concatenated messages; after parsing each one the
  parser saw the next as "trailing bytes" and logged a warning per message (hundreds of
  thousands under load). The framing loop already consumes batched frames correctly, so
  the warning was always bogus.

### Performance
- **Apply hot path.** `LocalDatabase` insert/update/delete now applies primary-key
  tables in a single pass (was a delta dictionary plus a second pass), skips
  update-detection for pure insert/delete batches, and keys per-query subscription
  membership by row hash. Behavior-unchanged; lower per-row cost under load.
- **Deserializer.** Dropped redundant per-read endian sets and hoisted the per-row
  deserialization-plan lookup out of the row loop. (Profiling confirms parse is ~85% of
  the inbound pipeline; the remaining cost is intrinsic to per-row `Resource`
  construction — see `godot-client/benchmark/`.)

### Docs
- README **Known Limitations & Caveats** section; documented the new types and behaviors.
- **`integration-tests/`** — live-server verification modules + headless harnesses
  (wide ints / `Uuid` / `ScheduleAt`, the cache trio, enum-with-payload and `Result`
  columns), with run instructions.
- **`godot-client/benchmark/`** — in-process apply micro-bench, real-workload replay
  from a captured Blackholio packet stream, and a parse-vs-apply deserializer profiler.

## [1.5.0] - 2026-06-17

Client feature-parity pass against the official C# and TypeScript SDKs, plus a
fix to make the Blackholio example actually build and run.

### Added
- **BTree index accessors.** Each single-column non-unique btree index gets a
  typed `filter(value) -> Array[Row]` accessor on its table wrapper (columns
  already covered by the primary key or a unique constraint keep `find()`).
- **`subscribe_all_tables()`** on generated module clients — subscribes to every
  table in the module with a single handle.
- **Brotli decompression** via Godot's built-in decoder. `CompressionPreference.BROTLI`
  now works instead of falling back to GZIP.
- **Light mode & confirmed reads.** `SpacetimeDBConnectionOptions.light_mode` and
  `confirmed_reads` (the latter was previously hardcoded `false`).
- **`on_before_delete` row callback** + `row_before_delete` signal — fires while
  the row is still queryable in the cache, before removal.
- **Query builder** `where_in(field, values)` (`IN (...)`) and
  `where_any(pairs)` (OR group).
- **Typed reducer return values.** `SpacetimeDBReducerCall.decode()` returns the
  typed ok value; codegen threads each reducer's `ok_return_type` automatically.

### Fixed
- **Blackholio example server** depended on `spacetimedb = { git = master }`,
  which drifts and breaks against a released server. Pinned to the released crate
  and resynced the client bindings (adds the `consume_entity_event` event table).
- Removed dead v1-vestigial `ReducerCallInfoData` / `UpdateStatusData` classes
  (the v2 wire `TransactionUpdate` carries only `query_sets`).

### Docs
- Documented all the above; corrected a version contradiction (tested floor is
  2.1.0, matching the schema-v10 requirement) and stale "Brotli not supported"
  notes. Committed missing `.uid` sidecars for the bench scripts.

## [1.4.0] - 2026-06-16

Rolls up everything since `1.3.1` (which was never tagged; feature work landed
after it, so this is published as a minor release).

### Added
- v3 WebSocket protocol negotiation and parsing of view primary keys.
- Headless codegen CLI entry point (generate bindings without opening the editor).
- UI logging toggle; schema generation flow refactored.

### Fixed
- **Serializer crash on first serialize of a struct.** `_serialize_resource_fields`
  read its plan with `_serialization_plan_cache.get(script)` (no default), which
  returns `null` on a cache miss; assigning that to the typed `Array` raised a
  runtime error the first time any struct/Resource reducer argument was serialized.
  Now mirrors the deserializer's `.get(script, [])` + `has()` guard.
- Robust message framing and a reconnect race in the deserializer/client.
- Subscription state machine: `ENDED` is now terminal — a late/out-of-order
  `applied` can no longer resurrect a subscription to `ACTIVE`.
- Drain limits from connection options are clamped (message ceiling, time-budget
  floor) so a misconfigured budget can't starve the apply loop.
- Critical, high, and medium defects from a wire/async audit pass.

### Performance
- **Adaptive per-frame message drain** — fixed 5-messages/frame replaced by an
  fps-aware AIMD time-budget controller plus a hard ceiling.
- **Cursor-based drain** — a backlog drains via an advancing cursor instead of
  re-slicing/re-queuing the unprocessed tail every frame (O(1)/frame vs
  O(remaining); ~80x less re-queue overhead clearing a large burst).
- **In-place row deserialization** — rows parsed directly from the message buffer
  (seek to per-row offset) instead of slicing each into its own buffer + a scratch
  `StreamPeerBuffer`. Over-read is now a hard error (schema/wire mismatch).
- **Typed (de)serialization plans** — per-field plans use a typed record instead
  of a `Dictionary`, dropping a hash lookup per field per row on both read and
  write paths.
- **Gzip decompression** feeds/drains in 64 KiB chunks instead of 4 KiB
  (~13% on ~1 MiB payloads).

### Tests
- Added coverage (previously absent) for: BSATN row-list deserialization (both
  encodings + over-read), gzip decompress round-trip, serializer round-trip,
  per-frame drain stop rule + cross-frame cursor, drain-budget clamps + AIMD
  controller, and the subscription state machine.

### Internal
- Explicit static typing and a formatting pass across the addon.

## [1.3.1] - Never tagged (rolled into 1.4.0)

These changes were prepared as `1.3.1` but never released under that tag; they
shipped as part of [1.4.0](#140---2026-06-16).

### Changed
- Added type annotations across core files (`local_database.gd`, `schema_parser.gd`, `spacetime.gd`, `row_receiver.gd`, `ui.gd`)
- Encapsulated WebSocket access behind `is_websocket_active()` in `spacetimedb_client.gd`
- Schema parser: extracted `_find_type_index()` helper, removed redundant blank lines
- Removed outdated migration guides (0.2.0, 1.0), kept only 1.3.0

## [1.3.0] - 2026-03-24

### Breaking
- **Requires SpacetimeDB 2.1.0+** — schema v9 support has been completely removed. The codegen now exclusively uses schema v10 (`?version=10`), which is only available in SpacetimeDB 2.1.0 and later. Users on SpacetimeDB 2.0.x must upgrade.

### Changed
- Schema parser reads v10 section-based format natively instead of normalizing to v9 shape
- Codegen string templates hoisted to top-level constants for Godot 4.7 compatibility
- Removed PK-less table debug noise (`print_debug` for event/PK-less tables)
- Blackholio example: typed dictionaries, removed dead code, deduplicated circle removal

## [1.2.0] - 2026-03-22

### Added
- One-off queries: `query_sql()` method and `one_off_query_received` signal for executing SQL without subscriptions
- Reducer return values: `SpacetimeDBReducerCall.ret_value` exposes BSATN-encoded return bytes from reducers
- Schema v10 support: codegen fetches the v10 module definition format when available, with section-based structure, `is_event` table flag, explicit name mappings, and separated lifecycle/schedule sections. Falls back to v9 for older servers (2.0.x).

### Changed
- `OneOffQueryMessage` now includes `request_id` field matching the v2 protocol
- Schema fetch now tries `?version=10` first, falls back to `?version=9` automatically

## [1.1.1] - 2026-03-12

### Added
- Blackholio example client (agar.io clone) replacing the previous test example
- GDScript documentation comments to all SDK classes

### Fixed
- Subscribe message serializing `query_id` as `i64` instead of `u32`
- BSATN type warning now appears after fallback instead of before
- Added `SubscribeApplied` debug log

## [1.1.0] - 2026-03-04

### Added
- Codegen enum deduplication: automatically reuses matching project enums instead of generating duplicates
- Query helpers on `ModuleTable`: `find_where()`, `first_where()`, `find_by()`, `first_by()`, `count_where()`
- Return types on `Option` methods

### Changed
- Moved plugin config to addon folder, consolidated hardcoded paths
- Replaced unnecessary `StringName` usage with `String` where not used as dictionary keys
- Reverted typed `Array` returns in `ModuleTable` base class

### Fixed
- Naming typos, extracted cache helper, removed dead signal
- Cleaned up debug prints, stale comments, and duplicated logic
- Removed commented-out code

## [1.0.0] - 2026-03-03

### Added
- **SpacetimeDB 2.0 support** with v2 BSATN binary protocol
- **Procedures**: full support for SpacetimeDB 2.0 procedures with `SpacetimeDBProcedureCall` handle, `wait_for_response()`, and `decode()`
- **Deep nesting**: arbitrary nesting of `Option<T>` and `Vec<T>` types (`Option<Option<T>>`, `Vec<Vec<T>>`, etc.)
- **Subscription lifecycle**: `end` signal fires on unsubscribe confirmation, error propagation via `error_message`, handles invalidated on disconnect/reconnect
- **Subscription error handling**: `wait_for_applied()` resolves immediately with `ERR_DOES_NOT_EXIST` on error instead of timing out
- **Structured reducer errors**: `SpacetimeDBReducerCall` with typed `Outcome` enum
- **Query builder**: `SpacetimeDBQuery` with fluent API, SQL identifier validation, and auto-escaping
- **Auto-reconnection**: exponential backoff with jitter, configurable via `SpacetimeDBConnectionOptions`
- **PK-less table storage**: hash-based batch delete for tables without a primary key
- Migration guide from 0.2.x to 1.0

### Changed
- `SpacetimeDBSubscription` is now `RefCounted` instead of `Node`
- Query builder validates identifiers (alphanumeric and underscores only)

### Removed
- `reducer_call_response` and `reducer_call_timeout` signals (replaced by `SpacetimeDBReducerCall` handle)

## [0.2.5] - 2025

### Fixed
- BSATN Deserializer `Array[Vector2i]` parsing
- Subscription messages now fully update the local DB before firing callbacks
- Plugin UI signal hookup for config changes
- Read-only dictionary fix
- Missing `plugin_config` file

## [0.2.4] - 2025

### Added
- Plugin UI and GDScript-based codegen

## [0.2.3] - 2025

### Added
- Rust sum type enum support for serialization
- Nested struct deserialization
- Array deserialization
- Web compatibility and default web export

### Changed
- Massive refactoring of core serialization
