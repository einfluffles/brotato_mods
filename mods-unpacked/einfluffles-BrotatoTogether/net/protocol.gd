extends Reference
# Wire format: var2bytes([msg_type, body]). Decoding never allows objects.

enum Msg {
	HELLO,  # client -> host: version, name
	WELCOME,  # host -> client: version, accepted, reason
	PING,  # any -> any: t
	PONG,  # any -> any: t
	INPUT,  # client -> host, unreliable: [seq, move: Vector2, aim: Vector2, buttons: int]
	BATTLE_START,  # host -> client: battle_id, run (RunStateCodec), types {idx: scene_path}
	BATTLE_END,  # host -> client: battle_id
	TYPE_DEF,  # host -> client: battle_id, idx, path
	SNAPSHOT,  # host -> client, unreliable: see sync/snapshot.gd
	FOCUS,  # host -> client: scene, cursors [[emulator path, player, control path]]
	SHOP_STATE,  # host -> client: shop_id, run (RunStateCodec incl. shop), slots, go
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
