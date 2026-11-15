extends Reference
# Entity parts that game physics code turns, moves, shows or hides relative to the entity. Puppets
# freeze physics, so the host sends these values (only for scenes that have such parts) and clients
# interpolate. Turrets (Structure/Turret) never rotate in this game version; the parts found are:
# - stampede dinos (GoTowardsBorderOppositeMovementBehavior): the whole unit turns along its run
# - Pivot children (predator, giant, jellyfish, unused corrupted tree): spinning rings of enemy
#   bullets, plus each EnemyProjectileRotating's distance from the center (it flies outwards first)
# - catling gun pet: both gun pivots aim at targets (rotation + scale.y mirror)
# - enemy lasers: aim (they don't move, so motion can't give it) and beam/aura visibility
# - brachiosaurus foot: visibility of its shadow / foot / release sprites, foot flip_h
# - bosses and elites (Boss): their health as a fraction, for the life bar over them (the
#   brachiosaurus' across the screen). Damage numbers are capped events; this is state.
#
# Optional group, sent after the base values only while active (the value count tells the client):
# - PIVOTS: boss pivots added at runtime (eel, tyrannosaurus, brachiosaurus instance `pivots_scene`
#   in a phase change); the client instances the same scene on its puppet
# - JUMP: JumpAttackBehavior's landing warning (position) and ground shadow (height, size) mid-jump
# - WARNING_LINE: WarningChargingAttackBehavior's red charge line (direction)
#
# The layout (which nodes, in which order) depends only on the scene, so it is derived from a
# pristine instance of it (not from a live, possibly damaged one) identically on host and client,
# and cached per scene path.

enum Kind { ROTATION, POSITION_X, SCALE_Y, POSITION_Y, SCALE, BITS, LINE_ANGLE, HEALTH }
enum Group { NONE, PIVOTS, JUMP, WARNING_LINE }

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)

# Largest in the game: eel/tyrannosaurus/brachiosaurus runtime pivots, 16 pivots + 16 bullets.
const MAX_VALUES: int = Snapshot.MAX_POSE_VALUES
const STAMPEDE_SHAKE_SEC := 1.2  # GoTowardsBorderOppositeMovementBehavior.get_movement
const HEALTH_STEPS := 1000  # a puppet's life bar is told "value of HEALTH_STEPS"
const HEALTH_META := "brotato_together_health"
const LASER_SPRITES := ["Sprite", "aura_0", "aura_1", "aura_2"]
const FOOT_BITS := [
	["Animation/Sprite", "visible"],
	["Sprite2", "visible"],
	["Sprite3", "visible"],
	["Sprite2", "flip_h"],
]

var _layouts := {}  # scene path -> layout Dictionary (see _derive)


func layout(entity: Node) -> Dictionary:
	return layout_of(entity.filename)


func layout_of(scene_path: String) -> Dictionary:
	if not _layouts.has(scene_path):
		_layouts[scene_path] = _derive(scene_path)
	return _layouts[scene_path]


# Host: current values, or empty when the scene has no parts or some base part is gone (the game
# frees a unit's pivots when it dies and does not restore them on pool reuse).
func capture(entity: Node) -> PoolRealArray:
	var lay := layout(entity)
	var values := []  # an Array: _read appends to it (pool arrays are passed by value)
	if not _read(entity, lay.parts, values):
		return PoolRealArray()
	if lay.group != Group.NONE and _group_active(entity, lay):
		var extra := []
		if _read(entity, lay.group_parts, extra):
			values += extra
	return PoolRealArray(values)


# Client: interpolate between two captures (b is the newer one; either may be empty). Called for
# every mirrored entity: no values for a scene with parts means the host's are gone.
func apply(entity: Node, a: PoolRealArray, b: PoolRealArray, t: float) -> void:
	var lay := layout(entity)
	var base: Array = lay.parts
	var group: Array = lay.group_parts
	if base.empty() and group.empty():
		return
	var active: bool = not group.empty() and b.size() == base.size() + group.size()
	if not active and b.size() != base.size():
		if b.empty():
			_show_pivots(entity, lay, false)
			_set_group(entity, lay, false)
		return  # otherwise host and client disagree about the scene: leave the puppet as it is
	if not base.empty():
		_restore_pivots(entity, lay)
		_show_pivots(entity, lay, true)
	_set_group(entity, lay, active)
	if a.size() != b.size():
		a = b
	_write(entity, base, a, b, t, 0)
	if active:
		_write(entity, group, a, b, t, base.size())
	if entity is CatlingGun:
		_order_catling_guns(entity)


# Client, right after a new entity got its first position: one-shot telegraphs the host shows
# from a spawn (stampede dinos shake the grass where they will burst out).
func spawned(entity: Node, main: Node) -> void:
	if layout(entity).stampede and main.has_method("_shake_zone_sprites"):
		main._shake_zone_sprites(entity.global_position, STAMPEDE_SHAKE_SEC)


# Client: the boss' own handler moves its bar (and hides it when this client's "life bars on
# bosses" option is off). Boss.init makes the brachiosaurus' bar across the screen; puppets never
# run it. Boss.die frees it.
static func _show_health(boss: Node, fraction: float) -> void:
	var value := int(round(clamp(fraction, 0.0, 1.0) * HEALTH_STEPS))
	if boss.has_meta(HEALTH_META) and boss.get_meta(HEALTH_META) == value:
		return
	boss.set_meta(HEALTH_META, value)
	if boss.use_fullscreen_lifebar and not is_instance_valid(boss._fullscreen_lifebar_canvas):
		boss.life_bar.hide()
		var canvas: Node = boss.FULLSCREEN_BOSS_LIFEBAR.instance()
		boss.get_tree().current_scene.add_child(canvas)
		canvas.get_node("BossName").text = boss.tr(boss.fullscreen_boss_name)
		boss._fullscreen_lifebar_canvas = canvas
		boss._fullscreen_lifebar = canvas.get_node("UIProgressBar")
	boss.on_health_updated(boss, value, HEALTH_STEPS)


# --- layout ---


static func _derive(scene_path: String) -> Dictionary:
	var lay := {
		"parts": [],  # [NodePath, Kind(, extra)] always sent
		"group": Group.NONE,
		"group_node": NodePath(),  # PIVOTS: runtime root name; JUMP: warning; LINE: behavior
		"group_parts": [],
		"shadow": NodePath(),  # JUMP: ground shadow
		"pivots_scene": null,
		"pivot_names": [],  # direct Pivot children (restored on reused puppets)
		"stampede": false,
	}
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		return lay
	var scene = load(scene_path)
	if not scene is PackedScene:
		return lay
	var pristine: Node = scene.instance()
	var parts: Array = lay.parts
	if pristine is Unit:
		var movement = pristine.get_node_or_null("MovementBehavior")
		if movement is GoTowardsBorderOppositeMovementBehavior:
			parts.append([NodePath("."), Kind.ROTATION])
			lay.stampede = true
	for child in pristine.get_children():
		if child is Pivot:
			lay.pivot_names.append(String(child.name))
			_add_pivot(pristine, child, parts)
	if pristine is CatlingGun:
		for gun_name in ["Gun_pivot_l", "Gun_pivot_r"]:
			var gun = _unique(pristine, gun_name)
			if gun != null:
				parts.append([pristine.get_path_to(gun), Kind.ROTATION])
				parts.append([pristine.get_path_to(gun), Kind.SCALE_Y])
	if pristine is EnemyLaser or pristine is EnemyLaserFollow:
		parts.append([NodePath("."), Kind.ROTATION])
		var bits := []
		for sprite_name in LASER_SPRITES:
			bits.append([NodePath(sprite_name), "visible"])
		parts.append([NodePath("."), Kind.BITS, bits])
	if pristine is BrachiosaurusFoot:
		var bits := []
		for bit in FOOT_BITS:
			bits.append([NodePath(bit[0]), bit[1]])
		parts.append([NodePath("."), Kind.BITS, bits])
	if pristine is Boss:
		parts.append([NodePath("."), Kind.HEALTH])
	_derive_group(pristine, lay)
	pristine.free()
	if parts.size() > MAX_VALUES:
		lay.parts = parts.slice(0, MAX_VALUES - 1)
	if lay.parts.size() + lay.group_parts.size() > MAX_VALUES:
		lay.group = Group.NONE
		lay.group_parts = []
	return lay


static func _derive_group(pristine: Node, lay: Dictionary) -> void:
	var pivots_scene = pristine.get("pivots_scene")
	if pivots_scene is PackedScene:
		var runtime: Node = pivots_scene.instance()
		var group_parts := []
		_add_pivots_below(runtime, runtime, String(runtime.name) + "/", group_parts)
		if not group_parts.empty():
			lay.group = Group.PIVOTS
			lay.group_node = NodePath(runtime.name)
			lay.group_parts = group_parts
			lay.pivots_scene = pivots_scene
		runtime.free()
		return
	for node in _descendants(pristine):
		if node is JumpAttackBehavior:
			var warning = _unique(pristine, "Land_shadow_warning")
			if not warning is Node2D:
				continue
			var path := pristine.get_path_to(warning)
			lay.group = Group.JUMP
			lay.group_node = path
			lay.group_parts = [[path, Kind.POSITION_X], [path, Kind.POSITION_Y]]
			var shadow = _unique(pristine, "Shadow")
			if shadow is Node2D:
				lay.shadow = pristine.get_path_to(shadow)
				lay.group_parts.append([lay.shadow, Kind.POSITION_Y])
				lay.group_parts.append([lay.shadow, Kind.SCALE])
			return
		if node is WarningChargingAttackBehavior:
			lay.group = Group.WARNING_LINE
			lay.group_node = pristine.get_path_to(node)
			lay.group_parts = [[lay.group_node, Kind.LINE_ANGLE]]
			return


static func _add_pivot(root: Node, pivot: Node, parts: Array, prefix := "") -> void:
	parts.append([NodePath(prefix + String(root.get_path_to(pivot))), Kind.ROTATION])
	for bullet in pivot.get_children():
		if bullet is EnemyProjectileRotating:
			parts.append([NodePath(prefix + String(root.get_path_to(bullet))), Kind.POSITION_X])


# Runtime pivot scenes nest them: Pivots/BulletsFar/Pivot*/EnemyProjectile.
static func _add_pivots_below(root: Node, node: Node, prefix: String, parts: Array) -> void:
	for child in node.get_children():
		if child is Pivot:
			_add_pivot(root, child, parts, prefix)
		else:
			_add_pivots_below(root, child, prefix, parts)


static func _descendants(node: Node) -> Array:
	var found := []
	for child in node.get_children():
		found.append(child)
		found += _descendants(child)
	return found


# Unique-name node of a scene (also outside the tree), by name as a fallback.
static func _unique(root: Node, node_name: String) -> Node:
	var node = root.get_node_or_null("%" + node_name)
	return node if node != null else root.find_node(node_name, true, false)


# --- host ---


static func _group_active(entity: Node, lay: Dictionary) -> bool:
	match lay.group:
		Group.PIVOTS:
			var pivots = entity.get("pivots")
			return (
				is_instance_valid(pivots)
				and pivots is Node
				and pivots.get_parent() == entity
				and NodePath(pivots.name) == lay.group_node
				and not pivots.is_queued_for_deletion()
			)
		Group.JUMP:
			var warning = entity.get_node_or_null(lay.group_node)
			return warning != null and warning.visible
		Group.WARNING_LINE:
			var line = _warning_line(entity, lay)
			return line != null and line.visible and line.get_parent() != null
	return false


static func _read(entity: Node, parts: Array, values: Array) -> bool:
	for part in parts:
		var node = entity.get_node_or_null(part[0])
		if node == null or node.is_queued_for_deletion():
			return false
		match part[1]:
			Kind.ROTATION:
				values.append(wrapf(node.rotation, -PI, PI))  # pivots spin without bound
			Kind.POSITION_X:
				values.append(node.position.x)
			Kind.POSITION_Y:
				values.append(node.position.y)
			Kind.SCALE_Y:
				values.append(node.scale.y)
			Kind.SCALE:
				values.append(node.scale.x)
			Kind.BITS:
				var bits := 0
				for k in part[2].size():
					var target = node.get_node_or_null(part[2][k][0])
					if target != null and target.get(part[2][k][1]):
						bits |= 1 << k
				values.append(bits)
			Kind.HEALTH:
				var most: float = max(1.0, node.max_stats.health)
				values.append(clamp(node.current_stats.health / most, 0.0, 1.0))
			Kind.LINE_ANGLE:
				var line = node.get("_warning_line")
				if not is_instance_valid(line) or line.points.size() < 1:
					return false
				values.append(line.points[0].angle())
	return true


# --- client ---


static func _write(
	entity: Node, parts: Array, a: PoolRealArray, b: PoolRealArray, t: float, offset: int
) -> void:
	for i in parts.size():
		var part: Array = parts[i]
		var node = entity.get_node_or_null(part[0])
		if node == null:
			continue
		var from: float = a[offset + i]
		var to: float = b[offset + i]
		match part[1]:
			Kind.ROTATION:
				node.rotation = lerp_angle(from, to, t)
			Kind.POSITION_X:
				node.position.x = lerp(from, to, t)
			Kind.POSITION_Y:
				node.position.y = lerp(from, to, t)
			Kind.SCALE_Y:
				node.scale.y = -1.0 if to < 0.0 else 1.0
			Kind.SCALE:
				var s: float = lerp(from, to, t)
				node.scale = Vector2(s, s)
			Kind.HEALTH:
				_show_health(node, to)
			Kind.BITS:
				var bits := int(to)
				for k in part[2].size():
					var target = node.get_node_or_null(part[2][k][0])
					var on := bool(bits & (1 << k))
					if target != null and bool(target.get(part[2][k][1])) != on:
						target.set(part[2][k][1], on)
			Kind.LINE_ANGLE:
				_draw_warning_line(node, lerp_angle(from, to, t))


# Same points as WarningChargingAttackBehavior.show_warning, from the direction's angle.
static func _draw_warning_line(behavior: Node, angle: float) -> void:
	var line = behavior.get("_warning_line")
	if not is_instance_valid(line):
		return
	var direction := Vector2.RIGHT.rotated(angle)
	var length: float = behavior.warning_line_length + behavior.warning_line_forward_offset
	line.points = PoolVector2Array([direction * 50.0, direction * length])


static func _warning_line(entity: Node, lay: Dictionary):
	var behavior = entity.get_node_or_null(lay.group_node)
	var line = behavior.get("_warning_line") if behavior != null else null
	return line if is_instance_valid(line) and line is Line2D else null


func _set_group(entity: Node, lay: Dictionary, active: bool) -> void:
	match lay.group:
		Group.PIVOTS:
			if active and entity.get_node_or_null(lay.group_node) == null:
				_add_runtime_pivots(entity, lay)
		Group.JUMP:
			var warning = entity.get_node_or_null(lay.group_node)
			if warning != null and warning.visible != active:
				warning.visible = active
				warning.show_behind_parent = true  # JumpAttackBehavior.init
			# Alive puppets have a shadow; the client's own die() hid it before pool reuse.
			var shadow = null if lay.shadow.is_empty() else entity.get_node_or_null(lay.shadow)
			if shadow != null and not shadow.visible:
				shadow.visible = true
				shadow.show_behind_parent = true
		Group.WARNING_LINE:
			var line = _warning_line(entity, lay)
			if line == null:
				return
			if line.get_parent() == null:  # the behavior's init() parents it; puppets skip init
				entity.add_child(line)
			if line.visible != active:
				line.visible = active


# What Eel/Tyranosaurus/Brachiosaurus.on_state_changed do, minus the gameplay: same scene, same
# node name, frozen. The boss's die() frees its bullets like on the host.
static func _add_runtime_pivots(entity: Node, lay: Dictionary) -> void:
	var pivots: Node = lay.pivots_scene.instance()
	if NodePath(pivots.name) != lay.group_node:
		pivots.free()
		return
	entity.add_child(pivots)
	PuppetEntity.puppetize(pivots)
	if "pivots" in entity:
		entity.pivots = pivots


# Pooled puppets lose their Pivot children in die() (the client runs it for the death animation);
# a host entity that has them (all fresh ones) gets them back from a pristine instance.
static func _restore_pivots(entity: Node, lay: Dictionary) -> void:
	var missing := []
	for pivot_name in lay.pivot_names:
		var node = entity.get_node_or_null(pivot_name)
		if node == null or node.is_queued_for_deletion():
			missing.append(pivot_name)
	if missing.empty():
		return
	var pristine: Node = load(entity.filename).instance()
	for pivot_name in missing:
		var pivot = pristine.get_node_or_null(pivot_name)
		if pivot == null:
			continue
		var old = entity.get_node_or_null(pivot_name)
		if old != null:
			old.name = "%s_freed" % pivot_name  # keep the path for the new one
		var index: int = pivot.get_index()
		pristine.remove_child(pivot)
		entity.add_child(pivot)
		entity.move_child(pivot, min(index, entity.get_child_count() - 1))
		var on_died := "_on_Enemy_died"  # Pivot frees itself with its unit
		if pivot.has_method(on_died) and not entity.is_connected("died", pivot, on_died):
			entity.connect("died", pivot, on_died)
		PuppetEntity.puppetize(pivot)
	pristine.free()


static func _show_pivots(entity: Node, lay: Dictionary, shown: bool) -> void:
	for pivot_name in lay.pivot_names:
		var pivot = entity.get_node_or_null(pivot_name)
		if pivot != null and pivot.visible != shown:
			pivot.visible = shown


# Draw order of CatlingGun._orient_gun: a gun pointing to the far side goes behind the body.
static func _order_catling_guns(catling: Node) -> void:
	for gun in [catling._gun_pivot_l, catling._gun_pivot_r]:
		var left: bool = gun == catling._gun_pivot_l
		var in_front: bool = (left and gun.scale.y > 0) or (not left and gun.scale.y < 0)
		var index := 4 if in_front else 1
		if gun.get_index() != min(index, gun.get_parent().get_child_count() - 1):
			gun.get_parent().move_child(gun, index)
