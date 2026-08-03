# Unit test for RowReceiver's subscription lifecycle across a reparent.
#
# _exit_tree() unsubscribes from the table, but Node._ready() only ever runs once
# per node, so a receiver that leaves the tree and comes back (a pooled UI panel,
# a re-parented actor, a scene swapped out and back in) stayed silently
# unsubscribed: no error, no rows, nothing to see from the outside. The fix is a
# request_ready() in _exit_tree, which re-arms _ready for the next entry.
#
# Re-arming opens a second question the tests below pin down: the subscription
# path awaits (for the database, then for the current rows), so a receiver that
# cycles while one of those awaits is suspended arms a second pass, and both
# passes would replay every existing row through `insert`. A generation counter
# retires the stale pass.
#
# The probe replaces the two boundaries that need a live server — _get_db and
# _subscribe_to_table — and drives the real _init_subscription, so the generation
# guard is what is under test rather than a copy of it.
#
# This one runs as a SCENE rather than a --script test: row_receiver.gd names the
# SpacetimeDB autoload, and autoload identifiers only resolve when Godot boots a
# normal main loop. run_tests.sh runs test_*.tscn for exactly this case.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       tests/test_row_receiver_reparent.tscn
extends Node


# An anonymous row type: on_set rejects _ModuleTableType itself (it is the base
# class, not a table), and an inner class reports an empty global name, so this
# passes that check without a generated binding in the project.
class _FakeRow:
	extends _ModuleTableType


# Counts subscription passes that reach the point of actually subscribing, and
# lets the test hold _get_db suspended to reproduce a cycle mid-resolution.
class _ProbeReceiver:
	extends RowReceiver

	signal db_released

	var subscribe_calls: int = 0
	var db_calls: int = 0
	var block_db: bool = false
	# Only ever checked for validity by the code under test — the overrides below
	# stand in for every call that would touch its contents, so an empty schema is
	# enough to build one.
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Probe"))


	func _get_db(_wait_for_init: bool = false) -> LocalDatabase:
		db_calls += 1
		if block_db:
			await db_released
		return db


	func _subscribe_to_table(_db: LocalDatabase, _table_name_sn: StringName, _generation: int) -> void:
		subscribe_calls += 1

	# selected_table_name is empty on a probe (no table_names constant to derive
	# from), which the real _subscribe_to_table treats as "nothing to do" — the
	# override above counts the call instead, so the empty name is fine.


# Keeps the real _subscribe_to_table — including its row replay and the guards
# around its awaits — and holds the row fetch open instead, so the assertion can
# be the symptom itself: how many times each existing row reaches `insert`.
class _ReplayProbe:
	extends RowReceiver

	signal rows_released

	var rows: Array[_ModuleTableType] = []
	var block_rows: bool = false
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Probe"))


	func _get_db(_wait_for_init: bool = false) -> LocalDatabase:
		return db


	func get_table_data() -> Array[_ModuleTableType]:
		if block_rows:
			await rows_released
		return rows


var _total: int = 0
var _probes: Array[_ProbeReceiver] = []
var _replay_probes: Array[_ReplayProbe] = []
var _insert_count: int = 0


func _ready() -> void:
	# M1: the checks await, so they run from a deferred coroutine rather than
	# stalling _ready itself.
	_run.call_deferred()


func _run() -> void:
	var f: int = 0
	f += await _test_resubscribes_after_reparent()
	f += await _test_rearms_every_cycle()
	f += await _test_cycle_during_resolution_subscribes_once()
	f += await _test_same_batch_cycle_subscribes_once()
	f += await _test_row_replay_runs_once_per_entry()

	for probe: _ProbeReceiver in _probes:
		probe.db.free()
		probe.free()
	_probes.clear()
	for replay_probe: _ReplayProbe in _replay_probes:
		replay_probe.db.free()
		replay_probe.free()
	_replay_probes.clear()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	get_tree().quit(f)


func _test_resubscribes_after_reparent() -> int:
	var f: int = 0
	var probe: _ProbeReceiver = _make_probe()
	add_child(probe)
	await _settle()
	f += _check("subscribes on first entry", probe.subscribe_calls, 1)

	remove_child(probe)
	await _settle()
	f += _check("no extra pass while out of the tree", probe.subscribe_calls, 1)

	add_child(probe)
	await _settle()
	f += _check("subscribes again after re-entry", probe.subscribe_calls, 2)

	remove_child(probe)
	return f


# request_ready() re-arms _ready for ONE entry, so a receiver cycled repeatedly
# (a pooled node reused across several scenes) has to re-arm on every exit, not
# only the first.
func _test_rearms_every_cycle() -> int:
	var f: int = 0
	var probe: _ProbeReceiver = _make_probe()
	add_child(probe)
	await _settle()

	for _cycle: int in 3:
		remove_child(probe)
		add_child(probe)
		await _settle()

	f += _check("re-arms on every cycle", probe.subscribe_calls, 4)

	remove_child(probe)
	return f


# The regression the generation counter guards: a receiver that cycles while its
# first pass is still waiting on the database arms a second pass. Both would
# otherwise reach _subscribe_to_table, and the row replay inside it would emit
# every existing row to consumers twice.
func _test_cycle_during_resolution_subscribes_once() -> int:
	var f: int = 0
	var probe: _ProbeReceiver = _make_probe()
	probe.block_db = true
	add_child(probe)
	await _settle()
	f += _check("first pass suspended in _get_db", probe.db_calls, 1)
	f += _check("nothing subscribed while suspended", probe.subscribe_calls, 0)

	remove_child(probe)
	add_child(probe)
	await _settle()
	f += _check("re-entry armed a second pass", probe.db_calls, 2)

	probe.block_db = false
	probe.db_released.emit()
	await _settle()
	f += _check("only the current entry subscribes", probe.subscribe_calls, 1)

	remove_child(probe)
	return f


# The other half of the same regression, and the one a real pool hits: once the
# database resolves synchronously (the steady state), nothing in the pass ever
# suspends, so a remove+add with no frame in between simply queues two passes
# that both run at the next flush. The generation each pass carries has to be the
# one from when it was QUEUED — read at run time, both passes see the post-exit
# value and both subscribe.
func _test_same_batch_cycle_subscribes_once() -> int:
	var f: int = 0
	var probe: _ProbeReceiver = _make_probe()
	add_child(probe)
	remove_child(probe)
	add_child(probe)
	await _settle()
	f += _check("same-batch cycle subscribes once", probe.subscribe_calls, 1)

	remove_child(probe)
	return f


# The symptom the guards exist for, measured on the real _subscribe_to_table:
# each row already in the database is replayed through `insert` when a receiver
# subscribes, so a stale pass surviving alongside the current one doubles every
# one of those emissions. Holding get_table_data() open also drives the guard
# after that await, which the counting probe above never reaches.
func _test_row_replay_runs_once_per_entry() -> int:
	var f: int = 0
	var probe: _ReplayProbe = _ReplayProbe.new()
	probe.table_to_receive = _FakeRow.new()
	# A non-empty name: _subscribe_to_table treats an empty one as nothing to do.
	probe.selected_table_name = &"probe_table"
	probe.rows = [_FakeRow.new(), _FakeRow.new()]
	probe.block_rows = true
	probe.insert.connect(_on_probe_insert)
	_replay_probes.append(probe)

	_insert_count = 0
	add_child(probe)
	await _settle()
	f += _check("no rows replayed while the fetch is open", _insert_count, 0)

	remove_child(probe)
	add_child(probe)
	await _settle()

	probe.block_rows = false
	probe.rows_released.emit()
	await _settle()
	f += _check("each row replayed once", _insert_count, probe.rows.size())

	remove_child(probe)
	return f


func _on_probe_insert(_row: _ModuleTableType) -> void:
	_insert_count += 1


func _make_probe() -> _ProbeReceiver:
	var probe: _ProbeReceiver = _ProbeReceiver.new()
	probe.table_to_receive = _FakeRow.new()
	_probes.append(probe)
	return probe


# _ready defers _init_subscription, so one frame runs _ready and the next runs
# the deferred call.
func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _check(label: String, actual: Variant, expected: Variant) -> int:
	_total += 1
	if actual == expected:
		return 0
	printerr("FAIL %s: expected %s, got %s" % [label, str(expected), str(actual)])
	return 1
