extends Reference
# Damage and heal numbers (EVENT_DAMAGE, EVENT_HEAL) and which events a snapshot carries.
# - Host: Unit.took_damage of the players and mirrored units and Player.healed become numbers with
#   a seq (u16 per battle). A number waits up to MAX_DELAY snapshots for room under the event cap
#   and goes out in COPIES snapshots, so a lost snapshot loses none (at most MAX_COPIES second
#   copies per snapshot). select_events ranks it: crits and kills over other hits, second copies
#   last. Numbers waiting for their first copy are capped per kind (MAX_PENDING, MAX_FEEDBACK), so
#   a flood of plain hits never keeps out a player's number, a heal, a crit or a kill.
# - Client: a seq it already has is dropped (fresh), the rest is shown through the game's own
#   handlers.
# One instance per battle on each side.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const HITBOX_SCENE := "res://overlap/hitbox.tscn"
const MAX_DELAY := 3  # snapshots (100 ms) a number may wait for room, its second copy included
const COPIES := 2
const MAX_COPIES := 16  # second copies per snapshot: at most 144 B more in a big fight
# Numbers waiting for their first copy, of each kind: plain enemy hits, key enemy hits (crits,
# kills, ...), player numbers and heals (their rate is bounded by the game: i-frames, 4 players).
# More of a kind are dropped. Numbers already sent once wait only for their second copy and do
# not count: they leave the queue within MAX_DELAY + 1 snapshots of being first offered, so at most
# 4 snapshots' worth of selected numbers (4 * BattleHost.MAX_EVENTS = 192) are among them. Hard
# bound of the queue: 256 + 256 + 64 + 192 = 768 entries.
const MAX_PENDING := 256  # per kind of enemy number
const MAX_FEEDBACK := 64
const SEEN := 1024  # seqs the client remembers: 16 snapshots full of numbers
# select_events: lower ranks are kept first.
const RANK_STATE := 0
const RANK_FEEDBACK := 1  # player numbers, explosions, stat texts, ...
const RANK_SOUND := 2
const RANK_KEY_HIT := 3  # crits, kills, one-shots, gold hits; a player number's second copy
const RANK_HIT := 4
const RANK_SAME_SOUND := 5  # a stream already in the snapshot
const RANK_COPY := 6  # an enemy number's second copy
const RANK_STRIDE := 1 << 20

var _seq := 0  # the next number's
# [event with its rank last, snapshot first offered in (-1: none), copies sent, rank when added]
var _pending := []
var _waiting := [0, 0, 0, 0, 0]  # by rank when added: entries not sent yet
var _by_seq := {}  # seq -> its _pending entry
var _seen := {}  # seq -> true
var _ring := PoolIntArray()  # the seqs in _seen, oldest at _ring_at
var _ring_at := 0
var _hitbox: WeakRef = null  # the client's stand-in for the host's hitbox (_args_of)


func _init() -> void:
	_ring.resize(SEEN)
	for i in SEEN:
		_ring[i] = -1


# Host, from Unit.took_damage. target: the unit's net id, or -(player_index + 1).
func damage(
	unit: Node, target: int, value: int, knockback: Vector2, flags: int, hit_type: int, args
) -> void:
	var rank := RANK_FEEDBACK if target < 0 else RANK_HIT
	if target >= 0 and (
		flags & (Snapshot.DAMAGE_CRIT | Snapshot.DAMAGE_ONE_SHOT)
		or hit_type != HitType.NORMAL
		or unit.current_stats.health <= 0  # a kill: take_damage left it at 0
	):
		rank = RANK_KEY_HIT
	if not _has_room(rank):
		return
	var scale := 1.0
	var from = null
	if args != null:
		scale = args.get_effect_scale()
		var hitbox = args.hitbox
		# Where the number and the hit effect go on a unit with an aim shape (bosses, dinosaurs).
		if hitbox != null and hitbox.is_inside_tree() and unit.get("aim_shape") != null:
			from = hitbox.global_position
	var event := Snapshot.damage_event(target, value, knockback, flags, hit_type, _seq, scale, from)
	_add(event + [rank])


# Host, from Player.healed (FloatingTextManager._on_player_healed shows "+value").
func heal(value: int, player_index: int) -> void:
	if value > 0 and _has_room(RANK_FEEDBACK):
		_add([Snapshot.EVENT_HEAL, player_index, value, _seq, RANK_FEEDBACK])


func _has_room(rank: int) -> bool:
	return _waiting[rank] < (MAX_FEEDBACK if rank == RANK_FEEDBACK else MAX_PENDING)


func _add(event: Array) -> void:
	var rank: int = event[-1]
	_waiting[rank] += 1
	var entry := [event, -1, 0, rank]
	_pending.append(entry)
	_by_seq[_seq] = entry
	_seq = (_seq + 1) & Snapshot.SEQ_MASK


# Host, before select_events: the numbers that may go out with this snapshot, oldest first (so in
# seq order, which keeps their seqs small on the wire).
func offer(events: Array, snapshot_count: int) -> void:
	var kept := []
	var copies := 0
	for entry in _pending:
		var event: Array = entry[0]
		if entry[1] < 0:
			entry[1] = snapshot_count
		if entry[2] >= COPIES or snapshot_count - entry[1] > MAX_DELAY:
			_by_seq.erase(Snapshot.number_seq(event, -1))
			if entry[2] == 0:
				_waiting[entry[3]] -= 1
			continue
		kept.append(entry)
		if entry[2] > 0:
			if copies >= MAX_COPIES:
				continue
			copies += 1
			var player: bool = event[0] == Snapshot.EVENT_HEAL or event[1] < 0
			event[-1] = RANK_KEY_HIT if player else RANK_COPY
		events.append(event)
	_pending = kept


# Host, after select_events: counts the copies that went out.
func sent(selected: Array) -> void:
	for event in selected:
		var entry = _by_seq.get(Snapshot.number_seq(event, -1))
		if entry != null:
			if entry[2] == 0:
				_waiting[entry[3]] -= 1
			entry[2] += 1


func pending() -> int:
	return _pending.size()


# At most `limit` events by RANK_*, the least valuable dropped first: second copies of enemy
# numbers, duplicate sounds (same stream already in this snapshot), damage numbers on enemies
# (crits and kills after the others), sounds; numbers on players, explosions and the like;
# animations, bonus gold and the wave's end last (they are state). Numbers carry their rank
# after their wire fields. Kept events stay in order.
static func select_events(events: Array, limit: int) -> Array:
	if events.size() <= limit:
		return events
	var ranked := []
	var sounds := {}
	for i in events.size():
		var event: Array = events[i]
		var rank := RANK_FEEDBACK
		match event[0]:
			Snapshot.EVENT_ANIM, Snapshot.EVENT_BONUS_GOLD, Snapshot.EVENT_WAVE_END:
				rank = RANK_STATE
			Snapshot.EVENT_DAMAGE:
				if event.size() > Snapshot.DAMAGE_FIELDS:
					rank = event[Snapshot.DAMAGE_FIELDS]
				elif event[1] >= 0:
					rank = RANK_HIT
			Snapshot.EVENT_HEAL:
				if event.size() > Snapshot.HEAL_FIELDS:
					rank = event[Snapshot.HEAL_FIELDS]
			Snapshot.EVENT_SOUND:
				rank = RANK_SAME_SOUND if sounds.has(event[1]) else RANK_SOUND
				sounds[event[1]] = true
		ranked.append(rank * RANK_STRIDE + i)
	ranked.sort()
	var keep := {}
	for k in limit:
		keep[ranked[k] % RANK_STRIDE] = true
	var selected := []
	for i in events.size():
		if keep.has(i):
			selected.append(events[i])
	return selected


# Client, for each event of a parsed snapshot: false for a number whose seq already came.
func fresh(event: Array) -> bool:
	var seq := Snapshot.number_seq(event, -1)
	if seq < 0:
		return true
	if _seen.has(seq):
		return false
	_seen.erase(_ring[_ring_at])
	_ring[_ring_at] = seq
	_ring_at = (_ring_at + 1) % SEEN
	_seen[seq] = true
	return true


# Client: what main.connect_visual_effects connects to Unit.took_damage (numbers, hit particles),
# for players, enemies and neutrals only like the game, the screen shake, and the hit flash
# take_damage itself does on every unit.
func show_damage(main: Node, target, event: Array) -> void:
	if target == null or typeof(event[3]) != TYPE_VECTOR2:
		return
	var flags := int(event[4])
	var args := [
		target,
		int(event[2]),
		event[3],
		bool(flags & Snapshot.DAMAGE_CRIT),
		bool(flags & Snapshot.DAMAGE_DODGE),
		bool(flags & Snapshot.DAMAGE_PROTECTED),
		bool(flags & Snapshot.DAMAGE_ARMOR),
		_args_of(main, event),
		int(event[5]),
		bool(flags & Snapshot.DAMAGE_ONE_SHOT),
	]
	if target is Player or target is Enemy or target is Neutral:
		for manager_name in ["_floating_text_manager", "_effects_manager"]:
			var manager = main.get(manager_name)
			if manager != null:
				manager.callv("_on_unit_took_damage", args)
	shake(main, target, args)
	if int(event[2]) > 0 and target.has_method("flash") and not target.dead:
		target.flash()


# The TakeDamageArgs the handlers read: the effect scale and, for a unit with an aim shape, a
# hitbox where the host's was (Unit.get_hit_feedback_position).
func _args_of(main: Node, event: Array) -> TakeDamageArgs:
	if event[8] == null:
		var args := TakeDamageArgs.new(RunData.DUMMY_PLAYER_INDEX)
		args.base_effect_scale = event[7]
		return args
	var hitbox = _hitbox.get_ref() if _hitbox != null else null
	if not is_instance_valid(hitbox) or not hitbox.is_inside_tree():
		hitbox = load(HITBOX_SCENE).instance()
		hitbox.deals_damage = false
		hitbox.active = false
		hitbox.monitorable = false  # found by no hurtbox (it monitors nothing either)
		hitbox.visible = false
		main.add_child(hitbox)
		hitbox.get_node("Collision").disabled = true
		_hitbox = weakref(hitbox)
	hitbox.global_position = event[8]
	hitbox.effect_scale = event[7]
	return TakeDamageArgs.new(RunData.DUMMY_PLAYER_INDEX, hitbox)


# Screenshaker's handlers, connected by main to the players and to every enemy / neutral.
static func shake(main: Node, target: Node, args: Array) -> void:
	var shaker = main.get("_screenshaker")
	if shaker == null:
		return
	if target is Player:
		shaker.callv("_on_player_took_damage", args)
	elif target is Enemy or target is Neutral:
		shaker.callv("_on_unit_took_damage", args)


# Client: FloatingTextManager._on_player_healed, which main connects to Player.healed.
static func show_heal(main: Node, event: Array) -> void:
	var texts = main.get("_floating_text_manager")
	if texts != null and event[1] < texts.players.size():
		texts._on_player_healed(event[2], event[1])
