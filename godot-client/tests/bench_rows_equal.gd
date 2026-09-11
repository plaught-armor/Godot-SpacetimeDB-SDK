# Sizes value equality on the change-detection path LocalDatabase runs: the `_row_eq`
# codegen emits on a generated row type, against the generic LocalDatabase._rows_equal
# walk a row script without one falls back to (docs/performance.md, "Update cost is
# dominated by value equality").
#
# Both sides are shipping code: the rows come from spacetime_bindings/ and the walk is
# LocalDatabase's own. An earlier version timed a local reimplementation of _rows_equal,
# which stopped matching the code the day row equality became value-based (d3c8db2) and
# understated the cost by ~3x. Measure the shipping function, never a copy of it.
#
# Each row shape is timed twice. The equal case (full walk, no early exit) is what an
# unchanged re-delivery costs. The differing case is what every real update ends on: the
# changed column takes the values-differ path, where the NaN test sits. Timing only the
# equal case hid a ~100 ns/row regression on that path for a month.
extends SceneTree

const N: int = 300000
const TRIALS: int = 7


func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for t: int in TRIALS:
		var s: int = Time.get_ticks_usec()
		fn.call()
		var el: int = Time.get_ticks_usec() - s
		if el < best:
			best = el
	return best


# The column list LocalDatabase._get_row_properties builds from a row script.
static func _columns(row: _ModuleTableType) -> Array[StringName]:
	var cols: Array[StringName] = []
	var script: Script = row.get_script()
	for prop: Dictionary in script.get_script_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE:
			cols.append(prop.name)
	return cols


func _report(label: String, x: _ModuleTableType, y: _ModuleTableType) -> void:
	var cols: Array[StringName] = _columns(x)
	var walk_us: int = _best(
		func() -> void:
			var sink: int = 0
			for i: int in N:
				if LocalDatabase._rows_equal(x, y, cols):
					sink += 1,
	)
	var gen_us: int = _best(
		func() -> void:
			var sink: int = 0
			for i: int in N:
				if x._row_eq(y, cols):
					sink += 1,
	)
	print(
		"  %s: _rows_equal walk %.0f ns/call | generated _row_eq %.0f ns/call | %.2fx (%.0f ns saved)"
		% [
			label,
			walk_us * 1000.0 / N,
			gen_us * 1000.0 / N,
			float(walk_us) / float(gen_us),
			(walk_us - gen_us) * 1000.0 / N,
		]
	)


static func _config() -> BlackholioConfig:
	return BlackholioConfig.create(1, 1000)


static func _player() -> BlackholioPlayer:
	var identity: PackedByteArray = []
	identity.resize(32)
	identity.fill(7)
	return BlackholioPlayer.create(identity, 3, "player")


static func _entity() -> BlackholioEntity:
	return BlackholioEntity.create(7, BlackholioDbVector2.create(1.0, 2.0), 42)


static func _circle() -> BlackholioCircle:
	return BlackholioCircle.create(7, 3, BlackholioDbVector2.create(0.6, 0.8), 1.25, 1700000000000)


func _initialize() -> void:
	print("equal case (full walk), N=%d best-of-%d" % [N, TRIALS])
	# Distinct instances, equal values — every delivered row is a fresh .new().
	_report("config (int, int)                 ", _config(), _config())
	_report("player (bytes, int, String)       ", _player(), _player())
	_report("entity (int, DbVector2, int)      ", _entity(), _entity())
	_report("circle (int, int, DbVector2, f, i)", _circle(), _circle())

	# Both sides return on the first column that really differs, in declaration order.
	print("differing case (one changed column), N=%d best-of-%d" % [N, TRIALS])
	var config: BlackholioConfig = _config()
	config.world_size = 2000
	_report("config last int differs           ", _config(), config)
	var player: BlackholioPlayer = _player()
	player.name = "renamed"
	_report("player last String differs        ", _player(), player)
	var entity: BlackholioEntity = _entity()
	entity.position.x = 5.0
	_report("entity nested float differs       ", _entity(), entity)
	var circle: BlackholioCircle = _circle()
	circle.speed = 2.5
	_report("circle float differs              ", _circle(), circle)
	var split: BlackholioCircle = _circle()
	split.last_split_time += 1
	_report("circle last int differs           ", _circle(), split)
	quit()
