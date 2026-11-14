extends Reference
# Battle snapshot wire format (host -> clients, unreliable, ~30 Hz). Plain arrays only.
#
# [battle_id, t_msec, wave_time_left,
#  players: Array of [position: Vector2, health: int, max_health: int, input_ack: int,
#                     gold: int, level: int, xp: float,
#                     weapons: PoolRealArray, per weapon [rotation, sprite_x, sprite_y,
#                     sprite_rotation]],
#  ids: PoolIntArray, types: PoolIntArray, positions: PoolVector2Array]
#
# Entity ids are host-assigned net ids (stable while the entity lives); types index a per-battle
# table of scene paths sent reliably (BATTLE_START / TYPE_DEF). input_ack is the last INPUT seq the
# host applied for that player (0 for host-local players); clients use it to reconcile prediction.

enum PlayerField { POSITION, HEALTH, MAX_HEALTH, INPUT_ACK, GOLD, LEVEL, XP, WEAPONS }

const FIELD_COUNT := 7
const PLAYER_FIELD_TYPES := [
	TYPE_VECTOR2, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_REAL, TYPE_REAL_ARRAY
]
const WEAPON_STRIDE := 4


static func build(
	battle_id: int,
	t_msec: int,
	wave_time_left: float,
	players: Array,
	ids: PoolIntArray,
	types: PoolIntArray,
	positions: PoolVector2Array
) -> Array:
	return [battle_id, t_msec, wave_time_left, players, ids, types, positions]


# Returns a Dictionary view or {} if malformed.
static func parse(body) -> Dictionary:
	if typeof(body) != TYPE_ARRAY or body.size() != FIELD_COUNT:
		return {}
	if (
		typeof(body[0]) != TYPE_INT
		or typeof(body[1]) != TYPE_INT
		or typeof(body[2]) != TYPE_REAL
		or typeof(body[3]) != TYPE_ARRAY
		or typeof(body[4]) != TYPE_INT_ARRAY
		or typeof(body[5]) != TYPE_INT_ARRAY
		or typeof(body[6]) != TYPE_VECTOR2_ARRAY
	):
		return {}
	var ids: PoolIntArray = body[4]
	if body[5].size() != ids.size() or body[6].size() != ids.size():
		return {}
	for player in body[3]:
		if typeof(player) != TYPE_ARRAY or player.size() != PLAYER_FIELD_TYPES.size():
			return {}
		for i in PLAYER_FIELD_TYPES.size():
			if typeof(player[i]) != PLAYER_FIELD_TYPES[i]:
				return {}
	return {
		"battle_id": body[0],
		"t": body[1],
		"wave_time_left": body[2],
		"players": body[3],
		"ids": ids,
		"types": body[5],
		"positions": body[6],
	}


# Weapon attack visuals: aim rotation + the tweened sprite offset/rotation (melee thrusts, recoil).
static func pack_weapons(weapons: Array) -> PoolRealArray:
	var packed := PoolRealArray()
	for weapon in weapons:
		packed.append(weapon.rotation)
		packed.append(weapon.sprite.position.x)
		packed.append(weapon.sprite.position.y)
		packed.append(weapon.sprite.rotation)
	return packed


static func apply_weapons(weapons: Array, a: PoolRealArray, b: PoolRealArray, t: float) -> void:
	var count: int = min(weapons.size(), b.size() / WEAPON_STRIDE)
	if a.size() != b.size():
		a = b  # weapon set changed: no interpolation this frame
	for i in count:
		var k: int = i * WEAPON_STRIDE
		var weapon = weapons[i]
		weapon.rotation = lerp_angle(a[k], b[k], t)
		weapon.sprite.position = Vector2(lerp(a[k + 1], b[k + 1], t), lerp(a[k + 2], b[k + 2], t))
		weapon.sprite.rotation = lerp_angle(a[k + 3], b[k + 3], t)


# Index of the entity id inside a parsed snapshot, -1 if absent. Snapshots are small (< ~300).
static func index_of(snapshot: Dictionary, id: int) -> int:
	var ids: PoolIntArray = snapshot.ids
	for i in ids.size():
		if ids[i] == id:
			return i
	return -1
