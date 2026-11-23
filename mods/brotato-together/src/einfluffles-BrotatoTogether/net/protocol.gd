extends Reference

enum Msg {
	HELLO,  # client -> host, resent until WELCOME: Compat.local_info (session/compat.gd)
	WELCOME,  # host -> client: version, accepted, reason, dlcs
	PING,  # any -> any: t
	PONG,  # any -> any: t, held (ms the PING waited for the answering frame)
	KICK,  # host -> client, no body: the host removed it from the lobby; the client leaves
	# client -> host, unreliable: [seq, move: Vector2, aim: Vector2, buttons (held mask),
	# presses (4-bit counter per button, sync/press_counter.gd), flags (sync/local_aim.gd),
	# previous: PoolVector2Array (the moves of the up to InputSync.REDUNDANCY inputs right before
	# seq, oldest first, so a lost packet's move still arrives with a later one),
	# sent_msec (the client's OS.get_ticks_msec() when it sent it)]
	INPUT,
	# host -> client: battle_id, run (the parts the client lacks, sync/run_parts.gd),
	# types {idx: scene_path}, colors (palette index per slot), holes (hole layout scene,
	# "": none), weapon_slots (per player), you (the client's player slot, -1: spectator)
	BATTLE_START,
	BATTLE_END,  # host -> client: battle_id
	TYPE_DEF,  # host -> client: battle_id, idx, path
	SNAPSHOT,  # host -> client, unreliable: see sync/snapshot.gd
	UI_SOUNDS,  # host -> client: sounds [[res:// path, volume, pitch, position or null]]
	# client -> host: battle_id, seq (of the sender's panel), kind, id, meca (-1: none).
	# kind "choose" | "reroll" | "take" | "discard" | "ban": id is the upgrade / item my_id
	# ("" for reroll). The crate weapon popup's "weapon_combine" | "weapon_discard" |
	# "weapon_meca_roll" | "weapon_meca" (meca: the index of the option picked): id is the
	# weapon's my_id, plus weapon (its slot in the sender's weapons). Other mods' kinds
	# (UpgradesSync.register_intent): id, plus arg (theirs to define); meca is the panel's meca
	# effect choice
	UPGRADE_INTENT,
	# client -> host: battle_id, page (the sender's carousel page), target (its cursor as a
	# ui/focus_targets.gd target inside its own panel, []: none), popup (its open menu,
	# sync/popup_view.gd). Cosmetic: what the others see.
	UPGRADE_FOCUS,
	# client -> host: shop_id, seq (of the sender's panel), kind, slot, id, arg (the kinds are
	# listed in sync/shop_intents.gd; other mods add their own: ShopSync.register_intent)
	SHOP_INTENT,
	# client -> host: shop_id, page, target, popup (like UPGRADE_FOCUS, inside the sender's shop
	# panel)
	SHOP_FOCUS,
	# host -> client: shop_id, player, stat (Keys hash), value: the icon and number the shop
	# floats over a player's reroll button when a reroll gave a stat (bone dice)
	SHOP_TEXT,
	# host -> client: challenges (ids reached in the host's run), stats (lifetime counter ->
	# how often it went up), won: what the run earns for the client's own save
	PROGRESS,
	# client -> host: kind, scene and that kind's numbers (a window of frame times and prediction
	# corrections, or a scene-change stall) for the host's log, built in sync/client_report.gd
	CLIENT_REPORT,
	# client -> host: scene (its filename), scrolls ([[target, value]]: how far each
	# ScrollContainer of the sender's own panel is scrolled)
	PANEL_SCROLL,
	# host -> client: [section (a StateStream constant), revision, body or null (the section has
	# no state now)]; the body is built by the section's provider (state_body)
	STATE,
}

const VERSION := 33
# How long a client predicts without snapshots and the host keeps a remote player's last INPUT.
# One value for both: a gap the client rides out must not release its buttons on the host.
const STALL_LIMIT_MSEC := 600


static func encode(msg_type: int, body = null) -> PoolByteArray:
	return var2bytes([msg_type, body])


# null: malformed. bytes2var's false: objects in network data are never decoded.
static func decode(data: PoolByteArray):
	if data.empty():
		return null
	var value = bytes2var(data, false)
	if typeof(value) != TYPE_ARRAY or value.size() != 2 or typeof(value[0]) != TYPE_INT:
		return null
	return value
