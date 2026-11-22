extends Reference
# Suite hit_numbers: damage and heal numbers on a client (sync/hit_numbers.gd). The wire format,
# the host's queue (carried over, two copies, a flood of hits) and the client's dedupe; then a host
# battle with a
# burst of 80 hits in one tick, a hit in an enemy's spawn tick, a hit on a pet, a hit and a heal on
# a player in one snapshot, a hit in a snapshot the client never gets and hits with an effect
# scale and a hitbox position, replayed on a client.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const HitNumbers := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/hit_numbers.gd")
const SnapshotTests := preload("res://mods-unpacked/einfluffles-TogetherTests/snapshot_tests.gd")
const HITBOX := "res://overlap/hitbox.tscn"
const ENEMY := "res://entities/units/enemies/crash_zone/basic/baby_alien/baby_alien.tscn"
const PET := "res://entities/units/pet/catling_gun/catling_gun.tscn"
const PET_EFFECT := "res://items/all/03_paws_n_claws/catling_gun/catling_gun_effect_0.tres"
const SNAPSHOTS := 16
const BURST := 80  # hits in one tick: 100 + i each
const BURST_AT := 2
const MAX_DELAY := 3  # snapshots (100 ms) a number may wait for room
const SPAWN_HIT := 777  # in the enemy's spawn tick, before its first snapshot
const SPAWN_AT := 3
const PET_HIT := 321
const PET_AT := 4
const PLAYER_HIT := 5
const PLAYER_HEAL := 8
const PLAYER_AT := 5
const LOST_HIT := 555  # in the snapshot the client never gets
const LOST_AT := 7
const AIMED_HIT := 888  # from a hitbox beside a unit with an aim shape, effect scale 0.5
const BURN_HIT := 999  # a burn tick: no hitbox, effect scale 0.1
const SCALED_AT := 8
const HITBOX_OFFSET := Vector2(60, -40)
const FLOOD := 320  # plain enemy hits in one tick, then FLOOD_RATE before each snapshot
const FLOOD_RATE := 80
const FLOOD_KEY_AT := 3  # the snapshot before which a player hit, a heal, a crit and a kill come

var t: Node


# What HitNumbers.damage reads of a unit.
class FakeUnit:
	extends Node
	var current_stats := {"health": 10}


func run(test_mod: Node, mod: Node):
	t = test_mod
	_test_wire()
	_test_queue()
	_test_flood()
	_test_dedupe()
	var saved: Dictionary = ProgressData.settings.duplicate(true)
	ProgressData.settings.damage_display = true
	ProgressData.settings.visual_effects = true
	yield(_test_battle(mod), "completed")
	ProgressData.settings = saved


static func is_crit(i: int) -> bool:
	return i % 10 == 0


static func is_kill(i: int) -> bool:
	return i % 10 == 5


func _test_wire() -> void:
	var view: Dictionary = SnapshotTests.new(t).scenario(2, 12, 6, 4, 2, 0, 0, 0, true)
	var at := Vector2(100.5, -20.0)
	view.events = [
		Snapshot.damage_event(5, 12, Vector2.RIGHT, Snapshot.DAMAGE_CRIT, 1, 65534, 0.1, at),
		Snapshot.damage_event(-2, 3, Vector2.ZERO, Snapshot.DAMAGE_DODGE, 0, 65535),
		[Snapshot.EVENT_HEAL, 1, 8, 1],
		Snapshot.damage_event(7, 40, Vector2.UP, 0, 0, 2, 0.5),
	]
	var bytes := Snapshot.encode(view)
	var events: Array = Snapshot.parse(bytes).get("events", [])
	var ok := events.size() == 4
	if ok:
		var aimed: Array = events[0]
		ok = aimed.slice(0, 2) == [Snapshot.EVENT_DAMAGE, 5, 12] and aimed[4] == Snapshot.DAMAGE_CRIT
		ok = ok and aimed[5] == 1 and aimed[6] == 65534 and abs(aimed[7] - 0.1) < 0.006
		ok = ok and aimed[8] is Vector2 and aimed[8].distance_to(at) < 0.3
		var dodged: Array = events[1]
		ok = ok and dodged[1] == -2 and dodged[6] == 65535 and dodged[7] == 1.0 and dodged[8] == null
		ok = ok and events[2] == [Snapshot.EVENT_HEAL, 1, 8, 1]
		ok = ok and events[3][6] == 2 and abs(events[3][7] - 0.5) < 0.006 and events[3][8] == null
	t._check(ok, "numbers keep seq (across the wrap), effect scale and hitbox position %s" % [events])
	var truncated := true
	for size in bytes.size():
		var prefix: PoolByteArray = bytes.subarray(0, size - 1) if size > 0 else PoolByteArray()
		truncated = truncated and Snapshot.parse(prefix).empty()
	t._check(truncated, "every truncation of a snapshot with numbers rejected")
	view.events = []
	var empty := Snapshot.encode(view).size()
	var knockback := Vector2(0.6, -0.8)
	view.events = [Snapshot.damage_event(1000, 25, knockback, 0, 0, 700)]
	var one := Snapshot.encode(view).size()
	view.events.append(Snapshot.damage_event(1004, 31, knockback, 0, 0, 701))
	var two := Snapshot.encode(view).size()
	view.events.append([Snapshot.EVENT_HEAL, 0, 3, 702])
	var heal := Snapshot.encode(view).size() - two
	print("  info: number sizes: first %d B, next %d B, heal %d B" % [one - empty, two - one, heal])
	t._check(two - one == 9 and heal == 4, "a damage number 9 B (1 B of it its seq), a heal 4 B")
	view.events = []
	var bare := Snapshot.encode(view)
	var bad := {
		"heal of a player that cannot be": [Snapshot.EVENT_HEAL, 9, 3, 0],
		"seq step past 16 bits": [Snapshot.EVENT_HEAL, 0, 3, 128, 128, 4],
	}
	for label in bad:
		# The event count, then the empty looks and angles sections close a snapshot.
		var broken := bare.subarray(0, bare.size() - 4)
		broken.append(1)
		broken.append_array(PoolByteArray(bad[label]))
		broken.append_array(PoolByteArray([0, 0]))
		t._check(Snapshot.parse(broken).empty(), "rejected: %s" % label)


func _test_queue() -> void:
	var burst: Dictionary = _queue_run(BURST)
	t._check(
		burst.sent == BURST and burst.last_first <= MAX_DELAY,
		"host: all of %d numbers at once go out within %d snapshots (%d)"
		% [BURST, MAX_DELAY + 1, burst.sent]
	)
	t._check(
		burst.most_copies <= HitNumbers.MAX_COPIES and burst.twice > 0,
		(
			"host: at most %d second copies per snapshot (%d, %d of %d numbers twice)"
			% [HitNumbers.MAX_COPIES, burst.most_copies, burst.twice, BURST]
		)
	)
	t._check(burst.last_first < burst.first_copy, "host: second copies only after every first one")
	t._check(burst.pending == 0, "host: nothing waits after that")
	var fight: Dictionary = _queue_run(12)
	t._check(
		fight.sent == 12 and fight.twice == 12 and fight.last_first == 0 and fight.first_copy == 1,
		"host: a dozen numbers go out at once and again in the next snapshot"
	)
	var numbers = HitNumbers.new()
	numbers.heal(5, 1)
	for k in MAX_DELAY + 2:
		var events := []
		numbers.offer(events, k)
		numbers.sent(HitNumbers.select_events(events, 0))  # never any room
	t._check(numbers.pending() == 0, "host: a number without room is dropped after 100 ms")


# A flood of plain enemy hits keeps the queue full of them and of numbers waiting for their second
# copy; a player hit, a heal, a crit and a kill still go out with the next snapshot.
func _test_flood() -> void:
	var numbers = HitNumbers.new()
	var unit := FakeUnit.new()
	var knock := Vector2.RIGHT
	var normal: int = HitType.NORMAL
	for i in FLOOD:
		numbers.damage(unit, 3, 1000 + i, knock, 0, normal, null)
	var full := false
	var key_out := []
	var most := 0
	for k in FLOOD_KEY_AT + 6:
		if k <= FLOOD_KEY_AT + 1:
			for i in FLOOD_RATE:
				numbers.damage(unit, 3, 2000 + i, knock, 0, normal, null)
		if k == FLOOD_KEY_AT:
			full = numbers._waiting[HitNumbers.RANK_HIT] == HitNumbers.MAX_PENDING
			numbers.damage(unit, -1, 7, knock, 0, normal, null)
			numbers.heal(9, 0)
			numbers.damage(unit, 4, 4242, knock, Snapshot.DAMAGE_CRIT, normal, null)
			unit.current_stats.health = 0
			numbers.damage(unit, 5, 4343, knock, 0, normal, null)
			unit.current_stats.health = 10
		most = int(max(most, numbers.pending()))
		var events := []
		for i in 8:
			events.append([Snapshot.EVENT_ANIM, i, "idle", 0.0, 1.0])
		numbers.offer(events, k)
		var selected := HitNumbers.select_events(events, 48)
		numbers.sent(selected)
		if k == FLOOD_KEY_AT:
			for event in selected:
				if event[0] == Snapshot.EVENT_HEAL:
					key_out.append("+%d" % event[2])
				elif event[0] == Snapshot.EVENT_DAMAGE and (event[1] < 0 or event[2] > 4000):
					key_out.append(("-%d" if event[1] < 0 else "%d") % event[2])
	t._check(
		full and key_out.size() == 4 and "-7" in key_out and "+9" in key_out,
		(
			"host: with the queue full of hits, a player hit, a heal, a crit and a kill go out with"
			+ " the next snapshot (full %s, out %s)" % [full, key_out]
		)
	)
	print("  info: flood queue at most %d entries" % most)
	for i in 1000:
		numbers.damage(unit, 3, 1, knock, 0, normal, null)
		numbers.damage(unit, 4, 1, knock, Snapshot.DAMAGE_CRIT, normal, null)
		numbers.damage(unit, -1, 1, knock, 0, normal, null)
		numbers.heal(1, 0)
	var bound: int = 2 * HitNumbers.MAX_PENDING + HitNumbers.MAX_FEEDBACK + 4 * 48
	t._check(
		numbers.pending() <= bound and numbers.pending() >= 2 * HitNumbers.MAX_PENDING,
		"host: 4000 numbers in one tick, the queue stays bounded (%d of at most %d)"
		% [numbers.pending(), bound]
	)
	for k in range(20, 20 + MAX_DELAY + 2):
		var events := []
		numbers.offer(events, k)
		numbers.sent(HitNumbers.select_events(events, 48))
	t._check(
		numbers.pending() == 0 and numbers._waiting == [0, 0, 0, 0, 0],
		"host: the queue and its counts empty again (%d, %s)" % [numbers.pending(), numbers._waiting]
	)
	unit.free()


# `count` enemy hits at once, then snapshots of 8 animations and up to 48 events.
func _queue_run(count: int) -> Dictionary:
	var numbers = HitNumbers.new()
	var unit := FakeUnit.new()
	for i in count:
		numbers.damage(unit, 3, 1 + i, Vector2.RIGHT, 0, HitType.NORMAL, null)
	unit.free()
	var copies := {}  # seq -> snapshots it went out in
	var most_copies := 0
	for k in MAX_DELAY + 3:
		var events := []
		for i in 8:
			events.append([Snapshot.EVENT_ANIM, i, "idle", 0.0, 1.0])
		numbers.offer(events, k)
		var selected := HitNumbers.select_events(events, 48)
		numbers.sent(selected)
		var second := 0
		for event in selected:
			if event[0] == Snapshot.EVENT_DAMAGE:
				var seq: int = event[6]
				second += 1 if copies.has(seq) else 0
				copies[seq] = copies.get(seq, []) + [k]
		most_copies = int(max(most_copies, second))
	var result := {"sent": copies.size(), "last_first": 0, "first_copy": 99, "twice": 0}
	for seq in copies:
		result.last_first = int(max(result.last_first, copies[seq][0]))
		if copies[seq].size() == 2:
			result.twice += 1
			result.first_copy = int(min(result.first_copy, copies[seq][1]))
	result["most_copies"] = most_copies
	result["pending"] = numbers.pending()
	return result


func _test_dedupe() -> void:
	var numbers = HitNumbers.new()
	var event := Snapshot.damage_event(5, 1, Vector2.ZERO, 0, 0, 65535)
	var sound := [Snapshot.EVENT_SOUND, 3, null, 0.0, 0.0, false, 0.0]
	var ok: bool = numbers.fresh(event) and not numbers.fresh(event.duplicate())
	ok = ok and numbers.fresh([Snapshot.EVENT_HEAL, 0, 3, 0])
	ok = ok and not numbers.fresh([Snapshot.EVENT_HEAL, 1, 2, 0])
	t._check(ok, "client: a number's second copy is dropped, also as another kind of number")
	t._check(numbers.fresh(sound) and numbers.fresh(sound), "client: other events are never dropped")
	for i in HitNumbers.SEEN:
		numbers.fresh([Snapshot.EVENT_HEAL, 0, 3, 1 + i])
	t._check(numbers.fresh(event), "client: a seq is forgotten %d numbers later" % HitNumbers.SEEN)


func _test_battle(mod: Node):
	var host: Node = mod.battle_host
	var client: Node = mod.battle_client
	host.set_process(false)
	CoopService.clear_coop_players()
	for i in 2:
		CoopService.connected_players.push_back([i, CoopService.PlayerType.GAMEPAD_XBOX])
	t.get_tree().change_scene("res://main.tscn")
	yield(t.get_tree(), "idle_frame")
	yield(t.get_tree(), "idle_frame")
	var main := t.get_tree().current_scene
	host._start_battle(main)
	var host_side := {}
	var recorded: Array = yield(_record_host(host, main, host_side), "completed")
	var start: Dictionary = bytes2var(var2bytes(host._battle_start_body()), false)
	start.types = {}
	for path in host._types:
		start.types[host._types[path]] = path
	host._end_battle()
	_check_wire(recorded)
	client._on_battle_start(start)
	yield(client, "battle_entered")
	var seen: Dictionary = yield(_replay(client, recorded, host_side), "completed")
	_check_client(seen)
	_check_scaled(client, recorded, host_side)
	client._leave_battle()
	host.set_process(true)


func _record_host(host: Node, main: Node, host_side: Dictionary):
	var players: Array = main.get("_players")
	for player in players:
		player._weapons_container.propagate_call("set_physics_process", [false])
		player._weapons_container.propagate_call("set_process", [false])
		player.max_stats.health = 100
		player.current_stats.health = 50
	var spawner = main.get("_entity_spawner")
	var zone: Rect2 = ZoneService.get_current_zone_rect()
	var enemies := []
	for i in BURST + 1:
		var at := zone.position + Vector2(100 + (i % 20) * 40, 100 + (i / 20) * 40)
		var enemy: Node = t._spawn_on_host(spawner, ENEMY, EntityType.ENEMY, at)
		enemy.propagate_call("set_physics_process", [false])  # parked: no moves, no attacks
		enemies.append(enemy)
	var pet: Node = t._spawn_on_host(
		spawner, PET, EntityType.PET, zone.end - Vector2(200, 200), load(PET_EFFECT)
	)
	pet.set_physics_process(false)
	host_side["pet"] = pet
	var recorded := []
	for k in SNAPSHOTS:
		yield(t.get_tree().create_timer(1.0 / 30.0), "timeout")
		match k:
			BURST_AT:
				for i in BURST:
					var health: int = enemies[i].current_stats.health
					if is_kill(i):
						enemies[i].current_stats.health = 0  # what take_damage leaves on a kill
					_hit(enemies[i], 100 + i, is_crit(i))
					enemies[i].current_stats.health = health
			SPAWN_AT:
				var fresh: Node = t._spawn_on_host(
					spawner, ENEMY, EntityType.ENEMY, zone.position + Vector2(100, 400)
				)
				fresh.propagate_call("set_physics_process", [false])
				host_side["fresh"] = fresh.get_meta(host.NET_ID_META)
				_hit(fresh, SPAWN_HIT, false)
			PET_AT:
				_hit(pet, PET_HIT, false)
			PLAYER_AT:
				var hit := TakeDamageArgs.new(-1)
				hit.dodgeable = false
				hit.armor_applied = false
				players[0].take_damage(PLAYER_HIT, hit)
				players[0].on_healing_effect(PLAYER_HEAL)
			LOST_AT:
				_hit(enemies[BURST], LOST_HIT, false)
			SCALED_AT:
				_scaled_hits(main, enemies, host_side)
		recorded.append(bytes2var(var2bytes(host._build_snapshot()), false))
		if k == 0:
			host_side["pet_id"] = pet.get_meta(host.NET_ID_META)
			host_side["aimed_id"] = enemies[1].get_meta(host.NET_ID_META)
	return recorded


# A hitbox beside enemy 1, which gets an aim shape like the brachiosaurus' (its hurtbox), and a
# burn tick on enemy 2.
func _scaled_hits(main: Node, enemies: Array, host_side: Dictionary) -> void:
	var aimed: Node = enemies[1]
	aimed.aim_shape = aimed.get_node("Hurtbox/Collision")
	var hitbox: Node = load(HITBOX).instance()
	main.add_child(hitbox)
	hitbox.global_position = aimed.global_position + HITBOX_OFFSET
	hitbox.effect_scale = 0.5
	var args := TakeDamageArgs.new(0, hitbox)
	host_side["feedback_at"] = aimed.get_hit_feedback_position(args)
	host_side["aimed_at"] = aimed.global_position
	_hit(aimed, AIMED_HIT, false, args)
	aimed.aim_shape = null
	hitbox.queue_free()
	var burn := TakeDamageArgs.new(0)
	burn.base_effect_scale = 0.1  # Unit._on_burning_timer_timeout
	burn.is_burning = true
	_hit(enemies[2], BURN_HIT, false, burn)


# Unit.took_damage as take_damage emits it, with the hit's outcome chosen.
static func _hit(unit: Node, value: int, crit: bool, args: TakeDamageArgs = null) -> void:
	if args == null:
		args = TakeDamageArgs.new(0)
	unit.emit_signal(
		"took_damage", unit, value, Vector2.RIGHT, crit, false, false, false, args, 0, false
	)


# Damage values per recorded snapshot, from what the host sent.
static func _sent_values(recorded: Array) -> Array:
	var per_snapshot := []
	for msg in recorded:
		var values := []
		for event in Snapshot.parse(msg[1]).events:
			if event[0] == Snapshot.EVENT_DAMAGE:
				values.append(event[2])
		per_snapshot.append(values)
	return per_snapshot


func _check_wire(recorded: Array) -> void:
	var sent := _sent_values(recorded)
	var in_time := {}
	for k in range(BURST_AT, BURST_AT + MAX_DELAY + 1):
		for value in sent[k]:
			in_time[value] = true
	var missing := []
	var first_missing := []
	for i in BURST:
		if not in_time.has(100 + i):
			missing.append(100 + i)
		if (is_crit(i) or is_kill(i)) and not 100 + i in sent[BURST_AT]:
			first_missing.append(100 + i)
	var times := {}  # burst value -> snapshots it went out in
	var burst := []  # of them per snapshot
	for k in range(BURST_AT, BURST_AT + MAX_DELAY + 1):
		var count := 0
		for value in sent[k]:
			if value >= 100 and value < 100 + BURST:
				times[value] = times.get(value, 0) + 1
				count += 1
		burst.append(count)
	var twice := 0
	for value in times:
		twice += 1 if times[value] >= 2 else 0
	print(
		(
			"  info: numbers per snapshot %s, of them the burst's %s, %d of %d sent twice"
			% [_sizes(sent), burst, twice, BURST]
		)
	)
	t._check(
		missing.empty(),
		(
			"all %d numbers of one tick go out within %d snapshots (missing %s)"
			% [BURST, MAX_DELAY + 1, missing]
		)
	)
	t._check(
		first_missing.empty(),
		"crits and kills go out with the first snapshot after the hits (missing %s)" % [first_missing]
	)
	t._check(
		SPAWN_HIT in sent[SPAWN_AT],
		"a hit in an enemy's spawn tick goes out with its first snapshot"
	)


static func _sizes(sent: Array) -> Array:
	var sizes := []
	for values in sent:
		sizes.append(values.size())
	return sizes


# The snapshot of LOST_AT never arrives. Counts what the client queued per damage value.
func _replay(client: Node, recorded: Array, host_side: Dictionary):
	var seen := {"texts": {}, "queued": {}, "pet_flash": false}
	var puppet_main: Node = client._main
	var replay_start := OS.get_ticks_msec()
	for k in recorded.size():
		var snap := SnapshotTests.retimed(recorded[k], recorded, replay_start)
		while OS.get_ticks_msec() < snap.t:
			yield(t.get_tree(), "idle_frame")
			_sample(client, puppet_main, seen, host_side)
		if k == LOST_AT:
			continue
		var before: int = client._events.size()
		client._on_snapshot(snap)
		for entry in client._events.slice(before, client._events.size() - 1):
			if entry[1][0] == Snapshot.EVENT_DAMAGE:
				seen.queued[entry[1][2]] = seen.queued.get(entry[1][2], 0) + 1
	var until := OS.get_ticks_msec() + 400
	while OS.get_ticks_msec() < until:
		yield(t.get_tree(), "idle_frame")
		_sample(client, puppet_main, seen, host_side)
	return seen


func _sample(client: Node, puppet_main: Node, seen: Dictionary, host_side: Dictionary) -> void:
	for text in puppet_main.get_node("%FloatingTexts").get_children():
		if text.visible:
			seen.texts[text.text] = true
	var pet = client._entities.get(host_side.get("pet_id", -1))
	if pet != null and is_instance_valid(pet) and pet.sprite.material == pet.flash_mat:
		seen.pet_flash = true


func _check_client(seen: Dictionary) -> void:
	var missing := []
	var twice := []
	for i in BURST:
		if seen.queued.get(100 + i, 0) == 0:
			missing.append(100 + i)
		if seen.queued.get(100 + i, 0) > 1:
			twice.append(100 + i)
	var label := "client queues all %d numbers of one tick (missing %s)" % [BURST, missing]
	t._check(missing.empty(), label)
	t._check(twice.empty(), "client queues each number once (twice: %s)" % [twice])
	t._check(seen.texts.has(str(SPAWN_HIT)), "client shows the hit of an enemy's spawn tick")
	t._check(
		not seen.texts.has(str(PET_HIT)),
		"no number for a hit on a pet (the game shows none)"
	)
	t._check(seen.pet_flash, "a hit pet still flashes like the host's")
	var player_texts := []
	for text in seen.texts:
		if text.begins_with("+") or text.begins_with("-"):
			player_texts.append(text)
	t._check(
		(
			seen.texts.has("-%d" % PLAYER_HIT)
			and seen.texts.has("+%d" % PLAYER_HEAL)
			and not seen.texts.has("+%d" % (PLAYER_HEAL - PLAYER_HIT))
		),
		"a hit and a heal in one snapshot show their own numbers %s" % [player_texts]
	)
	t._check(
		seen.queued.get(LOST_HIT, 0) == 1,
		"a number of a lost snapshot arrives once with the next (%d)" % seen.queued.get(LOST_HIT, 0)
	)


# What the client's handlers read for the two scaled hits: the effect scale, and for the unit
# with an aim shape the spot the host's number and hit effect had.
func _check_scaled(client: Node, recorded: Array, host_side: Dictionary) -> void:
	var events := {}
	for msg in recorded:
		for event in Snapshot.parse(msg[1]).events:
			if event[0] == Snapshot.EVENT_DAMAGE and event[2] in [AIMED_HIT, BURN_HIT]:
				events[event[2]] = event
	var aimed = events.get(AIMED_HIT)
	var burn = events.get(BURN_HIT)
	t._check(
		aimed != null and aimed[8] != null and abs(aimed[7] - 0.5) < 0.01,
		"a hit on a unit with an aim shape carries its hitbox' position and effect scale"
	)
	t._check(
		burn != null and burn[8] == null and abs(burn[7] - 0.1) < 0.01,
		"a burn tick carries its effect scale (0.1) and no position"
	)
	var unit = client._entities.get(host_side.aimed_id)
	if aimed == null or burn == null or unit == null:
		return
	unit.global_position = host_side.aimed_at  # where the host's was hit: it moves since
	unit.aim_shape = unit.get_node("Hurtbox/Collision")
	var args: TakeDamageArgs = client._numbers._args_of(client._main, aimed)
	var at: Vector2 = unit.get_hit_feedback_position(args)
	unit.aim_shape = null
	t._check(
		at.distance_to(host_side.feedback_at) < 1.0 and abs(args.get_effect_scale() - 0.5) < 0.01,
		"client: number and hit effect where the host's are (%s, host %s)" % [at, host_side.feedback_at]
	)
	var stand_in: Node = args.hitbox
	t._check(
		not stand_in.monitoring and not stand_in.monitorable and stand_in.get_node("Collision").disabled,
		"client: the stand-in hitbox finds nothing and is found by nothing"
	)
	args = client._numbers._args_of(client._main, burn)
	t._check(
		args.hitbox == null and abs(args.get_effect_scale() - 0.1) < 0.01,
		"client: a burn tick's hit effect at a tenth like the host's"
	)
