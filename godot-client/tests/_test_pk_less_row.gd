# Helper row type for a PK-less table: a minimal _ModuleTableType with no PRIMARY_KEY
# constant and no `id` / `identity` property, so LocalDatabase resolves no primary key
# and routes the table down its PK-less (value-refcounted) path.
# The `_`-prefix keeps it out of run_tests.sh's test_*.gd glob.
extends _ModuleTableType

var label: String = ""
