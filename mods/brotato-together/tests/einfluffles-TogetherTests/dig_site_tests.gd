extends Reference
# Suite dig_site: archaeologist dig sites. The client shows the host's sites where the host has
# them (not its own random ones), and the dig as the host digs it: progress sprite, particles,
# the body_enter squash, the dig sound, dug up. Its own players never dig a site of the host's.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const BattleScene := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_scene.gd")

const SITES := 2
const DIG_TIME := 0.8  # s, instead of the scene's 5 to 6

var t: Node


func _init(test_mod: Node) -> void:
	t = test_mod


func run(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	var tree := t.get_tree()
	host.set_process(false)
	var effects: Dictionary = RunData.players_data[0].effects
	var saved = effects.get(Keys.dig_sites_hash, 0)
	effects[Keys.dig_sites_hash] = SITES
	tree.change_scene("res://main.tscn")
	yield(tree, "idle_frame")
	yield(tree, "idle_frame")
	var main := tree.current_scene
	host._start_battle(main)
	var sites := BattleScene.dig_sites(main)
	t._check(sites.size() == SITES, "host wave has %d dig sites (%d)" % [SITES, sites.size()])
	if sites.size() != SITES:
		effects[Keys.dig_sites_hash] = saved
		host._end_battle()
		host.set_process(true)
		return
	var dug: Node = sites[0]
	dug.dig_time = DIG_TIME
	var positions := []
	for site in sites:
		positions.append(site.global_position)

	var msgs := [_snapshot(host)]  # nobody digs yet
	var player: Node = main.get("_players")[0]
	player.global_position = dug.global_position
	var waited := 0.0
	while dug.progress < DIG_TIME * 0.3 and waited < 2.0:
		yield(tree, "physics_frame")
		waited += 1.0 / Engine.iterations_per_second
	var mid_ratio: float = dug.get_progress_ratio()
	var mid_texture: Texture = dug._sprite.texture
	t._check(
		mid_ratio > 0.0 and mid_ratio < 1.0 and dug._dig_particles.emitting,
		"host player digs (%.2f)" % mid_ratio
	)
	msgs.append(_snapshot(host))
	waited = 0.0
	while not dug.dug_up and waited < 3.0:
		yield(tree, "physics_frame")
		waited += 1.0 / Engine.iterations_per_second
	t._check(dug.dug_up, "host dig site is dug up")
	msgs.append(_snapshot(host))
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	host._end_battle()
	effects[Keys.dig_sites_hash] = saved

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var cmain: Node = client._main
	t._check(BattleScene.dig_sites(cmain).empty(), "client drops the sites it rolled itself")
	yield(_feed(client, msgs[0], 3000), "completed")
	var shown := BattleScene.dig_sites(cmain)
	var at := []
	for site in shown:
		at.append(site.global_position)
	var same := shown.size() == SITES
	for position in positions:
		same = same and _near(at, position) != -1
	t._check(same, "client shows the host's dig sites where it has them (%s / %s)" % [at, positions])
	if not same:
		_leave(client, host)
		return
	var cdug: Node = shown[_near(at, positions[0])]
	var cother: Node = shown[_near(at, positions[1])]
	t._check(
		not cdug._dig_particles.emitting and cdug.get_progress_ratio() == 0.0,
		"an untouched site shows no dig"
	)

	yield(_feed(client, msgs[1], 2000), "completed")
	t._check(
		is_equal_approx(cdug.get_progress_ratio(), mid_ratio) and cdug._sprite.texture == mid_texture,
		"client shows the host's progress (%.2f of %.2f)" % [cdug.get_progress_ratio(), mid_ratio]
	)
	var anim: AnimationPlayer = cdug.get_node("%AnimationPlayer")
	t._check(
		cdug._dig_particles.emitting and anim.assigned_animation == "body_enter",
		"client plays the dig: particles and body_enter (%s)" % anim.assigned_animation
	)
	t._check(not cother._dig_particles.emitting, "the other site stays still")
	var audio: AudioStreamPlayer2D = cdug._dig_audio
	t._check(
		audio.playing and audio.stream in cdug.dig_sounds and not cother._dig_audio.playing,
		"client plays the dig sound at the site being dug (%s)" % audio.playing
	)

	yield(_feed(client, msgs[2], 1000), "completed")
	var last: Texture = cdug.textures[cdug.textures.size() - 1]
	t._check(
		cdug.dug_up and not cdug._dig_particles.emitting and cdug._sprite.texture == last,
		"client shows the site dug up"
	)
	t._check(cother.get_progress_ratio() == 0.0 and not cother.dug_up, "the other site is untouched")
	yield(_stand_on(cmain, cother), "completed")
	t._check(
		(
			cother.get_progress_ratio() == 0.0
			and not cother._dig_particles.emitting
			and cother._digging_players.empty()
			and not cother._dig_audio.playing
		),
		"a client player standing on a site of the host's leaves it untouched"
	)
	_leave(client, host)


func _snapshot(host: Node) -> Array:
	return bytes2var(var2bytes(host._build_snapshot()), false)


# Newest and already past the render delay: the client shows it as it is.
func _feed(client: Node, msg: Array, age_msec: int):
	var snap := Snapshot.parse(msg[1])
	snap.t = OS.get_ticks_msec() - age_msec
	client._on_snapshot(snap)
	for _i in 3:
		yield(t.get_tree(), "idle_frame")


# The client's players held on the site for a while: only the host digs.
func _stand_on(cmain: Node, site: Node):
	var players: Array = cmain.get("_players")
	for _i in 15:
		for player in players:
			if is_instance_valid(player):
				player.global_position = site.global_position
		yield(t.get_tree(), "physics_frame")


static func _near(at: Array, position: Vector2) -> int:
	for k in at.size():
		if at[k].distance_to(position) < 1.0:
			return k
	return -1


func _leave(client: Node, host: Node) -> void:
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)
