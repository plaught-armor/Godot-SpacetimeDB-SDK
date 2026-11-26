## Server message answering a [SubscribeBatchMessage].
##
## Carries one [SubscribeSetResultData] per requested set, in request order. Every
## applied set's rows are computed at the same transaction offset, and no
## [TransactionUpdateMessage] for those sets precedes this message.
@tool
class_name SubscribeBatchAppliedMessage
extends SpacetimeDBServerMessage

## The [member SubscribeBatchMessage.request_id] echoed back by the server.
var request_id: int
## Per-set outcomes, in request order.
var results: Array[SubscribeSetResultData] = []
