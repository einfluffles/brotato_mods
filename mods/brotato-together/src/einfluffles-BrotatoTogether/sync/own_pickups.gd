extends Reference
# Client: predicts the own player's pickups of consumables (fruit, crates) with the game's own
# rules on its predicted position. The host decides: a pickup it has not made CONFIRM_INPUTS
# inputs later comes back where the host has it and is not predicted again.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const SoundRelay := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/sound_relay.gd"
)
const PF := Snapshot.PlayerField
const CONFIRM_INPUTS := 10  # the host's pickup lands a tick or two after the move's input
const MAX_WAIT_SNAPSHOTS := 60  # 2 s of snapshots without the acks
const STILL_PX2 := 1.0  # shown where the newest snapshot has it (positions in 0.5 px)


var _tracked := {}  # net id -> consumable puppet
var _flights := {}  # net id -> [speed, where it stood, where it is]
var _held := {}  # net id -> Held
var _refused := {}  # net id -> true: the host didn't take it, it is the host's alone from now on


class Held:
	extends Reference
	var seq := 0  # the own input it was taken with
	var data = null  # ConsumableData
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


# A circle (the player's areas) against an item's box (consumables never turn).
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


func spawned(id: int, node: Node) -> void:
	if node is Consumable:
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
	var taken := []
	if _tracked.empty():
		return taken
	var reach := []
	var attract := []
	if own != null:
		reach = area_circle(own, own._item_pickup_area)
		attract = area_circle(own, own._item_attract_area)
	for id in _tracked.keys():
		var node = _tracked[id]
		if not is_instance_valid(node) or entities.get(id) != node:
			_tracked.erase(id)
			_flights.erase(id)
			_refused.erase(id)
		elif own == null:
			_land(id, node)
		elif _flights.has(id):
			if _fly(_flights[id], node, own, reach, delta):
				_take(id, node, seq, newest, taken)
		elif _standing(id, node, newest, own):
			var extents := item_extents(node)
			var position: Vector2 = node.global_position
			if overlaps(at + reach[0], reach[1], position, extents):
				_take(id, node, seq, newest, taken)
			elif _attracts(node, own) and overlaps(at + attract[0], attract[1], position, extents):
				_flights[id] = [Item.INITIAL_ATTRACT_SPEED, position, position]
	return taken


func confirm(snapshot: Dictionary, you: int, types: Dictionary) -> void:
	if _held.empty() or you < 0 or you >= snapshot.players.size():
		return
	var ack: int = snapshot.players[you][PF.INPUT_ACK]
	for id in _held.keys():
		var held: Held = _held[id]
		if held.gone_t >= 0:
			continue
		if Snapshot.index_of(snapshot, id) < 0:
			held.gone_t = snapshot.t
			_drop_sound(snapshot.events, held.data, types)
			continue
		held.waited += 1
		if ack >= held.seq + CONFIRM_INPUTS or held.waited > MAX_WAIT_SNAPSHOTS:
			_held.erase(id)  # the mirror shows it again where the host has it
			_refused[id] = true


func _standing(id: int, node: Node2D, newest: Dictionary, own) -> bool:
	if not node.visible or node.consumable_data == null or _refused.has(id):
		return false
	var j: int = Snapshot.index_of(newest, id)
	if j < 0 or newest.positions[j].distance_squared_to(node.global_position) > STILL_PX2:
		return false
	return RunData.can_pick_up_consumable(node.consumable_data, own.player_index)


# Player._on_ItemAttractArea_area_entered: healing ones while hurt. Not while a heal taken here
# is unconfirmed: the health shown doesn't have it yet.
func _attracts(node: Node, own) -> bool:
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
func _take(id: int, node: Node, seq: int, newest: Dictionary, taken: Array) -> void:
	var held := Held.new()
	held.seq = seq
	held.data = node.consumable_data
	held.heals = node.has_healing_effect()
	_held[id] = held
	_tracked.erase(id)
	_flights.erase(id)
	taken.append(id)
	if Snapshot.index_of(newest, id) < 0:
		held.gone_t = newest.t
	elif not held.data.pickup_sounds.empty():
		SoundRelay.replay(Utils.get_rand_element(held.data.pickup_sounds), null, 0.0, 0.0)


# Removes the host's Consumable.pickup sound event: the sound was played here at the take.
static func _drop_sound(events: Array, data, types: Dictionary) -> void:
	var paths := []
	for sound in data.pickup_sounds:
		paths.append(sound.resource_path)
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
