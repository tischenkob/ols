package server

import "core:encoding/json"

// The id that a `$/cancelRequest` notification targets. It is in `params.id`: the notification
// has no id of its own. A string id aliases root.
cancelled_request_id :: proc(root: json.Object) -> (id: RequestId, ok: bool) {
	params := root["params"].(json.Object) or_return

	#partial switch v in params["id"] {
	case json.String:
		return v, true
	case json.Integer:
		return v, true
	}

	return nil, false
}
