extends Reference
# Acid, petrol and fire puddles (GPESpawner, protocol 12): enemies and projectiles of evolved
# enemies leave acid / petrol, molotovs, explosions, fire trails and burning deaths leave fire.
# They are mirrored like gold: static nodes, so after their first snapshots only their net id and
# a FLAG_REST nibble travel. What they hurt, slow or set on fire is decided by the host's own
# puddles; a puppet has no collision layers and no running timers.
#
# Their look is chosen once in init(): one of the scene's puddle_sprites and the scale the spawn
# tween grows to (GPESpawner's size, for fire also the owner's fire_puddle_size stat). Both
# travel in the type key, "<scene>#puddle:<sprite>:<scale x>:<scale y>" (scale in 1/100), which
# is defined once per battle and shared by every puddle from the same source. The sprite's random
# rotation is picked by the client itself (it would cost a type per puddle or bytes per snapshot).
# A puddle leaves the snapshots when it starts to fade (despawn(): timeout or eviction), and the
# client plays the same fade before pooling its puppet.

const TAG := "puddle"
const SCALE_STEPS := 100.0
const MAX_SCALE := 10000  # 100x, in 1/100: far beyond any GPESpawner size
const MAX_SPRITES := 64


static func is_puddle(node: Node) -> bool:
	return node is AcidPuddle or node is PetrolPuddle or node is FirePuddle


# --- host ---


# Puddles that are on the ground and not fading. Pooled ones are out of the tree.
static func tracked(main: Node) -> Array:
	var nodes := []
	for container_name in ["_gpe_container", "_fire_puddles_container"]:
		var container = main.get(container_name)
		if not is_instance_valid(container):
			continue
		for child in container.get_children():  # also holes, dig sites, poacher zones
			if is_puddle(child) and child.is_active():
				nodes.append(child)
	return nodes


static func tag(puddle: Node) -> String:
	var sprite_index := int(max(0, puddle.puddle_sprites.find(puddle.sprite.texture)))
	var size: Vector2 = puddle._target_scale
	return "%s:%d:%d:%d" % [
		TAG, sprite_index, int(round(size.x * SCALE_STEPS)), int(round(size.y * SCALE_STEPS))
	]


# --- client ---


static func is_tag(tag: String) -> bool:
	return tag.begins_with(TAG + ":")


# [sprite index, target scale], or null when the tag is malformed (the puppet then shows its
# scene's own sprite at its scene's scale).
static func parse_tag(tag: String):
	var parts := tag.split(":")
	if parts.size() != 4 or parts[0] != TAG:
		return null
	var values := []
	for k in range(1, 4):
		if not parts[k].is_valid_integer():
			return null
		values.append(int(parts[k]))
	if values[0] < 0 or values[0] >= MAX_SPRITES:
		return null
	for k in [1, 2]:
		if values[k] < 1 or values[k] > MAX_SCALE:
			return null
	return [values[0], Vector2(values[1], values[2]) / SCALE_STEPS]


static func container(main: Node, puddle: Node) -> Node:
	return main.get("_fire_puddles_container" if puddle is FirePuddle else "_gpe_container")


# A fresh or pooled puppet: the host's sprite and size, the game's own spawn tween. Its lifetime
# timer never starts: the host's puddle decides when it goes.
static func start(puddle: Node, spec) -> void:
	puddle._is_dying = false
	puddle.set_deferred("monitoring", false)
	var size: Vector2 = puddle._base_scale
	if spec is Array:
		var sprite_index: int = spec[0]
		if sprite_index < puddle.puddle_sprites.size():
			puddle.sprite.texture = puddle.puddle_sprites[sprite_index]
		if sprite_index < puddle.puddle_sprites_outline.size():
			puddle.sprite_outline.texture = puddle.puddle_sprites_outline[sprite_index]
		size = spec[1]
	puddle.sprite.rotation_degrees = randf() * 360.0
	puddle._target_scale = size
	puddle._play_spawn_tween()


# The game's despawn() fade (scale down, fade out); returns how long it takes. Its despawn
# timer is paused on a puppet: the caller pools the puppet afterwards.
static func fade_out(puddle: Node) -> float:
	puddle.despawn()
	return puddle.despawn_duration
