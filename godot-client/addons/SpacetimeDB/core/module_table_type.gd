## Abstract base class for all generated SpacetimeDB table row types.
##
## Every codegen'd table row type (e.g. [code]WorldPawnStatsRow[/code]) extends
## this class. The [code]_ModuleTable[/code] and [code]LocalDatabase[/code]
## store and return rows typed as [_ModuleTableType].
class_name _ModuleTableType
extends Resource


## Whether this row holds the same value as [param other] — the test
## [LocalDatabase] runs to decide whether a re-delivered row is an update, and to match
## a row in a table without a primary key. Columns compare by value: a nested record by
## its own columns, and two floats that are both NaN as equal.
## [br][br]
## This base walks [param columns] generically. A generated row type overrides it with a
## comparison typed to its own columns, which gives the same answer several times faster
## and ignores [param columns].
func _row_eq(other: _ModuleTableType, columns: Array[StringName]) -> bool:
	return LocalDatabase._rows_equal(self, other, columns)
