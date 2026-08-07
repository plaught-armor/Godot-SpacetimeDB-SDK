# Regression test: the persisted auth token is stored per module, so two generated
# clients in one project stop overwriting each other's identity.
#
# token_save_path is a per-client @export with one hardcoded default, and the file used
# to hold one bare token, so every client in the process read and wrote the same value.
# Measured with two clients against a loopback identity server
# (tests/_probe_token_store.gd): run 1 issued two identities and saved whichever
# finished last; run 2 handed BOTH modules that one token, so the other module silently
# connected as a different identity and every row it owned went missing, with no error
# anywhere. The store is now a JSON object keyed by module name; a file that is not one
# is the pre-store format and is handed to whichever module asks, so an existing
# installation keeps its identity across the upgrade.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_token_store.gd
extends SceneTree

const TOKEN_PATH: String = "user://__test_token_store.dat"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_read()
	f += _test_write()
	f += _test_two_clients_one_file()
	f += _test_legacy_file_upgrade()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_read() -> int:
	var f: int = 0
	f += _check("empty file", SpacetimeDBClient.token_store_read("", "Alpha"), "")
	f += _check("whitespace only", SpacetimeDBClient.token_store_read("  \n", "Alpha"), "")
	# Pre-store format: one bare token, no owner. Any module gets it.
	f += _check("legacy bare token", SpacetimeDBClient.token_store_read("tok1", "Alpha"), "tok1")
	f += _check(
		"legacy token, trailing newline",
		SpacetimeDBClient.token_store_read("tok1\n", "Beta"),
		"tok1",
	)
	# A real token is a JWT, which is not JSON and must not be parsed as the store.
	f += _check(
		"legacy jwt",
		SpacetimeDBClient.token_store_read("aaa.bbb.ccc", "Alpha"),
		"aaa.bbb.ccc",
	)
	f += _check(
		"store hit",
		SpacetimeDBClient.token_store_read('{"Alpha":"tok1","Beta":"tok2"}', "Beta"),
		"tok2",
	)
	# The module that has no entry yet asks for a token of its own — it must NOT
	# inherit another module's, which is the bug this whole file is about.
	f += _check("store miss", SpacetimeDBClient.token_store_read('{"Alpha":"tok1"}', "Beta"), "")
	f += _check(
		"store entry is not a string",
		SpacetimeDBClient.token_store_read('{"Alpha":7}', "Alpha"),
		"",
	)
	# The pre-store token is the exception to "no inheriting": every module was reading
	# that one token before the store existed, so every module's rows live under it.
	f += _check(
		"pre-store token is offered to a module with no entry",
		SpacetimeDBClient.token_store_read('{"*":"legacy_tok","Alpha":"tok1"}', "Beta"),
		"legacy_tok",
	)
	f += _check(
		"a module's own entry beats the pre-store token",
		SpacetimeDBClient.token_store_read('{"*":"legacy_tok","Alpha":"tok1"}', "Alpha"),
		"tok1",
	)
	# Corrupt (a torn write, a truncated file): NOT the pre-store format. Returning the
	# text sent the file's bytes out as `Authorization: Bearer {"Alpha":"tok...`, and the
	# failure surfaced as a rejected token rather than as a corrupt store.
	f += _check("corrupt store: bare brace", SpacetimeDBClient.token_store_read("{", "Alpha"), "")
	f += _check(
		"corrupt store: truncated object",
		SpacetimeDBClient.token_store_read('{"Alpha":"tok1","Beta":"tok', "Alpha"),
		"",
	)
	f += _check("empty store", SpacetimeDBClient.token_store_read("{}", "Alpha"), "")
	# A client with no module_name (SpacetimeDBClient used directly) keys on "".
	f += _check(
		"empty module name keys on \"\"",
		SpacetimeDBClient.token_store_read('{"":"tok0"}', ""),
		"tok0",
	)
	return f


func _test_write() -> int:
	var f: int = 0
	f += _check(
		"write into nothing",
		SpacetimeDBClient.token_store_write("", "Alpha", "tok1"),
		'{"Alpha":"tok1"}',
	)
	f += _check(
		"write keeps the other module",
		SpacetimeDBClient.token_store_write('{"Alpha":"tok1"}', "Beta", "tok2"),
		'{"Alpha":"tok1","Beta":"tok2"}',
	)
	f += _check(
		"write replaces this module",
		SpacetimeDBClient.token_store_write('{"Alpha":"tok1","Beta":"tok2"}', "Alpha", "tok9"),
		'{"Alpha":"tok9","Beta":"tok2"}',
	)
	# The pre-store token is kept under the reserved key: the module writing first is not
	# necessarily the only one that was using it, and one that has not connected yet
	# still needs it to find its rows.
	f += _check(
		"write over a pre-store file keeps the bare token",
		SpacetimeDBClient.token_store_write("tok1", "Alpha", "tok1"),
		'{"*":"tok1","Alpha":"tok1"}',
	)
	f += _check(
		"the reserved entry survives later writes",
		SpacetimeDBClient.token_store_write('{"*":"tok1","Alpha":"tok1"}', "Beta", "tok2"),
		'{"*":"tok1","Alpha":"tok1","Beta":"tok2"}',
	)
	f += _check(
		"non-string entries are dropped",
		SpacetimeDBClient.token_store_write('{"Alpha":7,"Beta":"tok2"}', "Gamma", "tok3"),
		'{"Beta":"tok2","Gamma":"tok3"}',
	)
	# A JSON array is not a store and not a bare token either — but it also cannot be a
	# token this SDK ever wrote, so it is replaced rather than preserved.
	f += _check(
		"a JSON non-object is not a store",
		SpacetimeDBClient.token_store_write("[1,2]", "Alpha", "tok1"),
		'{"*":"[1,2]","Alpha":"tok1"}',
	)
	# A corrupt store cannot be merged into — its entries are already unreadable — so the
	# writer replaces it instead of carrying the broken text forward as a token.
	f += _check(
		"corrupt store is replaced",
		SpacetimeDBClient.token_store_write('{"Alpha":"tok1","Beta":"tok', "Alpha", "tok9"),
		'{"Alpha":"tok9"}',
	)
	# module_name is a plain String nothing validates, so a client CAN name itself the
	# reserved key. Writing under it would hand that client's token to every module with
	# no entry of its own — refused, store unchanged.
	f += _check(
		"a client cannot claim the reserved key",
		SpacetimeDBClient.token_store_write('{"Alpha":"tok1"}', "*", "tok_star"),
		'{"Alpha":"tok1"}',
	)
	return f


# The end of the path that used to lose an identity: two clients, one file, no network.
func _test_two_clients_one_file() -> int:
	var f: int = 0
	_erase()
	var alpha: SpacetimeDBClient = _client("Alpha")
	var beta: SpacetimeDBClient = _client("Beta")
	alpha._save_token("tokA")
	beta._save_token("tokB")

	var text: String = _read()
	f += _check(
		"Alpha reads its own token back",
		SpacetimeDBClient.token_store_read(text, "Alpha"),
		"tokA",
	)
	f += _check(
		"Beta reads its own token back",
		SpacetimeDBClient.token_store_read(text, "Beta"),
		"tokB",
	)
	# Rewriting one module's token leaves the other's alone.
	alpha._save_token("tokA2")
	text = _read()
	f += _check(
		"re-saving Alpha keeps Beta",
		SpacetimeDBClient.token_store_read(text, "Beta"),
		"tokB",
	)
	f += _check(
		"re-saving Alpha updates Alpha",
		SpacetimeDBClient.token_store_read(text, "Alpha"),
		"tokA2",
	)

	alpha.free()
	beta.free()
	_erase()
	return f


# Upgrading an existing installation must not start a new identity: the bare token
# already on disk is adopted, then written back under this module's name.
func _test_legacy_file_upgrade() -> int:
	var f: int = 0
	_erase()
	var file: FileAccess = FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	file.store_string("legacy_tok")
	file.close()

	var alpha: SpacetimeDBClient = _client("Alpha")
	var beta: SpacetimeDBClient = _client("Beta")
	f += _check(
		"legacy token is what the client would load",
		SpacetimeDBClient.token_store_read(_read(), alpha.module_name),
		"legacy_tok",
	)
	alpha._save_token("legacy_tok")
	# Nothing changed for this module, so the file is not rewritten at all — the cheapest
	# way not to damage a file carrying every module's credential is not to touch it.
	f += _check("saving an unchanged token leaves the file alone", _read(), "legacy_tok")
	f += _check(
		"legacy token still resolves after the save",
		SpacetimeDBClient.token_store_read(_read(), "Alpha"),
		"legacy_tok",
	)
	# The other module had not connected when Alpha rewrote the file. Its rows live under
	# that same token — every module was reading it — so it must still be offered one.
	f += _check(
		"the module that had not connected yet still finds it",
		SpacetimeDBClient.token_store_read(_read(), "Beta"),
		"legacy_tok",
	)
	beta._save_token("legacy_tok")
	f += _check(
		"both modules keep it after both have saved",
		SpacetimeDBClient.token_store_read(_read(), "Alpha"),
		"legacy_tok",
	)
	f += _check(
		"and the second one still resolves it too",
		SpacetimeDBClient.token_store_read(_read(), "Beta"),
		"legacy_tok",
	)
	# A module that acquires a DIFFERENT token takes an entry of its own, and the
	# pre-store one stays behind for whoever is still living off it.
	alpha._save_token("fresh_tok")
	f += _check(
		"a changed token is written under this module",
		SpacetimeDBClient.token_store_read(_read(), "Alpha"),
		"fresh_tok",
	)
	f += _check(
		"and the other module keeps the pre-store one",
		SpacetimeDBClient.token_store_read(_read(), "Beta"),
		"legacy_tok",
	)
	alpha.free()
	beta.free()
	_erase()
	return f

# --- harness ---


func _client(module: String) -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = module
	client.token_save_path = TOKEN_PATH
	return client


func _read() -> String:
	if not FileAccess.file_exists(TOKEN_PATH):
		return ""
	var file: FileAccess = FileAccess.open(TOKEN_PATH, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _erase() -> void:
	if FileAccess.file_exists(TOKEN_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TOKEN_PATH))


func _check(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1
