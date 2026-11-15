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
	# host -> client: scene, cursors [[player, menu, control]] (menu: the emulator's parent; menu
	# and control as ui/focus_targets.gd targets, see sync/focus_sync.gd)
	FOCUS,
	# host -> client: shop_id, run (RunStateCodec incl. shop), slots, go, seqs, pages, you,
	# colors (see sync/shop_sync.gd)
	SHOP_STATE,
	# host -> client: battle_id, visible, run, players, seqs, pages (see upgrades_sync.gd)
	UPGRADES_STATE,
	# host -> client: kind, count, you, colors, max, reward, join (only while joining is open:
	# hold progress of joining players), players [[id, label, random, ready, inv, idx,
	# locked text, locked by challenge]], grids (on change; see menu_sync.gd)
	MENU_STATE,
	BATTLE_PAUSE,  # host -> client: battle_id, paused, by (name), by_id (steam id, 0: host)
	UI_SOUNDS,  # host -> client: sounds [[res:// path, volume, pitch, position or null]]
	RETRY_PROMPT,  # host -> client: battle_id, visible, retry, retries, player, name
	SHOP_PAUSE,  # host -> client: paused, by, by_id (like BATTLE_PAUSE, while in the shop)
	# client -> host: battle_id, seq (of the sender's panel), kind ("choose" | "reroll" |
	# "take" | "discard" | "ban"), id (upgrade / item my_id, "" for reroll), meca (-1: none).
	# Crate weapon popup: kind "weapon_combine" | "weapon_discard" | "weapon_meca", id (the
	# weapon's my_id), weapon (its slot in the sender's weapons), stat (meca: stat key hash)
	UPGRADE_INTENT,
	# client -> host: battle_id, page (the sender's carousel page), target (its cursor as a
	# ui/focus_targets.gd target inside its own panel, []: none). Cosmetic: what the others see.
	UPGRADE_FOCUS,
	# client -> host: shop_id, seq (of the sender's panel), kind, slot, id, arg (the kinds are
	# listed in sync/shop_intents.gd)
	SHOP_INTENT,
	# client -> host: shop_id, page, target (like UPGRADE_FOCUS, inside the sender's shop panel)
	SHOP_FOCUS,
}

const VERSION := 10


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
