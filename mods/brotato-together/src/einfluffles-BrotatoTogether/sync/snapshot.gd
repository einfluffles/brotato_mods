extends Reference
# Battle snapshot (host -> clients, unreliable, ~30 Hz): a hand-packed PoolByteArray, little endian.
# A view (Dictionary) is what encode() takes and parse() returns:
#   battle_id, t (host msec), wave_time_left,
#   players: Array of [position: Vector2, health, max_health, input_ack, gold, level, xp: float,
#            weapons: PoolRealArray, per weapon [rotation, sprite_x, sprite_y, sprite_rotation]]
#            health/max_health/gold/level/xp are null when not sent (see below),
#            weapon_slots: PoolIntArray (wave-start slot of each weapon) or null (all still held),
#            speed: px/s or null when not sent (see sync/battle_scene.gd)]
#   ids, types: PoolIntArray; positions: PoolVector2Array (Vector2.ZERO for FLAG_REST entities)
#   flags: PoolByteArray, FLAG_BITS per entity (entity i at bit i * FLAG_BITS)
#   poses: {entity index: PoolRealArray} (see sync/pose.gd)
#   events: Array of
#     [EVENT_DAMAGE, target, value, knockback: Vector2, DAMAGE_* flags, hit_type]
#       target: entity net id, or -(player_index + 1) for players
#     [EVENT_SOUND, type idx of the stream, position: Vector2 or null, volume, pitch_rand,
#      always_play: bool, single cooldown (s, 0: SoundManager.play)]
#     [EVENT_ANIM, net id, animation name, position (s), speed] (see sync/anim_mirror.gd)
#     protocol 11 (see sync/feedback_mirror.gd):
#     [EVENT_EXPLOSION, type idx of the scene, position: Vector2, scale, smoke amount]
#     [EVENT_BONUS_GOLD, value, label visible: bool] (state, repeated)
#     [EVENT_WAVE_END, WAVE_* flags] (state, repeated)
#     [EVENT_GOLD_BOOST, position: Vector2, boost]
#     [EVENT_STAT, player index, stat (Keys hash), value] (the icon and number over a player)
#     [EVENT_WEAPON_ANIM, player index, weapon index, position (s)] (a whip's or flail's lash)
#   looks: {entity index: look bits} (since protocol 12, see sync/looks.gd; indices of the parsed
#     entity order: Looks.resolve reads them before resolve() may drop entities)
#   angles: the rotation of projectiles (protocol 18, see sync/facing.gd); encode() takes
#     {entity index: radians}, parse() returns {net id: radians}
#
# Wire layout:
#   u32 battle_id, u32 t, u16 wave time left (1/100 s)
#   u8 player count; per player: u8 PLAYER_STATS bit, i16 x, i16 y (1/POS_SCALE px),
#     varint input_ack, [stats: zigzag health, zigzag max_health, zigzag gold, varint level,
#     f32 xp], u8 weapon count, bitmask (1 bit per weapon: sprite moved), per weapon i16 angle
#     [+ i16 sprite x, i16 sprite y (1/8 px), i16 sprite angle],
#     [PLAYER_WEAPON_SLOTS: u8 bit count, slot bitmask], [PLAYER_SPEED: varint px/s]
#   u16 entity count; varint run count, runs of [varint type idx, varint length] (types in
#     entity order); net ids as zigzag varint deltas to the previous one (the host sorts each run
#     by id: mostly 1 byte); flags; i16 x, i16 y per entity without FLAG_REST
#   varint pose count; per pose: varint entity index (ascending), u8 value count, f32 values
#   u8 event count; per event: u8 kind + payload (see _put_event)
#   varint look count; per look: varint gap to the previous entity index + 1 (ascending), u8 bits
#   varint angle count; per angle: varint gap like the looks', i16 angle
# Nothing may follow. Angles are i16 over [-PI, PI].
#
# Rarely changing data is sparse; the client fills the gaps from earlier snapshots (resolve()):
# - FLAG_REST: the entity has not moved for a few snapshots (gold on the ground, structures): its
#   position is left out, except in a refresh every BattleHost.REST_REFRESH snapshots.
# - Player stats (HUD values) only for a while after they change and in periodic refreshes.
#
# Entity ids are host-assigned net ids (u16, stable while the entity lives); types index a
# per-battle table of scene paths sent reliably (BATTLE_START / TYPE_DEF). input_ack is the last
# INPUT seq the host applied for that player (0 for host-local players).

enum PlayerField {
	POSITION, HEALTH, MAX_HEALTH, INPUT_ACK, GOLD, LEVEL, XP, WEAPONS, WEAPON_SLOTS, SPEED
}

const EVENT_DAMAGE := 0
const EVENT_SOUND := 1
const EVENT_ANIM := 2
const EVENT_EXPLOSION := 3
const EVENT_BONUS_GOLD := 4
const EVENT_WAVE_END := 5
const EVENT_GOLD_BOOST := 6
const EVENT_STAT := 7
const EVENT_WEAPON_ANIM := 8
const DAMAGE_CRIT := 1
const DAMAGE_DODGE := 2
const DAMAGE_PROTECTED := 4
const DAMAGE_ARMOR := 8
const DAMAGE_ONE_SHOT := 16
const DAMAGE_FLAGS := 31
const DAMAGE_TO_PLAYER := 128  # wire only: target is a player index
const SOUND_POSITION := 1  # wire only
const SOUND_ALWAYS := 2
const SOUND_SINGLE := 4
const PLAYER_STATS := 1  # wire only
const BONUS_VISIBLE := 1  # wire only
const WAVE_FAILED := 1
const WAVE_LOST := 2
const WAVE_WON := 4
const WAVE_LABEL := 8  # the "wave completed" label is showing
const WAVE_FLAGS := 15
const EXPLOSION_SCALE := 100.0
const PLAYER_WEAPON_SLOTS := 2  # wire only (protocol 13, sync/battle_scene.gd)
const PLAYER_SPEED := 4  # wire only (protocol 13)
const MAX_SPEED := 1 << 20  # px/s; parse rejects more
const STAT_FIELDS := [
	PlayerField.HEALTH, PlayerField.MAX_HEALTH, PlayerField.GOLD, PlayerField.LEVEL, PlayerField.XP
]
const WEAPON_STRIDE := 4
const FLAG_FACING_LEFT := 1
const FLAG_HIDDEN := 2
const FLAG_FLIP_H := 4  # jump attacks turn the sprite with flip_h, not scale.x
const FLAG_REST := 8  # position not sent: unchanged (see resolve)
const FLAG_BITS := 4
const MAX_POSE_VALUES := 48  # see sync/pose.gd
const LOOK_BITS := 255  # every bit sync/looks.gd defines; parse rejects others
const MAX_PLAYERS := 8
const MAX_WEAPONS := 32
const MAX_ENTITIES := 8192
const MAX_EVENTS := 64  # what parse accepts; the host sends at most BattleHost.MAX_EVENTS
const MAX_NAME_BYTES := 64
const MAX_NET_ID := 65535
const POS_SCALE := 2.0  # 0.5 px steps (error <= 0.25 px), +-16 k px
const OFFSET_SCALE := 8.0  # weapon sprite offsets: 1/8 px
const ANGLE_SCALE := 32767.0 / PI
const KNOCKBACK_SCALE := 127.0
const VOLUME_SCALE := 2.0  # 0.5 dB
const PITCH_SCALE := 100.0
const COOLDOWN_SCALE := 50.0
const ANIM_TIME_SCALE := 1000.0
const RANK_STRIDE := 1 << 20


# --- encode ---


static func encode(view: Dictionary) -> PoolByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(view.battle_id)
	buf.put_u32(view.t)
	buf.put_u16(int(clamp(round(view.wave_time_left * 100.0), 0, 65535)))
	buf.put_u8(view.players.size())
	for entry in view.players:
		_put_player(buf, entry)
	var ids: PoolIntArray = view.ids
	var types: PoolIntArray = view.types
	var positions: PoolVector2Array = view.positions
	var flags: PoolByteArray = view.flags
	var count := ids.size()
	buf.put_u16(count)
	var runs := []  # [type, length]
	for i in count:
		if runs.empty() or runs[-1][0] != types[i]:
			runs.append([types[i], 0])
		runs[-1][1] += 1
	_put_varint(buf, runs.size())
	for run in runs:
		_put_varint(buf, run[0])
		_put_varint(buf, run[1])
	# Per entity, so without calls (several hundred entities, 30 times a second).
	var previous := 0
	for i in count:  # zigzag deltas: 1 byte for ids close to the previous one (host sorts runs)
		var id := ids[i]
		var delta := id - previous
		previous = id
		delta = delta * 2 if delta >= 0 else -delta * 2 - 1
		while delta >= 128:
			buf.put_u8((delta & 127) | 128)
			delta >>= 7
		buf.put_u8(delta)
	if not flags.empty():
		buf.put_data(flags)
	for i in count:
		var bit: int = i * FLAG_BITS
		if not (flags[bit >> 3] >> (bit & 7)) & FLAG_REST:
			var position := positions[i]
			buf.put_16(int(clamp(round(position.x * POS_SCALE), -32768, 32767)))
			buf.put_16(int(clamp(round(position.y * POS_SCALE), -32768, 32767)))
	var pose_indices: Array = view.poses.keys()
	pose_indices.sort()
	_put_varint(buf, pose_indices.size())
	for index in pose_indices:
		var values: PoolRealArray = view.poses[index]
		_put_varint(buf, index)
		buf.put_u8(values.size())
		for value in values:
			buf.put_float(value)
	buf.put_u8(view.events.size())
	for event in view.events:
		_put_event(buf, event)
	_put_looks(buf, view.get("looks", {}))
	_put_angles(buf, view.get("angles", {}))
	return buf.data_array


# Sparse like the looks: only the projectiles whose rotation the host sends this time.
static func _put_angles(buf: StreamPeerBuffer, angles: Dictionary) -> void:
	var indices: Array = angles.keys()
	indices.sort()
	_put_varint(buf, indices.size())
	var next := 0
	for index in indices:
		_put_varint(buf, index - next)
		buf.put_16(_angle(angles[index]))
		next = index + 1


# Sparse: only entities whose look the host sends this time (sync/looks.gd).
static func _put_looks(buf: StreamPeerBuffer, looks: Dictionary) -> void:
	var indices: Array = looks.keys()
	indices.sort()
	_put_varint(buf, indices.size())
	var next := 0
	for index in indices:
		_put_varint(buf, index - next)
		buf.put_u8(looks[index] & LOOK_BITS)
		next = index + 1


static func _put_player(buf: StreamPeerBuffer, entry: Array) -> void:
	var has_stats: bool = entry[PlayerField.HEALTH] != null
	buf.put_u8((PLAYER_STATS if has_stats else 0) | _scene_flags(entry))
	_put_position(buf, entry[PlayerField.POSITION])
	_put_varint(buf, entry[PlayerField.INPUT_ACK])
	if has_stats:
		_put_varint(buf, _zigzag(entry[PlayerField.HEALTH]))
		_put_varint(buf, _zigzag(entry[PlayerField.MAX_HEALTH]))
		_put_varint(buf, _zigzag(entry[PlayerField.GOLD]))
		_put_varint(buf, max(0, entry[PlayerField.LEVEL]))
		buf.put_float(entry[PlayerField.XP])
	var weapons: PoolRealArray = entry[PlayerField.WEAPONS]
	var count := int(min(weapons.size() / WEAPON_STRIDE, MAX_WEAPONS))
	buf.put_u8(count)
	var moved := PoolByteArray()
	moved.resize((count + 7) / 8)
	for i in moved.size():
		moved[i] = 0
	for i in count:
		if _sprite_moved(weapons, i * WEAPON_STRIDE):
			moved[i / 8] |= 1 << (i % 8)
	if not moved.empty():
		buf.put_data(moved)
	for i in count:
		var k: int = i * WEAPON_STRIDE
		buf.put_16(_angle(weapons[k]))
		if moved[i / 8] & (1 << (i % 8)):
			buf.put_16(_quantize(weapons[k + 1], OFFSET_SCALE))
			buf.put_16(_quantize(weapons[k + 2], OFFSET_SCALE))
			buf.put_16(_angle(weapons[k + 3]))
	_put_scene_fields(buf, entry)


# Protocol 13: [weapon slots: u8 bit count, mask (1 bit per wave-start weapon still held)],
# [speed: varint px/s], after the weapons and only when their flag bit is set.
static func _scene_flags(entry: Array) -> int:
	var flags := 0
	if entry.size() > PlayerField.WEAPON_SLOTS and entry[PlayerField.WEAPON_SLOTS] != null:
		flags |= PLAYER_WEAPON_SLOTS
	if entry.size() > PlayerField.SPEED and entry[PlayerField.SPEED] != null:
		flags |= PLAYER_SPEED
	return flags


static func _put_scene_fields(buf: StreamPeerBuffer, entry: Array) -> void:
	var flags := _scene_flags(entry)
	if flags & PLAYER_WEAPON_SLOTS:
		var slots: PoolIntArray = entry[PlayerField.WEAPON_SLOTS]
		var bits := 0
		for slot in slots:
			bits = int(max(bits, slot + 1))
		var mask := PoolByteArray()
		mask.resize((bits + 7) / 8)
		for i in mask.size():
			mask[i] = 0
		for slot in slots:
			mask[slot / 8] |= 1 << (slot % 8)
		buf.put_u8(bits)
		if not mask.empty():
			buf.put_data(mask)
	if flags & PLAYER_SPEED:
		_put_varint(buf, int(clamp(entry[PlayerField.SPEED], 0, MAX_SPEED)))


# false if malformed: more bits than weapons can have, bits set past the count, or a mask that
# does not hold exactly as many weapons as the snapshot lists.
static func _get_scene_fields(buf: StreamPeerBuffer, entry: Array, flags: int) -> bool:
	if flags & PLAYER_WEAPON_SLOTS:
		if buf.get_available_bytes() < 1:
			return false
		var bits := buf.get_u8()
		var size := (bits + 7) / 8
		if bits > MAX_WEAPONS or buf.get_available_bytes() < size:
			return false
		var mask: PoolByteArray = buf.get_data(size)[1] if size > 0 else PoolByteArray()
		var slots := PoolIntArray()
		for i in size * 8:
			if mask[i / 8] & (1 << (i % 8)):
				if i >= bits:
					return false
				slots.append(i)
		if slots.size() != entry[PlayerField.WEAPONS].size() / WEAPON_STRIDE:
			return false
		entry[PlayerField.WEAPON_SLOTS] = slots
	if flags & PLAYER_SPEED:
		var value := _get_varint(buf)
		if value < 0 or value > MAX_SPEED:
			return false
		entry[PlayerField.SPEED] = value
	return true


static func _sprite_moved(weapons: PoolRealArray, k: int) -> bool:
	return (
		_quantize(weapons[k + 1], OFFSET_SCALE) != 0
		or _quantize(weapons[k + 2], OFFSET_SCALE) != 0
		or _angle(weapons[k + 3]) != 0
	)


static func _put_event(buf: StreamPeerBuffer, event: Array) -> void:
	buf.put_u8(event[0])
	match event[0]:
		EVENT_DAMAGE:
			var target: int = event[1]
			var flags: int = event[4] & DAMAGE_FLAGS
			buf.put_u8(flags | (DAMAGE_TO_PLAYER if target < 0 else 0))
			if target < 0:
				buf.put_u8(int(clamp(-target - 1, 0, 255)))
			else:
				buf.put_u16(target)
			_put_varint(buf, _zigzag(event[2]))
			var knockback: Vector2 = event[3]
			buf.put_8(int(round(clamp(knockback.x, -1.0, 1.0) * KNOCKBACK_SCALE)))
			buf.put_8(int(round(clamp(knockback.y, -1.0, 1.0) * KNOCKBACK_SCALE)))
			buf.put_u8(int(clamp(event[5], 0, 255)))
		EVENT_SOUND:
			var flags := 0
			flags |= SOUND_POSITION if event[2] != null else 0
			flags |= SOUND_ALWAYS if event[5] else 0
			flags |= SOUND_SINGLE if event[6] > 0.0 else 0
			buf.put_u8(flags)
			_put_varint(buf, event[1])
			if event[2] != null:
				_put_position(buf, event[2])
			buf.put_8(int(round(clamp(event[3] * VOLUME_SCALE, -128, 127))))
			buf.put_u8(int(round(clamp(event[4] * PITCH_SCALE, 0, 255))))
			if event[6] > 0.0:
				buf.put_u8(int(round(clamp(event[6] * COOLDOWN_SCALE, 1, 255))))
		EVENT_ANIM:
			buf.put_u16(event[1])
			var name := _ascii_name(event[2])
			buf.put_u8(name.size())
			if not name.empty():
				buf.put_data(name)
			buf.put_u16(int(clamp(round(event[3] * ANIM_TIME_SCALE), 0, 65535)))
			buf.put_u16(int(clamp(round(event[4] * ANIM_TIME_SCALE), 0, 65535)))
		EVENT_EXPLOSION, EVENT_BONUS_GOLD, EVENT_WAVE_END, EVENT_GOLD_BOOST:
			_put_feedback_event(buf, event)
		EVENT_STAT, EVENT_WEAPON_ANIM:
			_put_feedback_event(buf, event)


# Protocol 11 kinds, after the kind byte:
#   EXPLOSION: varint type idx, i16 x, i16 y, u16 scale (1/100, >= 1), u8 smoke amount
#   BONUS_GOLD: u8 BONUS_VISIBLE bit, varint value
#   WAVE_END: u8 WAVE_* flags
#   GOLD_BOOST: i16 x, i16 y, u8 boost
#   STAT (protocol 18): u8 player index, u32 stat hash, zigzag varint value
#   WEAPON_ANIM (protocol 18): u8 player index, u8 weapon index, u16 position (ms)
static func _put_feedback_event(buf: StreamPeerBuffer, event: Array) -> void:
	match event[0]:
		EVENT_WEAPON_ANIM:
			buf.put_u8(int(clamp(event[1], 0, 255)))
			buf.put_u8(int(clamp(event[2], 0, 255)))
			buf.put_u16(int(clamp(round(event[3] * ANIM_TIME_SCALE), 0, 65535)))
		EVENT_STAT:
			buf.put_u8(int(clamp(event[1], 0, 255)))
			buf.put_u32(event[2])
			_put_varint(buf, _zigzag(event[3]))
		EVENT_EXPLOSION:
			_put_varint(buf, event[1])
			_put_position(buf, event[2])
			buf.put_u16(int(clamp(round(event[3] * EXPLOSION_SCALE), 1, 65535)))
			buf.put_u8(int(clamp(event[4], 0, 255)))
		EVENT_BONUS_GOLD:
			buf.put_u8(BONUS_VISIBLE if event[2] else 0)
			_put_varint(buf, event[1])
		EVENT_WAVE_END:
			buf.put_u8(event[1] & WAVE_FLAGS)
		EVENT_GOLD_BOOST:
			_put_position(buf, event[1])
			buf.put_u8(int(clamp(event[2], 0, 255)))


# Printable ASCII, else empty (the client ignores nameless animations; parse rejects the rest).
static func _ascii_name(name) -> PoolByteArray:
	var bytes: PoolByteArray = String(name).left(MAX_NAME_BYTES).to_utf8()
	for byte in bytes:
		if byte < 32 or byte > 126:
			return PoolByteArray()
	return bytes


static func _put_position(buf: StreamPeerBuffer, position: Vector2) -> void:
	buf.put_16(_quantize(position.x, POS_SCALE))
	buf.put_16(_quantize(position.y, POS_SCALE))


static func _put_varint(buf: StreamPeerBuffer, value: int) -> void:
	value = int(max(value, 0))
	while value >= 128:
		buf.put_u8((value & 127) | 128)
		value >>= 7
	buf.put_u8(value)


static func _quantize(value: float, scale: float) -> int:
	return int(clamp(round(value * scale), -32768, 32767))


static func _angle(value: float) -> int:
	return int(clamp(round(wrapf(value, -PI, PI) * ANGLE_SCALE), -32767, 32767))


static func _zigzag(value: int) -> int:
	return value * 2 if value >= 0 else -value * 2 - 1


# An angle as the wire carries it (the host compares these to see a projectile turn).
static func quantize_angle(value: float) -> int:
	return _angle(value)


# Snapped like on the wire: the host compares these to detect resting entities.
static func quantize_position(position: Vector2) -> Vector2:
	return Vector2(_quantize(position.x, POS_SCALE), _quantize(position.y, POS_SCALE))


# --- parse ---


# Returns the view, or {} if the body is malformed in any way.
static func parse(body) -> Dictionary:
	if typeof(body) != TYPE_RAW_ARRAY or body.size() < 11:
		return {}
	var buf := StreamPeerBuffer.new()
	buf.data_array = body
	var view := {
		"battle_id": buf.get_u32(),
		"t": buf.get_u32(),
		"wave_time_left": buf.get_u16() / 100.0,
		"players": [],
	}
	var player_count := buf.get_u8()
	if player_count > MAX_PLAYERS:
		return {}
	for _i in player_count:
		var entry = _get_player(buf)
		if entry == null:
			return {}
		view.players.append(entry)
	if not _get_entities(buf, view) or not _get_poses(buf, view):
		return {}
	if buf.get_available_bytes() < 1:
		return {}
	var event_count := buf.get_u8()
	if event_count > MAX_EVENTS:
		return {}
	view["events"] = []
	for _i in event_count:
		var event = _get_event(buf)
		if event == null:
			return {}
		view.events.append(event)
	if not _get_looks(buf, view) or not _get_angles(buf, view):
		return {}
	return view if buf.get_available_bytes() == 0 else {}


static func _get_angles(buf: StreamPeerBuffer, view: Dictionary) -> bool:
	var count := _get_varint(buf)
	var ids: PoolIntArray = view.ids
	if count < 0 or count > ids.size():
		return false
	var angles := {}
	var next := 0
	for _i in count:
		var gap := _get_varint(buf)
		if gap < 0 or next + gap >= ids.size() or buf.get_available_bytes() < 2:
			return false
		angles[ids[next + gap]] = buf.get_16() / ANGLE_SCALE
		next += gap + 1
	view["angles"] = angles
	return true


static func _get_looks(buf: StreamPeerBuffer, view: Dictionary) -> bool:
	var count := _get_varint(buf)
	var entity_count: int = view.ids.size()
	if count < 0 or count > entity_count:
		return false
	var looks := {}
	var next := 0
	for _i in count:
		var gap := _get_varint(buf)
		if gap < 0 or next + gap >= entity_count or buf.get_available_bytes() < 1:
			return false
		var look := buf.get_u8()
		if look & ~LOOK_BITS:
			return false
		looks[next + gap] = look
		next += gap + 1
	view["looks"] = looks
	return true


static func _get_player(buf: StreamPeerBuffer):
	if buf.get_available_bytes() < 5:
		return null
	var stats_flag := buf.get_u8()
	if stats_flag & ~(PLAYER_STATS | PLAYER_WEAPON_SLOTS | PLAYER_SPEED):
		return null
	var entry := []
	entry.resize(PlayerField.size())
	entry[PlayerField.POSITION] = _get_position(buf)
	entry[PlayerField.INPUT_ACK] = _get_varint(buf)
	if entry[PlayerField.INPUT_ACK] < 0:
		return null
	if stats_flag & PLAYER_STATS:
		entry[PlayerField.HEALTH] = _unzigzag(_get_varint(buf))
		entry[PlayerField.MAX_HEALTH] = _unzigzag(_get_varint(buf))
		entry[PlayerField.GOLD] = _unzigzag(_get_varint(buf))
		entry[PlayerField.LEVEL] = _get_varint(buf)
		if entry[PlayerField.LEVEL] < 0 or buf.get_available_bytes() < 4:
			return null
		for field in [PlayerField.HEALTH, PlayerField.MAX_HEALTH, PlayerField.GOLD]:
			if entry[field] == null:
				return null
		entry[PlayerField.XP] = buf.get_float()
		if is_nan(entry[PlayerField.XP]) or is_inf(entry[PlayerField.XP]):
			return null
	if buf.get_available_bytes() < 1:
		return null
	var count := buf.get_u8()
	var mask_size := (count + 7) / 8
	if count > MAX_WEAPONS or buf.get_available_bytes() < mask_size + 2 * count:
		return null
	var moved: PoolByteArray = buf.get_data(mask_size)[1] if mask_size > 0 else PoolByteArray()
	var weapons := PoolRealArray()
	for i in count:
		var sprite_moved: bool = moved[i / 8] & (1 << (i % 8))
		if buf.get_available_bytes() < (8 if sprite_moved else 2):
			return null
		weapons.append(buf.get_16() / ANGLE_SCALE)
		if sprite_moved:
			weapons.append(buf.get_16() / OFFSET_SCALE)
			weapons.append(buf.get_16() / OFFSET_SCALE)
			weapons.append(buf.get_16() / ANGLE_SCALE)
		else:
			weapons.append_array(PoolRealArray([0.0, 0.0, 0.0]))
	entry[PlayerField.WEAPONS] = weapons
	if not _get_scene_fields(buf, entry, stats_flag):
		return null
	return entry


static func _get_entities(buf: StreamPeerBuffer, view: Dictionary) -> bool:
	if buf.get_available_bytes() < 2:
		return false
	var count := buf.get_u16()
	if count > MAX_ENTITIES:
		return false
	var run_count := _get_varint(buf)
	if run_count < 0 or run_count > count:
		return false
	var types := PoolIntArray()
	for _i in run_count:
		var type_idx := _get_varint(buf)
		var length := _get_varint(buf)
		if type_idx < 0 or length < 1 or types.size() + length > count:
			return false
		for _k in length:
			types.append(type_idx)
	if types.size() != count or buf.get_available_bytes() < count:
		return false
	var ids := PoolIntArray()
	ids.resize(count)
	var previous := 0
	for i in count:
		var delta = _unzigzag(_get_varint(buf))
		if delta == null or previous + delta < 1 or previous + delta > MAX_NET_ID:
			return false
		previous += delta
		ids[i] = previous
	var flags_bytes := flags_size(count)
	if buf.get_available_bytes() < flags_bytes:
		return false
	var flags: PoolByteArray = buf.get_data(flags_bytes)[1] if flags_bytes > 0 else PoolByteArray()
	var positions := PoolVector2Array()
	positions.resize(count)
	for i in count:
		if get_flags(flags, i) & FLAG_REST:
			positions[i] = Vector2.ZERO
		elif buf.get_available_bytes() < 4:
			return false
		else:
			positions[i] = _get_position(buf)
	view["ids"] = ids
	view["types"] = types
	view["positions"] = positions
	view["flags"] = flags
	return true


static func _get_poses(buf: StreamPeerBuffer, view: Dictionary) -> bool:
	var count := _get_varint(buf)
	var entity_count: int = view.ids.size()
	if count < 0 or count > entity_count:
		return false
	var poses := {}
	var last := -1
	for _i in count:
		var index := _get_varint(buf)
		if index <= last or index >= entity_count or buf.get_available_bytes() < 1:
			return false
		var size := buf.get_u8()
		if size < 1 or size > MAX_POSE_VALUES or buf.get_available_bytes() < 4 * size:
			return false
		var values := PoolRealArray()
		for _k in size:
			var value := buf.get_float()
			if is_nan(value) or is_inf(value):
				return false
			values.append(value)
		poses[index] = values
		last = index
	view["poses"] = poses
	return true


static func _get_event(buf: StreamPeerBuffer):
	if buf.get_available_bytes() < 1:
		return null
	var kind := buf.get_u8()
	match kind:
		EVENT_DAMAGE:
			if buf.get_available_bytes() < 2:
				return null
			var flags := buf.get_u8()
			var to_player := bool(flags & DAMAGE_TO_PLAYER)
			if flags & ~(DAMAGE_FLAGS | DAMAGE_TO_PLAYER):
				return null
			if buf.get_available_bytes() < (1 if to_player else 2):
				return null
			var target: int = -(buf.get_u8() + 1) if to_player else buf.get_u16()
			var value = _unzigzag(_get_varint(buf))
			if value == null or buf.get_available_bytes() < 3:
				return null
			var knockback := Vector2(buf.get_8(), buf.get_8()) / KNOCKBACK_SCALE
			return [EVENT_DAMAGE, target, value, knockback, flags & DAMAGE_FLAGS, buf.get_u8()]
		EVENT_SOUND:
			if buf.get_available_bytes() < 1:
				return null
			var flags := buf.get_u8()
			if flags & ~(SOUND_POSITION | SOUND_ALWAYS | SOUND_SINGLE):
				return null
			var type_idx := _get_varint(buf)
			var size := 2 + (4 if flags & SOUND_POSITION else 0) + (1 if flags & SOUND_SINGLE else 0)
			if type_idx < 0 or buf.get_available_bytes() < size:
				return null
			var position = _get_position(buf) if flags & SOUND_POSITION else null
			var volume := buf.get_8() / VOLUME_SCALE
			var pitch := buf.get_u8() / PITCH_SCALE
			var cooldown: float = buf.get_u8() / COOLDOWN_SCALE if flags & SOUND_SINGLE else 0.0
			var always := bool(flags & SOUND_ALWAYS)
			return [EVENT_SOUND, type_idx, position, volume, pitch, always, cooldown]
		EVENT_ANIM:
			if buf.get_available_bytes() < 3:
				return null
			var id := buf.get_u16()
			var size := buf.get_u8()
			if size > MAX_NAME_BYTES or buf.get_available_bytes() < size + 4:
				return null
			var name := ""
			if size > 0:
				var bytes: PoolByteArray = buf.get_data(size)[1]
				for byte in bytes:
					if byte < 32 or byte > 126:  # printable ASCII only
						return null
				name = bytes.get_string_from_ascii()
			var position := buf.get_u16() / ANIM_TIME_SCALE
			return [EVENT_ANIM, id, name, position, buf.get_u16() / ANIM_TIME_SCALE]
		EVENT_EXPLOSION, EVENT_BONUS_GOLD, EVENT_WAVE_END, EVENT_GOLD_BOOST:
			return _get_feedback_event(buf, kind)
		EVENT_STAT, EVENT_WEAPON_ANIM:
			return _get_feedback_event(buf, kind)
	return null


static func _get_feedback_event(buf: StreamPeerBuffer, kind: int):
	match kind:
		EVENT_WEAPON_ANIM:
			if buf.get_available_bytes() < 4:
				return null
			var player := buf.get_u8()
			var weapon := buf.get_u8()
			if player >= MAX_PLAYERS or weapon >= MAX_WEAPONS:
				return null
			return [EVENT_WEAPON_ANIM, player, weapon, buf.get_u16() / ANIM_TIME_SCALE]
		EVENT_STAT:
			if buf.get_available_bytes() < 6:
				return null
			var player := buf.get_u8()
			var stat := buf.get_u32()
			var value = _unzigzag(_get_varint(buf))
			return null if value == null or player >= MAX_PLAYERS else [EVENT_STAT, player, stat, value]
		EVENT_EXPLOSION:
			var type_idx := _get_varint(buf)
			if type_idx < 0 or buf.get_available_bytes() < 7:
				return null
			var position := _get_position(buf)
			var scale := buf.get_u16()
			if scale == 0:
				return null
			return [EVENT_EXPLOSION, type_idx, position, scale / EXPLOSION_SCALE, buf.get_u8()]
		EVENT_BONUS_GOLD:
			if buf.get_available_bytes() < 2:
				return null
			var flags := buf.get_u8()
			var value := _get_varint(buf)
			if flags & ~BONUS_VISIBLE or value < 0:
				return null
			return [EVENT_BONUS_GOLD, value, bool(flags & BONUS_VISIBLE)]
		EVENT_WAVE_END:
			if buf.get_available_bytes() < 1:
				return null
			var flags := buf.get_u8()
			return null if flags & ~WAVE_FLAGS else [EVENT_WAVE_END, flags]
		EVENT_GOLD_BOOST:
			if buf.get_available_bytes() < 5:
				return null
			var position := _get_position(buf)
			return [EVENT_GOLD_BOOST, position, buf.get_u8()]
	return null


static func _get_position(buf: StreamPeerBuffer) -> Vector2:
	var x := buf.get_16() / POS_SCALE
	return Vector2(x, buf.get_16() / POS_SCALE)


# -1 if truncated or longer than 5 bytes.
static func _get_varint(buf: StreamPeerBuffer) -> int:
	var value := 0
	var shift := 0
	while shift <= 28:
		if buf.get_available_bytes() < 1:
			return -1
		var byte := buf.get_u8()
		value |= (byte & 127) << shift
		if byte < 128:
			return value
		shift += 7
	return -1


static func _unzigzag(value: int):
	if value < 0:
		return null
	return value / 2 if value % 2 == 0 else -(value + 1) / 2


# --- client: fill what was left out ---


# Fills positions of resting entities and missing player stats from earlier snapshots (cache:
# a Dictionary owned by the caller, empty at battle start). Resting entities the client has never
# seen a position for are left out of the view until their next refresh. Builds the id index.
static func resolve(view: Dictionary, cache: Dictionary) -> Dictionary:
	if not cache.has("t"):
		cache["t"] = -1
		cache["positions"] = {}
		cache["stats"] = {}
	var newest: bool = view.t >= cache.t
	_resolve_stats(view, cache.stats)
	_resolve_speeds(view, cache)
	var known: Dictionary = cache.positions
	var positions: PoolVector2Array = view.positions
	var ids: PoolIntArray = view.ids
	var unknown := []
	for i in ids.size():
		if get_flags(view.flags, i) & FLAG_REST:
			if known.has(ids[i]):
				positions[i] = known[ids[i]]
			else:
				unknown.append(i)
	view.positions = positions
	if not unknown.empty():
		_drop_entities(view, unknown)
	if newest:
		var updated := {}
		for i in view.ids.size():
			updated[view.ids[i]] = view.positions[i]
		cache.t = view.t
		cache.positions = updated
	view["index"] = _build_index(view.ids)
	return view


static func _resolve_stats(view: Dictionary, known: Dictionary) -> void:
	for i in view.players.size():
		var entry: Array = view.players[i]
		var complete := true
		for field in STAT_FIELDS:
			complete = complete and entry[field] != null
		if complete:
			if not known.has(i) or view.t >= known[i][0]:
				var stats := []
				for field in STAT_FIELDS:
					stats.append(entry[field])
				known[i] = [view.t, stats]
		elif known.has(i):
			for k in STAT_FIELDS.size():
				if entry[STAT_FIELDS[k]] == null:
					entry[STAT_FIELDS[k]] = known[i][1][k]


# Player speeds are sparse like the stats (sync/battle_scene.gd): the newest one sent stands.
static func _resolve_speeds(view: Dictionary, cache: Dictionary) -> void:
	if not cache.has("speeds"):
		cache["speeds"] = {}
	var known: Dictionary = cache.speeds
	for i in view.players.size():
		var entry: Array = view.players[i]
		if entry.size() <= PlayerField.SPEED:
			continue
		if entry[PlayerField.SPEED] != null:
			if not known.has(i) or view.t >= known[i][0]:
				known[i] = [view.t, entry[PlayerField.SPEED]]
		elif known.has(i):
			entry[PlayerField.SPEED] = known[i][1]


static func has_stats(entry: Array) -> bool:
	for field in STAT_FIELDS:
		if entry[field] == null:
			return false
	return true


static func _drop_entities(view: Dictionary, dropped: Array) -> void:
	var ids := PoolIntArray()
	var types := PoolIntArray()
	var positions := PoolVector2Array()
	var flags := []
	var poses := {}
	var skip := {}
	for i in dropped:
		skip[i] = true
	for i in view.ids.size():
		if skip.has(i):
			continue
		if view.poses.has(i):
			poses[ids.size()] = view.poses[i]
		ids.append(view.ids[i])
		types.append(view.types[i])
		positions.append(view.positions[i])
		flags.append(get_flags(view.flags, i))
	view.ids = ids
	view.types = types
	view.positions = positions
	view.flags = pack_flags(flags)
	view.poses = poses


static func _build_index(ids: PoolIntArray) -> Dictionary:
	var index := {}
	for i in ids.size():
		index[ids[i]] = i
	return index


# Index of the entity id inside a view, -1 if absent. O(1): the index is built once per view.
static func index_of(snapshot: Dictionary, id: int) -> int:
	if not snapshot.has("index"):
		snapshot["index"] = _build_index(snapshot.ids)
	return snapshot.index.get(id, -1)


# --- flags ---


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


# --- events ---


# At most `limit` events, the least valuable dropped first: duplicate sounds (same stream already
# in this snapshot), then damage numbers on enemies, sounds, damage on players and explosions;
# animations, bonus gold and the wave's end last (they are state). Kept events stay in order.
static func select_events(events: Array, limit: int) -> Array:
	if events.size() <= limit:
		return events
	var ranked := []
	var sounds := {}
	for i in events.size():
		var event: Array = events[i]
		var rank := 1
		match event[0]:
			EVENT_ANIM, EVENT_BONUS_GOLD, EVENT_WAVE_END:
				rank = 0
			EVENT_DAMAGE:
				rank = 1 if event[1] < 0 else 3
			EVENT_SOUND:
				rank = 4 if sounds.has(event[1]) else 2
				sounds[event[1]] = true
		ranked.append(rank * RANK_STRIDE + i)
	ranked.sort()
	var keep := {}
	for k in limit:
		keep[ranked[k] % RANK_STRIDE] = true
	var selected := []
	for i in events.size():
		if keep.has(i):
			selected.append(events[i])
	return selected


# State rather than a moment: still applied when it arrives late, never dropped first.
static func is_state_event(kind: int) -> bool:
	return kind == EVENT_ANIM or kind == EVENT_BONUS_GOLD or kind == EVENT_WAVE_END


# --- weapons ---


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
