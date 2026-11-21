extends Reference
# A cursed Molotov on the host: Weapon._ready frees what Sprite/Muzzle holds to put the curse
# particles there, BurningParticles too, which RangedWeapon.on_projectile_shot hides and shows by
# path on every throw (extensions/weapons/fireball.gd).

const MOLOTOV := "res://weapons/ranged/molotov/3/molotov_3_data.tres"
const BURNING := "Sprite/Muzzle/BurningParticles"

var _t: Node


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	var host: Node = together.battle_host
	host.set_process(false)
	var cursed: Resource = load(MOLOTOV).duplicate()
	cursed.is_cursed = true
	RunData.add_weapon(load(MOLOTOV), 0)
	RunData.add_weapon(cursed, 0)
	_t.get_tree().change_scene("res://main.tscn")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	host._start_battle(main)
	var weapons: Array = main._players[0].current_weapons
	var plain: Node = weapons[-2]
	var curse: Node = weapons[-1]
	yield(_t.get_tree(), "idle_frame")  # the curse's queue_free
	_t._check(
		curse.is_cursed and not curse.has_node(BURNING) and curse.muzzle.get_child_count() == 1,
		"the cursed Molotov's muzzle holds the curse particles only"
	)
	_t._check(curse.throwned_projectile_hide.empty(), "so it hides nothing when it throws")
	_t._check(
		plain.throwned_projectile_hide == [NodePath(BURNING)] and plain.has_node(BURNING),
		"the plain one still hides its burning particles"
	)
	for weapon in [plain, curse]:
		weapon._shooting_behavior.shoot(100.0)  # what Weapon does when a target is in range
	_t._check(
		not plain.get_node(BURNING).visible
		and plain.sprite.texture == plain.throwned_projectile_texture
		and curse.sprite.texture == curse.throwned_projectile_texture,
		"a throw shows both empty-handed, the plain one without its fire"
	)
	yield(_t.get_tree().create_timer(plain.throwned_texture_duration + 0.1), "timeout")
	_t._check(
		plain.get_node(BURNING).visible
		and plain.sprite.texture == plain.not_throwned_projectile_texture
		and curse.sprite.texture == curse.not_throwned_projectile_texture,
		"and both hold a bottle again afterwards"
	)
	host._end_battle()
	host.set_process(true)
