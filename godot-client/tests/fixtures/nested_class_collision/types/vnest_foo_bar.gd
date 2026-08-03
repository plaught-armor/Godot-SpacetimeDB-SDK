# Fixture: a nested payload type, named exactly as codegen would name one for a module
# called `vnest` with a type `FooBar` — file `vnest_foo_bar.gd`, class `VnestFooBar`.
# Its sibling `vnest_foobar.gd` (type `Foobar`) normalizes to the same string on both
# sides: file `vnestfoobar`, class `vnestfoobar`.
class_name VnestFooBar
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = {&"which": &"u32"}

@export var which: int = 1
