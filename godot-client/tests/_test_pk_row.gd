# Helper row type for test_update_null_prev. A minimal _ModuleTableType carrying a
# PRIMARY_KEY constant so LocalDatabase's update-detection path can resolve a pk.
# The `_`-prefix keeps it out of run_tests.sh's test_*.gd glob.
extends _ModuleTableType

const PRIMARY_KEY: StringName = &"id"

var id: int = 0
var val: int = 0
