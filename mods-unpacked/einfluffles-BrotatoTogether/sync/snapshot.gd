extends Reference
# Battle snapshot wire format (host -> clients, unreliable, ~30 Hz). Plain arrays only.
#
# [battle_id, t_msec, wave_time_left,
#  players: Array of [position: Vector2, health: int, max_health: int],
#  ids: PoolIntArray, types: PoolIntArray, positions: PoolVector2Array]
#
# Entity ids are host-assigned net ids (stable while the entity lives); types index a per-battle
# table of scene paths sent reliably (BATTLE_START / TYPE_DEF).

const FIELD_COUNT := 7


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
		if (
			typeof(player) != TYPE_ARRAY
			or player.size() != 3
			or typeof(player[0]) != TYPE_VECTOR2
			or typeof(player[1]) != TYPE_INT
			or typeof(player[2]) != TYPE_INT
		):
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


# Index of the entity id inside a parsed snapshot, -1 if absent. Snapshots are small (< ~300).
static func index_of(snapshot: Dictionary, id: int) -> int:
	var ids: PoolIntArray = snapshot.ids
	for i in ids.size():
		if ids[i] == id:
			return i
	return -1
