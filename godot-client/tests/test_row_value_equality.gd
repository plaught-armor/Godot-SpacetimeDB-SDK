# Regression: LocalDatabase._values_equal / _value_hash must compare rows with
# nested Resource columns (product/sum-type wrappers) BY VALUE, not by Object
# identity. Two rows deserialized from equal bytes carry distinct nested-Resource
# instances (fresh .new(), no interning), so an identity compare reports them
# unequal — firing spurious row_updated on the PK path and missing dedup on the
# PK-less path.
#
# Uses the real generated BlackholioCircle (has a nested BlackholioDbVector2
# `direction` column) rather than inner test classes.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_row_value_equality.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _make(id: int, dx: float, dy: float, spd: float) -> BlackholioCircle:
	return BlackholioCircle.create(id, 0, BlackholioDbVector2.create(dx, dy), spd, 0)


func _initialize() -> void:
	var f: int = 0

	# Two structurally-identical rows with DISTINCT nested `direction` instances.
	var a: BlackholioCircle = _make(42, 1.5, 2.5, 3.0)
	var b: BlackholioCircle = _make(42, 1.5, 2.5, 3.0)

	# Baseline: raw Variant != (the old bug) sees them unequal by identity.
	f += _check_b("baseline: nested Resource != by identity", a.direction != b.direction, true)

	# The fix: value-equal + hash-equal.
	f += _check_b("identity-equal rows compare equal", LocalDatabase._values_equal(a, b), true)
	f += _check_b(
		"identity-equal rows hash equal",
		LocalDatabase._value_hash(a) == LocalDatabase._value_hash(b),
		true,
	)

	# A genuinely different nested value must still be unequal (+ different hash).
	var c: BlackholioCircle = _make(42, 1.5, 9.9, 3.0) # direction.y differs
	f += _check_b("differing nested value → unequal", LocalDatabase._values_equal(a, c), false)
	f += _check_b(
		"differing nested value → different hash",
		LocalDatabase._value_hash(a) != LocalDatabase._value_hash(c),
		true,
	)

	# A differing top-level primitive is still caught.
	var d: BlackholioCircle = _make(99, 1.5, 2.5, 3.0) # entity_id differs
	f += _check_b("differing primitive → unequal", LocalDatabase._values_equal(a, d), false)

	# null nested column is handled (both null → equal; one null → unequal).
	var e1: BlackholioCircle = _make(1, 0.0, 0.0, 0.0)
	var e2: BlackholioCircle = _make(1, 0.0, 0.0, 0.0)
	e1.direction = null
	e2.direction = null
	f += _check_b("both null nested → equal", LocalDatabase._values_equal(e1, e2), true)
	f += _check_b(
		"both null nested → hash equal",
		LocalDatabase._value_hash(e1) == LocalDatabase._value_hash(e2),
		true,
	)
	e2.direction = BlackholioDbVector2.create(0.0, 0.0)
	f += _check_b("one null nested → unequal", LocalDatabase._values_equal(e1, e2), false)

	# _rows_equal compares primitive columns inline instead of delegating every
	# column to _values_equal (perf). The two paths must never diverge, so lock
	# them together over the same fixtures: a future refactor that drops the
	# typeof check or mishandles a column type fails here, not in production.
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("x"))
	var cols: Array[StringName] = []
	cols.assign(LocalDatabase._record_columns(a))
	f += _check_b("column list is non-empty", cols.is_empty(), false)
	for pair: Array in [[a, b], [a, c], [a, d], [e1, e2]]:
		var lhs: BlackholioCircle = pair[0]
		var rhs: BlackholioCircle = pair[1]
		f += _check_b(
			"_rows_equal agrees with _values_equal (%d vs %d)" % [lhs.entity_id, rhs.entity_id],
			db._rows_equal(lhs, rhs, cols),
			LocalDatabase._values_equal(lhs, rhs),
		)
	db.free()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1
