extends Reference
# A weapon that attacks with its own animation (AnimatedHitboxShootingBehavior: whip, flail),
# sync/feedback_mirror.gd EVENT_WEAPON_ANIM: the event's wire format, the host sending one per
# attack, the client's puppet weapon playing the lash. Part of the feedback suite
# (feedback_tests.gd); checks go through the test mod's _check.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const WHIP := "res://weapons/melee/whip/1/whip_data.tres"
const RECORD_MSEC := 700  # the lash lasts 0.48 s

var _t: Node


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node):
	_test_wire()
	yield(_test_battle(together), "completed")


func _test_wire() -> void:
	var view: Dictionary = SnapshotTests.new(_t).scenario(2, 12, 6, 4, 2, 2, 2, 1, true)
	view.events = []
	var plain := Snapshot.encode(view).size()
	view.events = [[Snapshot.EVENT_WEAPON_ANIM, 1, 5, 0.125]]
	var bytes := Snapshot.encode(view)
	var events: Array = Snapshot.parse(bytes).get("events", [])
	_t._check(
		events.size() == 1 and events[0] == [Snapshot.EVENT_WEAPON_ANIM, 1, 5, 0.125],
		"a weapon animation event survives the round trip, 5 B (%d) %s" % [bytes.size() - plain, events]
	)
	for bad in [[9, 0], [0, 200]]:
		view.events = [[Snapshot.EVENT_WEAPON_ANIM, bad[0], bad[1], 0.0]]
		_t._check(Snapshot.parse(Snapshot.encode(view)).empty(), "rejected: player / weapon %s" % [bad])


# Player 0's last weapon is a whip that attacks once on the host.
func _test_battle(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	# Without the DLC the game's weapon list has no whip, and the client's run would drop it.
	var whip_data: Resource = load(WHIP)
	var known: Array = ItemService.weapons
	var borrowed := not known.has(whip_data)
	if borrowed:
		known.append(whip_data)
	RunData.add_weapon(whip_data, 0)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	_t.get_tree().change_scene("res://main.tscn")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	host._start_battle(main)
	var slot: int = main._players[0].current_weapons.size() - 1
	var whip: Node = main._players[0].current_weapons[slot]
	_t._check(whip is WhipWeapon, "the host's player holds the whip")
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var sent := []
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < RECORD_MSEC:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		if recorded.size() == 2:
			whip._shooting_behavior.shoot(100.0)  # what Weapon does when a target is in range
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		for event in Snapshot.parse(recorded[-1][1]).events:
			if event[0] == Snapshot.EVENT_WEAPON_ANIM:
				sent.append(event)
	_t._check(
		sent.size() == 1 and sent[0][1] == 0 and sent[0][2] == slot and sent[0][3] < 0.1,
		"one event per attack, naming player and weapon %s" % [sent]
	)
	var host_animation: Animation = whip.get_node("AnimationPlayer").get_animation("lash")
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var puppets: Array = client._main._players[0].current_weapons
	_t._check(puppets.size() == slot + 1, "the client's player holds it too")
	if puppets.size() != slot + 1:
		client._leave_battle()
		Puppet.set_active(false)
		host.set_process(true)
		return
	var puppet: Node = puppets[slot]
	var player: AnimationPlayer = puppet.get_node("AnimationPlayer")
	var lash: Sprite = puppet.get_node("Sprite/Hitbox/Lash")
	var rest: Texture = puppet.sprite.texture
	var seen := {"playing": false, "lash": false, "frame": false}
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(_t.get_tree(), "idle_frame")
			seen.playing = seen.playing or player.current_animation == "lash"
			seen.lash = seen.lash or lash.visible
			seen.frame = seen.frame or puppet.sprite.texture != rest
		client._on_snapshot(snap)
	yield(_t.get_tree().create_timer(0.7), "timeout")
	_t._check(seen.playing, "the puppet whip plays its lash")
	_t._check(seen.lash and seen.frame, "with the lash out and the sprite's frames %s" % [seen])
	_t._check(
		not lash.visible and puppet.sprite.texture == rest and not player.is_playing(),
		"and is at rest again afterwards"
	)
	var tracks := 0
	var puppet_animation: Animation = player.get_animation("lash")
	for i in puppet_animation.get_track_count():
		tracks += 1 if puppet_animation.track_get_type(i) == Animation.TYPE_METHOD else 0
	_t._check(
		tracks == 0 and puppet_animation != host_animation,
		"without the track that opens the hitbox; the game's animation is untouched"
	)
	_t._check(not client._feedback.lash(client._main, 0, 0, 0.0), "a pistol has no lash to play")
	_t._check(not client._feedback.lash(client._main, 3, 9, 0.0), "nor a weapon that is not there")
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)
	if borrowed:
		known.erase(whip_data)
