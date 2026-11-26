extends Reference
# A scene that exists only in the host's memory, as data a client rebuilds under its own rules
# (sync/runtime_scenes.gd sends it). A description holds no code: the client makes nodes and
# inline resources only of the classes below, attaches a script only by the path of a script file
# it has, takes every other resource by a res:// path it can load itself, sets only properties
# the object lists for storage, and connects signals only to methods of the target's script.
# One instance per describe or rebuild.
#
# Description: [nodes, resources, connections]
# - node: [parent index (-1: the root), name, class, scene path, script path, properties]. With a
#   scene path the node is that scene's instance (class ""); with neither it is a node of an
#   instanced scene above it, changed.
# - resource (made at run time, no path): [class, script path, properties]
# - connection: [source index, signal, target index, method, flags]
# - properties: [name, value, name, value, ...]. A value is a plain Variant or [tag, payload]:
#   [ARRAY, [values]], [DICTIONARY, [key, value, ...]], [PATH, "res://..."] (a resource by path;
#   "<file>::<id>" for one inside a file) or [INLINE, index] (an earlier resource).

enum Tag { ARRAY, DICTIONARY, PATH, INLINE }

# The classes of the nodes the game's wave enemies make themselves (suite runtime_scenes), and
# Node (TreasureCastle's variant skin). An instanced scene's nodes keep their own classes.
const NODE_CLASSES := [
	"AnimationPlayer",
	"Area2D",
	"CollisionShape2D",
	"Node",
	"Node2D",
	"RigidBody2D",
	"Sprite",
	"Timer",
]
# Resources made at run time: stats (Resource with a script), a material duplicated per instance
# (ShaderMaterial, its shader by path), TreasureCastle's resized collision shapes and its blank
# sprite (ImageTexture of an Image).
const RESOURCE_CLASSES := ["CircleShape2D", "Image", "ImageTexture", "Resource", "ShaderMaterial"]
# Resources by path: data, never code.
const PATH_EXTENSIONS := ["gdshader", "ogg", "png", "res", "scn", "shader", "tres", "tscn", "wav"]
# Where a script and each script it extends, an instanced scene, and a scene or animation as a
# value may come from: the game's folders its wave enemies' scripts, scenes, projectiles and
# animations are in, the base of their behaviours, and mods. Not singletons, menus, the mod
# loader, a mod's mod_main.gd or this mod: their code would run as part of an enemy.
const SCENE_FILES := [
	"res://global/behavior.gd", "res://ui/hud/ui_progress_bar.gd", "res://ui/hud/ui_progress_bar.tscn"
]
const SCENE_ROOTS := [
	"res://entities/",
	"res://overlap/",
	"res://particles/",
	"res://projectiles/",
	"res://mods-unpacked/",
]
const NOT_SCENE_ROOTS := ["res://mods-unpacked/einfluffles-BrotatoTogether/"]
const CONNECT_FLAGS := 1 | 2 | 4  # CONNECT_DEFERRED, CONNECT_PERSIST, CONNECT_ONESHOT
const NOT_SENT := "__meta__"  # the game's enemies hold editor notes there, nothing else

const MAX_NODES := 128
const MAX_RESOURCES := 64
const MAX_CONNECTIONS := 64
const MAX_PATHS := 256
const MAX_VALUES := 32768
const MAX_DEPTH := 16

var why := ""  # the first reason a describe or rebuild failed

# describe
var _inline := {}  # resource -> index
var _open := {}  # resources being described: one inside itself is a cycle

# rebuild
var _resources := []
var _nodes := []
var _paths := {}  # path -> resource
var _files := []  # files whose inner resources were taken
var _values := 0


# Host: the description of a packed scene, or why it has none.
func describe(scene: PackedScene):
	var state := scene.get_state()
	var nodes := []
	var index := {}  # node path -> index
	for i in state.get_node_count():
		var path := str(state.get_node_path(i))
		var parent: int = index.get(str(state.get_node_path(i, true)), -1)
		if i > 0 and parent < 0:
			return "the node %s under a node it does not hold" % path
		if state.is_node_instance_placeholder(i) or not state.get_node_groups(i).empty():
			return "the placeholder or groups of %s" % path
		index[path] = i
		var instance = state.get_node_instance(i)
		if instance != null and instance.resource_path == "":
			return "the instanced scene of %s has no path" % path
		var script := ""
		var properties := []
		for p in state.get_node_property_count(i):
			var name := state.get_node_property_name(i, p)
			if name == "script":
				var value = state.get_node_property_value(i, p)
				script = _script_path(value)
				if value == null:
					_fail("a removed script")
			elif name != NOT_SENT:
				properties.append(name)
				properties.append(_encode(state.get_node_property_value(i, p), 0))
		if why != "":
			return "%s (%s)" % [why, path]
		nodes.append(
			[
				parent,
				state.get_node_name(i),
				state.get_node_type(i) if instance == null else "",
				instance.resource_path if instance != null else "",
				script,
				properties,
			]
		)
	var connections := []
	for c in state.get_connection_count():
		var source: int = index.get(str(state.get_connection_source(c)), -1)
		var target: int = index.get(str(state.get_connection_target(c)), -1)
		if source < 0 or target < 0 or not state.get_connection_binds(c).empty():
			return "the connection of %s" % state.get_connection_source(c)
		connections.append(
			[
				source,
				state.get_connection_signal(c),
				target,
				state.get_connection_method(c),
				state.get_connection_flags(c),
			]
		)
	return [nodes, _resources, connections]


func _encode(value, depth: int):
	if depth > MAX_DEPTH:
		_fail("values deeper than %d" % MAX_DEPTH)
		return null
	match typeof(value):
		TYPE_ARRAY:
			var items := []
			for item in value:
				items.append(_encode(item, depth + 1))
			return [Tag.ARRAY, items]
		TYPE_DICTIONARY:
			var pairs := []
			for key in value:
				pairs.append(_encode(key, depth + 1))
				pairs.append(_encode(value[key], depth + 1))
			return [Tag.DICTIONARY, pairs]
		TYPE_OBJECT:
			return _encode_object(value)
		TYPE_RID:
			_fail("a RID")
	return value


func _encode_object(object):
	if object == null:
		return null
	if not object is Resource:
		_fail("a %s that is no resource" % object.get_class())
		return null
	if object.resource_path != "":
		return [Tag.PATH, object.resource_path]
	if not _inline.has(object):
		if _open.has(object):
			_fail("a %s inside itself" % object.get_class())
			return null
		_open[object] = true
		var described := [object.get_class(), _script_path(object.get_script()), []]
		for property in object.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE and property.name != "script":
				if property.name != NOT_SENT:
					described[2].append(property.name)
					described[2].append(_encode(object.get(property.name), 0))
		_inline[object] = _resources.size()
		_resources.append(described)
	return [Tag.INLINE, _inline[object]]


func _script_path(script) -> String:
	if script == null:
		return ""
	var path: String = script.resource_path if script is Script else ""
	if path == "" or "::" in path:
		_fail("a script without a file of its own")
	return path


func _fail(reason: String) -> void:
	if why == "":
		why = reason


# Client: the scene of a description, or why not. Nothing outside the rules is made or run.
func rebuild(description):
	if typeof(description) != TYPE_ARRAY or description.size() != 3:
		return "not a description"
	var nodes = description[0]
	var resources = description[1]
	var connections = description[2]
	if typeof(nodes) != TYPE_ARRAY or typeof(resources) != TYPE_ARRAY:
		return "not a description"
	if typeof(connections) != TYPE_ARRAY or nodes.empty():
		return "not a description"
	if nodes.size() > MAX_NODES or resources.size() > MAX_RESOURCES:
		return "%d nodes, %d resources" % [nodes.size(), resources.size()]
	if connections.size() > MAX_CONNECTIONS:
		return "%d connections" % connections.size()
	for entry in resources:
		if why == "":
			_add_resource(entry)
	for i in nodes.size():
		if why == "":
			_add_node(nodes[i], i)
	for entry in connections:
		if why == "":
			_connect_signal(entry)
	var scene := PackedScene.new()
	if why == "" and scene.pack(_nodes[0]) != OK:
		_fail("it did not pack")
	if not _nodes.empty():
		_nodes[0].free()
	return scene if why == "" else why


func _add_resource(entry) -> void:
	if not _shaped(entry, [TYPE_STRING, TYPE_STRING, TYPE_ARRAY]):
		_fail("a malformed resource")
	elif not entry[0] in RESOURCE_CLASSES:
		_fail("an inline %s" % entry[0])
	else:
		var resource: Resource = ClassDB.instance(entry[0])
		_resources.append(resource)
		_attach_script(resource, entry[1])
		_apply(resource, entry[2])


func _add_node(entry, i: int) -> void:
	var shape := [TYPE_INT, TYPE_STRING, TYPE_STRING, TYPE_STRING, TYPE_STRING, TYPE_ARRAY]
	if not _shaped(entry, shape) or entry[1] == "" or (entry[0] < 0) != (i == 0):
		_fail("a malformed node")
		return
	if entry[0] >= i:
		_fail("a malformed node")
		return
	var name: String = entry[1]
	var parent: Node = _nodes[entry[0]] if i > 0 else null
	var node: Node = null
	if entry[2] == "" and entry[3] == "" and parent != null:
		node = _changed(parent, name)
	else:
		if entry[3] != "" and entry[2] == "":
			var scene = _by_path(entry[3])
			node = scene.instance() if scene is PackedScene and why == "" else null
		elif entry[3] == "" and entry[2] in NODE_CLASSES:
			node = ClassDB.instance(entry[2])
		if node != null:
			node.name = name
			if parent != null:
				parent.add_child(node)
				node.owner = _nodes[0]
			if str(node.name) != name:
				_fail("the node name %s" % name)
	if node == null:
		_fail("the node %s (%s)" % [name, entry[2] if entry[3] == "" else entry[3]])
		return
	_nodes.append(node)
	_attach_script(node, entry[4])
	_apply(node, entry[5])


# A node an instanced scene made, which the description changes: the scene's node becomes
# editable, so the change is packed with it.
func _changed(parent: Node, name: String) -> Node:
	for child in parent.get_children():
		var owner: Node = child.owner
		if str(child.name) != name or _nodes.has(child) or owner == null:
			continue
		if owner == _nodes[0] or (_nodes.has(owner) and owner.filename != ""):
			if owner != _nodes[0]:
				_nodes[0].set_editable_instance(owner, true)
			return child
	return null


func _attach_script(object: Object, path: String) -> void:
	if path == "" or why != "":
		return
	var script = null
	if res_path(path) and path.get_extension() == "gd" and on_disk(path):
		script = load(path)
	var fits: bool = script is GDScript and script.can_instance()
	if fits and ClassDB.is_parent_class(object.get_class(), script.get_instance_base_type()):
		var base = script
		while base is Script and fits:
			fits = scene_source(base.resource_path)
			base = base.get_base_script()
	else:
		fits = false
	if fits:
		object.set_script(script)
	else:
		_fail("the script %s on a %s" % [path, object.get_class()])


func _apply(object: Object, properties: Array) -> void:
	if properties.size() % 2 != 0:
		_fail("malformed properties")
	var names := _storage(object)
	for j in range(0, properties.size(), 2):
		if why != "":
			return
		var name = properties[j]
		var value = _decode(properties[j + 1], 0)
		if typeof(name) != TYPE_STRING or name in ["script", NOT_SENT]:
			_fail("the property %s" % [name])
			return
		if not names.has(name):
			names = _storage(object)  # one that comes with an earlier one (a shader's parameters)
		var animation: bool = object is AnimationPlayer and name.begins_with("anims/")
		if why == "" and not names.has(name) and not (animation and value is Animation):
			_fail("the property %s of a %s" % [name, object.get_class()])
		if why == "":
			object.set(name, value)


static func _storage(object: Object) -> Dictionary:
	var names := {}
	for property in object.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE:
			names[property.name] = true
	return names


func _connect_signal(entry) -> void:
	if not _shaped(entry, [TYPE_INT, TYPE_STRING, TYPE_INT, TYPE_STRING, TYPE_INT]):
		_fail("a malformed connection")
		return
	var count := _nodes.size()
	if entry[0] < 0 or entry[0] >= count or entry[2] < 0 or entry[2] >= count:
		_fail("a malformed connection")
		return
	var source: Node = _nodes[entry[0]]
	var target: Node = _nodes[entry[2]]
	if not source.has_signal(entry[1]) or not _script_methods(target).has(entry[3]):
		_fail("the connection %s to %s" % [entry[1], entry[3]])
	elif entry[4] & ~CONNECT_FLAGS:
		_fail("the connection flags %d" % entry[4])
	elif not source.is_connected(entry[1], target, entry[3]):
		source.connect(entry[1], target, entry[3], [], entry[4] | CONNECT_PERSIST)


# The methods of the object's script and the scripts it extends, none of its class's own.
static func _script_methods(object: Object) -> Dictionary:
	var names := {}
	var script = object.get_script()
	while script is Script:
		for method in script.get_script_method_list():
			if not ClassDB.class_has_method(object.get_class(), method.name):
				names[method.name] = true
		script = script.get_base_script()
	return names


func _decode(encoded, depth: int):
	_values += 1
	if why != "" or _values > MAX_VALUES or depth > MAX_DEPTH:
		_fail("more than %d values or %d levels" % [MAX_VALUES, MAX_DEPTH])
		return null
	match typeof(encoded):
		TYPE_ARRAY:
			return _decode_tagged(encoded, depth)
		TYPE_DICTIONARY:
			_fail("a dictionary outside a tag")
		TYPE_OBJECT, TYPE_RID:
			_fail("an object")
		TYPE_NODE_PATH:
			for n in encoded.get_name_count():
				if encoded.get_name(n) == "..":
					_fail("the node path %s" % encoded)
			if encoded.is_absolute():
				_fail("the node path %s" % encoded)
	return encoded


func _decode_tagged(encoded: Array, depth: int):
	var payload = encoded[1] if encoded.size() == 2 else null
	var tag = encoded[0] if encoded.size() == 2 else -1
	if tag is int and tag == Tag.ARRAY and payload is Array:
		var items := []
		for item in payload:
			items.append(_decode(item, depth + 1))
		return items
	if tag is int and tag == Tag.DICTIONARY and payload is Array and payload.size() % 2 == 0:
		var pairs := {}
		for j in range(0, payload.size(), 2):
			pairs[_decode(payload[j], depth + 1)] = _decode(payload[j + 1], depth + 1)
		return pairs
	if tag is int and tag == Tag.PATH and payload is String:
		return _by_path(payload)
	if tag is int and tag == Tag.INLINE and payload is int:
		if payload >= 0 and payload < _resources.size():
			return _resources[payload]
	_fail("a malformed value")
	return null


# A resource this game loads itself: a file (or its import or remap) or one in its cache; one
# inside a file ("<file>::<id>") once that file is loaded.
func _by_path(path: String) -> Resource:
	if _paths.has(path):
		return _paths[path]
	var parts := path.split("::")
	var file: String = parts[0]
	var ok := _paths.size() < MAX_PATHS and parts.size() <= 2 and res_path(file)
	ok = ok and file.get_extension() in PATH_EXTENSIONS and ResourceLoader.exists(file)
	if parts.size() == 2:
		ok = ok and parts[1].is_valid_integer()
	var resource: Resource = load(file) if ok else null
	if resource != null and parts.size() == 2:
		_files.append(resource)  # holds the file's inner resources while they are taken
		resource = load(path) if ResourceLoader.has_cached(path) else null
	if (resource is PackedScene or resource is Animation) and not scene_source(file):
		resource = null
	if resource == null:
		_fail("the resource %s" % path)
	_paths[path] = resource
	return resource


func _shaped(entry, types: Array) -> bool:
	if typeof(entry) != TYPE_ARRAY or entry.size() != types.size():
		return false
	for i in types.size():
		if typeof(entry[i]) != types[i]:
			return false
	return true


# A res:// path in its plain form: no "..", ".", "//", "\" or ":" past the prefix.
static func res_path(path: String) -> bool:
	if not path.begins_with("res://") or ":" in path.substr(6):
		return false
	return path.simplify_path() == path and path.length() > 6


static func scene_source(path: String) -> bool:
	if path in SCENE_FILES:
		return true
	if path.get_file() == "mod_main.gd":
		return false
	for root in NOT_SCENE_ROOTS:
		if path.begins_with(root):
			return false
	for root in SCENE_ROOTS:
		if path.begins_with(root):
			return true
	return false


# A file at the path, or the .remap an exported game puts there instead (a converted scene, a
# compiled script).
static func on_disk(path: String) -> bool:
	var file := File.new()
	return file.file_exists(path) or file.file_exists(path + ".remap")
