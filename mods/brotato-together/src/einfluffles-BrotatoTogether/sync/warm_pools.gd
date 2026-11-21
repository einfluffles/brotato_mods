extends Reference
# Puppets made in the frame that loads the battle scene and put into main's pool. Instancing an
# enemy or an explosion (their particles) makes the graphics driver wait for the GPU once in the
# frame it happens in: up to a few frames' time on a slow machine, for every frame with one. How
# many of a kind comes from what the last battle with it needed. One instance per session.

const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const ENEMIES := 6  # per enemy type no earlier battle needed any of
const EXPLOSIONS := 4  # likewise per explosion scene
const MAX_PER_TYPE := 40
const MAX_TOTAL := 200

# Scene path -> puppets of it the last battle that had it needed (made here plus instanced in the
# battle); 0: a kind that is only made here once a battle needed some.
var needed := {}
var battle := {}  # the same for this battle so far


# A puppet the battle had to instance: one more for the next battle.
func note_fresh(path: String, count := 1) -> void:
	battle[path] = battle.get(path, 0) + count


# What this battle needed becomes what the next one makes.
func remember() -> void:
	for path in battle:
		needed[path] = battle[path]
	battle.clear()


# types: idx -> PackedScene of the battle. Returns how many puppets were made.
func fill(client: Node, main: Node, types: Dictionary) -> int:
	var made := 0
	for idx in types:
		var scene = types[idx]
		if not scene is PackedScene or not client._boss_present(scene):
			continue
		var path: String = scene.resource_path
		var count: int = needed.get(path, -1)
		var first: Node = null
		if count < 0:  # not seen yet: its kind decides
			first = scene.instance()
			count = _default_count(first)
			needed[path] = count
		count = int(min(count, min(MAX_PER_TYPE, MAX_TOTAL - made)))
		if count <= 0:
			if first != null:
				first.free()
			continue
		for k in count:
			var node: Node = first if k == 0 and first != null else scene.instance()
			_make(client, main, scene, node)
		note_fresh(path, count)
		made += count
	return made


static func _default_count(node: Node) -> int:
	if node is PlayerExplosion:
		return EXPLOSIONS
	if node is Enemy and not node is Boss:
		return ENEMIES
	return 0


# Into the tree once (its _ready runs as for a puppet the battle makes), then into main's pool the
# way the game pools it, so BattleClient._spawn and FeedbackMirror.explode take it from there.
static func _make(client: Node, main: Node, scene: PackedScene, node: Node) -> void:
	var pool_id: int = scene.get_instance_id()
	if not main._pool.has(pool_id):
		main._pool[pool_id] = []
	if node is PlayerExplosion:
		main.add_explosion(node)
		node.sound_played = true
		node._hitbox.disable()
	else:
		client._container_for(node).add_child(node)
	node.pool_id = pool_id
	PuppetEntity.puppetize(node)
	AnimMirror.detach_game_handlers(node)
	node.get_parent().remove_child(node)
	main._pool[pool_id].push_back(node)
