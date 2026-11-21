extends "res://singletons/input_service.gd"
# The trade key's base action, before the game copies every action per device. The game wipes the
# InputMap (load_from_globals) whenever the gamepad movement setting changes.

const Hotkey := preload("res://mods-unpacked/einfluffles-BrotatoTrade/trade/hotkey.gd")


func _copy_device_actions():
	Hotkey.register()
	._copy_device_actions()
