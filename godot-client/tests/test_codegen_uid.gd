# Unit test for deterministic binding UIDs (SpacetimeCodegen._stable_uid_id).
#
# The UID write path (generate_bindings -> _write_deterministic_uid) is NOT
# covered by test_codegen_golden, which drives _generate_gdscript_from_schema
# directly and never mints UIDs. This locks the hash itself: a change to the
# FNV constant, prime, or 63-bit mask would silently repoint every generated
# binding's .uid on the next regen and break scene/.tres references — exactly
# what determinism is meant to prevent.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_codegen_uid.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _check(cond: bool, label: String) -> void:
	_total += 1
	if not cond:
		_fails += 1
		printerr("  FAIL: %s" % label)


func _run() -> void:
	# Canonical FNV-1a-64 of "res://a.gd", masked to 63 bits. Cross-checked
	# against an independent Python reference implementation. This is the
	# regression anchor: if the algorithm drifts, this value changes.
	var anchor_path: String = "res://a.gd"
	var anchor_id: int = 1551524846256749799
	var id_a: int = SpacetimeCodegen._stable_uid_id(anchor_path)
	_check(id_a == anchor_id, "known FNV-1a value for %s (got %d)" % [anchor_path, id_a])

	# Deterministic: same path always yields the same id.
	_check(id_a == SpacetimeCodegen._stable_uid_id(anchor_path), "deterministic across calls")

	# Positive and never ResourceUID.INVALID_ID (-1) — the 63-bit mask guarantees it.
	_check(id_a > 0, "id is positive")
	_check(id_a != ResourceUID.INVALID_ID, "id is not INVALID_ID")

	# Distinct paths yield distinct ids (no trivial collapse).
	var id_b: int = SpacetimeCodegen._stable_uid_id("res://b.gd")
	_check(id_a != id_b, "distinct paths -> distinct ids")

	# Every id survives the id_to_text / text_to_id round-trip the .uid sidecar
	# and the collision scan both rely on.
	var paths: PackedStringArray = [
		"res://spacetime_bindings/schema/module_blackholio_db.gd",
		"res://spacetime_bindings/schema/tables/blackholio_circle_table.gd",
		anchor_path,
	]
	for p: String in paths:
		var id: int = SpacetimeCodegen._stable_uid_id(p)
		var round_tripped: int = ResourceUID.text_to_id(ResourceUID.id_to_text(id))
		_check(round_tripped == id, "uid text round-trip for %s" % p)
		_check(id > 0 and id <= 0x7FFFFFFFFFFFFFFF, "%s within 63-bit range" % p)

	# Guard that the 63-bit mask is actually applied (not widened/removed). This
	# path's UNMASKED FNV-1a-64 has bit 63 set (15801356531823170817), so a
	# masked result MUST differ from it and MUST stay non-negative. Without this,
	# a 63->64-bit mask change could slip past the paths above.
	var high_bit_path: String = "res://spacetime_bindings/schema/tables/t0.gd"
	var high_bit_unmasked: int = 6577984494968395009 | (1 << 63) # reconstruct the raw hash
	var high_bit_id: int = SpacetimeCodegen._stable_uid_id(high_bit_path)
	_check(high_bit_id == 6577984494968395009, "masked value for bit-63 path")
	_check(high_bit_id != high_bit_unmasked, "63-bit mask clears the top bit")
	_check(high_bit_id > 0, "masked bit-63 path stays positive")
