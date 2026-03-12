## Client message that executes a single SQL query without creating a subscription.
##
## Serialized with variant tag [constant SpacetimeDBClientMessage.ONEOFF_QUERY].
## The server replies with a one-off query response containing the result rows.
class_name OneOffQueryMessage extends SpacetimeDBClientMessage

## The SQL query string to execute once on the server.
var query: String

func _init(p_query: String = ""):
	query = p_query
