extends Reference
# Wire format: var2bytes([msg_type, body]). Decoding never allows objects.

enum Msg {
	HELLO,  # client -> host, resent until WELCOME: see session/compat.gd local_info
	WELCOME,  # host -> client: version, accepted, reason, dlcs (session/dlc_borrow.gd)
	PING,  # any -> any: t
	PONG,  # any -> any: t, held (ms the PING waited for the answering frame, see session.gd)
	KICK,  # host -> client: the host removed it from the lobby; the client leaves
	# client -> host, unreliable: [seq, move: Vector2, aim: Vector2, buttons (held mask),
	# presses (4-bit counter per button, sync/press_counter.gd), flags (sync/local_aim.gd),
	# previous: PoolVector2Array (the moves of the up to InputSync.REDUNDANCY inputs right before
	# seq, oldest first, so a lost packet's move still arrives with a later one; protocol 16)]
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
	# listed in sync/shop_intents.gd; other mods add their own: ShopSync.register_intent)
	SHOP_INTENT,
	# client -> host: shop_id, page, target (like UPGRADE_FOCUS, inside the sender's shop panel)
	SHOP_FOCUS,
	# host -> client: shop_id, player, stat (Keys hash), value: the icon and number the shop
	# floats over a player's reroll button when a reroll gave a stat (bone dice; protocol 18)
	SHOP_TEXT,
	# host -> client: challenges (ids reached in the host's run), stats (lifetime counters ->
	# how often they went up), won: what the run earns for the client's own save
	# (session/progress_share.gd; protocol 20)
	PROGRESS,
	# host -> client: [section, revision, body or null (the section has no state now)], see
	# sync/state_stream.gd; each section's body is described where it is built (shop:
	# sync/shop_sync.gd, pause_shop: sync/pause_control.gd)
	STATE,
}

const VERSION := 21
# How long one side carries on without the other's stream (snapshots on a client, INPUT on the
# host) before it counts as gone rather than late. Both ends share it: a client predicts its own
# player for that long without snapshots (sync/battle_client.gd PREDICTION_STALE_MSEC), and the
# host keeps a remote player's held buttons and aim for that long without INPUT
# (sync/input_sync.gd INPUT_TIMEOUT_MSEC), so a gap the client rides out ends without a release.
const STALL_LIMIT_MSEC := 600


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
