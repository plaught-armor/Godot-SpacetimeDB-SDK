# Sibling of vnest_foo_bar.gd — the type a module would call `Foobar` next to a `FooBar`.
class_name VnestFoobar
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = {&"which": &"u32"}

@export var which: int = 2
