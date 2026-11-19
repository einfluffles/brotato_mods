extends Reference
# Suites bullet_hell_*: in a bullet-hell wave, every visible enemy bullet on the host must be in
# the snapshot and mirrored.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")

var t: Node


func _init(test_mod: Node) -> void:
	t = test_mod


func run(together: Node, variant: String):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	RunData.constant_projectile = 2
	RunData.players_data[0].effects[Keys.bullet_hell_event_hash] = 1
	var saved_variants: Array = ZoneService.bullets_hell
	ZoneService.bullets_hell = [load("res://projectiles/bullet_hells/%s.tscn" % variant)]
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main := t.get_tree().current_scene
	host._start_battle(main)
	yield(t.get_tree().create_timer(5.0), "timeout")
	var visible := 0
	for node in _descendants(main.get("_enemy_projectiles")):
		if node is Projectile and node.is_visible_in_tree():
			visible += 1
	var msg: Array = bytes2var(var2bytes(host._build_snapshot()), false)
	var snap := Snapshot.parse(msg[1])
	var mirrored := 0
	for i in snap.ids.size():
		var path: String = host._types.keys()[host._types.values().find(snap.types[i])]
		mirrored += 1 if "bullet" in path or "projectile" in path else 0
	ZoneService.bullets_hell = saved_variants
	print("  info: %s: %d visible enemy bullets, %d in snapshot" % [variant, visible, mirrored])
	t._check(visible > 0, "%s spawned bullets" % variant)
	t._check(mirrored >= visible, "%s: all visible bullets in the snapshot" % variant)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	host._end_battle()

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var snap2 := Snapshot.parse(msg[1])
	snap2.t = OS.get_ticks_msec() - 1000
	client._on_snapshot(snap2)
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var client_visible := 0
	for node in _descendants(client._main.get("_enemy_projectiles")):
		if node is Projectile and node.is_visible_in_tree():
			client_visible += 1
	t._check(
		client_visible == visible,
		"%s: client shows the same bullets (%d/%d)" % [variant, client_visible, visible]
	)
	client._leave_battle()
	Puppet.set_active(false)
	RunData.constant_projectile = 0
	RunData.players_data[0].effects[Keys.bullet_hell_event_hash] = 0
	host.set_process(true)


func _descendants(node: Node) -> Array:
	var found := []
	for child in node.get_children():
		found.append(child)
		found += _descendants(child)
	return found
