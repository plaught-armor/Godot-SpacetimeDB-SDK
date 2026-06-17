## Base class for codegen'd btree (non-unique) index accessors.
##
## Each generated btree index (e.g. [code]BlackholioCirclePlayerIdBTreeIndex[/code])
## extends this and exposes a typed [code]filter()[/code] returning every row whose
## indexed column equals the given value. Backed by a linear scan over
## [LocalDatabase] — the official C#/TS SDKs also scan, so this is full parity. The
## accessor exists for a typed API surface and can swap to a real index later
## without changing call sites.
class_name _ModuleTableBTreeIndex
extends Resource

## Normalized table name this index belongs to.
var _table_name: StringName
## The field name used as the (non-unique) index key.
var _field_name: StringName
## Database the scan reads from.
var _db: LocalDatabase

## Subclasses declare a typed [code]filter(col_val) -> Array[Row][/code] that scans
## via [member _db].find_by([member _table_name], [member _field_name], col_val).
## The method is not declared here so each subclass can narrow the parameter and
## return types (GDScript requires overrides to match the parent signature exactly).
