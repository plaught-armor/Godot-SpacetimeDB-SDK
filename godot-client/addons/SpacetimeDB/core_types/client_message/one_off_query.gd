class_name OneOffQueryMessage extends SpacetimeDBClientMessage

## The query string to execute once on the server.
var query: String

func _init(p_query: String = ""):
	query = p_query
