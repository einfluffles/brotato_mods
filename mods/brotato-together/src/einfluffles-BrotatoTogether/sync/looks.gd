extends Reference
# Lasting looks of mirrored entities: states the game shows for seconds or for the rest of an
# entity's life, which puppets never get because the game logic behind them only runs on the
# host. One byte per entity in the snapshot's looks section; only visuals are read and written.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const BURNING := 1  # Unit.apply_burning starts the unit's BurningParticles
const BURN_RED := 2  # the gradient BurningParticles._update_color picked; neither: the scene's own
const BURN_BLUE := 4
const CHARMED := 8  # CharmEnemyEffectBehavior.charm; on an enemy projectile the hue shift material
const CURSED := 16  # CurseEnemyEffectBehavior.init, cursed structures and pets
const BOOSTED := 32  # Entity.boost with show_outline (buffers, boosted turrets)
const MECA := 64  # Meca / MutantEnemyEffectBehavior.init: outline and evolution texture
const MUTANT := 128
const ALL := Snapshot.LOOK_BITS
const BURN_BITS := BURNING | BURN_RED | BURN_BLUE
const EVOLUTION_BITS := MECA | MUTANT
const OUTLINE_BITS := CHARMED | CURSED | BOOSTED | EVOLUTION_BITS
const REPEAT := 4  # snapshots a look is sent for after it changes (also when it becomes plain)
const REFRESH := 10  # snapshots between resends while not plain, staggered by net id
const EXPIRE_SNAPSHOTS := 45  # 1.5 s at 30 Hz: four refreshes in a row lost
const CHARM_ALPHA := 0.4  # CharmEnemyEffectBehavior.charm's add_outline arguments
const CHARM_DESATURATION := 0.75
const HUE_SHIFT_SHADER := "res://resources/shaders/hue_shift.gdshader"
const HUE_SHIFT_MATERIAL := "res://resources/shaders/hue_shift_shadermat.tres"
const CURSE_BEHAVIOR := "res://effect_behaviors/enemies/curse_enemy_effect_behavior.tscn"
const CURSE_NODE := "BrotatoTogetherCurse"
const LOOK_META := "brotato_together_look"
const RAMP_META := "brotato_together_ramp"
const MATERIAL_META := "brotato_together_material"
const TEXTURE_META := "brotato_together_texture"

# Host: net id -> [look, snapshot count of its last change]; only looks that are not plain or
# changed within REPEAT snapshots.
var _last := {}
var _next := {}
var _sent := {}  # entity index -> look, for the snapshot being built
var _hue_shader: Shader = null
# Client: net id -> puppet that shows a look; the charm material of enemy projectiles
var _looked := {}
var _charm_material: ShaderMaterial = null


static func can_have_look(node: Node) -> bool:
	return node is Entity or node is EnemyProjectile


# entity / unit: what the host's record already knows, so the many plain entities of a late wave
# cost two property reads and no class checks.
func capture(
	node: Node, net_id: int, index: int, snapshot_count: int, entity: bool, unit: bool
) -> void:
	var look := 0
	if not entity:
		look = look_of(node)  # an enemy shot
	elif not node._outline_colors.empty() or (unit and node._is_burning):
		look = look_of(node)
	_capture_look(look, net_id, index, snapshot_count)


func _capture_look(look: int, net_id: int, index: int, snapshot_count: int) -> void:
	var last = _last.get(net_id)
	var changed_at := snapshot_count
	if last == null:
		if look == 0:
			return  # plain since it appeared, or for longer than REPEAT snapshots
	elif last[0] == look:
		changed_at = last[1]
	var recent := snapshot_count - changed_at < REPEAT
	if look != 0 or recent:
		_next[net_id] = [look, changed_at]
	if recent or (look != 0 and (snapshot_count + net_id) % REFRESH == 0):
		_sent[index] = look


func end_snapshot() -> Dictionary:
	var sent := _sent
	_last = _next
	_next = {}
	_sent = {}
	return sent


func look_of(node: Node) -> int:
	var look := 0
	if node is Projectile:
		var sprite = node.get("_sprite")
		if sprite != null and _is_charm_material(sprite.material):
			look |= CHARMED
		return look
	for color in node._outline_colors:
		if color == Utils.CHARM_COLOR:
			look |= CHARMED
		elif color == Utils.CURSE_COLOR:
			look |= CURSED
		elif color == Utils.BOOST_COLOR:
			look |= BOOSTED
		elif color == Utils.MECA_COLOR:
			look |= MECA
		elif color == Utils.MUTANT_COLOR:
			look |= MUTANT
	if node is Unit and node._is_burning:
		look |= BURNING
		var particles = node._burning_particles
		if particles.color_ramp == particles.red_gradient:
			look |= BURN_RED
		elif particles.color_ramp == particles.blue_gradient:
			look |= BURN_BLUE
	return look


# The game uses the hue shift shader for charmed shots only (CharmEnemyEffectBehavior.charm, a
# charmed BloatedPufferfish's death shots). Its hue is not read: get_shader_param asks the
# VisualServer, a per-shot call that the headless one answers with null.
func _is_charm_material(material) -> bool:
	if not material is ShaderMaterial:
		return false
	if _hue_shader == null:
		_hue_shader = load(HUE_SHIFT_SHADER)
	return material.shader == _hue_shader


# Sets view.looks_by_id {net id: look}. Must run before Snapshot.resolve, which may drop
# entities and so change the indices. The caller owns cache, empty at battle start.
static func resolve(view: Dictionary, cache: Dictionary) -> void:
	if not cache.has("looks"):
		cache["looks"] = {}  # net id -> [look, host t, received count when confirmed]
		cache["looks_t"] = -1
		cache["looks_count"] = 0
	var known: Dictionary = cache.looks
	if view.t >= cache.looks_t:  # the newest so far: one more snapshot towards expiry
		cache.looks_t = view.t
		cache.looks_count += 1
	var count: int = cache.looks_count
	var ids: PoolIntArray = view.ids
	var looks: Dictionary = view.get("looks", {})
	for index in looks:
		var id: int = ids[index]
		var entry = known.get(id)
		if entry == null or view.t >= entry[1]:
			known[id] = [looks[index], view.t, count]
	var current := {}
	for id in known.keys():
		var entry: Array = known[id]
		if count - entry[2] > EXPIRE_SNAPSHOTS:
			known.erase(id)
		elif entry[0] != 0:
			current[id] = entry[0]
	view["looks_by_id"] = current


# looks: {net id: look}. Puppets that had a look and are no longer listed (plain again,
# despawned, reused for another id) lose it.
func apply(entities: Dictionary, looks: Dictionary) -> void:
	for id in _looked.keys():
		var node = _looked[id]
		if not looks.has(id) or entities.get(id) != node:
			_looked.erase(id)
			if is_instance_valid(node):
				set_look(node, 0)
	for id in looks:
		var node = entities.get(id)
		if node != null and is_instance_valid(node):
			set_look(node, looks[id])
			_looked[id] = node


func set_look(node: Node, look: int) -> void:
	var old: int = node.get_meta(LOOK_META) if node.has_meta(LOOK_META) else 0
	if old == look:
		return
	node.set_meta(LOOK_META, look)
	var changed := old ^ look
	if node is Projectile:
		if changed & CHARMED:
			_set_projectile_charm(node, look & CHARMED != 0)
		return
	if not node is Entity:
		return
	if changed & EVOLUTION_BITS:
		_set_evolution(node, look)  # first: the outline shader reads the texture's size
	if changed & OUTLINE_BITS:
		_set_outlines(node, look)
	if changed & CHARMED and look & CHARMED:
		node.sprite.self_modulate = Color.white  # never put back by the game either
	if changed & BURN_BITS and node is Unit:
		_set_burning(node, look)
	if changed & CURSED:
		_set_curse_particles(node, look & CURSED != 0)


# The look's outlines, through the entity's own Entity._set_outlines; other outlines a puppet
# may carry stay. Unit._set_outlines keeps a running hit flash on top.
static func _set_outlines(entity: Node, look: int) -> void:
	var colors := []
	var look_colors := [
		Utils.CHARM_COLOR, Utils.CURSE_COLOR, Utils.BOOST_COLOR, Utils.MECA_COLOR, Utils.MUTANT_COLOR
	]
	for color in entity._outline_colors:
		if not color in look_colors:
			colors.append(color)
	if look & MECA:
		colors.append(Utils.MECA_COLOR)
	if look & MUTANT:
		colors.append(Utils.MUTANT_COLOR)
	if look & CURSED:
		colors.append(Utils.CURSE_COLOR)
	if look & BOOSTED:
		colors.append(Utils.BOOST_COLOR)
	if look & CHARMED:
		colors.append(Utils.CHARM_COLOR)
	var charmed := look & CHARMED != 0
	entity._outline_colors = colors
	entity._current_material_alpha = CHARM_ALPHA if charmed else 1.0
	entity._current_material_desaturation = CHARM_DESATURATION if charmed else 0.0
	entity._set_outlines()


# The evolved sprite, like Meca / MutantEnemyEffectBehavior.init; the scene's own comes back when
# the look ends (a pooled puppet is reused for plain enemies). Enemies without such a texture
# (evolved elites are scenes of their own) only get the outline.
static func _set_evolution(node: Node, look: int) -> void:
	if not node is Enemy:
		return
	var sprite = node.get("_sprite_foot") if "_sprite_foot" in node else node.sprite
	if sprite == null:
		return
	var texture = null
	if look & MECA:
		texture = node.evolution_meca
	elif look & MUTANT:
		texture = node.evolution_mutant
	if texture != null:
		if not node.has_meta(TEXTURE_META):
			node.set_meta(TEXTURE_META, [sprite.texture])
		sprite.texture = texture
	elif node.has_meta(TEXTURE_META):
		sprite.texture = node.get_meta(TEXTURE_META)[0]
		node.remove_meta(TEXTURE_META)


# The unit's own BurningParticles, started and stopped like Unit.apply_burning / stop_burning
# do. Without burning_data (and with the puppet's areas off) they never spread a burn.
static func _set_burning(unit: Node, look: int) -> void:
	var particles = unit.get("_burning_particles")
	if particles == null:
		return
	if not look & BURNING:
		if particles.emitting:
			particles.stop_emitting()
		return
	var secondary = particles.secondary_particles
	if not particles.has_meta(RAMP_META):
		particles.set_meta(RAMP_META, [particles.color_ramp, secondary.color_ramp])
	var ramps: Array = particles.get_meta(RAMP_META)
	if look & BURN_BLUE:
		ramps = [particles.blue_gradient, particles.blue_gradient_secondary]
	elif look & BURN_RED:
		ramps = [particles.red_gradient, particles.red_gradient_secondary]
	particles.color_ramp = ramps[0]
	secondary.color_ramp = ramps[1]
	particles.start_emitting()


# The CurseParticles inside CurseEnemyEffectBehavior's scene: the puppet gets that scene without
# its script, next to its effect behaviors, not among them (Unit calls into every one of those).
static func _set_curse_particles(node: Node, cursed: bool) -> void:
	if node is Pet:
		var instance = node.curse_particle_instance
		if cursed and not is_instance_valid(instance) and node.curse_particles != null:
			node.curse_particle_instance = node.curse_particles.instance()
			node.add_child(node.curse_particle_instance)
		elif not cursed and is_instance_valid(instance):
			instance.queue_free()
			node.curse_particle_instance = null
		return
	if not node is Enemy:
		return
	var existing := node.get_node_or_null(CURSE_NODE)
	if cursed and existing == null:
		var curse: Node = load(CURSE_BEHAVIOR).instance()
		curse.set_script(null)
		curse.name = CURSE_NODE
		node.add_child(curse)
	elif not cursed and existing != null:
		node.remove_child(existing)
		existing.queue_free()


# A charmed enemy's shots: the material CharmEnemyEffectBehavior.charm hands its shooting
# behaviors (hue shifted to CHARM_COLOR). The puppet's own material comes back when it ends.
func _set_projectile_charm(projectile: Node, charmed: bool) -> void:
	var sprite = projectile.get("_sprite")
	if sprite == null:
		return
	if charmed:
		if _charm_material == null:
			_charm_material = load(HUE_SHIFT_MATERIAL).duplicate()
			_charm_material.set_shader_param("hue", Utils.CHARM_COLOR.h)
		projectile.set_meta(MATERIAL_META, [sprite.material])  # wrapped: it may be null
		sprite.material = _charm_material
	elif projectile.has_meta(MATERIAL_META):
		sprite.material = projectile.get_meta(MATERIAL_META)[0]
		projectile.remove_meta(MATERIAL_META)
