extends "res://ui/menus/shop/shop_item.gd"
# Locking writes RunData right here, and BaseShop._input calls this directly for the lock
# shortcut: there is no signal in between to rewire. In a client's copy of the shop the host
# decides, so the request leaves as a signal instead. sync/shop_local.gd sends it for this
# client's own panel; nobody listens on the other panels, where it therefore does nothing.

signal lock_requested(shop_item, locked)

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")


func change_lock_status(button_pressed: bool) -> void:
	if Puppet.is_active():
		emit_signal("lock_requested", self, button_pressed)
		return
	.change_lock_status(button_pressed)
