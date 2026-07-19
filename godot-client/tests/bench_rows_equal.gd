# Sizes the "codegen a typed _row_eq() per generated row class" lever (see
# docs/performance.md, optimization backlog #3) against the change-detection path
# LocalDatabase actually runs.
#
# It calls the REAL LocalDatabase._rows_equal — an earlier version of this bench
# reimplemented it locally as `a.get(p) != b.get(p)`, which stopped matching the
# code the day row equality became value-based (d3c8db2) and understated the lever
# by ~3x. Measure the shipping function, never a copy of it.
#
# Both row shapes are the equal case (full walk, no early exit): the worst case
# for _rows_equal and the case a real update wave hits on every unchanged column.
extends SceneTree

const N: int = 300000
const TRIALS: int = 7


## All-primitive row — no nested column, so _rows_equal never recurses.
class PrimRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int
	@export var a: int
	@export var b: int
	@export var c: float
	@export var d: float
	@export var e: int


	## What a codegen-emitted comparator would look like: typed field reads, no
	## per-column StringName lookup, no Variant dispatch, no recursion.
	func _row_eq(o: PrimRow) -> bool:
		return id == o.id and a == o.a and b == o.b and c == o.c and d == o.d and e == o.e


## Nested-record row — _rows_equal descends into the wrapper's columns by value.
class EntityRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"entity_id"
	@export var entity_id: int
	@export var position: BlackholioDbVector2
	@export var mass: int


	func _row_eq(o: EntityRow) -> bool:
		return (
			entity_id == o.entity_id and mass == o.mass
			and position.x == o.position.x and position.y == o.position.y
		)


func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for t: int in TRIALS:
		var s: int = Time.get_ticks_usec()
		fn.call()
		var el: int = Time.get_ticks_usec() - s
		if el < best:
			best = el
	return best


func _prim() -> PrimRow:
	var r: PrimRow = PrimRow.new()
	r.id = 7
	r.a = 42
	r.b = 84
	r.c = 1.5
	r.d = 2.5
	r.e = 99
	return r


func _entity() -> EntityRow:
	var p: BlackholioDbVector2 = BlackholioDbVector2.new()
	p.x = 1.0
	p.y = 2.0
	var r: EntityRow = EntityRow.new()
	r.entity_id = 7
	r.position = p
	r.mass = 42
	return r


func _report(
	label: String,
	db: LocalDatabase,
	x: _ModuleTableType,
	y: _ModuleTableType,
	props: Array[StringName],
) -> void:
	var dyn_us: int = _best(
		func() -> void:
			var sink: int = 0
			for i: int in N:
				if db._rows_equal(x, y, props):
					sink += 1
	)
	var typed_us: int = _best(
		func() -> void:
			var sink: int = 0
			for i: int in N:
				if x._row_eq(y):
					sink += 1
	)
	print(
		"  %s: _rows_equal %.0f ns/call | typed _row_eq %.0f ns/call | %.2fx (%.0f ns saved)"
		% [
			label,
			dyn_us * 1000.0 / N,
			typed_us * 1000.0 / N,
			float(dyn_us) / float(typed_us),
			(dyn_us - typed_us) * 1000.0 / N,
		]
	)


func _initialize() -> void:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("x"))
	print("equal case (full walk), N=%d best-of-%d" % [N, TRIALS])
	# Distinct instances, equal values — every delivered row is a fresh .new().
	_report(
		"prim   (6 primitive columns)",
		db,
		_prim(),
		_prim(),
		[&"id", &"a", &"b", &"c", &"d", &"e"] as Array[StringName],
	)
	_report(
		"entity (nested DbVector2)   ",
		db,
		_entity(),
		_entity(),
		[&"entity_id", &"position", &"mass"] as Array[StringName],
	)
	quit()
