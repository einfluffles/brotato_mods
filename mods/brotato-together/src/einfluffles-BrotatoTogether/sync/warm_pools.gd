extends Reference
# Puppets and effects made in the frame that loads the battle scene and put into main's pool.
# Instancing a scene with particles (every unit, explosions, hit effects) makes the graphics driver
# wait for the GPU once in the frame it happens in: up to a few frames' time on a slow machine, for
# every frame with one. How many of a scene comes from what the last battle with it used. Pose
# layouts (an instance each) are derived here too. One instance per session.

const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const PREPARED_META := "brotato_together_prepared"  # scene path, until a battle takes the node
const ENEMIES := 6  # per enemy type no earlier battle used any of
const EXPLOSIONS := 4  # likewise per explosion scene
# EffectsManager's exports: how many of each (hits come in bursts).
const EFFECTS := {
	"hit_particles": 12,
	"hit_effect": 12,
	"gold_pickup_particles": 4,
	"crit_particles": 4,
	"heal_particles": 2,
	"stats_boost_particles": 2,
	"speed_removed_particles": 2,
	"one_shot_particles": 2,
}
const MAX_PER_TYPE := 40
const MAX_TOTAL := 200

# Scene path -> how many to make (0: none). Kept across battles.
var needed := {}
var last_fresh := {}  # the last battle's instanced ones per scene path
var _prepared := {}  # this battle: scene path -> made here
var _taken := {}  # this battle: scene path -> made here and used
var _fresh := {}  # this battle: scene path -> instanced in it (none left in the pool)
var _scenes := {}  # scene path -> PackedScene: the same resource (pool id) in every battle


# A pooled node about to be used: the scene path if it was made here (and no longer counts as
# such), else "".
static func take(node: Node) -> String:
	if not node.has_meta(PREPARED_META):
		return ""
	var path: String = node.get_meta(PREPARED_META)
	node.remove_meta(PREPARED_META)
	return path


func note_taken(path: String, count := 1) -> void:
	_taken[path] = _taken.get(path, 0) + count


func note_fresh(path: String, count := 1) -> void:
	_fresh[path] = _fresh.get(path, 0) + count


# What this battle used becomes what the next one makes; made and unused halves each battle.
func remember() -> void:
	for path in _prepared:
		var used: int = _taken.get(path, 0) + _fresh.get(path, 0)
		needed[path] = int(max(used, _prepared[path] / 2))
	for path in _fresh:
		if not _prepared.has(path):
			needed[path] = _fresh[path]
	last_fresh = _fresh
	_prepared = {}
	_taken = {}
	_fresh = {}


# types: idx -> PackedScene of the battle. Also makes scenes earlier battles used that have no type
# yet (their TYPE_DEF comes later). Returns how many nodes were made.
func fill(client: Node, main: Node, types: Dictionary) -> int:
	var scenes := {}  # path -> PackedScene, each once (a scene can have several type indices)
	for idx in types:
		var scene = types[idx]
		if scene is PackedScene:
			scenes[scene.resource_path] = scene
	for path in needed:
		if needed[path] > 0 and not scenes.has(path) and _scenes.has(path):
			scenes[path] = _scenes[path]
	var counts := {}
	var firsts := {}
	for path in scenes:
		var scene: PackedScene = scenes[path]
		if not client._boss_present(scene):
			continue
		_scenes[path] = scene
		client._pose.layout_of(path)
		var count: int = needed.get(path, -1)
		if count < 0:  # not seen yet: its kind decides
			var first: Node = scene.instance()
			count = _default_count(first)
			needed[path] = count
			if count > 0:
				firsts[path] = first
			else:
				first.free()
		if count > 0:
			counts[path] = int(min(count, MAX_PER_TYPE))
	var made := _fill_effects(main)
	var order: Array = counts.keys()
	order.sort_custom(ByCount.new(counts), "first")  # a big horde cannot take the whole budget
	for path in order:
		var count: int = int(min(counts[path], max(0, MAX_TOTAL - made)))
		for k in count:
			var node: Node = firsts[path] if k == 0 and firsts.has(path) else scenes[path].instance()
			_make(client, main, scenes[path], node)
		if count < 1 and firsts.has(path):
			firsts[path].free()
		if count > 0:
			_prepared[path] = count
			made += count
	return made


class ByCount:
	var counts: Dictionary

	func _init(by_path: Dictionary) -> void:
		counts = by_path

	func first(a: String, b: String) -> bool:
		return counts[a] < counts[b] or (counts[a] == counts[b] and a < b)


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
	node.set_meta(PREPARED_META, scene.resource_path)
	PuppetEntity.puppetize(node)
	AnimMirror.detach_game_handlers(node)
	node.get_parent().remove_child(node)
	main._pool[pool_id].push_back(node)


# Hit and pickup effects the way EffectsManager.play makes them, into the same pool.
static func _fill_effects(main: Node) -> int:
	var manager = main.get("_effects_manager")
	if manager == null:
		return 0
	var made := 0
	for name in EFFECTS:
		var scene = manager.get(name)
		if not scene is PackedScene:
			continue
		var pool_id: int = scene.get_instance_id()
		if not main._pool.has(pool_id):
			main._pool[pool_id] = []
		for _k in EFFECTS[name]:
			var effect: Node = scene.instance()
			main.add_effect(effect)
			effect.connect("finished", manager, "on_graphical_effect_finished")
			effect.set_meta("pool_id", pool_id)
			effect.get_parent().remove_child(effect)
			main._pool[pool_id].push_back(effect)
			made += 1
	return made
