extends Reference
# Suite runtime_scenes: a scene that exists only in the host's memory (another mod packed it and
# gave it a path with take_over_path, as TreasureCastle does with its enemies) reaches a client as
# a description the client rebuilds under its own rules (sync/runtime_scenes.gd,
# sync/scene_description.gd). A hostile host's descriptions are refused and run no code.

const RuntimeScenes := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/runtime_scenes.gd"
)
const SceneDescription := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/scene_description.gd"
)
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const GENERATED := "res://mods-unpacked/einfluffles-TogetherTests/generated/"
const PATH := GENERATED + "foo.tscn"
const ENEMY := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
const ENEMY_DIR := "res://entities/units/enemies/crash_zone/basic/baby_alien/"
const ENEMY_STATS := ENEMY_DIR + "baby_alien_stats.tres"
const ENEMY_TEXTURE := ENEMY_DIR + "baby_alien.png"
const ENEMY_SCRIPT := "res://entities/units/enemies/enemy.gd"
const FIXTURES := "res://mods-unpacked/einfluffles-TogetherTests/fixtures/"
const ICON := GENERATED + "icon.tres"  # a texture a mod made at load and gave a path
const HEALTH := 4321
const PEER := 4848
const TYPE_IDX := 77
const TAG := SceneDescription.Tag
# What a hostile host would like to run on a client. If it ran, the Engine would have this meta.
const RAN := "bt_runtime_scenes_hostile_ran"
const PAYLOAD := (
	'extends Node\nfunc _init():\n\tEngine.set_meta("bt_runtime_scenes_hostile_ran", 1)\n'
)
const USER_SCRIPT := "user://bt_runtime_scenes_hostile.gd"
const USER_SCENE := "user://bt_runtime_scenes_hostile.tscn"  # the payload in a scene of its own
const LOOTER := "res://entities/units/enemies/crash_zone/basic/looter/looter.tscn"
const WHISTLE := "res://dlcs/dlc_1/items/whistle/whistle_fx.tscn"  # Looter's animation_whistle
const FLASH_END := "_on_FlashTimer_timeout"
const MENU_ANIMATION := (
	"res://ui/menus/title_screen/title_screen_background/base_title_screen_background.tscn::4"
)

var _t: Node = null
var _icon: AtlasTexture = null


func _init(t: Node) -> void:
	_t = t


func run(together: Node) -> void:
	_icon = AtlasTexture.new()
	_icon.atlas = load(ENEMY_TEXTURE)
	_icon.region = Rect2(0, 0, 8, 8)
	_icon.take_over_path(ICON)
	_test_in_memory()
	_test_host_to_client(together)
	_test_type_def_first(together)
	_test_once_per_peer()
	_test_client_keeps()
	_test_castle_like()
	_test_host_refuses()
	_test_payload_runs()
	_test_hostile_code()
	_test_hostile_strings()
	_test_rebuilt_scenes()
	_test_hostile_shapes()
	_test_hostile_limits()
	_test_session_limits()
	_test_limits()
	_test_game_enemies()
	_icon.take_over_path("")
	_icon = null


# An enemy as TreasureCastle makes one: a game enemy with stats of its own (an inline resource
# whose script is the game's), packed and given a path no file has.
static func _memory_scene(path: String, source := ENEMY) -> PackedScene:
	var node: Node = load(source).instance()
	node.stats = node.stats.duplicate()
	node.stats.health = HEALTH
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	scene.take_over_path(path)
	return scene


# An enemy as TreasureCastle's _tc_origin_scene makes one each wave: a game enemy with a mod's
# script (the game's enemy script with data of its own), stats of its own that name a texture the
# mod registered at load, a blank sprite made at run time (also its evolution textures), a mod's
# sprite under it, a mod's node with data that names resources, and resized collision shapes.
func _castle_scene(path: String) -> PackedScene:
	var node: Node = load(ENEMY).instance()
	var exported := {}
	for property in node.get_property_list():
		var stored: int = PROPERTY_USAGE_SCRIPT_VARIABLE | PROPERTY_USAGE_STORAGE
		if property.usage & stored == stored:
			exported[property.name] = node.get(property.name)
	node.set_script(load(FIXTURES + "castle_enemy.gd"))
	for key in exported:
		node.set(key, exported[key])
	node.definition = {"id": "stone_mite", "tags": ["common"], "params": {"phases": [{"hp": 1}]}}
	node.donor_stats = load(ENEMY_STATS)
	node.body_size = Vector2(60, 50)
	node.stats = node.stats.duplicate()
	node.stats.health = HEALTH
	node.stats.icon = _icon
	var blank := Image.new()
	blank.create(64, 48, false, Image.FORMAT_RGBA8)
	var texture := ImageTexture.new()
	texture.create_from_image(blank)
	var sprite: Sprite = node.get_node("Animation/Sprite")
	sprite.texture = texture
	node.evolution_meca = texture
	var body := Sprite.new()
	body.name = "CastleBody"
	body.texture = _icon
	body.position = Vector2(3, -4)
	body.use_parent_material = true
	sprite.add_child(body)
	body.owner = node
	var skin: Node = load(FIXTURES + "castle_skin.gd").new()
	skin.name = "CastleVariant"
	skin.textures = {"regular": _icon, "meca": _icon}
	skin.profiles = {
		"regular":
		{"atlas": "art/rigs/castle_regular_111.png", "parts": [{"name": "head", "texture": _icon}]}
	}
	node.add_child(skin)
	skin.owner = node
	for at in ["Collision", "Hurtbox/Collision"]:
		var collision: CollisionShape2D = node.get_node(at)
		collision.shape = collision.shape.duplicate()
		collision.shape.radius = 33.0
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	scene.take_over_path(path)
	return scene


# The host's SCENE body of the scene at path, and the client's scene from it: the host's own is
# taken off the path first, as on another machine.
func _round_trip(scene: PackedScene, path: String) -> Array:
	var body = RuntimeScenes.pack(path)
	scene.take_over_path("")
	var loaded = RuntimeScenes.unpack(body) if body != null else "not sent"
	return [loaded, body]


func _test_in_memory() -> void:
	var scene := _memory_scene(PATH)
	_t._check(RuntimeScenes.in_memory(PATH), "runtime scenes: a scene packed in memory counts")
	var loaded := [load(ENEMY), load(FIXTURES + "disk_scene.tscn"), load(FIXTURES + "remapped.tscn")]
	_t._check(
		loaded[2] is PackedScene and not File.new().file_exists(FIXTURES + "remapped.tscn"),
		"runtime scenes: the fixture behind a .remap loads, and has no file of its own"
	)
	for path in [ENEMY, FIXTURES + "disk_scene.tscn", FIXTURES + "remapped.tscn"]:
		_t._check(
			ResourceLoader.has_cached(path) and not RuntimeScenes.in_memory(path),
			"runtime scenes: a loaded scene file does not count (%s)" % path
		)
	_t._check(
		not RuntimeScenes.in_memory(GENERATED + "never_made.tscn"),
		"runtime scenes: a path nothing is cached under does not count"
	)
	scene.take_over_path("")


# The real host and client code: the host's first use of the type sends the scene's description
# before the TYPE_DEF; with the scene gone from this process the client rebuilds it.
func _test_host_to_client(together: Node) -> void:
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var shared = host.runtime_scenes
	var fake := StateStreamTests.FakeSession.new()
	fake.peers[PEER] = {"ready": true}
	var saved_session: Node = host.session
	host.session = fake
	var scene := _memory_scene(PATH)
	host._type_idx(PATH)
	host._type_idx(PATH + "#tag")
	host._on_peer_ready(PEER)  # a resync (outside a battle: nothing sent yet)
	host._send_battle_start(PEER, {"types": {0: PATH}})  # as _on_peer_ready sends it in a battle
	var kinds := []
	for sent in fake.sent:
		kinds.append(Protocol.Msg.keys()[sent[1]])
	_t._check(
		kinds == ["SCENE", "TYPE_DEF", "TYPE_DEF", "SCENE", "BATTLE_START"],
		"runtime scenes: SCENE once a peer, before the message that names it (%s)" % [kinds]
	)
	var body: Dictionary = fake.sent[0][2] if not fake.sent.empty() else {}
	host.session = saved_session
	host._watch_entry()  # the fake peer had it watch the tree
	host.run_sender.forget(PEER)
	host.runtime_scenes.forget(PEER)
	host._types.clear()
	fake.free()
	scene = null
	_t._check(
		not ResourceLoader.has_cached(PATH), "runtime scenes: the host's scene is gone from memory"
	)
	shared.receive(body)
	client._define_type(TYPE_IDX, PATH)
	var type_scene = client._types.get(TYPE_IDX)
	var node: Node = type_scene.instance() if type_scene is PackedScene else null
	_t._check(
		node != null and node.filename == PATH and node.stats.health == HEALTH,
		"runtime scenes: the client's type resolves to the host's scene, its own stats included"
	)
	_t._check(
		node != null and node.get_script().resource_path == ENEMY_SCRIPT,
		"runtime scenes: the instance has the game's enemy script"
	)
	if node != null:
		node.free()
	client._types.erase(TYPE_IDX)
	client._type_data.erase(TYPE_IDX)
	shared.clear()
	type_scene = null
	_t._check(
		not ResourceLoader.has_cached(PATH), "runtime scenes: the session's end lets the scene go"
	)


# A SCENE the host could not send (a failed send) is resent with the resync's BATTLE_START, after
# its TYPE_DEF resolved to nothing: the type resolves then, in the same battle.
func _test_type_def_first(together: Node) -> void:
	var client: Node = together.battle_client
	var shared = together.battle_host.runtime_scenes
	var scene := _memory_scene(PATH)
	var body = RuntimeScenes.pack(PATH)
	scene.take_over_path("")
	scene = null
	client._define_type(TYPE_IDX, PATH)
	var before = client._types.get(TYPE_IDX, "missing")
	shared.receive(body)
	client._adopt_start({"types": {TYPE_IDX: PATH}})
	var after = client._types.get(TYPE_IDX)
	_t._check(
		before == null and after is PackedScene and after.resource_path == PATH,
		"runtime scenes: a type defined before its SCENE resolves with the resync's BATTLE_START"
	)
	client._types.erase(TYPE_IDX)
	client._type_data.erase(TYPE_IDX)
	shared.clear()


func _test_once_per_peer() -> void:
	var scenes = RuntimeScenes.new()
	var scene := _memory_scene(PATH)
	_t._check(
		scenes.bodies_for(1, [PATH + "#a", ENEMY, PATH]).size() == 1,
		"runtime scenes: one body for the scene in memory, none for the game's scene file"
	)
	_t._check(scenes.bodies_for(1, [PATH]).empty(), "runtime scenes: not twice to a peer")
	_t._check(scenes.bodies_for(2, [PATH]).size() == 1, "runtime scenes: another peer gets it too")
	scenes.forget(1)
	_t._check(
		scenes.bodies_for(1, [PATH]).size() == 1, "runtime scenes: again after a resync (forget)"
	)
	scene.take_over_path("")


func _test_client_keeps() -> void:
	var scenes = RuntimeScenes.new()
	var own := _memory_scene(PATH)
	var body = RuntimeScenes.pack(PATH)
	scenes.receive(body)
	_t._check(load(PATH) == own, "runtime scenes: a scene cached here is kept, not replaced")
	own.take_over_path("")
	own = null
	scenes.receive(body)
	_t._check(not ResourceLoader.has_cached(PATH), "runtime scenes: a path is taken once a session")
	scenes.clear()
	scenes.receive(body)
	var first = load(PATH) if ResourceLoader.has_cached(PATH) else null
	scenes.receive(body)
	_t._check(
		first is PackedScene and load(PATH) == first,
		"runtime scenes: loaded in the next session, and not again for a second body"
	)
	scenes.clear()
	first = null


func _test_castle_like() -> void:
	var scene := _castle_scene(PATH)
	var original: Node = scene.instance()
	var trip := _round_trip(scene, PATH)
	var loaded = trip[0]
	var node: Node = loaded.instance() if loaded is PackedScene else null
	var differences := _differences(original, node) if node != null else ["%s" % [loaded]]
	_t._check(
		differences.empty(),
		"runtime scenes: a TreasureCastle-like enemy comes out as the host's (%s)" % [differences]
	)
	if node != null:
		var skin: Node = node.get_node("CastleVariant")
		var sprite: Sprite = node.get_node("Animation/Sprite")
		_t._check(
			(
				node.stats.health == HEALTH
				and node.stats.icon == _icon
				and node.donor_stats == load(ENEMY_STATS)
				and node.definition.params.phases[0].hp == 1
				and skin.profiles.regular.parts[0].texture == _icon
				and sprite.texture.get_size() == Vector2(64, 48)
				and node.evolution_meca == sprite.texture
				and node.get_node("Hurtbox/Collision").shape.radius == 33.0
				and node.get_node("FlashTimer").is_connected("timeout", node, FLASH_END)
			),
			"runtime scenes: its stats, the mod's data and resources, the blank sprite, the shapes"
		)
		print(
			(
				"  info: runtime scenes: TreasureCastle-like enemy: %d B, %d B packed, %s"
				% [trip[1].size, trip[1].data.size(), _counts(trip[1])]
			)
		)
		node.free()
	original.free()
	if loaded is PackedScene:
		loaded.take_over_path("")


# Where two instanced trees differ: each node's name, class, script, stored properties (resources
# by path the same object, made ones alike) and its signals' connections. Editor notes
# (SceneDescription.NOT_SENT) do not go.
func _differences(a: Node, b: Node, roots := []) -> Array:
	if roots.empty():
		roots = [a, b]
	var at := str(roots[0].get_path_to(a))
	if a.name != b.name or a.get_class() != b.get_class() or a.get_script() != b.get_script():
		return ["%s: %s %s / %s %s" % [at, a.get_class(), a.name, b.get_class(), b.name]]
	var found := []
	for property in a.get_property_list():
		var name: String = property.name
		if property.usage & PROPERTY_USAGE_STORAGE and name != SceneDescription.NOT_SENT:
			if not _alike(a.get(name), b.get(name), 0):
				found.append("%s.%s: %s / %s" % [at, name, a.get(name), b.get(name)])
	var connections := [_connections(a, roots[0]), _connections(b, roots[1])]
	if connections[0] != connections[1]:
		found.append("%s: connections %s / %s" % [at, connections[0], connections[1]])
	if a.get_child_count() != b.get_child_count():
		return found + ["%s: %d / %d children" % [at, a.get_child_count(), b.get_child_count()]]
	for i in a.get_child_count():
		found += _differences(a.get_child(i), b.get_child(i), roots)
	return found


static func _connections(node: Node, root: Node) -> Array:
	var found := []
	for item in node.get_signal_list():
		for connection in node.get_signal_connection_list(item.name):
			var target = connection.target
			var to: String = str(root.get_path_to(target)) if target is Node else str(target)
			found.append("%s>%s:%s" % [item.name, to, connection.method])
	found.sort()
	return found


static func _alike(a, b, depth: int) -> bool:
	if typeof(a) != typeof(b) or depth > 8:
		return false
	match typeof(a):
		TYPE_ARRAY:
			if a.size() != b.size():
				return false
			for i in a.size():
				if not _alike(a[i], b[i], depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			if a.size() != b.size():
				return false
			for key in a:
				if not b.has(key) or not _alike(a[key], b[key], depth + 1):
					return false
			return true
		TYPE_OBJECT:
			if a == b:
				return true
			if not a is Resource or not b is Resource or a.resource_path != "":
				return false
			if a.get_class() != b.get_class() or a.get_script() != b.get_script():
				return false
			for property in a.get_property_list():
				if property.usage & PROPERTY_USAGE_STORAGE:
					if not _alike(a.get(property.name), b.get(property.name), depth + 1):
						return false
			return true
	return a == b


# What a description cannot hold, the host does not send: the type stays unresolved on clients.
func _test_host_refuses() -> void:
	var cases := {}
	var scripted := Node2D.new()
	var script := GDScript.new()
	script.source_code = "extends Node2D\n"
	script.reload()
	scripted.set_script(script)
	cases["an embedded script"] = scripted
	var grouped := Node2D.new()
	var member := Node2D.new()
	member.name = "Member"
	member.add_to_group("g", true)
	grouped.add_child(member)
	member.owner = grouped
	cases["groups"] = grouped
	var holding: Node = load(FIXTURES + "castle_skin.gd").new()
	holding.profiles = {"x": Reference.new()}
	cases["an object that is no resource"] = holding
	var bound: Node = load(ENEMY).instance()
	bound.get_node("FlashTimer").connect("timeout", bound, "_on_BurningTimer_timeout", [1], 2)
	cases["a connection with arguments"] = bound
	var pointing: Node = load(FIXTURES + "castle_skin.gd").new()
	pointing.profiles = {"x": {"fx": "user://x.tscn"}}
	cases["a path out of res://"] = pointing
	for label in cases:
		var scene := PackedScene.new()
		scene.pack(cases[label])
		cases[label].free()
		scene.take_over_path(GENERATED + "refused.tscn")
		var why = SceneDescription.new().describe(scene)
		_t._check(
			why is String and RuntimeScenes.pack(GENERATED + "refused.tscn") == null,
			"runtime scenes: the host does not send %s (%s)" % [label, why]
		)
		scene.take_over_path("")


# The detector: the payload sets the meta when it runs.
func _test_payload_runs() -> void:
	var script := GDScript.new()
	script.source_code = PAYLOAD
	script.reload()
	var node: Node = script.new()
	var ran := Engine.has_meta(RAN)
	node.free()
	Engine.remove_meta(RAN)
	_t._check(ran, "runtime scenes: the hostile payload sets the Engine meta when it runs")


# A description that a client rebuilds: one Node2D.
static func _plain() -> Array:
	return [[[-1, "A", "Node2D", "", "", []]], [], []]


# A description with an inline Image: an RGBA8 image's data, its size and format as given.
static func _image(width: int, height: int, format = null) -> Array:
	var image := Image.new()
	image.create(int(max(width, 1)), int(max(height, 1)), false, Image.FORMAT_RGBA8)
	var data: Dictionary = image.get("data")
	data.width = width
	data.height = height
	if format != null:
		data.format = format
	var pairs := []
	for key in data:
		pairs += [key, data[key]]
	var description := _plain()
	description[1].append(["Image", "", ["data", [TAG.DICTIONARY, pairs]]])
	return description


static func _with_node(entry: Array, connections := []) -> Array:
	var description := _plain()
	description[0].append(entry)
	description[2] = connections
	return description


# Refused, and nothing of it ran: not while it was rebuilt, nor in an instance of what came back.
func _refused(description, label: String) -> void:
	var result = SceneDescription.new().rebuild(description)
	if result is PackedScene:
		var node: Node = result.instance()
		if node != null:
			node.free()
	var ran := Engine.has_meta(RAN)
	Engine.remove_meta(RAN)
	_t._check(
		result is String and result != "" and not ran,
		"runtime scenes: refused, %s (%s%s)" % [label, result, ", it ran" if ran else ""]
	)


# The ways code could ride along: scripts inline, by a path that is no script file here, as a
# property, in a node class that reaches out, a connection, an animation, a nested scene.
func _test_hostile_code() -> void:
	var plain = SceneDescription.new().rebuild(_plain())
	_t._check(plain is PackedScene, "runtime scenes: a plain description rebuilds (%s)" % [plain])
	var file := File.new()
	if file.open(USER_SCRIPT, File.WRITE) == OK:
		file.store_string(PAYLOAD)
		file.close()
	var inline := [TAG.INLINE, 0]
	for type in ["GDScript", "GDScript:", "gdscript", " GDScript", "Script", "VisualScript"]:
		var description := _plain()
		description[1] = [[type, "", ["source_code", PAYLOAD]]]
		description[0][0][5] = ["script", inline]
		_refused(description, "an inline %s as the script" % type)
	var holder := _plain()
	holder[1] = [["GDScript", "", ["source_code", PAYLOAD]]]
	holder[0][0][5] = ["position", Vector2.ONE, "payload", inline]
	_refused(holder, "an inline GDScript as a value")
	var resource := _plain()
	resource[1] = [["Resource", "", ["script", [TAG.PATH, USER_SCRIPT]]]]
	_refused(resource, "a resource's script as a property")
	var class_value := _plain()
	class_value[1] = [[NodePath("GDScript:"), "", ["source_code", PAYLOAD]]]
	_refused(class_value, "a class name that is no string")
	var scripts := {
		"a user:// script": USER_SCRIPT,
		"a res:// path that is no script": FIXTURES + "disk_scene.tscn",
		"a script that is no file here": FIXTURES + "missing.gd",
		"a script path with ..": "res://mods-unpacked/../" + USER_SCRIPT.get_file(),
		"a script path with //": "res:///" + ENEMY_SCRIPT.substr(6),
		"a script path with a control character": char(1) + USER_SCRIPT,
		"the game's script on a class it does not extend": ENEMY_SCRIPT,
	}
	for label in scripts:
		_refused(_with_node([0, "B", "Timer", "", scripts[label], []]), label)
	var outside := {
		"a singleton's script": "res://singletons/progress_data.gd",
		"a mod's mod_main.gd": "res://mods-unpacked/einfluffles-TogetherTests/mod_main.gd",
		"this mod's script": "res://mods-unpacked/einfluffles-BrotatoTogether/session/session.gd",
		"a mod's script that extends a singleton's": FIXTURES + "singleton_extension.gd",
	}
	for label in outside:
		_refused(_with_node([0, "B", "Node2D", "", outside[label], []]), label)
	var reporter := "res://singletons/bug_reporter.tscn"
	_refused(_with_node([0, "B", "", reporter, "", []]), "a scene outside the scene roots")
	var held := _plain()
	held[0][0][5] = ["position", [TAG.PATH, reporter + "::1"], "payload", [TAG.PATH, reporter]]
	_refused(held, "a scene outside the scene roots as a value, after one of its resources")
	var menu_animation := _with_node(
		[0, "B", "AnimationPlayer", "", "", ["anims/x", [TAG.PATH, MENU_ANIMATION]]]
	)
	_refused(menu_animation, "an animation outside the scene roots")
	for name in ["script/source", "script", SceneDescription.NOT_SENT, "payload"]:
		_refused(_with_node([0, "B", "Node2D", "", "", [name, PAYLOAD]]), "the property " + name)
	var path_value := _plain()
	path_value[0][0][5] = ["position", [TAG.PATH, USER_SCRIPT]]
	_refused(path_value, "a user:// resource")
	path_value[0][0][5] = ["position", [TAG.PATH, ENEMY_SCRIPT]]
	_refused(path_value, "a script by path as a value")
	var stats := _plain()
	stats[1] = [["Resource", "", ["resource_path", PATH]]]
	_refused(stats, "a resource's path")
	var request := ["download_file", USER_SCRIPT, "use_threads", true]
	_refused(_with_node([0, "B", "HTTPRequest", "", "", request]), "a node class off the list")
	_refused(_with_node([0, "B", "Node2D", USER_SCRIPT, "", []]), "a user:// scene")
	_refused(_with_node([0, "B", "", FIXTURES + "castle_skin.gd", "", []]), "a script as a scene")
	_refused(_with_node([0, "B", "", ENEMY_TEXTURE, "", []]), "a texture as a scene")
	var nested := _plain()
	nested[1] = [["PackedScene", "", ["_bundled", [TAG.DICTIONARY, []]]]]
	nested[0][0][5] = ["payload", inline]
	_refused(nested, "a nested PackedScene")
	var animation := _with_node([0, "B", "AnimationPlayer", "", "", ["anims/x", inline]])
	animation[1] = [["Animation", "", ["length", 1.0]]]
	_refused(animation, "an inline animation")
	animation = _with_node([0, "B", "AnimationPlayer", "", "", ["anims/x", [TAG.PATH, ENEMY_STATS]]])
	_refused(animation, "an animation that is no animation")
	var enemy := [-1, "E", "RigidBody2D", "", ENEMY_SCRIPT, []]
	var connections := {
		"a connection to a method of the class": [[0, "ready", 0, "queue_free", CONNECT_PERSIST]],
		"a connection to set": [[0, "ready", 0, "set", CONNECT_PERSIST]],
		"a connection of a signal it lacks": [[0, "payload", 0, FLASH_END, 2]],
		"a connection with other flags": [[0, "ready", 0, FLASH_END, 8]],
		"a connection to a node it lacks": [[0, "ready", 3, FLASH_END, 2]],
		"a connection with arguments": [[0, "ready", 0, FLASH_END, 2, [1]]],
	}
	for label in connections:
		_refused([[enemy], [], connections[label]], label)
	Directory.new().remove(USER_SCRIPT)


# A string the game load()s (Looter's animation_whistle, a mod's data) names a path out of res://:
# a share on another machine, user://, the disk, a res:// path out of the plain form.
func _test_hostile_strings() -> void:
	var node := Node.new()
	var script := GDScript.new()
	script.source_code = PAYLOAD
	script.reload()
	node.set_script(script)
	var payload := PackedScene.new()
	payload.pack(node)
	node.free()
	ResourceSaver.save(USER_SCENE, payload)
	payload = null
	Engine.remove_meta(RAN)
	var gadget: Node = load(FIXTURES + "whistle_gadget.gd").new()
	gadget.effect = USER_SCENE
	gadget.free()
	var ran := Engine.has_meta(RAN)
	Engine.remove_meta(RAN)
	_t._check(ran, "runtime scenes: a gadget given the path of the payload's scene runs it")
	var gadget_node := [0, "G", "Node2D", "", FIXTURES + "whistle_gadget.gd", ["effect", USER_SCENE]]
	_refused(_with_node(gadget_node), "a user:// scene in a gadget's path")
	var paths := [
		"//host/share/x.tscn",
		"\\\\host\\share\\x.tscn",
		"user://x.tscn",
		"/tmp/x.tscn",
		"C:/x.tscn",
		"c:\\x.tscn",
		"C:x.tscn",
		"res://../x.tscn",
		"res:///x.tscn",
		"res://x.tscn::1",
		"../x.tscn",
		"art\\..\\..\\x.tscn",
	]
	for path in paths:
		var values := {
			"as the value": path,
			"in an array": [TAG.ARRAY, [1, path]],
			"in a PoolStringArray": PoolStringArray(["x", path]),
			"as a dictionary key": [TAG.DICTIONARY, [path, 1]],
			"as a dictionary value": [TAG.DICTIONARY, ["fx", path]],
		}
		for label in values:
			var looter := [[[-1, "L", "", LOOTER, "", ["animation_whistle", values[label]]]], [], []]
			_refused(looter, "Looter's animation_whistle %s %s" % [label, path])
	var texts := [WHISTLE, "whistle_fx", "art/rigs/castle_regular_111.png", "Wave 3: 2..5"]
	for text in texts:
		var looter := [[[-1, "L", "", LOOTER, "", ["animation_whistle", text]]], [], []]
		var result = SceneDescription.new().rebuild(looter)
		var instance: Node = result.instance() if result is PackedScene else null
		_t._check(
			instance != null and instance.animation_whistle == text,
			"runtime scenes: Looter's animation_whistle %s stays (%s)" % [text, result]
		)
		if instance != null:
			instance.free()
	Directory.new().remove(USER_SCENE)


# A scene rebuilt from a host's description never goes into another one, instanced or as a value
# (each could hold 127 of the one before). One this client made itself in memory does.
func _test_rebuilt_scenes() -> void:
	var made := GENERATED + "made.tscn"
	var own := GENERATED + "own.tscn"
	var text := var2bytes(_plain())
	var body := {"path": made, "size": text.size(), "data": text.compress(RuntimeScenes.COMPRESSION)}
	var scenes = RuntimeScenes.new()
	scenes.receive(body)
	var kept = load(made) if ResourceLoader.has_cached(made) else null  # as a warm pool holds it
	_t._check(kept is PackedScene, "runtime scenes: the client took the host's scene")
	var own_scene := _memory_scene(own)
	for session in ["", ", after the session that took it"]:
		_refused(_with_node([0, "B", "", made, "", []]), "an instance of a rebuilt scene" + session)
		_refused(_holding(made), "a rebuilt scene as a value" + session)
		scenes.clear()
	for description in [_with_node([0, "B", "", own, "", []]), _holding(own)]:
		var result = SceneDescription.new().rebuild(description)
		_t._check(
			result is PackedScene,
			"runtime scenes: a scene this client made in memory goes into one (%s)" % [result]
		)
	own_scene.take_over_path("")
	if kept is PackedScene:
		kept.take_over_path("")


# A mod's node that holds the scene at path in its data.
static func _holding(path: String) -> Array:
	var textures := [TAG.DICTIONARY, ["s", [TAG.PATH, path]]]
	return _with_node([0, "S", "Node", "", FIXTURES + "castle_skin.gd", ["textures", textures]])


# Descriptions of the wrong shape, Objects where data goes, paths out of the plain form.
func _test_hostile_shapes() -> void:
	var shapes := {
		"no array": "x",
		"too short": [[], []],
		"no nodes": [[], [], []],
		"a node of another shape": [[[-1, "A", "Node2D", "", ""]], [], []],
		"a root with a parent": [[[0, "A", "Node2D", "", "", []]], [], []],
		"a later parent": _with_node([2, "B", "Node2D", "", "", []]),
		"a second root": _with_node([-1, "B", "Node2D", "", "", []]),
		"a class and a scene": _with_node([0, "B", "Node2D", ENEMY, "", []]),
		"a name the engine changes": _with_node([0, "B/C", "Node2D", "", "", []]),
		"an empty name": _with_node([0, "", "Node2D", "", "", []]),
		"a changed node no scene made": _with_node([0, "B", "", "", "", []]),
		"an odd property list": _with_node([0, "B", "Node2D", "", "", ["position"]]),
		"an Object": _with_node([0, "B", "Node2D", "", "", ["position", Reference.new()]]),
		"a bare dictionary": _with_node([0, "B", "Node2D", "", "", ["position", {"a": 1}]]),
		"an unknown tag": _with_node([0, "B", "Node2D", "", "", ["position", [9, 1]]]),
		"an inline resource not yet made":
		_with_node([0, "B", "Node2D", "", "", ["position", [TAG.INLINE, 0]]]),
		"an absolute node path":
		_with_node([0, "B", "Node2D", "", "", ["position", NodePath("/root")]]),
		"a node path out of the scene":
		_with_node([0, "B", "Node2D", "", "", ["position", NodePath("../x")]]),
		"a file inside a file without an id":
		_with_node([0, "B", "Node2D", "", "", ["position", [TAG.PATH, ENEMY + "::x"]]]),
		"a resource inside a file it lacks":
		_with_node([0, "B", "Node2D", "", "", ["position", [TAG.PATH, ENEMY + "::999"]]]),
	}
	for label in shapes:
		_refused(shapes[label], label)
	var side: int = SceneDescription.MAX_IMAGE_SIDE
	var images := {
		"a resource inside itself":
		[_plain()[0], [["Resource", "", ["resource_name", [TAG.INLINE, 0]]]], []],
		"a compressed image": _image(4, 4, "DXT5"),
		"an image wider than %d" % side: _image(side + 1, 1),
		"an image taller than %d" % side: _image(1, side + 1),
		"an image of no width": _image(0, 4),
		"an image's data of no dictionary": [_plain()[0], [["Image", "", ["data", 5]]], []],
	}
	for label in images:
		_refused(images[label], label)
	var blank = SceneDescription.new().rebuild(_image(64, 48))
	_t._check(
		blank is PackedScene, "runtime scenes: an RGBA8 image of 64x48 rebuilds (%s)" % [blank]
	)
	var scenes = RuntimeScenes.new()
	for wrong in ["x", [], null, {"path": 5}, {"path": PATH, "size": "1", "data": []}]:
		scenes.receive(wrong)
	_t._check(
		not ResourceLoader.has_cached(PATH) and scenes._held.size() <= 1,
		"runtime scenes: bodies that are no SCENE body change nothing"
	)
	var paths := {
		"a user:// path": "user://x.tscn",
		"a path with ..": "res://../x.tscn",
		"a path with //": "res:///x.tscn",
		"no scene": GENERATED + "x.gd",
		"the game's scene": ENEMY,
	}
	var plain := var2bytes(_plain())
	for label in paths:
		var data := plain.compress(RuntimeScenes.COMPRESSION)
		var wrong := {"path": paths[label], "size": plain.size(), "data": data}
		_rejected(RuntimeScenes.unpack(wrong), label)


func _rejected(why, label: String) -> void:
	_t._check(why is String and why != "", "runtime scenes: rejected, %s (%s)" % [label, why])


# A description over a cap is refused before anything of it is made.
func _test_hostile_limits() -> void:
	var deep = 1
	for _i in SceneDescription.MAX_DEPTH + 1:
		deep = [TAG.ARRAY, [deep]]
	_refused(_with_node([0, "B", "Node2D", "", "", ["position", deep]]), "values nested too deep")
	var many := []
	many.resize(SceneDescription.MAX_VALUES)
	_refused(
		_with_node([0, "B", "Node2D", "", "", ["position", [TAG.ARRAY, many]]]), "too many values"
	)
	var nodes := _plain()
	for i in SceneDescription.MAX_NODES:
		nodes[0].append([0, "N%d" % i, "Node2D", "", "", []])
	_refused(nodes, "too many nodes")
	var resources := _plain()
	for _i in SceneDescription.MAX_RESOURCES + 1:
		resources[1].append(["Resource", "", []])
	_refused(resources, "too many resources")
	var connections := _plain()
	for _i in SceneDescription.MAX_CONNECTIONS + 1:
		connections[2].append([0, "ready", 0, "x", 2])
	_refused(connections, "too many connections")
	var refs := []
	var icons := {}
	for item in ItemService.items + ItemService.weapons + ItemService.characters:
		var icon: Resource = item.icon
		var more: bool = refs.size() <= SceneDescription.MAX_PATHS
		if more and icon != null and not icons.has(icon.resource_path):
			icons[icon.resource_path] = true
			refs.append([TAG.PATH, icon.resource_path])
	_refused(
		_with_node([0, "B", "Node2D", "", "", ["position", [TAG.ARRAY, refs]]]),
		"more resources by path than %d (of %d)" % [SceneDescription.MAX_PATHS, refs.size()]
	)
	var text := var2bytes(_plain())
	var packed := text.compress(RuntimeScenes.COMPRESSION)
	var body := {"path": GENERATED + "small.tscn", "size": text.size(), "data": packed}
	var scene = RuntimeScenes.unpack(body)
	_t._check(scene is PackedScene, "runtime scenes: a small hand-made body loads (%s)" % [scene])
	if scene is PackedScene:
		scene.take_over_path("")
	body.size = RuntimeScenes.MAX_BYTES + 1
	_rejected(RuntimeScenes.unpack(body), "a description over the limit")
	body.size = text.size() + 1
	_rejected(RuntimeScenes.unpack(body), "a size the data does not have")
	body.size = text.size()
	body.data = Crypto.new().generate_random_bytes(RuntimeScenes.MAX_PACKED_BYTES + 1)
	_rejected(RuntimeScenes.unpack(body), "packed bytes over the limit")


# A host that sends scene after scene: a session takes so many, and so many bytes, then logs once
# and takes no more.
func _test_session_limits() -> void:
	var scenes = RuntimeScenes.new()
	var zeros := Image.new()  # its data is zeroed, a resized PoolByteArray's is not
	zeros.create(1024, RuntimeScenes.MAX_BYTES / 4096, false, Image.FORMAT_RGBA8)
	var big := zeros.get_data()
	var data := big.compress(RuntimeScenes.COMPRESSION)
	var bodies := RuntimeScenes.MAX_SESSION_BYTES / RuntimeScenes.MAX_BYTES + 3
	for i in bodies:
		var body := {"path": GENERATED + "flood_%d.tscn" % i, "size": big.size(), "data": data}
		scenes.receive(body)
	_t._check(
		scenes._held.size() == RuntimeScenes.MAX_SESSION_BYTES / RuntimeScenes.MAX_BYTES,
		"runtime scenes: a session takes %d B of descriptions (%d of %d bodies)"
		% [RuntimeScenes.MAX_SESSION_BYTES, scenes._held.size(), bodies]
	)
	scenes.clear()
	var plain := var2bytes(_plain())
	var small := plain.compress(RuntimeScenes.COMPRESSION)
	for i in RuntimeScenes.MAX_SESSION_SCENES + 2:
		scenes.receive({"path": GENERATED + "many_%d.tscn" % i, "size": plain.size(), "data": small})
	_t._check(
		scenes._held.size() == RuntimeScenes.MAX_SESSION_SCENES,
		"runtime scenes: a session takes %d scenes (%d)"
		% [RuntimeScenes.MAX_SESSION_SCENES, scenes._held.size()]
	)
	scenes.clear()


func _test_limits() -> void:
	# Noise does not compress (an image of it made at run time would go byte for byte).
	var rng := RandomNumberGenerator.new()
	var noise := PoolByteArray()
	noise.resize(102400)
	for i in noise.size():
		noise[i] = rng.randi() & 255
	var noisy := Node2D.new()
	var image := Image.new()
	image.create_from_data(160, 160, false, Image.FORMAT_RGBA8, noise)
	var texture := ImageTexture.new()
	texture.create_from_image(image)
	var sprite := Sprite.new()
	sprite.texture = texture
	noisy.add_child(sprite)
	sprite.owner = noisy
	var big := PackedScene.new()
	big.pack(noisy)
	noisy.free()
	big.take_over_path(GENERATED + "big.tscn")
	var scenes = RuntimeScenes.new()
	_t._check(
		scenes.bodies_for(1, [GENERATED + "big.tscn"]).empty(),
		"runtime scenes: a scene over the limit is not sent (the type goes without it)"
	)
	big.take_over_path("")
	_measure_blank_sprite(260, 260)
	_measure_blank_sprite(770, 350)


# TreasureCastle hides an enemy's own sprite behind a transparent texture made at run time (no
# path, so its pixels go in the description), up to a boss sprite's size.
func _measure_blank_sprite(width: int, height: int) -> void:
	var image := Image.new()
	image.create(width, height, false, Image.FORMAT_RGBA8)
	var texture := ImageTexture.new()
	texture.create_from_image(image)
	var node: Node = load(ENEMY).instance()
	node.get_node("Animation/Sprite").texture = texture
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	scene.take_over_path(GENERATED + "blank.tscn")
	var started := OS.get_ticks_usec()
	var body = RuntimeScenes.pack(GENERATED + "blank.tscn")
	var packed := OS.get_ticks_usec()
	scene.take_over_path("")
	scene = null
	var loaded = RuntimeScenes.unpack(body) if body != null else "not sent"
	var done := OS.get_ticks_usec()
	var shown = loaded.instance() if loaded is PackedScene else null
	var size: Vector2 = shown.get_node("Animation/Sprite").texture.get_size() if shown else Vector2()
	_t._check(
		size == Vector2(width, height),
		"runtime scenes: an enemy with a blank %dx%d texture of its own goes and loads (%s)"
		% [width, height, loaded]
	)
	if body != null:
		print(
			(
				"  info: runtime scenes: blank %dx%d sprite: %d B, %d B packed;"
				+ " host %.1f ms, client %.1f ms"
			)
			% [width, height, body.size, body.data.size(), (packed - started) / 1000.0,
			(done - packed) / 1000.0]
		)
	if shown != null:
		shown.free()
	if loaded is PackedScene:
		loaded.take_over_path("")


# Every enemy the game's waves spawn, packed in memory as TreasureCastle does: the client rebuilds
# each as the host has it. The sizes are for the limit.
func _test_game_enemies() -> void:
	var paths := {}
	for zone in ZoneService.zones:
		for wave in zone.waves_data:
			for group in wave.groups_data:
				for unit in group.wave_units_data:
					if unit.unit_scene != null:
						paths[unit.unit_scene.resource_path] = true
	var failed := []
	var bytes_max := 0
	var packed_max := [0, ""]
	var counts_max := {}
	var started := OS.get_ticks_usec()
	for path in paths:
		var scene := _memory_scene(GENERATED + "survey.tscn", path)
		var original: Node = scene.instance()
		var trip := _round_trip(scene, GENERATED + "survey.tscn")
		var loaded = trip[0]
		var node: Node = loaded.instance() if loaded is PackedScene else null
		var differences := _differences(original, node) if node != null else ["%s" % [loaded]]
		if not differences.empty() or node.stats.health != HEALTH:
			failed.append("%s: %s" % [path, differences])
		else:
			bytes_max = int(max(bytes_max, trip[1].size))
			if trip[1].data.size() > packed_max[0]:
				packed_max = [trip[1].data.size(), path]
			var counts := _counts(trip[1])
			for key in counts:
				counts_max[key] = int(max(counts_max.get(key, 0), counts[key]))
		original.free()
		if node != null:
			node.free()
		if loaded is PackedScene:
			loaded.take_over_path("")
	print(
		(
			"  info: runtime scenes: %d game enemies, largest %d B, %d B packed (%s); %.0f ms in all"
			% [
				paths.size(),
				bytes_max,
				packed_max[0],
				packed_max[1],
				(OS.get_ticks_usec() - started) / 1000.0
			]
		)
	)
	print("  info: runtime scenes: game enemies at most %s" % [counts_max])
	_t._check(
		paths.size() > 10 and failed.empty(),
		"runtime scenes: every wave enemy of the game comes out as the host's (%s)" % [failed]
	)


# What the caps of a description count, in a SCENE body: for SceneDescription's MAX_*.
static func _counts(body: Dictionary) -> Dictionary:
	var description: Array = bytes2var(body.data.decompress(body.size, RuntimeScenes.COMPRESSION))
	var counts := {"values": 0, "depth": 0, "paths": {}}
	for node in description[0]:
		for value in node[5]:
			_count(value, 0, counts)
	for resource in description[1]:
		for value in resource[2]:
			_count(value, 0, counts)
	return {
		"nodes": description[0].size(),
		"resources": description[1].size(),
		"connections": description[2].size(),
		"paths": counts.paths.size(),
		"values": counts.values,
		"depth": counts.depth,
	}


static func _count(value, depth: int, counts: Dictionary) -> void:
	counts.values += 1
	counts.depth = max(counts.depth, depth)
	if typeof(value) != TYPE_ARRAY:
		return
	if value[0] == TAG.PATH:
		counts.paths[value[1]] = true
	elif value[0] in [TAG.ARRAY, TAG.DICTIONARY]:
		for item in value[1]:
			_count(item, depth + 1, counts)
