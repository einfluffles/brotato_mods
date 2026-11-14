extends Reference
# Turns a battle node into a visual-only puppet: no physics/AI/weapons, no collisions, no hit/hurt
# areas. Idle processing (AnimationPlayers, particles) keeps running so it still looks alive.


static func puppetize(node: Node) -> void:
	node.propagate_call("set_physics_process", [false])
	_pause_timers(node)  # e.g. enemy retargeting timers would run AI code without a spawner
	if node is RigidBody2D:
		node.mode = RigidBody2D.MODE_STATIC
	if node is CollisionObject2D:
		node.collision_layer = 0
		node.collision_mask = 0
	_disable_areas(node)


# Visual part of Entity.respawn() for pooled puppets. The full respawn chain (Enemy.respawn)
# re-runs AI setup like update_target(), which needs a real spawner.
static func revive(entity: Node) -> void:
	entity.show()
	if entity._texture_base != null:
		entity.sprite.texture = entity._texture_base
	entity._animation_player.play("idle")
	entity.dead = false
	entity._pending_die = false
	entity.sleeping = false


static func _pause_timers(node: Node) -> void:
	for child in node.get_children():
		if child is Timer:
			child.paused = true
		_pause_timers(child)


# Start the visual animation without PlayerProjectile.shoot() (needs real weapon stats).
static func start_projectile_animation(projectile: Node) -> void:
	var player = projectile.get("_animation_player")
	if player != null and player.assigned_animation != "":
		player.play()


static func _disable_areas(node: Node) -> void:
	for child in node.get_children():
		if child is Area2D:
			child.set_deferred("monitoring", false)
			child.set_deferred("monitorable", false)
		_disable_areas(child)


# Facing + walk animation from the interpolated motion (Unit.update_animation flips sprites;
# Player.update_animation also switches idle/move animations). Projectiles face their motion.
static func animate(node: Node, motion: Vector2) -> void:
	if node is Projectile:
		if motion.length_squared() > 0.01:
			node.rotation = motion.angle()
	elif node.has_method("update_animation"):
		node.update_animation(motion)
