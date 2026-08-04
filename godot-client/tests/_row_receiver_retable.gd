# Unit test for which table a RowReceiver unsubscribes from when it leaves the tree.
#
# _subscribe_to_table registers its four listeners under the name it was called with, but
# _exit_tree unsubscribed selected_table_name — whatever that happens to hold *now*. The
# two disagree the moment the property changes while the receiver is in the tree (setting
# table_to_receive at runtime does exactly that, through on_set), and then the first
# table's listeners are never removed. They are Callables bound to this node, so once it
# is freed LocalDatabase calls into a freed instance on every row event for that table,
# for the rest of the session. The receiver now remembers the name it subscribed with and
# unsubscribes that one.
#
# This runs as a SCENE rather than a --script test: row_receiver.gd names the SpacetimeDB
# autoload, and autoload identifiers only resolve when Godot boots a normal main loop.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       tests/test_row_receiver_retable.tscn
extends Node

var _total: int = 0
var _probes: Array[_Probe] = []


func _ready() -> void:
	# M1: the checks await, so they run from a deferred coroutine rather than stalling
	# _ready itself.
	_run.call_deferred()


func _run() -> void:
	var f: int = 0
	f += await _test_unsubscribes_the_table_it_subscribed_to()
	f += await _test_unchanged_name_still_unsubscribes()

	for probe: _Probe in _probes:
		probe.db.free()
		probe.free()
	_probes.clear()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	get_tree().quit(f)


func _test_unsubscribes_the_table_it_subscribed_to() -> int:
	var f: int = 0
	var probe: _Probe = _make_probe(&"alpha")
	add_child(probe)
	await _settle()
	f += _check("subscribed to alpha", _listener_count(probe.db, &"alpha"), 4)

	# The table is swapped while the receiver is in the tree — what assigning
	# table_to_receive at runtime does, via on_set.
	probe.selected_table_name = &"beta"
	f += _check("no listeners on beta from the swap alone", _listener_count(probe.db, &"beta"), 0)

	remove_child(probe)
	await _settle()
	f += _check("alpha listeners removed on exit", _listener_count(probe.db, &"alpha"), 0)
	f += _check("beta untouched", _listener_count(probe.db, &"beta"), 0)
	return f


# The ordinary case, so the fix cannot be "unsubscribe nothing".
func _test_unchanged_name_still_unsubscribes() -> int:
	var f: int = 0
	var probe: _Probe = _make_probe(&"alpha")
	add_child(probe)
	await _settle()
	f += _check("subscribed", _listener_count(probe.db, &"alpha"), 4)

	remove_child(probe)
	await _settle()
	f += _check("unsubscribed on exit", _listener_count(probe.db, &"alpha"), 0)

	# Re-entry subscribes again (the reparent behaviour, pinned here against the change).
	add_child(probe)
	await _settle()
	f += _check("re-entry subscribes again", _listener_count(probe.db, &"alpha"), 4)
	remove_child(probe)
	await _settle()
	f += _check("and unsubscribes again", _listener_count(probe.db, &"alpha"), 0)
	return f


func _make_probe(table_name: StringName) -> _Probe:
	var probe: _Probe = _Probe.new()
	# Assigning the row type runs on_set, which clears selected_table_name (an inner class
	# declares no table_names), so the name is set after — directly, not through on_set.
	# Writing the property is the minimal way to move it, which is the whole defect
	# surface; driving it through on_set would need a generated row type carrying two
	# table_names entries, which this harness deliberately avoids.
	probe.table_to_receive = _FakeRow.new()
	probe.selected_table_name = table_name
	_probes.append(probe)
	return probe


# Total listeners registered for a table across the four kinds a receiver subscribes to.
func _listener_count(db: LocalDatabase, table_name: StringName) -> int:
	return (
		db._insert_listeners_by_table.get(table_name, []).size()
		+ db._update_listeners_by_table.get(table_name, []).size()
		+ db._delete_listeners_by_table.get(table_name, []).size()
		+ db._transactions_completed_listeners_by_table.get(table_name, []).size()
	)


# Three frames: _ready defers _init_subscription, which then awaits at least once. Two
# would do; the third is slack.
func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _check(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


# An anonymous row type: on_set rejects _ModuleTableType itself (it is the base class, not
# a table), and an inner class reports an empty global name, so this passes that check
# without a generated binding in the project.
class _FakeRow:
	extends _ModuleTableType


# Keeps the real _subscribe_to_table / _unsubscribe_from_table — the pair under test — and
# stands in only for the database resolution, which would otherwise need a live client.
class _Probe:
	extends RowReceiver

	var db: LocalDatabase = LocalDatabase.new(_mk_schema())


	static func _mk_schema() -> SpacetimeDBSchema:
		var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Probe", "res://__no_schema__", false)
		schema.raw_table_names = [&"alpha", &"beta"]
		return schema


	func _get_db(_wait_for_init: bool = false) -> LocalDatabase:
		return db
