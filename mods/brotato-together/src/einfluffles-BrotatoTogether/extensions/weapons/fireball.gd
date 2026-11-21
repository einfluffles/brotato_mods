extends "res://weapons/ranged/fireball/fireball.gd"
# Game bug: a cursed weapon's Weapon._ready frees everything in Sprite/Muzzle for its curse
# particles, Molotov's BurningParticles too, which RangedWeapon.on_projectile_shot then hides and
# shows by path on every throw: two get_node errors per throw in the log. Fireball's own script
# serves Molotov.


# Runs after the game's _ready (Godot 3 calls _ready on every script level, base first).
func _ready() -> void:
	if not is_cursed:
		return
	var kept := []
	for path in throwned_projectile_hide:
		var node := get_node_or_null(path)
		if node != null and not node.is_queued_for_deletion():
			kept.append(path)
	throwned_projectile_hide = kept
