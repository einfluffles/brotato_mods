extends Reference
# Wire format: var2bytes([msg_type, body]). Decoding never allows objects.

enum Msg {
	HELLO,  # client -> host: version, name
	WELCOME,  # host -> client: version, accepted, reason
	PING,  # any -> any: t
	PONG,  # any -> any: t
	INPUT,  # client -> host, unreliable: [seq, move: Vector2, aim: Vector2, buttons: int]
}

const VERSION := 1


static func encode(msg_type: int, body = null) -> PoolByteArray:
	return var2bytes([msg_type, body])


# Returns [msg_type, body] or null when the payload is malformed.
static func decode(data: PoolByteArray):
	if data.empty():
		return null
	var value = bytes2var(data, false)
	if typeof(value) != TYPE_ARRAY or value.size() != 2 or typeof(value[0]) != TYPE_INT:
		return null
	return value
