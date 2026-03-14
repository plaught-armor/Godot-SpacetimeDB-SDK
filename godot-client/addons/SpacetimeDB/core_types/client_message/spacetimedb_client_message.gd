## Base class for all client-to-server messages in the SpacetimeDB v2 WS protocol.
##
## Subclasses represent specific message types: [SubscribeMessage],
## [UnsubscribeMessage], [OneOffQueryMessage], [CallReducerMessage], and
## [CallProcedureMessage]. The variant tag constants must match the server's
## protocol definition.
class_name SpacetimeDBClientMessage
extends SpacetimeDBMessage

## Subscribe to one or more queries. See [SubscribeMessage].
const SUBSCRIBE := 0x00
## Unsubscribe from a query set. See [UnsubscribeMessage].
const UNSUBSCRIBE := 0x01
## Execute a one-off SQL query. See [OneOffQueryMessage].
const ONEOFF_QUERY := 0x02
## Call a reducer function on the server. See [CallReducerMessage].
const CALL_REDUCER := 0x03
## Call a stored procedure on the server. See [CallProcedureMessage].
const CALL_PROCEDURE := 0x04
