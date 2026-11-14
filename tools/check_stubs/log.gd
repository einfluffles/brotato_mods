# Parse-check stub for res://addons/mod_loader/api/log.gd (the real one needs the ModLoaderStore autoload,
# which isn't registered when Godot runs with --check-only). Mirrors the public static API we use.
class_name ModLoaderLog
extends Object


static func fatal(_message: String, _mod_name: String, _only_once := false) -> void:
	pass


static func error(_message: String, _mod_name: String, _only_once := false) -> void:
	pass


static func warning(_message: String, _mod_name: String, _only_once := false) -> void:
	pass


static func info(_message: String, _mod_name: String, _only_once := false) -> void:
	pass


static func success(_message: String, _mod_name: String, _only_once := false) -> void:
	pass


static func debug(_message: String, _mod_name: String, _only_once := false) -> void:
	pass
