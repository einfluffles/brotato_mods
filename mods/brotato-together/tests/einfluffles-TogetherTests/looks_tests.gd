extends Reference
# Lasting looks of entities and puddles (sync/looks.gd, sync/puddles.gd): the looks section of the
# wire format, the host's sparse sending, the client's resolve with expiry, then a host battle
# replayed on a client.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const HitNumbers := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/hit_numbers.gd")
const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Looks := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/looks.gd")
const Puddles := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/puddles.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const FacingTests := preload("res://mods-unpacked/einfluffles-TogetherTests/facing_tests.gd")
const ENEMY := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
const BULLET := "res://projectiles/bullet_enemy/enemy_projectile.tscn"
const CHARM := "res://effect_behaviors/enemies/charm_enemy_effect_behavior.tscn"
const CURSE := "res://effect_behaviors/enemies/curse_enemy_effect_behavior.tscn"
const RECORD_MSEC := 1500
const FIRE_LIFETIME := 1.0  # s: the fire puddle starts to fade during the recording
const EXPLOSION := "res://projectiles/explosion.tscn"
const ARSONIST_FIRE := "res://items/characters/arsonist/arsonist_effect_explosion_fire.tres"

var _t: Node
var _facing = null  # kept alive across its yields


func run(test_mod: Node, together: Node):
	_t = test_mod
	_test_wire()
	_test_sizes()
	_test_host_sparse()
	_test_resolve()
	yield(_test_battle(together), "completed")
	_facing = FacingTests.new(_t)
	yield(_facing.run(together), "completed")


func _test_wire() -> void:
	_t._check(Looks.ALL == Snapshot.LOOK_BITS, "every look bit is accepted by the parser")
	var view: Dictionary = SnapshotTests.new(_t).scenario(2, 12, 6, 4, 2, 4, 3, 2, true)
	var plain := Snapshot.encode(view)
	_t._check(plain[-2] == 0 and not Snapshot.parse(plain).empty(), "no looks: one count byte")
	var last: int = view.ids.size() - 1
	view["looks"] = {
		0: Looks.CHARMED | Looks.CURSED,
		5: Looks.BURNING | Looks.BURN_BLUE,
		last: Looks.BOOSTED | Looks.MECA,
		3: Looks.MUTANT,
		7: 0,
	}
	var parsed := Snapshot.parse(Snapshot.encode(view))
	_t._check(
		not parsed.empty() and _same(parsed.get("looks", {}), view.looks),
		"looks survive the round trip %s" % [parsed.get("looks")]
	)
	var broken := view.duplicate(true)  # no unknown bit is left to reject: a byte holds eight
	broken.looks = {view.ids.size(): Looks.BURNING}
	_t._check(Snapshot.parse(Snapshot.encode(broken)).empty(), "look index out of range rejected")


# A late wave with a burn build: 100 burning enemies and 5 charmed ones, the turn they all
# change, and the snapshots after it (only refreshes).
func _test_sizes() -> void:
	var view: Dictionary = SnapshotTests.new(_t).scenario(4, 150, 90, 50, 10, 30, 6, 8, true)
	view.events = HitNumbers.select_events(view.events, 48)
	var plain := Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size()
	var looks := Looks.new()
	var sizes := []
	for count in Looks.REFRESH * 3:
		for i in 105:
			var look := Looks.CHARMED if i < 5 else Looks.BURNING | Looks.BURN_RED
			looks._capture_look(look, view.ids[i], i, count)
		view["looks"] = looks.end_snapshot()
		sizes.append(Protocol.encode(Protocol.Msg.SNAPSHOT, Snapshot.encode(view)).size())
	var steady := 0
	for k in range(Looks.REPEAT, sizes.size()):
		steady += sizes[k]
	steady /= sizes.size() - Looks.REPEAT
	print(
		(
			"  info: late wave, 105 looked enemies: plain %d B, on change %d B, after it %d B avg"
			% [plain, sizes[0], steady]
		)
	)
	# + up to 3 B: var2bytes pads byte arrays to 4 B
	_t._check(sizes[0] - plain <= 2 * 105 + 4, "a changed look costs 2 B per entity")
	_t._check(
		steady - plain <= 2 * (105 / Looks.REFRESH + 1) + 4, "a lasting look costs ~0.2 B per entity"
	)


func _test_host_sparse() -> void:
	var looks := Looks.new()
	var sent := {"charmed": [], "plain": [], "ended": []}
	var ids := {"charmed": 7, "plain": 8, "ended": 9}
	for count in 40:
		var states := {
			"charmed": Looks.CHARMED,
			"plain": 0,
			"ended": Looks.BURNING if count < 20 else 0,
		}
		var index := 0
		for name in states:
			looks._capture_look(states[name], ids[name], index, count)
			index += 1
		var section: Dictionary = looks.end_snapshot()
		index = 0
		for name in states:
			if section.has(index):
				sent[name].append(count)
			index += 1
	_t._check(sent.plain.empty(), "a plain entity is never sent")
	_t._check(
		sent.charmed.slice(0, 3) == [0, 1, 2, 3] and sent.charmed.size() == 4 + 3,
		"a lasting look: on change, then every %d snapshots %s" % [Looks.REFRESH, sent.charmed]
	)
	_t._check(
		[20, 21, 22, 23] == sent.ended.slice(sent.ended.size() - 4, sent.ended.size() - 1),
		"an ended look is sent as plain for %d snapshots %s" % [Looks.REPEAT, sent.ended]
	)
	var enemy: Node = load(ENEMY).instance()  # not in the tree: only what look_of reads
	enemy._outline_colors = [Utils.CURSE_COLOR, Utils.BOOST_COLOR, Color.red]
	_t._check(
		looks.look_of(enemy) == Looks.CURSED | Looks.BOOSTED, "look read from the game's outlines"
	)
	enemy.free()


func _test_resolve() -> void:
	var cache := {}
	var first := _view(100, [5, 6, 7], {0: Looks.CHARMED, 2: Looks.BURNING})
	Looks.resolve(first, cache)
	_t._check(
		_same(first.looks_by_id, {5: Looks.CHARMED, 7: Looks.BURNING}), "looks resolved by net id"
	)
	var late := _view(50, [5, 6, 7], {0: 0})  # older than the cache: does not undo the charm
	Looks.resolve(late, cache)
	var next := _view(133, [5, 6, 7], {2: 0})
	Looks.resolve(next, cache)
	_t._check(
		_same(next.looks_by_id, {5: Looks.CHARMED}), "kept while not sent, plain when sent so"
	)
	var t := 133
	for _i in Looks.EXPIRE_SNAPSHOTS:
		t += 33
		Looks.resolve(_view(t, [5, 6, 7], {}), cache)
	var kept := _view(t + 33, [5, 6, 7], {})
	Looks.resolve(kept, cache)
	_t._check(
		kept.looks_by_id.empty() and cache.looks.empty(),
		"a look never confirmed for %d snapshots expires" % Looks.EXPIRE_SNAPSHOTS
	)


func _view(t: int, ids: Array, looks: Dictionary) -> Dictionary:
	return {"t": t, "ids": PoolIntArray(ids), "looks": looks}


# Dictionaries compare by reference in Godot 3.
static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key) or b[key] != a[key]:
			return false
	return true


func _test_battle(together: Node):
	var host: Node = together.battle_host
	var client: Node = together.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	var charmed_before: Array = RunData.current_charmed_enemies.duplicate()
	_t.get_tree().change_scene("res://main.tscn")
	yield(_t.get_tree(), "idle_frame")
	yield(_t.get_tree(), "idle_frame")
	var main := _t.get_tree().current_scene
	host._start_battle(main)
	var nodes := _spawn_looks(main)
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	var recorded := []
	var ids := {}  # from the first snapshot: the fire puddle loses its id when it is pooled
	var t0 := OS.get_ticks_msec()
	while OS.get_ticks_msec() - t0 < RECORD_MSEC:
		yield(_t.get_tree().create_timer(1.0 / 30.0), "timeout")
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		if ids.empty():
			for name in nodes:
				var node: Node = nodes[name]
				ids[name] = node.get_meta(host.NET_ID_META) if node.has_meta(host.NET_ID_META) else -1
	var host_values := _host_values(nodes)
	_measure_capture(nodes)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	var seen_fire := _check_host_snapshots(recorded, ids, start.types)

	client._on_battle_start(start)
	yield(client, "battle_entered")
	var puppet_main: Node = client._main
	var fire_puppet = null
	var replay_start := OS.get_ticks_msec()
	for msg in recorded:
		var snap := SnapshotTests.retimed(msg, recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(_t.get_tree(), "idle_frame")
		client._on_snapshot(snap)
		var node = client._entities.get(seen_fire)
		fire_puppet = node if node != null else fire_puppet
		var playing := 0  # sampled: explosion puppets pool themselves when "explode" ends
		for child in puppet_main._explosions.get_children():
			playing += 1 if child is PlayerExplosion else 0
		host_values["client_explosions"] = int(max(host_values.get("client_explosions", 0), playing))
	yield(_t.get_tree().create_timer(0.3), "timeout")
	client.set_process(false)
	var puppets := {}
	for name in nodes:
		puppets[name] = client._entities.get(ids[name])
	puppets.erase("fire")
	_t._check(not (null in puppets.values()), "client mirrors the looks test entities")
	if not (null in puppets.values()):
		_check_puppets(client, puppets, host_values)
		_check_puddle_puppets(puppet_main, puppets, host_values)
		_check_fire_puddle(client, fire_puppet)
		_check_blast_fire(client, puppet_main, puppets, host_values)
		_check_reset(client, puppets)
	client.set_process(true)
	client._leave_battle()
	Puppet.set_active(false)
	host.set_process(true)
	RunData.current_charmed_enemies = charmed_before


# Each look is made by the game's own code where it is cheap to reach; the shot gets the charm
# material like ShootingAttackBehavior.spawn_projectile does. Far from the players, weapons off.
func _spawn_looks(main: Node) -> Dictionary:
	for player in main.get("_players"):
		player._weapons_container.propagate_call("set_physics_process", [false])
		player._weapons_container.propagate_call("set_process", [false])
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var corner := zone.position + Vector2(120, 120)
	var spawner = main.get("_entity_spawner")
	var nodes := {}
	var k := 0
	for name in ["charmed", "burning", "cursed", "boosted", "plain"]:
		nodes[name] = _t._spawn_on_host(
			spawner, ENEMY, EntityType.ENEMY, corner + Vector2(90 * k, 0)
		)
		nodes[name].propagate_call("set_physics_process", [false])  # parked
		k += 1
	var charm: Node = load(CHARM).instance().init(nodes.charmed)
	nodes.charmed.effect_behaviors.add_child(charm)
	charm.charm(0)
	var burn := BurningData.new()
	burn.chance = 1.0
	burn.damage = 1
	burn.duration = 10
	burn.scaling_stats = [[Keys.stat_engineering_hash, 1.0]]  # blue flames
	nodes.burning.apply_burning(burn)
	var curse: Node = load(CURSE).instance()
	nodes.cursed.effect_behaviors.add_child(curse.init(nodes.cursed))
	var curse_boost := BoostArgs.new()  # what CurseSceneEffectBehavior adds: no outline
	curse_boost.show_outline = false
	nodes.cursed.boost(curse_boost)
	nodes.boosted.can_be_boosted = true
	nodes.boosted.boost(BoostArgs.new())
	var bullet_scene: PackedScene = load(BULLET)
	nodes["bullet"] = bullet_scene.instance()
	if not main._pool.has(bullet_scene.get_instance_id()):
		main._pool[bullet_scene.get_instance_id()] = []
	nodes.bullet.set_meta("pool_id", bullet_scene.get_instance_id())
	main.add_enemy_projectile(nodes.bullet)
	nodes.bullet.global_position = corner + Vector2(0, 200)
	var shot_material: ShaderMaterial = charm.projectile_shader.duplicate()
	shot_material.set_shader_param("hue", Utils.CHARM_COLOR.h)
	nodes.bullet.set_sprite_material(shot_material)
	var gpe = main._gpe_spawner
	nodes["acid"] = gpe.get_new_acid_puddle_at_pos(corner + Vector2(0, 400), false, false)
	nodes["petrol"] = gpe.get_new_petrol_puddle_at_pos(corner + Vector2(300, 400), false, true)
	nodes["fire"] = gpe.get_new_fire_puddle_at_pos(
		corner + Vector2(600, 400), BurningData.new(), Vector2(1.5, 1.5), FIRE_LIFETIME
	)
	var blast_fire = _explode_with_fire(main, corner + Vector2(900, 400))
	_t._check(blast_fire != null, "an arsonist's explosion leaves a fire puddle on the host")
	if blast_fire != null:
		nodes["blast_fire"] = blast_fire
	return nodes


# The game's own GPESpawner call puts the puddle down (the arsonist's fire_explosion effect). The
# explosion reaches clients as EVENT_EXPLOSION, whose puppet must not put down one of its own.
func _explode_with_fire(main: Node, position: Vector2) -> Node:
	var effects: Array = RunData.get_player_effect(Keys.fire_explosion_hash, 0)
	var fire_effect: Resource = load(ARSONIST_FIRE)
	effects.append(fire_effect)
	var scene: PackedScene = load(EXPLOSION)
	if not main._pool.has(scene.get_instance_id()):
		main._pool[scene.get_instance_id()] = []
	var explosion: Node = scene.instance()
	main.add_explosion(explosion)
	explosion.pool_id = scene.get_instance_id()  # end_explosion pools it
	explosion.global_position = position
	explosion.player_index = 0
	explosion.start_explosion()
	effects.erase(fire_effect)
	for child in main._fire_puddles_container.get_children():
		if child is FirePuddle and child.is_active() and child.global_position == position:
			return child
	return null


# What looks add to the host's snapshot of a late wave: 600 entities, nearly all plain.
func _measure_capture(nodes: Dictionary) -> void:
	var looks := Looks.new()
	var start := OS.get_ticks_usec()
	for i in 600:
		looks.capture(nodes.plain, 1000 + i, i, 0, true, true)
	var plain_usec := OS.get_ticks_usec() - start
	start = OS.get_ticks_usec()
	for i in 600:
		looks.capture(nodes.burning, 2000 + i, i, 0, true, true)
	var looked_usec := OS.get_ticks_usec() - start
	looks.end_snapshot()
	print(
		(
			"  info: looks capture of 600 entities: plain %.2f ms, all burning %.2f ms"
			% [plain_usec / 1000.0, looked_usec / 1000.0]
		)
	)


func _host_values(nodes: Dictionary) -> Dictionary:
	var values := {}
	for name in ["acid", "petrol"]:
		values[name + "_texture"] = nodes[name].sprite.texture
		values[name + "_scale"] = nodes[name]._target_scale
	if nodes.has("blast_fire"):
		values["blast_fire_scale"] = nodes.blast_fire._target_scale
	values["burn_ramp"] = nodes.burning._burning_particles.color_ramp
	values["blue"] = nodes.burning._burning_particles.blue_gradient
	return values


# Returns the fire puddle's net id.
func _check_host_snapshots(recorded: Array, ids: Dictionary, types: Dictionary) -> int:
	var cache := {}
	var entries := 0
	var looks_bytes := 0
	var fire_seen := false
	var last := {}
	for msg in recorded:
		last = Snapshot.parse(msg[1])
		entries += last.looks.size()
		looks_bytes += 2 * last.looks.size()
		fire_seen = fire_seen or Snapshot.index_of(last, ids.fire) >= 0
		Looks.resolve(last, cache)
	var expected := {
		"charmed": Looks.CHARMED,
		"burning": Looks.BURNING | Looks.BURN_BLUE,
		"cursed": Looks.CURSED,
		"boosted": Looks.BOOSTED,
		"bullet": Looks.CHARMED,
	}
	var actual := {}
	for name in expected:
		actual[name] = last.looks_by_id.get(ids[name], 0)
	print(
		(
			"  info: looks: %d snapshots, %d look entries (%d B, %.1f B per snapshot), %d entities"
			% [recorded.size(), entries, looks_bytes, looks_bytes / float(recorded.size()),
			last.ids.size()]
		)
	)
	_t._check(_same(actual, expected), "host sends the looks %s" % [actual])
	_t._check(not last.looks_by_id.has(ids.plain), "the plain enemy has no look")
	var refreshes: int = recorded.size() / Looks.REFRESH + 2
	_t._check(
		entries <= expected.size() * (Looks.REPEAT + refreshes),
		"looks sent sparsely (%d entries for %d looked entities)" % [entries, expected.size()]
	)
	var puddle_types := []
	for idx in types:
		if "#" + Puddles.TAG in types[idx]:
			puddle_types.append(types[idx].get_file())
	puddle_types.sort()
	# acid, petrol, fire at 1.5 and the explosion's fire at its own size
	_t._check(puddle_types.size() == 4, "one puddle type per source %s" % [puddle_types])
	_t._check(
		Snapshot.index_of(last, ids.acid) >= 0 and Snapshot.index_of(last, ids.petrol) >= 0,
		"acid and petrol puddles in the snapshot"
	)
	_t._check(
		fire_seen and Snapshot.index_of(last, ids.fire) < 0,
		"the fire puddle left the snapshots when it began to fade"
	)
	return ids.fire


func _check_puppets(client: Node, puppets: Dictionary, host_values: Dictionary) -> void:
	var charmed: Node = puppets.charmed
	var material = charmed.sprite.material
	if material == charmed.flash_mat:  # a replayed hit is flashing
		material = charmed._non_flash_material
	# Not the shader params: get_shader_param asks the VisualServer, null when headless.
	_t._check(
		(
			charmed._outline_colors == [Utils.CHARM_COLOR]
			and material is ShaderMaterial
			and material.shader == charmed.outline_material.shader
			and is_equal_approx(charmed._current_material_alpha, Looks.CHARM_ALPHA)
			and charmed.sprite.self_modulate == Color.white
		),
		"charmed puppet has the charm outline, faded (%s)" % [material]
	)
	_t._check(
		charmed.effect_behaviors.get_child_count() == 0 and charmed.collision_layer == 0,
		"charmed puppet runs no charm (no behavior, no collisions)"
	)
	var particles = puppets.burning._burning_particles
	var blue: bool = host_values.burn_ramp == host_values.blue
	_t._check(
		particles.emitting and particles.color_ramp == host_values.burn_ramp,
		"burning puppet burns with the host's flames (blue: %s)" % blue
	)
	_t._check(
		puppets.burning._burning == null and puppets.burning._burning_timer.is_stopped(),
		"burning puppet takes no burn damage"
	)
	var curse = puppets.cursed.get_node_or_null(Looks.CURSE_NODE)
	_t._check(
		puppets.cursed._outline_colors == [Utils.CURSE_COLOR] and curse != null,
		"cursed puppet: curse outline (not boosted's) and particles"
	)
	if curse != null:
		_t._check(
			curse.get_script() == null and curse.get_node_or_null("CurseParticles") != null,
			"curse particles without the curse's script"
		)
	_t._check(puppets.boosted._outline_colors == [Utils.BOOST_COLOR], "boosted puppet outlined")
	_t._check(
		puppets.plain._outline_colors.empty() and not puppets.plain._burning_particles.emitting,
		"plain puppet stays plain"
	)
	var shot = puppets.bullet._sprite.material
	_t._check(
		shot is ShaderMaterial and shot == client._looks._charm_material,
		"charmed enemy's shot has the charm hue"
	)


func _check_puddle_puppets(puppet_main: Node, puppets: Dictionary, host_values: Dictionary) -> void:
	for name in ["acid", "petrol"]:
		var puddle: Node = puppets[name]
		_t._check(
			(
				puddle.get_parent() == puppet_main._gpe_container
				and puddle.sprite.texture == host_values[name + "_texture"]
				and puddle._target_scale.distance_to(host_values[name + "_scale"]) < 0.01
			),
			"%s puddle: the host's sprite and size (%s)" % [name, puddle._target_scale]
		)
		_t._check(
			(
				puddle.collision_layer == 0
				and puddle.collision_mask == 0
				and not puddle.monitoring
				and puddle._lifetime_timer.is_stopped()
			),
			"%s puddle puppet hurts nobody and never times out itself" % name
		)


func _check_fire_puddle(client: Node, fire) -> void:
	_t._check(fire != null, "fire puddle mirrored while it lasted")
	if fire == null:
		return
	var pooled := false
	for pool in client._puppet_pool.values():
		pooled = pooled or fire in pool
	_t._check(
		(fire._is_dying and fire.is_inside_tree()) or pooled,
		"fire puddle puppet fades, then goes to the pool (pooled: %s)" % pooled
	)


# The explosion's fire puddle arrives as a puppet like any other; the client's explosion puppet
# (FeedbackMirror.explode never calls start_explosion) adds none: every puddle there is a puppet.
func _check_blast_fire(client: Node, puppet_main: Node, puppets: Dictionary, values: Dictionary):
	if not puppets.has("blast_fire"):
		return
	var explosions: int = values.get("client_explosions", 0)
	_t._check(explosions > 0, "the client played the host's explosion")
	var puddle: Node = puppets.blast_fire
	_t._check(
		(
			puddle.get_parent() == puppet_main._fire_puddles_container
			and puddle._target_scale.distance_to(values.blast_fire_scale) < 0.01
		),
		"blast fire puddle mirrored (%s, %d explosions)" % [puddle._target_scale, explosions]
	)
	var local := 0
	for container in [puppet_main._fire_puddles_container, puppet_main._gpe_container]:
		for child in container.get_children():
			if Puddles.is_puddle(child) and not child.has_meta(client.PUPPET_TYPE_META):
				local += 1
	_t._check(local == 0, "no local puddles on the client (%d)" % local)


func _check_reset(client: Node, puppets: Dictionary) -> void:
	var charmed: Node = puppets.charmed
	charmed.flash()  # a hit lands while the look changes
	client._looks.set_look(charmed, Looks.CHARMED | Looks.BOOSTED)
	_t._check(
		(
			charmed.sprite.material == charmed.flash_mat
			and charmed._non_flash_material is ShaderMaterial
			and charmed._outline_colors.size() == 2
		),
		"a look change during a hit flash lands after the flash"
	)
	for name in ["charmed", "burning", "cursed", "boosted", "bullet"]:
		client._looks.set_look(puppets[name], 0)
	charmed._on_FlashTimer_timeout()
	_t._check(
		charmed._outline_colors.empty() and charmed.sprite.material == null,
		"charm look removed"
	)
	charmed.flash_shield()
	client._looks.set_look(charmed, Looks.CHARMED)
	var shielded: bool = charmed.sprite.material == charmed.flash_shield_mat
	charmed._on_FlashTimer_timeout()
	_t._check(
		shielded and charmed.sprite.material is ShaderMaterial,
		"a look change during a shield flash lands after the flash"
	)
	client._looks.set_look(charmed, 0)
	_t._check(not puppets.burning._burning_particles.emitting, "flames stopped")
	_t._check(puppets.cursed.get_node_or_null(Looks.CURSE_NODE) == null, "curse particles removed")
	_t._check(
		puppets.bullet._sprite.material != client._looks._charm_material, "shot material restored"
	)
