extends Reference
# Turns a battle node into a visual-only puppet: no physics/AI/weapons, no collisions, no hit/hurt
# areas. Idle processing (AnimationPlayers, particles) keeps running so it still looks alive.


const FLASH_TIMER := "FlashTimer"
# Type tag of a spawn marker -> the entity type that decides its colour and sprite.
const BIRTH_CHARMED := "birth_charmed"
const BIRTH_TAGS := {
	"birth_enemy": EntityType.ENEMY,
	"birth_neutral": EntityType.NEUTRAL,
	"birth_structure": EntityType.STRUCTURE,
	"birth_charmed": EntityType.ENEMY,
}


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


# Visual part of Player.die(). The real die() emits "died" (main ends the wave when everyone is
# dead) and resets TempStats — host decisions. Parts are hidden instead of freed.
static func player_died(player: Node) -> void:
	player.dead = true
	player._animation_player.playback_speed = 1
	if player._animation_player.has_animation("death"):
		player._animation_player.play("death")
	Utils.disable_node(player._weapons_container)
	player.highlight.hide()
	for part in [player._legs, player._shadow, player._running_smoke]:
		if is_instance_valid(part):
			part.hide()
	for appearance in player._item_appearances:
		if is_instance_valid(appearance):
			appearance.hide()


# Not the hit flash's, nor a life bar's: they are started by what the client shows and their
# timeout only puts a material / a tint back (a paused Timer never fires: the unit, the bar
# would stay white).
static func _pause_timers(node: Node) -> void:
	for child in node.get_children():
		if child is Timer:
			child.paused = not (child.name == FLASH_TIMER or node is UIProgressBar)
		_pause_timers(child)


# A spawn marker (EntityBirth) runs its own flicker and hides itself after the same time as the
# host's; with no collision layers it never finds a player on it (the host moves it then, see
# BattleClient._apply_entities). tag: BIRTH_TAGS key from the type.
static func start_birth(birth: Node, tag: String) -> void:
	var request := SpawnRequest.new(BIRTH_TAGS.get(tag, EntityType.ENEMY), null, birth.global_position)
	request.charmed_by = 0 if tag == BIRTH_CHARMED else -1
	birth.start(request)


static func birth_tag(birth: Node) -> String:
	var request = birth.request
	if request != null and request.charmed_by != -1 and not birth is EntityGroupBirth:
		return BIRTH_CHARMED
	for tag in BIRTH_TAGS:
		if BIRTH_TAGS[tag] == birth.type:
			return tag
	return "birth_structure" if birth.type == EntityType.PET else "birth_enemy"


# Start the visual animation without PlayerProjectile.shoot() (needs real weapon stats).
static func start_projectile_animation(projectile: Node) -> void:
	var player = projectile.get("_animation_player")
	if player != null and player.assigned_animation != "":
		player.stop(true)  # a pooled puppet starts over, like the game's when it is shot
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
