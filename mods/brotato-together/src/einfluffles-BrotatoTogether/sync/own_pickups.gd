extends Reference
# Client: predicts the own player's pickups of consumables (fruit, crates) and materials (gold)
# with the game's own rules on its predicted position. The host decides: an item it still has
# where it stood CONFIRM_INPUTS inputs after the own player reached it comes back there and is not
# predicted again.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const PF := Snapshot.PlayerField
const CONFIRM_INPUTS := 10  # the host's touch or attraction lands a tick or two after the input
const MAX_WAIT_SNAPSHOTS := 60  # 2 s of snapshots without the acks, or of the host's flight
const STILL_PX2 := 1.0  # shown where the newest snapshot has it (positions in 0.5 px)
const SWEEP_STEP_PX := 8.0  # a frame's way is checked in steps of this (half a crate's box)
const SWEEP_SLACK := 1.5  # a way longer than its inputs' steps times this is a correction


var gold_sounds := [[], []]  # main.gold_pickup_sounds, main.gold_alt_pickup_sounds
var _tracked := {}  # net id -> consumable or gold puppet
var _flights := {}  # net id -> [speed, where it stood, where it is, own input it started with]
var _held := {}  # net id -> Held
var _refused := {}  # net id -> true: the host didn't take it, it is the host's alone from now on
var _last_at = null  # last frame's predicted position, null while nothing is predicted
var _last_seq := 0  # the own input it had


class Held:
	extends Reference
	var seq := 0  # the own input it was reached with (touched, or attracted)
	var stood := Vector2.ZERO
	var sounds := []  # resource paths of its pickup sounds
	var heals := false
	var gone_t := -1  # host time of the first snapshot without it
	var waited := 0  # newest snapshots that still had it


static func find_data(my_id: String):
	for data in ItemService.consumables:
		if data.my_id == my_id:
			return data
	# DLC drops (poisoned / meca / mutant / mutation fruit, meca parts) aren't in that list (not
	# even for owners): they are DLCData properties, which every copy of the game has.
	for update in ItemService.update_data_list:
		var dlc_data = update.dlc_data if update != null else null
		if dlc_data == null:
			continue
		for property in dlc_data.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				var value = dlc_data.get(property.name)
				if value is ConsumableData and value.my_id == my_id:
					return value
	return null


# A circle (the player's areas) against an item's box. Consumables never turn; gold lies turned at
# random, which is not mirrored: its box is taken unturned (a corner reaches up to 7 px further).
static func overlaps(center: Vector2, radius: float, item_at: Vector2, extents: Vector2) -> bool:
	var outside := (center - item_at).abs() - extents
	return Vector2(max(outside.x, 0.0), max(outside.y, 0.0)).length_squared() < radius * radius


# [center offset from the player, radius] of one of its item areas.
static func area_circle(player: Node2D, area: Area2D) -> Array:
	var shape_node: CollisionShape2D = area.get_node("CollisionShape2D")
	var radius: float = shape_node.shape.radius * abs(shape_node.global_scale.x)
	return [shape_node.global_position - player.global_position, radius]


static func item_extents(item: Node2D) -> Vector2:
	var shape_node: CollisionShape2D = item.get_node("CollisionShape2D")
	return shape_node.shape.extents * shape_node.global_scale.abs()


# The positions a frame's touches are checked at: the way from the last frame's one in short
# steps (the host checks every tick, a slow frame covers several), else just this one.
static func way(from, to: Vector2, longest: float) -> PoolVector2Array:
	var points := PoolVector2Array()
	if from != null and from.distance_to(to) <= longest:
		var steps := int(ceil(from.distance_to(to) / SWEEP_STEP_PX))
		for k in range(1, steps):
			points.append(from.linear_interpolate(to, float(k) / steps))
	points.append(to)
	return points


func set_gold_sounds(main: Node) -> void:
	for k in 2:
		var sounds = main.get(["gold_pickup_sounds", "gold_alt_pickup_sounds"][k])
		gold_sounds[k] = sounds if sounds is Array else []


func spawned(id: int, node: Node) -> void:
	if node is Consumable or node is Gold:
		_tracked[id] = node


# Taken here and still in the host's snapshots: the mirror must not respawn it.
func holds(id: int) -> bool:
	return _held.has(id)


# own: the own player while its prediction runs (else null); at: its predicted position without
# the correction blend; seq: its newest input. Returns the ids taken now.
func update(
	entities: Dictionary,
	own,
	at: Vector2,
	seq: int,
	newest: Dictionary,
	to: Dictionary,
	delta: float
) -> Array:
	for id in _held.keys():
		if _held[id].gone_t >= 0 and to.t >= _held[id].gone_t:
			_held.erase(id)
	var from = _last_at
	var steps: int = max(seq - _last_seq, 1)
	_last_seq = seq
	_last_at = at if own != null else null
	var taken := []
	if _tracked.empty():
		return taken
	var reach := []
	var attract := []
	var points := PoolVector2Array()
	if own != null:
		reach = area_circle(own, own._item_pickup_area)
		attract = area_circle(own, own._item_attract_area)
		var step: float = own.get_move_speed() / float(Engine.iterations_per_second)
		points = way(from, at, steps * step * SWEEP_SLACK)
	for id in _tracked.keys():
		var node = _tracked[id]
		if not is_instance_valid(node) or entities.get(id) != node:
			_tracked.erase(id)
			_flights.erase(id)
			_refused.erase(id)
		elif own == null:
			_land(id, node)
		elif _flights.has(id):
			var flight: Array = _flights[id]
			if _fly(flight, node, own, reach, delta):
				_take(id, node, flight[3], flight[1], newest, taken)
		elif _standing(id, node, newest, own):
			var extents := item_extents(node)
			var position: Vector2 = node.global_position
			if _touches(points, reach, position, extents):
				_take(id, node, seq, position, newest, taken)
			elif _attracts(node, own) and overlaps(at + attract[0], attract[1], position, extents):
				_flights[id] = [Item.INITIAL_ATTRACT_SPEED, position, position, seq]
	return taken


func confirm(snapshot: Dictionary, you: int, types: Dictionary) -> void:
	if _held.empty() or you < 0 or you >= snapshot.players.size():
		return
	var ack: int = snapshot.players[you][PF.INPUT_ACK]
	for id in _held.keys():
		var held: Held = _held[id]
		if held.gone_t >= 0:
			continue
		var j: int = Snapshot.index_of(snapshot, id)
		if j < 0:
			held.gone_t = snapshot.t
			_drop_sound(snapshot.events, held.sounds, types)
			continue
		held.waited += 1
		# Moved on the host: on its way to a player (likely this one), wait for it to land.
		var still: bool = snapshot.positions[j].distance_squared_to(held.stood) <= STILL_PX2
		if (still and ack >= held.seq + CONFIRM_INPUTS) or held.waited > MAX_WAIT_SNAPSHOTS:
			_held.erase(id)  # the mirror shows it again where the host has it
			_refused[id] = true


func _standing(id: int, node: Node2D, newest: Dictionary, own) -> bool:
	if not node.visible or _refused.has(id):
		return false
	var j: int = Snapshot.index_of(newest, id)
	if j < 0 or newest.positions[j].distance_squared_to(node.global_position) > STILL_PX2:
		return false
	if node is Gold:
		return true
	var data = node.consumable_data
	return data != null and RunData.can_pick_up_consumable(data, own.player_index)


static func _touches(points: PoolVector2Array, reach: Array, at: Vector2, extents: Vector2) -> bool:
	for point in points:
		if overlaps(point + reach[0], reach[1], at, extents):
			return true
	return false


# Player._on_ItemAttractArea_area_entered: gold always, healing ones while hurt. Not while a heal
# taken here is unconfirmed: the health shown doesn't have it yet.
func _attracts(node: Node, own) -> bool:
	if node is Gold:
		return true
	if own.current_stats.health >= own.max_stats.health or not node.has_healing_effect():
		return false
	for held in _held.values():
		if held.heals and held.gone_t < 0:
			return false
	return true


# Item._physics_process: towards the player, faster every tick; true once it touches. Its own
# position: the mirror puts the puppet back where the host has it when that changes.
static func _fly(flight: Array, node: Node2D, own: Node2D, reach: Array, delta: float) -> bool:
	flight[2] = flight[2].move_toward(own.global_position, delta * flight[0])
	flight[0] += Item.ATTRACT_ACCELERATION * delta * Engine.iterations_per_second
	node.global_position = flight[2]
	return overlaps(own.global_position + reach[0], reach[1], flight[2], item_extents(node))


# No prediction now (pause, stall, wave end, dead): a flight goes back where it stood.
func _land(id: int, node: Node2D) -> void:
	if _flights.has(id):
		node.global_position = _flights[id][1]
		_flights.erase(id)


# Gone from the newest snapshot already (a flight the host's ended first): its sound is queued.
# Gold sounds like main.on_gold_picked_up with this player's setting.
func _take(
	id: int, node: Node, seq: int, stood: Vector2, newest: Dictionary, taken: Array
) -> void:
	var held := Held.new()
	held.seq = seq
	held.stood = stood
	var play := [[], 0.0, 0.0]  # sounds, volume, pitch
	if node is Gold:
		var alt: bool = ProgressData.settings.get("alt_gold_sounds", false)
		play = [gold_sounds[1] if alt else gold_sounds[0], -5.0 if alt else 0.0, 0.2]
		held.sounds = _paths(gold_sounds[0] + gold_sounds[1])  # the host's setting picks
	else:
		play[0] = node.consumable_data.pickup_sounds
		held.sounds = _paths(play[0])
		held.heals = node.has_healing_effect()
	_held[id] = held
	_tracked.erase(id)
	_flights.erase(id)
	taken.append(id)
	if Snapshot.index_of(newest, id) < 0:
		held.gone_t = newest.t
	elif not play[0].empty():
		SoundRelay.replay(Utils.get_rand_element(play[0]), null, play[1], play[2])


static func _paths(sounds: Array) -> Array:
	var paths := []
	for sound in sounds:
		if sound is Resource:
			paths.append(sound.resource_path)
	return paths


# Removes the host's pickup sound event (Consumable.pickup, main.on_gold_picked_up): the sound was
# played here at the take.
static func _drop_sound(events: Array, paths: Array, types: Dictionary) -> void:
	for k in events.size():
		var event = events[k]
		if typeof(event) != TYPE_ARRAY or event.size() < 2 or typeof(event[0]) != TYPE_INT:
			continue
		if event[0] != Snapshot.EVENT_SOUND:
			continue
		var sound = types.get(event[1])
		if sound is AudioStream and sound.resource_path in paths:
			events.remove(k)
			return
