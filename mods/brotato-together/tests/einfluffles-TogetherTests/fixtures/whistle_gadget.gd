extends Node2D
# A mod's node that load()s a scene by a path in its data, as the game's Looter does with
# animation_whistle. It loads when the value is set, so a test sees what a path would run.

export(String, FILE) var effect = "" setget _set_effect


func _set_effect(value: String) -> void:
	effect = value
	var scene = load(value) if value != "" else null
	if scene is PackedScene:
		scene.instance().free()
