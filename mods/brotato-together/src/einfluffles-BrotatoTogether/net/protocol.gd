extends Reference
# Wire format: var2bytes([msg_type, body]). Decoding never allows objects.

enum Msg {
	HELLO,  # client -> host, resent until WELCOME: see session/compat.gd local_info
	WELCOME,  # host -> client: version, accepted, reason, dlcs (session/dlc_borrow.gd)
	PING,  # any -> any: t
	PONG,  # any -> any: t
	# client -> host, unreliable: [seq, move: Vector2, aim: Vector2, buttons (held mask),
	# presses (4-bit counter per button, sync/press_counter.gd), flags (sync/local_aim.gd)]
	INPUT,
	# host -> client: battle_id, run (RunStateCodec), types {idx: scene_path}, colors (palette
	# index per slot, CoopService extension; also in SHOP_STATE and MENU_STATE)
	BATTLE_START,
	BATTLE_END,  # host -> client: battle_id
	TYPE_DEF,  # host -> client: battle_id, idx, path
	SNAPSHOT,  # host -> client, unreliable: see sync/snapshot.gd
	FOCUS,  # host -> client: scene, cursors [[emulator path, player, control path]]
	SHOP_STATE,  # host -> client: shop_id, run (RunStateCodec incl. shop), slots, go, colors
	UPGRADES_STATE,  # host -> client: battle_id, visible, run, players (see upgrades_sync.gd)
	# host -> client: kind, count, you, colors, max, reward, join (only while joining is open:
	# hold progress of joining players), players [[id, label, random, ready, inv, idx,
	# locked text, locked by challenge]], grids (on change; see menu_sync.gd)
	MENU_STATE,
	BATTLE_PAUSE,  # host -> client: battle_id, paused, by (name), by_id (steam id, 0: host)
	UI_SOUNDS,  # host -> client: sounds [[res:// path, volume, pitch, position or null]]
	RETRY_PROMPT,  # host -> client: battle_id, visible, retry, retries, player, name
	SHOP_PAUSE,  # host -> client: paused, by, by_id (like BATTLE_PAUSE, while in the shop)
}

const VERSION := 6


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
