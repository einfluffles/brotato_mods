extends "res://ui/menus/global/focus_emulator.gd"
# Online, a grid several cursors share scrolls after this machine's own players only
# (ui/shared_scroll.gd); every other scroll is the game's.

const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")


func _ensure_control_visible(control: Control) -> void:
	var scroll = _find_parent_scroll_container(control)
	if scroll != null and not SharedScroll.follows(self, scroll):
		return
	._ensure_control_visible(control)
