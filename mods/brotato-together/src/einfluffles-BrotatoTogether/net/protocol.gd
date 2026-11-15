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
	# index per slot, CoopService extension; also in the shop and menu states)
	# + holes (hole layout scene, "" none), weapon_slots (per player; sync/battle_scene.gd)
	BATTLE_START,
	BATTLE_END,  # host -> client: battle_id
	TYPE_DEF,  # host -> client: battle_id, idx, path
	SNAPSHOT,  # host -> client, unreliable: see sync/snapshot.gd
	UI_SOUNDS,  # host -> client: sounds [[res:// path, volume, pitch, position or null]]
	# client -> host: battle_id, seq (of the sender's panel), kind ("choose" | "reroll" |
	# "take" | "discard" | "ban"), id (upgrade / item my_id, "" for reroll), meca (-1: none).
	# Crate weapon popup: kind "weapon_combine" | "weapon_discard" | "weapon_meca_roll" (the
	# host rolls the two meca options, sent in the upgrades state) | "weapon_meca" (meca: the
	# index of the option picked), id (the weapon's my_id), weapon (its slot in the sender's
	# weapons)
	UPGRADE_INTENT,
	# client -> host: battle_id, page (the sender's carousel page), target (its cursor as a
	# ui/focus_targets.gd target inside its own panel, []: none). Cosmetic: what the others see.
	UPGRADE_FOCUS,
	# client -> host: shop_id, seq (of the sender's panel), kind, slot, id, arg (the kinds are
	# listed in sync/shop_intents.gd)
	SHOP_INTENT,
	# client -> host: shop_id, page, target (like UPGRADE_FOCUS, inside the sender's shop panel)
	SHOP_FOCUS,
	# host -> client: [section, revision, body or null (the section has no state now)], see
	# sync/state_stream.gd; each section's body is described where it is built (shop:
	# sync/shop_sync.gd, pause_shop: sync/pause_control.gd)
	STATE,
}

const VERSION := 14


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
