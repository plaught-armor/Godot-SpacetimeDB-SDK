# Scratch probe: nested Option/Vec column shapes deeper than any committed fixture or
# earlier round-trip matrix (Option<Option<T>>, Vec<Vec<Vec<T>>>, Option<Vec<Option<T>>>,
# Vec<Option<Vec<T>>>). Writes a row with the SDK's serializer, compares the bytes with a
# hand-built BSATN oracle, then reads the oracle bytes back and compares the values.
extends SceneTree

var _total: int = 0
var _fails: int = 0

# Mirrors what codegen emitted for these column shapes (see _probe_nested_gen.gd).
const ROW_SOURCE: String = """
extends _ModuleTableType
const module_name: String = "Probe"
const table_names: Array[StringName] = [&'nest']
const PRIMARY_KEY: StringName = &"id"
const BSATN_TYPES: Dictionary[StringName, StringName] = {
	&"id": &"u32",
	&"oo": &"opt_u32",
	&"vvv": &"vec_vec_u32",
	&"ovo": &"vec_opt_u32",
	&"vov": &"opt_vec_u32",
	&"ov": &"vec_u32",
	&"vo": &"opt_u32",
}
@export var id: int
@export var oo: Option
@export var vvv: Array[Array]
@export var ovo: Option
@export var vov: Array[Option]
@export var ov: Option
@export var vo: Array[Option]
"""


func _initialize() -> void:
	var row_script: GDScript = GDScript.new()
	row_script.source_code = ROW_SOURCE
	var err: Error = row_script.reload()
	if err != OK:
		printerr("row script failed to compile: %s" % error_string(err))
		quit(1)
		return

	var row: Object = row_script.new()
	row.id = 7
	row.oo = Option.some(Option.some(5))
	var vvv: Array[Array] = [[[1], [2]], []]
	row.vvv = vvv
	row.ovo = Option.some([Option.some(3), Option.none()])
	var vov: Array[Option] = [Option.some([9]), Option.none()]
	row.vov = vov
	row.ov = Option.some([4, 5])
	var vo: Array[Option] = [Option.some(1), Option.none()]
	row.vo = vo

	var expected: PackedByteArray = _oracle()
	print("oracle bytes: ", expected.size())

	# --- write path ---
	var ser: BSATNSerializer = BSATNSerializer.new()
	ser._spb = StreamPeerBuffer.new()
	ser._spb.big_endian = false
	var ok: bool = ser._serialize_resource_fields(row)
	if not ok or ser.has_error():
		_fail("serialize failed: %s" % ser.get_last_error())
	var wrote: PackedByteArray = ser._spb.data_array
	_check(
		"write bytes match oracle",
		wrote == expected,
		"got %s\nwant %s" % [wrote.hex_encode(), expected.hex_encode()],
	)

	# --- read path ---
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	var de: BSATNDeserializer = BSATNDeserializer.new(schema, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.data_array = expected
	spb.seek(0)
	var back: Object = row_script.new()
	var read_ok: bool = de._populate_resource_from_bytes(back, spb)
	_check("read succeeded", read_ok and not de.has_error(), de.get_last_error())
	_check(
		"read consumed every byte",
		spb.get_position() == expected.size(),
		"at %d of %d" % [spb.get_position(), expected.size()],
	)

	_check("id", back.id == 7, str(back.id))
	_check("oo outer some", _is_some(back.oo), str(back.oo))
	if _is_some(back.oo):
		var inner: Variant = back.oo.unwrap()
		_check("oo inner is Option", inner is Option, str(inner))
		if inner is Option:
			_check("oo inner == 5", _is_some(inner) and inner.unwrap() == 5, str(inner.unwrap()))
	_check("vvv", str(back.vvv) == str([[[1], [2]], []]), str(back.vvv))
	_check("ovo some", _is_some(back.ovo), str(back.ovo))
	if _is_some(back.ovo):
		var lst: Variant = back.ovo.unwrap()
		_check("ovo len 2", lst is Array and lst.size() == 2, str(lst))
		if lst is Array and lst.size() == 2:
			_check(
				"ovo[0] == 3",
				lst[0] is Option and _is_some(lst[0]) and lst[0].unwrap() == 3,
				str(lst[0]),
			)
			_check("ovo[1] none", lst[1] is Option and not _is_some(lst[1]), str(lst[1]))
	_check("vov len 2", back.vov.size() == 2, str(back.vov))
	if back.vov.size() == 2:
		_check(
			"vov[0] == [9]",
			_is_some(back.vov[0]) and str(back.vov[0].unwrap()) == str([9]),
			str(back.vov[0]),
		)
		_check("vov[1] none", not _is_some(back.vov[1]), str(back.vov[1]))
	_check("ov == [4,5]", _is_some(back.ov) and str(back.ov.unwrap()) == str([4, 5]), str(back.ov))
	_check("vo len 2", back.vo.size() == 2, str(back.vo))
	if back.vo.size() == 2:
		_check("vo[0] == 1", _is_some(back.vo[0]) and back.vo[0].unwrap() == 1, str(back.vo[0]))
		_check("vo[1] none", not _is_some(back.vo[1]), str(back.vo[1]))

	# --- reducer-argument path (no property hint; type comes from the value) ---
	_arg_case("opt_opt", [Option.some(Option.some(5))], [&"opt_u32"], [0, 0, 5, 0, 0, 0])
	_arg_case("opt_opt_none_inner", [Option.some(Option.none())], [&"opt_u32"], [0, 1])
	_arg_case("opt_none", [Option.none()], [&"opt_u32"], [1])
	var vv: Array[Array] = [[1], []]
	_arg_case("vec_vec", [vv], [&"vec_u32"], [2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
	var vo_arg: Array[Option] = [Option.some(1), Option.none()]
	_arg_case("vec_opt", [vo_arg], [&"opt_u32"], [2, 0, 0, 0, 0, 1, 0, 0, 0, 1])

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _arg_case(label: String, args: Array, types: Array, want: Array) -> void:
	var ser: BSATNSerializer = BSATNSerializer.new()
	ser._spb = StreamPeerBuffer.new()
	ser._spb.big_endian = false
	var bsatn_types: Array[StringName] = []
	bsatn_types.assign(types)
	var got: PackedByteArray = ser._serialize_arguments(args, bsatn_types)
	var expect: PackedByteArray = want
	_check(
		"arg %s" % label,
		got == expect and not ser.has_error(),
		"got %s want %s err=%s" % [got.hex_encode(), expect.hex_encode(), ser.get_last_error()],
	)


func _is_some(o: Variant) -> bool:
	return o is Option and not o.is_none()


# Hand-built BSATN for the row above. Option: tag 0 = some (payload follows),
# tag 1 = none. Vec: u32 LE length then elements. u32: 4 bytes LE.
func _oracle() -> PackedByteArray:
	var b: PackedByteArray = []
	_u32(b, 7) # id
	# oo = Some(Some(5))
	b.append(0)
	b.append(0)
	_u32(b, 5)
	# vvv = [[[1],[2]],[]]
	_u32(b, 2)
	_u32(b, 2)
	_u32(b, 1)
	_u32(b, 1)
	_u32(b, 1)
	_u32(b, 2)
	_u32(b, 0)
	# ovo = Some([Some(3), None])
	b.append(0)
	_u32(b, 2)
	b.append(0)
	_u32(b, 3)
	b.append(1)
	# vov = [Some([9]), None]
	_u32(b, 2)
	b.append(0)
	_u32(b, 1)
	_u32(b, 9)
	b.append(1)
	# ov = Some([4,5])
	b.append(0)
	_u32(b, 2)
	_u32(b, 4)
	_u32(b, 5)
	# vo = [Some(1), None]
	_u32(b, 2)
	b.append(0)
	_u32(b, 1)
	b.append(1)
	return b


func _u32(b: PackedByteArray, v: int) -> void:
	b.append(v & 0xFF)
	b.append((v >> 8) & 0xFF)
	b.append((v >> 16) & 0xFF)
	b.append((v >> 24) & 0xFF)


func _check(label: String, cond: bool, detail: String = "") -> void:
	_total += 1
	if not cond:
		_fails += 1
		printerr("FAIL %s: %s" % [label, detail])


func _fail(msg: String) -> void:
	_total += 1
	_fails += 1
	printerr("FAIL %s" % msg)
