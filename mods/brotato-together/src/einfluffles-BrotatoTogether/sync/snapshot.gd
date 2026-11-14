extends Reference
# Battle snapshot wire format (host -> clients, unreliable, ~30 Hz). Plain arrays only.
#
# [battle_id, t_msec, wave_time_left,
#  players: Array of [position: Vector2, health: int, max_health: int, input_ack: int,
#                     gold: int, level: int, xp: float,
#                     weapons: PoolRealArray, per weapon [rotation, sprite_x, sprite_y,
#                     sprite_rotation]],
#  ids: PoolIntArray, types: PoolIntArray, positions: PoolVector2Array,
#  events: Array — one-shot feedback since the last snapshot:
#    [EVENT_DAMAGE, target, value, knockback: Vector2, flags, hit_type]
#      target: entity net id, or -(player_index + 1) for players
#    [EVENT_SOUND, type idx of the stream, position: Vector2 or null, volume, pitch],
#  flags: PoolByteArray, FLAG_BITS bits per entity (entity i at bit i * FLAG_BITS):
#    FLAG_FACING_LEFT (unit sprite mirrored), FLAG_HIDDEN, FLAG_FLIP_H (unit sprite.flip_h),
#  poses: PoolRealArray, only for entities with moving parts (see sync/pose.gd), as runs of
#    [entity index, value count, values...] with ascending entity indices]
#
# Entity ids are host-assigned net ids (stable while the entity lives); types index a per-battle
# table of scene paths sent reliably (BATTLE_START / TYPE_DEF). input_ack is the last INPUT seq the
# host applied for that player (0 for host-local players); clients use it to reconcile prediction.

enum PlayerField { POSITION, HEALTH, MAX_HEALTH, INPUT_ACK, GOLD, LEVEL, XP, WEAPONS }

const FIELD_COUNT := 10
const EVENT_DAMAGE := 0
const EVENT_SOUND := 1
const DAMAGE_CRIT := 1
const DAMAGE_DODGE := 2
const DAMAGE_PROTECTED := 4
const DAMAGE_ARMOR := 8
const DAMAGE_ONE_SHOT := 16
const PLAYER_FIELD_TYPES := [
	TYPE_VECTOR2, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_REAL, TYPE_REAL_ARRAY
]
const WEAPON_STRIDE := 4
const FLAG_FACING_LEFT := 1
const FLAG_HIDDEN := 2
const FLAG_FLIP_H := 4  # jump attacks turn the sprite with flip_h, not scale.x
const FLAG_BITS := 3
const MAX_POSE_VALUES := 48  # see sync/pose.gd


static func build(
	battle_id: int,
	t_msec: int,
	wave_time_left: float,
	players: Array,
	ids: PoolIntArray,
	types: PoolIntArray,
	positions: PoolVector2Array,
	events: Array,
	flags: PoolByteArray,
	poses: PoolRealArray
) -> Array:
	return [battle_id, t_msec, wave_time_left, players, ids, types, positions, events, flags, poses]


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
		or typeof(body[7]) != TYPE_ARRAY
		or typeof(body[8]) != TYPE_RAW_ARRAY
		or typeof(body[9]) != TYPE_REAL_ARRAY
	):
		return {}
	var ids: PoolIntArray = body[4]
	if body[5].size() != ids.size() or body[6].size() != ids.size():
		return {}
	if body[8].size() != flags_size(ids.size()):
		return {}
	var poses = parse_poses(body[9], ids.size())
	if typeof(poses) != TYPE_DICTIONARY:
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
		"events": body[7],
		"flags": body[8],
		"poses": poses,
	}


static func flags_size(entity_count: int) -> int:
	return (entity_count * FLAG_BITS + 7) / 8


# One FLAG_* combination per entity -> packed bits. (Pool arrays are passed by value in GDScript 3.)
static func pack_flags(values: Array) -> PoolByteArray:
	var flags := PoolByteArray()
	flags.resize(flags_size(values.size()))
	for i in flags.size():
		flags[i] = 0
	for i in values.size():
		var bit: int = i * FLAG_BITS
		flags[bit / 8] |= values[i] << (bit % 8)
	return flags


static func get_flags(flags: PoolByteArray, i: int) -> int:
	var bit := i * FLAG_BITS
	return (flags[bit / 8] >> (bit % 8)) & ((1 << FLAG_BITS) - 1)


# entity index -> PoolRealArray, or null if malformed (indices must ascend, counts be sane).
static func parse_poses(poses: PoolRealArray, entity_count: int):
	var result := {}
	var k := 0
	var last := -1
	while k < poses.size():
		if k + 2 > poses.size():
			return null
		var index := int(poses[k])
		var count := int(poses[k + 1])
		if (
			float(index) != poses[k]
			or float(count) != poses[k + 1]
			or index <= last
			or index >= entity_count
			or count < 1
			or count > MAX_POSE_VALUES
			or k + 2 + count > poses.size()
		):
			return null
		var values := PoolRealArray()
		for v in range(k + 2, k + 2 + count):
			if is_nan(poses[v]) or is_inf(poses[v]):
				return null
			values.append(poses[v])
		result[index] = values
		last = index
		k += 2 + count
	return result


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
