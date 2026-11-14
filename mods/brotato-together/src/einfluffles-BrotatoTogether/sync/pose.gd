extends Reference
# Entity parts that game physics code turns or moves relative to the entity. Puppets freeze physics,
# so the host sends these values (only for scenes that have such parts) and clients interpolate.
# Turrets (Structure/Turret) never rotate in this game version; the parts found in the game are:
# - stampede dinos (GoTowardsBorderOppositeMovementBehavior): the whole unit turns along its run
# - Pivot children (predator, giant, jellyfish, unused corrupted tree): spinning rings of enemy
#   bullets, plus each EnemyProjectileRotating's distance from the center (it flies outwards first)
# - catling gun pet: both gun pivots aim at targets (rotation + scale.y mirror)
#
# The layout (which nodes, in which order) depends only on the scene, so host and client derive the
# same one; it is cached per scene path.

enum Kind { ROTATION, POSITION_X, SCALE_Y }

const MAX_VALUES := 32  # largest layout in the game: giant, 2 pivots x (1 + 6 bullets) = 14

var _layouts := {}  # scene path -> Array of [NodePath, Kind]


func layout(entity: Node) -> Array:
	var key: String = entity.filename
	if not _layouts.has(key):
		_layouts[key] = _find_parts(entity)
	return _layouts[key]


# Host: current values, or empty when the scene has no parts or some of them are gone (the game
# frees a unit's pivots when it dies and does not restore them on pool reuse).
func capture(entity: Node) -> PoolRealArray:
	var values := PoolRealArray()
	for part in layout(entity):
		var node = entity.get_node_or_null(part[0])
		if node == null or node.is_queued_for_deletion():
			return PoolRealArray()
		match part[1]:
			Kind.ROTATION:
				values.append(wrapf(node.rotation, -PI, PI))  # pivots spin without bound
			Kind.POSITION_X:
				values.append(node.position.x)
			Kind.SCALE_Y:
				values.append(node.scale.y)
	return values


# Client: interpolate between two captures (b is the newer one; a may be empty).
func apply(entity: Node, a: PoolRealArray, b: PoolRealArray, t: float) -> void:
	var parts := layout(entity)
	if b.size() != parts.size() or parts.empty():
		return  # host and client disagree about the scene: leave the puppet as it is
	if a.size() != b.size():
		a = b
	for i in parts.size():
		var node = entity.get_node_or_null(parts[i][0])
		if node == null:
			continue
		match parts[i][1]:
			Kind.ROTATION:
				node.rotation = lerp_angle(a[i], b[i], t)
			Kind.POSITION_X:
				node.position.x = lerp(a[i], b[i], t)
			Kind.SCALE_Y:
				node.scale.y = -1.0 if b[i] < 0.0 else 1.0
	if entity is CatlingGun:
		_order_catling_guns(entity)


func _find_parts(entity: Node) -> Array:
	var parts := []
	if entity is Unit:
		var movement = entity.get_node_or_null("MovementBehavior")
		if movement is GoTowardsBorderOppositeMovementBehavior:
			parts.append([NodePath("."), Kind.ROTATION])
	for child in entity.get_children():
		if not child is Pivot:
			continue
		parts.append([entity.get_path_to(child), Kind.ROTATION])
		for bullet in child.get_children():
			if bullet is EnemyProjectileRotating:
				parts.append([entity.get_path_to(bullet), Kind.POSITION_X])
	if entity is CatlingGun:
		for gun in [entity._gun_pivot_l, entity._gun_pivot_r]:
			parts.append([entity.get_path_to(gun), Kind.ROTATION])
			parts.append([entity.get_path_to(gun), Kind.SCALE_Y])
	return parts.slice(0, MAX_VALUES - 1) if parts.size() > MAX_VALUES else parts


# Draw order of CatlingGun._orient_gun: a gun pointing to the far side goes behind the body.
static func _order_catling_guns(catling: Node) -> void:
	for gun in [catling._gun_pivot_l, catling._gun_pivot_r]:
		var left: bool = gun == catling._gun_pivot_l
		var in_front: bool = (left and gun.scale.y > 0) or (not left and gun.scale.y < 0)
		var index := 4 if in_front else 1
		if gun.get_index() != min(index, gun.get_parent().get_child_count() - 1):
			gun.get_parent().move_child(gun, index)
